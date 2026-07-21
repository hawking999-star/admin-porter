begin;

-- A tabela existente deixa de ser somente um snapshot final: cada linha passa a
-- representar o ciclo de uma faixa da solicitacao, inclusive antes do download.
alter table public.playlist_request_tracks
  alter column track_id drop not null,
  add column if not exists item_status text not null default 'pending',
  add column if not exists source_track_id text,
  add column if not exists source_url text,
  add column if not exists youtube_url text,
  add column if not exists youtube_video_id text,
  add column if not exists title text,
  add column if not exists artists jsonb not null default '[]'::jsonb,
  add column if not exists album text,
  add column if not exists duration_ms integer,
  add column if not exists match_confidence numeric,
  add column if not exists error_message text,
  add column if not exists metadata jsonb not null default '{}'::jsonb,
  add column if not exists updated_at timestamptz not null default now();

update public.playlist_request_tracks
   set item_status = 'completed',
       updated_at = now()
 where item_status = 'pending'
   and track_id is not null;

alter table public.playlist_request_tracks
  add constraint playlist_request_tracks_item_status_check
  check (item_status in (
    'pending', 'resolving', 'resolved', 'review_recommended', 'processing',
    'completed', 'not_found', 'failed', 'skipped', 'duplicate',
    'duration_exceeded', 'playlist_limit_exceeded'
  ));

create index playlist_request_tracks_request_status_idx
  on public.playlist_request_tracks (playlist_request_id, item_status, position);

comment on column public.playlist_request_tracks.item_status is
  'Estado individual da faixa na solicitacao; independente do status principal.';
comment on column public.playlist_request_tracks.source_track_id is
  'ID externo da faixa, por exemplo Spotify track ID.';
comment on column public.playlist_request_tracks.metadata is
  'Metadados operacionais seguros da resolucao; sem tokens ou caminhos do worker.';

-- O trigger legado que captura playlist_tracks passa a concluir o item ja
-- resolvido pelo worker; se nao houver item, preserva o snapshot historico.
create or replace function public.capture_playlist_request_track()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request_id uuid;
  v_youtube_id text;
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
     where r.playlist_id = new.playlist_id and r.status = 'approved'
     order by r.created_at desc limit 1;
  end if;
  if v_request_id is null then return new; end if;

  select t.metadata->>'youtube_id' into v_youtube_id
    from public.tracks t where t.id = new.track_id;

  update public.playlist_request_tracks
     set track_id = new.track_id,
         item_status = 'completed',
         updated_at = now(),
         captured_at = now()
   where playlist_request_id = v_request_id
     and youtube_video_id = v_youtube_id
     and item_status not in ('duplicate', 'playlist_limit_exceeded');

  if not found then
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
