# Correcao do App do Operador - retorno de ociosidade e novos desafios

## Incidente confirmado em producao

Operadora: `KAROLINE KARLA GONCALVES DE MOURA`

- `operator_id`: `292eb1ec-bd58-41f7-b1f3-644af134f019`
- periodo auditado: 28/07/2026 00:00 BRT ate 03/08/2026
- versao observada do App: `2.0.10`
- 36,07 horas de sessao
- 14 desafios recebidos
- 5 desafios respondidos, todos corretos
- 9 desafios expirados
- 8 entradas reais em ociosidade por `challenge_expired`
- somente 4 retornos confirmados por `challenge_idle_return`
- 18,71 horas mantidas em estado `idle`

Comparacao no mesmo periodo e na mesma versao do App:

- Ian: 75,26 horas de sessao, 86 recebidos, 46 respondidos e 29 retornos de ociosidade.
- Karoline: 36,07 horas de sessao, 14 recebidos, 5 respondidos e 4 retornos de ociosidade.

O backend deixa de agendar novos desafios enquanto o estado operacional continua
`idle`. A baixa quantidade da Karoline nao e perda do Analytics: o App deixou de
confirmar o retorno em metade das entradas de ociosidade.

## Contrato que o App deve cumprir

1. Ao receber `next_screen = "idle"` ou `operator_state.status = "idle"`, mostrar
   a tela bloqueante `OPERADOR OCIOSO`.
2. No botao explicito de retorno, chamar uma unica vez:

   ```ts
   await supabase.rpc("operator_challenge_resume_idle", {
     p_session_id: sessionId,
   });
   ```

3. Aguardar sucesso antes de remover a tela ociosa.
4. Depois do sucesso, consultar novamente `operator_challenge_state` ou
   `reconcile_operator_state` e renderizar o estado retornado pelo backend.
5. Em foreground, reconexao e retorno de uma ligacao, consultar novamente o
   estado. Se ele ainda for `idle`, reabrir a tela bloqueante.
6. Se uma ligacao comecar durante ociosidade, o App pode mostrar a chamada, mas
   ao terminar deve voltar para a tela ociosa ate existir a confirmacao explicita
   de retorno.
7. Nunca responder, reabrir ou reutilizar o desafio que expirou. O retorno apenas
   encerra a ociosidade; um desafio posterior deve ser uma nova entrega.
8. No logout, chamar `end_operator_session` uma vez. O backend publicado em
   03/08/2026 ja limpa `call_active` de sessoes encerradas.

## Pontos de implementacao

- Nao usar somente estado local, timer local ou cache para decidir se o operador
  saiu de ociosidade.
- Nao esconder a tela antes da resposta bem-sucedida de
  `operator_challenge_resume_idle`.
- Bloquear cliques repetidos enquanto a RPC estiver em andamento.
- Em erro de rede, manter a tela ociosa e permitir nova tentativa explicita.
- Ao restaurar o App, descartar estado visual antigo e consultar o backend.

## Criterios de aceite

1. Expirar um desafio e confirmar que o backend retorna `idle`.
2. Iniciar e terminar uma ligacao durante `idle`; a tela ociosa deve reaparecer.
3. Pressionar retorno uma vez e confirmar um unico `challenge_idle_return`.
4. Confirmar que o estado seguinte nao e `idle` e que novos desafios voltam a
   ser agendados.
5. Fechar/reabrir ou colocar o App em background durante `idle`; ao voltar, a
   tela ociosa deve continuar visivel.
6. Deslogar durante uma ligacao e entrar novamente; a nova sessao nao pode herdar
   `call_active` nem iniciar em `in_call`.
