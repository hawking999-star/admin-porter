# Prompt para o Dev do App — Nome de exibição moderado

## Backend publicado e validado

- Migrations aplicadas no Supabase de produção: `20260714175906_operator_display_name_moderation` e `20260714181051_operator_display_name_contract_hardening`.
- A causa original SQLSTATE `42883` foi corrigida; não há mais chamadas inválidas a `pg_catalog.coalesce/nullif`.
- A RPC abaixo foi validada com teste SQL transacional e rollback.
- `anon` não pode executar a RPC. `authenticated` pode executá-la, e o Operador é resolvido exclusivamente por `auth.uid()`.
- As tabelas de termos e solicitações não têm acesso direto para `anon` ou `authenticated`; toda operação passa pelas RPCs oficiais.

O App não precisa de migration, tabela, Realtime ou configuração adicional no Supabase. A única alteração necessária no App é tratar os envelopes reais documentados abaixo.

O backend oficial continua usando a RPC já integrada:

```text
update_my_operator_display_name(p_display_name text)
```

Não envie `operator_id`, `auth_user_id`, unidade, resultado de moderação ou identidade de Admin. O servidor identifica o Operador exclusivamente por `auth.uid()`.

## Resposta de sucesso

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

Quando o nome enviado for equivalente ao atual sem considerar caixa, acentos ou pontuação simples, `changed` será `false`, nenhuma nova auditoria será criada e `next_change_at` poderá ser `null`.

Após sucesso com `changed: true`, atualize imediatamente o nome no cabeçalho e no estado local usando somente `data.display_name`.

## Erros conhecidos

### Nome não permitido

```json
{
  "success": false,
  "server_now": "ISO-8601",
  "data": null,
  "error": {
    "code": "DISPLAY_NAME_NOT_ALLOWED",
    "message": "Esse nome de exibicao nao pode ser utilizado.",
    "retryable": false
  }
}
```

Mostre a mensagem sem revelar ou tentar descobrir qual termo foi detectado. A lista de moderação nunca deve existir no App.

### Prazo de 15 dias

```json
{
  "success": false,
  "server_now": "ISO-8601",
  "data": null,
  "error": {
    "code": "DISPLAY_NAME_CHANGE_COOLDOWN",
    "message": "O nome de exibicao so pode ser alterado uma vez a cada 15 dias.",
    "retryable": true,
    "retry_at": "ISO-8601"
  }
}
```

Use `server_now` e `retry_at`; não calcule o prazo com o relógio local.

### Excesso de tentativas

```json
{
  "success": false,
  "server_now": "ISO-8601",
  "data": null,
  "error": {
    "code": "DISPLAY_NAME_RATE_LIMITED",
    "message": "Muitas tentativas. Aguarde alguns minutos para tentar novamente.",
    "retryable": true,
    "retry_at": "ISO-8601"
  }
}
```

O limite é de cinco tentativas diferentes em dez minutos.

## Validações preservadas

- `DISPLAY_NAME_REQUIRED`
- `DISPLAY_NAME_TOO_SHORT`
- `DISPLAY_NAME_TOO_LONG`
- `NOT_AUTHENTICATED`
- `OPERATOR_NOT_FOUND`

O nome deve ter de 3 a 50 caracteres. Espaços no começo e no fim são removidos e espaços repetidos são reduzidos para um.

## Regras que pertencem somente ao backend

- Uma troca aplicada a cada 15 dias.
- Moderação sem diferença entre maiúsculas, minúsculas e acentos.
- Detecção por palavra, nome exato ou tentativa ofuscada.
- Registro de tentativas permitidas, bloqueadas e limitadas.
- Aprovação administrativa como exceção única.
- Nome cadastral separado e impossível de alterar pelo App.

Não criar polling, heartbeat, acesso direto às tabelas ou lógica paralela de moderação.

## Testes solicitados ao App

1. Salvar um nome permitido e atualizar o cabeçalho imediatamente.
2. Salvar o mesmo nome e aceitar `changed: false`.
3. Exibir corretamente cada validação conhecida.
4. Exibir o bloqueio de moderação sem erro genérico.
5. Exibir a data de nova troca usando `retry_at`.
6. Tratar o limite de tentativas sem repetir chamadas automaticamente.
7. Confirmar que nenhum identificador de Operador é enviado à RPC.
