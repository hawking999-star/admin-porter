begin;

-- A cota pertence ao dono da playlist, nao a sessao que executa o worker.
-- Isso mantem a mesma decisao para App, Admin, triggers e service_role.
create or replace function private.principal_track_limit_for_operator(p_operator_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select case when exists (
    select 1
      from public.operators operator_account
      join public.admin_users admin_account
        on admin_account.auth_user_id = operator_account.auth_user_id
     where operator_account.id = p_operator_id
       and operator_account.active is true
       and admin_account.active is true
       and admin_account.role = 'superadmin'
  ) then 400 else 170 end
$$;

create or replace function private.principal_track_limit_for_playlist(p_playlist_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      select private.principal_track_limit_for_operator(playlist.created_by_operator_id)
        from public.playlists playlist
       where playlist.id = p_playlist_id
    ),
    170
  )
$$;

revoke all on function private.principal_track_limit_for_operator(uuid)
  from public, anon, authenticated;
revoke all on function private.principal_track_limit_for_playlist(uuid)
  from public, anon, authenticated;

create or replace function private.enforce_principal_track_limit()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_type text;
  v_count integer;
  v_limit integer;
begin
  select playlist.type
    into v_type
    from public.playlists playlist
   where playlist.id = new.playlist_id
   for update;
  if not found then return new; end if;

  if v_type = 'principal' then
    v_limit := private.principal_track_limit_for_playlist(new.playlist_id);
    select count(*) into v_count
      from public.playlist_tracks
     where playlist_id = new.playlist_id;
    if v_count >= v_limit then
      raise exception 'PRINCIPAL_TRACK_LIMIT_REACHED'
        using errcode = 'check_violation',
              detail = pg_catalog.format('A playlist Principal aceita no maximo %s faixas.', v_limit);
    end if;
  end if;
  return new;
end;
$$;

revoke all on function private.enforce_principal_track_limit()
  from public, anon, authenticated;

-- Contrato consumido pelo App: devolve a cota efetiva da conta autenticada.
create or replace function public.get_my_playlists(p_request jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_req text := p_request->>'request_id';
  v_op public.operators%rowtype;
  v_rows jsonb;
  v_sec integer;
  v_principal_limit integer;
begin
  select * into v_op
    from public.operators
   where auth_user_id = v_uid and active is true;
  if v_uid is null or not found then
    return public._app_envelope(v_req, false, null, jsonb_build_object('code', 'FORBIDDEN'), null);
  end if;

  v_principal_limit := private.principal_track_limit_for_operator(v_op.id);
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', p.id,
    'type', p.type,
    'name', p.name,
    'status', p.status,
    'approval_status', p.approval_status,
    'revision', p.revision,
    'capabilities', private.operator_playlist_capabilities(p.type, p.status)
  ) order by p.type, p.created_at), '[]'::jsonb)
    into v_rows
    from public.playlists p
   where p.created_by_operator_id = v_op.id;

  select count(*) into v_sec
    from public.playlists
   where created_by_operator_id = v_op.id
     and type = 'secondary'
     and status <> 'archived'
     and approval_status <> 'rejected';

  return public._app_envelope(
    v_req,
    true,
    jsonb_build_object(
      'playlists', v_rows,
      'capabilities', jsonb_build_object('can_create_secondary', v_sec < 2, 'can_submit_principal', true),
      'secondary_count', v_sec,
      'secondary_limit', 2,
      'principal_track_limit', v_principal_limit,
      'track_duration_limit_seconds', 960
    ),
    null,
    jsonb_build_object(
      'secondary_count', v_sec,
      'secondary_limit', 2,
      'principal_track_limit', v_principal_limit,
      'track_duration_limit_seconds', 960
    )
  );
end;
$$;

revoke all on function public.get_my_playlists(jsonb) from public, anon;
grant execute on function public.get_my_playlists(jsonb) to authenticated;

-- RPC interna para o Railway descobrir a cota da playlist mesmo usando service_role.
create or replace function public.worker_get_principal_track_limit(p_playlist_id uuid)
returns integer
language sql
stable
security definer
set search_path = ''
as $$
  select private.principal_track_limit_for_playlist(p_playlist_id)
$$;

revoke all on function public.worker_get_principal_track_limit(uuid)
  from public, anon, authenticated;
grant execute on function public.worker_get_principal_track_limit(uuid)
  to service_role;

-- O upload manual do Admin reserva vagas usando a mesma cota da playlist.
create or replace function public.admin_prepare_library_music_upload(
  p_playlist_id uuid,
  p_filename text,
  p_mime text,
  p_size_bytes bigint,
  p_rights_statement text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_playlist public.playlists%rowtype;
  v_admin public.admin_users%rowtype;
  v_session private.music_upload_sessions%rowtype;
  v_extension text;
  v_link_count integer;
  v_pending_count integer;
  v_principal_limit integer;
begin
  select * into v_playlist
    from public.playlists
   where id = p_playlist_id
   for update;
  if v_playlist.id is null or v_playlist.status = 'archived' then
    raise exception 'music_upload_playlist_not_found';
  end if;

  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    v_playlist.unit_id
  );

  if p_size_bytes is null or p_size_bytes < 1 or p_size_bytes > 52428800 then raise exception 'music_upload_size_invalid'; end if;
  if lower(coalesce(p_mime, '')) not in (
    'audio/mpeg', 'audio/mp4', 'audio/x-m4a', 'audio/aac',
    'audio/ogg', 'audio/wav', 'audio/x-wav', 'audio/vnd.wave'
  ) then raise exception 'music_upload_mime_invalid'; end if;
  v_extension := lower(substring(coalesce(p_filename, '') from '\.([a-z0-9]+)$'));
  if v_extension not in ('mp3', 'm4a', 'aac', 'ogg', 'wav') then raise exception 'music_upload_extension_invalid'; end if;
  if length(btrim(coalesce(p_rights_statement, ''))) < 10 then raise exception 'music_upload_rights_required'; end if;

  select count(*) into v_link_count
    from public.playlist_tracks link
    join public.tracks track on track.id = link.track_id
   where link.playlist_id = v_playlist.id
     and track.status = 'available';
  select count(*) into v_pending_count
    from private.music_upload_sessions upload
   where upload.playlist_id = v_playlist.id
     and upload.request_item_id is null
     and upload.status in ('prepared', 'processing');
  v_principal_limit := private.principal_track_limit_for_playlist(v_playlist.id);
  if v_playlist.type = 'principal' and v_link_count + v_pending_count >= v_principal_limit then
    raise exception 'PRINCIPAL_TRACK_LIMIT_REACHED';
  end if;

  insert into private.music_upload_sessions (
    playlist_id, playlist_request_id, request_item_id, admin_user_id,
    original_filename, declared_mime, declared_size_bytes,
    rights_attested, rights_statement, staging_object_key, expires_at
  ) values (
    v_playlist.id, null, null, v_admin.id,
    left(p_filename, 255), lower(p_mime), p_size_bytes,
    true, left(btrim(p_rights_statement), 1000),
    'music-uploads/staging/' || pg_catalog.encode(extensions.gen_random_bytes(24), 'hex') || '.' || v_extension,
    pg_catalog.now() + interval '15 minutes'
  ) returning * into v_session;

  insert into public.admin_audit_logs (admin_user_id, action, entity_type, entity_id, after_data)
  values (
    v_admin.id, 'library_music_upload_prepared', 'playlist', v_playlist.id,
    pg_catalog.jsonb_build_object(
      'session_id', v_session.id,
      'filename', left(p_filename, 255),
      'mime', lower(p_mime),
      'size_bytes', p_size_bytes,
      'rights_statement', left(btrim(p_rights_statement), 1000),
      'principal_track_limit', v_principal_limit
    )
  );

  return pg_catalog.jsonb_build_object(
    'session_id', v_session.id,
    'staging_object_key', v_session.staging_object_key,
    'expires_at', v_session.expires_at,
    'declared_mime', v_session.declared_mime,
    'declared_size_bytes', v_session.declared_size_bytes,
    'principal_track_limit', v_principal_limit
  );
end;
$$;

revoke all on function public.admin_prepare_library_music_upload(uuid, text, text, bigint, text)
  from public, anon;
grant execute on function public.admin_prepare_library_music_upload(uuid, text, text, bigint, text)
  to authenticated;

-- Uploads anexados pelo worker tambem respeitam a cota baseada no dono.
create or replace function public.worker_attach_music_upload_track(
  p_task_id uuid,
  p_track_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task private.music_import_tasks%rowtype;
  v_item public.playlist_request_tracks%rowtype;
  v_playlist public.playlists%rowtype;
  v_old_link public.playlist_tracks%rowtype;
  v_new_link public.playlist_tracks%rowtype;
  v_position integer;
  v_count integer;
  v_principal_limit integer;
begin
  select * into v_task
    from private.music_import_tasks
   where id = p_task_id and task_kind = 'upload'
   for update;
  if v_task.id is null then raise exception 'music_upload_task_not_found'; end if;
  select * into v_playlist from public.playlists where id = v_task.playlist_id for update;
  if v_playlist.id is null or v_playlist.status = 'archived' then raise exception 'music_upload_playlist_not_found'; end if;
  perform 1 from public.tracks where id = p_track_id and status = 'available' for share;
  if not found then raise exception 'TRACK_NOT_AVAILABLE'; end if;

  select * into v_new_link
    from public.playlist_tracks
   where playlist_id = v_playlist.id and track_id = p_track_id
   limit 1 for update;

  if v_task.request_item_id is null then
    if v_new_link.id is not null then
      return pg_catalog.jsonb_build_object('playlist_track_id', v_new_link.id, 'position', v_new_link.position, 'duplicate', true);
    end if;
    select count(*) into v_count
      from public.playlist_tracks link
      join public.tracks track on track.id = link.track_id
     where link.playlist_id = v_playlist.id and track.status = 'available';
    v_principal_limit := private.principal_track_limit_for_playlist(v_playlist.id);
    if v_playlist.type = 'principal' and v_count >= v_principal_limit then raise exception 'PRINCIPAL_TRACK_LIMIT_REACHED'; end if;
    select coalesce(max(position), 0) + 1 into v_position
      from public.playlist_tracks where playlist_id = v_playlist.id;
    insert into public.playlist_tracks (playlist_id, track_id, position, added_by_type)
    values (v_playlist.id, p_track_id, v_position, 'admin_upload')
    returning * into v_new_link;
    return pg_catalog.jsonb_build_object('playlist_track_id', v_new_link.id, 'position', v_position, 'duplicate', false);
  end if;

  select * into v_item
    from public.playlist_request_tracks
   where id = v_task.request_item_id
   for update;
  if v_item.id is null then raise exception 'music_upload_item_not_found'; end if;
  v_position := greatest(coalesce(v_item.position, 0), 0);
  if v_item.track_id is not null then
    select * into v_old_link
      from public.playlist_tracks
     where playlist_id = v_playlist.id and track_id = v_item.track_id
     limit 1 for update;
  end if;

  if v_old_link.id is not null and v_new_link.id is not null and v_old_link.id <> v_new_link.id then
    v_position := v_old_link.position;
    delete from public.playlist_tracks where id = v_old_link.id;
    update public.playlist_tracks set position = v_position, updated_at = pg_catalog.now() where id = v_new_link.id;
  elsif v_old_link.id is not null and v_item.track_id is distinct from p_track_id then
    v_position := v_old_link.position;
    update public.playlist_tracks
       set track_id = p_track_id, added_by_type = 'admin_upload', updated_at = pg_catalog.now()
     where id = v_old_link.id
    returning * into v_new_link;
  elsif v_new_link.id is not null then
    if v_position > 0 and v_new_link.position <> v_position then
      update public.playlist_tracks set position = v_position, updated_at = pg_catalog.now() where id = v_new_link.id;
    else
      v_position := v_new_link.position;
    end if;
  else
    if v_position = 0 then
      select coalesce(max(position), 0) + 1 into v_position from public.playlist_tracks where playlist_id = v_playlist.id;
    end if;
    insert into public.playlist_tracks (playlist_id, track_id, position, added_by_type)
    values (v_playlist.id, p_track_id, v_position, 'admin_upload')
    returning * into v_new_link;
  end if;

  return pg_catalog.jsonb_build_object('playlist_track_id', v_new_link.id, 'position', v_position, 'duplicate', false);
end;
$$;

revoke all on function public.worker_attach_music_upload_track(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.worker_attach_music_upload_track(uuid, uuid)
  to service_role;

-- Acoes em lote nao podem enfileirar mais itens que a cota da playlist alvo.
create or replace function public.admin_accept_playlist_request_items(
  p_request_id uuid,
  p_item_ids uuid[]
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_item_id uuid;
  v_job_id uuid;
  v_job_ids uuid[] := array[]::uuid[];
  v_requested_count integer := cardinality(p_item_ids);
  v_playlist_id uuid;
  v_unit_id uuid;
  v_principal_limit integer;
begin
  if p_request_id is null then raise exception 'playlist_request_required'; end if;
  if v_requested_count is null or v_requested_count = 0 then raise exception 'playlist_request_items_required'; end if;

  select request.playlist_id, playlist.unit_id into v_playlist_id, v_unit_id
    from public.playlist_requests request
    join public.playlists playlist on playlist.id = request.playlist_id
   where request.id = p_request_id;
  if v_playlist_id is null then raise exception 'playlist_request_not_found'; end if;
  perform private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    v_unit_id
  );
  v_principal_limit := private.principal_track_limit_for_playlist(v_playlist_id);
  if v_requested_count > v_principal_limit then raise exception 'playlist_request_items_limit_exceeded'; end if;
  if exists (select 1 from pg_catalog.unnest(p_item_ids) item_id where item_id is null) then
    raise exception 'playlist_request_item_required';
  end if;

  for v_item_id in select distinct item_id from pg_catalog.unnest(p_item_ids) item_id loop
    v_job_id := public.admin_manage_playlist_request_item(p_request_id, 'retry', v_item_id, null);
    v_job_ids := pg_catalog.array_append(v_job_ids, v_job_id);
  end loop;

  return pg_catalog.jsonb_build_object('queued', cardinality(v_job_ids), 'job_ids', to_jsonb(v_job_ids));
end;
$$;

revoke all on function public.admin_accept_playlist_request_items(uuid, uuid[])
  from public, anon;
grant execute on function public.admin_accept_playlist_request_items(uuid, uuid[])
  to authenticated;

-- Mensagens antigas gravavam "170" no texto e ficariam incorretas para Super Admin.
create or replace function public.playlist_request_item_operator_message(p_status text)
returns text
language sql
immutable
set search_path = ''
as $$
  select case p_status
    when 'review_recommended' then 'Esta música parece ser uma versão diferente e precisa de revisão.'
    when 'not_found' then 'Não foi possível localizar esta música no YouTube.'
    when 'duration_exceeded' then 'A música ultrapassa a duração máxima de 16 minutos.'
    when 'playlist_limit_exceeded' then 'A playlist ultrapassa o limite de músicas permitido para esta conta.'
    when 'failed' then 'O serviço de importação está temporariamente indisponível.'
    when 'duplicate' then 'Esta música já está na playlist.'
    when 'skipped' then 'Esta música não será adicionada à playlist.'
    else null
  end
$$;

revoke all on function public.playlist_request_item_operator_message(text)
  from public, anon, authenticated;

alter function public.playlist_request_operator_messages(uuid)
  rename to playlist_request_operator_messages_limit170_impl;
revoke all on function public.playlist_request_operator_messages_limit170_impl(uuid)
  from public, anon, authenticated;

create function public.playlist_request_operator_messages(p_request_id uuid)
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    pg_catalog.jsonb_agg(
      case
        when message.value = pg_catalog.to_jsonb('A playlist ultrapassa o limite de 170 músicas.'::text)
          then pg_catalog.to_jsonb('A playlist ultrapassa o limite de músicas permitido para esta conta.'::text)
        else message.value
      end
      order by message.ordinality
    ),
    '[]'::jsonb
  )
  from pg_catalog.jsonb_array_elements(
    public.playlist_request_operator_messages_limit170_impl(p_request_id)
  ) with ordinality as message(value, ordinality)
$$;

revoke all on function public.playlist_request_operator_messages(uuid)
  from public, anon, authenticated;

commit;
