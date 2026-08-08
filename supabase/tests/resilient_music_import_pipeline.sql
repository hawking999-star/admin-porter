begin;

do $test$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_outside_admin_auth uuid := gen_random_uuid();
  v_unit uuid := gen_random_uuid();
  v_outside_unit uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_playlist uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_same_playlist_job uuid := gen_random_uuid();
  v_upload_item uuid := gen_random_uuid();
  v_prepare jsonb;
  v_session uuid;
  v_control_task private.music_import_tasks%rowtype;
  v_job_row public.download_jobs%rowtype;
  v_health private.music_provider_health%rowtype;
  v_cleanup record;
  v_delay_message bigint;
  v_redelivery_message bigint;
  v_visible integer;
  v_index integer;
  v_reuse_rejected boolean := false;
  v_validation_rejected boolean := false;
begin
  if pg_catalog.has_function_privilege('authenticated', 'public.worker_defer_youtube_job(uuid,text,text,jsonb)', 'execute') then
    raise exception 'authenticated must not defer provider jobs';
  end if;
  if not pg_catalog.has_function_privilege('service_role', 'public.worker_defer_youtube_job(uuid,text,text,jsonb)', 'execute') then
    raise exception 'service_role must defer provider jobs';
  end if;
  if pg_catalog.has_table_privilege('authenticated', 'private.music_import_tasks', 'select')
     or pg_catalog.has_table_privilege('service_role', 'private.music_import_tasks', 'select') then
    raise exception 'authoritative task table must remain RPC-only';
  end if;

  insert into auth.users(id) values (v_admin_auth);
  insert into public.units (id, code, name)
  values (v_unit, 'resilient-' || left(v_unit::text, 8), 'Teste importador resiliente');
  insert into public.admin_users(auth_user_id, display_name, role, active)
  values (v_admin_auth, 'Admin importador resiliente', 'superadmin', true);
  insert into public.operators (id, registered_name, display_name, unit_id)
  values (v_operator, 'Operador resiliente', 'Operador resiliente', v_unit);
  insert into public.playlists (
    id, created_by_operator_id, unit_id, name, type, approval_status, source_url
  ) values (
    v_playlist, v_operator, v_unit, 'Playlist resiliente', 'principal', 'approved',
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'
  );
  insert into public.playlist_requests (
    id, operator_id, playlist_id, source_url, status, idempotency_key, decided_at
  ) values (
    v_request, v_operator, v_playlist,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'approved', gen_random_uuid(), now()
  );

  update private.music_import_runtime_config set backend = 'shadow' where singleton;
  insert into public.download_jobs (
    id, playlist_id, playlist_request_id, source_url, status, attempts, mode
  ) values (
    v_job, v_playlist, v_request,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'queued', 3, 'playlist'
  );
  update public.playlist_requests set download_job_id = v_job where id = v_request;

  select * into v_control_task
  from private.music_import_tasks
  where download_job_id = v_job and task_kind = 'control';
  if v_control_task.queue_name <> 'music_import_control' or v_control_task.queue_message_id is null then
    raise exception 'control task was not atomically enqueued: %', row_to_json(v_control_task);
  end if;

  for v_index in 1..9 loop
    insert into public.playlist_request_tracks (
      playlist_request_id, download_job_id, position, item_status, title, youtube_video_id
    ) values (
      v_request, v_job, v_index, 'completed', 'Importada ' || v_index,
      lpad(v_index::text, 11, 'a')
    );
  end loop;
  for v_index in 10..12 loop
    insert into public.playlist_request_tracks (
      playlist_request_id, download_job_id, position, item_status, title,
      youtube_video_id, last_error_code, error_message
    ) values (
      v_request, v_job, v_index, 'failed', 'Falha ' || v_index,
      lpad(v_index::text, 11, 'b'), 'YOUTUBE_COOKIES_INVALID', 'YouTube indisponível'
    );
  end loop;
  insert into public.playlist_request_tracks (
    id, playlist_request_id, download_job_id, position, item_status, title,
    source_track_id, last_error_code, error_message
  ) values (
    v_upload_item, v_request, v_job, 13, 'not_found', 'Não encontrada',
    'spotify-track-13', 'SPOTIFY_MATCH_NOT_FOUND', 'Não localizada no YouTube'
  );

  select * into v_job_row from public.download_jobs where id = v_job;
  if v_job_row.total <> 13 or v_job_row.completed <> 9 or v_job_row.failed <> 4
     or (v_job_row.error_details#>>'{effective_summary,failed}')::integer <> 3
     or (v_job_row.error_details#>>'{effective_summary,not_found}')::integer <> 1 then
    raise exception 'effective reconciliation mismatch: %', row_to_json(v_job_row);
  end if;

  update public.download_jobs set attempts = attempts + 1, status = 'running' where id = v_job;
  perform public.worker_defer_youtube_job(v_job, 'YOUTUBE_COOKIES_INVALID', 'Bloqueio 1', '{}'::jsonb);
  update public.download_jobs set attempts = attempts + 1, status = 'running' where id = v_job;
  perform public.worker_defer_youtube_job(v_job, 'YOUTUBE_COOKIES_INVALID', 'Bloqueio 2', '{}'::jsonb);
  update public.download_jobs set attempts = attempts + 1, status = 'running' where id = v_job;
  perform public.worker_defer_youtube_job(v_job, 'YOUTUBE_COOKIES_INVALID', 'Bloqueio 3', '{}'::jsonb);

  select * into v_job_row from public.download_jobs where id = v_job;
  select * into v_health from private.music_provider_health where provider = 'youtube';
  if v_job_row.operational_status <> 'waiting_provider'
     or v_job_row.provider_defer_count <> 3
     or v_job_row.next_attempt_at <> 'infinity'::timestamptz
     or v_job_row.attempts <> 3
     or v_health.status <> 'blocked' then
    raise exception 'finite provider circuit mismatch: job %, health %', row_to_json(v_job_row), row_to_json(v_health);
  end if;
  if public.playlist_request_general_status(v_request) <> 'analyzing' then
    raise exception 'App projection changed while waiting_provider';
  end if;

  perform public.worker_record_youtube_probe_result(true, null, null);
  select * into v_job_row from public.download_jobs where id = v_job;
  if v_job_row.operational_status <> 'queued' or v_job_row.next_attempt_at > now() then
    raise exception 'successful canary did not resume waiting job';
  end if;

  update public.download_jobs
     set status = 'running', operational_status = 'processing', locked_at = now()
   where id = v_job;
  insert into public.download_jobs (
    id, playlist_id, playlist_request_id, source_url, status, attempts, mode,
    created_at, next_attempt_at
  ) values (
    v_same_playlist_job, v_playlist, v_request,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'queued', 0, 'single_track', now() - interval '1 day', now() - interval '1 day'
  );
  perform public.worker_claim_download_job(10);
  if (select status from public.download_jobs where id = v_same_playlist_job) <> 'queued' then
    raise exception 'two workers claimed jobs from the same playlist';
  end if;
  update public.download_jobs set status = 'queued', operational_status = 'queued', locked_at = null where id = v_job;

  begin
    perform public.admin_prepare_music_upload(
      v_upload_item, 'faixa-teste.m4a', 'audio/mp4', 1024,
      'Declaro possuir autorização para usar este áudio nesta playlist.'
    );
  exception when others then
    v_validation_rejected := position('acesso_negado' in sqlerrm) > 0;
  end;
  if not v_validation_rejected then raise exception 'unauthenticated upload was not rejected'; end if;

  insert into auth.users(id) values (v_outside_admin_auth);
  insert into public.units (id, code, name)
  values (v_outside_unit, 'outside-' || left(v_outside_unit::text, 8), 'Outra unidade');
  insert into public.admin_users(auth_user_id, display_name, role, unit_scope, active)
  values (v_outside_admin_auth, 'Admin de outra unidade', 'unit_manager', array[v_outside_unit], true);
  perform set_config('request.jwt.claim.sub', v_outside_admin_auth::text, true);
  v_validation_rejected := false;
  begin
    perform public.admin_prepare_music_upload(
      v_upload_item, 'faixa-teste.m4a', 'audio/mp4', 1024,
      'Declaro possuir autorização para usar este áudio nesta playlist.'
    );
  exception when others then
    v_validation_rejected := position('fora_do_escopo_da_unidade' in sqlerrm) > 0;
  end;
  if not v_validation_rejected then raise exception 'cross-unit upload was not rejected'; end if;

  perform set_config('request.jwt.claim.sub', v_admin_auth::text, true);
  v_validation_rejected := false;
  begin
    perform public.admin_prepare_music_upload(
      v_upload_item, 'faixa-teste.exe', 'application/octet-stream', 52428801,
      'sem direito'
    );
  exception when others then
    v_validation_rejected := position('music_upload_size_invalid' in sqlerrm) > 0;
  end;
  if not v_validation_rejected then raise exception 'oversized upload was not rejected'; end if;

  v_validation_rejected := false;
  begin
    perform public.admin_prepare_music_upload(
      v_upload_item, 'faixa-teste.exe', 'audio/mpeg', 1024,
      'Declaro possuir autorização para usar este áudio nesta playlist.'
    );
  exception when others then
    v_validation_rejected := position('music_upload_extension_invalid' in sqlerrm) > 0;
  end;
  if not v_validation_rejected then raise exception 'invalid upload extension was not rejected'; end if;

  v_validation_rejected := false;
  begin
    perform public.admin_prepare_music_upload(
      v_upload_item, 'faixa-teste.mp3', 'text/plain', 1024,
      'Declaro possuir autorização para usar este áudio nesta playlist.'
    );
  exception when others then
    v_validation_rejected := position('music_upload_mime_invalid' in sqlerrm) > 0;
  end;
  if not v_validation_rejected then raise exception 'invalid upload MIME was not rejected'; end if;

  v_validation_rejected := false;
  begin
    perform public.admin_prepare_music_upload(
      v_upload_item, 'faixa-teste.mp3', 'audio/mpeg', 1024, 'não'
    );
  exception when others then
    v_validation_rejected := position('music_upload_rights_required' in sqlerrm) > 0;
  end;
  if not v_validation_rejected then raise exception 'missing rights statement was not rejected'; end if;

  v_prepare := public.admin_prepare_music_upload(
    v_upload_item, 'faixa-teste.m4a', 'audio/mp4', 1024,
    'Declaro possuir autorização para usar este áudio nesta playlist.'
  );
  v_session := (v_prepare->>'session_id')::uuid;
  if v_session is null or v_prepare->>'staging_object_key' !~ '^music-uploads/staging/[a-f0-9]{48}\.m4a$' then
    raise exception 'upload session key is not server-generated: %', v_prepare;
  end if;
  perform public.worker_complete_music_upload_session(v_session, 1024, 'etag-test');
  begin
    perform public.worker_complete_music_upload_session(v_session, 1024, 'etag-test');
  exception when others then
    v_reuse_rejected := position('music_upload_session_already_used' in sqlerrm) > 0;
  end;
  if not v_reuse_rejected then raise exception 'upload session reuse was not rejected'; end if;

  v_prepare := public.admin_prepare_music_upload(
    v_upload_item, 'faixa-expirada.wav', 'audio/wav', 2048,
    'Declaro possuir autorização para usar este áudio nesta playlist.'
  );
  v_session := (v_prepare->>'session_id')::uuid;
  update private.music_upload_sessions set expires_at = now() - interval '1 minute' where id = v_session;
  v_validation_rejected := false;
  begin
    perform public.worker_complete_music_upload_session(v_session, 2048, 'etag-expired');
  exception when others then
    v_validation_rejected := position('music_upload_session_expired' in sqlerrm) > 0;
  end;
  if not v_validation_rejected then raise exception 'expired upload session was not rejected'; end if;

  select * into v_cleanup from public.worker_claim_expired_music_upload_session();
  if v_cleanup.session_id is distinct from v_session then
    raise exception 'expired upload session was not claimed for safe cleanup';
  end if;
  perform public.worker_complete_expired_music_upload_cleanup(
    v_session, false, 'controlled R2 cleanup failure'
  );
  update private.music_upload_sessions
     set cleanup_next_attempt_at = now() - interval '1 second'
   where id = v_session;
  select * into v_cleanup from public.worker_claim_expired_music_upload_session();
  perform public.worker_complete_expired_music_upload_cleanup(v_session, true, null);
  if not exists (
    select 1 from private.music_upload_sessions
     where id = v_session
       and cleanup_status = 'done'
       and staging_deleted_at is not null
       and cleanup_attempts = 2
  ) then
    raise exception 'expired upload cleanup retry was not recorded';
  end if;

  select * into v_delay_message
  from pgmq.send('music_import_tracks', pg_catalog.jsonb_build_object('version', 1, 'task_id', gen_random_uuid()), 60);
  select count(*)::integer into v_visible
  from pgmq.read('music_import_tracks', 30, 20) message
  where message.msg_id = v_delay_message;
  if v_visible <> 0 then raise exception 'pgmq 1.5.1 delay was not interpreted as seconds'; end if;

  select * into v_redelivery_message
  from pgmq.send('music_import_tracks', pg_catalog.jsonb_build_object('version', 1, 'task_id', gen_random_uuid()), 0);
  select count(*)::integer into v_visible
  from pgmq.read('music_import_tracks', 0, 100) message
  where message.msg_id = v_redelivery_message;
  if v_visible <> 1 then raise exception 'first pgmq delivery was not visible'; end if;
  select count(*)::integer into v_visible
  from pgmq.read('music_import_tracks', 30, 100) message
  where message.msg_id = v_redelivery_message and message.read_ct >= 2;
  if v_visible <> 1 then raise exception 'crashed pgmq delivery was not redelivered'; end if;

  select * into v_control_task
  from private.music_import_tasks
  where download_job_id = v_job and task_kind = 'control';
  perform public.worker_defer_music_import_message(
    v_control_task.queue_name, v_control_task.queue_message_id, v_control_task.id,
    'CONTROLLED_FAILURE', 'falha controlada 1'
  );
  perform public.worker_defer_music_import_message(
    v_control_task.queue_name, v_control_task.queue_message_id, v_control_task.id,
    'CONTROLLED_FAILURE', 'falha controlada 2'
  );
  perform public.worker_defer_music_import_message(
    v_control_task.queue_name, v_control_task.queue_message_id, v_control_task.id,
    'CONTROLLED_FAILURE', 'falha controlada 3'
  );
  perform public.worker_defer_music_import_message(
    v_control_task.queue_name, v_control_task.queue_message_id, v_control_task.id,
    'CONTROLLED_FAILURE', 'falha controlada final'
  );
  select * into v_control_task from private.music_import_tasks where id = v_control_task.id;
  if v_control_task.status <> 'dead_letter' or v_control_task.attempt_count <> 3 then
    raise exception 'finite queue retries did not reach dead_letter after 1/5/15 minute delays';
  end if;
end;
$test$;

rollback;
