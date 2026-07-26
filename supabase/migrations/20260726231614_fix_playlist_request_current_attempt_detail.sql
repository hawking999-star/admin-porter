begin;

-- Reimportacoes preservam as tentativas anteriores para auditoria. O detalhe do
-- Admin, entretanto, representa o estado atual e nao pode somar as linhas de
-- todos os jobs da mesma solicitacao.
create or replace function public.admin_playlist_request_detail(p_playlist_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_request_id uuid;
  v_job_id uuid;
  v_messages jsonb;
  v_items jsonb;
  v_summary jsonb;
  v_technical jsonb;
begin
  v_payload := public.admin_playlist_request_detail_phase12_impl(p_playlist_id);
  if v_payload is null then return null; end if;

  v_request_id := nullif(v_payload#>>'{request,id}', '')::uuid;

  select j.id
    into v_job_id
    from public.download_jobs j
    join public.playlist_requests r on r.id = v_request_id
   where (
     j.playlist_request_id = r.id
     or j.id = r.download_job_id
   )
     and coalesce(j.mode, 'playlist') = 'playlist'
   order by j.created_at desc, j.id desc
   limit 1;

  select pg_catalog.jsonb_build_object(
    'total', count(*),
    'resolved', count(*) filter (
      where prt.item_status in ('resolved', 'processing', 'completed')
    ),
    'review_recommended', count(*) filter (
      where prt.item_status = 'review_recommended'
    ),
    'not_found', count(*) filter (where prt.item_status = 'not_found'),
    'duplicate', count(*) filter (where prt.item_status = 'duplicate'),
    'duration_exceeded', count(*) filter (
      where prt.item_status = 'duration_exceeded'
    ),
    'playlist_limit_exceeded', count(*) filter (
      where prt.item_status = 'playlist_limit_exceeded'
    ),
    'failed', count(*) filter (where prt.item_status = 'failed')
  )
  into v_summary
  from public.playlist_request_tracks prt
  where prt.playlist_request_id = v_request_id
    and (v_job_id is null or prt.download_job_id = v_job_id);

  select coalesce(
    pg_catalog.jsonb_agg(
      item || pg_catalog.jsonb_build_object(
        'operator_message',
        public.playlist_request_item_operator_message(item->>'status')
      )
      order by coalesce((item->>'position')::integer, 0), item->>'id'
    ),
    '[]'::jsonb
  )
  into v_items
  from pg_catalog.jsonb_array_elements(
    coalesce(v_payload->'items', '[]'::jsonb)
  ) item
  join public.playlist_request_tracks prt
    on prt.id = (item->>'id')::uuid
  where prt.playlist_request_id = v_request_id
    and (v_job_id is null or prt.download_job_id = v_job_id);

  v_messages := public.playlist_request_operator_messages(v_request_id);

  select pg_catalog.jsonb_build_object(
    'code', j.error_code,
    'summary', j.error_details->>'technical_summary',
    'details', j.error_details
  )
  into v_technical
  from public.download_jobs j
  where j.id = v_job_id;

  v_payload := pg_catalog.jsonb_set(v_payload, '{summary}', v_summary, true);
  v_payload := pg_catalog.jsonb_set(v_payload, '{items}', v_items, true);
  v_payload := pg_catalog.jsonb_set(
    v_payload,
    '{request,operator_messages}',
    v_messages,
    true
  );
  v_payload := pg_catalog.jsonb_set(
    v_payload,
    '{request,operator_message}',
    coalesce(pg_catalog.to_jsonb(v_messages->>0), 'null'::jsonb),
    true
  );
  v_payload := pg_catalog.jsonb_set(
    v_payload,
    '{request,technical_error}',
    coalesce(v_technical, 'null'::jsonb),
    true
  );

  return v_payload;
end;
$$;

revoke all on function public.admin_playlist_request_detail(uuid)
  from public, anon;
grant execute on function public.admin_playlist_request_detail(uuid)
  to authenticated;

-- Mensagens amigaveis seguem a mesma tentativa vigente usada nos contadores.
create or replace function public.playlist_request_operator_messages(
  p_request_id uuid
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_general text;
  v_source text;
  v_job_id uuid;
  v_error_code text;
  v_review integer := 0;
  v_not_found integer := 0;
  v_duration integer := 0;
  v_limit integer := 0;
  v_messages jsonb := '[]'::jsonb;
begin
  select
    public.playlist_request_general_status(r.id),
    public.playlist_source_platform(r.source_url),
    latest_job.id,
    latest_job.error_code
  into v_general, v_source, v_job_id, v_error_code
  from public.playlist_requests r
  left join lateral (
    select j.id, j.error_code
      from public.download_jobs j
     where (
       j.playlist_request_id = r.id
       or j.id = r.download_job_id
     )
       and coalesce(j.mode, 'playlist') = 'playlist'
     order by j.created_at desc, j.id desc
     limit 1
  ) latest_job on true
  where r.id = p_request_id;

  if v_general is null then return '[]'::jsonb; end if;

  select
    count(*) filter (where item_status = 'review_recommended')::integer,
    count(*) filter (where item_status = 'not_found')::integer,
    count(*) filter (where item_status = 'duration_exceeded')::integer,
    count(*) filter (where item_status = 'playlist_limit_exceeded')::integer
  into v_review, v_not_found, v_duration, v_limit
  from public.playlist_request_tracks
  where playlist_request_id = p_request_id
    and (v_job_id is null or download_job_id = v_job_id);

  if v_general = 'partially_completed' then
    v_messages := v_messages || pg_catalog.jsonb_build_array(
      'A solicitação foi concluída parcialmente.'
    );
  end if;
  if v_general = 'waiting_review' or v_review > 0 then
    v_messages := v_messages || pg_catalog.jsonb_build_array(
      'Existem músicas que parecem versões diferentes e precisam de revisão.'
    );
  end if;

  if v_error_code = 'SPOTIFY_PLAYLIST_EMPTY' then
    v_messages := v_messages || pg_catalog.jsonb_build_array(
      'A playlist do Spotify não possui músicas disponíveis.'
    );
  elsif v_error_code = 'PLAYLIST_EMPTY' then
    v_messages := v_messages || pg_catalog.jsonb_build_array(
      'A playlist não possui músicas disponíveis.'
    );
  elsif v_error_code = 'SPOTIFY_LINK_UNAVAILABLE' then
    v_messages := v_messages || pg_catalog.jsonb_build_array(
      'O link do Spotify não está mais disponível.'
    );
  elsif v_error_code = any(array[
    'SPOTIFY_RESOLVER_UNAVAILABLE', 'SPOTIFY_RESOLVE_TIMEOUT',
    'IMPORT_TIMEOUT', 'REQUEST_TIMEOUT', 'WORKER_STALE_TIMEOUT',
    'WORKER_ENV_MISSING', 'SUPABASE_PERMISSION_DENIED', 'SUPABASE_ERROR',
    'R2_ACCESS_DENIED', 'R2_ERROR', 'IMPORTER_ERROR'
  ]) then
    v_messages := v_messages || pg_catalog.jsonb_build_array(
      'O serviço de importação está temporariamente indisponível.'
    );
  end if;

  if v_not_found > 0
     or v_error_code in ('SPOTIFY_MATCH_NOT_FOUND', 'IMPORTED_WITH_UNAVAILABLE') then
    v_messages := v_messages || pg_catalog.jsonb_build_array(
      'Não foi possível localizar algumas músicas no YouTube.'
    );
  end if;
  if v_limit > 0 then
    v_messages := v_messages || pg_catalog.jsonb_build_array(
      'A playlist ultrapassa o limite de 170 músicas.'
    );
  end if;
  if v_duration > 0 then
    v_messages := v_messages || pg_catalog.jsonb_build_array(
      'Uma ou mais músicas ultrapassam a duração máxima de 16 minutos.'
    );
  end if;
  if v_general = 'failed' and pg_catalog.jsonb_array_length(v_messages) = 0 then
    v_messages := pg_catalog.jsonb_build_array(
      case when v_source = 'spotify'
        then 'Não foi possível processar este link do Spotify.'
        else 'O serviço de importação está temporariamente indisponível.'
      end
    );
  end if;

  return v_messages;
end;
$$;

revoke all on function public.playlist_request_operator_messages(uuid)
  from public, anon, authenticated;

-- Ignorar uma faixa e concluir uma troca manual sao decisoes terminais. O job
-- original continua preservado, mas nao mantem o status geral preso em falha.
create or replace function public.playlist_request_general_status(p_request_id uuid)
returns text
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_decision text;
  v_job_id uuid;
  v_job_status text;
  v_job_completed integer := 0;
  v_total integer := 0;
  v_completed integer := 0;
  v_failed integer := 0;
  v_review integer := 0;
  v_resolving integer := 0;
  v_processing integer := 0;
begin
  select
    r.status,
    latest_job.id,
    latest_job.status,
    coalesce(latest_job.completed, 0)
  into
    v_decision,
    v_job_id,
    v_job_status,
    v_job_completed
  from public.playlist_requests r
  left join lateral (
    select j.id, j.status, j.completed
    from public.download_jobs j
    where (
      j.playlist_request_id = r.id
      or j.id = r.download_job_id
    )
      and coalesce(j.mode, 'playlist') = 'playlist'
    order by j.created_at desc, j.id desc
    limit 1
  ) latest_job on true
  where r.id = p_request_id;

  if v_decision is null then return null; end if;
  if v_decision = 'pending' then return 'pending'; end if;
  if v_decision = 'rejected' then return 'rejected'; end if;

  select
    count(*)::integer,
    count(*) filter (
      where item_status in ('completed', 'duplicate', 'skipped')
    )::integer,
    count(*) filter (where item_status = 'failed')::integer,
    count(*) filter (where item_status = 'review_recommended')::integer,
    count(*) filter (where item_status = 'resolving')::integer,
    count(*) filter (where item_status = 'processing')::integer
  into v_total, v_completed, v_failed, v_review, v_resolving, v_processing
  from public.playlist_request_tracks
  where playlist_request_id = p_request_id
    and (v_job_id is null or download_job_id = v_job_id);

  if v_job_status = 'queued' then return 'analyzing'; end if;
  if v_job_status = 'done' then return 'completed'; end if;
  if v_job_status = 'partial' then
    if v_review > 0 then return 'waiting_review'; end if;
    if v_total > 0
       and v_completed = v_total
       and v_failed = 0
       and v_resolving = 0
       and v_processing = 0 then
      return 'completed';
    end if;
    return case when v_job_completed > 0 then 'partially_completed' else 'failed' end;
  end if;
  if v_job_status = 'running' then
    if v_review > 0 then return 'waiting_review'; end if;
    if v_resolving > 0 or v_total = 0 then return 'analyzing'; end if;
    return 'processing';
  end if;
  if v_job_status = 'error' then
    if v_job_completed > 0 then return 'partially_completed'; end if;
    if v_total = 0 or v_failed > 0 then return 'failed'; end if;
    return 'completed';
  end if;

  if v_review > 0 then return 'waiting_review'; end if;
  if v_resolving > 0 then return 'analyzing'; end if;
  if v_processing > 0 then return 'processing'; end if;
  if v_completed > 0 and v_failed > 0 then return 'partially_completed'; end if;
  if v_failed > 0 and v_completed = 0 then return 'failed'; end if;
  return 'approved';
end;
$$;

revoke all on function public.playlist_request_general_status(uuid)
  from public, anon, authenticated;

commit;
