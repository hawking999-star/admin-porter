begin;

-- Durable transport. The public pgmq helper schema is intentionally not used:
-- every operation below is exposed through a narrowly scoped service_role RPC.
create extension if not exists pgmq;

do $$
begin
  if not exists (
    select 1 from pgmq.list_queues() where queue_name = 'music_import_control'
  ) then
    perform pgmq.create('music_import_control');
  end if;
  if not exists (
    select 1 from pgmq.list_queues() where queue_name = 'music_import_tracks'
  ) then
    perform pgmq.create('music_import_tracks');
  end if;
end;
$$;

create schema if not exists private;

alter table public.download_jobs
  add column if not exists operational_status text not null default 'queued',
  add column if not exists provider_defer_count integer not null default 0,
  add column if not exists provider_first_deferred_at timestamptz,
  add column if not exists provider_deferred_seconds bigint not null default 0,
  add column if not exists provider_resume_at timestamptz;

alter table public.download_jobs
  add constraint download_jobs_operational_status_check
  check (operational_status in (
    'queued', 'processing', 'waiting_provider', 'waiting_review',
    'completed', 'completed_with_issues', 'failed', 'cancelled'
  )),
  add constraint download_jobs_provider_defer_count_check
  check (provider_defer_count >= 0),
  add constraint download_jobs_provider_deferred_seconds_check
  check (provider_deferred_seconds >= 0);

create table private.music_import_runtime_config (
  singleton boolean primary key default true check (singleton),
  backend text not null default 'legacy' check (backend in ('legacy', 'shadow', 'pgmq')),
  max_active_playlists integer not null default 10 check (max_active_playlists between 1 and 50),
  max_tracks_per_playlist integer not null default 1 check (max_tracks_per_playlist between 1 and 5),
  max_youtube_operations integer not null default 2 check (max_youtube_operations between 1 and 10),
  max_upload_operations integer not null default 2 check (max_upload_operations between 1 and 10),
  youtube_start_spacing_seconds integer not null default 15 check (youtube_start_spacing_seconds between 0 and 300),
  worker_replica_target integer not null default 2 check (worker_replica_target between 1 and 20),
  last_youtube_start_at timestamptz,
  updated_at timestamptz not null default now(),
  updated_by_admin_id uuid references public.admin_users(id) on delete set null
);

insert into private.music_import_runtime_config (singleton)
values (true)
on conflict (singleton) do nothing;

create table private.music_provider_health (
  provider text primary key,
  status text not null default 'healthy' check (status in ('healthy', 'degraded', 'blocked', 'probing')),
  consecutive_failures integer not null default 0 check (consecutive_failures >= 0),
  first_failure_at timestamptz,
  last_failure_at timestamptz,
  last_success_at timestamptz,
  next_probe_at timestamptz,
  probe_lease_until timestamptz,
  error_code text,
  error_message text,
  total_blocked_seconds bigint not null default 0 check (total_blocked_seconds >= 0),
  updated_at timestamptz not null default now()
);

insert into private.music_provider_health (provider, status, last_success_at)
values ('youtube', 'healthy', now())
on conflict (provider) do nothing;

create table private.music_import_tasks (
  id uuid primary key default gen_random_uuid(),
  task_kind text not null check (task_kind in ('control', 'track', 'remediation', 'upload')),
  source_kind text not null check (source_kind in ('youtube', 'spotify_match', 'upload')),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  playlist_request_id uuid references public.playlist_requests(id) on delete cascade,
  download_job_id uuid references public.download_jobs(id) on delete set null,
  request_item_id uuid references public.playlist_request_tracks(id) on delete set null,
  upload_session_id uuid,
  status text not null default 'queued' check (status in (
    'queued', 'processing', 'waiting_provider', 'waiting_review',
    'waiting_upload', 'succeeded', 'skipped', 'failed',
    'dead_letter', 'cancelled'
  )),
  attempt_count integer not null default 0 check (attempt_count >= 0),
  defer_count integer not null default 0 check (defer_count >= 0),
  first_deferred_at timestamptz,
  deferred_seconds bigint not null default 0 check (deferred_seconds >= 0),
  lease_owner text,
  lease_expires_at timestamptz,
  next_attempt_at timestamptz not null default now(),
  queue_name text,
  queue_message_id bigint,
  queue_archived_at timestamptz,
  error_code text,
  error_message text,
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  started_at timestamptz,
  finished_at timestamptz,
  constraint music_import_tasks_queue_check check (
    queue_name is null or queue_name in ('music_import_control', 'music_import_tracks')
  )
);

create unique index music_import_tasks_request_item_kind_key
  on private.music_import_tasks (request_item_id, task_kind)
  where request_item_id is not null;
create unique index music_import_tasks_control_job_key
  on private.music_import_tasks (download_job_id)
  where task_kind = 'control' and download_job_id is not null;
create index music_import_tasks_status_next_idx
  on private.music_import_tasks (status, next_attempt_at, created_at);
create index music_import_tasks_playlist_status_idx
  on private.music_import_tasks (playlist_id, status, updated_at desc);

create table private.music_import_events (
  id bigint generated always as identity primary key,
  task_id uuid not null references private.music_import_tasks(id) on delete cascade,
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  from_status text,
  to_status text not null,
  error_code text,
  message text,
  duration_ms bigint,
  details jsonb not null default '{}'::jsonb,
  occurred_at timestamptz not null default now()
);

create index music_import_events_task_occurred_idx
  on private.music_import_events (task_id, occurred_at desc);
create index music_import_events_playlist_occurred_idx
  on private.music_import_events (playlist_id, occurred_at desc);

create table private.music_import_operation_leases (
  id uuid primary key,
  operation_kind text not null check (operation_kind in ('youtube', 'upload')),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  worker_id text not null,
  leased_at timestamptz not null default now(),
  lease_expires_at timestamptz not null,
  created_at timestamptz not null default now()
);

create index music_import_operation_leases_active_idx
  on private.music_import_operation_leases (operation_kind, lease_expires_at);

create table private.music_upload_sessions (
  id uuid primary key default gen_random_uuid(),
  playlist_id uuid not null references public.playlists(id) on delete cascade,
  playlist_request_id uuid references public.playlist_requests(id) on delete cascade,
  request_item_id uuid not null references public.playlist_request_tracks(id) on delete cascade,
  task_id uuid references private.music_import_tasks(id) on delete set null,
  admin_user_id uuid not null references public.admin_users(id) on delete restrict,
  original_filename text not null,
  declared_mime text not null,
  declared_size_bytes bigint not null check (declared_size_bytes between 1 and 52428800),
  rights_attested boolean not null check (rights_attested),
  rights_statement text not null check (length(btrim(rights_statement)) between 10 and 1000),
  staging_object_key text not null unique,
  status text not null default 'prepared' check (status in ('prepared', 'uploaded', 'processing', 'completed', 'failed', 'expired', 'cancelled')),
  expires_at timestamptz not null,
  used_at timestamptz,
  r2_etag text,
  verified_size_bytes bigint,
  content_sha256 text,
  final_track_id uuid references public.tracks(id) on delete set null,
  error_code text,
  error_message text,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint music_upload_session_single_use check (
    (used_at is null and status in ('prepared', 'uploaded'))
    or (used_at is not null and status in ('processing', 'completed', 'failed', 'expired', 'cancelled'))
  )
);

alter table private.music_import_tasks
  add constraint music_import_tasks_upload_session_fkey
  foreign key (upload_session_id) references private.music_upload_sessions(id) on delete set null;

create index music_upload_sessions_expiry_idx
  on private.music_upload_sessions (status, expires_at);

alter table private.music_import_runtime_config enable row level security;
alter table private.music_provider_health enable row level security;
alter table private.music_import_tasks enable row level security;
alter table private.music_import_events enable row level security;
alter table private.music_import_operation_leases enable row level security;
alter table private.music_upload_sessions enable row level security;

revoke all on schema pgmq from public, anon, authenticated;
revoke all on all tables in schema pgmq from public, anon, authenticated;
revoke all on all functions in schema pgmq from public, anon, authenticated;
revoke all on table private.music_import_runtime_config from public, anon, authenticated, service_role;
revoke all on table private.music_provider_health from public, anon, authenticated, service_role;
revoke all on table private.music_import_tasks from public, anon, authenticated, service_role;
revoke all on table private.music_import_events from public, anon, authenticated, service_role;
revoke all on table private.music_import_operation_leases from public, anon, authenticated, service_role;
revoke all on table private.music_upload_sessions from public, anon, authenticated, service_role;

create or replace function private.music_import_task_status_from_item(p_status text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_status
    when 'pending' then 'queued'
    when 'resolving' then 'queued'
    when 'resolved' then 'queued'
    when 'processing' then 'processing'
    when 'review_recommended' then 'waiting_review'
    when 'completed' then 'succeeded'
    when 'duplicate' then 'skipped'
    when 'skipped' then 'skipped'
    when 'not_found' then 'skipped'
    when 'duration_exceeded' then 'skipped'
    when 'playlist_limit_exceeded' then 'skipped'
    when 'failed' then 'failed'
    else 'queued'
  end
$$;

create or replace function private.music_import_enqueue_task_message(p_task_id uuid)
returns bigint
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task private.music_import_tasks%rowtype;
  v_backend text;
  v_queue text;
  v_message_id bigint;
begin
  select * into v_task from private.music_import_tasks where id = p_task_id for update;
  if not found or v_task.queue_message_id is not null or v_task.status <> 'queued' then
    return v_task.queue_message_id;
  end if;

  select backend into v_backend from private.music_import_runtime_config where singleton;
  if v_backend not in ('shadow', 'pgmq') then return null; end if;

  v_queue := case when v_task.task_kind = 'control'
    then 'music_import_control' else 'music_import_tracks' end;
  select * into v_message_id
  from pgmq.send(v_queue, pg_catalog.jsonb_build_object('version', 1, 'task_id', v_task.id), 0);

  update private.music_import_tasks
     set queue_name = v_queue,
         queue_message_id = v_message_id,
         updated_at = now()
   where id = v_task.id;
  return v_message_id;
end;
$$;

create or replace function private.music_import_task_audit_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_duration_ms bigint;
begin
  if tg_op = 'INSERT' or old.status is distinct from new.status then
    v_duration_ms := case
      when tg_op = 'UPDATE' then greatest(0, floor(extract(epoch from (now() - old.updated_at)) * 1000)::bigint)
      else null
    end;
    insert into private.music_import_events (
      task_id, playlist_id, from_status, to_status, error_code, message, duration_ms
    ) values (
      new.id, new.playlist_id,
      case when tg_op = 'UPDATE' then old.status else null end,
      new.status, new.error_code, new.error_message, v_duration_ms
    );
  end if;

  if new.status = 'queued' and new.queue_message_id is null then
    perform private.music_import_enqueue_task_message(new.id);
  elsif new.status in ('succeeded', 'skipped', 'failed', 'dead_letter', 'cancelled')
        and new.queue_message_id is not null
        and new.queue_archived_at is null then
    if pgmq.archive(new.queue_name, new.queue_message_id) then
      update private.music_import_tasks
         set queue_archived_at = now(), updated_at = now()
       where id = new.id and queue_archived_at is null;
    end if;
  end if;
  return new;
end;
$$;

create trigger trg_music_import_task_audit
after insert or update of status on private.music_import_tasks
for each row execute function private.music_import_task_audit_trigger();

create or replace function private.sync_music_import_task_from_item()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_playlist_id uuid;
  v_source text;
  v_status text;
begin
  select r.playlist_id,
         case when public.playlist_source_platform(r.source_url) = 'spotify'
           then 'spotify_match' else 'youtube' end
    into v_playlist_id, v_source
    from public.playlist_requests r
   where r.id = new.playlist_request_id;
  if v_playlist_id is null then return new; end if;

  v_status := private.music_import_task_status_from_item(new.item_status);
  insert into private.music_import_tasks (
    task_kind, source_kind, playlist_id, playlist_request_id,
    download_job_id, request_item_id, status, attempt_count,
    error_code, error_message, metadata, started_at, finished_at
  ) values (
    case when coalesce((select mode from public.download_jobs where id = new.download_job_id), 'playlist') = 'single_track'
      then 'remediation' else 'track' end,
    v_source, v_playlist_id, new.playlist_request_id, new.download_job_id,
    new.id, v_status, coalesce(new.attempts, 0), new.last_error_code,
    new.error_message,
    pg_catalog.jsonb_build_object('position', new.position, 'youtube_video_id', new.youtube_video_id),
    case when v_status = 'processing' then coalesce(new.locked_at, now()) else null end,
    case when v_status in ('succeeded', 'skipped', 'failed') then now() else null end
  )
  on conflict (request_item_id, task_kind) where request_item_id is not null do update
    set download_job_id = coalesce(excluded.download_job_id, private.music_import_tasks.download_job_id),
        task_kind = excluded.task_kind,
        source_kind = excluded.source_kind,
        status = excluded.status,
        attempt_count = excluded.attempt_count,
        error_code = excluded.error_code,
        error_message = excluded.error_message,
        metadata = private.music_import_tasks.metadata || excluded.metadata,
        lease_expires_at = case when excluded.status = 'processing'
          then coalesce(new.locked_at, now()) + interval '30 minutes' else null end,
        started_at = case when excluded.status = 'processing'
          then coalesce(private.music_import_tasks.started_at, now()) else private.music_import_tasks.started_at end,
        finished_at = case when excluded.status in ('succeeded', 'skipped', 'failed')
          then now() else null end,
        updated_at = now();
  return new;
end;
$$;

create trigger trg_sync_music_import_task_from_item
after insert or update of item_status, attempts, last_error_code, error_message, download_job_id
on public.playlist_request_tracks
for each row execute function private.sync_music_import_task_from_item();

create or replace function private.create_music_import_control_task()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(new.mode, 'playlist') <> 'playlist' then return new; end if;
  insert into private.music_import_tasks (
    task_kind, source_kind, playlist_id, playlist_request_id, download_job_id,
    status, metadata
  ) values (
    'control',
    case when public.playlist_source_platform(new.source_url) = 'spotify'
      then 'spotify_match' else 'youtube' end,
    new.playlist_id, new.playlist_request_id, new.id,
    case new.status when 'running' then 'processing' when 'done' then 'succeeded'
      when 'partial' then 'failed' when 'error' then 'failed' else 'queued' end,
    pg_catalog.jsonb_build_object('mode', coalesce(new.mode, 'playlist'))
  ) on conflict (download_job_id) where task_kind = 'control' and download_job_id is not null
    do nothing;
  return new;
end;
$$;

create trigger trg_create_music_import_control_task
after insert on public.download_jobs
for each row execute function private.create_music_import_control_task();

create or replace function private.sync_music_import_control_task()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_status text;
begin
  if coalesce(new.mode, 'playlist') <> 'playlist' then return new; end if;
  v_status := case
    when new.operational_status = 'waiting_provider' then 'waiting_provider'
    when new.operational_status = 'waiting_review' then 'waiting_review'
    when new.operational_status in ('completed', 'completed_with_issues') then 'succeeded'
    when new.status = 'running' then 'processing'
    when new.status = 'done' then 'succeeded'
    when new.status in ('partial', 'error') then 'failed'
    else 'queued'
  end;
  update private.music_import_tasks
     set status = v_status,
         error_code = new.error_code,
         error_message = new.error_message,
         next_attempt_at = case when new.next_attempt_at = 'infinity'::timestamptz then now() else new.next_attempt_at end,
         started_at = case when v_status = 'processing' then coalesce(started_at, now()) else started_at end,
         finished_at = case when v_status in ('succeeded', 'failed', 'cancelled') then now() else null end,
         updated_at = now()
   where download_job_id = new.id and task_kind = 'control';
  return new;
end;
$$;

create trigger trg_sync_music_import_control_task
after update of status, operational_status, error_code, error_message, next_attempt_at
on public.download_jobs
for each row execute function private.sync_music_import_control_task();

-- Backfill is generic and idempotent: it never downloads or relinks audio.
insert into private.music_import_tasks (
  task_kind, source_kind, playlist_id, playlist_request_id, download_job_id,
  status, metadata, started_at, finished_at
)
select 'control',
       case when public.playlist_source_platform(j.source_url) = 'spotify' then 'spotify_match' else 'youtube' end,
       j.playlist_id, j.playlist_request_id, j.id,
       case j.status when 'running' then 'processing' when 'done' then 'succeeded'
         when 'partial' then 'failed' when 'error' then 'failed' else 'queued' end,
       pg_catalog.jsonb_build_object('mode', coalesce(j.mode, 'playlist')),
       j.started_at, j.finished_at
  from public.download_jobs j
 where coalesce(j.mode, 'playlist') = 'playlist'
on conflict (download_job_id) where task_kind = 'control' and download_job_id is not null
do nothing;

insert into private.music_import_tasks (
  task_kind, source_kind, playlist_id, playlist_request_id, download_job_id,
  request_item_id, status, attempt_count, error_code, error_message, metadata,
  started_at, finished_at
)
select case when coalesce(j.mode, 'playlist') = 'single_track' then 'remediation' else 'track' end,
       case when public.playlist_source_platform(r.source_url) = 'spotify' then 'spotify_match' else 'youtube' end,
       r.playlist_id, item.playlist_request_id, item.download_job_id, item.id,
       private.music_import_task_status_from_item(item.item_status), item.attempts,
       item.last_error_code, item.error_message,
       pg_catalog.jsonb_build_object('position', item.position, 'youtube_video_id', item.youtube_video_id),
       item.locked_at,
       case when private.music_import_task_status_from_item(item.item_status) in ('succeeded', 'skipped', 'failed')
         then item.updated_at else null end
  from public.playlist_request_tracks item
  join public.playlist_requests r on r.id = item.playlist_request_id
  left join public.download_jobs j on j.id = item.download_job_id
on conflict (request_item_id, task_kind) where request_item_id is not null do nothing;

create or replace function private.reconcile_music_import_job(p_job_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.download_jobs%rowtype;
  v_total integer;
  v_imported integer;
  v_failed integer;
  v_not_found integer;
  v_review integer;
  v_skipped integer;
  v_active integer;
  v_effective_failed integer;
  v_operational text;
  v_effective_items jsonb;
begin
  select * into v_job from public.download_jobs where id = p_job_id;
  if not found or coalesce(v_job.mode, 'playlist') <> 'playlist' then return; end if;

  select count(*)::integer,
         count(*) filter (where item_status = 'completed')::integer,
         count(*) filter (where item_status = 'failed')::integer,
         count(*) filter (where item_status = 'not_found')::integer,
         count(*) filter (where item_status = 'review_recommended')::integer,
         count(*) filter (where item_status in ('skipped', 'duplicate', 'duration_exceeded', 'playlist_limit_exceeded'))::integer,
         count(*) filter (where item_status in ('pending', 'resolving', 'resolved', 'processing'))::integer
    into v_total, v_imported, v_failed, v_not_found, v_review, v_skipped, v_active
    from public.playlist_request_tracks
   where download_job_id = v_job.id;

  if v_total = 0 then return; end if;
  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'item_id', id,
    'youtube_id', youtube_video_id,
    'title', coalesce(title, youtube_video_id, 'Faixa'),
    'duration_seconds', case when duration_ms is null then null else duration_ms / 1000.0 end,
    'code', coalesce(last_error_code,
      case item_status when 'not_found' then 'SPOTIFY_MATCH_NOT_FOUND'
        when 'duration_exceeded' then 'TRACK_DURATION_LIMIT_EXCEEDED'
        when 'playlist_limit_exceeded' then 'PLAYLIST_LIMIT_EXCEEDED'
        else upper(item_status) end),
    'reason', error_message,
    'status', item_status
  ) order by position), '[]'::jsonb) into v_effective_items
  from public.playlist_request_tracks
  where download_job_id = v_job.id
    and item_status in ('failed', 'not_found', 'review_recommended', 'duration_exceeded', 'playlist_limit_exceeded');
  v_effective_failed := v_failed + v_not_found;
  v_operational := case
    when v_job.operational_status = 'waiting_provider' then 'waiting_provider'
    when v_job.status = 'queued' then 'queued'
    when v_job.status = 'running' then case when v_review > 0 then 'waiting_review' else 'processing' end
    when v_review > 0 then 'waiting_review'
    when v_effective_failed > 0 or v_skipped > 0 then 'completed_with_issues'
    when v_imported > 0 and v_active = 0 then 'completed'
    else 'failed'
  end;

  update public.download_jobs
     set total = v_total,
         completed = v_imported,
         failed = v_effective_failed,
         operational_status = v_operational,
         error_details = coalesce(error_details, '{}'::jsonb) || pg_catalog.jsonb_build_object(
           'effective_summary', pg_catalog.jsonb_build_object(
             'total', v_total, 'imported', v_imported, 'failed', v_failed,
             'not_found', v_not_found, 'review', v_review, 'skipped', v_skipped,
             'active', v_active
           ),
           'effective_items', v_effective_items
         ),
         updated_at = now()
   where id = v_job.id;
end;
$$;

create or replace function private.reconcile_music_import_job_trigger()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.download_job_id is not null then
    perform private.reconcile_music_import_job(new.download_job_id);
  end if;
  return new;
end;
$$;

create trigger trg_reconcile_music_import_job
after insert or update of item_status, track_id, error_message on public.playlist_request_tracks
for each row execute function private.reconcile_music_import_job_trigger();

do $$
declare v_job_id uuid;
begin
  for v_job_id in
    select distinct download_job_id from public.playlist_request_tracks where download_job_id is not null
  loop
    perform private.reconcile_music_import_job(v_job_id);
  end loop;
end;
$$;

create or replace function public.worker_claim_download_job(p_max_concurrent integer default 1)
returns setof public.download_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer;
  v_backend text;
  v_message record;
  v_task_id uuid;
  v_job_id uuid;
begin
  select least(
    greatest(coalesce(p_max_concurrent, 1), 1),
    max_active_playlists
  ), backend into v_limit, v_backend
  from private.music_import_runtime_config where singleton;

  perform pg_catalog.pg_advisory_xact_lock(7823479120341);
  if (select count(*) from public.download_jobs where status = 'running') >= v_limit then return; end if;

  if v_backend = 'pgmq' then
    for v_message in
      select * from pgmq.read('music_import_control', 1800, 10)
    loop
      if coalesce(v_message.message->>'version', '') <> '1'
         or coalesce(v_message.message->>'task_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
        perform pgmq.archive('music_import_control', v_message.msg_id);
        continue;
      end if;
      v_task_id := (v_message.message->>'task_id')::uuid;
      select task.download_job_id into v_job_id
        from private.music_import_tasks task
       where task.id = v_task_id
         and task.task_kind = 'control'
         and task.status = 'queued'
         and task.queue_message_id = v_message.msg_id
         and task.next_attempt_at <= now();
      if v_job_id is null then
        perform pgmq.set_vt('music_import_control', v_message.msg_id, 60);
        continue;
      end if;
      if not exists (
        select 1 from public.download_jobs job
         where job.id = v_job_id and job.status = 'queued'
           and job.next_attempt_at <= now()
           and job.operational_status <> 'waiting_provider'
      ) then
        perform pgmq.set_vt('music_import_control', v_message.msg_id, 60);
        continue;
      end if;
      return query
      update public.download_jobs job
         set status = 'running', operational_status = 'processing',
             started_at = coalesce(job.started_at, now()), locked_at = now(),
             attempts = job.attempts + 1, error = null, error_code = null,
             error_message = null, last_error_at = null, updated_at = now()
       where job.id = v_job_id
      returning job.*;
      return;
    end loop;
    return;
  end if;

  return query
  with candidate as (
    select job.id
      from public.download_jobs job
     where job.status = 'queued'
       and job.next_attempt_at <= now()
       and job.operational_status <> 'waiting_provider'
     order by job.next_attempt_at, job.created_at, job.id
     for update skip locked
     limit 1
  )
  update public.download_jobs job
     set status = 'running', operational_status = 'processing',
         started_at = coalesce(job.started_at, now()), locked_at = now(),
         attempts = job.attempts + 1, error = null, error_code = null,
         error_message = null, last_error_at = null, updated_at = now()
    from candidate
   where job.id = candidate.id
  returning job.*;
end;
$$;

revoke all on function public.worker_claim_download_job(integer) from public, anon, authenticated;
grant execute on function public.worker_claim_download_job(integer) to service_role;

create or replace function public.worker_defer_youtube_job(
  p_job_id uuid,
  p_error_code text,
  p_error_message text,
  p_error_details jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.download_jobs%rowtype;
  v_health private.music_provider_health%rowtype;
  v_defer_count integer;
  v_delay integer;
  v_blocked boolean;
  v_next timestamptz;
begin
  select * into v_job from public.download_jobs where id = p_job_id for update;
  if not found then raise exception 'download_job_not_found'; end if;
  select * into v_health from private.music_provider_health where provider = 'youtube' for update;

  v_defer_count := v_job.provider_defer_count + 1;
  v_delay := case when v_defer_count = 1 then 900 when v_defer_count = 2 then 1800 else 3600 end;
  v_blocked := v_defer_count >= 3;
  v_next := now() + pg_catalog.make_interval(secs => v_delay);

  update private.music_provider_health
     set status = case when v_blocked then 'blocked' else 'degraded' end,
         consecutive_failures = greatest(consecutive_failures + 1, v_defer_count),
         first_failure_at = coalesce(first_failure_at, now()),
         last_failure_at = now(), next_probe_at = v_next, probe_lease_until = null,
         error_code = left(coalesce(p_error_code, 'YOUTUBE_PROVIDER_UNAVAILABLE'), 120),
         error_message = left(coalesce(p_error_message, 'YouTube indisponível.'), 1000),
         updated_at = now()
   where provider = 'youtube';

  update public.download_jobs
     set status = 'queued', operational_status = 'waiting_provider',
         next_attempt_at = case when v_blocked then 'infinity'::timestamptz else v_next end,
         attempts = greatest(attempts - 1, 0), locked_at = null, finished_at = null,
         provider_defer_count = v_defer_count,
         provider_first_deferred_at = coalesce(provider_first_deferred_at, now()),
         provider_deferred_seconds = provider_deferred_seconds + v_delay,
         provider_resume_at = case when v_blocked then null else v_next end,
         error = 'waiting_provider', error_code = p_error_code,
         error_message = case when v_blocked
           then 'A importação está aguardando a recuperação confirmada do YouTube. Use um arquivo próprio ou retome após validar o provedor.'
           else pg_catalog.format('YouTube indisponível. Nova verificação de saúde em %s minuto(s).', v_delay / 60)
         end,
         error_details = coalesce(p_error_details, '{}'::jsonb) || pg_catalog.jsonb_build_object(
           'provider_defer_count', v_defer_count,
           'provider_first_deferred_at', coalesce(provider_first_deferred_at, now()),
           'provider_deferred_seconds', provider_deferred_seconds + v_delay,
           'next_provider_check_at', case when v_blocked then null else v_next end,
           'requires_provider_probe', true
         ),
         last_error_at = now(), updated_at = now()
   where id = v_job.id;

  update private.music_import_tasks
     set status = 'waiting_provider', defer_count = defer_count + 1,
         first_deferred_at = coalesce(first_deferred_at, now()),
         deferred_seconds = deferred_seconds + v_delay,
         next_attempt_at = v_next, error_code = p_error_code,
         error_message = p_error_message, lease_owner = null, lease_expires_at = null,
         updated_at = now()
   where download_job_id = v_job.id
     and status in ('queued', 'processing', 'waiting_provider');

  return pg_catalog.jsonb_build_object(
    'defer_count', v_defer_count, 'blocked', v_blocked,
    'delay_seconds', v_delay, 'next_probe_at', v_next
  );
end;
$$;

revoke all on function public.worker_defer_youtube_job(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.worker_defer_youtube_job(uuid, text, text, jsonb) to service_role;

create or replace function public.worker_claim_youtube_probe(p_lease_seconds integer default 180)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_health private.music_provider_health%rowtype;
begin
  select * into v_health from private.music_provider_health where provider = 'youtube' for update;
  if v_health.status = 'healthy'
     or v_health.next_probe_at is null
     or v_health.next_probe_at > now()
     or coalesce(v_health.probe_lease_until, '-infinity'::timestamptz) > now() then
    return pg_catalog.jsonb_build_object('claimed', false, 'status', v_health.status, 'next_probe_at', v_health.next_probe_at);
  end if;
  update private.music_provider_health
     set status = 'probing',
         probe_lease_until = now() + pg_catalog.make_interval(secs => least(greatest(coalesce(p_lease_seconds, 180), 30), 600)),
         updated_at = now()
   where provider = 'youtube';
  return pg_catalog.jsonb_build_object('claimed', true, 'status', v_health.status, 'next_probe_at', v_health.next_probe_at);
end;
$$;

create or replace function public.worker_record_youtube_probe_result(
  p_success boolean,
  p_error_code text default null,
  p_error_message text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_resumed integer := 0; v_failures integer;
begin
  if p_success then
    update private.music_provider_health
       set status = 'healthy', consecutive_failures = 0, first_failure_at = null,
           last_success_at = now(), next_probe_at = null, probe_lease_until = null,
           error_code = null, error_message = null, updated_at = now()
     where provider = 'youtube';
    update public.download_jobs
       set operational_status = 'queued', next_attempt_at = now(), provider_resume_at = now(),
           error_message = 'YouTube validado. Importação devolvida à fila.', updated_at = now()
     where status = 'queued' and operational_status = 'waiting_provider';
    get diagnostics v_resumed = row_count;
    update private.music_import_tasks
       set status = 'queued', next_attempt_at = now(), error_code = null,
           error_message = null, updated_at = now()
     where status = 'waiting_provider';
    return pg_catalog.jsonb_build_object('healthy', true, 'resumed_jobs', v_resumed);
  end if;

  select consecutive_failures into v_failures
    from private.music_provider_health where provider = 'youtube' for update;
  update private.music_provider_health
     set status = case when greatest(v_failures, 3) >= 3 then 'blocked' else 'degraded' end,
         consecutive_failures = greatest(v_failures, 3), last_failure_at = now(),
         next_probe_at = now() + interval '60 minutes', probe_lease_until = null,
         error_code = left(coalesce(p_error_code, 'YOUTUBE_CANARY_FAILED'), 120),
         error_message = left(coalesce(p_error_message, 'Falha no canário do YouTube.'), 1000),
         updated_at = now()
   where provider = 'youtube';
  return pg_catalog.jsonb_build_object('healthy', false, 'next_probe_at', now() + interval '60 minutes');
end;
$$;

revoke all on function public.worker_claim_youtube_probe(integer) from public, anon, authenticated;
revoke all on function public.worker_record_youtube_probe_result(boolean, text, text) from public, anon, authenticated;
grant execute on function public.worker_claim_youtube_probe(integer) to service_role;
grant execute on function public.worker_record_youtube_probe_result(boolean, text, text) to service_role;

create or replace function public.worker_acquire_music_import_slot(
  p_operation_kind text,
  p_owner_id uuid,
  p_playlist_id uuid,
  p_worker_id text,
  p_lease_seconds integer default 180
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_config private.music_import_runtime_config%rowtype; v_limit integer; v_active integer; v_wait integer := 0;
begin
  if p_operation_kind not in ('youtube', 'upload') then raise exception 'invalid_operation_kind'; end if;
  perform pg_catalog.pg_advisory_xact_lock(7823479120342);
  delete from private.music_import_operation_leases where lease_expires_at <= now();
  select * into v_config from private.music_import_runtime_config where singleton for update;
  v_limit := case when p_operation_kind = 'youtube' then v_config.max_youtube_operations else v_config.max_upload_operations end;
  select count(*)::integer into v_active from private.music_import_operation_leases where operation_kind = p_operation_kind;
  if v_active >= v_limit then return pg_catalog.jsonb_build_object('acquired', false, 'retry_after_seconds', 5); end if;
  if p_operation_kind = 'youtube' and v_config.last_youtube_start_at is not null then
    v_wait := greatest(0, ceil(v_config.youtube_start_spacing_seconds - extract(epoch from (now() - v_config.last_youtube_start_at)))::integer);
    if v_wait > 0 then return pg_catalog.jsonb_build_object('acquired', false, 'retry_after_seconds', v_wait); end if;
  end if;
  insert into private.music_import_operation_leases (id, operation_kind, playlist_id, worker_id, lease_expires_at)
  values (p_owner_id, p_operation_kind, p_playlist_id, left(p_worker_id, 200), now() + pg_catalog.make_interval(secs => least(greatest(coalesce(p_lease_seconds, 180), 30), 900)))
  on conflict (id) do update set lease_expires_at = excluded.lease_expires_at;
  if p_operation_kind = 'youtube' then update private.music_import_runtime_config set last_youtube_start_at = now(), updated_at = now() where singleton; end if;
  return pg_catalog.jsonb_build_object('acquired', true, 'lease_id', p_owner_id);
end;
$$;

create or replace function public.worker_release_music_import_slot(p_owner_id uuid)
returns boolean
language sql
security definer
set search_path = ''
as $$
  with deleted as (delete from private.music_import_operation_leases where id = p_owner_id returning 1)
  select exists(select 1 from deleted)
$$;

revoke all on function public.worker_acquire_music_import_slot(text, uuid, uuid, text, integer) from public, anon, authenticated;
revoke all on function public.worker_release_music_import_slot(uuid) from public, anon, authenticated;
grant execute on function public.worker_acquire_music_import_slot(text, uuid, uuid, text, integer) to service_role;
grant execute on function public.worker_release_music_import_slot(uuid) to service_role;

create or replace function public.worker_read_music_import_messages(
  p_queue_name text,
  p_visibility_seconds integer default 300,
  p_quantity integer default 1
)
returns table (
  message_id bigint, read_count integer, enqueued_at timestamptz,
  visibility_until timestamptz, task_id uuid
)
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_queue_name not in ('music_import_control', 'music_import_tracks') then raise exception 'invalid_queue_name'; end if;
  return query
  select m.msg_id, m.read_ct, m.enqueued_at, m.vt, nullif(m.message->>'task_id', '')::uuid
    from pgmq.read(p_queue_name, least(greatest(coalesce(p_visibility_seconds, 300), 30), 1800), least(greatest(coalesce(p_quantity, 1), 1), 20)) m
   where (m.message->>'version')::integer = 1;
end;
$$;

create or replace function public.worker_defer_music_import_message(
  p_queue_name text, p_message_id bigint, p_task_id uuid,
  p_error_code text, p_error_message text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_task private.music_import_tasks%rowtype; v_delay integer; v_archived boolean := false;
begin
  if p_queue_name not in ('music_import_control', 'music_import_tracks') then raise exception 'invalid_queue_name'; end if;
  select * into v_task from private.music_import_tasks where id = p_task_id for update;
  if not found or v_task.queue_message_id is distinct from p_message_id then raise exception 'queue_task_mismatch'; end if;
  if v_task.attempt_count >= 3 then
    update private.music_import_tasks set status = 'dead_letter', error_code = p_error_code,
      error_message = left(p_error_message, 1000), finished_at = now(), updated_at = now() where id = p_task_id;
    v_archived := pgmq.archive(p_queue_name, p_message_id);
    return pg_catalog.jsonb_build_object('dead_letter', true, 'archived', v_archived);
  end if;
  v_delay := case v_task.attempt_count when 0 then 60 when 1 then 300 else 900 end;
  perform pgmq.set_vt(p_queue_name, p_message_id, v_delay);
  update private.music_import_tasks set status = 'queued', attempt_count = attempt_count + 1,
    next_attempt_at = now() + pg_catalog.make_interval(secs => v_delay),
    error_code = p_error_code, error_message = left(p_error_message, 1000),
    lease_owner = null, lease_expires_at = null, updated_at = now() where id = p_task_id;
  return pg_catalog.jsonb_build_object('dead_letter', false, 'delay_seconds', v_delay);
end;
$$;

create or replace function public.worker_complete_music_import_message(
  p_queue_name text, p_message_id bigint, p_task_id uuid,
  p_status text default 'succeeded', p_details jsonb default '{}'::jsonb
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare v_archived boolean; v_archived_at timestamptz;
begin
  if p_queue_name not in ('music_import_control', 'music_import_tracks') then raise exception 'invalid_queue_name'; end if;
  if p_status not in ('succeeded', 'skipped', 'cancelled') then raise exception 'invalid_terminal_status'; end if;
  update private.music_import_tasks
     set status = p_status, metadata = metadata || coalesce(p_details, '{}'::jsonb),
         finished_at = now(), lease_owner = null, lease_expires_at = null, updated_at = now()
   where id = p_task_id and queue_message_id = p_message_id;
  if not found then raise exception 'queue_task_mismatch'; end if;
  select queue_archived_at into v_archived_at from private.music_import_tasks where id = p_task_id;
  if v_archived_at is not null then return true; end if;
  v_archived := pgmq.archive(p_queue_name, p_message_id);
  return v_archived;
end;
$$;

revoke all on function public.worker_read_music_import_messages(text, integer, integer) from public, anon, authenticated;
revoke all on function public.worker_defer_music_import_message(text, bigint, uuid, text, text) from public, anon, authenticated;
revoke all on function public.worker_complete_music_import_message(text, bigint, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.worker_read_music_import_messages(text, integer, integer) to service_role;
grant execute on function public.worker_defer_music_import_message(text, bigint, uuid, text, text) to service_role;
grant execute on function public.worker_complete_music_import_message(text, bigint, uuid, text, jsonb) to service_role;

create or replace function public.admin_prepare_music_upload(
  p_item_id uuid,
  p_filename text,
  p_mime text,
  p_size_bytes bigint,
  p_rights_statement text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item public.playlist_request_tracks%rowtype;
  v_request public.playlist_requests%rowtype;
  v_playlist public.playlists%rowtype;
  v_admin public.admin_users%rowtype;
  v_session private.music_upload_sessions%rowtype;
  v_extension text;
begin
  select * into v_item from public.playlist_request_tracks where id = p_item_id;
  if not found then raise exception 'music_upload_item_not_found'; end if;
  select * into v_request from public.playlist_requests where id = v_item.playlist_request_id;
  select * into v_playlist from public.playlists where id = v_request.playlist_id;
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    v_playlist.unit_id
  );
  if v_request.status <> 'approved' then raise exception 'music_upload_request_not_approved'; end if;
  if p_size_bytes is null or p_size_bytes < 1 or p_size_bytes > 52428800 then raise exception 'music_upload_size_invalid'; end if;
  if lower(coalesce(p_mime, '')) not in (
    'audio/mpeg', 'audio/mp4', 'audio/x-m4a', 'audio/aac',
    'audio/ogg', 'audio/wav', 'audio/x-wav', 'audio/vnd.wave'
  ) then raise exception 'music_upload_mime_invalid'; end if;
  v_extension := lower(substring(coalesce(p_filename, '') from '\.([a-z0-9]+)$'));
  if v_extension not in ('mp3', 'm4a', 'aac', 'ogg', 'wav') then raise exception 'music_upload_extension_invalid'; end if;
  if length(btrim(coalesce(p_rights_statement, ''))) < 10 then raise exception 'music_upload_rights_required'; end if;

  insert into private.music_upload_sessions (
    playlist_id, playlist_request_id, request_item_id, admin_user_id,
    original_filename, declared_mime, declared_size_bytes,
    rights_attested, rights_statement, staging_object_key, expires_at
  ) values (
    v_playlist.id, v_request.id, v_item.id, v_admin.id,
    left(p_filename, 255), lower(p_mime), p_size_bytes,
    true, left(btrim(p_rights_statement), 1000),
    'music-uploads/staging/' || encode(gen_random_bytes(24), 'hex') || '.' || v_extension,
    now() + interval '15 minutes'
  ) returning * into v_session;

  insert into public.admin_audit_logs (admin_user_id, action, entity_type, entity_id, after_data)
  values (v_admin.id, 'music_upload_prepared', 'playlist_request_track', v_item.id,
    pg_catalog.jsonb_build_object('session_id', v_session.id, 'playlist_id', v_playlist.id,
      'filename', left(p_filename, 255), 'mime', lower(p_mime), 'size_bytes', p_size_bytes,
      'rights_statement', left(btrim(p_rights_statement), 1000)));

  return pg_catalog.jsonb_build_object(
    'session_id', v_session.id, 'staging_object_key', v_session.staging_object_key,
    'expires_at', v_session.expires_at, 'declared_mime', v_session.declared_mime,
    'declared_size_bytes', v_session.declared_size_bytes
  );
end;
$$;

create or replace function public.worker_complete_music_upload_session(
  p_session_id uuid,
  p_verified_size_bytes bigint,
  p_etag text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_session private.music_upload_sessions%rowtype; v_task_id uuid;
begin
  select * into v_session from private.music_upload_sessions where id = p_session_id for update;
  if not found then raise exception 'music_upload_session_not_found'; end if;
  if v_session.status <> 'prepared' or v_session.used_at is not null then raise exception 'music_upload_session_already_used'; end if;
  if v_session.expires_at <= now() then
    update private.music_upload_sessions set status = 'expired', used_at = now(), updated_at = now() where id = v_session.id;
    raise exception 'music_upload_session_expired';
  end if;
  if p_verified_size_bytes is null or p_verified_size_bytes <> v_session.declared_size_bytes or p_verified_size_bytes > 52428800 then raise exception 'music_upload_size_mismatch'; end if;

  insert into private.music_import_tasks (
    task_kind, source_kind, playlist_id, playlist_request_id, request_item_id,
    upload_session_id, status, metadata
  ) values (
    'upload', 'upload', v_session.playlist_id, v_session.playlist_request_id,
    v_session.request_item_id, v_session.id, 'queued',
    pg_catalog.jsonb_build_object('staging_object_key', v_session.staging_object_key)
  ) returning id into v_task_id;

  update private.music_upload_sessions
     set status = 'processing', used_at = now(), task_id = v_task_id,
         verified_size_bytes = p_verified_size_bytes, r2_etag = left(p_etag, 500), updated_at = now()
   where id = v_session.id;
  update public.playlist_request_tracks
     set item_status = 'processing', locked_at = now(), error_message = null,
         last_error_code = null, updated_at = now()
   where id = v_session.request_item_id;
  return pg_catalog.jsonb_build_object('task_id', v_task_id, 'status', 'queued');
end;
$$;

create or replace function public.admin_confirm_music_upload_session(p_session_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_session private.music_upload_sessions%rowtype; v_unit_id uuid;
begin
  select upload.* into v_session
    from private.music_upload_sessions upload
   where upload.id = p_session_id;
  if not found then raise exception 'music_upload_session_not_found'; end if;
  select playlist.unit_id into v_unit_id
    from public.playlists playlist
   where playlist.id = v_session.playlist_id;
  perform private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    v_unit_id
  );
  if v_session.status <> 'prepared' or v_session.used_at is not null then raise exception 'music_upload_session_already_used'; end if;
  if v_session.expires_at <= now() then raise exception 'music_upload_session_expired'; end if;
  return pg_catalog.jsonb_build_object(
    'session_id', v_session.id,
    'staging_object_key', v_session.staging_object_key,
    'declared_mime', v_session.declared_mime,
    'declared_size_bytes', v_session.declared_size_bytes,
    'expires_at', v_session.expires_at
  );
end;
$$;

create or replace function public.worker_get_music_upload_task(p_task_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'task_id', task.id, 'playlist_id', task.playlist_id,
    'playlist_request_id', task.playlist_request_id,
    'request_item_id', task.request_item_id,
    'session_id', upload.id, 'staging_object_key', upload.staging_object_key,
    'original_filename', upload.original_filename,
    'declared_mime', upload.declared_mime,
    'declared_size_bytes', upload.declared_size_bytes,
    'rights_statement', upload.rights_statement,
    'admin_user_id', upload.admin_user_id,
    'position', item.position,
    'title', item.title,
    'artists', item.artists,
    'duration_ms', item.duration_ms
  )
  from private.music_import_tasks task
  join private.music_upload_sessions upload on upload.id = task.upload_session_id
  join public.playlist_request_tracks item on item.id = task.request_item_id
  where task.id = p_task_id and task.task_kind = 'upload'
$$;

create or replace function public.worker_claim_music_upload_task(
  p_worker_id text,
  p_lease_seconds integer default 900
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_task_id uuid;
begin
  with candidate as (
    select task.id
      from private.music_import_tasks task
     where task.task_kind = 'upload'
       and task.status = 'queued'
       and task.next_attempt_at <= now()
       and (task.lease_expires_at is null or task.lease_expires_at <= now())
     order by task.next_attempt_at, task.created_at
     for update skip locked
     limit 1
  )
  update private.music_import_tasks task
     set status = 'processing', lease_owner = left(p_worker_id, 200),
         lease_expires_at = now() + pg_catalog.make_interval(secs => least(greatest(coalesce(p_lease_seconds, 900), 60), 1800)),
         started_at = coalesce(task.started_at, now()), updated_at = now()
    from candidate
   where task.id = candidate.id
  returning task.id into v_task_id;
  if v_task_id is null then return null; end if;
  return public.worker_get_music_upload_task(v_task_id);
end;
$$;

create or replace function public.worker_finish_music_upload_task(
  p_task_id uuid,
  p_success boolean,
  p_track_id uuid default null,
  p_content_sha256 text default null,
  p_error_code text default null,
  p_error_message text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task private.music_import_tasks%rowtype;
  v_session private.music_upload_sessions%rowtype;
  v_delay integer;
  v_terminal boolean;
begin
  select * into v_task from private.music_import_tasks where id = p_task_id and task_kind = 'upload' for update;
  if not found then raise exception 'music_upload_task_not_found'; end if;
  select * into v_session from private.music_upload_sessions where id = v_task.upload_session_id for update;
  if not found then raise exception 'music_upload_session_not_found'; end if;

  if p_success then
    if p_track_id is null or coalesce(p_content_sha256, '') !~ '^[a-f0-9]{64}$' then raise exception 'music_upload_result_invalid'; end if;
    update private.music_import_tasks
       set status = 'succeeded', finished_at = now(), lease_owner = null,
           lease_expires_at = null, error_code = null, error_message = null,
           metadata = metadata || pg_catalog.jsonb_build_object('track_id', p_track_id, 'content_sha256', p_content_sha256),
           updated_at = now()
     where id = v_task.id;
    update private.music_upload_sessions
       set status = 'completed', content_sha256 = p_content_sha256,
           final_track_id = p_track_id, error_code = null, error_message = null,
           updated_at = now()
     where id = v_session.id;
    update public.playlist_request_tracks
       set item_status = 'completed', track_id = p_track_id, locked_at = null,
           error_message = null, last_error_code = null,
           metadata = metadata || pg_catalog.jsonb_build_object(
             'remediation_source', 'admin_upload', 'upload_session_id', v_session.id,
             'content_sha256', p_content_sha256
           ), updated_at = now()
     where id = v_session.request_item_id;
    insert into public.admin_audit_logs (admin_user_id, action, entity_type, entity_id, after_data)
    values (v_session.admin_user_id, 'music_upload_completed', 'playlist_request_track', v_session.request_item_id,
      pg_catalog.jsonb_build_object('session_id', v_session.id, 'playlist_id', v_session.playlist_id,
        'track_id', p_track_id, 'content_sha256', p_content_sha256,
        'rights_statement', v_session.rights_statement));
    return pg_catalog.jsonb_build_object('success', true, 'terminal', true);
  end if;

  v_terminal := v_task.attempt_count + 1 >= 3;
  v_delay := case v_task.attempt_count when 0 then 60 when 1 then 300 else 900 end;
  update private.music_import_tasks
     set status = case when v_terminal then 'dead_letter' else 'queued' end,
         attempt_count = attempt_count + 1,
         next_attempt_at = now() + pg_catalog.make_interval(secs => v_delay),
         lease_owner = null, lease_expires_at = null,
         error_code = left(coalesce(p_error_code, 'MUSIC_UPLOAD_PROCESSING_FAILED'), 120),
         error_message = left(coalesce(p_error_message, 'Falha ao processar o áudio enviado.'), 1000),
         finished_at = case when v_terminal then now() else null end,
         updated_at = now()
   where id = v_task.id;
  update private.music_upload_sessions
     set status = case when v_terminal then 'failed' else 'processing' end,
         error_code = left(coalesce(p_error_code, 'MUSIC_UPLOAD_PROCESSING_FAILED'), 120),
         error_message = left(coalesce(p_error_message, 'Falha ao processar o áudio enviado.'), 1000),
         updated_at = now()
   where id = v_session.id;
  if v_terminal then
    update public.playlist_request_tracks
       set item_status = 'failed', locked_at = null,
           last_error_code = left(coalesce(p_error_code, 'MUSIC_UPLOAD_PROCESSING_FAILED'), 120),
           error_message = left(coalesce(p_error_message, 'Falha ao processar o áudio enviado.'), 1000),
           updated_at = now()
     where id = v_session.request_item_id;
  end if;
  return pg_catalog.jsonb_build_object('success', false, 'terminal', v_terminal, 'delay_seconds', v_delay);
end;
$$;

revoke all on function public.admin_prepare_music_upload(uuid, text, text, bigint, text) from public, anon;
revoke all on function public.admin_confirm_music_upload_session(uuid) from public, anon;
grant execute on function public.admin_prepare_music_upload(uuid, text, text, bigint, text) to authenticated;
grant execute on function public.admin_confirm_music_upload_session(uuid) to authenticated;
revoke all on function public.worker_complete_music_upload_session(uuid, bigint, text) from public, anon, authenticated;
revoke all on function public.worker_get_music_upload_task(uuid) from public, anon, authenticated;
revoke all on function public.worker_claim_music_upload_task(text, integer) from public, anon, authenticated;
revoke all on function public.worker_finish_music_upload_task(uuid, boolean, uuid, text, text, text) from public, anon, authenticated;
grant execute on function public.worker_complete_music_upload_session(uuid, bigint, text) to service_role;
grant execute on function public.worker_get_music_upload_task(uuid) to service_role;
grant execute on function public.worker_claim_music_upload_task(text, integer) to service_role;
grant execute on function public.worker_finish_music_upload_task(uuid, boolean, uuid, text, text, text) to service_role;

create or replace function public.admin_playlist_import_snapshot(p_playlist_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_playlist public.playlists%rowtype;
  v_request public.playlist_requests%rowtype;
  v_job public.download_jobs%rowtype;
  v_health private.music_provider_health%rowtype;
  v_summary jsonb;
  v_tasks jsonb;
  v_state text;
begin
  select * into v_playlist from public.playlists where id = p_playlist_id;
  if not found then return null; end if;
  perform private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager', 'auditor', 'support_readonly'],
    v_playlist.unit_id
  );
  select * into v_request from public.playlist_requests
   where playlist_id = p_playlist_id order by created_at desc, id desc limit 1;
  select * into v_job from public.download_jobs
   where playlist_id = p_playlist_id and coalesce(mode, 'playlist') = 'playlist'
   order by created_at desc, id desc limit 1;
  select * into v_health from private.music_provider_health where provider = 'youtube';

  select pg_catalog.jsonb_build_object(
    'total', count(*)::integer,
    'imported', count(*) filter (where item_status = 'completed')::integer,
    'failed', count(*) filter (where item_status = 'failed')::integer,
    'not_found', count(*) filter (where item_status = 'not_found')::integer,
    'review', count(*) filter (where item_status = 'review_recommended')::integer,
    'skipped', count(*) filter (where item_status in ('skipped', 'duplicate', 'duration_exceeded', 'playlist_limit_exceeded'))::integer,
    'active', count(*) filter (where item_status in ('pending', 'resolving', 'resolved', 'processing'))::integer
  ) into v_summary
  from public.playlist_request_tracks item
  where item.playlist_request_id = v_request.id
    and (v_job.id is null or item.download_job_id = v_job.id);

  select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
    'id', task.id, 'kind', task.task_kind, 'source', task.source_kind,
    'status', task.status, 'attempts', task.attempt_count,
    'deferrals', task.defer_count, 'next_attempt_at', task.next_attempt_at,
    'error_code', task.error_code, 'error_message', task.error_message,
    'request_item_id', task.request_item_id, 'updated_at', task.updated_at
  ) order by task.updated_at desc), '[]'::jsonb) into v_tasks
  from private.music_import_tasks task
  where task.playlist_id = p_playlist_id
    and (v_request.id is null or task.playlist_request_id = v_request.id);

  v_state := coalesce(v_job.operational_status,
    case v_job.status when 'running' then 'processing' when 'done' then 'completed'
      when 'partial' then 'completed_with_issues' when 'error' then 'failed' else 'queued' end);
  return pg_catalog.jsonb_build_object(
    'playlist_id', p_playlist_id, 'request_id', v_request.id, 'job_id', v_job.id,
    'state', v_state, 'legacy_status', v_job.status,
    'progress', pg_catalog.jsonb_build_object('completed', coalesce(v_job.completed, 0), 'total', coalesce(v_job.total, 0)),
    'summary', coalesce(v_summary, '{}'::jsonb), 'tasks', v_tasks,
    'provider', pg_catalog.jsonb_build_object(
      'name', v_health.provider, 'status', v_health.status,
      'error_code', v_health.error_code, 'message', v_health.error_message,
      'next_probe_at', v_health.next_probe_at, 'last_success_at', v_health.last_success_at
    ),
    'next_attempt_at', case when v_job.next_attempt_at = 'infinity'::timestamptz then null else v_job.next_attempt_at end,
    'defer_count', coalesce(v_job.provider_defer_count, 0),
    'first_deferred_at', v_job.provider_first_deferred_at,
    'deferred_seconds', coalesce(v_job.provider_deferred_seconds, 0),
    'permissions', pg_catalog.jsonb_build_object(
      'can_retry', v_playlist.approval_status = 'approved' and v_health.status = 'healthy' and coalesce(v_job.status, '') <> 'running',
      'can_upload', v_playlist.approval_status = 'approved'
    )
  );
end;
$$;

create or replace function public.admin_playlist_import_snapshots(p_playlist_ids uuid[])
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(pg_catalog.jsonb_agg(public.admin_playlist_import_snapshot(requested.id)), '[]'::jsonb)
  from (
    select distinct id
    from pg_catalog.unnest(coalesce(p_playlist_ids, '{}'::uuid[])) as requested_id(id)
    limit 100
  ) requested
$$;

alter function public.admin_playlist_request_detail(uuid)
  rename to admin_playlist_request_detail_pre_resilient_impl;

create function public.admin_playlist_request_detail(p_playlist_id uuid)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_detail jsonb; v_snapshot jsonb;
begin
  v_snapshot := public.admin_playlist_import_snapshot(p_playlist_id);
  if v_snapshot is null then return null; end if;
  v_detail := public.admin_playlist_request_detail_pre_resilient_impl(p_playlist_id);
  if v_detail is null then return pg_catalog.jsonb_build_object('operational', v_snapshot); end if;
  return pg_catalog.jsonb_set(v_detail, '{operational}', v_snapshot, true);
end;
$$;

revoke all on function public.admin_playlist_import_snapshot(uuid) from public, anon;
revoke all on function public.admin_playlist_import_snapshots(uuid[]) from public, anon;
revoke all on function public.admin_playlist_request_detail(uuid) from public, anon;
grant execute on function public.admin_playlist_import_snapshot(uuid) to authenticated;
grant execute on function public.admin_playlist_import_snapshots(uuid[]) to authenticated;
grant execute on function public.admin_playlist_request_detail(uuid) to authenticated;

alter function public.admin_retry_playlist_import(uuid)
  rename to admin_retry_playlist_import_pre_resilient_impl;

create function public.admin_retry_playlist_import(p_playlist uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare v_health text;
begin
  select status into v_health from private.music_provider_health where provider = 'youtube';
  if v_health <> 'healthy' then raise exception 'youtube_provider_unavailable'; end if;
  perform public.admin_retry_playlist_import_pre_resilient_impl(p_playlist);
end;
$$;

revoke all on function public.admin_retry_playlist_import(uuid) from public, anon;
grant execute on function public.admin_retry_playlist_import(uuid) to authenticated;

create or replace function public.admin_resume_music_provider(p_provider text default 'youtube')
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_admin public.admin_users%rowtype;
begin
  if p_provider <> 'youtube' then raise exception 'unsupported_provider'; end if;
  v_admin := private.require_admin_for_backend(array['superadmin', 'operations_manager', 'content_manager'], null);
  update private.music_provider_health set status = 'degraded', next_probe_at = now(), probe_lease_until = null, updated_at = now() where provider = p_provider;
  insert into public.admin_audit_logs (admin_user_id, action, entity_type, after_data)
  values (v_admin.id, 'music_provider_probe_requested', 'music_provider', pg_catalog.jsonb_build_object('provider', p_provider));
  return pg_catalog.jsonb_build_object('provider', p_provider, 'probe_requested', true);
end;
$$;

create or replace function public.admin_set_music_import_backend(p_backend text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_admin public.admin_users%rowtype; v_enqueued integer := 0; v_task_id uuid;
begin
  if p_backend not in ('legacy', 'shadow', 'pgmq') then raise exception 'invalid_music_import_backend'; end if;
  v_admin := private.require_admin_for_backend(array['superadmin'], null);
  update private.music_import_runtime_config set backend = p_backend, updated_at = now(), updated_by_admin_id = v_admin.id where singleton;
  if p_backend in ('shadow', 'pgmq') then
    for v_task_id in select id from private.music_import_tasks where status = 'queued' and queue_message_id is null order by created_at
    loop
      if private.music_import_enqueue_task_message(v_task_id) is not null then v_enqueued := v_enqueued + 1; end if;
    end loop;
  end if;
  insert into public.admin_audit_logs (admin_user_id, action, entity_type, after_data)
  values (v_admin.id, 'music_import_backend_changed', 'music_import_runtime_config', pg_catalog.jsonb_build_object('backend', p_backend, 'enqueued', v_enqueued));
  return pg_catalog.jsonb_build_object('backend', p_backend, 'enqueued', v_enqueued);
end;
$$;

revoke all on function public.admin_resume_music_provider(text) from public, anon;
revoke all on function public.admin_set_music_import_backend(text) from public, anon;
grant execute on function public.admin_resume_music_provider(text) to authenticated;
grant execute on function public.admin_set_music_import_backend(text) to authenticated;

create or replace function public.admin_music_import_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare v_control record; v_tracks record; v_health private.music_provider_health%rowtype; v_config private.music_import_runtime_config%rowtype;
begin
  perform private.require_admin_for_backend(array['superadmin', 'unit_manager', 'operations_manager', 'content_manager', 'auditor', 'support_readonly'], null);
  select * into v_control from pgmq.metrics('music_import_control');
  select * into v_tracks from pgmq.metrics('music_import_tracks');
  select * into v_health from private.music_provider_health where provider = 'youtube';
  select * into v_config from private.music_import_runtime_config where singleton;
  return pg_catalog.jsonb_build_object(
    'backend', v_config.backend,
    'limits', pg_catalog.jsonb_build_object(
      'active_playlists', v_config.max_active_playlists,
      'tracks_per_playlist', v_config.max_tracks_per_playlist,
      'youtube_global', v_config.max_youtube_operations,
      'uploads_global', v_config.max_upload_operations,
      'youtube_spacing_seconds', v_config.youtube_start_spacing_seconds,
      'worker_replica_target', v_config.worker_replica_target
    ),
    'queues', pg_catalog.jsonb_build_object(
      'control', pg_catalog.to_jsonb(v_control), 'tracks', pg_catalog.to_jsonb(v_tracks)
    ),
    'tasks', pg_catalog.jsonb_build_object(
      'queued', (select count(*) from private.music_import_tasks where status = 'queued'),
      'processing', (select count(*) from private.music_import_tasks where status = 'processing'),
      'waiting_provider', (select count(*) from private.music_import_tasks where status = 'waiting_provider'),
      'waiting_review', (select count(*) from private.music_import_tasks where status = 'waiting_review'),
      'dead_letter', (select count(*) from private.music_import_tasks where status = 'dead_letter')
    ),
    'active_playlists', (select count(distinct playlist_id) from private.music_import_tasks where status = 'processing'),
    'provider', pg_catalog.to_jsonb(v_health),
    'generated_at', now()
  );
end;
$$;

revoke all on function public.admin_music_import_health() from public, anon;
grant execute on function public.admin_music_import_health() to authenticated;

comment on table private.music_import_tasks is 'Fonte autoritativa por unidade de trabalho; download_jobs permanece projeção compatível.';
comment on table private.music_import_events is 'Histórico append-only das transições do importador.';
comment on table private.music_provider_health is 'Circuit breaker compartilhado por todas as réplicas.';
comment on table private.music_upload_sessions is 'Sessões curtas, aleatórias e de uso único para upload administrativo autorizado.';
comment on column public.download_jobs.operational_status is 'Estado detalhado do importador; status legado continua compatível com o App.';

commit;
