begin;

-- REVIEW_RECOMMENDED is an actionable music-match review, not an importer
-- failure. It remains visible in the music review workflow and must not keep
-- the operational integration queue degraded after all downloads succeeded.
create or replace function public.admin_list_pending_import_errors(
  p_limit integer default 100
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 100);
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  return (
    with latest_error_job as (
      select distinct on (j.playlist_id)
        j.playlist_id,
        j.error,
        j.error_code,
        j.error_message,
        j.error_details,
        coalesce(j.last_error_at, j.updated_at, j.created_at) as error_at
      from public.download_jobs j
      where j.status in ('partial', 'error')
      order by
        j.playlist_id,
        coalesce(j.last_error_at, j.updated_at, j.created_at) desc
    ), pending_errors as (
      select
        j.*,
        p.name as playlist_name,
        p.type as playlist_type,
        p.approval_status,
        p.source_url,
        o.display_name as operator_name,
        u.name as unit_name
      from latest_error_job j
      join public.playlists p on p.id = j.playlist_id
      left join public.operators o on o.id = p.created_by_operator_id
      left join public.units u on u.id = p.unit_id
      where j.error_code is distinct from 'REVIEW_RECOMMENDED'
        and (
          p.import_error_acknowledged_at is null
          or j.error_at > p.import_error_acknowledged_at
        )
      order by j.error_at desc
      limit v_limit
    )
    select coalesce(
      jsonb_agg(
        jsonb_build_object(
          'playlist_id', playlist_id,
          'playlist_name', playlist_name,
          'playlist_type', playlist_type,
          'approval_status', approval_status,
          'source_url', source_url,
          'operator_name', operator_name,
          'unit_name', unit_name,
          'error_code', error_code,
          'error_message', coalesce(error_message, error),
          'error_details', error_details,
          'last_error_at', error_at
        )
      ),
      '[]'::jsonb
    )
    from pending_errors
  );
end
$$;

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
    else greatest(
      0,
      extract(epoch from (clock_timestamp() - v_heartbeat.last_seen_at))::integer
    )
  end;

  select
    count(*) filter (where status = 'queued')::integer,
    count(*) filter (where status = 'running')::integer,
    max(updated_at),
    min(created_at) filter (where status = 'queued')
  into
    v_import_queued,
    v_import_running,
    v_import_last_activity,
    v_oldest_queued
  from public.download_jobs;

  select count(*)::integer
  into v_import_errors
  from (
    select distinct on (j.playlist_id)
      j.playlist_id,
      j.error_code,
      coalesce(j.last_error_at, j.updated_at, j.created_at) as error_at
    from public.download_jobs j
    where j.status in ('partial', 'error')
    order by
      j.playlist_id,
      coalesce(j.last_error_at, j.updated_at, j.created_at) desc
  ) latest_error_job
  join public.playlists playlist_row
    on playlist_row.id = latest_error_job.playlist_id
  where latest_error_job.error_code is distinct from 'REVIEW_RECOMMENDED'
    and (
      playlist_row.import_error_acknowledged_at is null
      or latest_error_job.error_at > playlist_row.import_error_acknowledged_at
    );

  return jsonb_build_object(
    'database_connected', true,
    'generated_at', clock_timestamp(),
    'worker', jsonb_build_object(
      'state', case
        when v_heartbeat.last_seen_at is null or v_worker_age_seconds > 90
          then 'offline'
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
        when v_heartbeat.last_seen_at is null or v_worker_age_seconds > 90
          then 'unknown'
        when coalesce(v_heartbeat.details->>'r2_status', 'unknown') = 'healthy'
          then 'healthy'
        when coalesce(v_heartbeat.details->>'r2_status', 'unknown') = 'degraded'
          then 'degraded'
        else 'unknown'
      end,
      'last_checked_at', v_heartbeat.details->>'r2_checked_at',
      'message', v_heartbeat.details->>'r2_message'
    ),
    'imports', jsonb_build_object(
      'state', case
        when v_import_errors > 0 then 'degraded'
        when v_import_queued > 0
          and coalesce(v_import_last_activity, '-infinity'::timestamptz)
            < clock_timestamp() - interval '15 minutes'
          then 'stalled'
        else 'healthy'
      end,
      'queued', v_import_queued,
      'running', v_import_running,
      'completed', (
        select count(*) from public.download_jobs where status = 'done'
      ),
      'with_errors', v_import_errors,
      'oldest_queued_at', v_oldest_queued,
      'last_activity_at', v_import_last_activity
    ),
    'storage_cleanup', jsonb_build_object(
      'queued', (
        select count(*)
        from public.storage_deletion_jobs
        where status = 'queued'
      ),
      'running', (
        select count(*)
        from public.storage_deletion_jobs
        where status = 'running'
      ),
      'with_errors', (
        select count(*)
        from public.storage_deletion_jobs
        where status = 'error'
      ),
      'last_activity_at', (
        select max(updated_at) from public.storage_deletion_jobs
      )
    )
  );
end
$$;

revoke all on function public.admin_list_pending_import_errors(integer)
  from public, anon;
grant execute on function public.admin_list_pending_import_errors(integer)
  to authenticated;

revoke all on function public.admin_integration_status()
  from public, anon;
grant execute on function public.admin_integration_status()
  to authenticated;

commit;
