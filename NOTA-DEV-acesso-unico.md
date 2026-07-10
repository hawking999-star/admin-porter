# Acesso único: um login serve para app + painel

Resumo do que mudou e o que o app precisa conferir.

## O que mudou (conceito)

Antes, um login (`auth.users`) só podia ser **operador do app** OU **admin do painel** — nunca os dois. Agora os dois viram **selos independentes** sobre o mesmo login: a mesma pessoa pode entrar no app e no painel com a mesma senha.

Regra de entrada no painel: passou a depender **só** de existir uma linha ativa em `admin_users` para aquele `auth_user_id`. Ser operador não bloqueia mais o admin.

## Backend (Supabase — projeto `porter music` / `aifadvyxsefxfcgzgqol`)

Migration **`20260710160000_panel_access_dual_profile.sql`** — **já aplicada no remoto**. Sem tabelas novas, sem alterar colunas. Só adiciona duas RPCs (superadmin-only, auditadas em `admin_audit_logs`):

- `admin_grant_panel_access(p_operator uuid, p_mfa_required boolean)` — promove um operador do app a acesso ao painel (como `superadmin`), reaproveitando o login existente.
- `admin_grant_app_access(p_admin_user uuid, p_username text, p_unit_id uuid, p_role text, p_session_policy text)` — cria um perfil de operador para quem só tinha acesso ao painel, usando o mesmo login.

## O que o APP precisa verificar (ação do dev do app)

1. **Login por username continua funcionando** quando o mesmo `auth_user_id` também está em `admin_users`. O fluxo de login do app (ex.: `resolve-login-email` / RPCs `app_login_*`) **não pode rejeitar** um usuário só porque ele também é admin. Se houver qualquer checagem que exclua admins, remover.
2. **Nada de bloqueio cruzado**: sessão do app e sessão do painel são independentes (apps/domínios diferentes). Não é preciso unificar sessão — só garantir que uma não invalida a outra.
3. **Sem migração de dados**: operadores e acessos existentes continuam iguais. A novidade é apenas permitir sobreposição.

## Admin (este repositório) — precisa de deploy

- `AuthProvider`: portão de entrada agora checa só `admin_users`.
- Tela **Operadores e acessos → Acessos ao painel**: botão **"Dar acesso ao painel"** (promove operador do app) e ação **"Dar acesso ao app"** por linha (o caso "meu login de admin também entra no app").
- Papéis do painel reduzidos a **Super admin** (o backend ainda aceita os papéis antigos; só a tela foi simplificada).
