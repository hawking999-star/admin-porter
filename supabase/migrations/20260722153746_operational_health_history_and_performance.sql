-- Operational heartbeat, health dashboard, contextual history, and targeted
-- indexes for the Admin PTM. Heartbeats live in the private schema and are
-- exposed only through role-checked RPCs.

create table if not exists private.service_heartbeats (
  service_name text primary key,
  status text not null check (status in ('starting', 'idle', 'working', 'degraded', 'stopping')),
  started_at timestamptz not null default clock_timestamp(),
  last_seen_at timestamptz not null default clock_timestamp(),
  details jsonb not null default '{}'::jsonb,
  updated_at timestamptz not null default clock_timestamp()
);

revoke all on table private.service_heartbeats from public, anon, authenticated;

create or replace function public.worker_record_service_heartbeat(
  p_service_name text,
  p_status text,
  p_details jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_service_name text := btrim(coalesce(p_service_name, ''));
  v_status text := lower(btrim(coalesce(p_status, '')));
begin
  if v_service_name = '' or char_length(v_service_name) > 80 then
    raise exception using errcode = '22023', message = 'WORKER_HEARTBEAT_SERVICE_INVALID';
  end if;
  if v_status not in ('starting', 'idle', 'working', 'degraded', 'stopping') then
    raise exception using errcode = '22023', message = 'WORKER_HEARTBEAT_STATUS_INVALID';
  end if;
  if jsonb_typeof(coalesce(p_details, '{}'::jsonb)) <> 'object' then
    raise exception using errcode = '22023', message = 'WORKER_HEARTBEAT_DETAILS_INVALID';
  end if;

  insert into private.service_heartbeats (
    service_name,
    status,
    started_at,
    last_seen_at,
    details,
    updated_at
  ) values (
    v_service_name,
    v_status,
    clock_timestamp(),
    clock_timestamp(),
    coalesce(p_details, '{}'::jsonb),
    clock_timestamp()
  )
  on conflict (service_name) do update
  set status = excluded.status,
      last_seen_at = excluded.last_seen_at,
      details = excluded.details,
      updated_at = excluded.updated_at;
end;
$$;

revoke all on function public.worker_record_service_heartbeat(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.worker_record_service_heartbeat(text, text, jsonb) to service_role;

create or replace function public.admin_overview_counts(
  p_statistics_since timestamptz default null,
  p_unit_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_today timestamptz := date_trunc('day', clock_timestamp() at time zone 'America/Sao_Paulo') at time zone 'America/Sao_Paulo';
  v_ended_since timestamptz;
begin
  v_admin := private.require_admin_for_backend(
    array[
      'superadmin', 'unit_manager', 'operations_manager', 'content_manager',
      'challenge_manager', 'release_manager', 'auditor', 'support_readonly'
    ],
    null
  );
  v_ended_since := greatest(coalesce(p_statistics_since, v_today), v_today);

  return jsonb_build_object(
    'operators', (
      select count(*) from public.operators operator_row
      where operator_row.active = true
        and (p_unit_id is null or operator_row.unit_id = p_unit_id)
    ),
    'operatorsOnline', (
      select count(*)
      from public.operator_states state_row
      join public.operators operator_row on operator_row.id = state_row.operator_id
      where state_row.status = 'active'
        and (p_unit_id is null or operator_row.unit_id = p_unit_id)
    ),
    'activeSessions', (
      select count(*) from public.operator_sessions session_row
      where session_row.status = 'active'
        and (p_unit_id is null or session_row.unit_id = p_unit_id)
    ),
    'sessionsEndedToday', (
      select count(*) from public.operator_sessions session_row
      where session_row.status = 'ended'
        and session_row.ended_at >= v_ended_since
        and (p_unit_id is null or session_row.unit_id = p_unit_id)
    ),
    'pendingFeedback', (
      select count(*) from public.feedback feedback_row
      where feedback_row.status = 'new'
        and (p_unit_id is null or feedback_row.unit_id = p_unit_id)
    ),
    'pendingPlaylists', (
      select count(*) from public.playlists playlist_row
      where playlist_row.approval_status = 'pending'
        and (p_unit_id is null or playlist_row.unit_id = p_unit_id)
    )
  );
end;
$$;

revoke all on function public.admin_overview_counts(timestamptz, uuid) from public, anon;
grant execute on function public.admin_overview_counts(timestamptz, uuid) to authenticated;

create or replace function public.admin_integration_status()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_heartbeat private.service_heartbeats%rowtype;
  v_worker_age_seconds integer;
  v_import_queued integer;
  v_import_running integer;
  v_import_errors integer;
  v_import_last_activity timestamptz;
  v_oldest_queued timestamptz;
begin
  v_admin := private.require_admin_for_backend(
    array[
      'superadmin', 'unit_manager', 'operations_manager', 'content_manager',
      'challenge_manager', 'release_manager', 'auditor', 'support_readonly'
    ],
    null
  );

  select * into v_heartbeat
  from private.service_heartbeats
  where service_name = 'railway-worker';

  v_worker_age_seconds := case
    when v_heartbeat.last_seen_at is null then null
    else greatest(0, extract(epoch from (clock_timestamp() - v_heartbeat.last_seen_at))::integer)
  end;

  select
    count(*) filter (where status = 'queued')::integer,
    count(*) filter (where status = 'running')::integer,
    max(updated_at),
    min(created_at) filter (where status = 'queued')
  into v_import_queued, v_import_running, v_import_last_activity, v_oldest_queued
  from public.download_jobs;

  select count(*)::integer
  into v_import_errors
  from (
    select distinct on (j.playlist_id)
      j.playlist_id,
      coalesce(j.last_error_at, j.updated_at, j.created_at) as error_at
    from public.download_jobs j
    where j.status in ('partial', 'error')
    order by j.playlist_id, coalesce(j.last_error_at, j.updated_at, j.created_at) desc
  ) latest_error_job
  join public.playlists playlist_row on playlist_row.id = latest_error_job.playlist_id
  where playlist_row.import_error_acknowledged_at is null
     or latest_error_job.error_at > playlist_row.import_error_acknowledged_at;

  return jsonb_build_object(
    'database_connected', true,
    'generated_at', clock_timestamp(),
    'worker', jsonb_build_object(
      'state', case
        when v_heartbeat.last_seen_at is null or v_worker_age_seconds > 90 then 'offline'
        when v_heartbeat.status = 'degraded' then 'degraded'
        else 'healthy'
      end,
      'status', v_heartbeat.status,
      'last_seen_at', v_heartbeat.last_seen_at,
      'age_seconds', v_worker_age_seconds,
      'started_at', v_heartbeat.started_at,
      'details', coalesce(v_heartbeat.details, '{}'::jsonb)
    ),
    'r2', jsonb_build_object(
      'state', case
        when v_heartbeat.last_seen_at is null or v_worker_age_seconds > 90 then 'unknown'
        when coalesce(v_heartbeat.details->>'r2_status', 'unknown') = 'healthy' then 'healthy'
        when coalesce(v_heartbeat.details->>'r2_status', 'unknown') = 'degraded' then 'degraded'
        else 'unknown'
      end,
      'last_checked_at', v_heartbeat.details->>'r2_checked_at',
      'message', v_heartbeat.details->>'r2_message'
    ),
    'imports', jsonb_build_object(
      'state', case
        when v_import_errors > 0 then 'degraded'
        when v_import_queued > 0
             and coalesce(v_import_last_activity, '-infinity'::timestamptz) < clock_timestamp() - interval '15 minutes'
          then 'stalled'
        else 'healthy'
      end,
      'queued', v_import_queued,
      'running', v_import_running,
      'completed', (select count(*) from public.download_jobs where status = 'done'),
      'with_errors', v_import_errors,
      'oldest_queued_at', v_oldest_queued,
      'last_activity_at', v_import_last_activity
    ),
    'storage_cleanup', jsonb_build_object(
      'queued', (select count(*) from public.storage_deletion_jobs where status = 'queued'),
      'running', (select count(*) from public.storage_deletion_jobs where status = 'running'),
      'with_errors', (select count(*) from public.storage_deletion_jobs where status = 'error'),
      'last_activity_at', (select max(updated_at) from public.storage_deletion_jobs)
    )
  );
end;
$$;

revoke all on function public.admin_integration_status() from public, anon;
grant execute on function public.admin_integration_status() to authenticated;

create or replace function public.admin_entity_history(
  p_entity_id uuid,
  p_entity_types text[] default null,
  p_limit integer default 30
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 100);
begin
  v_admin := private.require_admin_for_backend(
    array[
      'superadmin', 'unit_manager', 'operations_manager', 'content_manager',
      'challenge_manager', 'release_manager', 'auditor', 'support_readonly'
    ],
    null
  );

  if p_entity_id is null then
    raise exception using errcode = '22023', message = 'ADMIN_HISTORY_ENTITY_REQUIRED';
  end if;

  return (
    select coalesce(jsonb_agg(to_jsonb(history_row) order by history_row.occurred_at desc), '[]'::jsonb)
    from (
      select
        audit.id,
        audit.action,
        audit.entity_type,
        audit.entity_id,
        audit.reason,
        audit.before_data,
        audit.after_data,
        audit.occurred_at,
        coalesce(admin_row.display_name, 'Sistema') as admin_name
      from public.admin_audit_logs audit
      left join public.admin_users admin_row on admin_row.id = audit.admin_user_id
      where audit.entity_id = p_entity_id
        and (
          coalesce(cardinality(p_entity_types), 0) = 0
          or audit.entity_type = any(p_entity_types)
        )
      order by audit.occurred_at desc
      limit v_limit
    ) history_row
  );
end;
$$;

revoke all on function public.admin_entity_history(uuid, text[], integer) from public, anon;
grant execute on function public.admin_entity_history(uuid, text[], integer) to authenticated;

create index if not exists admin_audit_logs_entity_id_occurred_at_idx
  on public.admin_audit_logs (entity_id, occurred_at desc)
  where entity_id is not null;

drop index if exists public.challenges_unit_status_idx;

notify pgrst, 'reload schema';
