begin;

do $$
declare
  v_unit uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_playlist uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_item uuid := gen_random_uuid();
  v_stale_item uuid := gen_random_uuid();
  v_claimed public.playlist_request_tracks%rowtype;
begin
  if has_function_privilege(
    'authenticated',
    'public.worker_claim_playlist_request_item(uuid,integer,integer,integer)',
    'execute'
  ) then
    raise exception 'authenticated must not claim playlist request items';
  end if;
  if not has_function_privilege(
    'service_role',
    'public.worker_claim_playlist_request_item(uuid,integer,integer,integer)',
    'execute'
  ) then
    raise exception 'service_role must claim playlist request items';
  end if;

  insert into public.units (id, code, name)
  values (v_unit, 'phase13-async-test', 'Phase 13 Async Test');
  insert into public.operators (id, display_name, unit_id)
  values (v_operator, 'Operador Phase 13', v_unit);
  insert into public.playlists (
    id, created_by_operator_id, unit_id, name, type, approval_status, source_url
  ) values (
    v_playlist, v_operator, v_unit, 'Playlist Phase 13', 'principal', 'approved',
    'https://www.youtube.com/playlist?list=PL1234567890ABCDEFGH'
  );
  insert into public.playlist_requests (
    id, operator_id, playlist_id, source_url, status, idempotency_key, decided_at
  ) values (
    v_request, v_operator, v_playlist,
    'https://www.youtube.com/playlist?list=PL1234567890ABCDEFGH',
    'approved', gen_random_uuid(), now()
  );
  insert into public.download_jobs (
    id, playlist_id, playlist_request_id, source_url, status, attempts, locked_at
  ) values (
    v_job, v_playlist, v_request,
    'https://www.youtube.com/playlist?list=PL1234567890ABCDEFGH',
    'running', 1, now()
  );
  update public.playlist_requests set download_job_id = v_job where id = v_request;

  insert into public.playlist_request_tracks (
    id, playlist_request_id, download_job_id, position, item_status,
    youtube_video_id, title
  ) values (
    v_item, v_request, v_job, 1, 'resolved', 'abcdefghijk', 'Faixa 1'
  );

  select * into v_claimed
    from public.worker_claim_playlist_request_item(v_job, 1, 2, 1800);
  if v_claimed.id <> v_item or v_claimed.item_status <> 'processing'
     or v_claimed.attempts <> 1 or v_claimed.locked_at is null then
    raise exception 'first item claim failed: %', row_to_json(v_claimed);
  end if;

  select * into v_claimed
    from public.worker_claim_playlist_request_item(v_job, 1, 2, 1800);
  if v_claimed.id is not null then
    raise exception 'active item was claimed twice';
  end if;

  update public.playlist_request_tracks
     set item_status = 'failed', locked_at = null
   where id = v_item;
  select * into v_claimed
    from public.worker_claim_playlist_request_item(v_job, 1, 2, 1800);
  if v_claimed.id <> v_item or v_claimed.attempts <> 2 then
    raise exception 'second item claim failed';
  end if;

  update public.playlist_request_tracks
     set item_status = 'failed', locked_at = null
   where id = v_item;
  select * into v_claimed
    from public.worker_claim_playlist_request_item(v_job, 1, 2, 1800);
  if v_claimed.id is not null then
    raise exception 'item exceeded the maximum of two attempts';
  end if;

  insert into public.playlist_request_tracks (
    id, playlist_request_id, download_job_id, position, item_status,
    attempts, locked_at, youtube_video_id, title
  ) values (
    v_stale_item, v_request, v_job, 2, 'processing',
    1, now() - interval '31 minutes', 'lmnopqrstuv', 'Faixa interrompida'
  );
  select * into v_claimed
    from public.worker_claim_playlist_request_item(v_job, 2, 2, 1800);
  if v_claimed.id <> v_stale_item or v_claimed.attempts <> 2 then
    raise exception 'stale item was not resumed';
  end if;
end;
$$;

rollback;
