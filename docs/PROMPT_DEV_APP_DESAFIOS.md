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

## Correção obrigatória: `P0001 / sessao_invalida`

O App só pode chamar `operator_challenge_state` com o `session_id` devolvido pela **sessão operacional ativa** em `start_operator_session`. Nunca reutilize um id persistido de um login anterior, nem o id da sessão de autenticação do Supabase.

Antes da primeira reconciliação de um novo login, salve o id devolvido por `start_operator_session` como `activeSessionId` e associe todos os timers a uma geração/epoch dessa sessão. Uma Promise, timer ou polling da geração anterior não pode usar o id novo nem renderizar depois da troca.

Ao iniciar logout, clicar em **Sair**, encerrar a sessão ou desmontar o App, siga esta ordem:

1. invalide a geração da sessão;
2. cancele despertador, polling e requisições futuras de desafios;
3. limpe `activeSessionId` do controlador local;
4. chame `end_operator_session` uma única vez para o id que estava ativo;
5. não faça nenhuma nova chamada de `operator_challenge_state` para esse id.

Se `operator_challenge_state` responder HTTP 400 com `code: "P0001"` e `message: "sessao_invalida"`, não faça retry automático e não mostre a tela genérica “Não foi possível verificar”. Cancele os timers, descarte o estado de desafio e volte o App ao fluxo de login/sessão encerrada. Se isso ocorrer durante o login, confira se a primeira consulta recebeu o id recém-devolvido por `start_operator_session` antes de ser chamada.

Esse erro é uma proteção do servidor: a sessão já foi encerrada, revogada, expirou ou pertence a outro Operador. O App não deve tentar adivinhar nem recriar localmente uma sessão.

## Despertador enquanto o player está aberto

Receber `next_screen: "player"` não encerra o fluxo. Enquanto existir uma sessão ativa e não houver ligação, bloqueio, desafio ou ociosidade, o App deve continuar reconciliando desafios sem exigir logout/login.

Quando o snapshot tiver `next_challenge_at`:

1. calcule somente o atraso até a próxima consulta usando a diferença entre `next_challenge_at` e `server_now`;
2. agende uma chamada única de `operator_challenge_state` para esse atraso, acrescentando no máximo 250 ms de tolerância;
3. quando o despertador disparar, consulte o servidor e renderize o novo `next_screen`;
4. nunca abra o desafio apenas porque o horário local chegou: a nova RPC é obrigatória e o servidor continua decidindo o estado.

Além do despertador exato, mantenha uma reconciliação de segurança a cada 10 segundos enquanto `next_screen === "player"`. Ela cobre suspensão do Windows, atraso de timer do Electron e perda momentânea de conexão.

Regras de concorrência:

- tenha no máximo uma chamada de `operator_challenge_state` em andamento;
- cancele o despertador anterior ao receber qualquer snapshot novo;
- cancele despertador e polling em logout, sessão encerrada, `call_started`, `blocked`, `idle` ou `challenge`;
- ao receber `call_finished`, use primeiro a resposta oficial da ligação e depois reagende conforme o `next_challenge_at` devolvido pelo fluxo normal;
- em `online`, retorno do Windows e retorno ao foreground, consulte imediatamente e reprograme o despertador;
- limpe todos os timers ao desmontar ou trocar a sessão.

Exemplo de lógica, adaptando aos módulos existentes do App:

```ts
let wakeTimer: ReturnType<typeof setTimeout> | null = null
let safetyTimer: ReturnType<typeof setInterval> | null = null
let stateRequestInFlight = false

function scheduleChallengeCheck(snapshot: ChallengeSnapshot) {
  clearChallengeTimers()
  if (snapshot.next_screen !== "player") return

  if (snapshot.next_challenge_at) {
    const delay = Math.max(
      0,
      Date.parse(snapshot.next_challenge_at) - Date.parse(snapshot.server_now),
    )
    wakeTimer = setTimeout(() => void refreshChallengeState("scheduled_due"), delay + 250)
  }

  safetyTimer = setInterval(
    () => void refreshChallengeState("player_safety_poll"),
    10_000,
  )
}

async function refreshChallengeState(reason: string) {
  if (stateRequestInFlight || !activeSessionId) return
  stateRequestInFlight = true
  try {
    const snapshot = await getOfficialChallengeState(activeSessionId)
    renderOfficialSnapshot(snapshot)
    scheduleChallengeCheck(snapshot)
  } finally {
    stateRequestInFlight = false
  }
}
```

Não crie `setInterval` duplicado a cada renderização. O agendador precisa pertencer ao controlador da sessão, e não a uma renderização isolada da tela do player.

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

Renderize as alternativas na ordem de `challenge.answer_definition.alternatives`. Envie apenas o `option_id` selecionado para a RPC versionada:

```ts
supabase.rpc("operator_challenge_answer_v2", {
  p_log_id: challenge.log_id,
  p_answer: { option_id: "option_a" },
})
```

Após a resposta aceita, exiba o feedback educacional retornado pelo backend antes de seguir para `next_snapshot`:

```ts
type ChallengeAnswerResponse = {
  schema_version: 2
  answer_feedback: {
    result: "correct" | "incorrect"
    is_correct: boolean
    selected_option_id: string
    correct_option_id: string
    correct_option_text: string
    answered_at: string
  }
  next_snapshot: ChallengeSnapshot
}
```

- Mostre se a resposta está correta por `answer_feedback.is_correct`.
- Mostre a alternativa correta em `answer_feedback.correct_option_text`, inclusive quando o Operador errar.
- Use exclusivamente o feedback devolvido pela RPC; o App não calcula correção localmente nem consulta tabelas diretamente.
- Não envie `is_correct`, `result`, `correct_option_id` ou qualquer campo de feedback no payload: o cliente envia somente `{ option_id }`.
- Em repetição por falha de rede, reenvie o mesmo `p_log_id` e o mesmo `option_id`; a RPC devolve o mesmo feedback sem reaplicar a punição.

Depois que o feedback for exibido conforme a experiência atual do App, renderize `next_snapshot` devolvido pela RPC.

## Ociosidade e botão Voltar

Quando o prazo acabar, chame `operator_challenge_state`; somente o servidor decide a transição para `idle`.

O botão **Voltar** chama:

```ts
supabase.rpc("operator_challenge_resume_idle", { p_session_id: session_id })
```

Essa RPC deve ser chamada **somente por um clique humano no botão Voltar**. Não a chame em renderização, `setInterval`, polling, reconexão, retorno ao foreground ou como efeito automático de `next_screen: "idle"`.

Quando o Operador estiver apto a trabalhar, o backend encerra a ocorrência perdida e devolve imediatamente **outro desafio**. O App não deve tentar escolher ou sortear o substituto localmente; apenas renderize o snapshot retornado.

- ao entrar em `idle`, cancele imediatamente o despertador e o polling de desafios;
- desabilite o botão Voltar enquanto a única chamada estiver em andamento;
- aceite no máximo uma chamada de `operator_challenge_resume_idle` por clique;
- chamadas repetidas não podem iniciar um loop de `idle -> active -> idle`;
- depois do primeiro sucesso, substitua a tela pelo snapshot devolvido antes de reabilitar qualquer agendador.

Ao trocar de sessão ou fazer logout, invalide também toda Promise antiga. Uma resposta iniciada pela sessão anterior não pode renderizar, confirmar exibição, responder ou retomar um desafio na sessão nova. O backend rejeita sessão encerrada com `sessao_invalida`; trate isso descartando a resposta antiga, sem tentar novamente.

Depois do sucesso, faça as duas atualizações com a mesma resposta, sem depender de sincronização de playlist ou de uma segunda reconciliação:

1. renderize `next_screen`;
2. atualize imediatamente o cabeçalho operacional com `operator_state.status` e `status_operacional`.

O retorno normal contém:

```json
{
  "next_screen": "challenge",
  "status_operacional": "ativo",
  "challenge": {
    "id": "UUID-DIFERENTE-DO-DESAFIO-PERDIDO",
    "log_id": "UUID-DA-NOVA-OCORRENCIA",
    "status": "pending"
  },
  "operator_state": {
    "status": "active",
    "revision": 18,
    "effective_at": "ISO-8601",
    "call_active": false
  },
  "server_now": "ISO-8601"
}
```

Depois de renderizar a nova tela, chame `operator_challenge_displayed` uma única vez para o novo `log_id`, seguindo o mesmo fluxo de exibição já descrito acima. Um clique repetido em **Voltar** pode devolver a mesma ocorrência aberta e não deve gerar outra tela nem outra confirmação duplicada.

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

## Testes obrigatórios do agendador

- Com o App já aberto no player, receba um snapshot com `next_challenge_at` entre 60 e 120 segundos no futuro e confirme nova chamada de `operator_challenge_state` sem relogar.
- Confirme que o desafio aparece quando a RPC muda para `next_screen: "challenge"`.
- Simule suspensão/atraso do timer e confirme que o polling de segurança recupera o desafio em até 10 segundos.
- Confirme que duas renderizações do player não criam dois pollings nem duas chamadas simultâneas.
- Entregue o log com motivo `scheduled_due` ou `player_safety_poll`, horário da chamada e `next_screen` recebido.
