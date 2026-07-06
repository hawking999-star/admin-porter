# Credenciais e setup do Supabase (para o dev)

Projeto: **aifadvyxsefxfcgzgqol** (porter music)

## ✅ Seguros — já preenchidos, pode compartilhar/usar

```
SUPABASE_URL=https://aifadvyxsefxfcgzgqol.supabase.co
SUPABASE_PUBLISHABLE_KEY=sb_publishable_eb1wX2cGhHN0SiXK9LaFgQ_o6DV4fOH
SUPABASE_PROJECT_REF=aifadvyxsefxfcgzgqol
```
(A chave `anon` antiga também existe e pode continuar no app; a `publishable` acima é a recomendada.)

## 🔒 Secretos — NUNCA no app / Git / conversa. Só você pega, no painel

| Variável | Onde pegar (dashboard.supabase.com → projeto) |
|---|---|
| `SUPABASE_DB_PASSWORD` | **Settings → Database → Database password**. Se não lembrar, botão **Reset database password** (gera uma nova). |
| `SUPABASE_ACCESS_TOKEN` | Canto superior direito (seu avatar) → **Access Tokens** → **Generate new token**. Link direto: https://supabase.com/dashboard/account/tokens |
| `SUPABASE_SECRET_KEY` (service_role / `sb_secret_...`) | **Settings → API** → em "Project API keys", **service_role** (botão *Reveal*), ou em "API Keys" a chave **`sb_secret_...`**. |

> A `service_role`/`sb_secret` dá acesso total ao banco (ignora RLS). Ela fica **só** nos secrets da
> Edge Function e na máquina do dev — nunca no Electron, no Admin, no Git ou aqui no chat.

## CLI (para migrations/desenvolvimento)

```
supabase login                                  # abre o navegador pra autorizar
supabase link --project-ref aifadvyxsefxfcgzgqol
supabase db pull                                # baixa o schema atual
```

## Edge Functions — não precisa configurar secret

- O Supabase injeta **automaticamente** `SUPABASE_URL`, `SUPABASE_ANON_KEY` e
  `SUPABASE_SERVICE_ROLE_KEY` nas funções hospedadas. **Nada a fazer.**
- Funções já publicadas e ativas neste projeto:
  - **`provision-operator`** — cria o login do operador (é a "create-operator-login" que você citou; ficou com este nome).
  - **`resolve-login-email`** — login por usuário ou e-mail.
- **SMTP** só é necessário se usar **convite por e-mail** ou **recuperação de senha**. No fluxo atual
  (o admin define a senha na criação) **não é preciso**.

## Ambiente de teste — o que já existe / falta

| Item | Estado |
|---|---|
| `admin_users` superadmin | ✅ existe (ativo) |
| Unidade ativa | ⏳ posso criar |
| Operador de teste com e-mail | ⏳ posso criar (com senha temporária de teste) |
| Device para aprovar | ⏳ posso criar (status `pending`) |

Posso semear esses 3 itens de teste agora — é só confirmar um e-mail/senha de teste (ou uso
`operador.teste@porter.local` com uma senha temporária).
