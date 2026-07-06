# Relatório para o DEV — Aba "Condomínios"

**Projeto:** PTM Admin (novo) · **Banco:** Supabase `aifadvyxsefxfcgzgqol` (porter music)
**Data:** 2026-07-05 · **Status da aba:** construída no admin, pendente de liberação de acesso (RLS) no banco.

---

## 1. O que a aba faz

Gerencia os **condomínios** (unidades onde os porteiros trabalham). É a base da operação:
porteiros, músicas e challenges se penduram em uma unidade.

Funções entregues:
- **Listar** condomínios, com busca por nome/código e contagem de porteiros ativos por unidade.
- **Criar** um condomínio novo.
- **Editar** um condomínio (clicando na linha).

## 2. Tabela usada e contrato de dados

Fonte da verdade: **`public.units`**. A aba lê e grava exatamente estas colunas:

| Coluna | Tipo | Uso na aba |
|---|---|---|
| `id` | uuid | chave (gerada pelo banco) |
| `code` | text (único) | "Código" — identificador único da unidade |
| `name` | text | "Nome" |
| `address` | text (nulo) | "Endereço" (logradouro) |
| `city` | text (nulo) | "Cidade" (também aparece na lista) |
| `state` | text (nulo) | "UF" (estado) |
| `timezone` | text | "Fuso" (padrão `America/Sao_Paulo`) |
| `active` | boolean | "Status" (Ativo/Inativo) |
| `created_at` | timestamptz | exibição |

> Colunas `address`, `city`, `state` foram **adicionadas ao banco** em 2026-07-05
> (migração `add_address_fields_to_units`), todas nuláveis.

A contagem de porteiros vem de **`public.operators`**, contando linhas com `unit_id = units.id` e `active = true`.

**Ao criar/editar**, o admin envia: `{ code, name, address, city, state, timezone, active }`.
`id`, `revision`, `created_at`, `updated_at` ficam por conta do banco (defaults/triggers).

## 3. Backend necessário ANTES de funcionar (IMPORTANTE)

Hoje todas as tabelas têm **RLS ligado e (aparentemente) sem política**. Efeito: o admin loga,
mas a lista vem **vazia** e criar/editar **falha silenciosamente**, porque a chave pública (anon)
não tem permissão. É preciso liberar acesso aos administradores.

Sugestão de política (rodar no SQL Editor — validar antes em ambiente de teste):

```sql
-- Quem é admin: existe linha ativa em admin_users para o usuário logado
create or replace function public.is_admin()
returns boolean language sql stable security definer
set search_path = public as $$
  select exists (
    select 1 from public.admin_users a
    where a.auth_user_id = auth.uid() and a.active = true
  );
$$;

-- units: admin lê e escreve
create policy units_admin_all on public.units
  for all to authenticated
  using (public.is_admin()) with check (public.is_admin());

-- operators: admin lê (necessário para a contagem de porteiros)
create policy operators_admin_read on public.operators
  for select to authenticated
  using (public.is_admin());
```

> Ajustar conforme os papéis de `admin_users.role` que devem enxergar/editar condomínios
> (hoje: superadmin, unit_manager, operations_manager, etc.). Se quiser escopo por unidade
> (`admin_users.unit_scope`), aplicar o filtro correspondente aqui.

## 4. O que o APP precisa saber (lado do porteiro)

> Alinhado com o dev do app (2026-07-05): **o app não consulta `units`/`condominiums` direto.**
> Ele consome o objeto `unit` que vem no **snapshot das RPCs**. Ver contrato completo no
> `handoff-dev-app.md` (seção "Contrato do snapshot — unit").

- **`units` é a fonte da verdade de "condomínio"**, exposta ao app via snapshot (`data.unit`).
- Cada porteiro (`operators`) referencia **uma** unidade via `operators.unit_id`.
- O **código (`code`) é único** e estável — usado pelo app em logs/telemetria.
- `timezone` da unidade é usado para horários civis no app.
- `active = false` → o `start_operator_session` já **bloqueia a sessão** com erro `UNIT_NOT_ACTIVE`.

## 5. Pendências / decisões

- **Confirmar os papéis** de `admin_users` que podem criar/editar condomínio.
- **Escopo por unidade?** Se supervisores só devem ver a própria unidade, decidir e ajustar a RLS.

### Decidido (2026-07-05)
- **Endereço/cidade/estado:** ✅ adicionados ao `units` e ao formulário do admin (mais o fuso, que já era configurável).
- **Exclusão:** ✅ decidido — **inativar já basta**. O admin não apaga condomínio; só marca `active = false`.
