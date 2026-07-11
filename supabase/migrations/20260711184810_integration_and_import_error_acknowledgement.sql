-- Um erro confirmado pelo administrador deixa de poluir a operação, mas volta a
-- aparecer se o Worker registrar uma falha mais nova.

alter table public.playlists
  add column if not exists import_error_acknowledged_at timestamptz;

create or replace function public.admin_acknowledge_playlist_import_error(p_playlist_id uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.admin_users%rowtype;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  update public.playlists
  set import_error_acknowledged_at = now()
  where id = p_playlist_id
    and import_status = 'failed';

  if not found then
    raise exception 'playlist_import_error_not_found';
  end if;
end
$$;

create or replace function public.admin_integration_status()
returns jsonb
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

  return jsonb_build_object(
    'database_connected', true,
    'imports', jsonb_build_object(
      'queued', (select count(*) from public.download_jobs where status = 'queued'),
      'running', (select count(*) from public.download_jobs where status = 'running'),
      'completed', (select count(*) from public.download_jobs where status = 'done'),
      'with_errors', (select count(*) from public.download_jobs where status in ('partial', 'error')),
      'last_activity_at', (select max(updated_at) from public.download_jobs)
    ),
    'storage_cleanup', jsonb_build_object(
      'queued', (select count(*) from public.storage_deletion_jobs where status = 'queued'),
      'running', (select count(*) from public.storage_deletion_jobs where status = 'running'),
      'with_errors', (select count(*) from public.storage_deletion_jobs where status = 'error'),
      'last_activity_at', (select max(updated_at) from public.storage_deletion_jobs)
    )
  );
end
$$;

revoke all on function public.admin_acknowledge_playlist_import_error(uuid) from public, anon;
revoke all on function public.admin_integration_status() from public, anon;
grant execute on function public.admin_acknowledge_playlist_import_error(uuid) to authenticated;
grant execute on function public.admin_integration_status() to authenticated;
