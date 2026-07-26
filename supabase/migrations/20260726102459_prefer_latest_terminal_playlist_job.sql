begin;

-- A playlist_request pode ser reenfileirada mais de uma vez e seus itens
-- preservam o histórico das tentativas anteriores. O job de playlist mais
-- recente é a fonte de verdade do resultado final; itens antigos não podem
-- rebaixar um job novo que terminou com sucesso.
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
  v_job_total integer := 0;
  v_job_completed integer := 0;
  v_job_failed integer := 0;
  v_total integer := 0;
  v_completed integer := 0;
  v_failed integer := 0;
  v_review integer := 0;
  v_resolving integer := 0;
  v_processing integer := 0;
begin
  select
    r.status,
    latest_job.status,
    coalesce(latest_job.total, 0),
    coalesce(latest_job.completed, 0),
    coalesce(latest_job.failed, 0)
  into
    v_decision,
    v_job_status,
    v_job_total,
    v_job_completed,
    v_job_failed
  from public.playlist_requests r
  left join lateral (
    select j.status, j.total, j.completed, j.failed
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

  -- Estados do job mais recente prevalecem sobre resíduos de tentativas
  -- anteriores armazenados em playlist_request_tracks.
  if v_job_status = 'queued' then return 'approved'; end if;
  if v_job_status = 'done' then return 'completed'; end if;
  if v_job_status = 'partial' then
    return case when v_job_completed > 0 then 'partially_completed' else 'failed' end;
  end if;

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

  if v_job_status = 'running' then
    if v_review > 0 then return 'waiting_review'; end if;
    if v_resolving > 0 or v_total = 0 then return 'analyzing'; end if;
    return 'processing';
  end if;

  if v_job_status = 'error' then
    if v_job_completed > 0 then return 'partially_completed'; end if;
    if v_total = 0 or v_failed > 0 then return 'failed'; end if;
    -- Somente exclusões esperadas (não encontrada, duração, limite, ignorada)
    -- não transformam a solicitação inteira em falha técnica.
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

-- Corrige resultados legados em que o banco já tinha atingido o teto de
-- 170 faixas, mas o worker antigo classificou a restrição esperada como erro.
-- O relatório técnico é preservado; nenhuma faixa ou vínculo é alterado.
with latest_playlist_jobs as (
  select
    j.id,
    p.id as playlist_id,
    row_number() over (
      partition by j.playlist_id
      order by j.created_at desc, j.id desc
    ) as job_order
  from public.download_jobs j
  join public.playlists p on p.id = j.playlist_id
  where coalesce(j.mode, 'playlist') = 'playlist'
),
full_principal_playlists as (
  select pt.playlist_id
  from public.playlist_tracks pt
  join public.tracks t on t.id = pt.track_id
  where t.status in ('available', 'processing')
  group by pt.playlist_id
  having count(*) >= 170
)
update public.download_jobs j
set
  status = 'done',
  error = null,
  error_code = null,
  error_message = null,
  last_error_at = null,
  updated_at = pg_catalog.now()
from latest_playlist_jobs latest,
     full_principal_playlists full_playlist,
     public.playlists p
where latest.id = j.id
  and latest.job_order = 1
  and full_playlist.playlist_id = j.playlist_id
  and p.id = j.playlist_id
  and p.type = 'principal'
  and j.status = 'partial'
  and coalesce(j.completed, 0) > 0
  and exists (
    select 1
    from jsonb_array_elements(coalesce(j.error_details->'skipped', '[]'::jsonb)) skipped
    where coalesce(skipped->>'reason', '') ilike '%PRINCIPAL_TRACK_LIMIT_REACHED%'
  );

commit;
