begin;
select plan(1);

do $test$
declare
  v_admin_auth_id uuid := gen_random_uuid();
  v_unit uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_playlist uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_source_job uuid := gen_random_uuid();
  v_item_one uuid := gen_random_uuid();
  v_item_two uuid := gen_random_uuid();
  v_blocked_item uuid := gen_random_uuid();
  v_result jsonb;
  v_count integer;
begin
  if pg_catalog.has_function_privilege(
    'anon',
    'public.admin_accept_playlist_request_items(uuid,uuid[])',
    'execute'
  ) then
    raise exception 'anon must not execute admin_accept_playlist_request_items';
  end if;
  if not pg_catalog.has_function_privilege(
    'authenticated',
    'public.admin_accept_playlist_request_items(uuid,uuid[])',
    'execute'
  ) then
    raise exception 'authenticated must execute admin_accept_playlist_request_items';
  end if;

  insert into auth.users(id) values (v_admin_auth_id);
  insert into public.units (id, code, name)
  values (v_unit, 'accept-batch-' || left(v_unit::text, 8), 'Teste aceite em lote');
  insert into public.admin_users(auth_user_id, display_name, role, active)
  values (v_admin_auth_id, 'Admin teste aceite em lote', 'superadmin', true);
  insert into public.operators (id, registered_name, display_name, unit_id)
  values (v_operator, 'Operador teste', 'Operador teste', v_unit);
  insert into public.playlists (
    id, created_by_operator_id, unit_id, name, type, approval_status, source_url
  ) values (
    v_playlist, v_operator, v_unit, 'Playlist teste aceite', 'principal', 'pending',
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'
  );
  insert into public.playlist_requests (
    id, operator_id, playlist_id, source_url, status, idempotency_key
  ) values (
    v_request, v_operator, v_playlist,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'pending', gen_random_uuid()
  );
  insert into public.download_jobs (
    id, playlist_id, playlist_request_id, source_url, status, mode
  ) values (
    v_source_job, v_playlist, v_request,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'partial', 'playlist'
  );
  insert into public.playlist_request_tracks (
    id, playlist_request_id, download_job_id, position, item_status,
    youtube_url, youtube_video_id, title
  ) values
    (
      v_item_one, v_request, v_source_job, 1, 'review_recommended',
      'https://www.youtube.com/watch?v=hQf7MeBTR2E', 'hQf7MeBTR2E', 'Faixa um'
    ),
    (
      v_item_two, v_request, v_source_job, 2, 'review_recommended',
      'https://www.youtube.com/watch?v=dQw4w9WgXcQ', 'dQw4w9WgXcQ', 'Faixa dois'
    );

  perform set_config('request.jwt.claim.sub', v_admin_auth_id::text, true);
  select public.admin_accept_playlist_request_items(
    v_request,
    array[v_item_one, v_item_two, v_item_one]
  ) into v_result;

  if (v_result ->> 'queued')::integer <> 2 then
    raise exception 'expected two unique queued items, got %', v_result;
  end if;
  select count(*) into v_count
    from public.download_jobs
   where playlist_request_id = v_request
     and mode = 'single_track'
     and status = 'queued';
  if v_count <> 2 then raise exception 'expected two single-track jobs, got %', v_count; end if;
  select count(*) into v_count
    from public.download_jobs
   where playlist_request_id = v_request
     and playlist_request_item_id in (v_item_one, v_item_two)
     and mode = 'single_track';
  if v_count <> 2 then raise exception 'expected jobs bound to exact request items, got %', v_count; end if;

  select count(*) into v_count
    from public.playlist_request_tracks
   where id in (v_item_one, v_item_two)
     and item_status = 'processing';
  if v_count <> 2 then raise exception 'expected both items processing, got %', v_count; end if;

  -- Repetir enquanto os jobs aguardam nao duplica a mesma acao.
  perform public.admin_accept_playlist_request_items(v_request, array[v_item_one, v_item_two]);
  select count(*) into v_count
    from public.download_jobs
   where playlist_request_id = v_request
     and mode = 'single_track'
     and status = 'queued';
  if v_count <> 2 then raise exception 'idempotency failed, got % jobs', v_count; end if;

  -- Uma importacao completa ativa ainda protege o conjunto da playlist.
  insert into public.download_jobs (
    playlist_id, playlist_request_id, source_url, status, mode
  ) values (
    v_playlist, v_request,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'queued', 'playlist'
  );
  insert into public.playlist_request_tracks (
    id, playlist_request_id, download_job_id, position, item_status,
    youtube_url, youtube_video_id, title
  ) values (
    v_blocked_item, v_request, v_source_job, 3, 'review_recommended',
    'https://www.youtube.com/watch?v=9bZkp7q19f0', '9bZkp7q19f0', 'Faixa bloqueada'
  );
  begin
    perform public.admin_accept_playlist_request_items(v_request, array[v_blocked_item]);
    raise exception 'expected import_already_running';
  exception
    when others then
      if sqlerrm <> 'import_already_running' then raise; end if;
  end;
end;
$test$;

select pass('aceite em lote enfileira varias faixas sem perder protecoes');
select * from finish();
rollback;
