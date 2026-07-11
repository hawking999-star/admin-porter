-- Corrige o botão "OK" do relatório de importação.
--
-- O admin lia o relatório de duas fontes:
--   1. playlists.error_details
--   2. download_jobs.error_details do job mais recente
--
-- A versão anterior limpava só playlists.error_details. Quando a tela refazia a
-- leitura, a mesma faixa voltava pelo download_jobs.error_details.

create or replace function public.admin_dismiss_skipped_track(
  p_playlist_id uuid,
  p_youtube_id text
)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin public.admin_users%rowtype;
  v_playlist_details jsonb;
  v_job_id uuid;
  v_job_details jsonb;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  if nullif(btrim(coalesce(p_youtube_id, '')), '') is null then
    raise exception 'youtube_id_required';
  end if;

  select error_details into v_playlist_details
  from public.playlists
  where id = p_playlist_id
  for update;

  select id, error_details into v_job_id, v_job_details
  from public.download_jobs
  where playlist_id = p_playlist_id
    and error_details is not null
  order by created_at desc
  limit 1
  for update;

  if v_playlist_details is not null and jsonb_typeof(v_playlist_details->'skipped') = 'array' then
    with filtered as (
      select coalesce(jsonb_agg(elem), '[]'::jsonb) as skipped
      from jsonb_array_elements(v_playlist_details->'skipped') elem
      where elem->>'youtube_id' is distinct from p_youtube_id
    )
    select case
      when jsonb_array_length(skipped) = 0 then null
      when v_playlist_details ? 'summary' then
        jsonb_set(
          jsonb_set(v_playlist_details, '{skipped}', skipped),
          '{summary,failed}',
          to_jsonb(jsonb_array_length(skipped))
        )
      else jsonb_set(v_playlist_details, '{skipped}', skipped)
    end
    into v_playlist_details
    from filtered;

    update public.playlists
    set error_details = v_playlist_details
    where id = p_playlist_id;
  end if;

  if v_job_id is not null and v_job_details is not null and jsonb_typeof(v_job_details->'skipped') = 'array' then
    with filtered as (
      select coalesce(jsonb_agg(elem), '[]'::jsonb) as skipped
      from jsonb_array_elements(v_job_details->'skipped') elem
      where elem->>'youtube_id' is distinct from p_youtube_id
    )
    select case
      when jsonb_array_length(skipped) = 0 then null
      when v_job_details ? 'summary' then
        jsonb_set(
          jsonb_set(v_job_details, '{skipped}', skipped),
          '{summary,failed}',
          to_jsonb(jsonb_array_length(skipped))
        )
      else jsonb_set(v_job_details, '{skipped}', skipped)
    end
    into v_job_details
    from filtered;

    update public.download_jobs
    set error_details = v_job_details
    where id = v_job_id;
  end if;
end
$$;

revoke all on function public.admin_dismiss_skipped_track(uuid, text) from public, anon;
grant execute on function public.admin_dismiss_skipped_track(uuid, text) to authenticated;
