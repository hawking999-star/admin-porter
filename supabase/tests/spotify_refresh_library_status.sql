begin;
select plan(1);

do $$
declare
  v_unit uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_playlist uuid := gen_random_uuid();
  v_empty_playlist uuid := gen_random_uuid();
  v_track uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_empty_job uuid := gen_random_uuid();
  v_status text;
  v_code text;
begin
  insert into public.units (id, code, name)
  values (v_unit, 'spotify-refresh-status-test', 'Spotify Refresh Status Test');
  insert into public.operators (id, registered_name, display_name, unit_id)
  values (
    v_operator,
    'Operador Spotify Refresh',
    'Operador Spotify Refresh',
    v_unit
  );

  insert into public.playlists (
    id, created_by_operator_id, unit_id, name, type, approval_status, source_url
  ) values (
    v_playlist, v_operator, v_unit, 'Biblioteca existente', 'principal', 'approved',
    'https://open.spotify.com/playlist/0AS2QQdymdLg7BHeCs0ech'
  ), (
    v_empty_playlist, v_operator, v_unit, 'Biblioteca vazia', 'secondary', 'approved',
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'
  );

  insert into public.tracks (id, title, status)
  values (v_track, 'Faixa preservada', 'available');
  insert into public.playlist_tracks (playlist_id, track_id, position)
  values (v_playlist, v_track, 1);

  insert into public.download_jobs (
    id, playlist_id, source_url, status
  ) values (
    v_job, v_playlist,
    'https://open.spotify.com/playlist/0AS2QQdymdLg7BHeCs0ech',
    'queued'
  );

  select import_status into v_status
  from public.playlists where id = v_playlist;
  if v_status <> 'success' then
    raise exception 'existing library was hidden during refresh: %', v_status;
  end if;

  update public.download_jobs
     set status = 'error',
         error_code = 'SPOTIFY_METADATA_ERROR',
         error_message = 'Falha temporária',
         finished_at = now()
   where id = v_job;

  select import_status, error_code into v_status, v_code
  from public.playlists where id = v_playlist;
  if v_status <> 'success' or v_code <> 'SPOTIFY_METADATA_ERROR' then
    raise exception 'refresh failure did not preserve library and warning: %, %',
      v_status, v_code;
  end if;

  update public.download_jobs
     set status = 'done',
         error_code = null,
         error_message = null,
         total = 1,
         completed = 1,
         failed = 0
   where id = v_job;

  select import_status, error_code into v_status, v_code
  from public.playlists where id = v_playlist;
  if v_status <> 'success' or v_code is not null then
    raise exception 'successful refresh did not clear warning: %, %', v_status, v_code;
  end if;

  insert into public.download_jobs (
    id, playlist_id, source_url, status
  ) values (
    v_empty_job, v_empty_playlist,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'queued'
  );
  select import_status into v_status
  from public.playlists where id = v_empty_playlist;
  if v_status <> 'processing' then
    raise exception 'empty library must remain processing: %', v_status;
  end if;

  update public.download_jobs
     set status = 'error',
         error_code = 'SPOTIFY_METADATA_ERROR',
         finished_at = now()
   where id = v_empty_job;
  select import_status into v_status
  from public.playlists where id = v_empty_playlist;
  if v_status <> 'failed' then
    raise exception 'first import failure must remain failed: %', v_status;
  end if;
end;
$$;

select pass('biblioteca existente permanece disponível durante atualização');
select * from finish();
rollback;
