# Handoff — histórico de solicitações de playlist

## Backend implantado

- Projeto: `aifadvyxsefxfcgzgqol`.
- Migrations remotas: `20260712113301_playlist_request_history_contract` e `20260712113509_fix_playlist_request_wrapper_success_envelope`.
- RPC: `public.get_my_playlist_requests(p_request jsonb DEFAULT '{}'::jsonb) RETURNS jsonb`.
- Envio integrado: `public.manage_operator_playlist` com `operation: "submit"`. O wrapper legado `submit_playlist` continua disponível e encaminha para o mesmo fluxo.
- Não há publicação, canal ou filtro de Realtime novo para este histórico.

## Chamada do App

Use somente `supabase.rpc('get_my_playlist_requests', { p_request })`. Não consulte `playlist_requests` diretamente e não envie `operator_id`.

```ts
const p_request = { request_id: crypto.randomUUID(), limit: 20 };
const { data, error } = await supabase.rpc('get_my_playlist_requests', { p_request });
```

`request_id` é UUID opcional de correlação; quando omitido, o servidor gera um. `limit` é opcional (padrão 20, mínimo 1, máximo 100).

Resposta de sucesso:

```json
{
  "success": true,
  "request_id": "d4b74aa1-0c63-4208-b836-c4f96d271c6b",
  "server_now": "2026-07-12T11:37:27.856986+00:00",
  "data": {
    "requests": [{
      "id": "uuid",
      "playlist_id": "uuid",
      "source_url": "https://...",
      "status": "approved",
      "created_at": "timestamptz",
      "updated_at": "timestamptz",
      "rejection_reason": null
    }]
  },
  "error": null
}
```

Sem solicitações, `success` continua `true` e `data.requests` é `[]`. Para usuário sem Operador ativo: `{"success":false,"data":null,"error":{"code":"FORBIDDEN"}}`. UUID inválido em `request_id` retorna `INVALID_UUID`; limite inválido retorna `INVALID_LIMIT`.

Status oficiais: `pending` (aguardando aprovação), `approved` (aprovada), `rejected` (rejeitada). Exiba o motivo somente quando `status === 'rejected'` e `rejection_reason` vier preenchido.

## Prompt para o Codex do App do Operador

Audite primeiro o código atual do App Electron e localize a implementação/modal de “Solicitações recentes” e o ponto que conclui o envio de Playlist Principal. Informe causa raiz, arquivos alterados e resultados dos testes.

O backend remoto do projeto `aifadvyxsefxfcgzgqol` agora oferece exclusivamente este contrato de leitura: `public.get_my_playlist_requests(p_request jsonb DEFAULT '{}'::jsonb) RETURNS jsonb`. Chame por `supabase.rpc('get_my_playlist_requests', { p_request: { request_id: crypto.randomUUID(), limit: 20 } })`. Não consulte tabelas diretamente, não envie `operator_id` e não use `get_my_playlists` como substituto.

Mapeie o envelope exatamente: `success`, `request_id`, `server_now`, `data.requests`, `error`. Cada item tem `id`, `playlist_id`, `source_url`, `status` (`pending`, `approved`, `rejected`), `created_at`, `updated_at` e `rejection_reason`. Mostre “Aguardando aprovação”, “Aprovada” e “Rejeitada”. Mostre “Nenhuma solicitação enviada.” apenas após resposta bem-sucedida com lista vazia. Em erro, mantenha dados já exibidos e mostre mensagem simples; detalhes somente nos logs.

O envio real é `manage_operator_playlist` com `operation: 'submit'`; `submit_playlist` é apenas compatibilidade. Após resposta bem-sucedida do envio, recarregue imediatamente o histórico. Não crie item local falso. Carregue somente na primeira consulta do modal; em atualização, mantenha a lista atual. Evite chamadas duplicadas e descarte respostas antigas por sequência/AbortController. Não use `setTimeout`, polling ou consulta periódica. Preserve o layout atual do modal.

Não implemente Realtime: o backend não publicou contrato seguro para isso. Respeite autenticação normal do Supabase; a RPC resolve o Operador por `auth.uid()` e só devolve as próprias solicitações.

Teste: envio, retry técnico com a mesma chave, novo envio com nova chave, fechamento/reabertura do modal, aprovação, rejeição, recarregamento após envio e isolamento entre dois Operadores. Confirme também que `get_my_playlists`, `get_playlist_tracks` e o fluxo atual de envio continuam inalterados.
