# Relatório para o dev do app — Dispositivos + Feedback

Data: 06/07/2026
Projeto Supabase: `porter music` (`aifadvyxsefxfcgzgqol`)

Duas mudanças no backend. A **#1 já resolve o login sem exigir nada do app**. A **#2 precisa de uma tela nova no app** (botão de enviar feedback) usando a RPC descrita abaixo.

---

## 1) Dispositivos agora são auto-aprovados (login imediato)

### Problema
No login o app mostrava **"Este dispositivo está aguardando aprovação do administrador."** Todo dispositivo novo entrava com `status = 'pending'` e ficava travado até um admin liberar manualmente.

### O que mudou (backend, já aplicado)
- **RPC `public.register_device(p_request jsonb)`**: dispositivo novo agora entra direto como `status = 'allowed'` (com `approved_at = now()`). Em reconexão, um dispositivo `pending` é **promovido** para `allowed`.
- **Edge Function `register_device`**: mesma lógica, para manter coerência.
- **Regra de segurança preservada:** se um admin marcar um dispositivo como `blocked` ou `retired`, a RPC **não** reverte — a decisão do admin é mantida.
- O dispositivo que estava pendente (o do teste de login) já foi liberado.

### O que o app precisa fazer
**Nada obrigatório.** O contrato de resposta é o mesmo. O `device.status` retornado agora vem `allowed` já na primeira chamada.

Recomendação (se ainda não faz): tratar os status de forma explícita no fluxo de login:
- `allowed` → segue para criar a sessão normalmente.
- `blocked` / `retired` → bloqueia com mensagem clara ("Dispositivo bloqueado pelo administrador").
- `pending` → não deve mais acontecer, mas se acontecer, tratar como antes.

> Observação: o `fingerprint_hash` na RPC ainda é um placeholder determinístico (`md5(device_id|platform)`). O algoritmo definitivo de fingerprint continua **pendente** — não foi alterado aqui.

---

## 2) Feedback dos operadores (nova funcionalidade)

Criei a tabela, o RLS e a RPC de envio. **A aba Feedback no admin já está pronta e funcionando** (lista, filtra por tipo/status e permite marcar Novo/Lido/Resolvido). Falta só o app enviar.

### Tabela `public.feedback`
| Coluna | Tipo | Observação |
|---|---|---|
| `id` | uuid | PK |
| `operator_id` | uuid | FK operators — preenchido pela RPC (vem do token) |
| `unit_id` | uuid | FK units — preenchido pela RPC (unidade do operador) |
| `type` | text | `suggestion` \| `problem` \| `praise` |
| `message` | text | obrigatório, até 2000 chars |
| `status` | text | `new` \| `read` \| `resolved` (default `new`) — controlado pelo admin |
| `app_version` | text | opcional |
| `created_at` | timestamptz | default now() |

RLS: admin tem acesso total (`is_admin()`); operador enxerga só os próprios envios. O **envio é feito pela RPC** abaixo (não inserir direto na tabela).

### RPC de envio: `public.submit_feedback(p_request jsonb)`
Chamar autenticado como o operador (mesmo padrão do `register_device`). O operador e a unidade são derivados do token — **o app não envia isso**.

**Payload (campos de `p_request`):**
- `message` (string, obrigatório)
- `type` (string, opcional) — aceita `suggestion|problem|praise` **ou** os equivalentes em PT: `sugestao|problema|elogio` (também `bug` → problem). Default: `suggestion`.
- `app_version` (string, opcional)
- `request_id` (string, opcional) — para idempotência/rastreio

**Exemplo com supabase-js:**
```ts
const { data, error } = await supabase.rpc("submit_feedback", {
  p_request: {
    request_id: crypto.randomUUID(),
    type: "problema",              // ou 'sugestao' / 'elogio'
    message: texto,                 // do campo de texto na tela
    app_version: APP_VERSION,
  },
});
// data é o envelope padrão (mesmo formato do register_device)
```

**Resposta (envelope padrão):**
```json
{
  "success": true,
  "request_id": "...",
  "server_now": "2026-07-06T09:30:22.099Z",
  "contract_version": 1,
  "api_version": "v1",
  "data": { "feedback": { "id": "uuid", "type": "problem", "status": "new" } },
  "error": null,
  "meta": { "submitted": true }
}
```

**Erros possíveis (`success:false`, em `error.code`):**
- `INVALID_CREDENTIALS` — sessão ausente ou operador inativo/não encontrado.
- `MESSAGE_REQUIRED` — mensagem vazia.
- `INTERNAL_ERROR` — erro inesperado (mensagem em `error.message`).

### Sugestão de UI no app (aba/ botão "Enviar feedback")
- Um seletor de tipo: **Sugestão / Problema / Elogio**.
- Um campo de texto (obrigatório).
- Botão enviar → chama `submit_feedback` → toast de sucesso e limpa o campo.

---

## 3) Login intermitente ("às vezes loga, às vezes não") — corrigido

### Causa
Na RPC `start_operator_session`, com `session_policy = 'single'`, se já existia uma sessão **ativa** e o `device_id` recebido era diferente, a função retornava `SESSION_ALREADY_ACTIVE` e **barrava** o login. Isso acontecia quando:
- o app fechava **sem chamar logout** (a sessão fica ativa por 12h, até `expires_at`); e/ou
- o `device_id` mudava entre aberturas do app.

Resultado: o operador às vezes conseguia entrar (quando a sessão anterior havia sido encerrada) e às vezes não.

### O que mudou (backend, já aplicado)
`start_operator_session` agora garante **no máximo uma sessão ativa** por operador, com "o login mais recente vence":
- Se existe sessão ativa **no mesmo dispositivo** → reaproveita e encerra as demais.
- Se não há no mesmo dispositivo → encerra **todas** as ativas (marca `revoked`, `end_reason = 'superseded_by_new_login'`) e cria a nova.
- Nunca mais retorna `SESSION_ALREADY_ACTIVE`.

Validado: cenário com sessão órfã em outro dispositivo e com duplicatas no mesmo dispositivo → sempre resulta em **1 sessão ativa** e login com sucesso.

### O que o app deveria fazer (recomendado)
1. **Persistir um `device_id` estável** (gravar um UUID no primeiro uso e reutilizar sempre). Se o app gera um novo a cada abertura, cria lixo de dispositivos/sessões (agora tolerado, mas não ideal).
2. **Chamar `end_operator_session`** ao fechar/logout do app, para encerrar a sessão na hora.

---

## 4) Turno e horário (para exibir no app)

O turno do operador agora é configurável no admin (no cadastro do operador). São 3 tipos:
- **12x36 Diurno** — 06h00–18h00 (fixo)
- **12x36 Noturno** — 18h00–06h00 (fixo)
- **6x1** — horário configurável (varia por condomínio)

### Onde o dado fica
Cada operador aponta para um turno em `operators.default_shift_id` → tabela `shifts` (`name`, `starts_at`, `ends_at`, `timezone`). O admin cuida de criar/atualizar esse registro.

### Como o app recebe (já pronto no backend)
Não precisa consultar a tabela direto. O turno já vem nas respostas das RPCs, no campo `data.shift`:

- **`start_operator_session`** (no login) → agora inclui:
  ```json
  "shift": { "id": "...", "name": "6x1", "ends_at": "2026-07-06T19:00:00+00:00", "in_shift": true }
  ```
- **`reconcile_operator_state`** (no heartbeat) → já incluía:
  ```json
  "shift": { "id": "...", "name": "12x36 Noturno", "ends_at": "..." }
  ```

Campos:
- `name` → nome do turno para exibir (ex.: "12x36 Diurno", "6x1").
- `ends_at` → timestamp (UTC, com timezone) de quando o turno termina; use para mostrar o horário / contagem.
- `in_shift` → se o horário atual está dentro do turno (no `start_operator_session`).
- `data.shift` é `null` quando o operador não tem turno definido.

> Observação: para exibir o horário de início/fim "cru" (ex.: 06:00–18:00), dá para derivar de `shifts.starts_at`/`ends_at`; se o app precisar desses campos diretamente na resposta, dá pra incluir também — só pedir.

---

## Status de validação
- ✅ Login liberado (dispositivo aprovado; auto-aprovação na RPC e na Edge Function).
- ✅ Login intermitente corrigido (take-over de sessão; sempre 1 sessão ativa) — testado.
- ✅ RPC `submit_feedback` testada ponta a ponta (inclui normalização PT → EN).
- ✅ Aba Feedback do admin lendo os dados com operador + condomínio.
- ✅ Turno configurável no admin; `start_operator_session` e `reconcile_operator_state` retornam `data.shift`.
- ⏳ Falta no app: (a) botão de enviar feedback (RPC `submit_feedback`); (b) exibir turno/horário via `data.shift`; (c) `device_id` estável + `end_operator_session` no fechamento.
