begin;

create index if not exists idx_music_import_operation_leases_playlist
  on private.music_import_operation_leases (playlist_id);
create index if not exists idx_music_import_runtime_config_updated_by
  on private.music_import_runtime_config (updated_by_admin_id)
  where updated_by_admin_id is not null;
create index if not exists idx_music_import_tasks_playlist_request
  on private.music_import_tasks (playlist_request_id)
  where playlist_request_id is not null;
create index if not exists idx_music_import_tasks_upload_session
  on private.music_import_tasks (upload_session_id)
  where upload_session_id is not null;
create index if not exists idx_music_upload_sessions_admin
  on private.music_upload_sessions (admin_user_id);
create index if not exists idx_music_upload_sessions_final_track
  on private.music_upload_sessions (final_track_id)
  where final_track_id is not null;
create index if not exists idx_music_upload_sessions_playlist
  on private.music_upload_sessions (playlist_id);
create index if not exists idx_music_upload_sessions_playlist_request
  on private.music_upload_sessions (playlist_request_id);
create index if not exists idx_music_upload_sessions_request_item
  on private.music_upload_sessions (request_item_id);
create index if not exists idx_music_upload_sessions_task
  on private.music_upload_sessions (task_id)
  where task_id is not null;

commit;
