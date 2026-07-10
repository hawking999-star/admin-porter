-- Botão "OK" no relatório de importação: o admin dispensa uma faixa indisponível,
-- tirando-a do relatório sem precisar trocar por outra. Só remove do error_details.

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
  v_details jsonb;
  v_skipped jsonb;
  v_new jsonb;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager', 'content_manager'],
    null
  );

  select error_details into v_details
  from public.playlists
  where id = p_playlist_id
  for update;

  if v_details is null then
    return;
  end if;

  v_skipped := v_details->'skipped';
  if v_skipped is null or jsonb_typeof(v_skipped) <> 'array' then
    return;
  end if;

  select coalesce(jsonb_agg(elem), '[]'::jsonb) into v_new
  from jsonb_array_elements(v_skipped) elem
  where elem->>'youtube_id' is distinct from p_youtube_id;

  if jsonb_array_length(v_new) = 0 then
    update public.playlists set error_details = null where id = p_playlist_id;
  else
    v_details := jsonb_set(v_details, '{skipped}', v_new);
    if v_details ? 'summary' then
      v_details := jsonb_set(v_details, '{summary,failed}', to_jsonb(jsonb_array_length(v_new)));
    end if;
    update public.playlists set error_details = v_details where id = p_playlist_id;
  end if;
end
$$;

revoke all on function public.admin_dismiss_skipped_track(uuid, text) from public, anon;
grant execute on function public.admin_dismiss_skipped_track(uuid, text) to authenticated;
