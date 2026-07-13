begin;

-- A Playlist principal e cumulativa: durante um job do Worker, o DELETE usado
-- para sincronizar o novo link nao pode remover musicas importadas anteriormente.
-- Remocoes administrativas continuam funcionando quando nao ha importacao ativa.
create function public.keep_principal_tracks_during_import()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if exists (
    select 1
    from public.playlists p
    join public.download_jobs j on j.playlist_id = p.id
    where p.id = old.playlist_id
      and p.type = 'principal'
      and j.status in ('queued', 'running')
  ) then
    return null;
  end if;

  return old;
end;
$$;

revoke all on function public.keep_principal_tracks_during_import()
  from public, anon, authenticated;

create trigger trg_keep_principal_tracks_during_import
before delete on public.playlist_tracks
for each row execute function public.keep_principal_tracks_during_import();

-- Recoloca no estado ativo as faixas historicas que ja foram comprovadamente
-- importadas. O trigger de captura e pausado somente durante este backfill para
-- nao atribuir faixas antigas ao envio mais recente.
alter table public.playlist_tracks disable trigger trg_capture_playlist_request_track;

with historical_tracks as (
  select distinct on (p.id, prt.track_id)
    p.id as playlist_id,
    prt.track_id,
    r.created_at as request_created_at,
    prt.position as request_position,
    prt.id as snapshot_id
  from public.playlists p
  join public.playlist_requests r on r.playlist_id = p.id and r.status = 'approved'
  join public.playlist_request_tracks prt on prt.playlist_request_id = r.id
  where p.type = 'principal'
    and p.status <> 'archived'
  order by p.id, prt.track_id, r.created_at, prt.position, prt.id
), missing_tracks as (
  select h.*
  from historical_tracks h
  where not exists (
    select 1
    from public.playlist_tracks current_track
    where current_track.playlist_id = h.playlist_id
      and current_track.track_id = h.track_id
  )
), ranked_tracks as (
  select
    m.*,
    row_number() over (
      partition by m.playlist_id
      order by m.request_created_at, m.request_position, m.snapshot_id
    )::integer as append_position
  from missing_tracks m
), playlist_max as (
  select
    r.playlist_id,
    coalesce(max(pt.position), 0) as max_position
  from ranked_tracks r
  left join public.playlist_tracks pt on pt.playlist_id = r.playlist_id
  group by r.playlist_id
), restored as (
  insert into public.playlist_tracks (
    playlist_id, track_id, position, added_by_type, added_by_id
  )
  select
    r.playlist_id,
    r.track_id,
    m.max_position + r.append_position,
    'system',
    null
  from ranked_tracks r
  join playlist_max m on m.playlist_id = r.playlist_id
  on conflict (playlist_id, track_id) do nothing
  returning playlist_id
)
update public.playlists p
set revision = p.revision + 1,
    updated_at = now()
where p.id in (select distinct playlist_id from restored);

alter table public.playlist_tracks enable trigger trg_capture_playlist_request_track;

commit;
