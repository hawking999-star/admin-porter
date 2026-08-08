begin;

alter table private.music_upload_sessions
  add column cleanup_status text not null default 'pending'
    check (cleanup_status in ('pending', 'running', 'done', 'error')),
  add column cleanup_attempts integer not null default 0 check (cleanup_attempts >= 0),
  add column cleanup_next_attempt_at timestamptz not null default now(),
  add column cleanup_locked_at timestamptz,
  add column cleanup_error text,
  add column staging_deleted_at timestamptz;

create index music_upload_sessions_cleanup_claim_idx
  on private.music_upload_sessions (cleanup_status, cleanup_next_attempt_at, expires_at)
  where staging_deleted_at is null;

create or replace function public.worker_claim_expired_music_upload_session()
returns table (session_id uuid, staging_object_key text)
language plpgsql
security definer
set search_path = ''
as $$
begin
  return query
  with candidate as (
    select upload.id
      from private.music_upload_sessions upload
     where upload.staging_deleted_at is null
       and (
         (upload.status = 'prepared' and upload.expires_at <= now())
         or (
           upload.status = 'expired'
           and upload.cleanup_status in ('pending', 'error')
           and upload.cleanup_next_attempt_at <= now()
         )
       )
     order by upload.cleanup_next_attempt_at, upload.expires_at, upload.id
     for update skip locked
     limit 1
  )
  update private.music_upload_sessions upload
     set status = 'expired',
         cleanup_status = 'running',
         cleanup_attempts = upload.cleanup_attempts + 1,
         cleanup_locked_at = now(),
         cleanup_error = null,
         updated_at = now()
    from candidate
   where upload.id = candidate.id
  returning upload.id, upload.staging_object_key;
end;
$$;

create or replace function public.worker_complete_expired_music_upload_cleanup(
  p_session_id uuid,
  p_success boolean,
  p_error text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_session private.music_upload_sessions%rowtype;
  v_delay integer;
  v_terminal boolean;
begin
  select * into v_session
    from private.music_upload_sessions
   where id = p_session_id
   for update;
  if not found then raise exception 'music_upload_session_not_found'; end if;
  if v_session.cleanup_status <> 'running' then raise exception 'music_upload_cleanup_not_claimed'; end if;

  if p_success then
    update private.music_upload_sessions
       set cleanup_status = 'done',
           cleanup_locked_at = null,
           cleanup_error = null,
           staging_deleted_at = now(),
           updated_at = now()
     where id = p_session_id;
    return pg_catalog.jsonb_build_object('terminal', true, 'deleted', true);
  end if;

  v_terminal := v_session.cleanup_attempts >= 5;
  v_delay := case v_session.cleanup_attempts
    when 1 then 60
    when 2 then 300
    when 3 then 900
    else 3600
  end;
  update private.music_upload_sessions
     set cleanup_status = case when v_terminal then 'error' else 'pending' end,
         cleanup_locked_at = null,
         cleanup_error = left(coalesce(p_error, 'R2 cleanup failed'), 1000),
         cleanup_next_attempt_at = now() + pg_catalog.make_interval(secs => v_delay),
         updated_at = now()
   where id = p_session_id;
  return pg_catalog.jsonb_build_object(
    'terminal', v_terminal,
    'retry_after_seconds', v_delay
  );
end;
$$;

revoke all on function public.worker_claim_expired_music_upload_session() from public, anon, authenticated;
revoke all on function public.worker_complete_expired_music_upload_cleanup(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.worker_claim_expired_music_upload_session() to service_role;
grant execute on function public.worker_complete_expired_music_upload_cleanup(uuid, boolean, text) to service_role;

commit;
