# Contrato para o dev do app — "Solicitar playlist"

Data: 06/07/2026 · Projeto Supabase `porter music` (`aifadvyxsefxfcgzgqol`)

## Modelo confirmado: LINK (sem upload de áudio)
A playlist é uma **URL** (Spotify/YouTube/etc.). Não há arquivos de áudio no sistema.
Por isso, os limites de **15 MB por arquivo**, **16 min por música** e **170 músicas por playlist**
**não se aplicam** neste modelo (eles pressupõem upload de faixas). Os códigos
`PLAYLIST_TRACK_LIMIT_REACHED`, `AUDIO_FILE_TOO_LARGE`, `AUDIO_DURATION_EXCEEDED` ficam
**reservados** para um futuro modelo de upload — se um dia migrarem para arquivos, implementamos
bucket 15 MB + Edge Function de duração + trava de 170 (com concorrência) nessa etapa.

## Diagnóstico do "botão que não faz nada"
O botão (ícone de corrente) não estava ligado a nenhuma ação real. Agora existe a RPC abaixo,
que **gera uma solicitação real** e retorna sucesso/erro padronizado.

---

## 1) Enviar solicitação — RPC `submit_playlist`
Chamar autenticado como o operador (mesmo padrão das outras RPCs). Operador e unidade vêm do token.

**Payload (`p_request`):**
| campo | tipo | obrigatório | notas |
|---|---|---|---|
| `url` | string | sim | precisa começar com `http://` ou `https://` (máx. 2048) |
| `type` | string | não | `principal` (padrão) ou `secondary` |
| `name` | string | não | nome (usado nas secundárias / renomear principal) |
| `request_id` | string | não | rastreio/idempotência |

**Exemplo (supabase-js):**
```ts
const { data } = await supabase.rpc("submit_playlist", {
  p_request: { type: "principal", url: link, request_id: crypto.randomUUID() },
});
```

**Sucesso** (`success: true`):
```json
{
  "success": true,
  "server_now": "2026-07-06T13:42:40.958Z",
  "data": {
    "code": "PLAYLIST_REQUEST_CREATED",
    "request": {
      "id": "playlist-uuid",
      "type": "principal",
      "status": "pending",
      "approval_status": "pending",
      "source_url": "https://open.spotify.com/playlist/....",
      "submitted_at": "2026-07-06T13:42:40.958Z"
    }
  },
  "meta": { "code": "PLAYLIST_REQUEST_CREATED" },
  "error": null
}
```

**Erros** (`success: false`, código em `error.code`):
| código | quando |
|---|---|
| `PLAYLIST_REQUEST_ALREADY_PENDING` | já existe solicitação pendente do mesmo tipo (aguardar revisão) |
| `URL_REQUIRED` | link vazio |
| `INVALID_URL` | link não começa com http(s) ou é longo demais |
| `INVALID_TYPE` | `type` diferente de principal/secondary |
| `INVALID_CREDENTIALS` | sessão ausente / operador inativo |
| `INTERNAL_ERROR` | erro inesperado (`error.message`) |

Regras: reenviar quando **rejeitada/aprovada/rascunho** é permitido (volta a `pending`);
reenviar quando **já pendente** é bloqueado. Há trava de concorrência (advisory lock) para evitar
duplicidade em cliques/chamadas simultâneas.

---

## 2) Consultar andamento — RPC `get_my_playlists`
```ts
const { data } = await supabase.rpc("get_my_playlists");
// data.data.playlists = [{ id, type, name, source_url, approval_status, status, rejection_reason, submitted_at, reviewed_at }]
```
Retorna as playlists do próprio operador (principal + secundárias) com o status atual.
Alternativa: ler direto a tabela (a RLS já restringe ao próprio operador):
```ts
supabase.from("playlists").select("id,type,name,source_url,approval_status,rejection_reason,submitted_at,reviewed_at");
```

## 3) Atualização em tempo real (Realtime)
A tabela `public.playlists` está publicada em `supabase_realtime`. O app pode assinar as mudanças
das próprias playlists (a RLS filtra para o operador):
```ts
supabase.channel("minhas-playlists")
  .on("postgres_changes",
    { event: "UPDATE", schema: "public", table: "playlists" },
    (payload) => atualizarUI(payload.new))  // ex.: aprovada / rejeitada
  .subscribe();
```
Assim, quando o admin aprova/rejeita, o app recebe o novo `approval_status` e o `rejection_reason`
sem precisar dar refresh.

---

## 4) Lado do Admin (já pronto)
- Aba **Músicas** = fila de aprovação. Lista, filtra, aprova e rejeita (com motivo).
- RPC usada: `admin_review_playlist(p_playlist uuid, p_action text /* 'approve' | 'reject' */, p_reason text)`.

## Tabelas e estados
**Tabela `public.playlists`** (campos relevantes):
`id`, `created_by_operator_id`, `unit_id`, `type` (`principal`|`secondary`), `source_url`,
`approval_status`, `status`, `rejection_reason`, `submitted_at`, `reviewed_at`, `reviewed_by`.

**`approval_status`** (estado da solicitação):
- `draft` — criada, sem link enviado (a principal nasce assim junto com o operador).
- `pending` — link enviado, aguardando revisão.
- `approved` — aprovada (o `status` vira `active`).
- `rejected` — rejeitada; `rejection_reason` preenchido; operador pode reenviar.

## Segurança (anti-burla) — validado
O operador **não** tem policy de INSERT/UPDATE em `playlists`. Testado: INSERT direto pela API
(role `authenticated`) é **bloqueado pelo RLS**; UPDATE direto afeta **0 linhas**. Toda mudança de
solicitação passa obrigatoriamente pela RPC `submit_playlist`, e toda aprovação pela
`admin_review_playlist` (só admin). Ou seja, não dá pra burlar chamando o Supabase direto.

## Teste final (executado)
1. ✅ Solicitação criada pelo app (`submit_playlist` → `PLAYLIST_REQUEST_CREATED`).
2. ✅ Aparece no Admin (fila de aprovação / `get_my_playlists`).
3. ✅ Aprovar e rejeitar (com motivo) funcionam.
4. ✅ Retorno padronizado ao app (envelopes + realtime).
5–7. ⛔ Limites de 170/15 MB/16 min — **não se aplicam** ao modelo de link (reservados p/ upload futuro).
8. ✅ Não é possível burlar via Supabase direto (RLS bloqueia insert/update do operador).

## Migrations aplicadas nesta entrega
- `playlist_request_contract` — `submit_playlist` (códigos padronizados + trava de pendente + concorrência), `get_my_playlists`, e `playlists` no publication de realtime.
