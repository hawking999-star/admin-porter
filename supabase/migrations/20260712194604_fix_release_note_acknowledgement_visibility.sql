-- A visualização (p_acknowledge = false) não encerra a pendência da nota.
-- Somente a confirmação explícita deve removê-la da consulta do Operador.
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
    select n.id, n.app_release_id, n.version_number, n.title, n.summary, n.content, n.published_at
    from public.app_release_notes n
    join public.app_releases r on r.id = n.app_release_id
    where n.status = 'published'
      and r.status = 'released'
      and r.is_current = true
    order by r.released_at desc nulls last, n.published_at desc nulls last
    limit 1
  )
  select cn.id, cn.app_release_id, cn.version_number, cn.title, cn.summary, cn.content, cn.published_at
  from current_note cn
  where public.current_operator_id() is not null
    and not exists (
      select 1
      from public.app_release_note_acknowledgements a
      where a.note_id = cn.id
        and a.operator_id = public.current_operator_id()
        and a.acknowledged_at is not null
    );
$$;

revoke all on function public.get_current_app_release_note() from public, anon;
grant execute on function public.get_current_app_release_note() to authenticated;
