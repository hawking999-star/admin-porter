begin;

-- A fila principal continua em download_jobs. Estes campos permitem que o mesmo
-- job seja retomado sem repetir faixas concluídas e limitam tentativas por item.
alter table public.download_jobs
  add column if not exists locked_at timestamptz;

alter table public.playlist_request_tracks
  add column if not exists download_job_id uuid
    references public.download_jobs(id) on delete set null,
  add column if not exists attempts integer not null default 0,
  add column if not exists locked_at timestamptz,
  add column if not exists last_error_code text;

alter table public.playlist_request_tracks
  add constraint playlist_request_tracks_attempts_check
  check (attempts >= 0);

alter table public.playlist_request_tracks
  add constraint playlist_request_tracks_job_position_key
  unique (download_job_id, position);

create index if not exists download_jobs_queued_created_idx
  on public.download_jobs (created_at, id)
  where status = 'queued';

create index if not exists playlist_request_tracks_resumable_idx
  on public.playlist_request_tracks (download_job_id, position)
  where item_status in ('resolved', 'processing', 'failed');

-- Claim atômico por faixa. Mesmo se dois processos receberem o mesmo job por
-- falha operacional, somente um deles pode adquirir cada item.
create function public.worker_claim_playlist_request_item(
  p_job_id uuid,
  p_position integer,
  p_max_attempts integer default 2,
  p_stale_after_seconds integer default 1800
)
returns setof public.playlist_request_tracks
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_max_attempts integer := least(greatest(coalesce(p_max_attempts, 2), 1), 5);
  v_stale_seconds integer := least(greatest(coalesce(p_stale_after_seconds, 1800), 60), 7200);
begin
  if not exists (
    select 1
      from public.download_jobs job
     where job.id = p_job_id
       and job.status = 'running'
  ) then
    return;
  end if;

  return query
  with candidate as (
    select item.id
      from public.playlist_request_tracks item
     where item.download_job_id = p_job_id
       and item.position = p_position
       and item.attempts < v_max_attempts
       and (
         item.item_status in ('resolved', 'failed')
         or (
           item.item_status = 'processing'
           and (
             item.locked_at is null
             or item.locked_at < pg_catalog.now()
               - pg_catalog.make_interval(secs => v_stale_seconds)
           )
         )
       )
     for update skip locked
     limit 1
  )
  update public.playlist_request_tracks item
     set item_status = 'processing',
         attempts = item.attempts + 1,
         locked_at = pg_catalog.now(),
         last_error_code = null,
         error_message = null,
         updated_at = pg_catalog.now()
    from candidate
   where item.id = candidate.id
  returning item.*;
end;
$$;

revoke all on function public.worker_claim_playlist_request_item(uuid, integer, integer, integer)
  from public, anon, authenticated;
grant execute on function public.worker_claim_playlist_request_item(uuid, integer, integer, integer)
  to service_role;

-- Mantém o claim de job existente, acrescentando lock/heartbeat explícito.
create or replace function public.worker_claim_download_job(
  p_max_concurrent integer default 1
)
returns setof public.download_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer := least(greatest(coalesce(p_max_concurrent, 1), 1), 10);
begin
  perform pg_catalog.pg_advisory_xact_lock(7823479120341);
  if (select count(*) from public.download_jobs where status = 'running') >= v_limit then
    return;
  end if;

  return query
  with candidate as (
    select job.id
      from public.download_jobs job
     where job.status = 'queued'
     order by job.created_at, job.id
     for update skip locked
     limit 1
  )
  update public.download_jobs job
     set status = 'running',
         started_at = coalesce(job.started_at, pg_catalog.now()),
         locked_at = pg_catalog.now(),
         attempts = job.attempts + 1,
         error = null,
         error_code = null,
         error_message = null,
         error_details = null,
         last_error_at = null,
         updated_at = pg_catalog.now()
    from candidate
   where job.id = candidate.id
  returning job.*;
end;
$$;

revoke all on function public.worker_claim_download_job(integer)
  from public, anon, authenticated;
grant execute on function public.worker_claim_download_job(integer) to service_role;

comment on column public.playlist_request_tracks.attempts is
  'Número de claims de processamento da faixa; limitado pelo Worker.';
comment on column public.playlist_request_tracks.locked_at is
  'Heartbeat do claim individual, usado para retomada após interrupção.';

commit;
