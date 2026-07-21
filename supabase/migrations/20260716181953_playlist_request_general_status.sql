begin;

-- O status de decisão de playlist_requests permanece compatível
-- (pending/approved/rejected). O ciclo operacional é projetado separadamente.
create or replace function public.playlist_request_general_status(p_request_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_decision text;
  v_job_status text;
  v_total integer := 0;
  v_completed integer := 0;
  v_failed integer := 0;
  v_review integer := 0;
  v_resolving integer := 0;
  v_processing integer := 0;
begin
  select r.status,
         (
           select j.status
             from public.download_jobs j
            where j.playlist_request_id = r.id
               or j.id = r.download_job_id
            order by j.created_at desc, j.id desc
            limit 1
         )
    into v_decision, v_job_status
    from public.playlist_requests r
   where r.id = p_request_id;

  if v_decision is null then return null; end if;
  if v_decision = 'pending' then return 'pending'; end if;
  if v_decision = 'rejected' then return 'rejected'; end if;

  select
    count(*)::integer,
    count(*) filter (where item_status in ('completed', 'duplicate'))::integer,
    count(*) filter (where item_status = 'failed')::integer,
    count(*) filter (where item_status = 'review_recommended')::integer,
    count(*) filter (where item_status = 'resolving')::integer,
    count(*) filter (where item_status = 'processing')::integer
  into v_total, v_completed, v_failed, v_review, v_resolving, v_processing
  from public.playlist_request_tracks
  where playlist_request_id = p_request_id;

  if v_review > 0 then return 'waiting_review'; end if;
  if v_resolving > 0 or (v_job_status = 'running' and v_total = 0) then return 'analyzing'; end if;
  if v_processing > 0 or v_job_status = 'running' then return 'processing'; end if;
  if v_job_status = 'queued' then return 'approved'; end if;

  if v_completed > 0 and (v_failed > 0 or v_job_status = 'partial') then
    return 'partially_completed';
  end if;
  if v_failed > 0 and v_completed = 0 then return 'failed'; end if;

  if v_job_status = 'error' then
    if v_completed > 0 then return 'partially_completed'; end if;
    -- Sem itens, a falha é geral (resolver, plataforma, R2, Supabase etc.).
    if v_total = 0 then return 'failed'; end if;
    -- Somente exclusões esperadas (não encontrada, duração, limite, ignorada)
    -- não transformam a solicitação inteira em falha técnica.
    return 'completed';
  end if;

  if v_job_status = 'done' then return 'completed'; end if;
  if v_job_status = 'partial' then
    return case when v_completed > 0 then 'partially_completed' else 'failed' end;
  end if;
  return 'approved';
end;
$$;

revoke all on function public.playlist_request_general_status(uuid)
  from public, anon, authenticated;

-- Preserva lifecycle_status para os consumidores existentes e acrescenta
-- general_status com o vocabulário detalhado da Fase 10.
alter function public.get_my_playlist_requests(jsonb)
  rename to get_my_playlist_requests_phase10_impl;
revoke all on function public.get_my_playlist_requests_phase10_impl(jsonb)
  from public, anon, authenticated;

create function public.get_my_playlist_requests(p_request jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_requests jsonb;
begin
  v_payload := public.get_my_playlist_requests_phase10_impl(p_request);
  if coalesce((v_payload->>'success')::boolean, false) is not true then
    return v_payload;
  end if;

  select coalesce(jsonb_agg(
    request_row || jsonb_build_object(
      'general_status',
      public.playlist_request_general_status((request_row->>'id')::uuid)
    )
    order by request_row->>'created_at' desc, request_row->>'id' desc
  ), '[]'::jsonb)
  into v_requests
  from jsonb_array_elements(coalesce(v_payload#>'{data,requests}', '[]'::jsonb)) request_row;

  return jsonb_set(v_payload, '{data,requests}', v_requests, true);
end;
$$;

revoke all on function public.get_my_playlist_requests(jsonb) from public, anon;
grant execute on function public.get_my_playlist_requests(jsonb) to authenticated;

-- O detalhe do Admin recebe a mesma projeção, sem duplicar as regras.
alter function public.admin_playlist_request_detail(uuid)
  rename to admin_playlist_request_detail_phase10_impl;
revoke all on function public.admin_playlist_request_detail_phase10_impl(uuid)
  from public, anon, authenticated;

create function public.admin_playlist_request_detail(p_playlist_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_request_id uuid;
begin
  v_payload := public.admin_playlist_request_detail_phase10_impl(p_playlist_id);
  if v_payload is null then return null; end if;
  v_request_id := nullif(v_payload#>>'{request,id}', '')::uuid;
  return jsonb_set(
    v_payload,
    '{request,general_status}',
    to_jsonb(public.playlist_request_general_status(v_request_id)),
    true
  );
end;
$$;

revoke all on function public.admin_playlist_request_detail(uuid) from public, anon;
grant execute on function public.admin_playlist_request_detail(uuid) to authenticated;

commit;
