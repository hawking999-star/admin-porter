# Fluxo de login do app (v1) — usuário OU e-mail + senha

**Projeto Supabase:** `aifadvyxsefxfcgzgqol`
**Data:** 2026-07-05

O operador entra digitando **usuário OU e-mail** + **senha**. A senha é definida pelo admin ao criar
o operador. Abaixo, exatamente o que o app deve fazer.

## Passo a passo que o app executa

**1. Resolver o identificador → e-mail** (porque o Supabase Auth autentica por e-mail)

`POST ${SUPABASE_URL}/functions/v1/resolve-login-email`
Headers: `apikey: <ANON_KEY>`, `Content-Type: application/json`
Body:
```json
{ "identifier": "joao.silva" }   // o que o operador digitou (usuário ou e-mail)
```
Resposta:
```json
{ "email": "joao@exemplo.com" }   // 200
```
- Se `identifier` já for e-mail, devolve ele mesmo.
- Se for usuário, resolve para o e-mail do operador (`operators.username` → login).
- Não encontrado → `404 { "error": "not_found" }`. **Recomendação:** o app mostra mensagem genérica
  ("usuário ou senha inválidos") para não revelar quais usuários existem.
- É `verify_jwt = false` (roda antes do login). Não valida senha — só traduz.

**2. Autenticar (fluxo nativo do Supabase Auth)**
```js
await supabase.auth.signInWithPassword({ email, password })
```
- Credencial errada → tratar como `INVALID_CREDENTIALS`.

**3. Já com a sessão (JWT), seguir o contrato de sessão**
- `register_device(p_request)` → status inicial `pending`.
- `start_operator_session(p_request)` → snapshot com `data.session` e `data.unit`.
- No ciclo: `reconcile_operator_state(p_request)`.
- Sair: `end_operator_session(p_request)`.

> As 4 RPCs só executam com `authenticated` (anon bloqueado).

## Provisionamento (lado do admin) — como o login é criado

O admin cria o operador na tela **Usuários**. O admin **não** cria login pelo navegador; a tela chama a
Edge Function:

`POST ${SUPABASE_URL}/functions/v1/provision-operator`  (Header `Authorization: Bearer <JWT do admin>`)
Body:
```json
{
  "display_name": "João da Silva",
  "username": "joao.silva",
  "email": "joao@exemplo.com",
  "password": "senha-definida-pelo-admin",
  "unit_id": "uuid-do-condominio",
  "role": "operador",
  "session_policy": "single",
  "active": true
}
```
- `verify_jwt = true`. A função valida se o chamador é admin com escopo na unidade
  (`admin_can_manage_operator_unit`), cria o login (`auth.users`, e-mail confirmado) e o perfil em
  `operators` com `auth_user_id` + `username`. Em erro no perfil, desfaz o login criado.
- Retorno: `{ ok: true, operator_id, auth_user_id, email }`.

## Mudanças no modelo (operators)

- **Novo:** `username text` — único (case-insensitive). Usado no login por usuário.
- **`employee_code`** deixou de ser obrigatório (removido da tela do admin).
- Login continua sendo `email` + `password` no Supabase Auth; `username` é resolvido para `email`
  pela `resolve-login-email`.

## Pendências sugeridas

- **Rate limit** na `resolve-login-email` (anti-enumeração de usuários).
- Política de senha (tamanho mínimo hoje: 6) — alinhar com o dev/segurança.
- Reset de senha do operador pelo admin (posso adicionar uma função depois).
