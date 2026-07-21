# Baseline Supabase local isolada

> **ESTE WORKDIR NÃO DEVE SER VINCULADO A UM PROJETO SUPABASE REMOTO.**
>
> **NUNCA EXECUTE DB PUSH, DB PULL OU MIGRATION REPAIR A PARTIR DESTE DIRETÓRIO.**

## Propósito

Este diretório reconstrói, em containers locais separados, o estado confirmado do
schema `public` do PTM Admin. Ele existe para resets reproduzíveis, lint e testes
de contrato sem executar a sequência histórica das migrations de produção.

A Supabase CLI exige que `config.toml`, `migrations`, `seed.sql` e `tests` fiquem
dentro de uma pasta `supabase`. Por isso, a raiz operacional da CLI é
`supabase-local-baseline/`, e os artefatos ficam em
`supabase-local-baseline/supabase/`.

As 94 migrations em `../supabase/migrations` continuam sendo o histórico de
produção. Elas não são executadas, alteradas, renomeadas ou substituídas por este
workdir. Os 34 stubs permanecem intactos porque a baseline local representa o
estado final do schema e não tenta reescrever a história aplicada.

## Fonte autoritativa

- Snapshot: `production-public-schema.sql`, obtido somente do schema `public`.
- Data: 2026-07-16.
- SHA-256 do snapshot:
  `04B39BF486C7AFB6380A6845C31A18F1B1BCF74FEFA14910A53B8A7A55B2B97F`.
- Supabase CLI usada na captura: `2.107.0`.
- Commit-base do deployment: `d28246d5a68572f00883650777e411d458869afe`.
- O snapshot bruto permanece fora do Git e fora deste workdir.

O snapshot é autoritativo para os objetos do schema `public`. Como um dump
limitado a `public` não inclui definições do schema `private`, as 20 funções
privadas efetivamente referenciadas foram extraídas das definições finais das
migrations locais implantadas. O script `scripts/build-baseline.ps1` verifica o
hash da fonte, remove ownership e valida o contrato de `operator_blocks`.

## Matriz de sanitização

| Elemento | Ação | Justificativa |
| --- | --- | --- |
| Extensions | Adaptar | `pgcrypto`, `pg_trgm` e `unaccent` são criadas nos schemas usados pelos contratos finais. |
| Schemas | Adaptar | `public` é preservado; `extensions` e `private` são preparados apenas para dependências confirmadas. |
| Types e enums | Preservar | Mantêm nomes e contratos confirmados. |
| Sequences | Preservar | Mantêm defaults e dependências do snapshot. |
| Tables e columns | Preservar | Mantêm o estado final, inclusive imperfeições conhecidas. |
| Defaults | Preservar | Mantêm semântica e tipos de retorno. |
| Constraints e FKs | Preservar | Nenhuma FK ou unicidade nova foi inventada. |
| Indexes | Preservar | Mantêm operadores e estratégias confirmadas. |
| Functions e RPCs | Preservar/Adaptar | Funções públicas vêm do snapshot; dependências privadas vêm das migrations finais identificadas. |
| Triggers | Preservar | Mantêm os alvos e funções do snapshot. |
| Views | Preservar | Mantêm a consulta final confirmada. |
| RLS e policies | Preservar | Nenhuma policy foi enfraquecida para os testes. |
| Grants e revokes | Preservar | Roles gerenciadas pelo Supabase local são compatíveis. |
| Owners | Remover | Evita ownership específico do ambiente remoto. |
| Comments | Preservar | Somente comentários de schema, sem caminhos ou dados reais. |
| Dados | Remover | O snapshot não contém dados; fixtures fictícias ficam em `seed.sql`. |

## Isolamento

- `project_id`: `ptm-admin-local-baseline`.
- API local: porta `55321`.
- Postgres local: porta `55322`.
- Shadow database: porta `55320`.
- Studio: porta `55323`.
- Inbucket: porta `55324`.
- Analytics: porta `55327`.
- Pooler reservado: porta `55329`.
- Inspector Edge Runtime: porta `8183`.

O diretório `.temp` pode ser recriado pela CLI com metadados locais de versão.
Os scripts recusam marcadores de link, como `project-ref`,
`linked-project.json` e `pooler-url`.

## Uso

Execute a partir da raiz do repositório:

```powershell
.\supabase-local-baseline\scripts\verify-unlinked.ps1
.\supabase-local-baseline\scripts\start-local.ps1
.\supabase-local-baseline\scripts\reset-local.ps1
.\supabase-local-baseline\scripts\lint-local.ps1
.\supabase-local-baseline\scripts\test-local.ps1
.\supabase-local-baseline\scripts\stop-local.ps1
```

O runner de testes usa `psql` dentro do container Postgres isolado porque os
quatro testes existentes são scripts transacionais de contrato, não arquivos
pgTAP. Os arquivos originais são copiados sem alteração e cada um termina com
`ROLLBACK`.

## Fixtures

`supabase/seed.sql` usa somente UUIDs fixos fictícios. Ele cria:

- duas unidades;
- um superadmin e um gestor operacional;
- dois Operadores ativos e um supervisor;
- dois turnos;
- dois dispositivos locais;
- uma regra global mínima de desafios.

Os testes criam e revertem seus próprios dados específicos de playlists,
challenges, logs e bloqueios. Não há e-mail, senha ou dado real nas fixtures.

## Atualização futura da baseline

1. Gere um novo snapshot somente de schema, somente de `public`, em diretório
   temporário fora do Git.
2. Revise o dry-run e confirme que não existe escrita ou inclusão de dados.
3. Atualize o hash esperado no builder somente após revisão.
4. Mapeie novamente toda referência ao schema `private` para a definição final
   já comprovada nas migrations.
5. Gere uma nova migration com `supabase migration new` neste workdir.
6. Execute dois resets completos, lint e os quatro testes.
7. Compare catálogo, assinaturas, RLS, policies, grants, triggers e constraints.

Nunca copie o dump bruto diretamente como migration.

## Riscos e rollback

O maior risco é divergência futura entre produção e a baseline compactada. A
mitigação é manter hash, fonte, mapeamento das dependências privadas e validação
em dois resets. Esta baseline não corrige dívidas do schema; melhorias devem ser
avaliadas em migrations novas e separadas.

Rollback local: pare os containers com `stop-local.ps1` e remova somente o
diretório `supabase-local-baseline/`. Nenhum arquivo de produção ou dado remoto
é necessário para o rollback.
