begin;

-- Permite que o Admin aceite varias correspondencias ja encontradas pelo
-- resolvedor. Os jobs de faixa unica entram na mesma fila e o worker os
-- processa sequencialmente; somente uma importacao de playlist inteira ativa
-- continua bloqueando a remediacao manual.
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
  v_item_was_processing boolean := false;
  v_active_jobs integer := 0;
  v_processing_items integer := 0;
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
  v_item_was_processing := v_item.item_status = 'processing';

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

  -- Uma importacao de playlist inteira altera o mesmo conjunto de faixas e
  -- continua sendo mutuamente exclusiva. Jobs single_track sao independentes
  -- e podem aguardar juntos na fila.
  if exists (
    select 1
      from public.download_jobs
     where playlist_id = v_playlist.id
       and status in ('queued', 'running')
       and coalesce(mode, 'playlist') <> 'single_track'
  ) then
    raise exception 'import_already_running';
  end if;

  -- Repetir a mesma acao enquanto a faixa ja aguarda o worker e idempotente.
  if v_item_was_processing then
    select count(*) into v_active_jobs
      from public.download_jobs job
     where job.playlist_id = v_playlist.id
       and job.playlist_request_id = v_request.id
       and job.mode = 'single_track'
       and job.status in ('queued', 'running')
       and job.source_url = v_item.youtube_url;
    select count(*) into v_processing_items
      from public.playlist_request_tracks item
     where item.playlist_request_id = v_request.id
       and item.item_status = 'processing'
       and item.youtube_video_id = v_item.youtube_video_id;
    if v_active_jobs >= v_processing_items then
      select job.id into v_job_id
        from public.download_jobs job
       where job.playlist_id = v_playlist.id
         and job.playlist_request_id = v_request.id
         and job.mode = 'single_track'
         and job.status in ('queued', 'running')
         and job.source_url = v_item.youtube_url
       order by job.created_at desc, job.id desc
       limit 1;
      if v_job_id is not null then return v_job_id; end if;
    end if;
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

create or replace function public.admin_accept_playlist_request_items(
  p_request_id uuid,
  p_item_ids uuid[]
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_item_id uuid;
  v_job_id uuid;
  v_job_ids uuid[] := array[]::uuid[];
  v_requested_count integer := cardinality(p_item_ids);
begin
  if p_request_id is null then raise exception 'playlist_request_required'; end if;
  if v_requested_count is null or v_requested_count = 0 then
    raise exception 'playlist_request_items_required';
  end if;
  if v_requested_count > 170 then raise exception 'playlist_request_items_limit_exceeded'; end if;
  if exists (select 1 from pg_catalog.unnest(p_item_ids) item_id where item_id is null) then
    raise exception 'playlist_request_item_required';
  end if;

  for v_item_id in
    select distinct item_id
      from pg_catalog.unnest(p_item_ids) item_id
  loop
    v_job_id := public.admin_manage_playlist_request_item(
      p_request_id,
      'retry',
      v_item_id,
      null
    );
    v_job_ids := pg_catalog.array_append(v_job_ids, v_job_id);
  end loop;

  return pg_catalog.jsonb_build_object(
    'queued', cardinality(v_job_ids),
    'job_ids', to_jsonb(v_job_ids)
  );
end;
$$;

revoke all on function public.admin_accept_playlist_request_items(uuid, uuid[])
  from public, anon;
grant execute on function public.admin_accept_playlist_request_items(uuid, uuid[])
  to authenticated;

commit;
