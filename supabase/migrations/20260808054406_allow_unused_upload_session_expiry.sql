begin;

alter table private.music_upload_sessions
  drop constraint music_upload_session_single_use;

alter table private.music_upload_sessions
  add constraint music_upload_session_single_use check (
    (
      used_at is null
      and status in ('prepared', 'uploaded', 'expired', 'cancelled')
    )
    or (
      used_at is not null
      and status in ('processing', 'completed', 'failed', 'expired', 'cancelled')
    )
  );

commit;
