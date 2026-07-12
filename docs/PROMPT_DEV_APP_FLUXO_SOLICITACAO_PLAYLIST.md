# Prompt para o dev do App do Operador - envio de playlist sem duplicidade

Audite e corrija o fluxo de envio de Playlist Principal no App do Operador. Nao crie mocks e nao consulte tabelas diretamente. Preserve login, rotas, player, layout e demais funcionalidades existentes.

## Contrato oficial

- Envio: RPC `public.manage_operator_playlist(p_request jsonb)` com `operation: "submit"`.
- Historico: RPC `public.get_my_playlist_requests(p_request jsonb)`.
- Use `request_id` UUID novo por chamada para correlacao.
- Gere um `idempotency_key` UUID uma unica vez por intencao de envio.
- Se houver timeout/retry da mesma intencao, reutilize exatamente o mesmo `idempotency_key` e o mesmo payload. Nao gere uma chave nova no retry.

## Comportamento obrigatorio da interface

1. Nao chamar submit em `useEffect`, montagem, reabertura do modal, refresh ou polling.
2. O submit so pode ocorrer por clique explicito do Operador.
3. Ao clicar, bloquear imediatamente o botao e impedir duplo clique enquanto a Promise estiver pendente.
4. Aguardar a resposta da RPC antes de limpar o formulario ou fechar o modal.
5. Em sucesso, recarregar `get_my_playlist_requests` uma unica vez. Nao criar item local falso.
6. Em erro, manter o link digitado e exibir a mensagem correspondente.
7. Nao reenviar automaticamente com outro `idempotency_key`.

## Erros que o App precisa mapear

- `PLAYLIST_REQUEST_ALREADY_PENDING`: "Ja existe uma playlist aguardando aprovacao. Aguarde a decisao do Admin."
- `PLAYLIST_IMPORT_IN_PROGRESS`: "Sua playlist aprovada ainda esta sendo importada. Aguarde a conclusao antes de enviar outra."
- `IDEMPOTENCY_KEY_REUSED`: "Este envio mudou durante uma tentativa. Atualize a tela e tente novamente."
- `PLAYLIST_REVISION_CONFLICT`: recarregar playlists e pedir nova confirmacao do Operador.
- `URL_NOT_A_PLAYLIST`: informar que o link precisa conter uma playlist valida do YouTube.

## Historico

- Renderizar apenas `data.requests` retornado por `get_my_playlist_requests`.
- Status: `pending` = "Aguardando aprovacao", `approved` = "Aprovada", `rejected` = "Rejeitada".
- Quando `rejection_reason` for "Solicitacao substituida por um novo envio.", mostrar "Substituida por outro envio" em vez de sugerir rejeicao manual do Admin.
- Ordenar pelo `created_at` devolvido pelo backend; nao ordenar por horario local inventado.

## Validacao exigida

- Um clique cria uma solicitacao.
- Clique duplo cria uma solicitacao.
- Retry de rede reutiliza a mesma chave e nao cria outra linha.
- Novo envio com solicitacao pendente mostra `PLAYLIST_REQUEST_ALREADY_PENDING`.
- Novo envio durante importacao mostra `PLAYLIST_IMPORT_IN_PROGRESS`.
- Reabrir o modal ou atualizar o historico nao chama submit.
- Informar arquivos alterados e resultados dos testes.
