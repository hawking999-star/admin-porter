begin;
select plan(1);

do $test$
declare
  v_unit uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_playlist uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_playlist_job uuid := gen_random_uuid();
  v_item uuid := gen_random_uuid();
  v_old_track uuid := gen_random_uuid();
  v_new_track uuid := gen_random_uuid();
  v_single_job uuid := gen_random_uuid();
  v_old_youtube text;
  v_new_youtube text;
  v_count integer;
  v_position integer;
  v_status text;
begin
  v_old_youtube := left(replace(v_old_track::text, '-', ''), 11);
  v_new_youtube := left(replace(v_new_track::text, '-', ''), 11);
  insert into public.units (id, code, name)
  values (v_unit, 'atomic-' || left(v_unit::text, 8), 'Teste troca atomica');
  insert into public.operators (id, registered_name, display_name, unit_id)
  values (v_operator, 'Operador teste', 'Operador teste', v_unit);
  insert into public.playlists (
    id, created_by_operator_id, unit_id, name, type, approval_status, source_url
  ) values (
    v_playlist, v_operator, v_unit, 'Playlist teste', 'principal', 'pending',
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
    v_playlist_job, v_playlist, v_request,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'partial', 'playlist'
  );
  insert into public.tracks (
    id, title, artist, duration_ms, storage_object_key, status, metadata
  ) values
    (
      v_old_track, 'Faixa antiga', 'Artista', 180000,
      'tracks/' || v_old_youtube || '.mp3', 'available',
      jsonb_build_object('youtube_id', v_old_youtube)
    ),
    (
      v_new_track, 'Faixa nova', 'Artista', 180000,
      'tracks/' || v_new_youtube || '.mp3', 'available',
      jsonb_build_object('youtube_id', v_new_youtube)
    );
  insert into public.playlist_tracks (
    playlist_id, track_id, position, added_by_type
  ) values (v_playlist, v_old_track, 7, 'system');
  insert into public.playlist_request_tracks (
    id, playlist_request_id, download_job_id, track_id, position,
    item_status, youtube_url, youtube_video_id, title, metadata
  ) values (
    v_item, v_request, v_playlist_job, v_old_track, 7,
    'failed', 'https://www.youtube.com/watch?v=' || v_old_youtube,
    v_old_youtube, 'Faixa antiga', '{"manual_replacement":true}'::jsonb
  )
  on conflict (playlist_request_id, track_id) do update
    set download_job_id = excluded.download_job_id,
        position = excluded.position,
        item_status = excluded.item_status,
        youtube_url = excluded.youtube_url,
        youtube_video_id = excluded.youtube_video_id,
        title = excluded.title,
        metadata = excluded.metadata
  returning id into v_item;
  insert into public.download_jobs (
    id, playlist_id, playlist_request_id, playlist_request_item_id,
    source_url, status, mode, replace_youtube_id
  ) values (
    v_single_job, v_playlist, v_request, v_item,
    'https://www.youtube.com/watch?v=' || v_new_youtube,
    'running', 'single_track', v_old_youtube
  );

  perform public.worker_replace_playlist_request_track(
    v_single_job,
    v_new_track,
    v_new_youtube
  );

  select count(*), min(position)
    into v_count, v_position
    from public.playlist_tracks
   where playlist_id = v_playlist
     and track_id = v_new_track;
  if v_count <> 1 or v_position <> 7 then
    raise exception 'replacement did not preserve one link at position 7';
  end if;
  if exists (
    select 1 from public.playlist_tracks
     where playlist_id = v_playlist and track_id = v_old_track
  ) then
    raise exception 'old playlist link was not removed';
  end if;

  select item_status into v_status
    from public.playlist_request_tracks
   where id = v_item
     and track_id = v_new_track;
  if v_status <> 'completed' then
    raise exception 'request item was not completed on the replacement track';
  end if;
end;
$test$;

select pass('troca manual substitui o vinculo sem duplicar e preserva a posicao');
select * from finish();
rollback;
