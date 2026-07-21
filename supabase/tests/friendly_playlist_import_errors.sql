begin;

do $$
declare
  v_unit uuid := gen_random_uuid();
  v_operator uuid := gen_random_uuid();
  v_playlist uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_job uuid := gen_random_uuid();
  v_messages jsonb;
begin
  if public.playlist_request_item_operator_message('review_recommended')
     <> 'Esta música parece ser uma versão diferente e precisa de revisão.' then
    raise exception 'unexpected review message';
  end if;

  insert into public.units (id, code, name)
  values (v_unit, 'phase12-errors-test', 'Phase 12 Errors Test');

  insert into public.operators (id, display_name, unit_id)
  values (v_operator, 'Operador Phase 12', v_unit);

  insert into public.playlists (
    id, created_by_operator_id, unit_id, name, type, approval_status, source_url
  ) values (
    v_playlist, v_operator, v_unit, 'Playlist Phase 12', 'principal', 'approved',
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M'
  );

  insert into public.playlist_requests (
    id, operator_id, playlist_id, source_url, status, idempotency_key, decided_at
  ) values (
    v_request, v_operator, v_playlist,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'approved', gen_random_uuid(), now()
  );

  insert into public.download_jobs (
    id, playlist_id, playlist_request_id, source_url, status, error_code, error_message,
    error_details
  ) values (
    v_job, v_playlist, v_request,
    'https://open.spotify.com/playlist/37i9dQZF1DXcBWIGoYBM5M',
    'error', 'SPOTIFY_LINK_UNAVAILABLE', 'O link do Spotify não está mais disponível.',
    '{"technical_summary":"spotDL returned unavailable","internal":"not for operator"}'::jsonb
  );
  update public.playlist_requests set download_job_id = v_job where id = v_request;

  v_messages := public.playlist_request_operator_messages(v_request);
  if not v_messages ? 'O link do Spotify não está mais disponível.' then
    raise exception 'missing unavailable-link friendly message: %', v_messages;
  end if;
  if v_messages::text like '%spotDL%' or v_messages::text like '%internal%' then
    raise exception 'technical detail leaked into operator messages: %', v_messages;
  end if;

  insert into public.playlist_request_tracks (
    playlist_request_id, position, item_status, title
  ) values
    (v_request, 1, 'completed', 'Concluída'),
    (v_request, 2, 'not_found', 'Não encontrada'),
    (v_request, 3, 'duration_exceeded', 'Longa'),
    (v_request, 171, 'playlist_limit_exceeded', 'Excedente');
  update public.download_jobs
     set status = 'partial', completed = 1, failed = 3, error_code = 'IMPORTED_WITH_UNAVAILABLE'
   where id = v_job;

  v_messages := public.playlist_request_operator_messages(v_request);
  if not v_messages ? 'A solicitação foi concluída parcialmente.'
     or not v_messages ? 'Não foi possível localizar algumas músicas no YouTube.'
     or not v_messages ? 'A playlist ultrapassa o limite de 170 músicas.'
     or not v_messages ? 'Uma ou mais músicas ultrapassam a duração máxima de 16 minutos.' then
    raise exception 'missing partial-import friendly messages: %', v_messages;
  end if;
end;
$$;

rollback;
