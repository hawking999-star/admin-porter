-- Leitura da NOTA vigente para o app (Electron), à prova de "histórico".
--
-- Problema: o app buscava a nota no cliente (ex.: pegar notas não vistas,
-- ordenar por data e mostrar a primeira). Isso faz uma nota antiga reaparecer
-- depois que a mais recente é confirmada.
--
-- Correção (menor alteração, reaproveitando o contrato): uma RPC que
--   1) identifica PRIMEIRO a nota atual global (release is_current + released +
--      nota published) — nunca uma anterior;
--   2) só então checa se ESTE operador já visualizou/confirmou essa nota;
--   3) retorna a nota só se ainda não vista; senão retorna vazio.
--
-- Operador é sempre resolvido por auth.uid() (current_operator_id) — nunca por
-- operator_id vindo do cliente. Mesma forma de payload das colunas já usadas
-- pelo app (id, version_number, title, summary, content, published_at).

create or replace function public.get_current_app_release_note()
returns table (
  id uuid,
  app_release_id uuid,
  version_number text,
  title text,
  summary text,
  content text,
  published_at timestamptz
)
language sql
stable
security definer
set search_path = public
as $$
  with current_note as (
    -- Passo 1: a ÚNICA nota vigente hoje = nota publicada da versão atual
    -- (is_current) que já foi liberada. Ordenação só desempata entre canais;
    -- o índice único parcial garante 1 is_current por canal.
    select n.id, n.app_release_id, n.version_number, n.title, n.summary, n.content, n.published_at
    from public.app_release_notes n
    join public.app_releases r on r.id = n.app_release_id
    where n.status = 'published'
      and r.status = 'released'
      and r.is_current = true
    order by r.released_at desc nulls last, n.published_at desc nulls last
    limit 1
  )
  -- Passo 2 e 3: devolve a nota atual só se este operador ainda não a viu.
  select cn.id, cn.app_release_id, cn.version_number, cn.title, cn.summary, cn.content, cn.published_at
  from current_note cn
  where public.current_operator_id() is not null
    and not exists (
      select 1
      from public.app_release_note_acknowledgements a
      where a.note_id = cn.id
        and a.operator_id = public.current_operator_id()
    );
$$;

revoke all on function public.get_current_app_release_note() from public, anon;
grant execute on function public.get_current_app_release_note() to authenticated;
