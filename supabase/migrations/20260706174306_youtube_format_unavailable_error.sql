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
$$;
