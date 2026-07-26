begin;

create or replace function public.admin_reimport_playlist_request(p_request uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_request public.playlist_requests%rowtype;
  v_playlist public.playlists%rowtype;
  v_job_id uuid;
begin
  select * into v_admin
    from public.admin_users
   where auth_user_id = auth.uid()
     and active is true
   limit 1;

  if v_admin.id is null then raise exception 'forbidden'; end if;

  select * into v_request
    from public.playlist_requests
   where id = p_request
   for update;

  if v_request.id is null then raise exception 'playlist_request_not_found'; end if;

  select * into v_playlist
    from public.playlists
   where id = v_request.playlist_id
   for update;

  if v_playlist.id is null then raise exception 'playlist_not_found'; end if;
  if not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id)
  then
    raise exception 'forbidden';
  end if;
  if v_request.status <> 'approved' then raise exception 'playlist_request_not_approved'; end if;
  if public.playlist_source_platform(v_request.source_url) not in ('youtube', 'spotify') then
    raise exception 'unsupported_platform';
  end if;

  if exists (
    select 1
      from public.download_jobs
     where playlist_id = v_playlist.id
       and status in ('queued', 'running')
  ) then
    raise exception 'import_already_running';
  end if;

  update public.playlists
     set source_url = v_request.source_url,
         approval_status = 'approved',
         import_status = 'processing',
         error_code = null,
         error_message = null,
         error_details = null,
         last_error_at = null,
         import_started_at = pg_catalog.now(),
         import_finished_at = null,
         updated_at = pg_catalog.now(),
         revision = revision + 1
   where id = v_playlist.id;

  insert into public.download_jobs (
    playlist_id,
    playlist_request_id,
    source_url,
    status,
    attempts,
    mode,
    created_at,
    updated_at
  ) values (
    v_playlist.id,
    v_request.id,
    v_request.source_url,
    'queued',
    0,
    'playlist',
    pg_catalog.now(),
    pg_catalog.now()
  ) returning id into v_job_id;

  -- Consumidores legados usam este ponteiro, enquanto os contratos novos
  -- também procuram o job mais recente por playlist_request_id.
  update public.playlist_requests
     set download_job_id = v_job_id,
         updated_at = pg_catalog.now()
   where id = v_request.id;

  insert into public.admin_audit_logs (
    admin_user_id,
    action,
    entity_type,
    entity_id,
    before_data,
    after_data,
    occurred_at
  ) values (
    v_admin.id,
    'playlist_request_reimported',
    'playlist_requests',
    v_request.id,
    pg_catalog.to_jsonb(v_playlist),
    pg_catalog.jsonb_build_object(
      'playlist_id', v_playlist.id,
      'playlist_request_id', v_request.id,
      'source_url', v_request.source_url,
      'download_job_id', v_job_id
    ),
    pg_catalog.now()
  );
end;
$$;

revoke all on function public.admin_reimport_playlist_request(uuid) from public, anon;
grant execute on function public.admin_reimport_playlist_request(uuid) to authenticated;

-- Reconcilia ponteiros antigos sem alterar jobs, solicitações ou faixas.
with latest_jobs as (
  select
    j.playlist_request_id,
    j.id as job_id,
    row_number() over (
      partition by j.playlist_request_id
      order by j.created_at desc, j.id desc
    ) as job_order
  from public.download_jobs j
  where j.playlist_request_id is not null
    and coalesce(j.mode, 'playlist') = 'playlist'
)
update public.playlist_requests r
   set download_job_id = latest.job_id,
       updated_at = pg_catalog.now()
  from latest_jobs latest
 where latest.playlist_request_id = r.id
   and latest.job_order = 1
   and r.download_job_id is distinct from latest.job_id;

commit;
