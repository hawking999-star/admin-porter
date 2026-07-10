# Validação — Integração do gerenciamento seguro de playlists (App Electron)

Data: 10/07/2026. Projeto Supabase: `aifadvyxsefxfcgzgqol` (remoto, ACTIVE_HEALTHY).
Escopo desta validação: **contrato de backend** (RPCs, retornos, RLS, grants).
O código-fonte do App Electron é outro repositório e **não está** neste workspace,
portanto os itens de comportamento do cliente foram validados de forma **indireta**
(o backend só permite o caminho por RPC; qualquer leitura direta é bloqueada por RLS).

## Resumo

- Playlists: contrato **conforme**. As três RPCs existem e devolvem todos os campos
  exigidos. Tracks e playlist_tracks estão fechados para o cliente — o App só
  consegue ler por RPC e só recebe `public_url`.
- Corrigido nesta validação: revogados os grants indevidos de `anon` na tabela
  `playlists` (migration `20260710101500_revoke_anon_grants_on_playlists.sql`).
- Comunicados/notas de release: **NÃO** seguem a regra "somente RPC" — e essa é a
  decisão registrada: **manter como está** (leitura direta + Realtime). Ver §4.

---

## 1. RPCs de playlist — existência e assinatura

| RPC | Assinatura | Status |
|-----|-----------|--------|
| `get_my_playlists` | `(p_request jsonb)` | OK |
| `get_playlist_tracks` | `(p_request jsonb)` | OK |
| `manage_operator_playlist` | `(p_request jsonb)` | OK |

Todas são `SECURITY DEFINER`, `search_path=''`, autenticam por `auth.uid()` →
`operators.auth_user_id` (operador `active`), grant de execução só para `authenticated`.

## 2. Retornos do backend — o que o App precisa

### `get_my_playlists` — CONFORME
`data.playlists[]` com `id`, `type`, `name`, `status`, `approval_status`, **`revision`**
e **`capabilities`** por playlist (via `private.operator_playlist_capabilities`).
Também retorna, em `data` **e** `meta`:

- `data.capabilities` = `{ can_create_secondary, can_submit_principal }`
- `secondary_count`
- `secondary_limit` = 2
- `principal_track_limit` = 170
- `track_duration_limit_seconds` = 960

### `get_playlist_tracks` — CONFORME
`data.playlist_id`, `data.playlist_revision` e `data.tracks[]`. Cada track:
`playlist_track_id`, `title`, `artist`, `duration_ms`, `position`,
**`public_url`** (de `tracks.metadata->>'public_url'`) e `status`.
**Não** devolve o `id` global de `tracks` nem `storage_object_key`. Só faixas
`available`.

### `manage_operator_playlist` — CONFORME
Aceita `request_id`, `idempotency_key` (obrigatório, uuid), `operation`
(`submit`, `create_secondary`, `rename`, `archive_secondary`, `add_tracks`,
`remove_tracks`, `reorder_tracks`), `playlist_id`, `expected_revision` (obrigatório
para playlist existente), `name`, `playlist_track_ids` ou `source_playlist_track_ids`
conforme a operação. Idempotência por hash do request (menos `request_id`);
conflito de revisão retorna `PLAYLIST_REVISION_CONFLICT` com `reload_required`.

`data` do sucesso contém todos os campos exigidos:
`created_playlist`, `affected_playlist_ids`, `affected_playlist_revisions`,
`removed_playlist_track_ids`, `added_playlist_track_ids`,
`already_present_source_ids`, `secondary_count`, `secondary_limit`
(+ `operation`, `playlist_id`, `revision`, `storage_cleanup_queued_count`).

### Envelope padrão (`_app_envelope`)
`{ success, request_id, server_now, contract_version:1, api_version:'v1', data, error, meta }`.

## 3. Isolamento do cliente (verificado por grants + RLS)

| Tabela | Grant a `anon` | Grant a `authenticated` | Policy do operador | Leitura direta pelo App? |
|--------|---------------|-------------------------|--------------------|--------------------------|
| `tracks` | nenhum | nenhum | só `admin_all` | Bloqueada (correto) |
| `playlist_tracks` | nenhum | nenhum | só `admin_all` | Bloqueada (correto) |
| `playlists` | **revogado nesta validação** | mantido | só `admin_all` | Bloqueada (correto) |

O App **não** usa `service_role`, **não** usa SDK de Storage/R2 e **não** manipula
`storage_object_key` — esses caminhos só existem nas RPCs do worker
(`claim_storage_deletion_job`, `complete_storage_deletion_job`), com grant apenas
para `service_role`. A única URL de áudio exposta é `public_url`.

**Correção aplicada:** revogado `all on public.playlists from anon`
(migration `20260710101500`). O grant de `authenticated` foi **mantido de propósito**:
o Admin lê `playlists` diretamente via `supabase.from('playlists')` e precisa dele;
o operador continua bloqueado pela RLS (existe apenas a policy `admin_all`, e a
antiga `playlists_op_sel` foi removida no contrato de playlists). `tracks` e
`playlist_tracks` não têm grant algum para cliente — acesso do Admin é por RPC
(`admin_music_library_page`, etc.).

## 4. Comunicados e notas de release — regra "somente RPC" NÃO aplicada

Estado atual (migrations `20260708181320` e `20260708182532`):

- Existem RPCs apenas de **confirmação**: `record_app_notice_acknowledgement`
  e `record_app_release_note_acknowledgement`.
- **Não** existem RPCs de **leitura** (`get_app_notices` / `get_app_release_notes`).
- O App lê `app_notices` e `app_release_notes` **direto por REST + Supabase Realtime**,
  filtrado por RLS de operador (`app_notices_operator_active_select`,
  `app_release_notes_operator_published_select`) — e essa leitura direta é
  **intencional**: o `PROMPT_DEV_APP_avisos_notas_realtime.md` instrui o dev a
  consumir as tabelas via Realtime ("se o SELECT retornou, é para mostrar").

Ou seja, para playlists a policy de SELECT do operador foi **removida** (RPC-only),
mas para avisos/notas ela foi **mantida de propósito** para viabilizar o push ao vivo.
Realtime assina tabelas com RLS; não assina RPC. Portanto, tornar avisos/notas
"somente RPC" implica **abrir mão do push ao vivo** por SELECT direto (ou trocar por
outro mecanismo, ex. Realtime Broadcast disparado por trigger).

**Decisão registrada: MANTER como está.** A regra "somente RPC" foi criada para
`playlists`/`tracks` porque essas tabelas expõem estrutura interna sensível
(id global de track, `storage_object_key`, catálogo). `app_notices` e
`app_release_notes` são tabelas de **conteúdo** (título, mensagem, versão) sem
colunas internas sensíveis, e a RLS de operador já entrega exatamente o que ele
pode ver. O SELECT direto é o que viabiliza o **push ao vivo** via Realtime — que é
um requisito explícito do fluxo. Forçar RPC-only aqui exigiria abrir mão do tempo
real (ou reimplementar com Broadcast por trigger) sem ganho real de segurança.
Portanto **não** foram criadas RPCs `get_app_notices` / `get_app_release_notes`;
o contrato atual está aprovado.

Observação (não bloqueante): as RPCs de ack (`record_app_notice_acknowledgement`,
`record_app_release_note_acknowledgement`) usam args posicionais e `raise exception`,
enquanto as de playlist usam envelope jsonb + `request_id`/idempotência. Só vale
padronizar se no futuro quiserem um contrato único; hoje funciona e é idempotente.
