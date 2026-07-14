# Prompt para o Dev do App — Nome de exibição, prazo e transparência

## Contexto publicado

O Admin e o Supabase já estão em produção. O App continua usando a RPC existente para pedir a troca e agora possui uma RPC de consulta do próprio Operador para mostrar o prazo de 15 dias e o resultado da análise administrativa.

Migrations relevantes já aplicadas:

- `20260714175906_operator_display_name_moderation`
- `20260714181051_operator_display_name_contract_hardening`
- `20260714185815_admin_display_name_override`
- `20260714190743_operator_display_name_status`

Não criar tabelas, não acessar tabelas diretamente, não usar Realtime nem polling para este recurso. O servidor identifica o Operador exclusivamente por `auth.uid()`.

## RPCs oficiais

### Solicitar alteração

```text
update_my_operator_display_name(p_display_name text)
```

Não enviar `operator_id`, `auth_user_id`, condomínio, resultado de moderação ou qualquer identidade de Admin.

No sucesso, usar somente `data.display_name` para atualizar o cabeçalho e o estado local:

```json
{
  "success": true,
  "server_now": "ISO-8601",
  "data": {
    "display_name": "Nome normalizado",
    "changed": true,
    "moderation_status": "allowed",
    "next_change_at": "ISO-8601"
  },
  "error": null
}
```

Quando `changed` for `false`, não mostrar erro: o nome informado já é equivalente ao atual.

### Consultar prazo e decisão administrativa

```text
get_my_operator_display_name_status()
```

Chamar esta RPC:

1. Ao abrir a tela/modal de alteração de nome.
2. Ao App voltar para primeiro plano, se a tela de nome estiver aberta.
3. Logo após `update_my_operator_display_name`, tanto no sucesso quanto em erro conhecido.

Não fazer polling. Esta consulta devolve apenas o estado do próprio Operador autenticado:

```json
{
  "success": true,
  "server_now": "2026-07-14T15:00:00.000Z",
  "data": {
    "display_name": "Kadu",
    "next_change_at": "2026-07-29T15:00:00.000Z",
    "can_change_now": false,
    "review": {
      "request_id": "uuid",
      "requested_name": "Nome solicitado pelo Operador",
      "status": "pending | approved | rejected",
      "reviewed_at": "ISO-8601 ou null",
      "message": "Mensagem oficial do servidor",
      "reason": "Justificativa do Admin ou null"
    }
  },
  "error": null
}
```

`review` pode ser `null`. O servidor nunca retorna o termo de moderação que disparou o bloqueio.

## Interface esperada

Na tela de nome de exibição, montar uma área clara e discreta com:

- Nome atual.
- Campo de novo nome, desabilitado quando `can_change_now` for `false`.
- Prazo: “Nova alteração disponível em DD/MM às HH:mm”.
- Opcionalmente, uma contagem regressiva visual baseada na diferença inicial entre `server_now` e `next_change_at`; o relógio local não é fonte de verdade. Ao retornar ao App, consultar o servidor novamente.
- Um cartão de status da solicitação, quando houver `review`:
  - `pending`: “Sua solicitação está em análise.” Não mostrar motivo ou termo bloqueado.
  - `rejected`: “Sua solicitação de nome foi negada.” Mostrar `review.reason` quando vier preenchido. Não inventar nem inferir motivo.
  - `approved`: informar que a solicitação foi aprovada e usar `data.display_name` como nome atual.

O cartão de rejeição deve continuar visível ao voltar à tela de nome, não apenas no instante em que a RPC falha. Isso dá transparência quando o Admin negar uma solicitação depois.

## Erros oficiais da solicitação

| Código | Comportamento no App |
| --- | --- |
| `DISPLAY_NAME_NOT_ALLOWED` | Mostrar que o nome não pode ser usado e chamar o snapshot. Se a solicitação estiver pendente, mostrar “em análise”; nunca revelar o termo bloqueado. |
| `DISPLAY_NAME_CHANGE_COOLDOWN` | Mostrar `retry_at` devolvido pelo servidor e atualizar o snapshot. |
| `DISPLAY_NAME_RATE_LIMITED` | Mostrar `retry_at` devolvido pelo servidor, sem retentar automaticamente. |
| `DISPLAY_NAME_REQUIRED`, `DISPLAY_NAME_TOO_SHORT`, `DISPLAY_NAME_TOO_LONG` | Mostrar a validação correspondente no campo. |
| `NOT_AUTHENTICATED`, `OPERATOR_NOT_FOUND` | Tratar como falha de sessão, sem inventar estado de moderação. |

## Regras de segurança e consistência

- Não calcular 15 dias a partir da hora do dispositivo.
- Não salvar uma lista de palavras bloqueadas no App.
- Não mostrar `moderation_reason` interno ou tentar deduzir o termo bloqueado.
- Não enviar identificadores de Operador ou dados administrativos.
- Não alterar o nome cadastral: o App trabalha somente com nome de exibição.

## Testes solicitados

1. Troca permitida atualiza o cabeçalho e mostra o prazo retornado pelo servidor.
2. Durante os 15 dias, o campo fica bloqueado e exibe a data/hora de liberação.
3. Nome bloqueado mostra a mensagem segura e o status “em análise”.
4. Após o Admin rejeitar uma solicitação com justificativa, reabrir a tela de nome mostra “negada” e a justificativa retornada pelo servidor.
5. Após aprovação, a tela mostra o nome aplicado pelo servidor.
6. O App em primeiro plano atualiza o prazo/decisão ao consultar o snapshot, sem polling.
7. Nenhuma chamada envia `operator_id` ou acessa tabelas de moderação diretamente.
