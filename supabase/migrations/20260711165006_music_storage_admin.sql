-- Visão administrativa do acervo no R2. O painel nunca apaga objetos diretamente:
-- ele agenda a mesma fila protegida que o Worker processa com nova checagem de vínculo.

create or replace function public.admin_music_storage_overview()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_result jsonb;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  select jsonb_build_object(
    'total_tracks', count(*),
    'linked_tracks', count(*) filter (
      where exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
    ),
    'orphaned_tracks', count(*) filter (
      where t.status = 'available'
        and not exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
    ),
    'queued_deletions', (
      select count(*) from public.storage_deletion_jobs j where j.status in ('queued', 'running', 'error')
    ),
    'measured_tracks', count(*) filter (
      where coalesce(t.metadata->>'size_bytes', '') ~ '^[0-9]+$'
    ),
    'used_bytes', coalesce(sum(
      case
        when coalesce(t.metadata->>'size_bytes', '') ~ '^[0-9]+$'
          then (t.metadata->>'size_bytes')::bigint
        else 0
      end
    ), 0),
    'last_measured_at', max(nullif(t.metadata->>'storage_checked_at', '')::timestamptz)
  ) into v_result
  from public.tracks t;

  return v_result;
end;
$$;

create or replace function public.admin_list_orphaned_music_tracks(p_limit integer default 50)
returns table(
  id uuid,
  title text,
  artist text,
  storage_object_key text,
  size_bytes bigint,
  created_at timestamptz
)
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  return query
  select
    t.id,
    t.title,
    t.artist,
    t.storage_object_key,
    case
      when coalesce(t.metadata->>'size_bytes', '') ~ '^[0-9]+$'
        then (t.metadata->>'size_bytes')::bigint
      else null
    end,
    t.created_at
  from public.tracks t
  where t.status = 'available'
    and not exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
  order by t.created_at asc
  limit greatest(1, least(coalesce(p_limit, 50), 100));
end;
$$;

create or replace function public.admin_queue_orphaned_music_deletions()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_queued integer := 0;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  with candidates as (
    select t.id, t.storage_object_key
    from public.tracks t
    where t.status = 'available'
      and not exists (select 1 from public.playlist_tracks pt where pt.track_id = t.id)
    for update
  ), disabled as (
    update public.tracks t
    set status = 'disabled', revision = revision + 1, updated_at = now()
    from candidates c
    where t.id = c.id
    returning t.id, t.storage_object_key
  ), queued as (
    insert into public.storage_deletion_jobs(track_id, storage_object_key, status, next_attempt_at, last_error)
    select id, storage_object_key, 'queued', now(), null from disabled
    on conflict (track_id) do update
      set status = 'queued', next_attempt_at = now(), last_error = null, locked_at = null, updated_at = now()
    returning id
  )
  select count(*) into v_queued from queued;

  return jsonb_build_object('queued', v_queued);
end;
$$;

revoke all on function public.admin_music_storage_overview() from public, anon;
revoke all on function public.admin_list_orphaned_music_tracks(integer) from public, anon;
revoke all on function public.admin_queue_orphaned_music_deletions() from public, anon;
grant execute on function public.admin_music_storage_overview() to authenticated;
grant execute on function public.admin_list_orphaned_music_tracks(integer) to authenticated;
grant execute on function public.admin_queue_orphaned_music_deletions() to authenticated;
