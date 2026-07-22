begin;

-- Aprovacoes de um novo envio preservam o snapshot anterior sem reposicionar
-- linhas ja capturadas. Atualizar a posicao de uma linha historica podia colidir
-- com playlist_request_tracks_job_position_key e abortar toda a aprovacao.
create or replace function public.preserve_playlist_request_on_approval()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_previous_request uuid;
begin
  if new.status <> 'approved' or old.status = 'approved' then
    return new;
  end if;

  select r.id into v_previous_request
  from public.playlist_requests r
  where r.playlist_id = new.playlist_id
    and r.id <> new.id
    and r.status = 'approved'
  order by coalesce(r.decided_at, r.updated_at) desc, r.created_at desc
  limit 1;

  if v_previous_request is not null then
    insert into public.playlist_request_tracks (
      playlist_request_id, track_id, position, captured_at
    )
    select v_previous_request, pt.track_id, greatest(pt.position, 0), pg_catalog.now()
    from public.playlist_tracks pt
    where pt.playlist_id = new.playlist_id
    on conflict (playlist_request_id, track_id) do nothing;
  end if;

  update public.download_jobs j
  set playlist_request_id = new.id
  where j.id = (
    select candidate.id
    from public.download_jobs candidate
    where candidate.playlist_id = new.playlist_id
      and candidate.source_url is not distinct from new.source_url
      and candidate.playlist_request_id is null
      and candidate.status in ('queued', 'running')
    order by candidate.created_at desc, candidate.id desc
    limit 1
  );

  return new;
end;
$$;

revoke all on function public.preserve_playlist_request_on_approval()
  from public, anon, authenticated;

-- Retentativas precisam pertencer ao mesmo envio que originou o link. Sem esse
-- vinculo, o Admin continuava calculando o status pelo job antigo com falha.
create or replace function public.admin_retry_playlist_import(p_playlist uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_platform text;
  v_playlist_request_id uuid;
  v_job_id uuid;
begin
  select * into v_admin
    from public.admin_users
   where auth_user_id = auth.uid()
     and active is true
   limit 1;

  if v_admin.id is null then raise exception 'forbidden'; end if;

  select * into v_playlist
    from public.playlists
   where id = p_playlist
   for update;

  if v_playlist.id is null then raise exception 'playlist_not_found'; end if;
  if v_playlist.approval_status <> 'approved' then raise exception 'playlist_not_approved'; end if;

  v_platform := public.playlist_source_platform(v_playlist.source_url);
  if v_platform not in ('youtube', 'spotify') then
    update public.playlists
       set import_status = 'failed',
           error_code = 'UNSUPPORTED_PLATFORM',
           error_message = public.playlist_import_error_message('UNSUPPORTED_PLATFORM', null),
           error_details = pg_catalog.jsonb_build_object(
             'platform', v_platform,
             'source_url', v_playlist.source_url
           ),
           last_error_at = pg_catalog.now()
     where id = p_playlist;
    return;
  end if;

  if exists (
    select 1
      from public.download_jobs
     where playlist_id = p_playlist
       and status in ('queued', 'running')
  ) then
    raise exception 'import_already_running';
  end if;

  select r.id
    into v_playlist_request_id
    from public.playlist_requests r
   where r.playlist_id = p_playlist
     and r.status = 'approved'
     and coalesce(r.normalized_url, r.source_url) is not distinct from v_playlist.source_url
   order by coalesce(r.decided_at, r.updated_at) desc, r.created_at desc, r.id desc
   limit 1;

  update public.playlists
     set import_status = 'processing',
         error_code = null,
         error_message = null,
         error_details = null,
         last_error_at = null,
         import_started_at = pg_catalog.now(),
         import_finished_at = null
   where id = p_playlist;

  insert into public.download_jobs (
    playlist_id,
    playlist_request_id,
    source_url,
    status,
    attempts,
    created_at,
    updated_at
  ) values (
    p_playlist,
    v_playlist_request_id,
    v_playlist.source_url,
    'queued',
    0,
    pg_catalog.now(),
    pg_catalog.now()
  )
  returning id into v_job_id;

  if v_playlist_request_id is not null then
    update public.playlist_requests
       set download_job_id = v_job_id,
           updated_at = pg_catalog.now()
     where id = v_playlist_request_id;
  end if;
end;
$$;

revoke all on function public.admin_retry_playlist_import(uuid)
  from public, anon;
grant execute on function public.admin_retry_playlist_import(uuid)
  to authenticated;

-- Repara apenas retentativas historicas comprovadamente concluidas e sem dono.
-- O pareamento exige a mesma playlist, a mesma URL normalizada e uma
-- solicitacao aprovada anterior; jobs parciais ou com erro ficam intocados.
with retry_matches as (
  select
    j.id as job_id,
    r.id as request_id,
    pg_catalog.row_number() over (
      partition by j.id
      order by coalesce(r.decided_at, r.updated_at) desc, r.created_at desc, r.id desc
    ) as match_order
  from public.download_jobs j
  join public.playlist_requests r
    on r.playlist_id = j.playlist_id
   and r.status = 'approved'
   and coalesce(r.normalized_url, r.source_url) is not distinct from j.source_url
   and coalesce(r.decided_at, r.updated_at, r.created_at) <= j.created_at
  where j.playlist_request_id is null
    and j.status = 'done'
    and j.total > 0
    and j.completed >= j.total
    and coalesce(j.failed, 0) = 0
), selected_matches as (
  select job_id, request_id
  from retry_matches
  where match_order = 1
)
update public.download_jobs j
   set playlist_request_id = selected_matches.request_id
  from selected_matches
 where j.id = selected_matches.job_id;

-- O job mais recente passa a ser a referencia direta da solicitacao. Isso
-- tambem corrige imediatamente o status exibido no Admin.
with latest_jobs as (
  select
    j.playlist_request_id,
    j.id as job_id,
    pg_catalog.row_number() over (
      partition by j.playlist_request_id
      order by j.created_at desc, j.id desc
    ) as job_order
  from public.download_jobs j
  where j.playlist_request_id is not null
)
update public.playlist_requests r
   set download_job_id = latest_jobs.job_id,
       updated_at = pg_catalog.now()
  from latest_jobs
 where latest_jobs.playlist_request_id = r.id
   and latest_jobs.job_order = 1
   and r.download_job_id is distinct from latest_jobs.job_id;

commit;
