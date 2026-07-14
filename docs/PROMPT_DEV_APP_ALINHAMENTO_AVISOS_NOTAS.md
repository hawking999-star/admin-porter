# Prompt para o dev do App - alinhamento de notas e avisos

O backend Supabase ja esta validado. Implemente somente os ajustes abaixo no App do
Operador. Nao crie RPC, tabela, migration, acesso com service_role ou envio de
`operator_id`.

## 1. Nota de atualizacao

Continue usando apenas a RPC autenticada `get_current_app_release_note`. Ela retorna
uma lista com zero ou uma nota; use `data?.[0] ?? null`. Realtime em
`app_release_notes` deve apenas disparar nova chamada dessa RPC.

O modal nao tem checkbox. Portanto, o botao `Entendi` representa a confirmacao final:

```ts
await supabase.rpc('record_app_release_note_acknowledgement', {
  p_note_id: note.id,
  p_acknowledge: true,
});

const { data, error } = await supabase.rpc('get_current_app_release_note');
if (error) throw error;

if ((data ?? []).length === 0) {
  renderReleaseNote(null);
  openNoticesIfNeeded();
}
```

Nao use `p_acknowledge: false` no botao final. `false` e somente leitura opcional:
registra `read_at`, mas a nota continua pendente. Se quiser registrar a abertura do
modal, chame `false` uma unica vez ao exibir a nota; isso nao substitui o `true`.

Em erro na confirmacao ou no reload, mantenha a nota renderizada e mostre erro. Nao
feche o modal localmente antes de confirmar a resposta do backend.

## 2. Avisos

Continue lendo os avisos com o cliente Supabase autenticado:

```ts
const { data: notices, error } = await supabase
  .from('app_notices')
  .select('id, title, message, severity, requires_ack, starts_at, ends_at')
  .eq('status', 'active')
  .order('severity', { ascending: false });
```

Nao filtre audiencia, horario de inicio ou horario de fim no App. A RLS ja devolve
somente avisos ativos, vigentes e autorizados para o Operador.

Depois de carregar os avisos visiveis, carregue os registros do proprio Operador para
persistir o estado de confirmacao entre reinicios:

```ts
const ids = (notices ?? []).map((notice) => notice.id);
const { data: acknowledgements, error: ackError } = await supabase
  .from('app_notice_acknowledgements')
  .select('notice_id, acknowledged_at')
  .in('notice_id', ids);
if (ackError) throw ackError;

const acknowledgedIds = new Set(
  (acknowledgements ?? [])
    .filter((ack) => ack.acknowledged_at !== null)
    .map((ack) => ack.notice_id),
);
```

Exiba o checkbox apenas quando houver aviso visivel com `requires_ack === true` cujo
id nao esteja em `acknowledgedIds`.

Ao abrir o modal, mantenha a leitura simples atual com `p_acknowledge: false`. No
botao `Entendi`, confirme todos os avisos obrigatorios ainda pendentes com
`p_acknowledge: true`. Essa chamada e idempotente.

## 3. Erros e Realtime

- Em falha de carga, preserve avisos e nota ja renderizados. Remova o uso de
  `renderNotices([])` no caminho de erro.
- Para `notice_not_found` ou `release_note_not_found`, remova apenas o item que deixou
  de ser visivel e recarregue a fonte correspondente.
- Para `operator_not_found`, encerre a sessao local e solicite novo login.
- Assine `app_notices` e `app_release_notes` somente como gatilho para recarregar os
  dados. Nao use `payload.new` como fonte final e remova os canais no logout.

## Criterios de aceite

1. Nota: `false` mantem a RPC com uma nota; `true` faz a RPC retornar vazia para o
   mesmo Operador.
2. Outro Operador sem confirmacao continua recebendo a nota.
3. Um aviso obrigatorio confirmado nao mostra checkbox depois de fechar e reabrir o
   App.
4. Avisos fora da janela de validade nao aparecem.
5. Falha temporaria de rede nao apaga a UI ja carregada.
