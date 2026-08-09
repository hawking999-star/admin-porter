begin;

alter table public.download_jobs
  add column if not exists playlist_request_item_id uuid;

do $$
begin
  if not exists (
    select 1
      from pg_catalog.pg_constraint
     where conname = 'download_jobs_playlist_request_item_id_fkey'
       and conrelid = 'public.download_jobs'::pg_catalog.regclass
  ) then
    alter table public.download_jobs
      add constraint download_jobs_playlist_request_item_id_fkey
      foreign key (playlist_request_item_id)
      references public.playlist_request_tracks(id)
      on delete set null;
  end if;
end;
$$;

create index if not exists download_jobs_playlist_request_item_created_idx
  on public.download_jobs (playlist_request_item_id, created_at desc)
  where playlist_request_item_id is not null;

-- The job must identify the exact request item. Matching only by YouTube ID
-- lets the capture trigger win the race and leaves the original item unchanged.
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
  v_admin public.admin_users%rowtype;
  v_request public.playlist_requests%rowtype;
  v_playlist public.playlists%rowtype;
  v_item public.playlist_request_tracks%rowtype;
  v_previous_youtube_id text;
  v_parsed jsonb;
  v_job_id uuid;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );
  if p_action not in ('ignore', 'replace_youtube', 'retry') then
    raise exception 'invalid_action';
  end if;

  select * into v_request
    from public.playlist_requests
   where id = p_request_id
   for update;
  if v_request.id is null then raise exception 'playlist_request_not_found'; end if;

  select * into v_playlist
    from public.playlists
   where id = v_request.playlist_id
   for update;
  if v_playlist.id is null then raise exception 'playlist_not_found'; end if;

  perform private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    v_playlist.unit_id
  );

  if p_item_id is null then raise exception 'playlist_request_item_required'; end if;
  select * into v_item
    from public.playlist_request_tracks
   where id = p_item_id
     and playlist_request_id = v_request.id
   for update;
  if v_item.id is null then raise exception 'playlist_request_item_not_found'; end if;

  if p_action = 'ignore' then
    update public.playlist_request_tracks
       set item_status = 'skipped',
           error_message = 'Ignorada pelo administrador.',
           locked_at = null,
           updated_at = pg_catalog.now()
     where id = v_item.id;
    return null;
  end if;

  v_previous_youtube_id := v_item.youtube_video_id;
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
           item_status = 'processing',
           error_message = null,
           last_error_code = null,
           locked_at = null,
           metadata = coalesce(metadata, '{}'::jsonb)
             || pg_catalog.jsonb_build_object('manual_replacement', true),
           updated_at = pg_catalog.now()
     where id = v_item.id
     returning * into v_item;
  elsif coalesce(v_item.youtube_url, '') = '' then
    raise exception 'item_without_youtube_result';
  else
    v_parsed := public.parse_music_url(v_item.youtube_url);
    if v_parsed is null
       or v_parsed ->> 'source' <> 'youtube'
       or v_parsed ->> 'resourceType' <> 'video' then
      raise exception 'invalid_youtube_video_url';
    end if;
    update public.playlist_request_tracks
       set youtube_url = v_parsed ->> 'normalizedUrl',
           youtube_video_id = v_parsed ->> 'resourceId',
           item_status = 'processing',
           error_message = null,
           last_error_code = null,
           locked_at = null,
           updated_at = pg_catalog.now()
     where id = v_item.id
     returning * into v_item;
  end if;

  if exists (
    select 1
      from public.download_jobs
     where playlist_id = v_playlist.id
       and status in ('queued', 'running')
       and coalesce(mode, 'playlist') <> 'single_track'
  ) then
    raise exception 'import_already_running';
  end if;

  select job.id into v_job_id
    from public.download_jobs job
   where job.playlist_request_item_id = v_item.id
     and job.mode = 'single_track'
     and job.status in ('queued', 'running')
     and job.source_url = v_item.youtube_url
   order by job.created_at desc, job.id desc
   limit 1;
  if v_job_id is not null then return v_job_id; end if;

  insert into public.download_jobs (
    playlist_id, playlist_request_id, playlist_request_item_id,
    source_url, status, attempts, mode, replace_youtube_id,
    created_at, updated_at
  ) values (
    v_playlist.id, v_request.id, v_item.id,
    v_item.youtube_url, 'queued', 0, 'single_track',
    coalesce(v_previous_youtube_id, v_item.youtube_video_id),
    pg_catalog.now(), pg_catalog.now()
  ) returning id into v_job_id;

  return v_job_id;
end;
$$;

revoke all on function public.admin_manage_playlist_request_item(uuid, text, uuid, text)
  from public, anon;
grant execute on function public.admin_manage_playlist_request_item(uuid, text, uuid, text)
  to authenticated;

-- Keep the legacy report action working, but bind it to the current request
-- item whenever the report contains the original YouTube ID.
create or replace function public.admin_enqueue_track_replacement(
  p_playlist_id uuid,
  p_source_url text,
  p_replace_youtube_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_request_id uuid;
  v_playlist_job_id uuid;
  v_item_id uuid;
  v_parsed jsonb;
  v_old_youtube_id text;
  v_job_id uuid;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );
  select * into v_playlist
    from public.playlists
   where id = p_playlist_id
   for update;
  if v_playlist.id is null then raise exception 'playlist_not_found'; end if;
  perform private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    v_playlist.unit_id
  );

  v_parsed := public.parse_music_url(p_source_url);
  if v_parsed is null
     or v_parsed ->> 'source' <> 'youtube'
     or v_parsed ->> 'resourceType' <> 'video' then
    raise exception 'invalid_youtube_video_url';
  end if;
  v_old_youtube_id := nullif(pg_catalog.btrim(coalesce(p_replace_youtube_id, '')), '');
  if v_old_youtube_id is not null
     and v_old_youtube_id !~ '^[A-Za-z0-9_-]{11}$' then
    raise exception 'invalid_replace_youtube_id';
  end if;

  select j.playlist_request_id, j.id
    into v_request_id, v_playlist_job_id
    from public.download_jobs j
   where j.playlist_id = v_playlist.id
     and j.playlist_request_id is not null
     and coalesce(j.mode, 'playlist') = 'playlist'
   order by j.created_at desc, j.id desc
   limit 1;

  if v_request_id is not null and v_old_youtube_id is not null then
    select item.id into v_item_id
      from public.playlist_request_tracks item
     where item.playlist_request_id = v_request_id
       and item.youtube_video_id = v_old_youtube_id
     order by
       (item.download_job_id = v_playlist_job_id) desc,
       (item.title is not null) desc,
       item.updated_at desc,
       item.id desc
     limit 1
     for update;
  end if;

  if v_item_id is not null then
    update public.playlist_request_tracks
       set youtube_url = v_parsed ->> 'normalizedUrl',
           youtube_video_id = v_parsed ->> 'resourceId',
           item_status = 'processing',
           error_message = null,
           last_error_code = null,
           locked_at = null,
           metadata = coalesce(metadata, '{}'::jsonb)
             || pg_catalog.jsonb_build_object('manual_replacement', true),
           updated_at = pg_catalog.now()
     where id = v_item_id;

    select job.id into v_job_id
      from public.download_jobs job
     where job.playlist_request_item_id = v_item_id
       and job.mode = 'single_track'
       and job.status in ('queued', 'running')
       and job.source_url = v_parsed ->> 'normalizedUrl'
     order by job.created_at desc, job.id desc
     limit 1;
    if v_job_id is not null then return v_job_id; end if;
  end if;

  insert into public.download_jobs (
    playlist_id, playlist_request_id, playlist_request_item_id,
    source_url, status, attempts, mode, replace_youtube_id,
    created_at, updated_at
  ) values (
    v_playlist.id, v_request_id, v_item_id,
    v_parsed ->> 'normalizedUrl', 'queued', 0, 'single_track',
    v_old_youtube_id, pg_catalog.now(), pg_catalog.now()
  ) returning id into v_job_id;
  return v_job_id;
end;
$$;

revoke all on function public.admin_enqueue_track_replacement(uuid, text, text)
  from public, anon;
grant execute on function public.admin_enqueue_track_replacement(uuid, text, text)
  to authenticated;

-- Atomic worker operation: preserve the old position, remove the old link,
-- keep one request snapshot row, and finish the exact item selected by Admin.
create or replace function public.worker_replace_playlist_request_track(
  p_job_id uuid,
  p_track_id uuid,
  p_youtube_video_id text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job public.download_jobs%rowtype;
  v_item public.playlist_request_tracks%rowtype;
  v_existing_item public.playlist_request_tracks%rowtype;
  v_old_link public.playlist_tracks%rowtype;
  v_new_link public.playlist_tracks%rowtype;
  v_old_track_id uuid;
  v_position integer;
  v_duplicate boolean := false;
begin
  if p_job_id is null or p_track_id is null then
    raise exception 'replacement_job_and_track_required';
  end if;
  if coalesce(p_youtube_video_id, '') !~ '^[A-Za-z0-9_-]{11}$' then
    raise exception 'invalid_replace_youtube_id';
  end if;

  select * into v_job
    from public.download_jobs
   where id = p_job_id
     and mode = 'single_track'
   for update;
  if v_job.id is null then raise exception 'download_job_not_found'; end if;
  if v_job.playlist_request_id is null or v_job.playlist_request_item_id is null then
    raise exception 'playlist_request_item_not_bound';
  end if;

  perform 1
    from public.tracks
   where id = p_track_id
     and status = 'available'
   for share;
  if not found then
    raise exception 'TRACK_NOT_AVAILABLE' using errcode = 'check_violation';
  end if;

  select * into v_item
    from public.playlist_request_tracks
   where id = v_job.playlist_request_item_id
     and playlist_request_id = v_job.playlist_request_id
   for update;
  if v_item.id is null then raise exception 'playlist_request_item_not_found'; end if;

  v_old_track_id := v_item.track_id;
  v_position := greatest(coalesce(v_item.position, 0), 0);

  select * into v_existing_item
    from public.playlist_request_tracks
   where playlist_request_id = v_job.playlist_request_id
     and track_id = p_track_id
     and id <> v_item.id
   limit 1
   for update;

  if v_existing_item.id is not null
     and v_existing_item.download_job_id is null
     and v_existing_item.source_track_id is null
     and v_existing_item.title is null then
    delete from public.playlist_request_tracks
     where id = v_existing_item.id;
    v_existing_item.id := null;
  end if;

  v_duplicate := v_existing_item.id is not null;
  if v_duplicate then
    update public.playlist_request_tracks
       set track_id = null,
           item_status = 'duplicate',
           youtube_url = 'https://www.youtube.com/watch?v=' || p_youtube_video_id,
           youtube_video_id = p_youtube_video_id,
           error_message = 'Faixa ja vinculada a esta playlist.',
           last_error_code = null,
           locked_at = null,
           updated_at = pg_catalog.now()
     where id = v_item.id;
  else
    update public.playlist_request_tracks
       set track_id = p_track_id,
           item_status = 'processing',
           youtube_url = 'https://www.youtube.com/watch?v=' || p_youtube_video_id,
           youtube_video_id = p_youtube_video_id,
           error_message = null,
           last_error_code = null,
           locked_at = null,
           updated_at = pg_catalog.now()
     where id = v_item.id;
  end if;

  if v_old_track_id is not null then
    select * into v_old_link
      from public.playlist_tracks
     where playlist_id = v_job.playlist_id
       and track_id = v_old_track_id
     limit 1
     for update;
  end if;
  select * into v_new_link
    from public.playlist_tracks
   where playlist_id = v_job.playlist_id
     and track_id = p_track_id
   limit 1
   for update;

  if v_old_link.id is not null and v_new_link.id is not null
     and v_old_link.id <> v_new_link.id then
    v_position := v_old_link.position;
    delete from public.playlist_tracks where id = v_old_link.id;
    update public.playlist_tracks
       set position = v_position,
           updated_at = pg_catalog.now()
     where id = v_new_link.id;
  elsif v_old_link.id is not null and v_old_track_id is distinct from p_track_id then
    v_position := v_old_link.position;
    update public.playlist_tracks
       set track_id = p_track_id,
           added_by_type = 'system',
           updated_at = pg_catalog.now()
     where id = v_old_link.id;
  elsif v_new_link.id is not null then
    if v_position > 0 and v_new_link.position <> v_position then
      update public.playlist_tracks
         set position = v_position,
             updated_at = pg_catalog.now()
       where id = v_new_link.id;
    else
      v_position := v_new_link.position;
    end if;
  else
    if v_position = 0 then
      select coalesce(max(position), 0) + 1 into v_position
        from public.playlist_tracks
       where playlist_id = v_job.playlist_id;
    end if;
    insert into public.playlist_tracks (
      playlist_id, track_id, position, added_by_type
    ) values (
      v_job.playlist_id, p_track_id, v_position, 'system'
    );
  end if;

  if not v_duplicate then
    update public.playlist_request_tracks
       set item_status = 'completed',
           position = greatest(v_position, 0),
           error_message = null,
           last_error_code = null,
           locked_at = null,
           updated_at = pg_catalog.now()
     where id = v_item.id;
  end if;

  return pg_catalog.jsonb_build_object(
    'item_id', v_item.id,
    'track_id', p_track_id,
    'position', v_position,
    'status', case when v_duplicate then 'duplicate' else 'completed' end
  );
end;
$$;

revoke all on function public.worker_replace_playlist_request_track(uuid, uuid, text)
  from public, anon, authenticated;
grant execute on function public.worker_replace_playlist_request_track(uuid, uuid, text)
  to service_role;

-- Bind historical manual jobs to the original rich request item. This lets the
-- repair below remove links that were appended by the previous implementation.
update public.download_jobs job
   set playlist_request_item_id = (
     select item.id
       from public.playlist_request_tracks item
      where item.playlist_request_id = job.playlist_request_id
        and item.youtube_video_id = (
          public.parse_music_url(job.source_url)->>'resourceId'
        )
        and coalesce((item.metadata->>'manual_replacement')::boolean, false)
      order by
        (item.title is not null) desc,
        (item.download_job_id is not null) desc,
        item.updated_at desc,
        item.id desc
      limit 1
   )
 where job.playlist_request_item_id is null
   and job.playlist_request_id is not null
   and job.mode = 'single_track'
   and job.replace_youtube_id is not null;

do $$
declare
  v_repair record;
begin
  for v_repair in
    select distinct on (job.playlist_request_item_id)
      job.id as job_id,
      track.id as track_id,
      coalesce(track.metadata->>'youtube_id', parsed.youtube_video_id) as youtube_video_id
    from public.download_jobs job
    cross join lateral (
      select public.parse_music_url(job.source_url)->>'resourceId' as youtube_video_id
    ) parsed
    join public.tracks track
      on track.storage_object_key = 'tracks/' || parsed.youtube_video_id || '.mp3'
     and track.status = 'available'
   where job.playlist_request_item_id is not null
     and job.mode = 'single_track'
     and job.status = 'done'
   order by job.playlist_request_item_id, job.finished_at desc nulls last, job.created_at desc
  loop
    perform public.worker_replace_playlist_request_track(
      v_repair.job_id,
      v_repair.track_id,
      v_repair.youtube_video_id
    );
  end loop;
end;
$$;

-- Repair one or two rounds of UTF-8 text that was decoded as Latin-1 before
-- it reached Postgres. The wrapper keeps the existing message rules intact.
create or replace function private.repair_utf8_mojibake(p_value text)
returns text
language plpgsql
immutable
strict
set search_path = ''
as $$
declare
  v_result text := p_value;
  v_decoded text;
  v_attempt integer;
begin
  for v_attempt in 1..2 loop
    exit when pg_catalog.strpos(v_result, pg_catalog.chr(195)) = 0
          and pg_catalog.strpos(v_result, pg_catalog.chr(194)) = 0;
    begin
      v_decoded := pg_catalog.convert_from(
        pg_catalog.convert_to(v_result, 'LATIN1'),
        'UTF8'
      );
    exception when others then
      return v_result;
    end;
    exit when v_decoded = v_result;
    v_result := v_decoded;
  end loop;
  return v_result;
end;
$$;

revoke all on function private.repair_utf8_mojibake(text)
  from public, anon, authenticated;

alter function public.playlist_request_operator_messages(uuid)
  rename to playlist_request_operator_messages_mojibake_impl;
revoke all on function public.playlist_request_operator_messages_mojibake_impl(uuid)
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
      pg_catalog.to_jsonb(private.repair_utf8_mojibake(message))
      order by ordinal
    ),
    '[]'::jsonb
  )
  from pg_catalog.jsonb_array_elements_text(
    public.playlist_request_operator_messages_mojibake_impl(p_request_id)
  ) with ordinality as messages(message, ordinal)
$$;

revoke all on function public.playlist_request_operator_messages(uuid)
  from public, anon, authenticated;

alter function public.playlist_request_item_operator_message(text)
  rename to playlist_request_item_operator_message_mojibake_impl;
revoke all on function public.playlist_request_item_operator_message_mojibake_impl(text)
  from public, anon, authenticated;

create function public.playlist_request_item_operator_message(p_status text)
returns text
language sql
immutable
security definer
set search_path = ''
as $$
  select private.repair_utf8_mojibake(
    public.playlist_request_item_operator_message_mojibake_impl(p_status)
  )
$$;

revoke all on function public.playlist_request_item_operator_message(text)
  from public, anon, authenticated;

commit;
