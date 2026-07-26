-- A remediação manual pode concluir o único item que deixou o job original
-- como partial. O histórico do job é preservado, mas o status apresentado ao
-- Admin e ao App deve refletir o estado atual dos itens daquela tentativa.
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
    count(*) filter (where item_status in ('completed', 'duplicate'))::integer,
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
