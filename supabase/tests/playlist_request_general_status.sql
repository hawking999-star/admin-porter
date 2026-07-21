begin;

do $$
declare
  v_unit uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_playlist uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_item_ok uuid := gen_random_uuid();
  v_item_failed uuid := gen_random_uuid();
  v_actual text;
begin
  insert into public.units (id, code, name)
  values (v_unit, 'phase10-status-test', 'Phase 10 Status Test');

  insert into public.operators (id, display_name, unit_id)
  values (v_operator, 'Operador Phase 10', v_unit);

  insert into public.playlists (
    id, created_by_operator_id, unit_id, name, type, approval_status, source_url
  ) values (
    v_playlist, v_operator, v_unit, 'Playlist Phase 10', 'principal', 'pending',
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'
  );

  insert into public.playlist_requests (
    id, operator_id, playlist_id, source_url, status, idempotency_key
  ) values (
    v_request, v_operator, v_playlist,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'pending', gen_random_uuid()
  );

  v_actual := public.playlist_request_general_status(v_request);
  if v_actual <> 'pending' then raise exception 'expected pending, got %', v_actual; end if;

  update public.playlist_requests
     set status = 'approved', decided_at = now()
   where id = v_request;
  v_actual := public.playlist_request_general_status(v_request);
  if v_actual <> 'approved' then raise exception 'expected approved, got %', v_actual; end if;

  insert into public.download_jobs (
    id, playlist_id, playlist_request_id, source_url, status
  ) values (
    v_job, v_playlist, v_request,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M', 'running'
  );
  update public.playlist_requests set download_job_id = v_job where id = v_request;
  v_actual := public.playlist_request_general_status(v_request);
  if v_actual <> 'analyzing' then raise exception 'expected analyzing, got %', v_actual; end if;

  insert into public.playlist_request_tracks (
    id, playlist_request_id, position, item_status, title
  ) values (
    v_item_ok, v_request, 1, 'review_recommended', 'Faixa em revisão'
  );
  v_actual := public.playlist_request_general_status(v_request);
  if v_actual <> 'waiting_review' then raise exception 'expected waiting_review, got %', v_actual; end if;

  update public.playlist_request_tracks set item_status = 'processing' where id = v_item_ok;
  v_actual := public.playlist_request_general_status(v_request);
  if v_actual <> 'processing' then raise exception 'expected processing, got %', v_actual; end if;

  update public.playlist_request_tracks set item_status = 'completed' where id = v_item_ok;
  insert into public.playlist_request_tracks (
    id, playlist_request_id, position, item_status, title
  ) values (
    v_item_failed, v_request, 2, 'failed', 'Faixa com falha'
  );
  update public.download_jobs set status = 'partial', completed = 1, failed = 1 where id = v_job;
  v_actual := public.playlist_request_general_status(v_request);
  if v_actual <> 'partially_completed' then
    raise exception 'expected partially_completed, got %', v_actual;
  end if;

  delete from public.playlist_request_tracks where id = v_item_ok;
  update public.download_jobs set status = 'error', completed = 0, failed = 1 where id = v_job;
  v_actual := public.playlist_request_general_status(v_request);
  if v_actual <> 'failed' then raise exception 'expected failed, got %', v_actual; end if;

  update public.playlist_request_tracks set item_status = 'not_found' where id = v_item_failed;
  v_actual := public.playlist_request_general_status(v_request);
  if v_actual <> 'completed' then
    raise exception 'expected completed for exclusions-only result, got %', v_actual;
  end if;
end;
$$;

rollback;
