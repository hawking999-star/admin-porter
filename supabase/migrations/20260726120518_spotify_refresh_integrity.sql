-- Atualização fresca de playlists Spotify com fila retomável.
begin;

alter table public.download_jobs
  add column if not exists next_attempt_at timestamptz not null default pg_catalog.now();

drop index if exists public.download_jobs_queued_created_idx;
create index if not exists download_jobs_queued_next_attempt_idx
  on public.download_jobs (next_attempt_at, created_at, id)
  where status = 'queued';

drop index if exists public.playlist_request_tracks_resumable_idx;
create index playlist_request_tracks_resumable_idx
  on public.playlist_request_tracks (download_job_id, position)
  where item_status in ('resolving', 'resolved', 'processing', 'failed');

create or replace function public.worker_claim_download_job(
  p_max_concurrent integer default 1
)
returns setof public.download_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_max_concurrent, 1), 1), 10);
begin
  perform pg_catalog.pg_advisory_xact_lock(7823479120341);
  if (select count(*) from public.download_jobs where status = 'running') >= v_limit then
    return;
  end if;

  return query
  with candidate as (
    select job.id
      from public.download_jobs job
     where job.status = 'queued'
       and job.next_attempt_at <= pg_catalog.now()
     order by job.next_attempt_at, job.created_at, job.id
     for update skip locked
     limit 1
  )
  update public.download_jobs job
     set status = 'running',
         started_at = coalesce(job.started_at, pg_catalog.now()),
         locked_at = pg_catalog.now(),
         attempts = job.attempts + 1,
         error = null,
         error_code = null,
         error_message = null,
         error_details = null,
         last_error_at = null,
         updated_at = pg_catalog.now()
    from candidate
   where job.id = candidate.id
  returning job.*;
end;
$$;

revoke all on function public.worker_claim_download_job(integer)
  from public, anon, authenticated;
grant execute on function public.worker_claim_download_job(integer) to service_role;

create or replace function public.worker_claim_playlist_request_item(
  p_job_id uuid,
  p_position integer,
  p_max_attempts integer default 2,
  p_stale_after_seconds integer default 1800
)
returns setof public.playlist_request_tracks
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max_attempts integer := least(greatest(coalesce(p_max_attempts, 2), 1), 5);
  v_stale_seconds integer := least(greatest(coalesce(p_stale_after_seconds, 1800), 60), 7200);
begin
  if not exists (
    select 1
      from public.download_jobs job
     where job.id = p_job_id
       and job.status = 'running'
  ) then
    return;
  end if;

  return query
  with candidate as (
    select item.id
      from public.playlist_request_tracks item
     where item.download_job_id = p_job_id
       and item.position = p_position
       and item.attempts < v_max_attempts
       and (
         item.item_status in ('resolving', 'resolved', 'failed')
         or (
           item.item_status = 'processing'
           and (
             item.locked_at is null
             or item.locked_at < pg_catalog.now()
               - pg_catalog.make_interval(secs => v_stale_seconds)
           )
         )
       )
     for update skip locked
     limit 1
  )
  update public.playlist_request_tracks item
     set item_status = 'processing',
         attempts = item.attempts + 1,
         locked_at = pg_catalog.now(),
         last_error_code = null,
         error_message = null,
         updated_at = pg_catalog.now()
    from candidate
   where item.id = candidate.id
  returning item.*;
end;
$$;

revoke all on function public.worker_claim_playlist_request_item(uuid, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.worker_claim_playlist_request_item(uuid, integer, integer, integer)
  to service_role;

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

create or replace function public.sync_playlist_import_from_job()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_import_status text;
  v_message text;
  v_code text;
  v_has_library boolean := false;
begin
  if coalesce(new.mode, 'playlist') <> 'playlist' then
    return new;
  end if;

  if exists (
    select 1
    from public.download_jobs later_job
    where later_job.playlist_id = new.playlist_id
      and coalesce(later_job.mode, 'playlist') = 'playlist'
      and (later_job.created_at, later_job.id) > (new.created_at, new.id)
  ) then
    return new;
  end if;

  select exists (
    select 1
    from public.playlist_tracks link
    join public.tracks track on track.id = link.track_id
    where link.playlist_id = new.playlist_id
      and track.status in ('available', 'processing')
  ) into v_has_library;

  v_import_status := case
    when v_has_library and new.status in ('queued', 'running', 'partial', 'error')
      then 'success'
    when new.status in ('queued', 'running') then 'processing'
    when new.status = 'done' then 'success'
    when new.status in ('partial', 'error') then 'failed'
    else 'not_started'
  end;

  v_code := coalesce(
    new.error_code,
    case
      when new.status in ('partial', 'error') and coalesce(new.completed, 0) = 0
        then 'NO_TRACKS_DOWNLOADED'
      when new.status in ('partial', 'error') then 'PARTIAL_IMPORT_FAILED'
      else null
    end
  );
  v_message := public.playlist_import_error_message(
    v_code,
    coalesce(new.error_message, new.error)
  );

  update public.playlists
  set
    import_status = v_import_status,
    import_started_at = case
      when new.status in ('queued', 'running')
        then coalesce(import_started_at, new.started_at, pg_catalog.now())
      else import_started_at
    end,
    import_finished_at = case
      when new.status in ('done', 'partial', 'error')
        then coalesce(new.finished_at, pg_catalog.now())
      else import_finished_at
    end,
    error_code = case
      when new.status in ('partial', 'error') then v_code
      else null
    end,
    error_message = case
      when new.status in ('partial', 'error') then v_message
      else null
    end,
    error_details = case
      when new.status in ('partial', 'error') then coalesce(
        new.error_details,
        pg_catalog.jsonb_build_object(
          'download_job_id', new.id,
          'download_status', new.status,
          'raw_error', new.error,
          'completed', new.completed,
          'failed', new.failed,
          'total', new.total
        )
      )
      when new.error_details is not null then new.error_details
      else null
    end,
    last_error_at = case
      when new.status in ('partial', 'error')
        then coalesce(new.last_error_at, pg_catalog.now())
      else null
    end
  where id = new.playlist_id;

  return new;
end;
$$;

comment on column public.download_jobs.next_attempt_at is
  'Instante mínimo para novo claim; usado pelo backoff do Spotify.';

commit;
