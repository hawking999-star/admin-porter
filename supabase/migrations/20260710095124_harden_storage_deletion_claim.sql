create or replace function public.claim_storage_deletion_job()
returns table(job_id uuid, track_id uuid, storage_object_key text, attempts integer)
language sql
security definer
set search_path = ''
as $$
  with candidate as (
    select j.id
    from public.storage_deletion_jobs j
    join public.tracks t on t.id=j.track_id and t.status='disabled'
    where (
      (
        (j.status in ('queued','error') and j.next_attempt_at<=now())
        or (j.status='running' and j.locked_at<now()-interval '10 minutes')
      )
      and not exists(select 1 from public.playlist_tracks pt where pt.track_id=j.track_id)
    )
    order by j.created_at
    for update of j skip locked
    limit 1
  ), claimed as (
    update public.storage_deletion_jobs j
       set status='running',attempts=j.attempts+1,locked_at=now(),updated_at=now()
      from candidate c
     where j.id=c.id
     returning j.id,j.track_id,j.storage_object_key,j.attempts
  )
  select id,track_id,storage_object_key,attempts from claimed;
$$;

revoke all on function public.claim_storage_deletion_job() from public,anon,authenticated;
grant execute on function public.claim_storage_deletion_job() to service_role;
