# Controle de releases do Porter Music

Data: 2026-07-07.

## Resumo

O Admin/Supabase governa a criacao, aprovacao, liberacao, bloqueio e rollback das versoes do Porter Music. Upload no R2 nao libera atualizacao automaticamente.

Somente uma release com `status = released`, `is_current = true` e `channel = stable` pode ser entregue ao Worker.

Nao foram alterados Electron, Cloudflare Worker, bucket R2, GitHub Actions, login dos operadores, playlists ou contratos fora de atualizacoes.

## Migrations

Criadas/aplicadas para releases:

- `20260706202732_app_release_approval_flow.sql`
- `20260707010139_app_release_release_notes_default_cleanup.sql`
- `20260707012612_app_release_contract_hardening.sql`

## app_releases

Tabela principal: `public.app_releases`.

Campos finais relevantes:

- `id uuid primary key default gen_random_uuid()`
- `version text not null unique`
- `platform text not null default 'win32-x64'`
- `channel text not null default 'stable'`
- `status text not null default 'draft'`
- `is_current boolean not null default false`
- `mandatory boolean not null default true`
- `minimum_version text null`
- `title text not null`
- `release_notes text null`
- `manifest_key text null`
- `installer_key text null`
- `blockmap_key text null`
- `sha512 text null`
- `size_bytes bigint null`
- `created_by uuid`
- `approved_by uuid`
- `released_by uuid`
- `blocked_by uuid`
- `created_at timestamptz not null default now()`
- `updated_at timestamptz not null default now()`
- `approved_at timestamptz null`
- `released_at timestamptz null`
- `blocked_at timestamptz null`
- `block_reason text null`

Status aceitos: `draft`, `testing`, `approved`, `released`, `blocked`, `superseded`.

SemVer aceito: somente formato simples `x.y.z`, por exemplo `1.0.6`. Rejeita `v1.0.6`, `1.0` e textos.

Regra de release ativa: indice parcial `app_releases_current_channel_uidx` garante uma unica `is_current = true` por `channel`.

## app_release_audit

Tabela: `public.app_release_audit`.

Campos:

- `id uuid primary key default gen_random_uuid()`
- `release_id uuid`
- `action text not null`
- `previous_status text null`
- `new_status text null`
- `actor_id uuid null`
- `metadata jsonb not null default '{}'`
- `created_at timestamptz not null default now()`

Acoes: `created`, `edited`, `approved`, `released`, `blocked`, `superseded`, `rollback`.

## RLS

RLS ativo em `app_releases` e `app_release_audit`.

Policies:

- `app_releases_admin_select`: `SELECT` para `authenticated` quando `is_admin()`.
- `app_releases_release_admin_write`: escrita para `authenticated` quando `is_release_admin()`.
- `app_release_audit_admin_select`: `SELECT` para `authenticated` quando `is_admin()`.

`anon` nao tem acesso direto. Operador comum nao gerencia releases. O frontend usa publishable key; service role fica apenas na Edge Function.

## RPCs

Assinaturas:

- `create_app_release(p_version text, p_title text, p_release_notes text, p_channel text, p_mandatory boolean, p_minimum_version text, p_manifest_key text, p_installer_key text, p_blockmap_key text, p_sha512 text, p_size_bytes bigint, p_status text) returns uuid`
- `update_app_release(p_release_id uuid, p_title text, p_release_notes text, p_mandatory boolean, p_minimum_version text, p_manifest_key text, p_installer_key text, p_blockmap_key text, p_sha512 text, p_size_bytes bigint, p_status text) returns void`
- `approve_app_release(p_release_id uuid) returns void`
- `release_app_release(p_release_id uuid) returns void`
- `block_app_release(p_release_id uuid, p_reason text) returns void`
- `rollback_app_release(p_target_release_id uuid) returns void`

Somente `superadmin` e `release_manager` podem executar.

Antes de liberar exige: `version`, `title`, `manifest_key`, `installer_key`, `blockmap_key`, `sha512`, `size_bytes`.

## Edge Function

Nome: `get-current-app-release`.

URL:

```text
https://aifadvyxsefxfcgzgqol.supabase.co/functions/v1/get-current-app-release?channel=stable
```

Metodo: `GET`.

Header:

```http
X-Porter-Update-Secret: <PORTER_UPDATE_INTERNAL_SECRET>
```

Configuracao confirmada:

- `verify_jwt = false`
- funcao ativa no Supabase
- versao deployada: `2`
- autenticacao feita no codigo por comparacao constante do header com `PORTER_UPDATE_INTERNAL_SECRET`
- consulta usa service role somente depois de validar o segredo interno

Resposta 200 esperada:

```json
{
  "id": "uuid",
  "version": "1.0.6",
  "channel": "stable",
  "status": "released",
  "is_current": true,
  "mandatory": true,
  "minimum_version": null,
  "title": "Melhorias no Porter Music",
  "release_notes": "Descricao da atualizacao",
  "manifest_key": "stable/manifests/1.0.6.yml",
  "installer_key": "stable/Porter-Music-Setup-1.0.6-x64.exe",
  "blockmap_key": "stable/Porter-Music-Setup-1.0.6-x64.exe.blockmap",
  "sha512": "...",
  "size_bytes": 123456789,
  "released_at": "2026-07-07T00:00:00Z"
}
```

Resposta 401:

```json
{ "error": "unauthorized" }
```

Resposta 404:

```json
{ "error": "release_not_found" }
```

Resposta 405:

```json
{ "error": "method_not_allowed" }
```

## Admin e notas

A rota `/atualizacoes` foi reaproveitada. Nao foi criada outra aba de notas.

A tela mostra:

- versao, titulo, canal, status e release ativa
- obrigatoria/opcional e versao minima
- `manifest_key`, `installer_key`, `blockmap_key`, `sha512`, tamanho
- responsaveis e datas de criacao, aprovacao, liberacao e bloqueio
- motivo de bloqueio
- notas de releases liberadas como "Atualizacao do aplicativo"

Releases em `draft`, `testing`, `approved` ou `blocked` nao aparecem como atualizacao lancada.

Acoes disponiveis:

- criar
- editar
- enviar para teste
- aprovar
- liberar
- bloquear
- rollback

Liberar, bloquear e rollback exigem confirmacao explicita.

## Contrato com o Worker

O Worker deve chamar:

```text
GET https://aifadvyxsefxfcgzgqol.supabase.co/functions/v1/get-current-app-release?channel=stable
X-Porter-Update-Secret: <PORTER_UPDATE_INTERNAL_SECRET>
```

Codigos:

- `200`: usar `manifest_key` para buscar o YAML aprovado no R2 privado.
- `401`: segredo ausente/incorreto; nao entregar update.
- `404`: nao ha release ativa valida; nao inventar latest.
- `405`: metodo diferente de GET.

Regra: somente `status = released` e `is_current = true` e entregue. O Worker nao deve usar "ultimo arquivo enviado no R2" como fonte de verdade.

## Teste final consolidado

Executado em canal isolado `codex-test-013325314` para nao afetar `stable`. Dados ficticios removidos ao final: 3 releases, 12 linhas de `app_release_audit` e 12 linhas de `admin_audit_logs`.

Resultado do banco/RPCs: OK.

Validado:

- release em `draft` nao aparece na consulta de release ativa
- `update_app_release` envia draft para `testing`
- `approve_app_release` aprova release pronta
- `release_app_release` libera release e deixa uma unica `is_current`
- release anterior vira `superseded`
- payload completo contem `id`, `status`, `is_current`, chaves R2, hash e tamanho
- notas liberadas aparecem na consulta usada pela aba existente
- `rollback_app_release` reativa a versao anterior
- `block_app_release` registra `blocked_by` e `block_reason`
- operador comum recebe `forbidden`
- auditoria registrou `created`, `edited`, `approved`, `released`, `superseded`, `rollback`, `blocked`

Validado via HTTP:

- sem `X-Porter-Update-Secret`: `401 {"error":"unauthorized"}`
- com segredo incorreto: `401 {"error":"unauthorized"}`
- metodo `POST`: `405 {"error":"method_not_allowed"}`

Nao foi executado `200`/`404` HTTP com segredo correto porque o valor real de `PORTER_UPDATE_INTERNAL_SECRET` nao esta disponivel localmente e nao deve ser inventado nem exposto.

## Configuracoes manuais pendentes

Configurar ou confirmar no Supabase Secret Store:

```bash
npx supabase secrets set PORTER_UPDATE_INTERNAL_SECRET="<segredo forte>"
```

Configurar o mesmo valor no Cloudflare Worker.

O valor real do secret nao deve ir para migration, codigo, frontend, `.env` versionado, documentacao ou GitHub.

## Confirmacao do secret

Nao foi possivel confirmar se `PORTER_UPDATE_INTERNAL_SECRET` ja esta cadastrado: o CLI retornou `403` ao listar secrets por falta de privilegio da conta. O endpoint esta protegido e responde `401` sem header ou com header incorreto, mas isso nao distingue secret ausente de secret cadastrado.

## Pendencias

- Confirmar/cadastrar `PORTER_UPDATE_INTERNAL_SECRET` no Supabase.
- Configurar o mesmo segredo no Cloudflare Worker.
- Testar `200` e `404` HTTP reais com o segredo correto.
- Cadastrar/liberar uma release `stable` real com artefatos validos no R2 privado.
