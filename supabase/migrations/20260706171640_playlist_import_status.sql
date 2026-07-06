-- Separa status de aprovação do status operacional de importação.
-- Seguro para produção: só adiciona campos ausentes, preserva dados existentes.

alter table public.playlists
  add column if not exists import_status text not null default 'not_started',
  add column if not exists error_message text,
  add column if not exists error_code text,
  add column if not exists error_details jsonb,
  add column if not exists last_error_at timestamptz,
  add column if not exists import_started_at timestamptz,
  add column if not exists import_finished_at timestamptz,
  add column if not exists reviewed_by_admin_id uuid;

alter table public.download_jobs
  add column if not exists error_code text,
  add column if not exists error_message text,
  add column if not exists error_details jsonb,
  add column if not exists last_error_at timestamptz;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'playlists_import_status_check'
      and conrelid = 'public.playlists'::regclass
  ) then
    alter table public.playlists
      add constraint playlists_import_status_check
      check (import_status in ('not_started', 'processing', 'success', 'failed'));
  end if;
end $$;

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'playlists_reviewed_by_admin_id_fkey'
      and conrelid = 'public.playlists'::regclass
  ) then
    alter table public.playlists
      add constraint playlists_reviewed_by_admin_id_fkey
      foreign key (reviewed_by_admin_id) references public.admin_users(id)
      on delete set null;
  end if;
end $$;

create or replace function public.playlist_source_platform(p_url text)
returns text
language sql
immutable
as $$
  select case
    when p_url is null or btrim(p_url) = '' then 'none'
    when p_url !~* '^https?://' then 'invalid'
    when p_url ~* '(^https?://)?([^/]+\.)?(youtube\.com|youtu\.be)(/|$)' then 'youtube'
    when p_url ~* '(^https?://)?([^/]+\.)?spotify\.com(/|$)' then 'spotify'
    else 'unsupported'
  end
$$;

create or replace function public.playlist_import_error_message(
  p_error_code text,
  p_raw_message text default null
)
returns text
language sql
stable
as $$
  select case p_error_code
    when 'INVALID_URL' then 'Link inválido ou plataforma não suportada.'
    when 'UNSUPPORTED_PLATFORM' then 'Plataforma não suportada pelo importador.'
    when 'PLAYLIST_PRIVATE_OR_UNAVAILABLE' then 'Playlist privada ou indisponível.'
    when 'PLAYLIST_EMPTY' then 'Playlist vazia ou sem músicas disponíveis.'
    when 'YOUTUBE_ERROR' then 'Falha no YouTube ao ler ou baixar a playlist.'
    when 'SPOTIFY_UNSUPPORTED' then 'Importação automática de Spotify ainda não está disponível.'
    when 'R2_ACCESS_DENIED' then 'Falha ao salvar no R2: acesso negado.'
    when 'R2_ERROR' then 'Falha ao salvar no R2.'
    when 'SUPABASE_PERMISSION_DENIED' then 'Falha no Supabase: permissão negada.'
    when 'SUPABASE_ERROR' then 'Falha no Supabase ao gravar a importação.'
    when 'IMPORT_TIMEOUT' then 'Falha no importador: tempo limite excedido.'
    when 'WORKER_ENV_MISSING' then 'Falha no importador: variável de ambiente obrigatória ausente.'
    when 'NO_TRACKS_DOWNLOADED' then 'Nenhuma música foi baixada da playlist.'
    else coalesce(nullif(p_raw_message, ''), 'Falha ao importar playlist.')
  end
$$;

create or replace function public.sync_playlist_import_from_job()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_import_status text;
  v_message text;
  v_code text;
begin
  v_import_status := case new.status
    when 'queued' then 'processing'
    when 'running' then 'processing'
    when 'done' then 'success'
    when 'partial' then 'failed'
    when 'error' then 'failed'
    else 'not_started'
  end;

  v_code := coalesce(
    new.error_code,
    case
      when new.status in ('partial', 'error') and coalesce(new.completed, 0) = 0 then 'NO_TRACKS_DOWNLOADED'
      when new.status in ('partial', 'error') then 'PARTIAL_IMPORT_FAILED'
      else null
    end
  );
  v_message := public.playlist_import_error_message(v_code, coalesce(new.error_message, new.error));

  update public.playlists
  set
    import_status = v_import_status,
    import_started_at = case
      when new.status in ('queued', 'running') then coalesce(import_started_at, new.started_at, now())
      else import_started_at
    end,
    import_finished_at = case
      when new.status in ('done', 'partial', 'error') then coalesce(new.finished_at, now())
      else import_finished_at
    end,
    error_code = case when v_import_status = 'failed' then v_code else null end,
    error_message = case when v_import_status = 'failed' then v_message else null end,
    error_details = case
      when v_import_status = 'failed' then coalesce(
        new.error_details,
        jsonb_build_object(
          'download_job_id', new.id,
          'download_status', new.status,
          'raw_error', new.error,
          'completed', new.completed,
          'failed', new.failed,
          'total', new.total
        )
      )
      else null
    end,
    last_error_at = case when v_import_status = 'failed' then coalesce(new.last_error_at, now()) else null end
  where id = new.playlist_id;

  return new;
end
$$;

drop trigger if exists trg_sync_playlist_import_from_job on public.download_jobs;
create trigger trg_sync_playlist_import_from_job
after insert or update of status, total, completed, failed, error, error_code, error_message, error_details, last_error_at, started_at, finished_at
on public.download_jobs
for each row
execute function public.sync_playlist_import_from_job();

create or replace function public.sync_playlist_review_import_defaults()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid;
  v_platform text;
begin
  if new.approval_status is distinct from old.approval_status then
    select id into v_admin_id
    from public.admin_users
    where auth_user_id = auth.uid()
    limit 1;

    if new.approval_status in ('approved', 'rejected') then
      new.reviewed_by_admin_id := coalesce(new.reviewed_by_admin_id, v_admin_id);
      new.reviewed_at := coalesce(new.reviewed_at, now());
    end if;

    if new.approval_status = 'rejected' then
      new.import_status := 'not_started';
      new.import_started_at := null;
      new.import_finished_at := null;
      new.error_code := null;
      new.error_message := null;
      new.error_details := null;
      new.last_error_at := null;
    elsif new.approval_status = 'approved' then
      v_platform := public.playlist_source_platform(new.source_url);

      if v_platform = 'youtube' then
        new.import_status := 'not_started';
        new.error_code := null;
        new.error_message := null;
        new.error_details := null;
        new.last_error_at := null;
      elsif v_platform = 'spotify' then
        new.import_status := 'failed';
        new.error_code := 'SPOTIFY_UNSUPPORTED';
        new.error_message := public.playlist_import_error_message('SPOTIFY_UNSUPPORTED', null);
        new.error_details := jsonb_build_object('platform', v_platform, 'source_url', new.source_url);
        new.last_error_at := now();
      else
        new.import_status := 'failed';
        new.error_code := case when v_platform = 'invalid' then 'INVALID_URL' else 'UNSUPPORTED_PLATFORM' end;
        new.error_message := public.playlist_import_error_message(new.error_code, null);
        new.error_details := jsonb_build_object('platform', v_platform, 'source_url', new.source_url);
        new.last_error_at := now();
      end if;
    end if;
  end if;

  return new;
end
$$;

drop trigger if exists trg_sync_playlist_review_import_defaults on public.playlists;
create trigger trg_sync_playlist_review_import_defaults
before update of approval_status
on public.playlists
for each row
execute function public.sync_playlist_review_import_defaults();

create or replace function public.admin_retry_playlist_import(p_playlist uuid)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist public.playlists%rowtype;
  v_platform text;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  select * into v_playlist
  from public.playlists
  where id = p_playlist
  for update;

  if v_playlist.id is null then
    raise exception 'playlist_not_found';
  end if;

  if v_playlist.approval_status <> 'approved' then
    raise exception 'playlist_not_approved';
  end if;

  v_platform := public.playlist_source_platform(v_playlist.source_url);
  if v_platform <> 'youtube' then
    update public.playlists
    set
      import_status = 'failed',
      error_code = case when v_platform = 'spotify' then 'SPOTIFY_UNSUPPORTED' else 'UNSUPPORTED_PLATFORM' end,
      error_message = public.playlist_import_error_message(
        case when v_platform = 'spotify' then 'SPOTIFY_UNSUPPORTED' else 'UNSUPPORTED_PLATFORM' end,
        null
      ),
      error_details = jsonb_build_object('platform', v_platform, 'source_url', v_playlist.source_url),
      last_error_at = now()
    where id = p_playlist;
    return;
  end if;

  if exists (
    select 1
    from public.download_jobs
    where playlist_id = p_playlist
      and status in ('queued', 'running')
  ) then
    raise exception 'import_already_running';
  end if;

  update public.playlists
  set
    import_status = 'processing',
    error_code = null,
    error_message = null,
    error_details = null,
    last_error_at = null,
    import_started_at = now(),
    import_finished_at = null
  where id = p_playlist;

  insert into public.download_jobs (playlist_id, source_url, status, attempts, created_at, updated_at)
  values (p_playlist, v_playlist.source_url, 'queued', 0, now(), now());
end
$$;

grant execute on function public.admin_retry_playlist_import(uuid) to authenticated;
revoke execute on function public.admin_retry_playlist_import(uuid) from anon;

with latest_job as (
  select distinct on (playlist_id)
    playlist_id,
    status,
    error,
    error_code,
    error_message,
    error_details,
    last_error_at,
    started_at,
    finished_at,
    completed,
    failed,
    total
  from public.download_jobs
  order by playlist_id, created_at desc
)
update public.playlists p
set
  import_status = case latest_job.status
    when 'queued' then 'processing'
    when 'running' then 'processing'
    when 'done' then 'success'
    when 'partial' then 'failed'
    when 'error' then 'failed'
    else p.import_status
  end,
  import_started_at = coalesce(p.import_started_at, latest_job.started_at),
  import_finished_at = coalesce(p.import_finished_at, latest_job.finished_at),
  error_code = case
    when latest_job.status in ('partial', 'error') then coalesce(latest_job.error_code, 'NO_TRACKS_DOWNLOADED')
    else p.error_code
  end,
  error_message = case
    when latest_job.status in ('partial', 'error') then public.playlist_import_error_message(
      coalesce(latest_job.error_code, 'NO_TRACKS_DOWNLOADED'),
      coalesce(latest_job.error_message, latest_job.error)
    )
    else p.error_message
  end,
  error_details = case
    when latest_job.status in ('partial', 'error') then coalesce(
      latest_job.error_details,
      jsonb_build_object(
        'raw_error', latest_job.error,
        'completed', latest_job.completed,
        'failed', latest_job.failed,
        'total', latest_job.total
      )
    )
    else p.error_details
  end,
  last_error_at = case
    when latest_job.status in ('partial', 'error') then coalesce(latest_job.last_error_at, now())
    else p.last_error_at
  end
from latest_job
where p.id = latest_job.playlist_id;
