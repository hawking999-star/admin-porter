begin;

-- A agregacao anterior partia dos itens; esta versao tambem representa o
-- periodo entre a aprovacao e a primeira resolucao pelo worker.
create or replace function public.admin_playlist_request_detail(p_playlist_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_playlist public.playlists%rowtype;
  v_request public.playlist_requests%rowtype;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  select * into v_playlist from public.playlists where id = p_playlist_id;
  if v_playlist.id is null then raise exception 'playlist_not_found'; end if;
  if not public.is_superadmin() and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception 'forbidden';
  end if;
  select * into v_request from public.playlist_requests
   where playlist_id = p_playlist_id order by created_at desc, id desc limit 1;
  if v_request.id is null then return null; end if;

  return jsonb_build_object(
    'request', jsonb_build_object(
      'id', v_request.id, 'status', v_request.status,
      'original_url', coalesce(v_request.original_url, v_request.source_url),
      'normalized_url', coalesce(v_request.normalized_url, v_request.source_url),
      'source_type', coalesce(v_request.source_type, public.playlist_source_platform(v_request.source_url)),
      'source_resource_type', v_request.source_resource_type,
      'source_resource_id', v_request.source_resource_id,
      'created_at', v_request.created_at, 'rejection_reason', v_request.rejection_reason
    ),
    'playlist', jsonb_build_object('id', v_playlist.id, 'name', v_playlist.name, 'type', v_playlist.type,
      'approval_status', v_playlist.approval_status, 'import_status', v_playlist.import_status),
    'operator', jsonb_build_object('name', (select display_name from public.operators where id = v_playlist.created_by_operator_id)),
    'unit', jsonb_build_object('name', (select name from public.units where id = v_playlist.unit_id),
      'city', (select city from public.units where id = v_playlist.unit_id),
      'state', (select state from public.units where id = v_playlist.unit_id)),
    'summary', (select jsonb_build_object(
      'total', count(*),
      'resolved', count(*) filter (where item_status in ('resolved', 'processing', 'completed')),
      'review_recommended', count(*) filter (where item_status = 'review_recommended'),
      'not_found', count(*) filter (where item_status = 'not_found'),
      'duplicate', count(*) filter (where item_status = 'duplicate'),
      'duration_exceeded', count(*) filter (where item_status = 'duration_exceeded'),
      'playlist_limit_exceeded', count(*) filter (where item_status = 'playlist_limit_exceeded'),
      'failed', count(*) filter (where item_status = 'failed')
    ) from public.playlist_request_tracks where playlist_request_id = v_request.id),
    'items', coalesce((select jsonb_agg(jsonb_build_object(
      'id', prt.id, 'position', prt.position, 'status', prt.item_status,
      'spotify_track_id', prt.source_track_id, 'spotify_url', prt.source_url,
      'title', prt.title, 'artists', prt.artists, 'album', prt.album, 'duration_ms', prt.duration_ms,
      'youtube_url', prt.youtube_url, 'youtube_video_id', prt.youtube_video_id,
      'youtube_title', t.title, 'youtube_artist', t.artist,
      'youtube_channel', coalesce(prt.metadata ->> 'youtube_channel', t.metadata ->> 'youtube_channel'),
      'youtube_duration_ms', coalesce(t.duration_ms, nullif(prt.metadata ->> 'youtube_duration_ms', '')::integer),
      'duration_difference_ms', case when prt.duration_ms is not null and coalesce(t.duration_ms, nullif(prt.metadata ->> 'youtube_duration_ms', '')::integer) is not null
        then abs(prt.duration_ms - coalesce(t.duration_ms, nullif(prt.metadata ->> 'youtube_duration_ms', '')::integer)) end,
      'match_confidence', prt.match_confidence, 'review_reason', prt.error_message, 'error_message', prt.error_message
    ) order by prt.position, prt.id)
    from public.playlist_request_tracks prt left join public.tracks t on t.id = prt.track_id
    where prt.playlist_request_id = v_request.id), '[]'::jsonb)
  );
end;
$$;

revoke all on function public.admin_playlist_request_detail(uuid) from public, anon;
grant execute on function public.admin_playlist_request_detail(uuid) to authenticated;

commit;
