-- Higiene de segurança: a tabela public.playlists ainda tinha grants para o papel
-- anon (SELECT/INSERT/UPDATE/DELETE/etc). A RLS já bloqueia (só existe a policy
-- admin_all e a policy de leitura do operador foi removida no contrato de playlists),
-- mas o grant a anon contradiz o princípio de menor privilégio e o restante do
-- contrato (tracks e playlist_tracks já não têm nenhum grant para anon/authenticated).
--
-- NÃO revogamos de authenticated: o Admin lê playlists diretamente via
-- supabase.from('playlists') e depende desse grant (o operador continua bloqueado
-- pela RLS, pois só há a policy admin_all).

revoke all on public.playlists from anon;
