# Prompt para o dev do app dos operadores — Avisos e Notas em tempo real

## Objetivo do fluxo

Quando o admin **publica uma nota de atualização** ou **ativa um aviso**, ele deve
aparecer **na hora** no app do operador, **sem relogar**. O operador vê o conteúdo,
marca em uma **caixa de "li / confirmo"** e essa confirmação fica **registrada para o
admin** (o admin já mostra contagem de "Lidas" e "Confirmadas").

Remover do app o **botão manual de "aviso de atualização"**. Não deve haver botão para
o operador buscar aviso/nota — a entrega é automática via Supabase Realtime.

O admin **não muda** por conta do app: ele só grava nas tabelas. Todo o backend abaixo
já está criado e com RLS. Você só precisa consumir.

---

## Autenticação (pré-requisito)

O app já loga o operador via Supabase Auth. As políticas de RLS usam:
`auth.uid()` → `operators.auth_user_id` (operador `active = true`).
Use o **mesmo cliente Supabase autenticado** para o Realtime e para as RPCs — a RLS
filtra automaticamente o que cada operador pode ver. Você **não precisa** filtrar
audiência (todos / condomínio / turno / operador) no cliente: a RLS já faz isso.

---

## Modelo de dados (somente o que o app usa)

### `app_notices` — avisos (independentes de versão)
Campos relevantes: `id`, `title`, `message`, `severity` (`info` | `warning` |
`critical` | `success`), `status` (`draft` | `active` | `expired` | `disabled`),
`starts_at`, `ends_at`, `is_active`, `audience_type`, `requires_ack` (bool).

RLS do operador: só enxerga avisos **ativos e vigentes** para ele:
`status = 'active' and is_active = true` e dentro da janela `starts_at`/`ends_at` e
compatível com a audiência. Ou seja: **se o SELECT retornou, é para mostrar.**

### `app_release_notes` — notas de atualização (sempre ligadas a uma versão)
Campos relevantes: `id`, `app_release_id`, `version_number`, `title`, `summary`,
`content`, `status` (`draft` | `published`), `published_at`.

RLS do operador: só enxerga notas **publicadas de versões já liberadas**
(`status = 'published'` e a versão em `app_releases.status = 'released'`).
De novo: **se o SELECT retornou, é para mostrar.**

> `content` vem em blocos de texto separados por linha em branco, com títulos
> `Novidades`, `Correções`, `Observações`. Pode renderizar como texto puro
> (whitespace-pre-wrap) ou dividir por esses rótulos.

---

## Confirmação de leitura (RPCs) — é isso que "registra no admin"

Chame via `supabase.rpc(...)` com o operador autenticado.

### Aviso
```ts
await supabase.rpc('record_app_notice_acknowledgement', {
  p_notice_id: notice.id,
  p_acknowledge: true, // true = confirmou/aceitou; false = só marca "lido"
});
```

### Nota de atualização
```ts
await supabase.rpc('record_app_release_note_acknowledgement', {
  p_note_id: note.id,
  p_acknowledge: true,
});
```

Regras:
- `p_acknowledge: false` registra **leitura** (aparece em "Lidas" no admin).
- `p_acknowledge: true` registra **confirmação/aceite** (aparece em "Confirmadas").
- Idempotente (upsert por operador): pode chamar de novo sem duplicar.
- Só funciona se o aviso/nota estiver realmente visível para o operador (ativo /
  publicado+liberado). Caso contrário retorna erro (veja abaixo).

**UX sugerida:** ao renderizar, chame com `false` (marca lido). A caixa "Li e confirmo"
chama com `true`. Para avisos com `requires_ack = true`, só deixe o operador dispensar
depois de confirmar.

---

## Realtime — assinar avisos e notas ao vivo

As tabelas `app_notices` e `app_release_notes` já estão na publication
`supabase_realtime`. A RLS vale por assinante: cada operador só recebe os eventos que
pode ver.

```ts
const channel = supabase
  .channel('operator-updates')
  .on('postgres_changes',
    { event: '*', schema: 'public', table: 'app_notices' },
    (payload) => handleNoticeChange(payload.new, payload.eventType))
  .on('postgres_changes',
    { event: '*', schema: 'public', table: 'app_release_notes' },
    (payload) => handleNoteChange(payload.new, payload.eventType))
  .subscribe();

// ao deslogar / desmontar:
supabase.removeChannel(channel);
```

`payload.new` traz a linha nova (INSERT/UPDATE). Ao receber um evento, atualize a UI:
mostre o aviso/nota. Se um aviso mudar para `disabled`/`expired`, o operador deixa de
ter permissão de vê-lo — trate `UPDATE` cujo novo estado não é mais "ativo" removendo-o
da tela (ou simplesmente re-busque, veja abaixo).

> Importante sobre notas: ao **liberar** uma versão, um trigger no banco "toca" a nota
> publicada dela (`updated_at = now()`), disparando um `UPDATE` no Realtime **no exato
> momento da liberação**. Então a nota chega ao vivo mesmo que tenha sido publicada
> antes de a versão ser liberada.

---

## Carga inicial (ao abrir o app / logar)

O Realtime só entrega o que muda **depois** de assinar. Então, ao iniciar, faça **uma
busca inicial** do que já está vigente (a RLS já filtra):

```ts
// Avisos ativos para este operador
const { data: notices } = await supabase
  .from('app_notices')
  .select('id, title, message, severity, requires_ack, starts_at, ends_at')
  .eq('status', 'active')
  .order('severity', { ascending: false });

// Nota publicada da versão atual liberada
const { data: notes } = await supabase
  .from('app_release_notes')
  .select('id, title, summary, content, version_number, published_at, app_releases!inner(version, is_current, released_at)')
  .eq('status', 'published')
  .eq('app_releases.is_current', true)
  .limit(1);
```

Fluxo recomendado: **1) busca inicial → 2) assina o Realtime**. Mesclar os dois no
mesmo estado (dedupe por `id`).

---

## Erros das RPCs (mensagens `raise exception`)

Trate e traduza para o operador:

- `operator_not_found` — sessão sem operador ativo (deslogar/relogar).
- `notice_not_found` — aviso não está mais ativo/visível (remover da tela).
- `release_note_not_found` — nota não está mais publicada/liberada (remover da tela).

---

## Checklist de aceite

- [ ] Removido o botão manual de "aviso de atualização" do app.
- [ ] Ao abrir o app: busca inicial de avisos ativos + nota da versão atual.
- [ ] Assinatura Realtime de `app_notices` e `app_release_notes` com o cliente logado.
- [ ] Aviso/nota novo aparece **sem relogar**.
- [ ] Caixa "Li e confirmo" chama a RPC de ack correspondente (`p_acknowledge: true`).
- [ ] Avisos com `requires_ack = true` só somem após confirmar.
- [ ] Ao sair, `removeChannel` para não vazar assinatura.

## O que NÃO precisa fazer

- Não precisa filtrar audiência (todos/condomínio/turno/operador) no cliente — a RLS faz.
- Não precisa endpoint novo no admin — tudo é Supabase (tabelas + RPCs + Realtime).
- Não precisa service_role no app — tudo roda como `authenticated`.
