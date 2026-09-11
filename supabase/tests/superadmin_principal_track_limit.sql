begin;

do $test$
declare
  v_unit uuid := gen_random_uuid();
  v_normal_auth uuid := gen_random_uuid();
  v_super_auth uuid := gen_random_uuid();
  v_normal_operator uuid := gen_random_uuid();
  v_super_operator uuid := gen_random_uuid();
  v_normal_playlist uuid := gen_random_uuid();
  v_super_playlist uuid := gen_random_uuid();
  v_normal_extra_track uuid;
  v_super_extra_track uuid;
  v_response jsonb;
begin
  insert into auth.users(id) values (v_normal_auth), (v_super_auth);
  insert into public.units(id, code, name)
  values (v_unit, 'limit-' || left(v_unit::text, 8), 'Teste de cotas por perfil');
  insert into public.admin_users(auth_user_id, display_name, role, active)
  values (v_super_auth, 'Conta Super Admin', 'superadmin', true);
  insert into public.operators(id, auth_user_id, registered_name, display_name, unit_id, active)
  values
    (v_normal_operator, v_normal_auth, 'Operador comum', 'Operador comum', v_unit, true),
    (v_super_operator, v_super_auth, 'Operador superadmin', 'Operador superadmin', v_unit, true);
  insert into public.playlists(id, unit_id, name, type, status, approval_status, created_by_operator_id)
  values
    (v_normal_playlist, v_unit, 'Principal comum', 'principal', 'active', 'approved', v_normal_operator),
    (v_super_playlist, v_unit, 'Principal superadmin', 'principal', 'active', 'approved', v_super_operator);

  if private.principal_track_limit_for_operator(v_normal_operator) <> 170 then
    raise exception 'normal operator did not receive limit 170';
  end if;
  if private.principal_track_limit_for_operator(v_super_operator) <> 400 then
    raise exception 'superadmin operator did not receive limit 400';
  end if;
  if private.principal_track_limit_for_playlist(v_super_playlist) <> 400 then
    raise exception 'superadmin playlist did not receive limit 400';
  end if;

  perform set_config('request.jwt.claim.sub', v_super_auth::text, true);
  v_response := public.get_my_playlists(jsonb_build_object('request_id', 'superadmin-limit-test'));
  if not (v_response->>'success')::boolean
     or (v_response#>>'{data,principal_track_limit}')::integer <> 400 then
    raise exception 'App contract did not return limit 400: %', v_response;
  end if;

  insert into public.tracks(title, duration_ms, storage_object_key, status, metadata)
  select 'Normal ' || item, 1000, 'limit-test/normal-' || v_unit || '-' || item || '.mp3', 'available',
         jsonb_build_object('limit_test', v_unit, 'owner', 'normal')
    from generate_series(1, 171) item;
  insert into public.tracks(title, duration_ms, storage_object_key, status, metadata)
  select 'Super ' || item, 1000, 'limit-test/super-' || v_unit || '-' || item || '.mp3', 'available',
         jsonb_build_object('limit_test', v_unit, 'owner', 'super')
    from generate_series(1, 401) item;

  insert into public.playlist_tracks(playlist_id, track_id, position, added_by_type)
  select v_normal_playlist, track.id, row_number() over (order by track.id) - 1, 'system'
    from public.tracks track
   where track.metadata->>'limit_test' = v_unit::text and track.metadata->>'owner' = 'normal'
   order by track.id
   limit 170;
  select track.id into v_normal_extra_track
    from public.tracks track
   where track.metadata->>'limit_test' = v_unit::text and track.metadata->>'owner' = 'normal'
     and not exists (
       select 1 from public.playlist_tracks link
        where link.playlist_id = v_normal_playlist and link.track_id = track.id
     )
   limit 1;
  begin
    insert into public.playlist_tracks(playlist_id, track_id, position, added_by_type)
    values (v_normal_playlist, v_normal_extra_track, 170, 'system');
    raise exception 'normal playlist accepted track 171';
  exception when check_violation then
    if SQLERRM <> 'PRINCIPAL_TRACK_LIMIT_REACHED' then raise; end if;
  end;

  insert into public.playlist_tracks(playlist_id, track_id, position, added_by_type)
  select v_super_playlist, track.id, row_number() over (order by track.id) - 1, 'system'
    from public.tracks track
   where track.metadata->>'limit_test' = v_unit::text and track.metadata->>'owner' = 'super'
   order by track.id
   limit 400;
  select track.id into v_super_extra_track
    from public.tracks track
   where track.metadata->>'limit_test' = v_unit::text and track.metadata->>'owner' = 'super'
     and not exists (
       select 1 from public.playlist_tracks link
        where link.playlist_id = v_super_playlist and link.track_id = track.id
     )
   limit 1;
  begin
    insert into public.playlist_tracks(playlist_id, track_id, position, added_by_type)
    values (v_super_playlist, v_super_extra_track, 400, 'system');
    raise exception 'superadmin playlist accepted track 401';
  exception when check_violation then
    if SQLERRM <> 'PRINCIPAL_TRACK_LIMIT_REACHED' then raise; end if;
  end;

  update public.admin_users set active = false where auth_user_id = v_super_auth;
  if private.principal_track_limit_for_operator(v_super_operator) <> 170 then
    raise exception 'inactive superadmin retained elevated limit';
  end if;
end;
$test$;

rollback;
