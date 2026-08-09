begin;

-- Request history remains auditable, but an Admin can hide completed entries
-- from both the Admin library and the operator App without deleting records.
alter table public.playlist_requests
  add column if not exists dismissed_at timestamptz,
  add column if not exists dismissed_by_admin_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_catalog.pg_constraint
     where conname = 'playlist_requests_dismissed_by_admin_id_fkey'
       and conrelid = 'public.playlist_requests'::pg_catalog.regclass
  ) then
    alter table public.playlist_requests
      add constraint playlist_requests_dismissed_by_admin_id_fkey
      foreign key (dismissed_by_admin_id)
      references public.admin_users(id)
      on delete set null;
  end if;
end;
$$;

create index if not exists playlist_requests_visible_operator_created_idx
  on public.playlist_requests (operator_id, created_at desc)
  where dismissed_at is null;

-- Library uploads do not need to impersonate a playlist request item.
alter table private.music_upload_sessions
  alter column request_item_id drop not null;

-- The original upload RPC used pgcrypto with an empty search_path.
alter function public.admin_prepare_music_upload(uuid, text, text, bigint, text)
  set search_path = pg_catalog, extensions;

create or replace function private.reconcile_playlist_request_import(
  p_request_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request public.playlist_requests%rowtype;
  v_job public.download_jobs%rowtype;
  v_total integer := 0;
  v_completed integer := 0;
  v_failed integer := 0;
  v_not_found integer := 0;
  v_review integer := 0;
  v_active integer := 0;
  v_skipped integer := 0;
  v_message text;
  v_is_latest boolean := false;
begin
  select * into v_request
    from public.playlist_requests
   where id = p_request_id;
  if v_request.id is null then return null; end if;

  select * into v_job
    from public.download_jobs
   where playlist_request_id = v_request.id
     and coalesce(mode, 'playlist') = 'playlist'
   order by created_at desc, id desc
   limit 1
   for update;
  if v_job.id is null then return null; end if;

  select
    count(*)::integer,
    count(*) filter (where item_status = 'completed')::integer,
    count(*) filter (where item_status = 'failed')::integer,
    count(*) filter (where item_status = 'not_found')::integer,
    count(*) filter (where item_status = 'review_recommended')::integer,
    count(*) filter (where item_status in ('pending', 'resolving', 'resolved', 'processing'))::integer,
    count(*) filter (where item_status in ('duplicate', 'skipped', 'duration_exceeded', 'playlist_limit_exceeded'))::integer
  into v_total, v_completed, v_failed, v_not_found, v_review, v_active, v_skipped
  from public.playlist_request_tracks
  where playlist_request_id = v_request.id
    and download_job_id = v_job.id;

  if v_total = 0 or v_active > 0 then
    return pg_catalog.jsonb_build_object(
      'request_id', v_request.id,
      'job_id', v_job.id,
      'state', 'processing',
      'active', v_active
    );
  end if;

  if v_review > 0 then
    v_message := v_review || ' música(s) aguardando revisão do resultado do YouTube.';
  elsif v_failed + v_not_found > 0 then
    v_message := (v_failed + v_not_found) || ' música(s) não foram importadas.';
  else
    v_message := null;
  end if;

  update public.download_jobs
     set status = case when v_review + v_failed + v_not_found > 0 then 'partial' else 'done' end,
         operational_status = case when v_review + v_failed + v_not_found > 0
           then 'completed_with_issues' else 'completed' end,
         total = v_total,
         completed = v_completed,
         failed = v_failed + v_not_found,
         error_code = case
           when v_review > 0 then 'REVIEW_RECOMMENDED'
           when v_failed + v_not_found > 0 then 'IMPORT_PARTIAL'
           else null
         end,
         error_message = v_message,
         error = v_message,
         error_details = case when v_message is null then null else pg_catalog.jsonb_build_object(
           'effective_summary', pg_catalog.jsonb_build_object(
             'total', v_total,
             'imported', v_completed,
             'failed', v_failed,
             'not_found', v_not_found,
             'review', v_review,
             'skipped', v_skipped,
             'active', 0
           )
         ) end,
         finished_at = coalesce(finished_at, pg_catalog.now()),
         updated_at = pg_catalog.now()
   where id = v_job.id;

  select v_request.id = latest.id into v_is_latest
    from lateral (
      select id
        from public.playlist_requests
       where playlist_id = v_request.playlist_id
       order by created_at desc, id desc
       limit 1
    ) latest;

  if v_is_latest then
    update public.playlists
       set import_status = case when v_message is null then 'success' else 'failed' end,
           error_code = case
             when v_review > 0 then 'REVIEW_RECOMMENDED'
             when v_failed + v_not_found > 0 then 'IMPORT_PARTIAL'
             else null
           end,
           error_message = v_message,
           error_details = case when v_message is null then null else pg_catalog.jsonb_build_object(
             'effective_summary', pg_catalog.jsonb_build_object(
               'total', v_total,
               'imported', v_completed,
               'failed', v_failed,
               'not_found', v_not_found,
               'review', v_review,
               'skipped', v_skipped,
               'active', 0
             )
           ) end,
           last_error_at = case when v_message is null then null else pg_catalog.now() end,
           import_finished_at = pg_catalog.now(),
           updated_at = pg_catalog.now()
     where id = v_request.playlist_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'request_id', v_request.id,
    'job_id', v_job.id,
    'state', case when v_message is null then 'completed' else 'completed_with_issues' end,
    'total', v_total,
    'review', v_review,
    'failed', v_failed + v_not_found
  );
end;
$$;

revoke all on function private.reconcile_playlist_request_import(uuid)
  from public, anon, authenticated;

create or replace function private.trg_reconcile_playlist_request_import()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform private.reconcile_playlist_request_import(new.playlist_request_id);
  return new;
end;
$$;

drop trigger if exists trg_reconcile_playlist_request_import
  on public.playlist_request_tracks;
create trigger trg_reconcile_playlist_request_import
after insert or update of item_status, track_id
on public.playlist_request_tracks
for each row
execute function private.trg_reconcile_playlist_request_import();

do $$
declare v_request record;
begin
  for v_request in
    select distinct on (playlist_id) id
      from public.playlist_requests
     order by playlist_id, created_at desc, id desc
  loop
    perform private.reconcile_playlist_request_import(v_request.id);
  end loop;
end;
$$;

create or replace function public.admin_clear_operator_playlist_requests(
  p_operator_id uuid,
  p_playlist_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_operator public.operators%rowtype;
  v_admin public.admin_users%rowtype;
  v_ids uuid[] := '{}'::uuid[];
begin
  select * into v_operator
    from public.operators
   where id = p_operator_id;
  if v_operator.id is null then raise exception 'operador_nao_encontrado'; end if;

  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    v_operator.unit_id
  );

  if p_playlist_id is not null and not exists (
    select 1 from public.playlists
     where id = p_playlist_id
       and created_by_operator_id = v_operator.id
  ) then
    raise exception 'playlist_fora_do_operador';
  end if;

  with dismissed as (
    update public.playlist_requests request
       set dismissed_at = pg_catalog.now(),
           dismissed_by_admin_id = v_admin.id,
           updated_at = pg_catalog.now()
     where request.operator_id = v_operator.id
       and (p_playlist_id is null or request.playlist_id = p_playlist_id)
       and request.dismissed_at is null
       and request.status <> 'pending'
    returning request.id
  )
  select coalesce(pg_catalog.array_agg(id), '{}'::uuid[]) into v_ids
    from dismissed;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data
  ) values (
    v_admin.id, 'playlist_requests_cleared', 'operator', v_operator.id,
    pg_catalog.jsonb_build_object(
      'playlist_id', p_playlist_id,
      'request_ids', pg_catalog.to_jsonb(v_ids),
      'cleared_count', pg_catalog.cardinality(v_ids)
    )
  );

  return pg_catalog.jsonb_build_object(
    'success', true,
    'cleared_count', pg_catalog.cardinality(v_ids),
    'pending_preserved', (
      select count(*) from public.playlist_requests request
       where request.operator_id = v_operator.id
         and (p_playlist_id is null or request.playlist_id = p_playlist_id)
         and request.dismissed_at is null
         and request.status = 'pending'
    )
  );
end;
$$;

revoke all on function public.admin_clear_operator_playlist_requests(uuid, uuid)
  from public, anon;
grant execute on function public.admin_clear_operator_playlist_requests(uuid, uuid)
  to authenticated;

-- Keep historical wrappers intact and filter only the public response.
alter function public.get_my_playlist_requests(jsonb)
  rename to get_my_playlist_requests_before_admin_dismissal_impl;
revoke all on function public.get_my_playlist_requests_before_admin_dismissal_impl(jsonb)
  from public, anon, authenticated;

create function public.get_my_playlist_requests(p_request jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_payload jsonb; v_rows jsonb;
begin
  v_payload := public.get_my_playlist_requests_before_admin_dismissal_impl(p_request);
  if coalesce((v_payload->>'success')::boolean, false) is not true then return v_payload; end if;

  select coalesce(pg_catalog.jsonb_agg(request_row order by request_row->>'created_at' desc), '[]'::jsonb)
    into v_rows
    from pg_catalog.jsonb_array_elements(coalesce(v_payload#>'{data,requests}', '[]'::jsonb)) request_row
    join public.playlist_requests request
      on request.id = (request_row->>'id')::uuid
   where request.dismissed_at is null;

  return pg_catalog.jsonb_set(v_payload, '{data,requests}', v_rows, true);
end;
$$;

revoke all on function public.get_my_playlist_requests(jsonb)
  from public, anon;
grant execute on function public.get_my_playlist_requests(jsonb)
  to authenticated;

alter function public.get_my_playlists(jsonb)
  rename to get_my_playlists_before_library_counts_impl;
revoke all on function public.get_my_playlists_before_library_counts_impl(jsonb)
  from public, anon, authenticated;

create function public.get_my_playlists(p_request jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_payload jsonb; v_rows jsonb;
begin
  v_payload := public.get_my_playlists_before_library_counts_impl(p_request);
  if coalesce((v_payload->>'success')::boolean, false) is not true then return v_payload; end if;

  select coalesce(pg_catalog.jsonb_agg(
    playlist_row || pg_catalog.jsonb_build_object(
      'track_count', (
        select count(*) from public.playlist_tracks link
        join public.tracks track on track.id = link.track_id
        where link.playlist_id = (playlist_row->>'id')::uuid
          and track.status = 'available'
      ),
      'tracks_updated_at', (
        select max(greatest(link.updated_at, track.updated_at))
        from public.playlist_tracks link
        join public.tracks track on track.id = link.track_id
        where link.playlist_id = (playlist_row->>'id')::uuid
          and track.status = 'available'
      )
    ) order by playlist_row->>'type', playlist_row->>'name'
  ), '[]'::jsonb) into v_rows
  from pg_catalog.jsonb_array_elements(coalesce(v_payload#>'{data,playlists}', '[]'::jsonb)) playlist_row;

  return pg_catalog.jsonb_set(v_payload, '{data,playlists}', v_rows, true);
end;
$$;

revoke all on function public.get_my_playlists(jsonb)
  from public, anon;
grant execute on function public.get_my_playlists(jsonb)
  to authenticated;

alter function public.admin_music_library_page(integer, integer, text)
  rename to admin_music_library_page_before_request_cleanup_impl;
revoke all on function public.admin_music_library_page_before_request_cleanup_impl(integer, integer, text)
  from public, anon, authenticated;

create function public.admin_music_library_page(
  p_limit integer default 12,
  p_offset integer default 0,
  p_search text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare v_payload jsonb; v_rows jsonb;
begin
  v_payload := public.admin_music_library_page_before_request_cleanup_impl(p_limit, p_offset, p_search);

  select coalesce(pg_catalog.jsonb_agg(
    operator_row || pg_catalog.jsonb_build_object(
      'playlists', coalesce((
        select pg_catalog.jsonb_agg(
          playlist_row || pg_catalog.jsonb_build_object(
            'track_count', (
              select count(*) from public.playlist_tracks link
              join public.tracks track on track.id = link.track_id
              where link.playlist_id = (playlist_row->>'id')::uuid
                and track.status = 'available'
            ),
            'tracks', coalesce((
              select pg_catalog.jsonb_agg(track_row order by (track_row->>'position')::integer)
                from pg_catalog.jsonb_array_elements(coalesce(playlist_row->'tracks', '[]'::jsonb)) track_row
               where track_row->>'status' = 'available'
            ), '[]'::jsonb),
            'pending_upload_count', (
              select count(*) from private.music_import_tasks task
               where task.playlist_id = (playlist_row->>'id')::uuid
                 and task.task_kind = 'upload'
                 and task.status in ('queued', 'processing', 'waiting_provider')
            )
          ) order by case playlist_row->>'type' when 'principal' then 0 else 1 end, playlist_row->>'name')
        from pg_catalog.jsonb_array_elements(coalesce(operator_row->'playlists', '[]'::jsonb)) playlist_row
      ), '[]'::jsonb),
      'request_history', coalesce((
        select pg_catalog.jsonb_agg(request_row order by request_row->>'submitted_at' desc)
          from pg_catalog.jsonb_array_elements(coalesce(operator_row->'request_history', '[]'::jsonb)) request_row
          join public.playlist_requests request
            on request.id = (request_row->>'id')::uuid
         where request.dismissed_at is null
      ), '[]'::jsonb)
    ) order by operator_row->>'display_name'
  ), '[]'::jsonb) into v_rows
  from pg_catalog.jsonb_array_elements(coalesce(v_payload->'rows', '[]'::jsonb)) operator_row;

  return pg_catalog.jsonb_set(v_payload, '{rows}', v_rows, true);
end;
$$;

revoke all on function public.admin_music_library_page(integer, integer, text)
  from public, anon;
grant execute on function public.admin_music_library_page(integer, integer, text)
  to authenticated;

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
  if v_playlist.type = 'principal' and v_link_count + v_pending_count >= 170 then
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
      'rights_statement', left(btrim(p_rights_statement), 1000)
    )
  );

  return pg_catalog.jsonb_build_object(
    'session_id', v_session.id,
    'staging_object_key', v_session.staging_object_key,
    'expires_at', v_session.expires_at,
    'declared_mime', v_session.declared_mime,
    'declared_size_bytes', v_session.declared_size_bytes
  );
end;
$$;

revoke all on function public.admin_prepare_library_music_upload(uuid, text, text, bigint, text)
  from public, anon;
grant execute on function public.admin_prepare_library_music_upload(uuid, text, text, bigint, text)
  to authenticated;

create or replace function public.worker_get_music_upload_task(p_task_id uuid)
returns jsonb
language sql
security definer
set search_path = ''
as $$
  select pg_catalog.jsonb_build_object(
    'task_id', task.id, 'playlist_id', task.playlist_id,
    'playlist_request_id', task.playlist_request_id,
    'request_item_id', task.request_item_id,
    'session_id', upload.id, 'staging_object_key', upload.staging_object_key,
    'original_filename', upload.original_filename,
    'declared_mime', upload.declared_mime,
    'declared_size_bytes', upload.declared_size_bytes,
    'rights_statement', upload.rights_statement,
    'admin_user_id', upload.admin_user_id,
    'position', item.position,
    'title', coalesce(item.title, pg_catalog.regexp_replace(upload.original_filename, '\.[^.]+$', '')),
    'artists', coalesce(item.artists, '[]'::jsonb)
  )
  from private.music_import_tasks task
  join private.music_upload_sessions upload on upload.id = task.upload_session_id
  left join public.playlist_request_tracks item on item.id = task.request_item_id
  where task.id = p_task_id and task.task_kind = 'upload'
$$;

revoke all on function public.worker_get_music_upload_task(uuid)
  from public, anon, authenticated;
grant execute on function public.worker_get_music_upload_task(uuid)
  to service_role;

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
      from public.playlist_tracks link join public.tracks track on track.id = link.track_id
     where link.playlist_id = v_playlist.id and track.status = 'available';
    if v_playlist.type = 'principal' and v_count >= 170 then raise exception 'PRINCIPAL_TRACK_LIMIT_REACHED'; end if;
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

commit;
