# Contrato seguro de playlists — App do Operador

Data da auditoria: 10/07/2026. Projeto Supabase: `aifadvyxsefxfcgzgqol`.

## Resultado

O contrato de banco está aplicado no Supabase remoto. O Electron usa somente
`supabase.rpc()`: não consulta `playlists`, `tracks` ou `playlist_tracks`, não acessa
Storage/R2 e não recebe `track_id` global nem `storage_object_key`. A única URL de
áudio retornada é `public_url`.

O código do worker que consome exclusões órfãs também está implementado neste repo,
mas ainda precisa ser publicado no Railway. A CLI local não estava autenticada.

## 1. O que já existia e estava correto

- `get_my_playlists`, `get_playlist_tracks`, `submit_playlist`,
  `rename_principal_playlist` e `manage_operator_playlist` autenticavam por
  `auth.uid()`, usavam `SECURITY DEFINER`, `search_path=''` e grants somente para
  `authenticated`.
- O limite de duas secundárias já tinha trigger com advisory lock por Operador.
- Os limites de 170 faixas na Principal e 960 segundos por faixa já tinham triggers.
- `tracks` e `playlist_tracks` já estavam sem grants para `anon`/`authenticated`.
- Mutações já usavam revisão, idempotência e `playlist_changed`.

## 2. O que foi criado ou alterado

- Novas operações `create_secondary` e `add_tracks`.
- `remove_tracks` na Principal agora remove os mesmos tracks de todas as playlists
  do mesmo Operador e incrementa todas as revisions afetadas.
- Remoção em secundária continua local àquela secundária e nunca agenda exclusão.
- Fila `storage_deletion_jobs` e RPCs exclusivos do worker para compensação R2.
- Trigger que impede criar vínculo para track que não esteja `available`.
- Retornos padronizados com estado suficiente para a UI.
- Capabilities completas e explícitas.
- `get_playlist_tracks` deixou de retornar o `id` global de `tracks`.
- A policy `playlists_op_sel` foi removida; Operadores leem playlists somente por RPC.
- O wrapper `rename_principal_playlist` resolve/valida exclusivamente a Principal.

## 3. Migrations aplicadas

- `20260710093219_secure_operator_playlist_management.sql` — base segura anterior.
- `20260710094539_complete_operator_playlist_contract_v2.sql` — contrato completo,
  fila R2, operações, capabilities e segurança.
- `20260710095124_harden_storage_deletion_claim.sql` — claim somente para track
  `disabled` e sem referências.
- `20260710095237_enforce_rename_principal_wrapper_scope.sql` — escopo do wrapper.

## 4. Objetos alterados

- RPCs App: `manage_operator_playlist(jsonb)`, `get_my_playlists(jsonb)`,
  `get_playlist_tracks(jsonb)`, `submit_playlist(jsonb)` e
  `rename_principal_playlist(jsonb)`.
- RPCs worker, grant apenas `service_role`: `claim_storage_deletion_job()` e
  `complete_storage_deletion_job(uuid, boolean, text)`.
- Helpers privados: `private.try_uuid`, `private.operator_playlist_capabilities` e
  `private.require_available_track_link`.
- Tabela interna: `public.storage_deletion_jobs`, com RLS e sem policy de cliente.
- Trigger: `trg_require_available_track_link` em `playlist_tracks`.
- Policy removida: `playlists_op_sel`.

## 5. Leituras

### `get_my_playlists`

Entrada:

```json
{ "request_id": "uuid-ou-correlation-id" }
```

Retorna `playlists[]`, cada uma com `id`, `type`, `name`, `status`,
`approval_status`, `revision` e `capabilities`. Também retorna em `data` e `meta`:
`secondary_count`, `secondary_limit=2`, `principal_track_limit=170` e
`track_duration_limit_seconds=960`.

### `get_playlist_tracks`

Entrada:

```json
{ "request_id": "uuid-ou-correlation-id", "playlist_id": "uuid" }
```

Cada item disponível contém somente `playlist_track_id`, `title`, `artist`,
`duration_ms`, `position`, `public_url` e `status`. Não contém `track_id` global,
`storage_object_key`, bucket ou credencial.

## 6. Mutações

Todas chamam:

```ts
supabase.rpc('manage_operator_playlist', { p_request: payload })
```

### `create_secondary`

```json
{
  "request_id": "create-1",
  "idempotency_key": "uuid",
  "operation": "create_secondary",
  "name": "Minha playlist"
}
```

Cria secundária vazia, ativa, com revision `1`. Normaliza espaços, exige nome e
aceita no máximo 80 caracteres. O limite de duas é serializado no backend.

### `submit`

```json
{
  "request_id": "submit-1",
  "idempotency_key": "uuid",
  "operation": "submit",
  "type": "principal",
  "url": "https://youtube.com/playlist?list=...",
  "name": "Principal",
  "expected_revision": 4
}
```

Mantém o fluxo legado de solicitação/importação. `expected_revision` é obrigatório
quando uma Principal existente será atualizada. Para secundária nova, o limite de
duas também é aplicado.

### `rename`

```json
{
  "request_id": "rename-1",
  "idempotency_key": "uuid",
  "operation": "rename",
  "playlist_id": "uuid",
  "expected_revision": 4,
  "name": "Novo nome"
}
```

Aceita Principal ou secundária pertencente ao Operador, não arquivada.

### `archive_secondary`

```json
{
  "request_id": "archive-1",
  "idempotency_key": "uuid",
  "operation": "archive_secondary",
  "playlist_id": "uuid",
  "expected_revision": 2
}
```

Nunca aceita Principal. Não existe operação de excluir playlist Principal.

### `add_tracks`

```json
{
  "request_id": "add-1",
  "idempotency_key": "uuid",
  "operation": "add_tracks",
  "playlist_id": "uuid-da-secundaria",
  "expected_revision": 3,
  "source_playlist_track_ids": ["uuid-da-faixa-na-principal"]
}
```

Os IDs de origem precisam ser `playlist_track_id` da Principal do mesmo Operador.
Somente tracks `available` são aceitos. O backend cria apenas vínculos; não copia
track nem arquivo. Itens já presentes são sucesso/no-op e aparecem em
`already_present_source_ids`. IDs repetidos no mesmo payload retornam
`DUPLICATE_TRACK_REFERENCE`.

### `remove_tracks`

```json
{
  "request_id": "remove-1",
  "idempotency_key": "uuid",
  "operation": "remove_tracks",
  "playlist_id": "uuid",
  "expected_revision": 7,
  "playlist_track_ids": ["uuid", "uuid"]
}
```

Na secundária, remove somente os vínculos daquela secundária. Na Principal, resolve
os tracks internamente e remove todos os vínculos desses tracks em playlists do
mesmo Operador, incluindo secundárias e arquivadas. Outros Operadores não são
afetados. Todas as playlists alteradas recebem revision nova.

### `reorder_tracks`

```json
{
  "request_id": "reorder-1",
  "idempotency_key": "uuid",
  "operation": "reorder_tracks",
  "playlist_id": "uuid",
  "expected_revision": 5,
  "playlist_track_ids": ["uuid-na-posicao-0", "uuid-na-posicao-1"]
}
```

A lista deve conter exatamente todas as faixas disponíveis da playlist, na ordem
final desejada.

## 7. Retorno padronizado

Todo sucesso de `manage_operator_playlist` retorna em `data`:

- `operation`, `playlist_id`, `revision`;
- `affected_playlist_ids`, `affected_playlist_revisions`;
- `created_playlist` ou `null`;
- `removed_playlist_track_ids`, `added_playlist_track_ids`;
- `already_present_source_ids`;
- `secondary_count`, `secondary_limit`;
- `storage_cleanup_queued_count`.

Resposta real do teste para criação:

```json
{
  "success": true,
  "data": {
    "operation": "create_secondary",
    "revision": 1,
    "secondary_count": 1,
    "secondary_limit": 2,
    "created_playlist": {
      "name": "Secundaria Um",
      "type": "secondary",
      "status": "active",
      "revision": 1
    }
  },
  "error": null,
  "meta": { "code": "PLAYLIST_CHANGED" }
}
```

Resposta real de conflito:

```json
{
  "success": false,
  "data": null,
  "error": {
    "code": "PLAYLIST_REVISION_CONFLICT",
    "expected_revision": 1,
    "current_revision": 4,
    "reload_required": true
  }
}
```

## 8. Códigos estáveis

`SECONDARY_LIMIT_REACHED`, `PLAYLIST_REVISION_CONFLICT`,
`PLAYLIST_NOT_ALLOWED`, `TRACK_NOT_AVAILABLE`, `FORBIDDEN`,
`IDEMPOTENCY_KEY_REUSED`, `IDEMPOTENCY_KEY_REQUIRED`, `INVALID_OPERATION`,
`INVALID_REQUEST`, `INVALID_UUID`, `INVALID_REVISION`, `INVALID_TYPE`,
`INVALID_URL`, `NAME_REQUIRED`, `NAME_TOO_LONG`, `PRINCIPAL_NOT_FOUND`,
`DUPLICATE_TRACK_REFERENCE` e `INTERNAL_ERROR`.

O Electron deve decidir por `success` e `error.code`, nunca por texto.

## 9. Capabilities finais

Por playlist:

- `can_rename`
- `can_remove_tracks`
- `can_reorder_tracks`
- `can_add_tracks_from_principal`
- `can_archive`
- `can_remove_from_principal`
- `can_edit_principal_name`
- `can_delete_playlist` — sempre `false`; secundária é arquivada.

Globais em `data.capabilities`:

- `can_create_secondary`
- `can_submit_principal`

## 10. Revision e idempotência

- `create_secondary` e criação inicial via `submit` começam em revision `1`.
- Toda alteração de playlist existente exige `expected_revision`.
- Conflito não aplica alteração parcial e retorna a revision atual.
- Retry da mesma tentativa: mesma `idempotency_key` e mesmo payload.
- Nova ação: nova chave.
- Mesma chave com payload diferente: `IDEMPOTENCY_KEY_REUSED`.
- Resposta e auditoria são persistidas na mesma transação da mutação.

## 11. Exclusão compartilhada e Storage

Quando a Principal remove tracks, as linhas de `tracks` são bloqueadas antes da
contagem global. Se ainda existir referência de outro Operador, o registro e o
objeto permanecem intactos. Quando a última referência desaparece:

1. o track muda para `disabled`;
2. um job interno recebe `track_id` e `storage_object_key`;
3. o trigger impede qualquer vínculo novo para o track desabilitado;
4. o worker só faz claim se ele continua `disabled` e sem referências;
5. o worker apaga o objeto R2;
6. após sucesso, a RPC reconta referências e remove o job e o registro global.

Se o delete R2 ou a confirmação falhar, o job é reenfileirado. `delete_object` é
repetível; se o objeto já tiver sido removido, a confirmação posterior conclui a
limpeza do banco. `storage_object_key` nunca sai dos RPCs do App.

## 12. Teste consolidado

O teste transacional com rollback passou cobrindo: limites, duas secundárias e
bloqueio da terceira, renomes, add individual/lote, duplicados, reorder, remoção em
secundária, cascata da Principal, compartilhamento entre dois Operadores, fila da
última referência, finalização após sucesso R2, conflito, idempotência, isolamento,
capabilities e 14 eventos `playlist_changed`.

Arquivo: `supabase/tests/operator_playlist_contract_consolidated.sql`.

## 13. Implementação necessária no Electron

- Manter somente `supabase.rpc()`.
- Atualizar modelos de leitura: não existe mais `track.id`; usar
  `playlist_track_id`.
- Tocar somente `public_url`.
- Renderizar ações por capabilities.
- Gerar uma `idempotency_key` por ação e preservá-la durante retries.
- Guardar a revision recebida e enviá-la na próxima mutação.
- Em `PLAYLIST_REVISION_CONFLICT`, recarregar playlists e faixas.
- Após sucesso, aplicar os campos padronizados ou refazer as duas leituras.
- Nunca montar URL de R2, consultar tabelas ou enviar chave de objeto.

## Prompt pronto para o Codex do App Electron

```text
Implemente no Porter Music Electron o gerenciamento de playlists usando somente
supabase.rpc(). Não consulte playlists, tracks, playlist_tracks ou Storage e não
use service_role. A única URL tocável é track.public_url.

Leituras:
- get_my_playlists({ request_id })
- get_playlist_tracks({ request_id, playlist_id })

get_playlist_tracks retorna playlist_track_id, title, artist, duration_ms,
position, public_url e status. Não existe track.id nem storage_object_key no
contrato do App.

Mutações: supabase.rpc('manage_operator_playlist', { p_request }). Toda ação usa
request_id, idempotency_key UUID e, para playlist existente, expected_revision.
Operações e campos:
- create_secondary: name
- submit: type, url, name e expected_revision se atualizar Principal
- rename: playlist_id, expected_revision, name
- archive_secondary: playlist_id, expected_revision
- add_tracks: playlist_id da secundária, expected_revision,
  source_playlist_track_ids da Principal
- remove_tracks: playlist_id, expected_revision, playlist_track_ids
- reorder_tracks: playlist_id, expected_revision, lista completa ordenada em
  playlist_track_ids

Use exatamente as capabilities retornadas: can_rename, can_remove_tracks,
can_reorder_tracks, can_add_tracks_from_principal, can_archive,
can_remove_from_principal, can_edit_principal_name, can_delete_playlist e a global
can_create_secondary. A Principal nunca pode ser arquivada/excluída.

Em sucesso, consuma operation, playlist_id, revision, affected_playlist_ids,
affected_playlist_revisions, created_playlist, removed_playlist_track_ids,
added_playlist_track_ids, already_present_source_ids, secondary_count e
secondary_limit. Em falha, use somente error.code. Para
PLAYLIST_REVISION_CONFLICT, recarregue get_my_playlists e get_playlist_tracks.
Retry da mesma tentativa mantém a mesma idempotency_key e payload; uma nova ação
gera nova chave. Nunca inferir erro por mensagem textual.

Preserve os wrappers submit_playlist e rename_principal_playlist onde já forem
usados, incluindo idempotency_key. Não implemente nenhuma exclusão de R2 no App.
```
