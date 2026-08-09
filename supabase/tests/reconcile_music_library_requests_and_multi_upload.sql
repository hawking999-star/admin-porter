begin;

do $test$
declare
  v_admin_auth uuid := gen_random_uuid();
  v_operator_auth uuid := gen_random_uuid();
  v_unit uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_playlist uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_prepare jsonb;
  v_session private.music_upload_sessions%rowtype;
  v_result jsonb;
begin
  insert into auth.users(id) values (v_admin_auth), (v_operator_auth);
  insert into public.units(id, code, name)
  values (v_unit, 'music-fix-' || left(v_unit::text, 8), 'Teste biblioteca musical');
  insert into public.admin_users(auth_user_id, display_name, role, active)
  values (v_admin_auth, 'Admin biblioteca', 'superadmin', true);
  insert into public.operators(id, auth_user_id, registered_name, display_name, unit_id)
  values (v_operator, v_operator_auth, 'Operador biblioteca', 'Operador biblioteca', v_unit);
  insert into public.playlists(
    id, created_by_operator_id, unit_id, name, type, status,
    approval_status, import_status, source_url, error_code, error_message
  ) values (
    v_playlist, v_operator, v_unit, 'Principal teste', 'principal', 'active',
    'approved', 'failed', 'https://www.youtube.com/playlist?list=PL1234567890',
    'REVIEW_RECOMMENDED', '1 música aguardando revisão.'
  );
  insert into public.playlist_requests(
    id, operator_id, playlist_id, source_url, status, idempotency_key, decided_at
  ) values (
    v_request, v_operator, v_playlist,
    'https://www.youtube.com/playlist?list=PL1234567890',
    'approved', gen_random_uuid(), now()
  );
  insert into public.download_jobs(
    id, playlist_id, playlist_request_id, source_url, status, mode,
    total, completed, failed, error_code, error_message
  ) values (
    v_job, v_playlist, v_request,
    'https://www.youtube.com/playlist?list=PL1234567890',
    'partial', 'playlist', 2, 1, 0, 'REVIEW_RECOMMENDED',
    '1 música aguardando revisão.'
  );
  update public.playlist_requests set download_job_id = v_job where id = v_request;
  insert into public.playlist_request_tracks(
    playlist_request_id, download_job_id, position, item_status, title, youtube_video_id
  ) values
    (v_request, v_job, 1, 'completed', 'Faixa pronta', 'abcdefghijk'),
    (v_request, v_job, 2, 'review_recommended', 'Faixa revisar', 'lmnopqrstuv');

  update public.playlist_request_tracks
     set item_status = 'completed'
   where playlist_request_id = v_request
     and position = 2;

  if (select status from public.download_jobs where id = v_job) <> 'done' then
    raise exception 'latest playlist job was not reconciled to done';
  end if;
  if (select error_message from public.playlists where id = v_playlist) is not null then
    raise exception 'stale playlist error was not cleared';
  end if;

  perform set_config('request.jwt.claim.sub', v_admin_auth::text, true);
  v_prepare := public.admin_prepare_library_music_upload(
    v_playlist, 'faixa autorizada.mp3', 'audio/mpeg', 1024,
    'Declaro autorização para usar este áudio.'
  );
  select * into v_session
    from private.music_upload_sessions
   where id = (v_prepare->>'session_id')::uuid;
  if v_session.playlist_id <> v_playlist or v_session.request_item_id is not null then
    raise exception 'library upload was not prepared independently from request items';
  end if;

  v_result := public.admin_clear_operator_playlist_requests(v_operator, v_playlist);
  if (v_result->>'cleared_count')::integer <> 1 then
    raise exception 'completed request was not cleared: %', v_result;
  end if;
  if (select dismissed_at from public.playlist_requests where id = v_request) is null then
    raise exception 'request dismissal was not persisted';
  end if;

  perform set_config('request.jwt.claim.sub', v_operator_auth::text, true);
  v_result := public.get_my_playlist_requests(
    jsonb_build_object('request_id', gen_random_uuid(), 'limit', 20)
  );
  if jsonb_array_length(coalesce(v_result#>'{data,requests}', '[]'::jsonb)) <> 0 then
    raise exception 'dismissed request is still visible to the App';
  end if;
  v_result := public.get_my_playlists(jsonb_build_object('request_id', gen_random_uuid()));
  if coalesce((v_result#>>'{data,playlists,0,track_count}')::integer, -1) <> 0 then
    raise exception 'App playlist count is not available-only: %', v_result;
  end if;

  if pg_catalog.has_function_privilege('authenticated', 'public.worker_attach_music_upload_track(uuid,uuid)', 'execute') then
    raise exception 'authenticated must not attach uploaded tracks';
  end if;
  if not pg_catalog.has_function_privilege('service_role', 'public.worker_attach_music_upload_track(uuid,uuid)', 'execute') then
    raise exception 'service_role must attach uploaded tracks';
  end if;
end;
$test$;

rollback;
