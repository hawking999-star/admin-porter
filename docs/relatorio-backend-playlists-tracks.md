# Relatório técnico — Backend Porter Music (Playlists, Secundárias e Músicas)

Projeto Supabase: **porter music** — ref `aifadvyxsefxfcgzgqol` (Postgres 17).
Data desta rodada: **2026-07-06**. Público: dev do App Electron (operador).

Tudo abaixo foi verificado no banco real (schema, `pg_proc`, RLS, grants, edge functions e o worker `railway-worker/main.py`). Onde algo **não existe**, está dito explicitamente. Nada foi inventado.

Envelope padrão de todas as RPCs do app (`_app_envelope`):

```json
{
  "success": true,
  "request_id": "uuid-ou-string",
  "server_now": "2026-07-06T15:44:34.157Z",
  "contract_version": 1,
  "api_version": "v1",
  "data": { },
  "error": null,
  "meta": { }
}
```

Em erro: `success=false`, `data=null`, `error={ "code": "...", "message": "..." }`.

---

## Resumo do que mudou nesta rodada (migrations aplicadas)

| Version | Nome | O que faz |
|---|---|---|
| `20260706…` | `rename_principal_and_playlists_revision` | Cria `rename_principal_playlist`; `get_my_playlists` passa a retornar `revision` por playlist + `meta` com contagem de secundárias |
| `20260706…` | `secondary_playlist_limit` | Trigger `trg_enforce_secondary_limit` (backstop atômico) + `submit_playlist` devolve `SECONDARY_LIMIT_REACHED` |
| `20260706…` | `get_playlist_tracks` | Cria RPC de leitura de faixas de uma playlist do operador |
| `20260706…` | `harden_secondary_limit_trigger_grants` | Revoga EXECUTE da função de trigger (não é RPC) |

Todas testadas com o operador real autenticado e **revertidas via rollback** — nenhum dado de produção foi alterado (a Principal segue `revision=12`).

---

## Tarefa 1 — Renomear a Playlist Principal

**RPC:** `rename_principal_playlist(p_request jsonb)` → `POST /rest/v1/rpc/rename_principal_playlist`
**Permissão:** `authenticated` + `service_role` (anon revogado). Só o operador dono renomeia — a Principal é localizada por `created_by_operator_id = <operador autenticado>` e `type='principal'`.

**Payload:**
```json
{
  "request_id": "uuid",
  "name": "Novo nome da playlist",
  "playlist_id": "uuid",          // opcional; se ausente, usa a única Principal do operador
  "expected_revision": 12          // opcional; controle de concorrência
}
```

**Sucesso:**
```json
{
  "success": true,
  "data": {
    "playlist": { "id": "3dff5e1b-…", "type": "principal", "name": "Novo nome", "revision": 13 },
    "revision": 13,
    "unchanged": false
  },
  "meta": { "code": "PLAYLIST_RENAMED" }
}
```
Quando o nome já é igual ao atual: `unchanged=true` e a `revision` **não** muda (idempotência natural — pode reenviar à vontade).

**Erros:**

| code | Quando |
|---|---|
| `INVALID_CREDENTIALS` | sem sessão / operador inexistente ou inativo |
| `NAME_REQUIRED` | nome vazio ou só espaços |
| `NAME_TOO_LONG` | nome > **80** caracteres (retorna `max_length: 80`) |
| `PRINCIPAL_NOT_FOUND` | operador não tem Principal |
| `REVISION_CONFLICT` | `expected_revision` ≠ revisão atual (retorna `current_revision` e `expected_revision`) |
| `INTERNAL_ERROR` | erro inesperado |

**Respostas às perguntas da Tarefa 1:**
1. RPC: `rename_principal_playlist`.
2. Payload: acima.
3. Resposta de sucesso: acima (só altera `name`; preserva id, `type`, faixas e vínculos; nunca cria playlist nova — faz `UPDATE` no id existente).
4. Códigos de erro: tabela acima.
5. Limite: **80 caracteres**.
6. Campo de revisão: coluna **`playlists.revision`** (bigint, +1 a cada alteração). Concorrência via `expected_revision`.
7. Operadores **podem** renomear a própria Principal (confirmado por teste).
8. `get_my_playlists` **agora** retorna `id`, `name`, `revision` e `can_rename` por playlist (ver Tarefa 4). Antes retornava tudo menos `revision`.

**Fluxo do App (confirmado compatível):** comparar nome atual × novo → chamar `rename_principal_playlist` → esperar `success` → recarregar `get_my_playlists` → só então `submit_playlist` (sem `name`). Se o rename falhar, não chamar `submit_playlist`. ✔️

---

## Tarefa 2 — Limite de 2 playlists secundárias

**Regra oficial:** cada operador pode ter **no máximo 2** playlists `type='secondary'`. A Principal nunca conta.

**Critério exato de contagem** (uma secundária ocupa vaga quando):
`type = 'secondary'` **E** `status <> 'archived'` **E** `approval_status <> 'rejected'`.
Ou seja: contam as secundárias em `draft`, `pending`, `approved` que não estejam `archived`. Secundárias **rejeitadas** ou **arquivadas** liberam a vaga.

**Onde é aplicado (atômico, não só no app):**
- **`submit_playlist`** (é o caminho atual de criação de secundária, com `type='secondary'`): faz a checagem sob `pg_advisory_xact_lock` por operador e devolve erro estruturado.
- **Trigger `trg_enforce_secondary_limit` BEFORE INSERT ON `playlists`**: backstop no banco. Pega `pg_advisory_xact_lock` por operador, conta e levanta exceção `SECONDARY_LIMIT_REACHED`. Protege contra chamadas diretas à API/PostgREST e corridas (dois inserts simultâneos serializam no lock; o 2º é barrado). Secundárias criadas por admin (`created_by_operator_id IS NULL`) **não** entram no limite.

**RPC de criação:** `submit_playlist(p_request jsonb)` com `type='secondary'` (contrato já existente; agora com o limite).

**Payload:**
```json
{ "request_id": "uuid", "type": "secondary", "url": "https://youtube.com/playlist?list=…", "name": "opcional" }
```

**Erro ao atingir o limite:**
```json
{ "success": false, "error": { "code": "SECONDARY_LIMIT_REACHED", "message": "Limite de 2 playlists secundarias atingido.", "limit": 2 } }
```

**Respostas às perguntas da Tarefa 2:**
1. RPC: `submit_playlist` (type `secondary`).
2. Payload/sucesso: sucesso é o mesmo envelope `PLAYLIST_REQUEST_CREATED` do contrato atual.
3. Contagem: `secondary` + `status<>'archived'` + `approval_status<>'rejected'`.
4. Código do limite: **`SECONDARY_LIMIT_REACHED`**.
5. Atomicidade: **sim** — trigger + advisory lock por operador (testado: 3ª secundária bloqueada mesmo por insert direto).
6. `get_my_playlists` retorna todas as secundárias e ainda expõe `meta.secondary_count` / `meta.secondary_limit`.

> ⚠️ **Nota importante sobre o modelo atual de "secundária".** Hoje uma secundária é *outra playlist de URL externa* enviada por `submit_playlist` (mesmo ciclo de aprovação da Principal). **Não existe** ainda o conceito de "secundária curada a partir da Principal" (criar vazia e adicionar faixas da Principal). Isso afeta a Tarefa 4 — ver abaixo. Além disso, `submit_playlist` só permite **1 solicitação `pending` por tipo** de cada vez (`PLAYLIST_REQUEST_ALREADY_PENDING`), então o limite de 2 se aplica de fato sobre secundárias já **aprovadas/rascunho**, não sobre pendentes simultâneas.

---

## Tarefa 3 — Aprovação / importação de músicas

**Como funciona hoje (verificado):**

1. Admin aprova em `admin_review_playlist(p_playlist, p_action, p_reason)`. Ao aprovar: `approval_status='approved'`, `status='active'`, e **se a URL for YouTube**, enfileira 1 registro em `download_jobs (status='queued')` (com deduplicação: não enfileira se já há job `queued`/`running`). Decisão é **definitiva** (`already_reviewed` se já revista).
2. O **worker Railway** (`railway-worker/main.py`, service_role) faz o trabalho real: lê a playlist (até **170** faixas), baixa mp3 (≤ **15 MB**), sobe pro R2 e grava em **`tracks`** + **`playlist_tracks`** (`added_by_type='system'`, `position` sequencial). Atualiza `download_jobs.total/completed/failed` e status final `done` / `partial` / `error`. Retry até 3 tentativas.
3. As faixas são associadas **apenas à playlist do job** (a Principal aprovada). Secundárias **nunca** recebem faixas automaticamente. ✔️

**Tabelas de música:** `tracks` (id, title, artist, category_id, duration_ms, `storage_object_key` UNIQUE, content_hash, mime_type, status, metadata, revision) e `playlist_tracks` (playlist_id, track_id, position, added_by_type, added_by_id). Sem duplicação **dentro** da mesma playlist: a chave de storage é `tracks/{playlist_id}/{video_id}.mp3` (UNIQUE).

**Gaps encontrados (precisam de decisão/ajuste):**

- **Requisito "marcar como aceita só após importação real":** hoje `approval_status` vira `approved` **no ato da revisão**, antes do download terminar. O progresso/estado real da importação vive em **`download_jobs.status`** (`queued→running→done/partial/error`). Recomendo o consumidor tratar `download_jobs` como fonte de verdade de "importação concluída" (o admin web já faz isso). Se você quiser que `approval_status` só mude no fim, é uma alteração de design (aprovação em 2 fases) — dá para fazer, mas muda o contrato do admin.
- **Reprocessamento (retry) tem bug de idempotência no worker:** ao reprocessar, o worker apaga as linhas de `playlist_tracks` (system) mas **não** apaga as `tracks` órfãs. Como `storage_object_key` é UNIQUE, o `INSERT` de uma faixa já existente **falha** (viola unique) e conta como `failed`. Não duplica, mas quebra o reprocesso parcial. **Correção (1 linha, no worker):** trocar o `insert` em `tracks` por *upsert* `on_conflict=storage_object_key` (ou apagar as `tracks` órfãs junto no cleanup). Posso aplicar se você quiser.
- **Operador não enxerga o progresso de download:** `download_jobs` só tem policy de admin (RLS `admin_all`). Se o App Electron precisar mostrar "baixando 12/170", falta uma RPC `get_playlist_import_status` (não existe). Fácil de adicionar — me avise.

**Teste final da Tarefa 3:** o caminho existe e está correto para o "caminho feliz" (import completo → todas na Principal → nenhuma em secundária). O ponto a corrigir é só o reprocesso (upsert no worker).

---

## Tarefa 4 — App consultar músicas

### 4.1 Leitura de faixas — IMPLEMENTADO nesta rodada

Necessário porque `tracks` e `playlist_tracks` **não têm** policy de SELECT para operador (só `admin_all`). Logo a leitura precisa ser via RPC `SECURITY DEFINER` com checagem de propriedade — foi o que criei.

**RPC:** `get_playlist_tracks(p_request jsonb)` → `POST /rest/v1/rpc/get_playlist_tracks`
**Permissão:** `authenticated` + `service_role` (anon revogado). Só faixas de playlist cujo `created_by_operator_id` = operador autenticado (serve Principal e secundárias).

**Payload:**
```json
{ "request_id": "uuid", "playlist_id": "uuid", "limit": 200, "offset": 0 }
```
`limit` default 200 (máx 500), `offset` default 0.

**Sucesso:**
```json
{
  "success": true,
  "data": {
    "playlist_id": "3dff5e1b-…",
    "playlist_revision": 12,
    "tracks": [
      {
        "position": 1,
        "id": "uuid-da-track",
        "title": "…",
        "artist": "…",
        "duration_ms": 210000,
        "storage_object_key": "tracks/<playlist>/<videoid>.mp3",
        "public_url": "https://pub-xxxx.r2.dev/tracks/…mp3",
        "status": "available",
        "updated_at": "2026-07-06T…Z"
      }
    ]
  },
  "meta": { "total": 170, "limit": 200, "offset": 0, "returned": 170 }
}
```

**Erros:** `INVALID_CREDENTIALS`, `PLAYLIST_ID_REQUIRED`, `PLAYLIST_NOT_FOUND`, `FORBIDDEN` (playlist de outro operador).

> **Reprodução/áudio:** o campo tocável é `public_url` (vem de `tracks.metadata.public_url`), que **só é preenchido se o bucket R2 estiver com acesso público** (`R2_PUBLIC_BASE_URL` setado no worker). Se o bucket for privado, `public_url` vem `null` e o `storage_object_key` sozinho não toca — seria preciso um endpoint de **signed URL** (não existe hoje). Decida: bucket público (simples) ou criar RPC/edge function de URL assinada.

### 4.2 Mutações de secundárias — NÃO EXISTEM (proposta, aguarda decisão)

Os nomes `mutate_operator_playlist` / criar-secundária-vazia / renomear-secundária / adicionar-faixa-da-principal / mover / remover **não estão implementados**. E há uma decisão de modelo antes de implementar:

> **Hoje "secundária" = playlist de URL externa** (via `submit_playlist`). A Tarefa 4 descreve secundárias como **listas curadas a partir da Principal** (criar vazia, adicionar faixas da Principal, mover/remover). São **dois modelos diferentes**. Preciso que você confirme qual é o desejado antes de eu criar esses contratos — implementar "às cegas" seria criar contrato de fachada.

Se for o modelo **curado** (o que a Tarefa 4 sugere), o conjunto a implementar seria, todos `SECURITY DEFINER`, envelope padrão, com `expected_revision` e idempotência por `request_id`:

- `create_secondary_playlist(name)` — cria vazia, aplica o limite da Tarefa 2. Erros: `SECONDARY_LIMIT_REACHED`, `NAME_REQUIRED/TOO_LONG`.
- `rename_secondary_playlist(playlist_id, name, expected_revision)` — igual ao rename da Principal, mas para `type='secondary'` do dono.
- `add_track_to_secondary(secondary_id, track_id, expected_revision)` — só permite `track_id` que já esteja na **Principal** do operador; grava em `playlist_tracks` com `added_by_type='operator'`.
- `move_track_in_secondary` / `remove_track_from_secondary(secondary_id, track_id/position)`.
- Critério de arquivadas/desativadas: operações recusam playlists com `status IN ('archived','inactive')` → erro `PLAYLIST_ARCHIVED`.

Digo o texto exato do payload/resposta/erro de cada uma assim que você confirmar o modelo. **Confirmação:** essas 5 operações **ainda não existem** no projeto.

---

## Itens gerais da entrega

**Histórico de reenvios de solicitações:** **não existe** tabela dedicada. `submit_playlist` para a Principal faz `UPDATE` no lugar (sobrescreve `source_url`, zera `rejection_reason`, `approval_status='pending'`, `revision+1`). O único rastro é o contador `playlists.revision` + `admin_audit_logs` (ações de admin) + `operational_events` (hoje vazia). Se você precisa de histórico de reenvios, é preciso criar uma tabela `playlist_submissions` (me avise).

**Realtime:** hoje **não é necessário** para renomear/limite/leitura (o App faz request→response e recarrega `get_my_playlists`). **Seria útil** só para o progresso de download aparecer sozinho — assinar a tabela `download_jobs` filtrando por `playlist_id` (payload: `status,total,completed,failed`). Alternativa sem Realtime: o App faz polling da RPC de status (a criar) enquanto `status IN ('queued','running')`.

**Códigos de erro no projeto (playlists/tracks):**
`INVALID_CREDENTIALS`, `INVALID_TYPE`, `URL_REQUIRED`, `INVALID_URL`, `PLAYLIST_REQUEST_ALREADY_PENDING`, `PLAYLIST_REQUEST_CREATED` (sucesso), `SECONDARY_LIMIT_REACHED` (novo), `NAME_REQUIRED` (novo), `NAME_TOO_LONG` (novo), `PRINCIPAL_NOT_FOUND` (novo), `REVISION_CONFLICT` (novo), `PLAYLIST_RENAMED` (sucesso, novo), `PLAYLIST_ID_REQUIRED` (novo), `PLAYLIST_NOT_FOUND` (novo), `FORBIDDEN` (novo), `INTERNAL_ERROR`. RPCs de admin usam exceções cruas: `forbidden`, `playlist_not_found`, `already_reviewed`, `invalid_action`.

**Mudanças necessárias no App Electron (`src/…`):**
- `supabase-client.js` / `renderer.js`: adicionar chamada a **`rename_principal_playlist`** antes do `submit_playlist` (fluxo já previsto).
- Tratar o novo erro **`SECONDARY_LIMIT_REACHED`** no envio de secundária (usar `meta.secondary_count`/`secondary_limit` de `get_my_playlists` para desabilitar o botão preventivamente).
- Adicionar chamada a **`get_playlist_tracks`** (a tela de músicas do operador não existia — este é o primeiro contrato de catálogo).
- Ler `revision` de `get_my_playlists` e mandar em `expected_revision` no rename.
- **Nenhuma** mudança destrutiva; contratos existentes seguem iguais.

**Segurança (advisor):** a função de trigger teve EXECUTE revogado (não é RPC). As demais RPCs seguem o padrão do projeto (checam `auth.uid()` internamente). Fica pendente, no nível do projeto (pré-existente, opcional): revisar RPCs ainda expostas a `anon` e ativar *Leaked Password Protection* no Auth.
