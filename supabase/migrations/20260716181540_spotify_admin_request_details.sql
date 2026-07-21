begin;

-- O Admin continua acessando itens somente por RPC: a tabela permanece sem
-- permissao direta para o navegador e a funcao aplica o escopo do condominio.
create or replace function public.admin_playlist_request_detail(p_playlist_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_playlist public.playlists%rowtype;
  v_request public.playlist_requests%rowtype;
  v_result jsonb;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;

  select * into v_playlist from public.playlists where id = p_playlist_id;
  if v_playlist.id is null then raise exception 'playlist_not_found'; end if;
  if not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception 'forbidden';
  end if;

  select * into v_request
    from public.playlist_requests
   where playlist_id = p_playlist_id
   order by created_at desc, id desc
   limit 1;
  if v_request.id is null then return null; end if;

  select jsonb_build_object(
    'request', jsonb_build_object(
      'id', v_request.id,
      'status', v_request.status,
      'original_url', coalesce(v_request.original_url, v_request.source_url),
      'normalized_url', coalesce(v_request.normalized_url, v_request.source_url),
      'source_type', coalesce(v_request.source_type, public.playlist_source_platform(v_request.source_url)),
      'source_resource_type', v_request.source_resource_type,
      'source_resource_id', v_request.source_resource_id,
      'created_at', v_request.created_at,
      'rejection_reason', v_request.rejection_reason
    ),
    'playlist', jsonb_build_object(
      'id', v_playlist.id, 'name', v_playlist.name, 'type', v_playlist.type,
      'approval_status', v_playlist.approval_status, 'import_status', v_playlist.import_status
    ),
    'operator', jsonb_build_object('name', o.display_name),
    'unit', jsonb_build_object('name', u.name, 'city', u.city, 'state', u.state),
    'summary', jsonb_build_object(
      'total', count(prt.id),
      'resolved', count(prt.id) filter (where prt.item_status in ('resolved', 'processing', 'completed')),
      'review_recommended', count(prt.id) filter (where prt.item_status = 'review_recommended'),
      'not_found', count(prt.id) filter (where prt.item_status = 'not_found'),
      'duplicate', count(prt.id) filter (where prt.item_status = 'duplicate'),
      'duration_exceeded', count(prt.id) filter (where prt.item_status = 'duration_exceeded'),
      'playlist_limit_exceeded', count(prt.id) filter (where prt.item_status = 'playlist_limit_exceeded'),
      'failed', count(prt.id) filter (where prt.item_status = 'failed')
    ),
    'items', coalesce(jsonb_agg(jsonb_build_object(
      'id', prt.id, 'position', prt.position, 'status', prt.item_status,
      'spotify_track_id', prt.source_track_id, 'spotify_url', prt.source_url,
      'title', prt.title, 'artists', prt.artists, 'album', prt.album,
      'duration_ms', prt.duration_ms, 'youtube_url', prt.youtube_url,
      'youtube_video_id', prt.youtube_video_id,
      'youtube_title', t.title, 'youtube_artist', t.artist,
      'youtube_channel', coalesce(prt.metadata ->> 'youtube_channel', t.metadata ->> 'youtube_channel'),
      'youtube_duration_ms', coalesce(t.duration_ms, nullif(prt.metadata ->> 'youtube_duration_ms', '')::integer),
      'duration_difference_ms', case when prt.duration_ms is not null
        and coalesce(t.duration_ms, nullif(prt.metadata ->> 'youtube_duration_ms', '')::integer) is not null
        then abs(prt.duration_ms - coalesce(t.duration_ms, nullif(prt.metadata ->> 'youtube_duration_ms', '')::integer)) end,
      'match_confidence', prt.match_confidence, 'review_reason', prt.error_message,
      'error_message', prt.error_message
    ) order by prt.position, prt.id) filter (where prt.id is not null), '[]'::jsonb)
  ) into v_result
  from public.playlist_request_tracks prt
  left join public.tracks t on t.id = prt.track_id
  left join public.operators o on o.id = v_playlist.created_by_operator_id
  left join public.units u on u.id = v_playlist.unit_id
  where prt.playlist_request_id = v_request.id
  group by o.display_name, u.name, u.city, u.state;

  return coalesce(v_result, jsonb_build_object('request', jsonb_build_object('id', v_request.id)));
end;
$$;

create or replace function public.admin_manage_playlist_request_item(
  p_request_id uuid,
  p_action text,
  p_item_id uuid default null,
  p_youtube_url text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.playlist_requests%rowtype;
  v_playlist public.playlists%rowtype;
  v_item public.playlist_request_tracks%rowtype;
  v_parsed jsonb;
  v_job_id uuid;
begin
  if not public.is_admin() then raise exception 'forbidden'; end if;
  if p_action not in ('ignore', 'replace_youtube', 'retry') then raise exception 'invalid_action'; end if;

  select * into v_request from public.playlist_requests where id = p_request_id for update;
  if v_request.id is null then raise exception 'playlist_request_not_found'; end if;
  select * into v_playlist from public.playlists where id = v_request.playlist_id for update;
  if v_playlist.id is null then raise exception 'playlist_not_found'; end if;
  if not public.is_superadmin() and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception 'forbidden';
  end if;

  if p_item_id is null then raise exception 'playlist_request_item_required'; end if;
  select * into v_item from public.playlist_request_tracks
   where id = p_item_id and playlist_request_id = v_request.id for update;
  if v_item.id is null then raise exception 'playlist_request_item_not_found'; end if;

  if p_action = 'ignore' then
    update public.playlist_request_tracks
       set item_status = 'skipped', error_message = 'Ignorada pelo administrador.', updated_at = now()
     where id = v_item.id;
    return null;
  end if;

  if p_action = 'replace_youtube' then
    v_parsed := public.parse_music_url(p_youtube_url);
    if v_parsed is null
       or v_parsed ->> 'source' <> 'youtube'
       or v_parsed ->> 'resourceType' <> 'video' then
      raise exception 'invalid_youtube_video_url';
    end if;
    update public.playlist_request_tracks
       set youtube_url = v_parsed ->> 'normalizedUrl',
           youtube_video_id = v_parsed ->> 'resourceId',
           item_status = 'resolved', error_message = null,
           metadata = metadata || jsonb_build_object('manual_replacement', true), updated_at = now()
     where id = v_item.id
     returning * into v_item;
  end if;

  if p_action = 'retry' and coalesce(v_item.youtube_url, '') = '' then
    raise exception 'item_without_youtube_result';
  end if;
  if p_action = 'retry' then
    update public.playlist_request_tracks
       set item_status = 'processing', error_message = null, updated_at = now()
     where id = v_item.id returning * into v_item;
  end if;

  if coalesce(v_item.youtube_url, '') = '' then raise exception 'item_without_youtube_result'; end if;
  if exists (select 1 from public.download_jobs where playlist_id = v_playlist.id and status in ('queued', 'running')) then
    raise exception 'import_already_running';
  end if;

  insert into public.download_jobs (
    playlist_id, playlist_request_id, source_url, status, attempts, mode, replace_youtube_id, created_at, updated_at
  ) values (
    v_playlist.id, v_request.id, v_item.youtube_url, 'queued', 0, 'single_track', v_item.youtube_video_id, now(), now()
  ) returning id into v_job_id;
  return v_job_id;
end;
$$;

revoke all on function public.admin_playlist_request_detail(uuid) from public, anon;
grant execute on function public.admin_playlist_request_detail(uuid) to authenticated;
revoke all on function public.admin_manage_playlist_request_item(uuid, text, uuid, text) from public, anon;
grant execute on function public.admin_manage_playlist_request_item(uuid, text, uuid, text) to authenticated;

commit;
