-- Preserva o relatório de importação (faixas indisponíveis) mesmo quando o job
-- termina como SUCESSO. Antes, error_details só era copiado para a playlist em
-- caso de falha; agora, se o worker enviar um relatório (indisponíveis), ele é
-- mantido para o admin exibir de forma NEUTRA, sem parecer erro.
--
-- Comportamento novo do worker: importou tudo que dava e só sobraram faixas
-- indisponíveis (geo-bloqueio, sem formato, removidas) => job 'done' (success),
-- porém com error_details.skipped preenchido. Esta trigger passa a preservar isso.

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
      -- Sucesso COM relatório de indisponíveis: preserva para o admin mostrar neutro.
      when new.error_details is not null then new.error_details
      else null
    end,
    last_error_at = case when v_import_status = 'failed' then coalesce(new.last_error_at, now()) else null end
  where id = new.playlist_id;

  return new;
end
$$;
