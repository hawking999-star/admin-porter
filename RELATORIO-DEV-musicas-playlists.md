# Relatório para o dev do app — Músicas (playlists por link)

Data: 06/07/2026
Projeto Supabase: `porter music` (`aifadvyxsefxfcgzgqol`)

## Modelo escolhido
Playlist é um **link** (URL) enviado pelo operador — **não** há upload de áudio nem bucket. Fluxo:

1. Cada operador tem **uma playlist principal**, criada automaticamente junto com o operador (e já criei para os operadores existentes).
2. O operador envia o **link** da playlist pelo app (botão). Pode ser da principal ou criar **secundárias**.
3. O envio entra como **pendente**. No admin, o gestor **aprova** (vira ativa) ou **rejeita com motivo** (o operador vê e reenvia).
4. O link aponta para o **servidor de streaming de vocês** (a configuração do servidor é por conta de vocês).

O admin (fila de aprovação) já está pronto e testado.

## Mudanças no banco (tabela `public.playlists`, já aplicadas)
Colunas novas:
- `source_url text` — o link enviado.
- `approval_status text` — `draft` | `pending` | `approved` | `rejected` (default `draft`).
- `rejection_reason text` — motivo quando rejeitada.
- `submitted_at`, `reviewed_at`, `reviewed_by` — carimbos.
- (`type` já existia: `principal` | `secondary`; `status` vira `active` quando aprovada.)

Regras:
- Índice único: no máximo **1 playlist principal por operador**.
- RLS: o operador **enxerga as próprias playlists** (`select`), então o app pode ler o link aprovado. O envio é feito pela RPC abaixo.

## RPC de envio (app): `public.submit_playlist(p_request jsonb)`
Chamar autenticado como o operador (mesmo padrão das outras RPCs). Operador e unidade vêm do token.

**Payload (`p_request`):**
- `type` (string): `principal` (default) ou `secondary`.
- `url` (string, obrigatório): precisa começar com `http://` ou `https://`.
- `name` (string, opcional): nome da playlist (usado nas secundárias).
- `request_id` (string, opcional).

**Exemplo (supabase-js):**
```ts
const { data } = await supabase.rpc("submit_playlist", {
  p_request: {
    type: "principal",            // ou "secondary"
    url: linkDigitado,
    name: "Sertanejo",            // opcional (secundárias)
    request_id: crypto.randomUUID(),
  },
});
// data = envelope padrão; em caso de sucesso: data.data.playlist = { id, type, approval_status: "pending" }
```

**Comportamento:**
- `principal` → atualiza a playlist principal do operador com o link e marca **pendente** (reenvio limpa a rejeição anterior).
- `secondary` → cria uma nova playlist secundária **pendente**.

**Erros (`success:false`, `error.code`):** `INVALID_CREDENTIALS`, `URL_REQUIRED`, `INVALID_URL`, `INVALID_TYPE`, `INTERNAL_ERROR`.

## O que o app precisa fazer
1. **Tela/botão "Enviar playlist"**: campo de link (+ nome para secundárias) → chama `submit_playlist`.
2. **Mostrar o status** de cada playlist: pendente / aprovada / rejeitada. Quando rejeitada, exibir o `rejection_reason` e permitir reenviar.
3. **Tocar a playlist aprovada**: ler as playlists do operador e usar o `source_url` das que estão `approval_status = 'approved'`.
   ```ts
   const { data } = await supabase
     .from("playlists")
     .select("id, name, type, source_url, approval_status, rejection_reason")
     .eq("approval_status", "approved");
   ```
   (A RLS já garante que o operador só vê as próprias.)

> Opcional: se preferir, dá para embutir a playlist principal aprovada na resposta do `reconcile_operator_state`/`start_operator_session` — só pedir que eu incluo.

## Status de validação
- ✅ Playlist principal criada automaticamente (e backfill dos operadores existentes).
- ✅ `submit_playlist` testada (principal e secundária) → entram pendentes.
- ✅ Aprovar/Rejeitar testado no admin (aprovada→ativa; rejeitada→com motivo).
- ⏳ Falta no app: botão de enviar link, exibir status/motivo e tocar a playlist aprovada.
