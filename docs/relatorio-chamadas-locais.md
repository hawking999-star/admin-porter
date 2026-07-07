# Integracao local de chamadas

Data: 2026-07-07.

## Decisao de arquitetura

A deteccao de chamadas fica local no Electron/helper .NET 8. O Supabase nao detecta chamada, nao acompanha audio e nao recebe atualizacao continua.

O backend recebe somente eventos discretos:

- `call_started`
- `call_finished`

Uma ligacao completa deve gerar no maximo duas operacoes aplicadas no backend: um inicio e um encerramento.

## Contrato do Electron

RPC:

```text
operator_operational_event
```

Payload minimo:

```json
{
  "event": "call_started",
  "event_id": "uuid",
  "source": "microsip",
  "occurred_at": "ISO-8601",
  "metadata": {
    "phase": "incoming"
  }
}
```

Campos opcionais aceitos:

- `request_id`
- `session_id`
- `device_id`

Eventos aceitos:

- `call_started`
- `call_finished`

## Idempotencia

O backend exige `event_id` UUID e usa `public.app_request_idempotency` com `rpc_name = 'operator_operational_event'`.

Comportamento:

- mesmo `event_id` retorna `result = duplicate`
- `call_started` quando ja existe chamada ativa retorna `result = no_change`
- `call_finished` quando nao existe chamada ativa retorna `result = no_change`
- duplicatas e `no_change` nao criam nova transicao em `operator_status_history`
- uma chamada normal cria no maximo dois eventos em `operational_events`: `call.started` e `call.ended`

## Estado operacional

`operator_states` recebeu os campos:

- `call_active`
- `call_source`
- `call_started_at`
- `call_event_id`
- `call_previous_status`

No primeiro `call_started` valido:

- `call_active = true`
- `status = 'in_call'`
- Admin passa a exibir "Em atendimento" usando o status operacional ja existente
- desafio pendente/displayed vira `paused`
- `pause_reason = 'call_active'`

No `call_finished` valido:

- `call_active = false`
- o status volta para `blocked`, `outside_shift`, `idle` ou `active`, conforme reconciliacao imediata
- desafios pausados por chamada voltam para `pending`
- `expires_at` do desafio e recalculado com `challenges.duration_seconds`
- a resposta ja contem o estado completo para o Electron decidir a proxima tela

## Resposta relevante

A resposta segue o envelope operacional existente (`success`, `server_now`, `data`, `error`, `meta`).

Campos principais em `data`:

```json
{
  "result": "applied",
  "call_active": false,
  "status_operacional": "ativo",
  "server_now": "ISO-8601",
  "blocked_until": null,
  "pending_challenge": null,
  "expires_at": null,
  "next_screen": "player",
  "operator_state": {
    "status": "active",
    "call_active": false
  }
}
```

Quando houver desafio pendente apos `call_finished`, `pending_challenge` vem preenchido e `next_screen = 'challenge'`.

## Reconcile

`reconcile_operator_state` foi ajustada para respeitar `call_active = true`.

Enquanto houver chamada ativa:

- nao sobrescreve o status para `active`
- retorna `operator_state.call_active = true`
- `playback_allowed = false`
- usa o heartbeat operacional ja existente

Nao foi criado heartbeat de chamada.

## Egress e Realtime

Verificado:

- nao foi criada Edge Function periodica
- nao foi criado polling de chamada
- nao foi criado heartbeat separado de chamada
- nao foi criada subscription especifica de chamada
- `supabase_realtime` nao publica `operator_states`, `operational_events` ou `challenge_logs`

A publicacao Realtime existente continua sem canal especifico de chamada.

## Teste consolidado

Executado em transacao com rollback no final.

Validado:

1. `call_started` altera operador para `in_call` / "Em atendimento".
2. desafio pendente vira `paused` com `pause_reason = 'call_active'`.
3. duplicata com mesmo `event_id` retorna `duplicate`.
4. novo `call_started` durante chamada ativa retorna `no_change`.
5. duplicata e `no_change` nao criam historico extra.
6. `call_finished` encerra atendimento.
7. resposta de `call_finished` ja contem reconciliacao completa.
8. desafio pausado volta para `pending` com novo `expires_at`.
9. nao ha Realtime especifico para chamada.
10. chamada completa gera no maximo dois eventos aplicados no backend.

Resultado: OK.
