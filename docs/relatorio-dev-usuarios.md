# Relatório para o DEV — Aba "Usuários"

**Projeto:** PTM Admin (novo) · **Banco:** Supabase `aifadvyxsefxfcgzgqol` (porter music)
**Data:** 2026-07-05 · **Status:** construída no admin; criação de login depende de backend (ver seção 4).

---

## 1. O que a aba faz

Duas sub-abas:

- **Porteiros** (`operators`): listar, buscar, **criar** e **editar** o cadastro do porteiro
  (nome, código, condomínio, cargo, política de sessão, ativo).
- **Acessos ao admin** (`admin_users`): listar e **editar** quem entra no admin (nome, papel, 2FA, ativo).
  *Criar* um acesso novo depende de criar o login antes (seção 4).

## 2. Tabelas e colunas usadas

**`public.operators`** (porteiro):

| Coluna | Uso |
|---|---|
| `id` | chave |
| `display_name` | "Nome" |
| `employee_code` | "Código do funcionário" |
| `unit_id` → `units.id` | "Condomínio" (select) |
| `role` (`operador`/`supervisor`) | "Cargo" |
| `session_policy` (`single`/`multi`) | "Sessão" (1 ou vários dispositivos) |
| `active` | "Status" |
| `auth_user_id` | só leitura na aba: mostra "Vinculado" / "Sem login" |

Ao criar/editar, o admin envia: `{ display_name, employee_code, unit_id, role, session_policy, active }`.

**`public.admin_users`** (acesso ao admin):

| Coluna | Uso |
|---|---|
| `display_name` | "Nome" |
| `role` | "Papel" (superadmin, unit_manager, operations_manager, content_manager, challenge_manager, release_manager, auditor, support_readonly) |
| `mfa_required` | "2FA" |
| `active` | "Status" |
| `auth_user_id` | **NOT NULL** — obrigatório; por isso não dá pra criar sem login |

**`public.units`**: usada só para o select de condomínio (id, name, active).

## 3. Backend necessário (RLS)

Além das políticas de `units`/`operators` do relatório de Condomínios, a aba precisa que o admin
possa **inserir/atualizar** `operators` e **atualizar** `admin_users`:

```sql
-- operators: admin cria e edita (a leitura já foi liberada no relatório de Condomínios)
create policy operators_admin_write on public.operators
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- admin_users: admin lê e edita
create policy admin_users_admin_all on public.admin_users
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());
```

> `is_admin()` é a função criada no relatório de Condomínios. Ajustar por papel se necessário
> (ex.: só `superadmin` pode editar `admin_users`).

## 4. Criação de LOGIN — precisa de backend (edge function)

O admin roda no navegador com a **chave pública (anon)**, que **não pode criar usuários de login**
(isso exige a `service_role`, que nunca vai pro navegador). Então:

- **Porteiro:** o admin cria o **cadastro** (`operators`), mas o **login do app** (registro em
  `auth.users` + preencher `operators.auth_user_id`) precisa de uma **Edge Function** com service_role.
  Fluxo sugerido: função `create-operator-login(operator_id, email, senha)` → cria o auth user →
  seta `auth_user_id` no operator. (No admin antigo havia algo equivalente: `createAdminManagedUser`
  e `resolve-login-email`.)
- **Acesso ao admin:** como `admin_users.auth_user_id` é obrigatório, criar um acesso novo passa
  pelo mesmo caminho: criar o auth user primeiro, depois inserir a linha em `admin_users`.

**Enquanto essa função não existe:** dá pra criar o login à mão no painel (Authentication → Add user)
e depois vincular o `auth_user_id` na linha. Se quiser, eu preparo a Edge Function `create-operator-login`.

## 5. O que o APP precisa saber

- **`operators` é a fonte da verdade do porteiro** (substitui `users`/`agent` do banco antigo).
- O login do porteiro é identificado por **`operators.auth_user_id`** (liga o `auth.users` ao cadastro).
- `role`: `operador` ou `supervisor` — o app deve usar isso para as permissões do porteiro.
- `session_policy`: `single` = 1 dispositivo por vez; `multi` = vários. O controle de sessão do app
  (`operator_sessions`) deve respeitar isso.
- `active = false` → porteiro não deve conseguir iniciar plantão.

## 6. Pendências / decisões

- **Escala/turno padrão** (`operators.default_shift_id`) ficou de fora do formulário por enquanto —
  entra quando a aba de **turnos/escalas** for construída.
- Confirmar quais papéis de `admin_users` podem editar acessos (hoje qualquer admin).
- Definir o fluxo oficial de criação de login (Edge Function vs. manual).
