-- Fluxo em tempo real de avisos/notas para o app dos operadores + confirmação de
-- leitura das NOTAS de atualização (espelha app_notice_acknowledgements).
--
-- Objetivo: quando o admin publica uma nota ou ativa um aviso, ele aparece ao vivo
-- no app (sem relogar) via Supabase Realtime, e o operador pode marcar como lido/
-- aceito — o que fica registrado para o admin ver (contagens de lidas/confirmadas).

-- 1. Tabela de confirmações de leitura das notas de atualização.
create table if not exists public.app_release_note_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  note_id uuid not null references public.app_release_notes(id) on delete cascade,
  operator_id uuid not null references public.operators(id) on delete cascade,
  read_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_release_note_ack_note_operator_uidx unique (note_id, operator_id),
  constraint app_release_note_ack_ack_after_read_check check (acknowledged_at is null or acknowledged_at >= read_at)
);

create index if not exists app_release_note_ack_operator_idx
  on public.app_release_note_acknowledgements (operator_id, read_at desc);

drop trigger if exists t_app_release_note_ack_updated_at on public.app_release_note_acknowledgements;
create trigger t_app_release_note_ack_updated_at
before update on public.app_release_note_acknowledgements
for each row execute function public.touch_updated_at();

-- 2. RPC chamada pelo APP: operador confirma leitura/aceite de uma nota publicada
--    de uma versão que já está liberada. p_acknowledge=false apenas registra leitura;
--    p_acknowledge=true registra o aceite (confirmação).
create or replace function public.record_app_release_note_acknowledgement(
  p_note_id uuid,
  p_acknowledge boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_operator_id uuid := public.current_operator_id();
  v_ack_id uuid;
begin
  if v_operator_id is null then
    raise exception 'operator_not_found';
  end if;

  if not exists (
    select 1
    from public.app_release_notes n
    join public.app_releases r on r.id = n.app_release_id
    where n.id = p_note_id
      and n.status = 'published'
      and r.status = 'released'
  ) then
    raise exception 'release_note_not_found';
  end if;

  insert into public.app_release_note_acknowledgements (
    note_id, operator_id, read_at, acknowledged_at
  ) values (
    p_note_id,
    v_operator_id,
    now(),
    case when coalesce(p_acknowledge, false) then now() else null end
  )
  on conflict (note_id, operator_id) do update
    set read_at = coalesce(public.app_release_note_acknowledgements.read_at, excluded.read_at),
        acknowledged_at = case
          when coalesce(p_acknowledge, false) then coalesce(public.app_release_note_acknowledgements.acknowledged_at, now())
          else public.app_release_note_acknowledgements.acknowledged_at
        end,
        updated_at = now()
  returning id into v_ack_id;

  return v_ack_id;
end;
$$;

-- 3. RLS: admin vê tudo; operador só vê/insere/atualiza a própria confirmação.
alter table public.app_release_note_acknowledgements enable row level security;

drop policy if exists app_release_note_ack_admin_select on public.app_release_note_acknowledgements;
create policy app_release_note_ack_admin_select
on public.app_release_note_acknowledgements
for select to authenticated
using (public.is_admin());

drop policy if exists app_release_note_ack_operator_select on public.app_release_note_acknowledgements;
create policy app_release_note_ack_operator_select
on public.app_release_note_acknowledgements
for select to authenticated
using (operator_id = public.current_operator_id());

drop policy if exists app_release_note_ack_operator_insert on public.app_release_note_acknowledgements;
create policy app_release_note_ack_operator_insert
on public.app_release_note_acknowledgements
for insert to authenticated
with check (operator_id = public.current_operator_id());

drop policy if exists app_release_note_ack_operator_update on public.app_release_note_acknowledgements;
create policy app_release_note_ack_operator_update
on public.app_release_note_acknowledgements
for update to authenticated
using (operator_id = public.current_operator_id())
with check (operator_id = public.current_operator_id());

-- 4. Grants.
revoke all on public.app_release_note_acknowledgements from anon;
grant select, insert, update on public.app_release_note_acknowledgements to authenticated;

revoke all on function public.record_app_release_note_acknowledgement(uuid, boolean) from public, anon;
grant execute on function public.record_app_release_note_acknowledgement(uuid, boolean) to authenticated;

-- 5. Realtime: publica avisos e notas para o app assinar ao vivo. A RLS de SELECT
--    continua valendo por assinante (cada operador só recebe o que pode ver).
do $$
begin
  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_notices'
  ) then
    execute 'alter publication supabase_realtime add table public.app_notices';
  end if;

  if not exists (
    select 1 from pg_publication_tables
    where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'app_release_notes'
  ) then
    execute 'alter publication supabase_realtime add table public.app_release_notes';
  end if;
end $$;

-- 6. Ao LIBERAR uma versão, "toca" a nota publicada vinculada (bump updated_at) para
--    disparar um evento Realtime de UPDATE na nota no exato momento em que a versão
--    passa a ser 'released' — assim o operador recebe a nota ao vivo mesmo que ela
--    tenha sido publicada ANTES da liberação (a RLS da nota só passa após released).
create or replace function public.touch_release_note_on_release()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  if new.status = 'released' and coalesce(old.status, '') <> 'released' then
    update public.app_release_notes
      set updated_at = now()
      where app_release_id = new.id
        and status = 'published';
  end if;
  return new;
end;
$$;

drop trigger if exists t_touch_release_note_on_release on public.app_releases;
create trigger t_touch_release_note_on_release
after update of status on public.app_releases
for each row execute function public.touch_release_note_on_release();
