begin;

-- Claim curto e serializado: impede que múltiplas réplicas ultrapassem o limite
-- global e usa SKIP LOCKED para nunca esperar por outro job.
create or replace function public.worker_claim_download_job(
  p_max_concurrent integer default 1
)
returns setof public.download_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_max_concurrent, 1), 1), 10);
begin
  perform pg_catalog.pg_advisory_xact_lock(7823479120341);
  if (select count(*) from public.download_jobs where status = 'running') >= v_limit then
    return;
  end if;

  return query
  with candidate as (
    select job.id
      from public.download_jobs job
     where job.status = 'queued'
     order by job.created_at, job.id
     for update skip locked
     limit 1
  )
  update public.download_jobs job
     set status = 'running',
         started_at = pg_catalog.now(),
         attempts = job.attempts + 1,
         error = null,
         error_code = null,
         error_message = null,
         error_details = null,
         last_error_at = null,
         updated_at = pg_catalog.now()
    from candidate
   where job.id = candidate.id
  returning job.*;
end;
$$;

revoke all on function public.worker_claim_download_job(integer)
  from public, anon, authenticated;
grant execute on function public.worker_claim_download_job(integer) to service_role;

-- Endurece a RPC legada: URL centralizada, vídeo único e escopo da unidade.
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
  v_parsed jsonb;
  v_job uuid;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );
  select * into v_playlist from public.playlists where id = p_playlist_id;
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
  if nullif(pg_catalog.btrim(coalesce(p_replace_youtube_id, '')), '') is not null
     and pg_catalog.btrim(p_replace_youtube_id) !~ '^[A-Za-z0-9_-]{11}$' then
    raise exception 'invalid_replace_youtube_id';
  end if;

  insert into public.download_jobs (
    playlist_id, source_url, status, mode, replace_youtube_id
  ) values (
    v_playlist.id,
    v_parsed ->> 'normalizedUrl',
    'queued',
    'single_track',
    nullif(pg_catalog.btrim(coalesce(p_replace_youtube_id, '')), '')
  ) returning id into v_job;
  return v_job;
end;
$$;

revoke all on function public.admin_enqueue_track_replacement(uuid, text, text)
  from public, anon;
grant execute on function public.admin_enqueue_track_replacement(uuid, text, text)
  to authenticated;

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
           updated_at = pg_catalog.now()
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
           item_status = 'resolved',
           error_message = null,
           metadata = metadata || pg_catalog.jsonb_build_object('manual_replacement', true),
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
           updated_at = pg_catalog.now()
     where id = v_item.id
     returning * into v_item;
  end if;

  if exists (
    select 1 from public.download_jobs
     where playlist_id = v_playlist.id
       and status in ('queued', 'running')
  ) then
    raise exception 'import_already_running';
  end if;

  insert into public.download_jobs (
    playlist_id, playlist_request_id, source_url, status, attempts,
    mode, replace_youtube_id, created_at, updated_at
  ) values (
    v_playlist.id, v_request.id, v_item.youtube_url, 'queued', 0,
    'single_track', v_item.youtube_video_id, pg_catalog.now(), pg_catalog.now()
  ) returning id into v_job_id;
  return v_job_id;
end;
$$;

revoke all on function public.admin_manage_playlist_request_item(uuid, text, uuid, text)
  from public, anon;
grant execute on function public.admin_manage_playlist_request_item(uuid, text, uuid, text)
  to authenticated;

-- Dados multi-tenant permanecem RPC-only.
alter table public.playlist_requests enable row level security;
alter table public.playlist_request_tracks enable row level security;
revoke all on table public.playlist_requests from public, anon, authenticated;
revoke all on table public.playlist_request_tracks from public, anon, authenticated;

commit;
