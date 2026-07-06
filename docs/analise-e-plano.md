# Análise do admin antigo + Plano do novo

## Resumo

O admin antigo (`admin-porterr`) é grande e bem-feito no esqueleto, mas ficou **inchado**
(~24.600 linhas fora a UI) e ligado ao **banco antigo**. O banco novo (`aifadvyxsefxfcgzgqol`)
já é limpo e reorganizado. Decisão: **reaproveitar a aparência e reescrever os dados**,
construindo enxuto, aba por aba, cada uma com relatório para o dev.

## O que foi reaproveitado

- Stack base: React + Supabase + React Query.
- Kit visual completo (~46 componentes de UI) e o tema escuro do print.
- Estrutura da barra lateral (grupos Operação / Engajamento / Sistema) idêntica.
- Padrão de tela: lista + busca + formulário em diálogo.

## O que foi cortado (enxugamento)

| Cortado | Por quê |
|---|---|
| SSR / TanStack Start + camada de servidor | Complexidade que quebrava; SPA direto no Supabase é mais simples |
| AWS SDK + Cloudflare R2 + importador YouTube | Fora do núcleo do admin; tratamos por relatório se precisar |
| Geração de desafios por IA, importações em massa | Gordura das abas Músicas (4.044 linhas) e Challenges (3.007) |
| Formato duplo de dados dos desafios | Banco novo já é limpo, não precisa |

## O que NÃO veio junto (riscos do projeto antigo)

- Segredos vazados no GitHub (service_role, R2, cookies YouTube) — o novo nunca guarda segredo no código.
- 183 problemas de performance do banco antigo — o banco novo é outro, já limpo.

## De → Para (banco antigo → banco novo)

| Antigo | Novo |
|---|---|
| `users` | `operators` (+ `admin_users` para acesso ao admin) |
| `musicas` | `tracks` |
| `condominiums` / `condominium_settings` / `configuracoes` | `units` + `system_settings` |
| `sessions` | `operator_sessions` |
| `audit_logs` | `admin_audit_logs` |
| `challenges` (formato duplo) | `challenges` (formato único, limpo) |

## Ordem de construção (aba por aba)

1. **Base + Condomínios** ✅ (feito nesta etapa)
2. **Usuários** (operators + admin_users) — depende de units
3. **Músicas** (tracks + playlists + categories) — versão enxuta
4. **Challenges** (challenges + challenge_logs + operator_blocks)
5. **Visão Geral** (dashboard, só leitura)
6. **Analytics / Logs / Auditoria / Atualizações / Feedback / Integração**

Cada aba termina com um `relatorio-dev-<aba>.md` explicando: o que faz, tabelas/colunas usadas,
backend necessário (RLS/funções) e o que o app precisa do lado dele.

## Pendência transversal mais importante

**RLS (permissões).** As tabelas do banco novo têm RLS ligado sem política. Antes de qualquer aba
mostrar dados, é preciso liberar acesso aos admins (ver `relatorio-dev-condominios.md`, seção 3).
Este é o primeiro passo de backend.
