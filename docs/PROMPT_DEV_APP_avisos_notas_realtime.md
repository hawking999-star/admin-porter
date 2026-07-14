# Contrato alinhado para o App do Operador - avisos e notas

Este documento substitui os fluxos antigos que liam `app_release_notes` diretamente.
Use o cliente Supabase autenticado, sem `service_role` e sem enviar `operator_id`.

## Nota de atualizacao

A fonte oficial e somente a RPC:

```ts
const { data, error } = await supabase.rpc('get_current_app_release_note');
if (error) throw error;
const note = data?.[0] ?? null;
```

Ela retorna zero ou uma nota, sempre da release `released`, `is_current = true` e com
nota `published`. O retorno vazio nao e erro.

O modal atual nao tem checkbox. Ao abrir, o App pode registrar leitura simples:

```ts
await supabase.rpc('record_app_release_note_acknowledgement', {
  p_note_id: note.id,
  p_acknowledge: false,
});
```

Essa chamada nao fecha a pendencia. No botao `Entendi`, chame obrigatoriamente:

```ts
await supabase.rpc('record_app_release_note_acknowledgement', {
  p_note_id: note.id,
  p_acknowledge: true,
});
```

Depois de `true`, recarregue `get_current_app_release_note()`; para aquele Operador ela
deve retornar vazia. As duas chamadas sao idempotentes e o backend resolve o Operador
pelo JWT.

## Atualizacoes e avisos

Os avisos ativos podem ser lidos diretamente, pois a RLS ja aplica status, janela de
validade e audiencia do Operador:

```ts
const { data: notices, error } = await supabase
  .from('app_notices')
  .select('id, title, message, severity, requires_ack, starts_at, ends_at')
  .eq('status', 'active')
  .order('severity', { ascending: false });
if (error) throw error;
```

Nao filtre audiencia nem `starts_at`/`ends_at` no cliente. Se a RLS retornou o aviso, ele
esta vigente para o Operador. `requires_ack` e booleano real.

Para manter o checkbox correto apos fechar e reabrir o App, carregue tambem somente os
proprios registros de confirmacao:

```ts
const ids = (notices ?? []).map((notice) => notice.id);
const { data: acknowledgements, error: ackError } = await supabase
  .from('app_notice_acknowledgements')
  .select('notice_id, acknowledged_at')
  .in('notice_id', ids);
if (ackError) throw ackError;

const acknowledgedNoticeIds = new Set(
  (acknowledgements ?? [])
    .filter((ack) => ack.acknowledged_at !== null)
    .map((ack) => ack.notice_id),
);
```

Mostre o checkbox somente se existir aviso visivel com `requires_ack === true` cujo id
nao esteja em `acknowledgedNoticeIds`. Ao abrir o modal, registre leitura com `false`.
No clique de `Entendi`, confirme cada aviso obrigatorio pendente com `true`:

```ts
await Promise.all(pendingRequiredNotices.map((notice) =>
  supabase.rpc('record_app_notice_acknowledgement', {
    p_notice_id: notice.id,
    p_acknowledge: true,
  }),
));
```

Nao envie `operator_id`. A RPC e idempotente, resolve o Operador pelo JWT e recusa aviso
fora da janela, desativado ou de outra audiencia com `notice_not_found`.

## Realtime e erros

Assine `app_notices` e `app_release_notes` apenas como gatilho de recarga. Nao use
`payload.new` como fonte final. Em evento de nota, recarregue a RPC; em evento de aviso,
recarregue avisos e confirmacoes. Remova o canal no logout.

Em erro de carregamento, mantenha os dados ja exibidos. Nao troque a lista atual por uma
lista vazia. Trate `release_note_not_found` e `notice_not_found` como item que deixou de
estar visivel; trate `operator_not_found` pedindo novo login.

## Aceite

- Nota atual: RPC retorna lista com zero ou uma nota.
- Botao `Entendi` da nota usa `p_acknowledge: true`.
- Aviso obrigatorio usa checkbox ate existir `acknowledged_at` para o proprio Operador.
- Avisos fora da janela nao chegam pela RLS.
- Um evento Realtime apenas dispara nova consulta.
