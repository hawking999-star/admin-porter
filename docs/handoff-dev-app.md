# Handoff PTM Admin → Dev do App (alinhamento geral)

**Projeto Supabase:** `aifadvyxsefxfcgzgqol` (porter music) — banco novo, limpo.
**Admin:** SPA React nova, substitui o admin antigo (inchado, ligado ao banco antigo).
**Data:** 2026-07-05.

Princípio de trabalho: o **admin gerencia os dados**; o **app consome via RPCs/snapshot** (não lê
tabela direto). Cada aba do admin tem um relatório próprio; este documento junta tudo o que toca o app.

---

## 1. Modelo de dados novo (só o que interessa ao app)

Nomes mudaram em relação ao banco antigo:

| Antigo | Novo | Observação |
|---|---|---|
| `users` | `operators` | porteiros; login em `auth_user_id` |
| `condominiums` / `condominium_settings` / `configuracoes` | `units` (+ `system_settings`) | condomínio |
| `musicas` | `tracks` | — |
| `sessions` | `operator_sessions` | — |
| `challenges` (formato duplo) | `challenges` (formato único) | limpo |
| `audit_logs` | `admin_audit_logs` | — |

Tabelas-chave para o app:

- **`operators`**: `unit_id` (unidade do porteiro), `employee_code`, `display_name`, `role`
  (`operador`/`supervisor`), `session_policy` (`single`/`multi`), `active`, `auth_user_id`.
- **`units`**: `id`, `code`, `name`, `timezone`, `active` (+ `address`, `city`, `state` novos).

---

## 2. Contrato do snapshot — `unit`  ✅ APLICADO (2026-07-05)

Conforme pedido do dev, o `start_operator_session` agora **retorna o objeto `unit`** e **bloqueia
unidade inativa**.

**Onde o app lê:** dentro do envelope padrão, em **`data.unit`**. Formato do envelope:

```json
{
  "success": true,
  "request_id": "...",
  "server_now": "2026-07-05T12:00:00.000Z",
  "contract_version": 1,
  "api_version": "v1",
  "data": {
    "session": { "id": "uuid", "status": "active" },
    "unit": {
      "id": "uuid",
      "code": "PORTER-001",
      "name": "Condomínio",
      "timezone": "America/Sao_Paulo",
      "active": true
    }
  },
  "error": null,
  "meta": null
}
```

- O `unit` vem tanto na sessão nova quanto na sessão reaproveitada (`meta.reused = true`).
- **Novo erro `UNIT_NOT_ACTIVE`**: se `units.active = false`, o `start_operator_session` recusa a
  sessão com `{ "error": { "code": "UNIT_NOT_ACTIVE", "message": "Condominio inativo ou nao encontrado." } }`.

**Alinhamento confirmado (do dev):**
- `operators.unit_id` define a unidade do porteiro. ✔
- `unit.code` usado em logs/telemetria. ✔
- `unit.timezone` para horários civis; a contagem por `server_now` + `shift.ends_at` absoluto
  independe de fuso. ✔ (nada muda nessa lógica)
- Sem migração de tabela no app: ele passa a consumir `unit` do snapshot. ✔

**`reconcile_operator_state` também retorna `data.unit`** ✅ APLICADO (2026-07-05) — mesmo formato.
Confirmado pelo dev: o app descarta o snapshot do `start` e usa o do `reconcile`, então o `unit`
oficial vem por aqui. (O `reconcile` inclui o `unit.active`; a decisão de encerrar sessão quando a
unidade fica inativa no meio do plantão fica com o app.)

---

## 3. `register_device` — ✅ APLICADO (2026-07-05)

RPC `public.register_device(p_request jsonb)` criada conforme o payload do dev:

```json
{ "request_id": "uuid", "device_id": "uuid persistente da instalação",
  "label": null, "platform": "win32-x64", "app_version": "1.0.0",
  "channel": "stable", "contract_version": 1 }
```

Comportamento:
- `operator_id` e `unit_id` derivados de `auth.uid()` → `operators`. **`unit_id` do app é ignorado.**
- `fingerprint_hash` **gerado internamente** (hash determinístico de `device_id`+`platform`; o algoritmo
  final de fingerprint continua PENDENTE — trocar aqui quando definirem).
- Insere em `public.devices` com `status = 'pending'` (aprovação pelo admin). `platform`/`app_version`/
  `channel`/`contract_version` vão em `metadata`.
- Upsert por `device_id` (=`devices.id`): rechamar só atualiza `last_seen_at`/`metadata`, **não rebaixa**
  um device já `allowed`.
- Retorno: `data.device = { id, status }`.

> Como `devices.id` = o `device_id` persistente do app, o `start_operator_session` continua achando o
> device por esse mesmo id.

---

## 4. Login de porteiro / acesso ao admin — ⏳ PRECISA EDGE FUNCTION

O admin roda com a **chave pública (anon)**, que **não cria usuários de login** (isso exige
`service_role`, que nunca vai pro navegador). Então:

- **Porteiro:** o admin cria o cadastro em `operators`, mas o login do app (registro em `auth.users`
  + preencher `operators.auth_user_id`) precisa de uma **Edge Function** com service_role
  (`create-operator-login`).
- **Acesso ao admin:** `admin_users.auth_user_id` é **NOT NULL** → criar acesso novo passa pelo mesmo caminho.

Confirmado pelo dev: **oficializar a Edge Function `create-operator-login`** (provisionamento pelo
admin). O app já autentica direto por e-mail/senha no Supabase Auth; a função é só para o admin criar
o login. O processo manual (Authentication → Add user + vincular `auth_user_id`) fica como
**contingência temporária**. Provisionamento de `admin_users` só por `superadmin`.

Status: **⏳ a construir** — próximo passo. Preciso só decidir o fluxo: senha temporária definida no
admin, ou convite por e-mail.

---

## 5. Segurança (RLS) e auditoria — ✅ FEITO / ATUALIZADO (2026-07-05)

Regras por papel (conforme dev / doc 04):

- **`admin_users`**: leitura por qualquer admin; **criar/alterar/ativar/desativar só `superadmin`**.
- **`operators`**: leitura por admin; criar/editar por `superadmin` ou gestor (`unit_manager`/
  `operations_manager`) **dentro do próprio `unit_scope`**; excluir só `superadmin`.
- **`units`**: gerenciado por admin (`is_admin()`).
- Helpers: `is_admin()`, `is_superadmin()`, `admin_can_manage_operator_unit(unit)`.

**Auditoria:** gatilhos em `admin_users`, `operators` e `units` gravam toda mudança em
`admin_audit_logs` (ação, entidade, `before_data`/`after_data`, admin responsável).

- **Não afeta o app:** as RPCs do app são `SECURITY DEFINER` e continuam funcionando normalmente.

---

## 5b. Contrato v1 de login/RPCs — conferido (doc 12)  ✅

- **`start_operator_session`**, **`reconcile_operator_state`**, **`end_operator_session`**: retornos
  seguem o envelope padrão e os campos consumidos pelo app. `end` é idempotente (retorna sucesso mesmo
  se a sessão já foi encerrada pela mesma operação).
- **`shift.ends_at` é `timestamptz` absoluto** — resolvido para a ocorrência do turno no fuso do turno,
  tratando virada de meia-noite. O app ancora em `server_now`.
- **`unit`** vai no `data` do `start` e do `reconcile` (extra, além do mínimo do doc 12).
- **Grants travados:** as 4 RPCs (`start`, `reconcile`, `end`, `register_device`) têm `execute` só para
  `authenticated`; `anon` e `public` revogados. Todas são `security definer` com `search_path` fixo e
  derivam o operador de `auth.uid()`.
- **Códigos de erro presentes:** `INVALID_CREDENTIALS`, `UNIT_NOT_ACTIVE`, `DEVICE_NOT_ALLOWED`,
  `SESSION_ALREADY_ACTIVE`, `APP_VERSION_NOT_ALLOWED`, `OPERATOR_BLOCKED`, `SESSION_REVOKED`,
  `SESSION_EXPIRED`. `outside_shift` é **estado** (não erro de login): a sessão inicia com
  `playback_allowed:false`, como o app espera.
- **Login por código de operador:** se a credencial não for e-mail, fica pendente a Edge Function
  `login_operator` (não expor senha/tabela). Por enquanto, Supabase Auth por e-mail/senha.

## 6. Estado das abas do admin

| Aba | Estado | Fonte de dados |
|---|---|---|
| Condomínios | ✅ pronto | `units` |
| Usuários | ✅ pronto | `operators` + `admin_users` |
| Visão Geral / Músicas / Challenges / Analytics / Logs / Auditoria / Atualizações / Feedback / Integração | ⏳ próximos | a definir |

---

## 7. Erros padronizados que o app deve tratar (RPCs de sessão)

`INVALID_CREDENTIALS`, **`UNIT_NOT_ACTIVE`** (novo), `OPERATOR_BLOCKED`, `DEVICE_NOT_ALLOWED`,
`APP_VERSION_NOT_ALLOWED`, `SESSION_ALREADY_ACTIVE`, `INTERNAL_ERROR`.

---

## 8. Situação das pendências

| Item | Estado |
|---|---|
| `unit` no `start_operator_session` | ✅ feito |
| `unit` no `reconcile_operator_state` | ✅ feito |
| erro `UNIT_NOT_ACTIVE` no start | ✅ feito (app precisa **mapear a mensagem**) |
| `register_device` (deriva unit_id, fingerprint interno, pending) | ✅ feito |
| RLS por papel + auditoria (superadmin/unit_manager) | ✅ feito |
| Edge Function `create-operator-login` | ⏳ a construir (decidir senha temp. vs convite) |
| Algoritmo final de `fingerprint_hash` | ⏳ pendente (dev) |
| Retenção/particionamento de logs e eventos | ⏳ pendente (dev) |
| `playlist_requests` / `feedback_submissions` (negócio) | ⏳ pendente de definição (dev) |

**Do lado do app:** adicionar a mensagem para `UNIT_NOT_ACTIVE` (o dev apontou que ainda não está mapeada).

---

## 9. Atualizações do app / Worker — pronto no Admin, pendente deploy/config

O Admin/Supabase passa a controlar qual versão do app é liberada. O upload no R2 não libera atualização sozinho.

- Tabela governada: `app_releases`
- Auditoria: `app_release_audit`
- Edge Function: `get-current-app-release`
- Secret interno: `PORTER_UPDATE_INTERNAL_SECRET`
- Handoff completo: `docs/relatorio-releases-app.md`

Contrato do Worker:

```http
GET https://aifadvyxsefxfcgzgqol.supabase.co/functions/v1/get-current-app-release?channel=stable
X-Porter-Update-Secret: <PORTER_UPDATE_INTERNAL_SECRET>
```

O Worker deve usar `manifest_key` para montar `/stable/latest.yml`. O último arquivo enviado ao R2 não é necessariamente a versão liberada.
