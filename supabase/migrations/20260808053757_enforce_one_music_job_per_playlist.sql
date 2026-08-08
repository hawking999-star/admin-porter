begin;

create or replace function public.worker_claim_download_job(p_max_concurrent integer default 1)
returns setof public.download_jobs
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_limit integer;
  v_backend text;
  v_message record;
  v_task_id uuid;
  v_job_id uuid;
begin
  select least(
    greatest(coalesce(p_max_concurrent, 1), 1),
    max_active_playlists
  ), backend into v_limit, v_backend
  from private.music_import_runtime_config where singleton;

  perform pg_catalog.pg_advisory_xact_lock(7823479120341);
  if (select count(*) from public.download_jobs where status = 'running') >= v_limit then return; end if;

  if v_backend = 'pgmq' then
    for v_message in
      select * from pgmq.read('music_import_control', 1800, 10)
    loop
      if coalesce(v_message.message->>'version', '') <> '1'
         or coalesce(v_message.message->>'task_id', '') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[1-5][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$' then
        perform pgmq.archive('music_import_control', v_message.msg_id);
        continue;
      end if;
      v_task_id := (v_message.message->>'task_id')::uuid;
      select task.download_job_id into v_job_id
        from private.music_import_tasks task
       where task.id = v_task_id
         and task.task_kind = 'control'
         and task.status = 'queued'
         and task.queue_message_id = v_message.msg_id
         and task.next_attempt_at <= now();
      if v_job_id is null then
        perform pgmq.set_vt('music_import_control', v_message.msg_id, 60);
        continue;
      end if;
      if not exists (
        select 1
          from public.download_jobs job
         where job.id = v_job_id
           and job.status = 'queued'
           and job.next_attempt_at <= now()
           and job.operational_status <> 'waiting_provider'
           and not exists (
             select 1
               from public.download_jobs active
              where active.playlist_id = job.playlist_id
                and active.status = 'running'
                and active.id <> job.id
           )
      ) then
        perform pgmq.set_vt('music_import_control', v_message.msg_id, 60);
        continue;
      end if;
      return query
      update public.download_jobs job
         set status = 'running', operational_status = 'processing',
             started_at = coalesce(job.started_at, now()), locked_at = now(),
             attempts = job.attempts + 1, error = null, error_code = null,
             error_message = null, last_error_at = null, updated_at = now()
       where job.id = v_job_id
      returning job.*;
      return;
    end loop;
    return;
  end if;

  return query
  with candidate as (
    select job.id
      from public.download_jobs job
     where job.status = 'queued'
       and job.next_attempt_at <= now()
       and job.operational_status <> 'waiting_provider'
       and not exists (
         select 1
           from public.download_jobs active
          where active.playlist_id = job.playlist_id
            and active.status = 'running'
            and active.id <> job.id
       )
     order by job.next_attempt_at, job.created_at, job.id
     for update skip locked
     limit 1
  )
  update public.download_jobs job
     set status = 'running', operational_status = 'processing',
         started_at = coalesce(job.started_at, now()), locked_at = now(),
         attempts = job.attempts + 1, error = null, error_code = null,
         error_message = null, last_error_at = null, updated_at = now()
    from candidate
   where job.id = candidate.id
  returning job.*;
end;
$$;

revoke all on function public.worker_claim_download_job(integer) from public, anon, authenticated;
grant execute on function public.worker_claim_download_job(integer) to service_role;

commit;
