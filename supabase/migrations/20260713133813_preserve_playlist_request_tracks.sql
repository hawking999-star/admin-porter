begin;

-- Cada envio passa a ter um snapshot proprio das faixas importadas. A playlist
-- principal continua sendo o estado ativo do App, enquanto o historico deixa de
-- depender dos vinculos mutaveis de playlist_tracks.
create table public.playlist_request_tracks (
  id uuid primary key default gen_random_uuid(),
  playlist_request_id uuid not null references public.playlist_requests(id) on delete cascade,
  track_id uuid not null references public.tracks(id) on delete restrict,
  position integer not null check (position >= 0),
  captured_at timestamptz not null default now(),
  constraint playlist_request_tracks_request_track_key unique (playlist_request_id, track_id)
);

create index playlist_request_tracks_request_position_idx
  on public.playlist_request_tracks (playlist_request_id, position, captured_at);

alter table public.playlist_request_tracks enable row level security;
revoke all on table public.playlist_request_tracks from public, anon, authenticated;

alter table public.download_jobs
  add column playlist_request_id uuid references public.playlist_requests(id) on delete set null;

create index download_jobs_playlist_request_created_idx
  on public.download_jobs (playlist_request_id, created_at desc)
  where playlist_request_id is not null;

-- Associa os jobs antigos a solicitacao que tem a mesma playlist/link e cuja
-- decisao administrativa aconteceu mais perto da criacao do job.
update public.download_jobs j
set playlist_request_id = (
  select r.id
  from public.playlist_requests r
  where r.playlist_id = j.playlist_id
    and r.source_url = j.source_url
    and r.status = 'approved'
  order by abs(extract(epoch from (coalesce(r.decided_at, r.updated_at) - j.created_at))), r.created_at desc
  limit 1
)
where j.playlist_request_id is null;

-- Ao aprovar um novo envio, preserva o estado ativo anterior antes que o Worker
-- substitua playlist_tracks e liga o job recem-criado ao novo envio.
create function public.preserve_playlist_request_on_approval()
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
    select v_previous_request, pt.track_id, greatest(pt.position, 0), now()
    from public.playlist_tracks pt
    where pt.playlist_id = new.playlist_id
    on conflict (playlist_request_id, track_id) do update
      set position = excluded.position;
  end if;

  update public.download_jobs j
  set playlist_request_id = new.id
  where j.id = (
    select candidate.id
    from public.download_jobs candidate
    where candidate.playlist_id = new.playlist_id
      and candidate.source_url = new.source_url
      and candidate.playlist_request_id is null
      and candidate.status in ('queued', 'running')
    order by candidate.created_at desc
    limit 1
  );

  return new;
end;
$$;

revoke all on function public.preserve_playlist_request_on_approval() from public, anon, authenticated;

create trigger trg_preserve_playlist_request_on_approval
after update of status on public.playlist_requests
for each row
when (new.status = 'approved' and old.status is distinct from new.status)
execute function public.preserve_playlist_request_on_approval();

-- Toda faixa gravada pelo Worker tambem e registrada no snapshot do envio que
-- originou o job em execucao. O fallback cobre clientes antigos sem job ligado.
create function public.capture_playlist_request_track()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_request_id uuid;
begin
  select j.playlist_request_id into v_request_id
  from public.download_jobs j
  where j.playlist_id = new.playlist_id
    and j.playlist_request_id is not null
    and j.status in ('queued', 'running')
  order by j.created_at desc
  limit 1;

  if v_request_id is null then
    select r.id into v_request_id
    from public.playlist_requests r
    join public.playlists p on p.id = r.playlist_id
    where r.playlist_id = new.playlist_id
      and r.status = 'approved'
      and r.source_url = p.source_url
    order by coalesce(r.decided_at, r.updated_at) desc, r.created_at desc
    limit 1;
  end if;

  if v_request_id is not null then
    insert into public.playlist_request_tracks (
      playlist_request_id, track_id, position, captured_at
    ) values (
      v_request_id, new.track_id, greatest(new.position, 0), now()
    )
    on conflict (playlist_request_id, track_id) do update
      set position = excluded.position;
  end if;

  return new;
end;
$$;

revoke all on function public.capture_playlist_request_track() from public, anon, authenticated;

create trigger trg_capture_playlist_request_track
after insert or update of playlist_id, track_id, position on public.playlist_tracks
for each row execute function public.capture_playlist_request_track();

-- Snapshot do estado ativo atual para todos os envios cujo ultimo job ja foi
-- associado. Isso torna a migracao util tambem para historicos anteriores.
insert into public.playlist_request_tracks (
  playlist_request_id, track_id, position, captured_at
)
select latest.playlist_request_id, pt.track_id, greatest(pt.position, 0), now()
from public.playlist_tracks pt
join lateral (
  select j.playlist_request_id
  from public.download_jobs j
  where j.playlist_id = pt.playlist_id
    and j.playlist_request_id is not null
    and j.status in ('done', 'partial', 'running', 'queued')
  order by j.created_at desc
  limit 1
) latest on true
on conflict (playlist_request_id, track_id) do update
  set position = excluded.position;

-- Recuperacao dirigida por evidencia para a primeira playlist da Karoline.
-- O job concluido tem total=completed=26 e os 26 tracks foram criados dentro
-- da janela exclusiva desse job. Em outros ambientes, a CTE nao encontra dados.
with recovery_job as (
  select j.*, r.id as request_row_id
  from public.download_jobs j
  join public.playlist_requests r
    on r.playlist_id = j.playlist_id
   and r.source_url = j.source_url
   and r.status = 'approved'
  join public.operators o on o.id = r.operator_id
  where o.username = 'karoline.moura'
    and j.source_url = 'https://youtube.com/playlist?list=PLNXibcaTy19dVD5muIJSiN9EWv5Wy_t2w&si=yMXpkI7E_qtVTv4T'
    and j.status = 'done'
    and j.total = 26
    and j.completed = 26
    and j.failed = 0
  order by j.created_at
  limit 1
), recovered_tracks as (
  select
    j.request_row_id,
    t.id as track_id,
    row_number() over (order by t.created_at)::integer as position,
    count(*) over () as recovered_count
  from recovery_job j
  join public.tracks t
    on t.created_at between j.started_at - interval '5 seconds'
                        and j.finished_at + interval '5 seconds'
   and t.status in ('available', 'processing')
   and nullif(t.metadata->>'youtube_id', '') is not null
)
insert into public.playlist_request_tracks (
  playlist_request_id, track_id, position, captured_at
)
select request_row_id, track_id, position, now()
from recovered_tracks
where recovered_count = 26
on conflict (playlist_request_id, track_id) do update
  set position = excluded.position;

-- Reimporta exatamente o link de um envio historico aprovado. O job recebe o
-- request_id para que o trigger continue capturando as faixas no snapshot certo.
create function public.admin_reimport_playlist_request(p_request uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_request public.playlist_requests%rowtype;
  v_playlist public.playlists%rowtype;
  v_job_id uuid;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid() and active is true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select * into v_request
  from public.playlist_requests
  where id = p_request
  for update;

  if v_request.id is null then
    raise exception 'playlist_request_not_found';
  end if;

  select * into v_playlist
  from public.playlists
  where id = v_request.playlist_id
  for update;

  if v_playlist.id is null then
    raise exception 'playlist_not_found';
  end if;

  if not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(v_playlist.unit_id) then
    raise exception 'forbidden';
  end if;

  if v_request.status <> 'approved' then
    raise exception 'playlist_request_not_approved';
  end if;

  if public.playlist_source_platform(v_request.source_url) <> 'youtube' then
    raise exception 'unsupported_platform';
  end if;

  if exists (
    select 1 from public.download_jobs
    where playlist_id = v_playlist.id and status in ('queued', 'running')
  ) then
    raise exception 'import_already_running';
  end if;

  update public.playlists
  set source_url = v_request.source_url,
      approval_status = 'approved',
      import_status = 'processing',
      error_code = null,
      error_message = null,
      error_details = null,
      last_error_at = null,
      import_started_at = now(),
      import_finished_at = null,
      updated_at = now(),
      revision = revision + 1
  where id = v_playlist.id;

  insert into public.download_jobs (
    playlist_id, playlist_request_id, source_url, status, attempts,
    mode, created_at, updated_at
  ) values (
    v_playlist.id, v_request.id, v_request.source_url, 'queued', 0,
    'playlist', now(), now()
  ) returning id into v_job_id;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id,
    before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    'playlist_request_reimported',
    'playlist_requests',
    v_request.id,
    to_jsonb(v_playlist),
    jsonb_build_object(
      'playlist_id', v_playlist.id,
      'playlist_request_id', v_request.id,
      'source_url', v_request.source_url,
      'download_job_id', v_job_id
    ),
    now()
  );
end;
$$;

revoke all on function public.admin_reimport_playlist_request(uuid) from public, anon;
grant execute on function public.admin_reimport_playlist_request(uuid) to authenticated;

-- Mantem a paginacao existente e troca apenas a origem do historico: agora ele
-- vem de playlist_requests e inclui o snapshot de faixas de cada envio.
alter function public.admin_music_library_page(integer, integer, text)
  rename to admin_music_library_page_impl;
revoke all on function public.admin_music_library_page_impl(integer, integer, text)
  from public, anon, authenticated;

create function public.admin_music_library_page(
  p_limit integer default 12,
  p_offset integer default 0,
  p_search text default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_rows jsonb := '[]'::jsonb;
begin
  v_payload := public.admin_music_library_page_impl(p_limit, p_offset, p_search);

  select coalesce(jsonb_agg(
    operator_row || jsonb_build_object(
      'request_history', coalesce((
        select jsonb_agg(jsonb_build_object(
          'id', r.id,
          'playlist_id', r.playlist_id,
          'name', p.name,
          'type', p.type,
          'approval_status', r.status,
          'import_status', case latest_job.status
            when 'queued' then 'processing'
            when 'running' then 'processing'
            when 'done' then 'success'
            when 'partial' then 'failed'
            when 'error' then 'failed'
            else case when snapshot.track_count > 0 then 'success' else 'not_started' end
          end,
          'source_url', r.source_url,
          'submitted_at', r.created_at,
          'reviewed_at', r.decided_at,
          'rejection_reason', r.rejection_reason,
          'error_message', coalesce(latest_job.error_message, latest_job.error),
          'track_count', snapshot.track_count,
          'latest_job', latest_job.job,
          'tracks', snapshot.tracks
        ) order by r.created_at desc, r.id desc)
        from public.playlist_requests r
        join public.playlists p on p.id = r.playlist_id
        left join lateral (
          select
            count(*)::integer as track_count,
            coalesce(jsonb_agg(jsonb_build_object(
              'playlist_track_id', prt.id,
              'track_id', t.id,
              'position', prt.position,
              'title', t.title,
              'artist', t.artist,
              'duration_ms', t.duration_ms,
              'source_url', t.metadata->>'source_url',
              'public_url', t.metadata->>'public_url',
              'status', t.status,
              'added_by_type', 'snapshot',
              'created_at', prt.captured_at,
              'updated_at', t.updated_at
            ) order by prt.position, prt.captured_at), '[]'::jsonb) as tracks
          from public.playlist_request_tracks prt
          join public.tracks t on t.id = prt.track_id
          where prt.playlist_request_id = r.id
            and t.status in ('available', 'processing')
        ) snapshot on true
        left join lateral (
          select
            j.status, j.error, j.error_message,
            to_jsonb(j) - 'error_details' as job
          from public.download_jobs j
          where j.playlist_request_id = r.id
          order by j.created_at desc
          limit 1
        ) latest_job on true
        where r.operator_id = (operator_row->>'id')::uuid
        limit 50
      ), '[]'::jsonb)
    )
    order by operator_row->>'display_name'
  ), '[]'::jsonb)
  into v_rows
  from jsonb_array_elements(coalesce(v_payload->'rows', '[]'::jsonb)) operator_row;

  return jsonb_set(v_payload, '{rows}', v_rows, true);
end;
$$;

revoke all on function public.admin_music_library_page(integer, integer, text) from public, anon;
grant execute on function public.admin_music_library_page(integer, integer, text) to authenticated;

commit;
