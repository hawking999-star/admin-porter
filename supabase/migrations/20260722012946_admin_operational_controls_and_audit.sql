-- Operational controls requested in the Admin panel:
--   * category-aware, non-destructive statistics reset;
--   * safe completion/retry visibility for R2 deletion jobs;
--   * read-only access hardening for the administrative audit trail.

create or replace function private.statistics_reset_category_at(p_category text)
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    nullif(value->'categories'->>p_category, '')::timestamptz,
    nullif(value->>'reset_at', '')::timestamptz
  )
  from public.system_settings
  where key = 'statistics_reset'
    and scope_type = 'global'
    and scope_id is null
    and active = true
  order by revision desc, created_at desc
  limit 1
$$;

create or replace function public.admin_statistics_reset_info()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin_for_backend(null, null);

  return jsonb_build_object(
    'reset_at', private.statistics_reset_at(),
    'resets', jsonb_build_object(
      'sessions', private.statistics_reset_category_at('sessions'),
      'calls', private.statistics_reset_category_at('calls'),
      'challenges', private.statistics_reset_category_at('challenges'),
      'attention', private.statistics_reset_category_at('attention')
    )
  );
end;
$$;

create or replace function public.admin_reset_statistics(p_categories text[])
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_now timestamptz := clock_timestamp();
  v_before jsonb;
  v_after jsonb;
  v_categories jsonb;
  v_selected text[];
  v_category text;
  v_revision bigint;
  v_all_categories constant text[] := array['sessions', 'calls', 'challenges', 'attention'];
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  select coalesce(array_agg(distinct lower(btrim(category))), array[]::text[])
    into v_selected
  from unnest(coalesce(p_categories, array[]::text[])) category
  where nullif(btrim(category), '') is not null;

  if cardinality(v_selected) = 0 then
    raise exception using errcode = '22023', message = 'STATISTICS_RESET_CATEGORY_REQUIRED';
  end if;

  if exists (
    select 1 from unnest(v_selected) category
    where not (category = any(v_all_categories))
  ) then
    raise exception using errcode = '22023', message = 'STATISTICS_RESET_CATEGORY_INVALID';
  end if;

  select value, revision
    into v_before, v_revision
  from public.system_settings
  where key = 'statistics_reset'
    and scope_type = 'global'
    and scope_id is null
    and active = true
  order by revision desc, created_at desc
  limit 1
  for update;

  v_before := coalesce(v_before, '{}'::jsonb);
  v_categories := coalesce(v_before->'categories', '{}'::jsonb);

  foreach v_category in array v_selected loop
    v_categories := jsonb_set(v_categories, array[v_category], to_jsonb(v_now), true);
  end loop;

  v_after := jsonb_build_object(
    'reset_at', case
      when v_selected @> v_all_categories then to_jsonb(v_now)
      else coalesce(v_before->'reset_at', 'null'::jsonb)
    end,
    'categories', v_categories
  );

  update public.system_settings
  set active = false,
      updated_at = v_now
  where key = 'statistics_reset'
    and scope_type = 'global'
    and scope_id is null
    and active = true;

  insert into public.system_settings (
    scope_type, scope_id, key, value, revision, active, created_at, updated_at
  ) values (
    'global', null, 'statistics_reset', v_after,
    coalesce(v_revision, 0) + 1, true, v_now, v_now
  );

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    'statistics_reset_selective',
    'analytics',
    v_before,
    jsonb_build_object('categories', to_jsonb(v_selected), 'settings', v_after),
    v_now
  );

  return jsonb_build_object(
    'reset_at', nullif(v_after->>'reset_at', '')::timestamptz,
    'resets', v_categories,
    'categories', to_jsonb(v_selected)
  );
end;
$$;

create or replace function public.admin_reset_statistics()
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select public.admin_reset_statistics(array['sessions', 'calls', 'challenges', 'attention'])
$$;

create or replace function public.admin_music_storage_overview()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  perform private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  select jsonb_build_object(
    'total_tracks', count(*),
    'linked_tracks', count(*) filter (
      where exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
    ),
    'orphaned_tracks', count(*) filter (
      where t.status = 'available'
        and not exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
    ),
    'queued_deletions', (
      select count(*) from public.storage_deletion_jobs j where j.status in ('queued', 'running', 'error')
    ),
    'failed_deletions', (
      select count(*) from public.storage_deletion_jobs j where j.status = 'error'
    ),
    'measured_tracks', count(*) filter (
      where coalesce(t.metadata->>'size_bytes', '') ~ '^[0-9]+$'
    ),
    'used_bytes', coalesce(sum(
      case
        when coalesce(t.metadata->>'size_bytes', '') ~ '^[0-9]+$'
          then (t.metadata->>'size_bytes')::bigint
        else 0
      end
    ), 0),
    'last_measured_at', max(nullif(t.metadata->>'storage_checked_at', '')::timestamptz)
  ) into v_result
  from public.tracks t;

  return v_result;
end;
$$;

create or replace function public.complete_storage_deletion_job(
  p_job_id uuid,
  p_success boolean,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.storage_deletion_jobs%rowtype;
  v_playlist_refs integer;
  v_history_refs integer;
begin
  select * into v_job
  from public.storage_deletion_jobs
  where id = p_job_id
  for update;

  if not found then
    return jsonb_build_object('success', false, 'code', 'JOB_NOT_FOUND');
  end if;

  if not p_success then
    update public.storage_deletion_jobs
       set status = 'error',
           last_error = left(coalesce(p_error, 'Falha ao excluir objeto.'), 2000),
           next_attempt_at = now() + make_interval(secs => least(3600, 30 * (2 ^ least(attempts, 6))::int)),
           locked_at = null,
           updated_at = now()
     where id = v_job.id;

    return jsonb_build_object('success', false, 'code', 'STORAGE_DELETE_RETRY_QUEUED');
  end if;

  select count(*) into v_playlist_refs
  from public.playlist_tracks
  where track_id = v_job.track_id;

  if v_playlist_refs > 0 then
    update public.storage_deletion_jobs
       set status = 'cancelled', locked_at = null, updated_at = now()
     where id = v_job.id;
    update public.tracks
       set status = 'available', revision = revision + 1, updated_at = now()
     where id = v_job.track_id;
    return jsonb_build_object(
      'success', false,
      'code', 'TRACK_STILL_REFERENCED',
      'reference_count', v_playlist_refs
    );
  end if;

  select count(*) into v_history_refs
  from public.playlist_request_tracks
  where track_id = v_job.track_id;

  delete from public.storage_deletion_jobs where id = v_job.id;

  if v_history_refs > 0 then
    update public.tracks
       set status = 'deleted',
           metadata = (coalesce(metadata, '{}'::jsonb) - 'public_url' - 'size_bytes') || jsonb_build_object(
             'storage_deleted_at', now(),
             'storage_deleted_key', v_job.storage_object_key
           ),
           revision = revision + 1,
           updated_at = now()
     where id = v_job.track_id;

    return jsonb_build_object(
      'success', true,
      'code', 'OBJECT_DELETED_HISTORY_PRESERVED',
      'history_reference_count', v_history_refs
    );
  end if;

  delete from public.tracks
  where id = v_job.track_id
    and not exists (
      select 1 from public.playlist_tracks where track_id = v_job.track_id
    )
    and not exists (
      select 1 from public.playlist_request_tracks where track_id = v_job.track_id
    );

  return jsonb_build_object('success', true, 'code', 'TRACK_AND_OBJECT_DELETED');
end;
$$;

create or replace function public.admin_list_storage_deletion_jobs(p_limit integer default 50)
returns table(
  id uuid,
  track_id uuid,
  title text,
  artist text,
  storage_object_key text,
  status text,
  attempts integer,
  last_error text,
  next_attempt_at timestamptz,
  created_at timestamptz,
  updated_at timestamptz
)
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  return query
  select
    j.id, j.track_id, t.title, t.artist, j.storage_object_key,
    j.status, j.attempts, j.last_error, j.next_attempt_at, j.created_at, j.updated_at
  from public.storage_deletion_jobs j
  join public.tracks t on t.id = j.track_id
  where j.status in ('queued', 'running', 'error')
  order by
    case j.status when 'error' then 0 when 'running' then 1 else 2 end,
    j.updated_at asc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$$;

create or replace function public.admin_retry_storage_deletion_jobs()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_requeued integer;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  update public.storage_deletion_jobs
     set status = 'queued',
         next_attempt_at = now(),
         locked_at = null,
         last_error = null,
         updated_at = now()
   where status = 'error';
  get diagnostics v_requeued = row_count;

  if v_requeued > 0 then
    insert into public.admin_audit_logs (
      admin_user_id, action, entity_type, after_data, occurred_at
    ) values (
      v_admin.id,
      'storage_deletion_jobs_requeued',
      'music_storage',
      jsonb_build_object('requeued', v_requeued),
      now()
    );
  end if;

  return jsonb_build_object('requeued', v_requeued);
end;
$$;

drop policy if exists admin_insert on public.admin_audit_logs;
revoke all on table public.admin_audit_logs from anon;
revoke insert, update, delete, truncate, references, trigger on table public.admin_audit_logs from authenticated;
grant select on table public.admin_audit_logs to authenticated;

revoke all on function private.statistics_reset_category_at(text) from public, anon, authenticated;
revoke all on function public.admin_statistics_reset_info() from public, anon;
revoke all on function public.admin_reset_statistics() from public, anon;
revoke all on function public.admin_reset_statistics(text[]) from public, anon;
revoke all on function public.admin_music_storage_overview() from public, anon;
revoke all on function public.complete_storage_deletion_job(uuid, boolean, text) from public, anon, authenticated;
revoke all on function public.admin_list_storage_deletion_jobs(integer) from public, anon;
revoke all on function public.admin_retry_storage_deletion_jobs() from public, anon;

grant execute on function public.admin_statistics_reset_info() to authenticated;
grant execute on function public.admin_reset_statistics() to authenticated;
grant execute on function public.admin_reset_statistics(text[]) to authenticated;
grant execute on function public.admin_music_storage_overview() to authenticated;
grant execute on function public.complete_storage_deletion_job(uuid, boolean, text) to service_role;
grant execute on function public.admin_list_storage_deletion_jobs(integer) to authenticated;
grant execute on function public.admin_retry_storage_deletion_jobs() to authenticated;
