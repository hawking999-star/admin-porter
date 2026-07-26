begin;
select plan(1);

do $test$
declare
  v_admin_auth_id uuid := gen_random_uuid();
  v_unit uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_playlist uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_old_job uuid := gen_random_uuid();
  v_current_job uuid := gen_random_uuid();
  v_current_item uuid := gen_random_uuid();
  v_detail jsonb;
  v_job_status text;
begin
  insert into auth.users(id) values (v_admin_auth_id);
  insert into public.units (id, code, name)
  values (
    v_unit,
    'current-attempt-' || left(v_unit::text, 8),
    'Teste tentativa vigente'
  );
  insert into public.admin_users(auth_user_id, display_name, role, active)
  values (
    v_admin_auth_id,
    'Admin tentativa vigente',
    'superadmin',
    true
  );
  insert into public.operators (id, registered_name, display_name, unit_id)
  values (v_operator, 'Operador teste', 'Operador teste', v_unit);
  insert into public.playlists (
    id, created_by_operator_id, unit_id, name, type, approval_status, source_url
  ) values (
    v_playlist,
    v_operator,
    v_unit,
    'Playlist tentativa vigente',
    'principal',
    'approved',
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'
  );
  insert into public.playlist_requests (
    id, operator_id, playlist_id, source_url, status, idempotency_key, decided_at
  ) values (
    v_request,
    v_operator,
    v_playlist,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'approved',
    gen_random_uuid(),
    now()
  );
  insert into public.download_jobs (
    id, playlist_id, playlist_request_id, source_url, status, mode, created_at
  ) values
    (
      v_old_job,
      v_playlist,
      v_request,
      'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
      'partial',
      'playlist',
      now() - interval '1 hour'
    ),
    (
      v_current_job,
      v_playlist,
      v_request,
      'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
      'partial',
      'playlist',
      now()
    );
  update public.playlist_requests
     set download_job_id = v_current_job
   where id = v_request;

  insert into public.playlist_request_tracks (
    id, playlist_request_id, download_job_id, position, item_status, title
  ) values
    (gen_random_uuid(), v_request, v_old_job, 1, 'review_recommended', 'Tentativa antiga 1'),
    (gen_random_uuid(), v_request, v_old_job, 2, 'failed', 'Tentativa antiga 2'),
    (v_current_item, v_request, v_current_job, 1, 'completed', 'Tentativa atual 1'),
    (gen_random_uuid(), v_request, v_current_job, 2, 'skipped', 'Tentativa atual 2');

  perform set_config('request.jwt.claim.sub', v_admin_auth_id::text, true);
  v_detail := public.admin_playlist_request_detail(v_playlist);

  if (v_detail#>>'{summary,total}')::integer <> 2 then
    raise exception 'expected 2 current items, got %', v_detail#>>'{summary,total}';
  end if;
  if pg_catalog.jsonb_array_length(v_detail->'items') <> 2 then
    raise exception 'expected 2 visible items, got %', v_detail->'items';
  end if;
  if v_detail#>>'{request,general_status}' <> 'completed' then
    raise exception 'expected skipped current item to be terminal, got %',
      v_detail#>>'{request,general_status}';
  end if;
  if pg_catalog.jsonb_array_length(
    coalesce(v_detail#>'{request,operator_messages}', '[]'::jsonb)
  ) <> 0 then
    raise exception 'old attempt messages leaked into current detail: %',
      v_detail#>'{request,operator_messages}';
  end if;

  update public.playlist_request_tracks
     set item_status = 'processing'
   where id = v_current_item;
  update public.playlist_request_tracks
     set item_status = 'completed'
   where id = v_current_item;

  select status into v_job_status
    from public.download_jobs
   where id = v_current_job;
  if v_job_status <> 'done' then
    raise exception 'expected remediated current job to be done, got %',
      v_job_status;
  end if;
end;
$test$;

select pass('detalhe usa somente a tentativa vigente da playlist');
select * from finish();
rollback;
