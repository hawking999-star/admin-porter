# Auditoria Supabase remoto x repo local - PTM Admin

Data: 2026-07-08
Modo: read-only
Projeto local: `C:\Users\hawking\Music\admin porter music`

## A) Resumo executivo

O Supabase remoto foi acessado em modo read-only e comparado contra `supabase/migrations`, `supabase/functions`, docs locais, queries do Admin e `railway-worker/main.py`.

Situacao geral: o remoto e a fonte real do contrato Admin/App/Supabase. O repo local nao e confiavel para reconstruir um ambiente limpo porque muitas migrations locais sao stubs de 116 bytes, varias definicoes SQL criticas existem apenas no remoto e alguns timestamps de migrations aplicadas no remoto divergem dos arquivos locais.

Risco principal: um `supabase db reset` ou um novo projeto criado somente a partir do repo local nao reproduz RPCs do App, tabelas auxiliares, colunas de musica/R2, grants, triggers, policies e Edge Functions que existem no ambiente remoto real.

O que impede correcao segura agora: falta um snapshot completo versionado do schema remoto. O comando de dump via Supabase CLI exigiu credencial/configuracao indisponivel (`SUPABASE_DB_PASSWORD`/privilegio de dump) e nao foi forcado.

Conclusao: antes de qualquer migration nova, criar um baseline/snapshot auditavel do contrato remoto e reconciliar stubs locais.

## B) Ambiente analisado

### Remoto identificado

- Project ref: `aifadvyxsefxfcgzgqol`
- Nome: `porter music`
- Regiao: `us-west-2`
- Status: `ACTIVE_HEALTHY`
- Postgres: `17.6.1`
- Host observado: `db.aifadvyxsefxfcgzgqol.supabase.co`
- Fonte local do link: `supabase/config.toml`, `supabase/.temp/project-ref`, `supabase/.temp/linked-project.json`

Nao foram impressos ou gravados secrets. Variaveis sensiveis do processo estavam ausentes: `SUPABASE_ACCESS_TOKEN`, `SUPABASE_DB_PASSWORD`, `SUPABASE_PROJECT_REF`, `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY`.

### Arquivos locais analisados

- `supabase/config.toml`
- `supabase/migrations/*.sql`
- `supabase/functions/*`
- `src/features/*/queries.ts`
- `railway-worker/main.py`
- `docs/*.md`
- `package.json`

### App do Operador

O App do Operador nao esta no workspace. A auditoria do App foi feita por contrato remoto, docs locais e nomes de RPCs citados.

### Snapshot/dump

Tentativa read-only:

```powershell
npx.cmd supabase db dump --linked --schema public,private --file docs\audit\supabase-remote-schema.snapshot.sql
```

Resultado: falhou com 403 de privilegio/login role e solicitacao de `SUPABASE_DB_PASSWORD`. Nenhum arquivo `docs/audit/supabase-remote-schema.snapshot.sql` foi gerado. Nao foi forçado, nao foi inventado dump.

## C) Divergencias por objeto

| Objeto | Tipo | Remoto | Local | Divergencia | Impacto | Prioridade | Correcao recomendada |
|---|---|---:|---:|---|---|---|---|
| `supabase_migrations` | historico | Sim | Parcial | Remoto tem timestamps recentes diferentes dos arquivos locais | Repo nao reflete exatamente o historico aplicado | P0 | Criar reconciliacao de baseline antes de novas migrations |
| Migrations de 116 bytes | migrations | Aplicadas | Stub | Varios nomes aplicados remotamente tem arquivo local sem SQL real | Banco limpo nao reproduz contrato | P0 | Substituir stubs por baseline/snapshot auditado ou migrations reais |
| `start_operator_session` | RPC | Sim | Stub/doc | Definicao existe so no remoto | App depende do remoto | P0 | Versionar SQL local |
| `end_operator_session` | RPC | Sim | Stub/doc | Definicao existe so no remoto | App depende do remoto | P0 | Versionar SQL local |
| `register_device` | RPC | Sim | Stub/doc | Definicao existe so no remoto | Login/dispositivo nao reproduz localmente | P0 | Versionar SQL local |
| `submit_playlist` | RPC | Sim | Stub/doc | Definicao existe so no remoto | App playlist quebra em banco limpo | P0 | Versionar SQL local e grants |
| `get_my_playlists` | RPC | Sim | Stub/doc | Definicao existe so no remoto | App nao lista playlists em banco limpo | P0 | Versionar SQL local e grants |
| `get_playlist_tracks` | RPC | Sim | Stub/doc | Definicao existe so no remoto | App nao carrega faixas | P0 | Versionar SQL local |
| `rename_principal_playlist` | RPC | Sim | Stub/doc | Definicao existe so no remoto | Fluxo de rename depende do remoto | P0 | Versionar SQL local |
| `operator_operational_event` | RPC | Sim | Sim | Existe local em migration recente; precisa validar timestamp remoto divergente | Eventos operacionais dependem de contrato exato | P1 | Alinhar timestamp/conteudo com remoto |
| `submit_challenge_response` | RPC | Nao | Nao | Ausente | Ciclo de desafio do App incompleto | P1 | Definir e criar contrato |
| `expire_challenge` | RPC | Nao | Nao | Ausente | Expiracao nao tem RPC dedicada | P1 | Definir se sera evento ou RPC |
| `get_current_challenge` | RPC | Nao | Nao | Ausente | App nao tem contrato claro para buscar desafio | P1 | Criar contrato App |
| `tracks` | tabela | Sim | Divergente | Remoto tem colunas R2 ausentes no baseline local | Worker depende dessas colunas | P0 | Corrigir baseline/migration local |
| `devices` | tabela | Sim | Nao | Remoto tem tabela sem criacao local real | Login/device nao reproduz | P0 | Versionar tabela, indexes, RLS e triggers |
| `categories` | tabela | Sim | Nao | Remoto tem tabela sem criacao local real | Musicas/playlists usam categoria | P1 | Versionar tabela |
| `call_sessions` | tabela | Sim | Nao | Remoto tem tabela sem criacao local real | Atendimento/chamadas incompleto localmente | P1 | Versionar tabela |
| `app_release_rules` | tabela | Sim | Nao | Remoto tem tabela sem criacao local real | Regras de update nao reproduzem | P1 | Versionar tabela e policies |
| `app_versions` | view | Sim | Nao | View legacy sobre `app_releases` | Compatibilidade de App/Edge pode depender dela | P1 | Versionar view com grants seguros |
| `create_operator` | Edge Function | Sim | Nao | Function remota ausente em `supabase/functions` | Deploy a partir do repo remove/nao reproduz funcao | P0 | Exportar/codificar fonte local |
| `register_device` | Edge Function | Sim | Nao | Function remota ausente em `supabase/functions` | Contrato duplicado RPC/Edge precisa decisao | P0 | Documentar fonte e caller real |
| `get-current-app-release` | Edge Function | Sim | Sim | Remoto existe, local existe | OK parcial; validar campos contra `app_releases` | P1 | Manter alinhado com tabela/view |

## D) RPCs do App

| RPC | Existe remoto | Existe repo | Assinatura remota | Retorno | Caller esperado | Auth | Security | Grant indevido anon? | Risco | Versionar local |
|---|---:|---:|---|---|---|---|---|---:|---|---:|
| `start_operator_session` | Sim | Stub/doc | `p_request jsonb` | `jsonb` | App | usa `auth.uid()` | definer, `search_path=''` | Nao | App nao inicia sessao em ambiente limpo | Sim |
| `end_operator_session` | Sim | Stub/doc | `p_request jsonb` | `jsonb` | App | usa `auth.uid()` | definer, `search_path=''` | Nao | Sessao nao encerra em ambiente limpo | Sim |
| `register_device` | Sim | Stub/doc | `p_request jsonb` | `jsonb` | App/Edge | usa `auth.uid()` | definer, `search_path=''` | Nao | Device/login nao reproduz localmente | Sim |
| `submit_playlist` | Sim | Stub/doc | `p_request jsonb` | `jsonb` | App | usa `auth.uid()` | definer, `search_path=''` | Sim | Endpoint publico de definer depende de check interno | Sim |
| `get_my_playlists` | Sim | Stub/doc | `p_request jsonb` | `jsonb` | App | usa `auth.uid()` | definer, `search_path=''` | Sim | Endpoint publico de definer depende de check interno | Sim |
| `get_playlist_tracks` | Sim | Stub/doc | `p_request jsonb` | `jsonb` | App | usa `auth.uid()` | definer, `search_path=''` | Nao | App nao lista faixas em banco limpo | Sim |
| `rename_principal_playlist` | Sim | Stub/doc | `p_request jsonb` | `jsonb` | App | usa `auth.uid()` | definer, `search_path=''` | Nao | Rename principal nao reproduz | Sim |
| `operator_operational_event` | Sim | Sim | `p_request jsonb` | `jsonb` | App | usa `auth.uid()` | definer, `search_path=''` | Nao | Contrato existe, mas historico/timestamp local diverge | Sim |
| `reconcile_operator_state` | Sim | Sim | `p_request jsonb` | `jsonb` | App/Admin | usa `auth.uid()` | definer, `search_path=''` | Nao | Contrato existe, validar compatibilidade local | Sim |
| `submit_feedback` | Sim | Nao completo | `p_request jsonb` | `jsonb` | App | usa `auth.uid()` | definer, `search_path=''` | Sim | Feedback depende do remoto; grant anon incoerente | Sim |
| `get_my_principal_playlist` | Nao | Nao | N/A | N/A | App | N/A | N/A | N/A | Nome citado no escopo nao existe | Confirmar necessidade |
| `record_operator_event` | Nao | Nao | N/A | N/A | App | N/A | N/A | N/A | Provavel nome legado; remoto usa `operator_operational_event` | Confirmar/depreciar |
| `submit_challenge_response` | Nao | Nao | N/A | N/A | App | N/A | N/A | N/A | Ciclo de desafio incompleto | Sim |
| `expire_challenge` | Nao | Nao | N/A | N/A | App/cron | N/A | N/A | N/A | Expiracao nao tem API explicita | Sim |
| `get_current_challenge` | Nao | Nao | N/A | N/A | App | N/A | N/A | N/A | App nao tem busca clara de desafio | Sim |
| `get_current_app_release` | Nao como RPC | Edge Function | Edge `get-current-app-release` | HTTP JSON | App | `verify_jwt=false` | Edge | Publico por design | Contrato depende da Edge Function | Sim como function |

## E) Tabelas criticas

| Tabela | Colunas divergentes / observacoes | RLS | Policies | Indices | Risco | Recomendacao |
|---|---|---|---|---|---|---|
| `operators` | Remoto tem `role`, `username`; local baseline e parcial | Sim | select admin; insert/update por `admin_can_manage_operator_unit`; delete superadmin | status/unit/session relacionados | Alto | Reconciliar schema e admin RPCs |
| `admin_users` | Remoto tem `unit_scope uuid[]`; `auth_user_id` not null | Sim | CRUD admin/superadmin | `active, role`, auth unique | Alto | Localizar autorizacao por unidade no baseline |
| `units` | Remoto tem address/city/state | Sim | policies duplicadas `admin_all` e `units_admin_all` | basicos | Medio | Remover duplicidade em etapa futura |
| `operator_sessions` | Remoto tem `device_id`, `contract_version`, `revision`, `unit_id not null` | Sim | `admin_all` | operator/status, device/status, heartbeat | Alto | Versionar contrato de sessao real |
| `operator_states` | Remoto suporta `active`, `idle`, `in_call`, `blocked`, `outside_shift`, `offline`; tem campos de chamada | Sim | `admin_all` | status/update, call_active | Alto | Documentar fonte de estado atual |
| `operator_status_history` | Guarda transicoes com `from_status`, `to_status`, `reason_code`, `state_revision` | Sim | select/insert admin | historico | Medio | Garantir escrita por RPC/evento |
| `operational_events` | Remoto tem `schema_version`, related entity, `received_at`, idempotency | Sim | select/insert admin | event_type/received_at, operator/received_at, idempotency unique | Alto | Usar como evento bruto oficial |
| `operator_blocks` | Remoto mudou para `scheduled/active/finished/revoked`; vincula session/challenge_log | Sim | `admin_all` | operator/status/blocked_until | Medio | Alinhar local que usa `ended` |
| `challenges` | Remoto tem `unit_id`, `status`, `block_seconds`, `created_by`, `revision`; local usa `active` | Sim | `admin_all` | unit/status | Alto | Redesenhar contrato local de desafios |
| `challenge_logs` | Remoto tem `answer_result`, `pending_at`, `displayed_at`, `closed_at`, `expires_at not null`; local e simples | Sim | `admin_all` | operator/status/expires_at | Alto | Criar RPCs/eventos de resposta/expiracao |
| `playlists` | Remoto tem `category_id`, `created_by_admin_id`, import/review fields, `reviewed_by_admin_id`; defaults divergem | Sim | admin all + select proprio do Operador | varios indices/trgm | Alto | Reconciliar playlist request/import |
| `tracks` | Remoto tem `category_id`, `storage_object_key`, `content_hash`, `mime_type`, `revision`; local baseline nao | Sim | `admin_all` | `storage_object_key` unique, status/category/title | P0 | Corrigir local para worker/R2 |
| `playlist_tracks` | Remoto tem `added_by_id`; local nao | Sim | `admin_all` | playlist/position, unique playlist/track | Medio | Versionar coluna e unique real |
| `download_jobs` | Remoto tem `error_code`, `error_message`, `error_details`, `last_error_at`; local baseline nao | Sim | SELECT para `{public}` com `is_admin()` | playlist/status | Medio | Trocar policy para `authenticated` em hardening futuro |
| `feedback` | Remoto tem `resolved_at`, `resolved_by`, `revision`; nao tem prioridade/responsavel/resposta/historico | Sim | admin all + select proprio do Operador | status/type/unit/trgm | Medio | P2 para prioridade/resposta/historico |
| `app_releases` | Remoto tem campos legacy `artifact_uri/hash/signature`, manifest/installers, unique current por channel | Sim | select admin; write release admin | current unique, channel/status | Alto | Definir contrato unico Edge/Admin |
| `app_release_rules` | Existe remoto, nao local | Sim | admin all | nao confirmado completo | Medio | Versionar regras de update |
| `admin_audit_logs` | Existe remoto/local, mas audit triggers remotos cobrem units/operators/admin_users | Sim | select/insert admin | basico | Medio | Versionar triggers/funcoes de audit |

## F) Contrato oficial recomendado

- Operador: `operators` como cadastro; `operator_sessions` como sessoes; `operator_states` como estado atual.
- Admin: `admin_users` com `role` e `unit_scope`; mutacoes sensiveis por RPC admin.
- Condominio: `units`; escopo por `admin_users.unit_scope`.
- Estado atual: `operator_states`.
- Historico operacional: `operator_status_history`.
- Eventos do App: `operational_events` via `operator_operational_event`.
- Desafios: `challenges` para definicao; `challenge_logs` para entrega/resposta/expiracao; faltam RPCs App.
- Feedback: `feedback` para mensagem/status; faltam prioridade, responsavel operacional, resposta e historico se forem requisitos de atendimento.
- Playlists: `playlists`, `playlist_tracks`, `download_jobs`; App por RPCs e Admin por RPCs existentes.
- Tracks: `tracks` com R2 em `storage_object_key`, `content_hash`, `mime_type`; `playlist_tracks` relaciona faixas.
- Releases: `app_releases` como fonte principal; `app_versions` apenas compatibilidade; Edge Function `get-current-app-release` como API publica.
- Auditoria: `admin_audit_logs` + triggers `audit_admin_change()` para entidades sensiveis.

## G) Ordem de correcao recomendada

1. Gerar snapshot/baseline local do schema remoto com credencial adequada, sem secrets versionados.
2. Reconciliar historico de migrations: stubs, timestamps divergentes e objetos remotos sem fonte local.
3. Versionar RPCs do App: sessoes, device, playlists, feedback e eventos.
4. Corrigir contrato `tracks`/R2 no baseline local.
5. Fechar status operacional: estado atual, historico, eventos brutos e duracao.
6. Fechar desafios/ocioso: RPCs `get_current_challenge`, `submit_challenge_response`, expiracao e eventos oficiais.
7. Fechar feedback: decidir prioridade, responsavel, resposta e historico.
8. Fechar releases: consolidar `app_releases`, `app_versions`, Edge Function e regras.
9. Fechar auditoria visual/admin: paginas em breve e visibilidade operacional.
10. Rodar validacao local em banco limpo antes de qualquer push remoto.

## H) Tracks e R2

Contrato remoto de `tracks`:

- Existe: `storage_object_key`, `content_hash`, `mime_type`, `revision`, `category_id`, `title`, `artist`, `status`, `created_at`, `updated_at`.
- Nao existe: `duration_seconds`; o remoto usa `duration_ms`.
- Nao existe coluna top-level `source_url` em `tracks`; origem de playlist fica em `playlists.source_url`.
- `storage_object_key` e `mime_type` sao `not null`; `storage_object_key` e unique.

Worker:

- `railway-worker/main.py` consulta/upserta por `storage_object_key`.
- Grava `content_hash` e `mime_type`.
- Esta alinhado ao remoto.
- Nao esta alinhado ao baseline local.

Admin:

- `src/features/musicas/queries.ts` usa RPCs de biblioteca/admin, nao escreve diretamente em `tracks`.
- Esta mais alinhado ao remoto do que ao baseline.

Duplicidade:

- Nao apareceu tabela `musicas` ou `music` no remoto.
- O modelo oficial parece ser `tracks` + `playlist_tracks`.

## I) Status operacional

Status oficiais desejados:

- `ativo`: remoto suporta via `operator_states.status = 'active'`.
- `atendimento`: remoto suporta via `operator_states.status = 'in_call'` e tambem `call_active/call_started_at`.
- `ocioso`: remoto suporta via `operator_states.status = 'idle'`.

Eventos minimos:

- `session.started` / `session.ended`: suportaveis por `operator_sessions` e `operator_operational_event`, mas nao havia linhas em `operational_events` no momento da auditoria.
- `call_started` / `call_finished`: suportaveis por `operator_states` e `call_sessions`; RPC `operator_operational_event` existe.
- `challenge.displayed`, `challenge.answered`, `challenge.expired`: `challenge_logs` tem colunas/status, mas faltam RPCs App especificas.
- `idle.started`, `idle.ended`: podem ser representados em `operator_status_history`/`operational_events`, mas faltam evidencias de eventos gravados.

Respostas objetivas:

- Estado atual: `operator_states`.
- Historico: `operator_status_history`.
- Duracao: derivada de timestamps em `operator_status_history`, `operator_sessions`, `call_sessions`, `challenge_logs`.
- Evento bruto: `operational_events`.
- Atendimento: suportado estruturalmente.
- Ocioso: suportado estruturalmente.
- Desafio expirado: suportado em `challenge_logs.status = 'expired'`, mas sem RPC dedicada.
- Admin calcula tempo ocioso: possivel por historico se houver eventos/transicoes gravadas.
- App tem RPC para enviar eventos: sim, `operator_operational_event`; nao tem RPCs dedicadas para desafios.

## J) Challenges

Remoto:

- `challenges`: definicao por unidade, status, tempo limite, bloqueio, revisao.
- `challenge_logs`: operador, sessao, status, resposta, timestamps de pending/displayed/answered/expires/closed.
- Nao apareceu `challenge_responses`.
- Nao apareceram RPCs `get_current_challenge`, `submit_challenge_response`, `expire_challenge`.

Ciclo Admin -> App -> resposta/expiracao -> Admin:

- Parcial.
- Admin tem tabelas para criar/visualizar.
- App nao tem contrato RPC completo para buscar desafio atual, responder e expirar.
- O que criar primeiro: RPCs do App e regra de expiracao/reconciliacao.
- O que documentar primeiro: schema remoto real de `challenges` e `challenge_logs`.

## K) Feedback

Remoto:

- `feedback`: `operator_id`, `unit_id`, `type`, `message`, `status`, `app_version`, `resolved_at`, `resolved_by`, `revision`, timestamps.
- Status: `new`, `read`, `resolved`.
- RPC `submit_feedback(p_request jsonb)` existe, usa `auth.uid()`, mas tem grant para `anon/public`.
- RPC admin `admin_update_feedback_status` existe.

Analise:

- App consegue enviar feedback no remoto.
- Admin consegue tratar status basico.
- Falta prioridade, responsavel operacional dedicado, resposta ao Operador e historico de mudancas.
- Prioridade: P2 se feedback for triagem simples; P1 se virar fluxo de suporte com SLA/resposta.

## L) Releases

Remoto:

- `app_releases` contem `version`, `platform`, `channel`, `status`, `release_notes`, `is_current`, `mandatory`, `minimum_version`, `manifest_key`, `installer_key`, `blockmap_key`, `sha512`, `size_bytes`, aprovacao/bloqueio.
- Existe unique index de current por `channel`.
- Existem constraints de semver estrita `X.Y.Z`.
- Existe view `app_versions` mapeando `manifest_key` para `artifact_uri` e `sha512` para `artifact_hash`.
- Existe `app_release_rules`, ausente no repo local.

Edge Function:

- `get-current-app-release` existe local/remoto e e publica (`verify_jwt=false`), esperado para App.

Analise:

- Admin e Edge Function precisam ser travados no mesmo contrato: `app_releases` como fonte e `app_versions` como compatibilidade.
- Existe release current unica por canal.
- Existe canal/status coerente.
- Existe checksum (`sha512`) e campos legacy (`artifact_hash` via view).
- Existe versao obrigatoria/opcional (`mandatory`, `minimum_version`).
- App consegue consumir se a Edge Function permanecer alinhada; sem versionar `app_release_rules`, ambiente limpo fica incompleto.

## M) RLS, policies, grants, realtime, storage

RLS:

- Todas as tabelas publicas remotas verificadas estao com RLS habilitada.
- View `app_versions` nao tem RLS propria; views podem bypassar RLS por padrao dependendo de configuracao. Deve ter grants revisados ou `security_invoker` se aplicavel.

Policies:

- Admin geral usa `is_admin()` em muitas tabelas.
- `operators` usa `admin_can_manage_operator_unit(unit_id)` para insert/update.
- `feedback` e `playlists` tem SELECT proprio do Operador.
- `download_jobs` tem SELECT para role `{public}` com `is_admin()`; recomenda-se alterar futuramente para `{authenticated}`.
- `units` tem policies duplicadas `admin_all` e `units_admin_all`.

Grants:

- RPCs com grant indevido/incoerente para anon/public: `get_my_playlists`, `submit_playlist`, `submit_feedback`.
- RPCs restritas corretamente a authenticated: `start_operator_session`, `end_operator_session`, `register_device`, `get_playlist_tracks`, `rename_principal_playlist`, `operator_operational_event`, `reconcile_operator_state`.
- Funcoes helper `admin_can_manage_operator_unit` e `is_superadmin` tambem aparecem executaveis por anon/public; como retornam boolean e usam `auth.uid()`, o risco e menor, mas deve ser endurecido por consistencia.

Realtime:

- Publicacao `supabase_realtime`: apenas `public.playlists`.
- Nao ha publicacao para `operator_states`, `operational_events` ou `challenge_logs`.

Storage:

- `storage.buckets` retornou vazio.
- Musicas parecem depender de R2/worker externo, nao Supabase Storage.

## N) Checklist manual seguro

Se precisar confirmar manualmente no Supabase SQL Editor, usar apenas SELECTs:

```sql
select routine_schema, routine_name
from information_schema.routines
where routine_schema in ('public', 'private')
order by routine_schema, routine_name;
```

```sql
select table_name, column_name, data_type, is_nullable, column_default
from information_schema.columns
where table_schema = 'public'
order by table_name, ordinal_position;
```

```sql
select tablename, policyname, cmd, roles, qual, with_check
from pg_policies
where schemaname = 'public'
order by tablename, policyname;
```

```sql
select schemaname, tablename
from pg_publication_tables
where pubname = 'supabase_realtime'
order by schemaname, tablename;
```

```sql
select id, name, public
from storage.buckets
order by id;
```

```sql
select n.nspname, p.proname, pg_get_function_identity_arguments(p.oid) as args,
       has_function_privilege('anon', p.oid, 'EXECUTE') as anon_execute,
       has_function_privilege('authenticated', p.oid, 'EXECUTE') as authenticated_execute,
       p.prosecdef as security_definer
from pg_proc p
join pg_namespace n on n.oid = p.pronamespace
where n.nspname in ('public', 'private')
order by n.nspname, p.proname;
```

## O) Validacoes locais

- `npm.cmd run typecheck`: passou (`tsc --noEmit`).
- `npm.cmd run build`: passou (`tsc -b && vite build`).
- Aviso nao bloqueante do build: chunk JS final acima de 500 kB (`dist/assets/index-BjVPKyCm.js`, 874.35 kB antes de gzip).
- O build gerou/atualizou artefatos locais como `dist/` e `tsconfig.tsbuildinfo`; nao foram feitas correcoes de codigo nesta etapa.
