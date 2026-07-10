-- Security advisors hardening (2026-07-08)
-- (a) Revogar EXECUTE de anon/public em 16 funcoes SECURITY DEFINER que
--     exigem autenticacao; manter apenas 'authenticated'.
-- (b) Fixar search_path nas 2 funcoes helper marcadas como mutable.

-- (a) Bloquear execucao anonima ------------------------------------------
do $$
declare r record;
begin
  for r in
    select p.oid::regprocedure::text as sig
    from pg_proc p join pg_namespace n on n.oid = p.pronamespace
    where n.nspname = 'public'
      and p.proname = any (array[
        'admin_archive_secondary_playlist','admin_can_manage_operator_unit',
        'admin_music_library','admin_operator_email','admin_remove_playlist_track',
        'admin_rename_music_playlist','admin_retry_playlist_import','admin_review_playlist',
        'admin_set_operator_shift','audit_admin_change','get_my_playlists','is_superadmin',
        'submit_feedback','submit_playlist','sync_playlist_import_from_job',
        'sync_playlist_review_import_defaults'])
  loop
    execute format('revoke all on function %s from public, anon;', r.sig);
    execute format('grant execute on function %s to authenticated;', r.sig);
  end loop;
end $$;

-- (b) search_path fixo nas helpers ---------------------------------------
CREATE OR REPLACE FUNCTION public.playlist_source_platform(p_url text)
 RETURNS text
 LANGUAGE sql
 IMMUTABLE
 SET search_path = ''
AS $function$
  select case
    when p_url is null or btrim(p_url) = '' then 'none'
    when p_url !~* '^https?://' then 'invalid'
    when p_url ~* '(^https?://)?([^/]+\.)?(youtube\.com|youtu\.be)(/|$)' then 'youtube'
    when p_url ~* '(^https?://)?([^/]+\.)?spotify\.com(/|$)' then 'spotify'
    else 'unsupported'
  end
$function$;

CREATE OR REPLACE FUNCTION public.playlist_import_error_message(p_error_code text, p_raw_message text DEFAULT NULL::text)
 RETURNS text
 LANGUAGE sql
 STABLE
 SET search_path = ''
AS $function$
  select case p_error_code
    when 'INVALID_URL' then 'Link inválido ou plataforma não suportada.'
    when 'UNSUPPORTED_PLATFORM' then 'Plataforma não suportada pelo importador.'
    when 'PLAYLIST_PRIVATE_OR_UNAVAILABLE' then 'Playlist privada ou indisponível.'
    when 'PLAYLIST_EMPTY' then 'Playlist vazia ou sem músicas disponíveis.'
    when 'YOUTUBE_ERROR' then 'Falha no YouTube ao ler ou baixar a playlist.'
    when 'YOUTUBE_COOKIES_MISSING' then 'Falha ao importar: YouTube exigiu autenticação e a variável YOUTUBE_COOKIES não está configurada.'
    when 'YOUTUBE_FORMAT_UNAVAILABLE' then 'Falha no YouTube: nenhum formato de áudio disponível para download no ambiente do importador.'
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
$function$;
