# Prompt para o dev do App do Operador - notas de atualizacao

Substitua a leitura direta de `public.app_release_notes` por esta RPC oficial:

```ts
const { data, error } = await supabase.rpc('get_current_app_release_note');
```

## Contrato real

Assinatura:

```sql
public.get_current_app_release_note()
returns table (
  id uuid,
  app_release_id uuid,
  version_number text,
  title text,
  summary text,
  content text,
  published_at timestamptz
)
```

A chamada usa a sessao Supabase autenticada. Ela resolve internamente o Operador ativo por
`auth.uid() -> operators.auth_user_id`; nunca envie `operator_id` pelo App.

O retorno e uma lista: ela tem exatamente uma nota pendente ou fica vazia (`[]`). Nao ha
envelope `success`/`error`; trate `error` do Supabase normalmente.

```ts
type ReleaseNote = {
  id: string;
  app_release_id: string;
  version_number: string;
  title: string;
  summary: string;
  content: string;
  published_at: string | null;
};

async function reloadCurrentReleaseNote() {
  const { data, error } = await supabase.rpc('get_current_app_release_note');
  if (error) throw error;
  return (data?.[0] ?? null) as ReleaseNote | null;
}
```

A RPC devolve somente a nota `published` vinculada a uma release `released` e `is_current = true`.
Notas antigas nao sao fallback.

## Confirmacao

```ts
await supabase.rpc('record_app_release_note_acknowledgement', {
  p_note_id: note.id,
  p_acknowledge: false, // registra apenas visualizacao; a nota continua pendente
});

await supabase.rpc('record_app_release_note_acknowledgement', {
  p_note_id: note.id,
  p_acknowledge: true, // confirma definitivamente
});
```

A confirmacao e idempotente por `(note_id, operator_id)`. Depois de `true`, chame
`reloadCurrentReleaseNote()` e espere `null` para esse Operador. Outro Operador que ainda
nao confirmou continua recebendo a mesma nota.

## Modal atual do App

O modal de Nota de atualizacao nao possui checkbox. Portanto, o botao `Entendi` e a
confirmacao final do operador e deve chamar `p_acknowledge: true`. Nao use `false` nesse
botao: `false` serve somente para telemetria de leitura e a RPC continuara devolvendo a
mesma nota na proxima carga.

Se o App quiser registrar que a nota foi aberta antes do clique, pode chamar `false` uma
vez ao exibi-la. Isso e opcional e nunca deve fechar a nota nem substituir a chamada
`true` do botao `Entendi`.

## Realtime

Mantenha a assinatura de `public.app_release_notes`, mas use qualquer evento apenas como
gatilho para `reloadCurrentReleaseNote()`. Nao use `payload.new` nem consulte
`app_release_notes` diretamente como fonte final da UI.

```ts
const channel = supabase
  .channel('operator-release-notes')
  .on(
    'postgres_changes',
    { event: '*', schema: 'public', table: 'app_release_notes' },
    () => void reloadCurrentReleaseNote(),
  )
  .subscribe();

// No logout/desmonte:
supabase.removeChannel(channel);
```

Fluxo: apos autenticar, carregue a RPC; assine Realtime; ao receber evento, recarregue a
RPC; ao confirmar com `true`, recarregue a RPC. Nunca use service role no App.
