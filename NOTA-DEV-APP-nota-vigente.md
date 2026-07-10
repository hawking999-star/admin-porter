# App Electron — trocar a leitura da nota de atualização

## Problema
Notas antigas reapareciam como "histórico" depois que a mais recente era confirmada.

## O que mudar (só a nota; avisos continuam iguais)
Na **carga inicial** e a cada **evento Realtime** de `app_release_notes`, em vez de buscar na tabela e escolher no cliente, chame a nova RPC:

```ts
const { data, error } = await supabase.rpc('get_current_app_release_note');
// data = [] (nada a mostrar) OU [{ id, app_release_id, version_number, title, summary, content, published_at }]
const note = data?.[0] ?? null;
// se note === null, não mostra nada. Se vier, mostra (é a nota vigente ainda não confirmada por este operador).
```

Substitui aquele bloco antigo:
```ts
// REMOVER isto:
const { data: notes } = await supabase
  .from('app_release_notes')
  .select('...').eq('status','published').eq('app_releases.is_current', true).limit(1);
```

## Garantias da RPC (não precisa lógica no cliente)
- Retorna **só a nota vigente** (versão atual liberada). Nunca uma nota anterior.
- Retorna **vazio** se este operador já confirmou a nota atual.
- Operador é identificado por `auth.uid()` (sessão logada) — não envie `operator_id`.

## Confirmação (sem mudança)
Continua igual: `supabase.rpc('record_app_release_note_acknowledgement', { p_note_id: note.id, p_acknowledge: true })`.

## Realtime (sem mudança de assinatura)
Mantém a assinatura de `app_release_notes`. Só troque o handler: ao receber evento, **re-chame `get_current_app_release_note()`** e mostre o resultado (ou limpe a tela se vier vazio). Assim uma nota nova aparece uma vez, e nada antigo volta.
