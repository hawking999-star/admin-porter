# Validação do ciclo de solicitações de playlist — 14/07/2026

## Resultado

O contrato foi corrigido e validado no projeto Supabase `aifadvyxsefxfcgzgqol`.
Nenhuma RPC foi renomeada:

- `manage_operator_playlist(jsonb)`
- `get_my_playlist_requests(jsonb)`
- `admin_review_playlist(uuid, text, text)`

A migration remota `playlist_request_lifecycle` existia, mas as RPCs falhavam
antes de executar o contrato com SQLSTATE `42883`, pois `NULLIF`, `COALESCE`,
`LEAST` e `GREATEST` foram qualificadas incorretamente como funções de
`pg_catalog`.

## Arquivos criados

- `supabase/migrations/20260714171431_fix_playlist_request_lifecycle_builtins.sql`
- `supabase/migrations/20260714172143_fix_operator_profile_audit_builtins.sql`

Nenhum arquivo do Admin ou do Worker precisou ser alterado.

## Migrations aplicadas no Supabase

- `fix_playlist_request_lifecycle_builtins`
- `fix_operator_profile_audit_builtins`

A segunda correção foi necessária porque a mesma qualificação inválida também
atingia `audit_admin_change()` e `update_my_operator_display_name(text)`.

## JSON real de `get_my_playlist_requests`

Resposta obtida com uma sessão autenticada real de Operador após a correção:

```json
{
  "success": true,
  "request_id": "4a4f70a0-007c-44fa-8881-ebb85a98ef71",
  "server_now": "2026-07-14T17:17:43.735655+00:00",
  "data": {
    "requests": [
      {
        "id": "ca9d6c5e-b19a-41e0-a257-6c2748b9b7b3",
        "playlist_id": "c348fd74-bda4-48e9-b2f5-d0eb656e6c26",
        "status": "approved",
        "lifecycle_status": "failed",
        "rejection_reason": null,
        "failure_message": "Nao foi possivel concluir o processamento. Voce pode enviar novamente."
      },
      {
        "id": "0097ce0c-7313-4cf3-9bbb-22d7f2db7614",
        "playlist_id": "c348fd74-bda4-48e9-b2f5-d0eb656e6c26",
        "status": "approved",
        "lifecycle_status": "completed",
        "rejection_reason": null,
        "failure_message": null
      }
    ],
    "submission": {
      "allowed": true,
      "blocked_reason": null,
      "blocking_request_id": null,
      "playlist_id": "c348fd74-bda4-48e9-b2f5-d0eb656e6c26",
      "expected_revision": 49
    }
  },
  "error": null
}
```

Os campos `source_url`, `created_at` e `updated_at` também foram retornados; foram
omitidos acima apenas para manter a evidência legível.

## Teste concorrente real

Duas transações simultâneas chamaram `manage_operator_playlist` para o mesmo
Operador sintético, com chaves e links diferentes:

- chamada 1: `success=true`, revisão da playlist alterada de `1` para `2`;
- chamada 2: `PLAYLIST_REQUEST_ALREADY_PENDING`;
- quantidade final antes da limpeza: exatamente `1` solicitação pendente;
- ID temporário aceito: `64bb8f97-2158-44cb-b3a8-ec12af999368`.

O Operador, a playlist, a solicitação, a idempotência, os eventos e os logs
sintéticos foram removidos após a prova. Auditoria final: `0` linhas temporárias.

## Aprovação, job e ciclo de vida

Teste isolado em transação, integralmente revertido ao final:

- solicitação aprovada: `e277eca2-83cd-4e12-ae53-027cdaa6d686`;
- job vinculado: `09ebb5db-ace2-4eb6-afe4-728a82b4c73c`;
- `queued` projetou `in_progress` e bloqueou novo envio;
- `running` manteve `in_progress`;
- `done` projetou `completed` e liberou novo envio.

Teste de falha:

- solicitação: `a285628c-7e3a-4b5e-9970-185b9c6da711`;
- job vinculado: `24f37167-daf4-4e0f-835f-849adf4cd2f6`;
- `partial` projetou `failed` e liberou novo envio;
- a mensagem interna de teste não apareceu em `failure_message`.

Teste de rejeição:

- solicitação: `3f1a87c7-bd26-41f3-8947-79582bc8868e`;
- status legado `rejected` preservado;
- `lifecycle_status=rejected`;
- nenhum job criado;
- novo envio liberado.

As duas solicitações aprovadas anteriores permaneceram `approved`. Nenhuma foi
rejeitada ou reescrita automaticamente por um envio posterior.

## Guardas preservados

- retry com a mesma chave devolveu a mesma resposta em teste assertivo;
- chave reaproveitada com payload diferente: `IDEMPOTENCY_KEY_REUSED`;
- solicitação pendente: `PLAYLIST_REQUEST_ALREADY_PENDING`;
- revisão antiga: `PLAYLIST_REVISION_CONFLICT`;
- jobs `queued/running`: `PLAYLIST_IMPORT_IN_PROGRESS` permanece na barreira;
- lock transacional por Operador preservado.

## Worker e Realtime

O Worker local já implementa:

- claim condicional `queued -> running`;
- finalização em `done`, `partial` ou `error`;
- retry controlado de falhas recuperáveis.

O trigger remoto `trg_sync_playlist_import_from_job` continua atualizando
`playlists.import_status`, e `public.playlists` permanece na publicação
`supabase_realtime`.

Os logs reais da API confirmaram o Worker implantado ativo, consultando
`download_jobs` com `python-httpx/0.28.1` aproximadamente a cada 10 segundos.
O teste desta entrega validou as transições no banco e o trigger em transação;
não foi criada uma importação externa falsa no YouTube/R2 apenas para forçar um
download completo.

## Segurança

- RLS de `playlist_requests`: ativo;
- acesso direto de `authenticated` à tabela: revogado;
- execução das três RPCs por `authenticated`: permitida;
- execução das três RPCs por `anon`: negada;
- identificação do Operador continua baseada em `auth.uid()`;
- `SECURITY DEFINER` e `search_path=''` preservados;
- nenhuma função remota restante contém as qualificações inválidas auditadas;
- advisors: nenhum erro de segurança e nenhum erro de performance.

## Liberação

O contrato backend está corrigido e liberado para o App. O App deve continuar
consumindo o envelope oficial `{ success, request_id, server_now, data, error }`
e ler `requests` e `submission` dentro de `data`.
