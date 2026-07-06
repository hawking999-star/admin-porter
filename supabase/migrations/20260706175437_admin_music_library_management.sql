create or replace function public.admin_music_library()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_rows jsonb;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select coalesce(jsonb_agg(operator_row order by operator_row->>'display_name'), '[]'::jsonb)
  into v_rows
  from (
    select jsonb_build_object(
      'id', o.id,
      'display_name', o.display_name,
      'username', o.username,
      'email', au.email,
      'active', o.active,
      'role', o.role,
      'unit_id', o.unit_id,
      'unit_name', u.name,
      'unit_city', u.city,
      'unit_state', u.state,
      'updated_at', o.updated_at,
      'playlists', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', p.id,
            'name', p.name,
            'type', p.type,
            'status', p.status,
            'approval_status', p.approval_status,
            'import_status', p.import_status,
            'source_url', p.source_url,
            'platform', public.playlist_source_platform(p.source_url),
            'revision', p.revision,
            'created_at', p.created_at,
            'updated_at', p.updated_at,
            'submitted_at', p.submitted_at,
            'reviewed_at', p.reviewed_at,
            'import_started_at', p.import_started_at,
            'import_finished_at', p.import_finished_at,
            'error_code', p.error_code,
            'error_message', p.error_message,
            'last_error_at', p.last_error_at,
            'track_count', coalesce((
              select count(*)
              from public.playlist_tracks pt
              join public.tracks t on t.id = pt.track_id
              where pt.playlist_id = p.id
                and t.status in ('available','processing')
            ), 0),
            'latest_job', (
              select to_jsonb(dj) - 'error_details'
              from public.download_jobs dj
              where dj.playlist_id = p.id
              order by dj.created_at desc
              limit 1
            ),
            'tracks', coalesce((
              select jsonb_agg(
                jsonb_build_object(
                  'playlist_track_id', pt.id,
                  'track_id', t.id,
                  'position', pt.position,
                  'title', t.title,
                  'artist', t.artist,
                  'duration_ms', t.duration_ms,
                  'source_url', t.metadata->>'source_url',
                  'public_url', t.metadata->>'public_url',
                  'status', t.status,
                  'added_by_type', pt.added_by_type,
                  'created_at', pt.created_at,
                  'updated_at', pt.updated_at
                )
                order by pt.position, pt.created_at
              )
              from public.playlist_tracks pt
              join public.tracks t on t.id = pt.track_id
              where pt.playlist_id = p.id
                and t.status in ('available','processing')
            ), '[]'::jsonb)
          )
          order by case p.type when 'principal' then 0 else 1 end, p.created_at
        )
        from public.playlists p
        where p.created_by_operator_id = o.id
          and p.status <> 'archived'
      ), '[]'::jsonb),
      'request_history', coalesce((
        select jsonb_agg(
          jsonb_build_object(
            'id', p2.id,
            'name', p2.name,
            'type', p2.type,
            'approval_status', p2.approval_status,
            'import_status', p2.import_status,
            'source_url', p2.source_url,
            'submitted_at', p2.submitted_at,
            'reviewed_at', p2.reviewed_at,
            'rejection_reason', p2.rejection_reason,
            'error_message', p2.error_message
          )
          order by coalesce(p2.submitted_at, p2.created_at) desc
        )
        from public.playlists p2
        where p2.created_by_operator_id = o.id
      ), '[]'::jsonb)
    ) as operator_row
    from public.operators o
    join public.units u on u.id = o.unit_id
    left join auth.users au on au.id = o.auth_user_id
    where public.is_superadmin()
       or public.admin_can_manage_operator_unit(o.unit_id)
  ) q;

  return v_rows;
end
$$;

create or replace function public.admin_rename_music_playlist(
  p_playlist uuid,
  p_name text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_before public.playlists%rowtype;
  v_name text := nullif(btrim(p_name), '');
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  if v_name is null then
    raise exception 'name_required';
  end if;

  if char_length(v_name) > 80 then
    raise exception 'name_too_long';
  end if;

  select * into v_playlist
  from public.playlists
  where id = p_playlist
  for update;

  if v_playlist.id is null then
    raise exception 'playlist_not_found';
  end if;

  if v_playlist.unit_id is not null
     and not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception 'forbidden';
  end if;

  if v_playlist.name is distinct from v_name then
    v_before := v_playlist;

    update public.playlists
    set name = v_name,
        updated_at = now(),
        revision = revision + 1
    where id = p_playlist
    returning * into v_playlist;

    insert into public.admin_audit_logs (
      admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
    )
    values (
      v_admin.id,
      'music_playlist_renamed',
      'playlist',
      p_playlist,
      jsonb_build_object('name', v_before.name),
      jsonb_build_object('name', v_name),
      now()
    );
  end if;

  return jsonb_build_object('ok', true, 'playlist_id', v_playlist.id, 'name', v_playlist.name, 'revision', v_playlist.revision);
end
$$;

create or replace function public.admin_remove_playlist_track(
  p_playlist_track uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_link record;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select
    pt.id,
    pt.playlist_id,
    pt.track_id,
    pt.position,
    p.unit_id,
    p.name as playlist_name,
    t.title as track_title
  into v_link
  from public.playlist_tracks pt
  join public.playlists p on p.id = pt.playlist_id
  join public.tracks t on t.id = pt.track_id
  where pt.id = p_playlist_track
  for update of pt;

  if v_link.id is null then
    raise exception 'playlist_track_not_found';
  end if;

  if v_link.unit_id is not null
     and not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_link.unit_id) then
    raise exception 'forbidden';
  end if;

  delete from public.playlist_tracks
  where id = p_playlist_track;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, occurred_at
  )
  values (
    v_admin.id,
    'music_playlist_track_removed',
    'playlist_track',
    p_playlist_track,
    jsonb_build_object(
      'playlist_id', v_link.playlist_id,
      'track_id', v_link.track_id,
      'position', v_link.position,
      'playlist_name', v_link.playlist_name,
      'track_title', v_link.track_title
    ),
    now()
  );

  return jsonb_build_object('ok', true, 'playlist_id', v_link.playlist_id, 'track_id', v_link.track_id);
end
$$;

create or replace function public.admin_archive_secondary_playlist(
  p_playlist uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_before public.playlists%rowtype;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select * into v_playlist
  from public.playlists
  where id = p_playlist
  for update;

  if v_playlist.id is null then
    raise exception 'playlist_not_found';
  end if;

  if v_playlist.type <> 'secondary' then
    raise exception 'cannot_archive_principal';
  end if;

  if v_playlist.unit_id is not null
     and not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception 'forbidden';
  end if;

  v_before := v_playlist;

  update public.playlists
  set status = 'archived',
      updated_at = now(),
      revision = revision + 1
  where id = p_playlist
  returning * into v_playlist;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  )
  values (
    v_admin.id,
    'music_secondary_playlist_archived',
    'playlist',
    p_playlist,
    jsonb_build_object('status', v_before.status),
    jsonb_build_object('status', v_playlist.status),
    now()
  );

  return jsonb_build_object('ok', true, 'playlist_id', v_playlist.id, 'status', v_playlist.status);
end
$$;

grant execute on function public.admin_music_library() to authenticated;
grant execute on function public.admin_rename_music_playlist(uuid, text) to authenticated;
grant execute on function public.admin_remove_playlist_track(uuid) to authenticated;
grant execute on function public.admin_archive_secondary_playlist(uuid) to authenticated;

revoke execute on function public.admin_music_library() from anon;
revoke execute on function public.admin_rename_music_playlist(uuid, text) from anon;
revoke execute on function public.admin_remove_playlist_track(uuid) from anon;
revoke execute on function public.admin_archive_secondary_playlist(uuid) from anon;
