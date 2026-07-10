# Handoff — integração local de chamadas (MicroSIP / Discord)

Backend **pronto e testado** (Supabase `aifadvyxsefxfcgzgqol`). A detecção é 100% local
(Electron + helper .NET 8). O Supabase **não** detecta chamada, não acompanha áudio e
**não** recebe atualização contínua. Você só envia **dois eventos discretos**.

## Regra de ouro

Uma ligação completa = **no máximo 2 chamadas** à RPC: um `call_started` e um
`call_finished`. Nada de polling, heartbeat de chamada, ou "confirmar" a ligação depois.

## A única RPC

`operator_operational_event` (via `supabase.rpc(...)`, com o operador autenticado).

### Payload

```json
{
  "event": "call_started",
  "event_id": "b3f1c2a4-....-uuid",
  "source": "microsip",
  "occurred_at": "2026-07-10T12:00:00.000Z",
  "metadata": { "phase": "incoming" }
}
```

- `event`: **só** `call_started` ou `call_finished`. Qualquer outro → erro `INVALID_EVENT`.
- `event_id`: **UUID obrigatório e único por evento**. É a chave de idempotência.
  Gere um novo a cada transição real. Se reenviar (retry), use o **mesmo** `event_id`.
- `source`: `microsip`, `discord`, etc. (livre).
- `occurred_at`: ISO-8601 do momento local do evento. Se faltar, o backend usa `now()`.
- `metadata`: objeto livre (ex.: `phase`). Opcionais também aceitos: `request_id`,
  `session_id`, `device_id`. Se você tem o `session_id` da sessão atual, envie — evita
  ambiguidade quando há mais de uma sessão.

### Chamada (TypeScript, no Electron)

```ts
const { data, error } = await supabase.rpc("operator_operational_event", {
  p_request: {
    event: "call_started",          // ou "call_finished"
    event_id: crypto.randomUUID(),  // NOVO por transição; reter p/ retry
    source: "microsip",
    occurred_at: new Date().toISOString(),
    session_id: currentSessionId,   // opcional, recomendado
    metadata: { phase: "incoming" },
  },
});
```

## Resposta (envelope padrão)

```json
{
  "success": true,
  "server_now": "2026-07-10T12:00:00.000Z",
  "data": {
    "result": "applied",
    "call_active": false,
    "status_operacional": "ativo",
    "server_now": "2026-07-10T12:00:00.000Z",
    "blocked_until": null,
    "pending_challenge": null,
    "expires_at": null,
    "next_screen": "player"
  },
  "meta": { "changed": true, "event_id": "..." }
}
```

- `data.result`: `applied` (mudou), `duplicate` (mesmo `event_id` já processado) ou
  `no_change` (já estava nesse estado).
- **Use `data` como fonte de verdade** para decidir a tela: `next_screen`
  (`call` | `player` | `challenge` | `blocked` | `outside_shift` | `login`),
  `status_operacional`, `pending_challenge`, `expires_at`, `blocked_until`.
- **`server_now` manda no tempo.** Nunca use o relógio local para expiração de desafio.

## Comportamento que você pode confiar

**`call_started`** → operador vira "Em atendimento" (`call_active=true`,
`status_operacional=em_atendimento`, `next_screen=call`). O desafio pendente é
**pausado** e seu `expires_at` volta **null** — ou seja, **não expira nem penaliza**
enquanto durar a chamada. Início repetido não faz nada novo.

**`call_finished`** → encerra (`call_active=false`), **reconcilia na hora** e a
resposta **já traz o estado completo**: para onde ir (`next_screen`), desafio pendente
restaurado com novo `expires_at`, bloqueio, etc. **Não chame nenhuma função de
reconciliação depois** — a resposta do `call_finished` basta.

## Idempotência / retries

- Reenviar o **mesmo `event_id`** → `result: "duplicate"`, sem duplicar histórico.
- `call_started` quando já está em chamada → `result: "no_change"`.
- `call_finished` quando não está em chamada → `result: "no_change"`.
- Em falha de rede, **repita com o mesmo `event_id`** (seguro).

## O que NÃO fazer (proibido por contrato)

- ❌ Polling / heartbeat **de chamada** (use o heartbeat de sessão que já existe).
- ❌ Canal Realtime ou subscription exclusiva para chamada / broadcast de `call_active`.
- ❌ Enviar `call_active` continuamente ou "manter vivo" o estado.
- ❌ Chamar reconcile após `call_finished`.
- ❌ Mandar qualquer evento que não seja `call_started` / `call_finished`.

## Recuperação de estado (queda de app/internet)

Não crie nada novo. Use o fluxo de sessão que já existe: **reconcilie uma única vez**
no login, ao voltar para foreground ou ao reconectar (`reconcile_operator_state`), que
respeita `call_active`. Se um `call_active` ficar "preso", esse mesmo fluxo corrige —
sem loops nem histórico repetido.

## Erros possíveis (`success:false`, `error.code`)

`INVALID_EVENT`, `EVENT_ID_REQUIRED`, `INVALID_CREDENTIALS`, `SESSION_NOT_FOUND`,
`SESSION_NOT_ACTIVE`. Trate mostrando a tela adequada (ex.: sessão inativa → reautenticar).
