begin;

create or replace function public.admin_music_import_health()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_control record;
  v_tracks record;
  v_health private.music_provider_health%rowtype;
  v_config private.music_import_runtime_config%rowtype;
  v_circuit_seconds bigint;
begin
  perform private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager', 'auditor', 'support_readonly'],
    null
  );
  select * into v_control from pgmq.metrics('music_import_control');
  select * into v_tracks from pgmq.metrics('music_import_tracks');
  select * into v_health from private.music_provider_health where provider = 'youtube';
  select * into v_config from private.music_import_runtime_config where singleton;
  v_circuit_seconds := coalesce(v_health.total_blocked_seconds, 0)
    + case
        when v_health.status <> 'healthy' and v_health.first_failure_at is not null
          then greatest(extract(epoch from now() - v_health.first_failure_at)::bigint, 0)
        else 0
      end;

  return pg_catalog.jsonb_build_object(
    'backend', v_config.backend,
    'limits', pg_catalog.jsonb_build_object(
      'active_playlists', v_config.max_active_playlists,
      'tracks_per_playlist', v_config.max_tracks_per_playlist,
      'youtube_global', v_config.max_youtube_operations,
      'uploads_global', v_config.max_upload_operations,
      'youtube_spacing_seconds', v_config.youtube_start_spacing_seconds,
      'worker_replica_target', v_config.worker_replica_target
    ),
    'queues', pg_catalog.jsonb_build_object(
      'control', pg_catalog.to_jsonb(v_control),
      'tracks', pg_catalog.to_jsonb(v_tracks)
    ),
    'tasks', pg_catalog.jsonb_build_object(
      'queued', (select count(*) from private.music_import_tasks where status = 'queued'),
      'processing', (select count(*) from private.music_import_tasks where status = 'processing'),
      'waiting_provider', (select count(*) from private.music_import_tasks where status = 'waiting_provider'),
      'waiting_review', (select count(*) from private.music_import_tasks where status = 'waiting_review'),
      'dead_letter', (select count(*) from private.music_import_tasks where status = 'dead_letter')
    ),
    'active_playlists', (
      select count(distinct playlist_id)
      from private.music_import_tasks
      where status in ('queued', 'processing') and playlist_id is not null
    ),
    'paused_playlists', (
      select count(distinct playlist_id)
      from private.music_import_tasks
      where status = 'waiting_provider' and playlist_id is not null
    ),
    'provider', pg_catalog.to_jsonb(v_health) || pg_catalog.jsonb_build_object(
      'circuit_open_seconds', v_circuit_seconds
    ),
    'generated_at', now()
  );
end;
$$;

revoke all on function public.admin_music_import_health() from public, anon;
grant execute on function public.admin_music_import_health() to authenticated;

commit;
