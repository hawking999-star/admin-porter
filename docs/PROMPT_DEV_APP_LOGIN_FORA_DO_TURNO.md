# Prompt para o dev do App — login fora do turno

Corrija o App do Operador para tratar `outside_shift` como um estado operacional
válido de uma sessão autenticada, nunca como erro de login ou erro de
verificação.

## Incidente real

Na versão `2.0.10`, a Operadora Erica iniciou uma sessão fora do turno. O
Supabase respondeu `200` em `operator_challenge_state` com:

```json
{
  "next_screen": "outside_shift",
  "operator_state": {
    "status": "outside_shift"
  },
  "status_operacional": "fora_do_turno"
}
```

O App lançou localmente:

```text
code: LOCAL_CHALLENGE_FLOW_ERROR
message: Estado de desafio inválido
next_screen recebido: outside_shift
```

Esse comportamento está errado. A regra do produto é:

- o Operador pode autenticar e iniciar uma sessão antes, depois ou fora do turno;
- o player e o restante do App continuam disponíveis;
- o cabeçalho pode mostrar `Fora do turno`;
- nenhum desafio pode ser agendado, exibido ou respondido fora do turno;
- quando o turno começar, o fluxo normal de desafios volta automaticamente,
  sem exigir logout ou novo login.

## Contrato vigente do backend

O hotfix de compatibilidade faz os snapshots fora do turno retornarem:

```json
{
  "next_screen": "player",
  "outside_shift": true,
  "challenge_mode": "disabled",
  "operator_state": {
    "status": "outside_shift"
  },
  "status_operacional": "fora_do_turno",
  "challenge": null
}
```

Mesmo assim, mantenha compatibilidade defensiva com versões anteriores do
backend: se `next_screen === "outside_shift"`, normalize internamente para a
mesma tela do `player`, sem lançar exceção.

## Implementação obrigatória

1. Inclua `outside_shift` no tipo aceito de `next_screen`.
2. Nunca gere `LOCAL_CHALLENGE_FLOW_ERROR` para `outside_shift`.
3. Renderize o player quando:
   - `next_screen === "player"` e
     `operator_state.status === "outside_shift"`; ou
   - `next_screen === "outside_shift"` por compatibilidade.
4. Preserve o status visual `Fora do turno`.
5. Não encerre `operator_sessions`, não limpe a autenticação e não redirecione
   ao login por causa de `outside_shift`.
6. Não crie desafio, contador, bloqueio ou ociosidade localmente.
7. Continue consultando `operator_challenge_state` com a sessão ativa. O
   servidor decide quando o turno começou e quando desafios podem voltar.
8. Ao receber `challenge_mode === "disabled"` ou
   `operator_state.status === "outside_shift"`:
   - descarte qualquer desafio local obsoleto;
   - cancele contador e despertador de desafio;
   - mantenha somente a reconciliação de segurança.
9. Não use o relógio do Windows para decidir se está dentro do turno.
10. Após `call_finished`, foreground, reconexão ou mudança de turno, respeite o
    snapshot mais recente do servidor sem forçar `active` localmente.

Exemplo de normalização:

```ts
function normalizeChallengeScreen(snapshot: ChallengeSnapshot) {
  const outsideShift =
    snapshot.next_screen === "outside_shift" ||
    snapshot.outside_shift === true ||
    snapshot.operator_state?.status === "outside_shift"

  if (outsideShift) {
    return {
      ...snapshot,
      next_screen: "player" as const,
      outside_shift: true,
      challenge_mode: "disabled" as const,
      challenge: undefined,
    }
  }

  return snapshot
}
```

## Aceite obrigatório

Teste com sessão real e registre evidência:

1. Login antes do início do turno:
   - entra normalmente;
   - abre o player;
   - mostra `Fora do turno`;
   - não mostra erro;
   - não cria desafio.
2. Permanecer logado até o turno começar:
   - não exige novo login;
   - muda pelo snapshot do servidor;
   - desafios voltam somente depois de `in_shift=true`.
3. Login depois do fim do turno:
   - mesmo comportamento do item 1.
4. `call_started` e `call_finished` fora do turno:
   - não mudam o estado para `active`;
   - não liberam desafio.
5. Reabrir o App, voltar ao foreground e perder/reconectar a internet:
   - preserva a sessão;
   - não mostra `Não foi possível verificar`;
   - não duplica polling.
6. Resposta legada `next_screen: "outside_shift"`:
   - é aceita e normalizada;
   - nunca lança `LOCAL_CHALLENGE_FLOW_ERROR`.

Entregue:

- arquivos alterados;
- testes automatizados;
- build da versão corrigida;
- log do snapshot recebido e da tela escolhida;
- evidência de uma sessão fora do turno sem desafio aberto.
