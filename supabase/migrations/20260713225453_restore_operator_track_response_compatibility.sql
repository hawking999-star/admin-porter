-- Mantem o identificador seguro e escopado a playlist no campo oficial
-- `playlist_track_id`, mas restaura `id` como alias temporario para clientes
-- anteriores ao contrato v2. O ID global de `tracks` e a chave do R2 continuam
-- privados.
create or replace function public.get_playlist_tracks(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_req text := p_request->>'request_id';
  v_pid uuid := private.try_uuid(nullif(p_request->>'playlist_id', ''));
  v_op public.operators%rowtype;
  v_pl public.playlists%rowtype;
  v_rows jsonb;
begin
  select *
    into v_op
    from public.operators
   where auth_user_id = v_uid
     and active is true;

  if v_uid is null or not found then
    return public._app_envelope(
      v_req,
      false,
      null,
      jsonb_build_object('code', 'FORBIDDEN'),
      null
    );
  end if;

  if v_pid is null then
    return public._app_envelope(
      v_req,
      false,
      null,
      jsonb_build_object('code', 'INVALID_UUID', 'field', 'playlist_id'),
      null
    );
  end if;

  select *
    into v_pl
    from public.playlists
   where id = v_pid
     and created_by_operator_id = v_op.id;

  if not found then
    return public._app_envelope(
      v_req,
      false,
      null,
      jsonb_build_object('code', 'PLAYLIST_NOT_ALLOWED'),
      null
    );
  end if;

  select coalesce(
    jsonb_agg(
      jsonb_build_object(
        'id', pt.id,
        'playlist_track_id', pt.id,
        'title', t.title,
        'artist', t.artist,
        'duration_ms', t.duration_ms,
        'position', pt.position,
        'public_url', t.metadata->>'public_url',
        'status', t.status,
        'updated_at', t.updated_at
      )
      order by pt.position
    ),
    '[]'::jsonb
  )
    into v_rows
    from public.playlist_tracks pt
    join public.tracks t on t.id = pt.track_id
   where pt.playlist_id = v_pl.id
     and t.status = 'available';

  return public._app_envelope(
    v_req,
    true,
    jsonb_build_object(
      'playlist_id', v_pl.id,
      'playlist_revision', v_pl.revision,
      'tracks', v_rows
    ),
    null,
    null
  );
end;
$$;

revoke all on function public.get_playlist_tracks(jsonb) from public, anon;
grant execute on function public.get_playlist_tracks(jsonb) to authenticated;
