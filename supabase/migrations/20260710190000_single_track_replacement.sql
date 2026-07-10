-- Troca manual de faixa: reimportar UMA faixa indisponível colando outra URL do
-- YouTube, sem reprocessar a playlist inteira.

-- 1) download_jobs ganha um "modo" e o id da faixa que está sendo substituída.
alter table public.download_jobs
  add column if not exists mode text not null default 'playlist',
  add column if not exists replace_youtube_id text;

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'download_jobs_mode_check' and conrelid = 'public.download_jobs'::regclass
  ) then
    alter table public.download_jobs
      add constraint download_jobs_mode_check check (mode in ('playlist', 'single_track'));
  end if;
end $$;

-- 2) Guarda na trigger: um job de faixa única NÃO altera o status/relatório geral
--    da playlist (o worker ajusta só a faixa trocada).
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
  if coalesce(new.mode, 'playlist') <> 'playlist' then
    return new;  -- single_track: não mexe no import_status nem no relatório da playlist
  end if;

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
      when new.error_details is not null then new.error_details
      else null
    end,
    last_error_at = case when v_import_status = 'failed' then coalesce(new.last_error_at, now()) else null end
  where id = new.playlist_id;

  return new;
end
$$;

-- 3) RPC: admin enfileira a reimportação de UMA faixa (cola a nova URL).
create or replace function public.admin_enqueue_track_replacement(
  p_playlist_id uuid,
  p_source_url text,
  p_replace_youtube_id text default null
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.admin_users%rowtype;
  v_job uuid;
  v_url text := btrim(coalesce(p_source_url, ''));
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  if v_url = '' or (v_url !~* 'youtube\.com' and v_url !~* 'youtu\.be') then
    raise exception 'invalid_url';
  end if;

  if not exists (select 1 from public.playlists where id = p_playlist_id) then
    raise exception 'playlist_not_found';
  end if;

  insert into public.download_jobs (playlist_id, source_url, status, mode, replace_youtube_id)
  values (p_playlist_id, v_url, 'queued', 'single_track', nullif(btrim(coalesce(p_replace_youtube_id, '')), ''))
  returning id into v_job;

  return v_job;
end
$$;

revoke all on function public.admin_enqueue_track_replacement(uuid, text, text) from public, anon;
grant execute on function public.admin_enqueue_track_replacement(uuid, text, text) to authenticated;
