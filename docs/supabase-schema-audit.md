# PTM ADMIN - Supabase Schema Audit

Data: 2026-07-07

Escopo desta etapa: banco, migrations, RLS, grants, funcoes e documentacao tecnica. Nao houve alteracao de UI ou fluxo visual.

## Resumo

O repositorio dependia de um banco remoto pre-existente: as primeiras migrations eram placeholders com `Baseline remoto ja aplicado em producao`. Isso fazia `supabase db reset` depender de objetos que nao estavam versionados localmente.

A migration `20260704173241_01_org_identity.sql` foi transformada em uma baseline local aditiva e idempotente. Ela declara os objetos centrais usados pelo Admin antes das migrations posteriores que alteram playlists, releases, eventos locais e RPCs administrativas.

## Objetos usados pelo Admin

| Objeto | Tipo | Onde aparece | Status local apos etapa 3 | Impacto se faltar |
| --- | --- | --- | --- | --- |
| `admin_users` | tabela | `AuthProvider`, usuarios, releases, Edge Function `provision-operator`, varias RPCs | definido na baseline | Admin nao autentica/autoriza e RPCs administrativas falham |
| `operators` | tabela | usuarios, overview, feedback, musicas, logs, Edge Function `resolve-login-email` | definido na baseline | Operadores nao listam, login por usuario falha, relatorios quebram |
| `units` | tabela | condominios, usuarios, feedback, musicas | definido na baseline | Condominios, vinculos e escopo administrativo falham |
| `shifts` | tabela | usuarios (`shifts(name, starts_at, ends_at)`), RPC de turno | definido na baseline | Turnos de Operador nao carregam |
| `operator_sessions` | tabela | overview, logs, RPCs operacionais | definido na baseline | Metricas de sessoes e reconciliacao falham |
| `operator_states` | tabela | overview, chamada local, reconciliacao | definido na baseline | Status online/ociosidade/chamada falham |
| `operator_status_history` | tabela | logs, overview diario | definido na baseline | Feed de logs e resumo diario falham |
| `operator_blocks` | tabela | RPCs operacionais | definido na baseline | Bloqueio operacional nao consegue ser calculado |
| `operational_events` | tabela | logs, chamada local | definido na baseline | Eventos de chamada/local nao persistem |
| `app_request_idempotency` | tabela | RPCs operacionais | definido na baseline | Idempotencia de eventos locais falha |
| `system_settings` | tabela | reconciliacao | definido na baseline | Revisao de configuracao falha |
| `feedback` | tabela | feedback, overview, RPC `admin_update_feedback_status` | definido na baseline | Feedback nao lista nem atualiza status |
| `playlists` | tabela | musicas, overview, logs, RPCs de playlist | definido na baseline | Aprovacao/importacao/biblioteca musical falham |
| `playlist_tracks` | tabela | biblioteca musical | definido na baseline | Remocao/listagem de faixas falha |
| `tracks` | tabela | biblioteca musical | definido na baseline | Biblioteca musical nao consegue montar faixas |
| `download_jobs` | tabela | musicas, logs, retry import | definido na baseline | Status de importacao e retry falham |
| `challenges` | tabela | RPCs operacionais e overview diario | definido na baseline | Desafios pendentes/reconciliacao falham |
| `challenge_logs` | tabela | overview diario, RPCs operacionais | definido na baseline | Resumo de challenges e pausa por chamada falham |
| `admin_audit_logs` | tabela | overview, RPCs administrativas | definido na baseline | Auditoria administrativa nao registra/lista |
| `app_releases` | tabela | atualizacoes, Edge Function `get-current-app-release` | criada em `20260706202732_app_release_approval_flow.sql` | Atualizacoes/releases falham |
| `app_release_audit` | tabela | release flow | criada em `20260706202732_app_release_approval_flow.sql` | Auditoria de releases falha |

## RPCs e funcoes revisadas/criadas

Baseline:

- `private.require_admin(text[], uuid)`: valida `auth.uid()`, `admin_users.active = true`, role permitida e escopo conservador por unidade.
- `public.current_admin_user_id()`: retorna admin ativo atual.
- `public.is_admin()`: usado em RLS para leitura administrativa.
- `public.is_superadmin()`: usado por RPCs administrativas e musicais.
- `public.admin_can_manage_operator_unit(uuid)`: permite `superadmin` e `operations_manager`; o escopo especifico de `unit_manager` precisa ser confirmado no remoto.
- `public.admin_operator_email(uuid)`: retorna e-mail do Operador somente para admin autorizado.
- `public.admin_set_operator_shift(uuid, text, text, text)`: define turno do Operador.
- `public.admin_review_playlist(uuid, text, text)`: aprova/rejeita playlist com auditoria.
- `public._app_envelope(...)`, `public._app_shift_info(uuid)`, `public._app_version_check(...)`: auxiliares necessarios para compilar RPCs operacionais locais.

Migrations posteriores ja criam/recriam:

- `public.admin_retry_playlist_import(uuid)`
- `public.admin_music_library()`
- `public.admin_rename_music_playlist(uuid, text)`
- `public.admin_remove_playlist_track(uuid)`
- `public.admin_archive_secondary_playlist(uuid)`
- `public.current_admin_user_id()`
- `public.is_release_admin()`
- `private.require_release_admin()`
- `public.create_app_release(...)`
- `public.update_app_release(...)`
- `public.approve_app_release(uuid)`
- `public.release_app_release(uuid)`
- `public.block_app_release(uuid, text)`
- `public.rollback_app_release(uuid)`
- `public.operator_operational_event(jsonb)`
- `public.reconcile_operator_state(jsonb)`
- RPCs administrativas da etapa 2 em `20260707233645_admin_backend_hardening.sql`.

## RLS, grants e indices

RLS foi habilitado na baseline para as tabelas public sensiveis usadas diretamente pelo Admin:

- `units`, `admin_users`, `shifts`, `operators`
- `operator_sessions`, `operator_states`, `operator_status_history`, `operator_blocks`, `operational_events`
- `app_request_idempotency`, `system_settings`
- `challenges`, `challenge_logs`
- `playlists`, `tracks`, `playlist_tracks`, `download_jobs`
- `feedback`, `admin_audit_logs`

Policy criada:

- `ptm_admin_select`: `for select to authenticated using (public.is_admin())`.

Grants:

- `anon`: revogado nas tabelas sensiveis e nas RPCs administrativas.
- `authenticated`: `select` nas tabelas sensiveis, condicionado por RLS; `execute` apenas nas funcoes/RPCs que o Admin ou app autenticado precisam chamar.
- `private`: sem uso por `public`, `anon` ou `authenticated`.

Indices adicionados:

- Admin/auth: `admin_users_auth_active_idx`, `admin_users_role_active_idx`.
- Operadores/unidades: `operators_auth_active_idx`, `operators_unit_active_idx`, `operators_username_idx`, `shifts_unit_active_idx`.
- Sessoes/status: `operator_sessions_operator_status_idx`, `operator_sessions_status_started_idx`, `operator_states_status_idx`, `operator_status_history_operator_time_idx`, `operator_status_history_time_idx`.
- Eventos/bloqueios/challenges: `operational_events_operator_time_idx`, `operational_events_type_time_idx`, `operator_blocks_operator_active_idx`, `challenge_logs_operator_status_idx`.
- Musicas/playlists: `playlists_operator_status_idx`, `playlists_unit_approval_idx`, `playlists_reviewed_at_idx`, `playlist_tracks_playlist_position_idx`, `download_jobs_playlist_created_idx`, `download_jobs_status_created_idx`.
- Feedback/auditoria: `feedback_status_created_idx`, `feedback_operator_created_idx`, `admin_audit_logs_admin_time_idx`, `admin_audit_logs_entity_time_idx`.

## Auditoria das migrations

- `20260704173241_01_org_identity.sql`: agora e baseline real instalavel, com tabelas centrais, RLS, grants, indices e funcoes auxiliares.
- `20260704173259_02_sessions_state_events.sql` ate `20260706155148_playlist_tracks_unique_link.sql`: ainda sao placeholders de baseline remoto. A etapa 3 nao substituiu todos individualmente; a baseline principal concentra os objetos necessarios para as migrations reais posteriores.
- `20260706171640_playlist_import_status.sql`: depende de `playlists`, `download_jobs`, `admin_users`; agora esses objetos existem localmente antes dela.
- `20260706172800_youtube_cookies_missing_error.sql` e `20260706174306_youtube_format_unavailable_error.sql`: recriam mensagem de erro de playlist.
- `20260706175437_admin_music_library_management.sql`: depende de `admin_users`, `operators`, `units`, `playlists`, `playlist_tracks`, `tracks`, `download_jobs`, `admin_audit_logs`, `is_superadmin`, `admin_can_manage_operator_unit`; baseline cobre.
- `20260706202732_app_release_approval_flow.sql`: cria `app_releases`, `app_release_audit`, funcoes e policies de releases; depende de `admin_users` e `is_admin`; baseline cobre.
- `20260707010139_app_release_release_notes_default_cleanup.sql`: ajuste em `app_releases`.
- `20260707011011_local_call_operational_events.sql`: depende de estados, sessoes, operadores, bloqueios, challenges, idempotencia e helpers `_app_*`; baseline cobre.
- `20260707012612_app_release_contract_hardening.sql`: endurece contrato de releases.
- `20260707233645_admin_backend_hardening.sql`: cria RPCs administrativas seguras da etapa 2 e depende das tabelas administrativas centrais; baseline cobre.

## Pontos que precisam confirmar no Supabase remoto

1. Como o remoto modela escopo de `unit_manager`.
   - Nao ha evidencia local de coluna/tabela de vinculo admin-unidade.
   - A baseline local e conservadora: `unit_manager` nao recebe escopo automatico sem esse mapeamento.
2. Se existem tabelas app-only fora do Admin que devem entrar em baseline completa futura.
3. Se o remoto possui policies alem do padrao admin-select para escrita direta.
4. Se `admin_users.role` remoto usa exatamente os roles versionados no frontend.
5. Se as Edge Functions estao deployadas e com secrets corretos no ambiente remoto.

## SQLs de verificacao remota

Verificar tabelas esperadas:

```sql
select table_name
from information_schema.tables
where table_schema = 'public'
  and table_name = any (array[
    'admin_users','operators','units','shifts','operator_sessions','operator_states',
    'operator_status_history','operator_blocks','operational_events','app_request_idempotency',
    'system_settings','feedback','playlists','playlist_tracks','tracks','download_jobs',
    'challenges','challenge_logs','admin_audit_logs','app_releases','app_release_audit'
  ])
order by table_name;
```

Verificar colunas criticas:

```sql
with expected(table_name, column_name) as (
  values
    ('admin_users','auth_user_id'), ('admin_users','role'), ('admin_users','active'), ('admin_users','mfa_required'),
    ('operators','auth_user_id'), ('operators','display_name'), ('operators','username'), ('operators','unit_id'), ('operators','role'), ('operators','session_policy'), ('operators','active'),
    ('units','code'), ('units','name'), ('units','address'), ('units','city'), ('units','state'), ('units','timezone'), ('units','active'),
    ('feedback','type'), ('feedback','message'), ('feedback','status'), ('feedback','app_version'), ('feedback','operator_id'), ('feedback','unit_id'),
    ('playlists','created_by_operator_id'), ('playlists','unit_id'), ('playlists','approval_status'), ('playlists','import_status'), ('playlists','reviewed_by_admin_id'),
    ('download_jobs','playlist_id'), ('download_jobs','status'), ('download_jobs','error_message'), ('download_jobs','error_code'),
    ('app_releases','version'), ('app_releases','status'), ('app_releases','is_current'), ('app_releases','block_reason')
)
select e.table_name, e.column_name
from expected e
where not exists (
  select 1
  from information_schema.columns c
  where c.table_schema = 'public'
    and c.table_name = e.table_name
    and c.column_name = e.column_name
)
order by e.table_name, e.column_name;
```

Verificar RLS:

```sql
select c.relname as table_name, c.relrowsecurity as rls_enabled, c.relforcerowsecurity as rls_forced
from pg_class c
join pg_namespace n on n.oid = c.relnamespace
where n.nspname = 'public'
  and c.relname = any (array[
    'admin_users','operators','units','feedback','playlists','playlist_tracks','tracks',
    'download_jobs','admin_audit_logs','operator_sessions','operator_states',
    'operator_status_history','operational_events','challenges','challenge_logs',
    'app_releases','app_release_audit'
  ])
order by c.relname;
```

Verificar policies:

```sql
select schemaname, tablename, policyname, roles, cmd, qual, with_check
from pg_policies
where schemaname = 'public'
  and tablename = any (array[
    'admin_users','operators','units','feedback','playlists','playlist_tracks','tracks',
    'download_jobs','admin_audit_logs','operator_sessions','operator_states',
    'operator_status_history','operational_events','challenges','challenge_logs',
    'app_releases','app_release_audit'
  ])
order by tablename, policyname;
```

Verificar funcoes e `search_path`:

```sql
select
  n.nspname as schema_name,
  p.proname as function_name,
  pg_get_function_identity_arguments(p.oid) as args,
  p.prosecdef as security_definer,
  p.proconfig as config
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'private')
  and p.proname = any (array[
    'current_admin_user_id','is_admin','is_superadmin','admin_can_manage_operator_unit',
    'require_admin','admin_operator_email','admin_set_operator_shift','admin_review_playlist',
    'admin_create_operator','admin_update_operator','admin_update_admin_user',
    'admin_create_unit','admin_update_unit','admin_update_feedback_status'
  ])
order by n.nspname, p.proname, args;
```

Verificar grants de RPCs sensiveis:

```sql
select routine_schema, routine_name, grantee, privilege_type
from information_schema.routine_privileges
where routine_schema in ('public', 'private')
  and routine_name in (
    'admin_create_operator','admin_update_operator','admin_update_admin_user',
    'admin_create_unit','admin_update_unit','admin_update_feedback_status',
    'admin_operator_email','admin_set_operator_shift','admin_review_playlist'
  )
order by routine_schema, routine_name, grantee;
```

Verificar indices principais:

```sql
select schemaname, tablename, indexname, indexdef
from pg_indexes
where schemaname = 'public'
  and tablename = any (array[
    'admin_users','operators','units','feedback','playlists','playlist_tracks',
    'download_jobs','admin_audit_logs','operator_sessions','operator_states',
    'operator_status_history','operational_events','challenge_logs','app_releases'
  ])
order by tablename, indexname;
```

Verificar historico de migrations remoto:

```sql
select version, name, inserted_at
from supabase_migrations.schema_migrations
order by version;
```

## Aplicacao e validacao

Local:

```powershell
npm.cmd run typecheck
npm.cmd run build
npx.cmd supabase db reset
```

Remoto, antes de qualquer push/deploy:

```powershell
$env:SUPABASE_ACCESS_TOKEN="TOKEN_DE_CONTA_COM_PRIVILEGIO_NO_PROJETO"
$env:SUPABASE_DB_PASSWORD="SENHA_DO_BANCO"
npx.cmd supabase db push --dry-run
npx.cmd supabase db push
npx.cmd supabase functions deploy provision-operator
npx.cmd supabase functions deploy resolve-login-email
```

Observacao: o `supabase db reset` local exige Docker Desktop ou Docker Engine ativo.
