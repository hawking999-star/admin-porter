-- A tela pode ler o último job, mas uma playlist mantém histórico de reimportações.
-- Dispensa a faixa em todos os relatórios dessa playlist para ela não reaparecer
-- quando a ordenação ou a fonte exibida mudar.

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

  with candidates as (
    select id, error_details
    from public.download_jobs
    where playlist_id = p_playlist_id
      and error_details is not null
      and jsonb_typeof(error_details->'skipped') = 'array'
    for update
  ), filtered as (
    select
      c.id,
      c.error_details,
      (
        select coalesce(jsonb_agg(item), '[]'::jsonb)
        from jsonb_array_elements(c.error_details->'skipped') item
        where item->>'youtube_id' is distinct from p_youtube_id
      ) as skipped
    from candidates c
  )
  update public.download_jobs job
  set error_details = case
    when jsonb_array_length(filtered.skipped) = 0 then null
    when filtered.error_details ? 'summary' then
      jsonb_set(
        jsonb_set(filtered.error_details, '{skipped}', filtered.skipped),
        '{summary,failed}',
        to_jsonb(jsonb_array_length(filtered.skipped))
      )
    else jsonb_set(filtered.error_details, '{skipped}', filtered.skipped)
  end
  from filtered
  where job.id = filtered.id;
end
$$;

revoke all on function public.admin_dismiss_skipped_track(uuid, text) from public, anon;
grant execute on function public.admin_dismiss_skipped_track(uuid, text) to authenticated;
