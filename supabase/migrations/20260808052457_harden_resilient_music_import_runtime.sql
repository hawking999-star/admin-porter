begin;

-- Keep imported and processed counts separate. A duplicate is terminal and must
-- advance 23/28 progress, but it must never be reported as a newly imported song.
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
  v_processed integer;
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
  v_processed := v_imported + v_failed + v_not_found + v_skipped;
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
             'total', v_total, 'processed', v_processed, 'imported', v_imported,
             'failed', v_failed, 'not_found', v_not_found, 'review', v_review,
             'skipped', v_skipped, 'active', v_active
           ),
           'effective_items', v_effective_items
         ),
         updated_at = now()
   where id = v_job.id;
end;
$$;

-- A closed search_path is intentional; crypto helpers therefore need their
-- real extension schema.
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
    'music-uploads/staging/' || pg_catalog.encode(extensions.gen_random_bytes(24), 'hex') || '.' || v_extension,
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
         error_details = coalesce(v_job.error_details, '{}'::jsonb)
           || coalesce(p_error_details, '{}'::jsonb)
           || pg_catalog.jsonb_build_object(
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
    'processed', count(*) filter (where item_status in (
      'completed', 'failed', 'not_found', 'skipped', 'duplicate',
      'duration_exceeded', 'playlist_limit_exceeded'
    ))::integer,
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
    'progress', pg_catalog.jsonb_build_object(
      'completed', coalesce((v_summary->>'imported')::integer, 0),
      'processed', coalesce((v_summary->>'processed')::integer, 0),
      'total', coalesce((v_summary->>'total')::integer, v_job.total, 0)
    ),
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

-- Contain every currently hot invalid-cookie job before the new worker is
-- deployed. No identifiers are hardcoded and already terminal items stay put.
do $$
begin
  if exists (
    select 1 from public.download_jobs
     where coalesce(mode, 'playlist') = 'playlist'
       and status in ('queued', 'running')
       and error_code = 'YOUTUBE_COOKIES_INVALID'
  ) then
    update private.music_provider_health
       set status = 'blocked',
           consecutive_failures = greatest(consecutive_failures, 3),
           first_failure_at = coalesce(first_failure_at, now()),
           last_failure_at = coalesce(last_failure_at, now()),
           next_probe_at = now(),
           error_code = 'YOUTUBE_COOKIES_INVALID',
           error_message = 'Aguardando validação do PO Token/cookies por URL-canário autorizada.',
           updated_at = now()
     where provider = 'youtube';

    update public.download_jobs
       set status = 'queued',
           operational_status = 'waiting_provider',
           next_attempt_at = 'infinity'::timestamptz,
           locked_at = null,
           finished_at = null,
           provider_defer_count = greatest(provider_defer_count, 3),
           provider_first_deferred_at = coalesce(provider_first_deferred_at, now()),
           provider_resume_at = null,
           error = 'waiting_provider',
           error_message = 'Aguardando validação do YouTube por URL-canário. Você pode enviar um arquivo próprio autorizado.',
           error_details = coalesce(error_details, '{}'::jsonb) || pg_catalog.jsonb_build_object(
             'provider_defer_count', greatest(provider_defer_count, 3),
             'next_provider_check_at', null,
             'requires_provider_probe', true
           ),
           updated_at = now()
     where coalesce(mode, 'playlist') = 'playlist'
       and status in ('queued', 'running')
       and error_code = 'YOUTUBE_COOKIES_INVALID';

    update private.music_import_tasks task
       set status = 'waiting_provider',
           defer_count = greatest(defer_count, 3),
           first_deferred_at = coalesce(first_deferred_at, now()),
           next_attempt_at = now(),
           lease_owner = null,
           lease_expires_at = null,
           error_code = 'YOUTUBE_COOKIES_INVALID',
           error_message = 'Aguardando validação do YouTube por URL-canário.',
           updated_at = now()
      from public.download_jobs job
     where task.download_job_id = job.id
       and coalesce(job.mode, 'playlist') = 'playlist'
       and job.operational_status = 'waiting_provider'
       and job.error_code = 'YOUTUBE_COOKIES_INVALID'
       and task.status in ('queued', 'processing', 'waiting_provider');
  end if;

  perform private.reconcile_music_import_job(id)
    from public.download_jobs
   where coalesce(mode, 'playlist') = 'playlist';
end;
$$;

revoke all on function public.admin_prepare_music_upload(uuid, text, text, bigint, text) from public, anon;
revoke all on function public.worker_defer_youtube_job(uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.admin_prepare_music_upload(uuid, text, text, bigint, text) to authenticated;
grant execute on function public.worker_defer_youtube_job(uuid, text, text, jsonb) to service_role;

commit;
