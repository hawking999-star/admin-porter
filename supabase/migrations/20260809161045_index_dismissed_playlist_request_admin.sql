create index if not exists playlist_requests_dismissed_by_admin_id_idx
  on public.playlist_requests (dismissed_by_admin_id)
  where dismissed_by_admin_id is not null;
