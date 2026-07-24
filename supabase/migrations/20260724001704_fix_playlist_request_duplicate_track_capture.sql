begin;

-- Um mesmo vídeo do YouTube pode ser o melhor resultado de duas posições do
-- Spotify. O histórico preserva as duas posições, mas só uma pode referenciar
-- o mesmo track_id por solicitação. O trigger precisa atualizar somente a
-- posição que acabou de entrar na playlist, nunca todas as posições com o
-- mesmo youtube_video_id.
create or replace function public.normalize_duplicate_playlist_request_track()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if new.item_status = 'duplicate' then
    new.track_id := null;
  end if;
  return new;
end;
$$;

drop trigger if exists trg_normalize_duplicate_playlist_request_track
  on public.playlist_request_tracks;

create trigger trg_normalize_duplicate_playlist_request_track
before insert or update of item_status, track_id
on public.playlist_request_tracks
for each row
execute function public.normalize_duplicate_playlist_request_track();

create or replace function public.capture_playlist_request_track()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request_id uuid;
  v_youtube_id text;
  v_item_id uuid;
begin
  select j.playlist_request_id into v_request_id
    from public.download_jobs j
   where j.playlist_id = new.playlist_id
     and j.status in ('running', 'done', 'partial')
   order by j.created_at desc
   limit 1;

  if v_request_id is null then
    select r.id into v_request_id
      from public.playlist_requests r
     where r.playlist_id = new.playlist_id
       and r.status = 'approved'
     order by r.created_at desc
     limit 1;
  end if;
  if v_request_id is null then
    return new;
  end if;

  select t.metadata ->> 'youtube_id' into v_youtube_id
    from public.tracks t
   where t.id = new.track_id;

  select prt.id into v_item_id
    from public.playlist_request_tracks prt
   where prt.playlist_request_id = v_request_id
     and prt.position = new.position
     and prt.youtube_video_id is not distinct from v_youtube_id
     and prt.track_id is null
     and prt.item_status not in ('duplicate', 'playlist_limit_exceeded')
   order by prt.updated_at desc, prt.id
   limit 1
   for update;

  if v_item_id is not null then
    update public.playlist_request_tracks
       set track_id = new.track_id,
           item_status = 'completed',
           updated_at = now(),
           captured_at = now()
     where id = v_item_id;
  else
    insert into public.playlist_request_tracks (
      playlist_request_id, track_id, position, captured_at, item_status,
      youtube_video_id, updated_at
    ) values (
      v_request_id, new.track_id, greatest(new.position, 0), now(), 'completed',
      v_youtube_id, now()
    ) on conflict (playlist_request_id, track_id) do update
      set position = excluded.position,
          item_status = 'completed',
          updated_at = now();
  end if;

  return new;
end;
$$;

commit;
