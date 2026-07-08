# Auditoria read-only - App do Operador vs Admin/Supabase

Data: 2026-07-08
Publico: dev do App do Operador
Projeto Supabase: `aifadvyxsefxfcgzgqol` (`porter music`)
Base usada: contrato remoto Supabase, PTM Admin local, docs tecnicos e worker Railway.

> Importante: o codigo do App do Operador nao esta neste workspace. Este relatorio nao afirma que o App atual chama ou nao chama uma funcao especifica; ele define o contrato real esperado e o que o dev do App precisa confirmar no codigo dele. Nada foi alterado no banco, no Admin ou no App.

## A) Resumo executivo

O App do Operador so estara alinhado com PTM Admin/Supabase se consumir o backend por RPCs/Edge Functions, nao por leitura direta de tabelas sensiveis.

Contrato remoto confirmado:

- Login por usuario ou email: `resolve-login-email` + `supabase.auth.signInWithPassword`.
- Sessao/dispositivo: `register_device`, `start_operator_session`, `reconcile_operator_state`, `end_operator_session`.
- Estado operacional/chamada: `operator_operational_event` aceita hoje apenas `call_started` e `call_finished`.
- Playlists/musicas: `get_my_playlists`, `rename_principal_playlist`, `submit_playlist`, `get_playlist_tracks`.
- Feedback: `submit_feedback`.
- Releases: Edge Function `get-current-app-release`, protegida por `X-Porter-Update-Secret`.

Principais desalinhamentos/riscos para producao:

- O App nao pode depender de RPCs que nao existem: `get_current_challenge`, `submit_challenge_response`, `expire_challenge`, `get_my_principal_playlist`, `record_operator_event`.
- Desafios ainda nao tem API App dedicada para buscar, responder e expirar. O backend retorna `pending_challenge` em payloads operacionais, mas falta contrato completo de resposta/expiracao.
- Eventos exigidos no produto (`session.started`, `session.ended`, `idle.started`, `idle.ended`, `challenge.*`, `feedback.submitted`, `playlist.submitted`) nao existem todos como eventos aceitos por `operator_operational_event`.
- `operator_operational_event` grava no remoto `call.started` e `call.ended`, enquanto o payload aceito do App e `call_started`/`call_finished`. O dev deve respeitar esses nomes de entrada.
- `get_my_playlists`, `submit_playlist` e `submit_feedback` existem no remoto, mas ainda tem grant `anon/public`; as funcoes validam `auth.uid()`, mas o ideal futuro e restringir a `authenticated`.
- Musica/R2 depende de `public_url` em `tracks.metadata`. Se R2 for privado, o App nao toca apenas com `storage_object_key`; falta endpoint de signed URL.
- O repo local nao reproduz completamente o remoto. Para o dev do App, o contrato remoto e a fonte real ate a reconciliacao de migrations.

## B) Inventario de chamadas Supabase esperadas no App

| Arquivo provavel no App | Tabela/RPC/Edge | Operacao | Payload esperado | Retorno esperado | Status |
|---|---|---|---|---|---|
| `supabase-client.js` / auth service | Edge `resolve-login-email` | Resolver username/email antes do Auth | `{ "identifier": "kaua.gomes" }` | `{ "email": "..." }` ou `404 { "error": "not_found" }` | Contrato confirmado; confirmar uso no App |
| `supabase-client.js` / auth service | `supabase.auth.signInWithPassword` | Login nativo | `{ email, password }` | Sessao/JWT Supabase | Contrato confirmado; confirmar uso no App |
| session service | RPC `register_device` | Registrar instalacao/dispositivo | `{ request_id, device_id, label, platform, app_version, channel, contract_version }` | envelope com `data.device = { id, status }` | Existe remoto; confirmar uso |
| session service | RPC `start_operator_session` | Iniciar sessao | `{ request_id, device_id, app_version, channel, contract_version }` | envelope com `data.session`, `data.unit`, estado operacional | Existe remoto; confirmar payload real |
| session service | RPC `reconcile_operator_state` | Heartbeat/reconciliacao | `{ request_id, session_id, app_version }` | envelope com `operator_state`, `unit`, `pending_challenge`, `next_screen` | Existe remoto; deve ser ciclo periodico |
| session service | RPC `end_operator_session` | Encerrar sessao | `{ request_id, session_id, reason }` | envelope idempotente de encerramento | Existe remoto; confirmar uso ao sair/fechar App |
| call detector/local helper | RPC `operator_operational_event` | Inicio/fim de atendimento | `{ event: "call_started"|"call_finished", event_id, source, occurred_at, metadata, session_id?, device_id? }` | envelope com `result`, `call_active`, `status_operacional`, `next_screen` | Existe remoto; aceita so esses 2 eventos |
| playlists service | RPC `get_my_playlists` | Listar playlists do Operador | `{ request_id }` | `data.playlists`, `meta.secondary_count`, `meta.secondary_limit` | Existe remoto; grant anon precisa hardening futuro |
| playlists service | RPC `rename_principal_playlist` | Renomear principal | `{ request_id, name, playlist_id?, expected_revision? }` | playlist atualizada + `revision` | Existe remoto |
| playlists service | RPC `submit_playlist` | Enviar link principal/secundaria | `{ request_id, type, url, name? }` | `PLAYLIST_REQUEST_CREATED` ou erro estruturado | Existe remoto; grant anon precisa hardening futuro |
| music service | RPC `get_playlist_tracks` | Buscar faixas | `{ request_id, playlist_id, limit, offset }` | `data.tracks[]` com `public_url`, `storage_object_key`, `status` | Existe remoto |
| feedback service | RPC `submit_feedback` | Enviar feedback | `{ request_id, type, message, app_version? }` | `data.feedback` | Existe remoto; grant anon precisa hardening futuro |
| update service / worker | Edge `get-current-app-release` | Consultar release liberada | `GET ?channel=stable` + `X-Porter-Update-Secret` | release com manifest/installer/blockmap/sha512 | Existe local/remoto; nao usar sem secret |
| challenge service | RPC `get_current_challenge` | Buscar desafio atual | N/A | N/A | Nao existe; nao usar |
| challenge service | RPC `submit_challenge_response` | Responder desafio | N/A | N/A | Nao existe; precisa contrato |
| challenge service | RPC `expire_challenge` | Expirar desafio | N/A | N/A | Nao existe; precisa contrato |

## C) Fluxos analisados

### 1. Login

Arquivos/contrato base:

- `docs/fluxo-login-app.md`
- `supabase/functions/resolve-login-email/index.ts`
- `supabase/functions/provision-operator/index.ts`

Fluxo esperado:

1. App envia `POST /functions/v1/resolve-login-email` com `{ "identifier": "usuario-ou-email" }`.
2. Se identifier ja e email, a function devolve o proprio email.
3. Se identifier e username, resolve `operators.username` ativo para `auth_user_id`, busca email no Auth e devolve.
4. App chama `supabase.auth.signInWithPassword({ email, password })`.
5. Com JWT, App chama `register_device` e `start_operator_session`.

Username com ponto:

- Aceito pela regex local: `^[a-z0-9._-]{3,60}$`.
- Exemplo `kaua.gomes` e valido.

Riscos:

- Se `operators.auth_user_id` estiver ausente, `resolve-login-email` retorna `not_found`.
- Se o operador foi criado sem Auth user pelo Admin antigo/manual, login quebra.
- A mensagem do App deve ser generica: usuario ou senha invalidos.

Correcao recomendada:

- Dev do App deve confirmar que sempre chama `resolve-login-email` antes de `signInWithPassword`.
- Admin/backend devem garantir provisionamento por `provision-operator`, nunca cadastro parcial.

### 2. Sessao do Operador

RPCs remotas confirmadas:

- `register_device(p_request jsonb)` -> `jsonb`
- `start_operator_session(p_request jsonb)` -> `jsonb`
- `reconcile_operator_state(p_request jsonb)` -> `jsonb`
- `end_operator_session(p_request jsonb)` -> `jsonb`

Todas usam `auth.uid()`, `SECURITY DEFINER`, `search_path=''`, grant para `authenticated`, sem grant anon.

O que o App precisa fazer:

- Persistir `device_id` por instalacao.
- Chamar `register_device` antes/inicio do ciclo.
- Chamar `start_operator_session` ao entrar.
- Rodar `reconcile_operator_state` como heartbeat operacional.
- Chamar `end_operator_session` ao sair, logout, encerramento intencional ou troca de usuario.

Admin consegue saber online/ativo se:

- `operator_sessions.status='active'` estiver atualizado.
- `operator_states.status` for mantido por start/reconcile/eventos.
- App nao ficar aberto sem reconcile.

Onde quebra:

- Device com status nao permitido gera `DEVICE_NOT_ALLOWED`.
- Unidade inativa gera `UNIT_NOT_ACTIVE`.
- Sessao concorrente pode gerar `SESSION_ALREADY_ACTIVE` conforme policy.

### 3. Status ativo/atendimento/ocioso

Tabela de estado atual: `operator_states`.
Historico: `operator_status_history`.
Evento bruto: `operational_events`.

Mapeamento remoto:

- `operator_states.status='active'` -> `status_operacional='ativo'`.
- `operator_states.status='in_call'` -> `status_operacional='em_atendimento'`.
- `operator_states.status='idle'` -> `status_operacional='ocioso'`.

Evento App aceito hoje:

```json
{
  "event": "call_started",
  "event_id": "uuid",
  "source": "microsip",
  "occurred_at": "ISO-8601",
  "metadata": { "phase": "incoming" },
  "session_id": "opcional",
  "device_id": "opcional"
}
```

Eventos aceitos por `operator_operational_event`:

- `call_started`
- `call_finished`

Eventos gravados internamente:

- `call.started`
- `call.ended`

Onde quebra:

- `idle.started` e `idle.ended` nao sao aceitos por `operator_operational_event`.
- Se o App usa `idle_started`, `idle_finished` ou `record_operator_event`, isso nao existe no remoto.
- Duracao de atendimento/ocioso depende de transicoes consistentes em `operator_status_history`.

Correcao recomendada:

- P0/P1: App deve usar `operator_operational_event` para chamadas locais.
- P1: definir contrato oficial para idle via `operator_operational_event` ou nova RPC, antes de o App enviar `idle.started`/`idle.ended`.

### 4. Desafios

Tabelas remotas:

- `challenges`
- `challenge_logs`

Campos remotos relevantes:

- `challenges.unit_id`, `status`, `duration_seconds`, `block_seconds`, `answer_definition`.
- `challenge_logs.operator_id`, `session_id`, `status`, `answer_result`, `pending_at`, `displayed_at`, `answered_at`, `expires_at`, `closed_at`.

O que existe:

- `reconcile_operator_state` / payload operacional pode retornar `pending_challenge`.
- `operator_operational_event(call_started)` pausa desafio pendente/displayed.
- `operator_operational_event(call_finished)` reabre desafio pausado e recalcula `expires_at`.

O que falta:

- `get_current_challenge` nao existe.
- `submit_challenge_response` nao existe.
- `expire_challenge` nao existe.
- `challenge_responses` nao existe.
- `challenge.displayed`, `challenge.answered`, `challenge.expired` nao sao eventos aceitos por `operator_operational_event`.

Respostas:

- Desafio pode aparecer ao App via `pending_challenge` no reconcile/event response.
- Resposta do desafio nao tem RPC dedicada confirmada.
- Desafio nao respondido pode ser representado em `challenge_logs.status='expired'`, mas falta API App para expirar.
- Ocioso por nao resposta ainda precisa contrato; nao assuma no App.
- Admin consegue saber quem nao respondeu se `challenge_logs` for atualizado; hoje falta a parte App.

Correcao recomendada:

- Criar contrato unico de desafio antes de implementar tela no App: buscar, marcar displayed, responder, expirar, iniciar/encerrar ocioso.

### 5. Playlists e musicas

Fonte de verdade:

- `playlists`
- `playlist_tracks`
- `tracks`
- `download_jobs`

RPCs:

- `get_my_playlists`
- `rename_principal_playlist`
- `submit_playlist`
- `get_playlist_tracks`

Contrato de faixas:

- `get_playlist_tracks` retorna `tracks[]` com `position`, `id`, `title`, `artist`, `duration_ms`, `storage_object_key`, `public_url`, `status`, `updated_at`.
- Campo tocavel atual: `public_url`.
- Se `public_url` vier `null`, `storage_object_key` sozinho nao basta para tocar audio.

Playlist principal:

- Nao existe `get_my_principal_playlist`.
- App deve usar `get_my_playlists` e localizar `type='principal'`.

Muitos Operadores:

- Leitura por RPC e paginacao em `get_playlist_tracks(limit/offset)`.
- Risco maior e progresso de importacao: App nao tem RPC de status de `download_jobs`; para mostrar progresso precisa nova RPC ou polling por contrato especifico.

### 6. Envio de playlist/link pelo Operador

Fluxo esperado:

1. App chama `submit_playlist` com `type='principal'` ou `type='secondary'` e `url`.
2. Salva/atualiza em `playlists`.
3. Admin aprova/rejeita via `admin_review_playlist`.
4. Ao aprovar, worker Railway cria/atualiza `download_jobs` e importa para `tracks` + `playlist_tracks`.
5. App recarrega `get_my_playlists` e `get_playlist_tracks`.

Pontos importantes:

- Secundaria hoje significa outra playlist externa enviada por URL.
- Nao existe ainda modelo de secundaria curada a partir da principal.
- `submit_playlist` so permite uma solicitacao pending por tipo.
- Limite de secundaria: 2, erro `SECONDARY_LIMIT_REACHED`.

Evento esperado pelo produto:

- `playlist.submitted` ainda nao e aceito por `operator_operational_event`.
- Hoje o proprio `submit_playlist` e a fonte transacional da solicitacao.

### 7. Feedback

RPC:

- `submit_feedback(p_request jsonb)`

Payload esperado:

```json
{
  "request_id": "uuid",
  "type": "suggestion|problem|praise",
  "message": "texto",
  "app_version": "1.0.0"
}
```

Backend:

- Deriva Operador por `auth.uid()`.
- Grava `feedback.operator_id`, `unit_id`, `type`, `message`, `status='new'`, `app_version`.

Suficiente para Admin tratar?

- Sim para triagem basica.
- Falta prioridade, responsavel, resposta ao Operador e historico se o feedback virar suporte/SLA.

Evento esperado pelo produto:

- `feedback.submitted` nao e aceito por `operator_operational_event`.
- Hoje `submit_feedback` e a fonte do envio.

### 8. Updates/releases

Edge Function:

- `get-current-app-release`
- Metodo: `GET`
- Query: `?channel=stable`
- Header obrigatorio: `X-Porter-Update-Secret`

Resposta esperada:

- `id`
- `version`
- `channel`
- `status`
- `is_current`
- `mandatory`
- `minimum_version`
- `title`
- `release_notes`
- `manifest_key`
- `installer_key`
- `blockmap_key`
- `sha512`
- `size_bytes`
- `released_at`

Erros:

- Sem secret ou secret incorreto: `401 { "error": "unauthorized" }`.
- Metodo errado: `405 { "error": "method_not_allowed" }`.
- Sem release valida: `404 { "error": "release_not_found" }`.

Riscos:

- App nao deve chamar sem o segredo interno.
- App/worker precisa respeitar `mandatory` e `minimum_version`.
- App deve validar hash/checksum (`sha512`) antes de instalar.
- Admin libera por `app_releases`; ultimo arquivo no R2 nao e necessariamente release liberada.

## D) Eventos que o App ja deveria enviar/acionar pelo contrato atual

Confirmados como aceitos por RPC operacional:

- `call_started`
- `call_finished`

Acionados por RPCs especificas, nao por `operator_operational_event`:

- envio de playlist/link: `submit_playlist`
- envio de feedback: `submit_feedback`
- inicio/fim de sessao: `start_operator_session` / `end_operator_session`

Precisa confirmar no codigo do App:

- se o App realmente envia `call_started` e `call_finished`;
- se gera `event_id` UUID unico e reusa o mesmo em retry;
- se chama `end_operator_session` em logout/fechamento.

## E) Eventos esperados que o App ainda nao tem contrato aceito

Eventos do produto sem entrada operacional dedicada hoje:

- `session.started` - usar `start_operator_session`, nao evento cru.
- `session.ended` - usar `end_operator_session`, nao evento cru.
- `idle.started` - nao aceito por `operator_operational_event`.
- `idle.ended` - nao aceito por `operator_operational_event`.
- `challenge.displayed` - nao aceito.
- `challenge.answered` - nao aceito.
- `challenge.expired` - nao aceito.
- `feedback.submitted` - usar `submit_feedback`, ou criar evento/audit depois.
- `playlist.submitted` - usar `submit_playlist`, ou criar evento/audit depois.

## F) RPCs/tabelas usadas pelo App que nao existem no contrato local completo

Existem no remoto, mas o repo local/migrations ainda nao reproduzem de forma confiavel:

- `start_operator_session`
- `end_operator_session`
- `register_device`
- `submit_playlist`
- `get_my_playlists`
- `get_playlist_tracks`
- `rename_principal_playlist`
- `submit_feedback`
- tabelas/objetos: `devices`, `categories`, `call_sessions`, `app_release_rules`, `app_versions`

Nao existem no remoto nem local e nao devem ser usados pelo App:

- `get_current_challenge`
- `submit_challenge_response`
- `expire_challenge`
- `get_my_principal_playlist`
- `record_operator_event`
- `challenge_responses`

## G) RPCs/tabelas esperadas pelo Admin/Supabase que o App nao deve acessar direto

O App deve evitar leitura/escrita direta nas tabelas abaixo e usar RPC/Edge:

- `operators`
- `operator_sessions`
- `operator_states`
- `operator_status_history`
- `operational_events`
- `challenge_logs`
- `tracks`
- `playlist_tracks`
- `download_jobs`
- `feedback`
- `app_releases`

O App pode receber dados derivados dessas tabelas via:

- `start_operator_session`
- `reconcile_operator_state`
- `operator_operational_event`
- `get_my_playlists`
- `get_playlist_tracks`
- `submit_feedback`
- `get-current-app-release`

## H) Correcoes recomendadas por prioridade

### P0 - quebra login, sessao, seguranca ou producao

- Confirmar que o App chama `resolve-login-email` antes de `signInWithPassword`, para username como `kaua.gomes`.
- Confirmar que o App usa `operators.auth_user_id` indiretamente via Auth/JWT, nunca tentando autenticar por tabela.
- Persistir `device_id` estavel e chamar `register_device`.
- Chamar `start_operator_session`, `reconcile_operator_state` e `end_operator_session` nos momentos corretos.
- Nao usar `get_current_challenge`, `submit_challenge_response`, `expire_challenge`, `record_operator_event` porque nao existem.
- Para updates, nao chamar `get-current-app-release` sem `X-Porter-Update-Secret`.

### P1 - quebra contrato Admin/App

- Implementar no App `operator_operational_event` com `call_started`/`call_finished`.
- Definir contrato backend para `idle.started`/`idle.ended`.
- Definir contrato de desafios: displayed, answered, expired e retorno de ocioso.
- Usar `get_my_playlists` para localizar Principal; nao chamar `get_my_principal_playlist`.
- Usar `get_playlist_tracks` para catalogo; nao ler `tracks` direto.
- Tratar `SECONDARY_LIMIT_REACHED`, `PLAYLIST_REQUEST_ALREADY_PENDING`, `REVISION_CONFLICT`.

### P2 - atrapalha operacao

- Criar/consumir status de importacao de playlist para o Operador se o App precisar mostrar progresso.
- Adicionar fluxo visual para `public_url=null` em musica, pois signed URL nao existe.
- Feedback: definir prioridade/responsavel/resposta se for suporte operacional.
- Mapear mensagens de erro como `UNIT_NOT_ACTIVE`, `DEVICE_NOT_ALLOWED`, `APP_VERSION_NOT_ALLOWED`.

### P3 - melhoria tecnica

- Padronizar nomes de eventos externos vs internos: entrada `call_started`, registro `call.started`.
- Usar `request_id` em todas as RPCs.
- Logar localmente `server_now`, `contract_version`, `api_version` e `request_id`.
- Implementar backoff em retry de RPC sem reutilizar `event_id` indevidamente fora de idempotencia.

## I) Plano de correcao do App

1. Login/`resolve-login-email`
   - Garantir username/email + senha.
   - Aceitar username com ponto.
   - Mensagem generica em `not_found`/credencial invalida.

2. Sessao e presenca
   - Persistir `device_id`.
   - `register_device` -> `start_operator_session` -> loop `reconcile_operator_state`.
   - `end_operator_session` em logout/fechamento.

3. Status atendimento/ocioso
   - Implementar `operator_operational_event` para `call_started`/`call_finished`.
   - Nao enviar idle ainda sem contrato aprovado.
   - Mostrar `status_operacional` vindo do backend.

4. Desafios e respostas
   - Consumir `pending_challenge` do reconcile/event response como leitura inicial.
   - Aguardar/criar contrato para displayed/answered/expired.
   - Nao inventar tabela/RPC no App.

5. Feedback
   - Usar `submit_feedback`.
   - Enviar `type`, `message`, `app_version`.
   - Tratar sucesso como status inicial `new`.

6. Playlists/musicas
   - `get_my_playlists` para Principal/secundarias.
   - `rename_principal_playlist` antes de reenviar link se nome mudou.
   - `submit_playlist` para link.
   - `get_playlist_tracks` para faixas.
   - Tocar por `public_url`; se nulo, exibir estado indisponivel ate existir signed URL.

7. Updates/releases
   - Consultar `get-current-app-release` com secret interno.
   - Respeitar `mandatory`, `minimum_version`, `sha512`, `manifest_key`, `installer_key`, `blockmap_key`.
   - Nao assumir que ultimo arquivo R2 e release liberada.

## Arquivos usados nesta auditoria

- `docs/fluxo-login-app.md`
- `docs/handoff-dev-app.md`
- `docs/relatorio-chamadas-locais.md`
- `docs/relatorio-backend-playlists-tracks.md`
- `docs/relatorio-releases-app.md`
- `docs/audit/supabase-remote-vs-local-contract.md`
- `supabase/functions/resolve-login-email/index.ts`
- `supabase/functions/get-current-app-release/index.ts`
- `supabase/migrations/20260707011011_local_call_operational_events.sql`
- `railway-worker/main.py`

