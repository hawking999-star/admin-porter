# Prompt para o dev do App do Operador — Desafios

Implemente as telas de desafios consumindo exclusivamente as RPCs do Supabase. O servidor é a fonte de verdade: não sorteie desafios, não calcule punições, não valide respostas e não use o relógio local como prazo oficial.

## Chamadas

No login, retorno ao foreground e reconexão, depois da sessão estar ativa, chame:

```ts
supabase.rpc("operator_challenge_state", { p_request: { session_id } })
```

Use `next_screen` retornado:

- `player`: mantém o player. Se houver `next_challenge_at`, apenas apresente a próxima verificação; não crie timer de desafio.
- `challenge`: renderize título, enunciado e alternativas de `challenge`. Ao montar, chame `operator_challenge_displayed(log_id)` uma única vez.
- `paused_by_call`: renderize uma tela informando que o desafio está pausado durante a ligação. Não habilite resposta.
- `blocked`: renderize bloqueio até `blocked_until`.
- `idle`: renderize a tela de ociosidade sem acesso ao player. O botão “Voltar” chama `operator_challenge_resume_idle(session_id)`; o retorno pode trazer um novo desafio.

Para responder, envie somente a escolha do Operador:

```ts
supabase.rpc("operator_challenge_answer", {
  p_log_id: challenge.log_id,
  p_answer: { value: "A" },
})
```

Renderize imediatamente o próximo estado devolvido pela RPC. Não revele a alternativa correta no App.

## Ligações e encerramento

Mantenha a integração já existente com `operator_operational_event` usando apenas `call_started` e `call_finished`.

- Durante a chamada, não mostre nem responda desafio.
- Se um desafio estava aberto, o backend o pausa.
- Após `call_finished`, o backend aplica espera fixa de 90 segundos antes de reagendar. Não tente restaurar o desafio nem chamar outra RPC de reconciliação além do fluxo normal.
- Antes de encerrar uma sessão ou fechar o App com um desafio aberto, chame `operator_challenge_session_ended(session_id)`. A punição por abandono só será aplicada pelo servidor no próximo login.

## Tempo e erros

- Use `server_now` e `expires_at` devolvidos pelo backend para exibir contador apenas como representação visual.
- Quando o contador chegar ao fim, chame `operator_challenge_state`; o servidor decide se o estado mudou para `idle`.
- Trate `desafio_indisponivel` chamando `operator_challenge_state` e renderizando o estado devolvido.
- Nunca envie `operator_id`, condomínio, resultado, tempo restante ou duração de bloqueio: todos são determinados no backend.
