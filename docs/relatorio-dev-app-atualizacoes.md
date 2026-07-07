# Relatorio para o dev do app/Worker - Atualizacoes Porter Music

Data: 2026-07-07

## Contexto

O Admin/Supabase agora e a fonte de verdade para liberar atualizacoes do Porter Music.

O simples upload de arquivos no R2 nao libera versao nova.

Somente uma release com estes campos pode ser entregue aos operadores:

```text
status = released
is_current = true
channel = stable
```

## O que o app/Worker deve fazer

Antes de responder o arquivo de update para o Electron, o Worker deve consultar a Edge Function do Supabase:

```http
GET https://aifadvyxsefxfcgzgqol.supabase.co/functions/v1/get-current-app-release?channel=stable
X-Porter-Update-Secret: <PORTER_UPDATE_INTERNAL_SECRET>
```

O Electron nao precisa consultar o Supabase para esse fluxo. Quem conversa com o Supabase e o Worker.

## Autenticacao

A Edge Function nao usa JWT do operador.

Ela exige o header interno:

```http
X-Porter-Update-Secret
```

Esse valor deve ser o mesmo configurado em:

- Supabase Secret Store: `PORTER_UPDATE_INTERNAL_SECRET`
- Cloudflare Worker secret: `PORTER_UPDATE_INTERNAL_SECRET`

Nao colocar esse valor no Electron, no frontend, em GitHub, em arquivo versionado ou em logs.

## Resposta 200

Quando existir release ativa valida, a resposta sera:

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

## Como usar a resposta

O Worker deve usar `manifest_key` para buscar no R2 privado o YAML aprovado.

Exemplo:

```text
manifest_key = stable/manifests/1.0.6.yml
```

Esse arquivo deve virar a resposta do endpoint que o Electron ja usa para auto-update, por exemplo `/stable/latest.yml`.

O Worker tambem deve considerar como oficiais:

```text
installer_key
blockmap_key
sha512
size_bytes
```

Esses campos representam a versao aprovada no Admin.

## Regras obrigatorias

O Worker nao deve:

- usar o ultimo arquivo enviado ao R2 como release ativa;
- liberar update apenas porque existe arquivo no bucket;
- consultar releases em `draft`, `testing`, `approved`, `blocked` ou `superseded`;
- depender do login/JWT do operador;
- expor `PORTER_UPDATE_INTERNAL_SECRET` em resposta, log ou frontend;
- inventar `latest.yml` quando o Supabase retornar 404.

O Worker deve:

- chamar a Edge Function antes de servir update;
- validar `status === "released"`;
- validar `is_current === true`;
- usar `manifest_key` como fonte do YAML aprovado;
- tratar `mandatory` e `minimum_version` conforme a logica atual do updater;
- manter R2 privado.

## Codigos HTTP

### 200

Existe release ativa valida.

Acao do Worker:

- buscar `manifest_key` no R2;
- servir o YAML aprovado ao Electron;
- usar os demais campos para auditoria/log operacional, se necessario.

### 401

Secret ausente ou incorreto.

Resposta:

```json
{ "error": "unauthorized" }
```

Acao do Worker:

- nao entregar update;
- registrar erro operacional sem logar o secret.

### 404

Nao existe release ativa valida para o canal.

Resposta:

```json
{ "error": "release_not_found" }
```

Acao do Worker:

- nao inventar update;
- nao usar ultimo arquivo do R2;
- responder ao Electron como "sem atualizacao disponivel" conforme o fluxo atual.

### 405

Metodo diferente de GET.

Resposta:

```json
{ "error": "method_not_allowed" }
```

## Fluxo esperado

```text
Electron
  -> Worker atual
  -> Worker chama Supabase get-current-app-release
  -> Supabase confirma release released/is_current/stable
  -> Worker busca manifest_key no R2 privado
  -> Worker entrega o YAML aprovado
  -> Electron baixa/instala como ja faz hoje
```

## Testes que o dev do app/Worker deve executar

1. Chamar a Edge Function sem `X-Porter-Update-Secret`.
   - Esperado: `401`.

2. Chamar com secret incorreto.
   - Esperado: `401`.

3. Chamar com secret correto e sem release ativa.
   - Esperado: `404`.

4. Criar/liberar uma release `stable` real no Admin.
   - Esperado: Edge Function retorna `200`.

5. Confirmar que o Worker usa o `manifest_key` retornado.
   - Esperado: o YAML entregue ao Electron e exatamente o YAML aprovado no Admin.

6. Bloquear ou substituir a release no Admin.
   - Esperado: Worker para de entregar a bloqueada e passa a seguir a release ativa.

7. Executar rollback no Admin.
   - Esperado: Worker passa a entregar o `manifest_key` da versao reativada.

## O que ja foi feito no Admin/Supabase

- Tabela `app_releases`.
- Tabela `app_release_audit`.
- RLS para impedir operador comum e anonimo.
- RPCs de criar, editar, aprovar, liberar, bloquear e rollback.
- Edge Function `get-current-app-release`.
- `verify_jwt = false` na Edge Function.
- Autenticacao por `X-Porter-Update-Secret`.
- Tela `/atualizacoes` no Admin para gerir releases.

## Pendencias fora do Admin/Supabase

- Configurar `PORTER_UPDATE_INTERNAL_SECRET` no Supabase.
- Configurar o mesmo secret no Cloudflare Worker.
- Ajustar/confirmar Worker para consultar a Edge Function antes de servir update.
- Testar `200` real com secret correto.
- Criar uma release `stable` real no Admin com chaves de artefatos existentes no R2.

