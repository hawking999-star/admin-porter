# Prompt para o dev do App do Operador — Desafios

Implemente as telas de desafios consumindo exclusivamente as RPCs do Supabase. O servidor é a fonte de verdade: não sorteie desafios, não calcule punições, não valide respostas e não use o relógio local como prazo oficial.

## Contrato de resposta

As RPCs de estado dos desafios retornam um objeto plano. Para essas RPCs, aceite o formato plano e normalize-o internamente se o cliente exigir um envelope:

```ts
type ChallengeSnapshot = {
  next_screen: "player" | "challenge" | "paused_by_call" | "blocked" | "idle"
  server_now: string
  next_challenge_at?: string
  blocked_until?: string
  status_operacional?: "ativo" | "ocioso" | "em_atendimento" | "bloqueado" | "fora_do_turno" | "offline"
  operator_state?: {
    status: "active" | "idle" | "in_call" | "blocked" | "outside_shift" | "offline"
    revision: number
    effective_at: string
    call_active: boolean
  }
  challenge?: {
    log_id: string
    id: string
    title: string
    prompt: string
    kind: "multiple_choice"
    expires_at: string
    answer_definition: { alternatives: string[] }
  }
}
```

## Reconciliação

No login, retorno ao foreground e reconexão, depois da sessão estar ativa, chame:

```ts
supabase.rpc("operator_challenge_state", { p_request: { session_id } })
```

Use `next_screen` retornado:

- `player`: mantenha o player. Se houver `next_challenge_at`, apenas agende a próxima consulta; não crie um prazo de resposta.
- `challenge`: ainda não inicie o contador com esse primeiro snapshot. Confirme a exibição conforme a seção seguinte.
- `paused_by_call`: mostre a tela de pausa por ligação e não permita resposta.
- `blocked`: mostre o bloqueio até `blocked_until`.
- `idle`: mostre a tela de ociosidade sem acesso ao player.

## Exibição e contador

Ao receber `next_screen: "challenge"`, monte a tela e chame uma única vez por `log_id`:

```ts
supabase.rpc("operator_challenge_displayed", { p_log_id: challenge.log_id })
```

Substitua o snapshot anterior pelo objeto devolvido por `operator_challenge_displayed`. O backend inicia nesse momento a janela completa configurada pelo admin.

- Calcule a representação visual usando exclusivamente `server_now` e `challenge.expires_at` devolvidos por `operator_challenge_displayed`.
- Não reutilize o `expires_at` do primeiro `operator_challenge_state` depois que o `displayed` responder.
- Não chame `operator_challenge_displayed` novamente para o mesmo `log_id`; chamadas repetidas são idempotentes e não podem estender o prazo.
- Não use `Date.now()` como fonte oficial. O relógio local serve somente para animar a diferença já calculada a partir do servidor.

## Resposta

Renderize as alternativas na ordem de `challenge.answer_definition.alternatives`. Envie o índice selecionado como `A`, `B`, `C` ou `D`:

```ts
supabase.rpc("operator_challenge_answer", {
  p_log_id: challenge.log_id,
  p_answer: { value: "A" },
})
```

Renderize imediatamente o próximo estado devolvido pela RPC. Não revele a alternativa correta no App.

## Ociosidade e botão Voltar

Quando o prazo acabar, chame `operator_challenge_state`; somente o servidor decide a transição para `idle`.

O botão **Voltar** chama:

```ts
supabase.rpc("operator_challenge_resume_idle", { p_session_id: session_id })
```

Depois do sucesso, faça as duas atualizações com a mesma resposta, sem depender de sincronização de playlist ou de uma segunda reconciliação:

1. renderize `next_screen`;
2. atualize imediatamente o cabeçalho operacional com `operator_state.status` e `status_operacional`.

O retorno normal contém:

```json
{
  "next_screen": "player",
  "status_operacional": "ativo",
  "operator_state": {
    "status": "active",
    "revision": 18,
    "effective_at": "ISO-8601",
    "call_active": false
  },
  "server_now": "ISO-8601"
}
```

Se o retorno for `blocked`, `in_call` ou `outside_shift`, respeite o estado devolvido; não force `active` localmente.

## Ligações e encerramento

Mantenha a integração existente com `operator_operational_event` usando apenas `call_started` e `call_finished`.

- Durante a chamada, não mostre nem responda desafio.
- Se um desafio estiver aberto, o backend o pausa.
- Após `call_finished`, o backend aplica espera fixa de 90 segundos antes de reagendar. Não tente restaurar o desafio localmente.
- Antes de encerrar uma sessão ou fechar o App com um desafio aberto, chame `operator_challenge_session_ended(session_id)`. A punição por abandono será aplicada pelo servidor no próximo login.

## Erros

- Trate `desafio_indisponivel` chamando `operator_challenge_state` e renderizando o estado devolvido.
- Sempre finalize `loading`/`aria-busy` em `finally`.
- Nunca envie `operator_id`, condomínio, resultado, tempo restante, resposta correta ou duração de bloqueio.
