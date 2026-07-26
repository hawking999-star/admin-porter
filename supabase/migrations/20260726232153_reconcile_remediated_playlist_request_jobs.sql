begin;

-- O job da playlist e historico, mas o selo operacional precisa deixar de
-- anunciar falha depois que todas as faixas da tentativa vigente foram
-- resolvidas, substituidas ou conscientemente ignoradas pelo Admin.
create or replace function private.reconcile_playlist_request_current_job(
  p_request_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_job_id uuid;
  v_playlist_id uuid;
  v_job_status text;
  v_total integer := 0;
  v_terminal integer := 0;
begin
  select j.id, j.playlist_id, j.status
    into v_job_id, v_playlist_id, v_job_status
    from public.download_jobs j
    join public.playlist_requests r on r.id = p_request_id
   where (
     j.playlist_request_id = r.id
     or j.id = r.download_job_id
   )
     and coalesce(j.mode, 'playlist') = 'playlist'
   order by j.created_at desc, j.id desc
   limit 1
   for update of j;

  if v_job_id is null or v_job_status not in ('partial', 'error') then
    return;
  end if;

  select
    count(*)::integer,
    count(*) filter (
      where item_status in ('completed', 'duplicate', 'skipped')
    )::integer
  into v_total, v_terminal
  from public.playlist_request_tracks
  where playlist_request_id = p_request_id
    and download_job_id = v_job_id;

  if v_total = 0 or v_terminal <> v_total then
    return;
  end if;

  update public.download_jobs
     set status = 'done',
         total = v_total,
         completed = v_total,
         failed = 0,
         error = null,
         error_code = null,
         error_message = null,
         error_details = case
           when error_details is null then null
           else pg_catalog.jsonb_build_object(
             'remediated_at', pg_catalog.now(),
             'previous', error_details
           )
         end,
         last_error_at = null,
         finished_at = coalesce(finished_at, pg_catalog.now()),
         updated_at = pg_catalog.now()
   where id = v_job_id;

  update public.playlists
     set import_status = 'success',
         error_message = null,
         error_code = null,
         error_details = case
           when error_details is null then null
           else pg_catalog.jsonb_build_object(
             'remediated_at', pg_catalog.now(),
             'previous', error_details
           )
         end,
         last_error_at = null,
         import_finished_at = coalesce(import_finished_at, pg_catalog.now()),
         updated_at = pg_catalog.now()
   where id = v_playlist_id;
end;
$$;

revoke all on function private.reconcile_playlist_request_current_job(uuid)
  from public, anon, authenticated;

create or replace function private.reconcile_playlist_request_track_status()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.item_status is distinct from old.item_status
     and new.item_status in ('completed', 'duplicate', 'skipped') then
    perform private.reconcile_playlist_request_current_job(
      new.playlist_request_id
    );
  end if;
  return new;
end;
$$;

revoke all on function private.reconcile_playlist_request_track_status()
  from public, anon, authenticated;

drop trigger if exists playlist_request_track_reconcile_job
  on public.playlist_request_tracks;
create trigger playlist_request_track_reconcile_job
after update of item_status on public.playlist_request_tracks
for each row
execute function private.reconcile_playlist_request_track_status();

-- Corrige imediatamente solicitacoes ja remediadas antes desta migration.
do $$
declare
  v_request record;
begin
  for v_request in
    select distinct r.id
      from public.playlist_requests r
      join public.download_jobs j
        on j.playlist_request_id = r.id
        or j.id = r.download_job_id
     where coalesce(j.mode, 'playlist') = 'playlist'
       and j.status in ('partial', 'error')
  loop
    perform private.reconcile_playlist_request_current_job(v_request.id);
  end loop;
end;
$$;

commit;
