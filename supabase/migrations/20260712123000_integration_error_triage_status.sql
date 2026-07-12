-- A fila operacional só deve exibir falhas que ainda precisam de ação. Um erro
-- confirmado pelo Admin reaparece automaticamente se o Worker registrar uma
-- falha mais recente na mesma playlist. A fonte oficial é download_jobs: há
-- históricos anteriores à sincronização de import_status que ainda precisam de
-- tratamento pelo painel.

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

  update public.playlists p
  set import_error_acknowledged_at = now()
  where p.id = p_playlist_id
    and exists (
      select 1
      from public.download_jobs j
      where j.playlist_id = p.id
        and j.status in ('partial', 'error')
    );

  if not found then
    raise exception 'playlist_import_error_not_found';
  end if;
end
$$;

create or replace function public.admin_list_pending_import_errors(p_limit integer default 100)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 100);
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  return (
    with latest_error_job as (
      select distinct on (j.playlist_id)
        j.playlist_id,
        j.error,
        j.error_code,
        j.error_message,
        j.error_details,
        coalesce(j.last_error_at, j.updated_at, j.created_at) as error_at
      from public.download_jobs j
      where j.status in ('partial', 'error')
      order by j.playlist_id, coalesce(j.last_error_at, j.updated_at, j.created_at) desc
    ), pending_errors as (
      select
        j.*,
        p.name as playlist_name,
        p.type as playlist_type,
        p.approval_status,
        p.source_url,
        o.display_name as operator_name,
        u.name as unit_name
      from latest_error_job j
      join public.playlists p on p.id = j.playlist_id
      left join public.operators o on o.id = p.created_by_operator_id
      left join public.units u on u.id = p.unit_id
      where p.import_error_acknowledged_at is null
         or j.error_at > p.import_error_acknowledged_at
      order by j.error_at desc
      limit v_limit
    )
    select coalesce(jsonb_agg(jsonb_build_object(
      'playlist_id', playlist_id,
      'playlist_name', playlist_name,
      'playlist_type', playlist_type,
      'approval_status', approval_status,
      'source_url', source_url,
      'operator_name', operator_name,
      'unit_name', unit_name,
      'error_code', error_code,
      'error_message', coalesce(error_message, error),
      'error_details', error_details,
      'last_error_at', error_at
    )), '[]'::jsonb)
    from pending_errors
  );
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
      'with_errors', (
        with latest_error_job as (
          select distinct on (j.playlist_id)
            j.playlist_id,
            coalesce(j.last_error_at, j.updated_at, j.created_at) as error_at
          from public.download_jobs j
          where j.status in ('partial', 'error')
          order by j.playlist_id, coalesce(j.last_error_at, j.updated_at, j.created_at) desc
        )
        select count(*)
        from latest_error_job j
        join public.playlists p on p.id = j.playlist_id
        where p.import_error_acknowledged_at is null
           or j.error_at > p.import_error_acknowledged_at
      ),
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

revoke all on function public.admin_integration_status() from public, anon;
grant execute on function public.admin_integration_status() to authenticated;
revoke all on function public.admin_acknowledge_playlist_import_error(uuid) from public, anon;
grant execute on function public.admin_acknowledge_playlist_import_error(uuid) to authenticated;
revoke all on function public.admin_list_pending_import_errors(integer) from public, anon;
grant execute on function public.admin_list_pending_import_errors(integer) to authenticated;
