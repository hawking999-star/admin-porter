create table if not exists public.app_release_notes (
  id uuid primary key default gen_random_uuid(),
  app_release_id uuid not null references public.app_releases(id) on delete cascade,
  version_number text not null,
  title text not null,
  summary text not null,
  content text not null,
  status text not null default 'draft',
  published_at timestamptz,
  created_by uuid references public.admin_users(id) on delete set null,
  updated_by uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_release_notes_release_uidx unique (app_release_id),
  constraint app_release_notes_status_check check (status in ('draft', 'published')),
  constraint app_release_notes_title_not_blank check (nullif(btrim(title), '') is not null),
  constraint app_release_notes_summary_not_blank check (nullif(btrim(summary), '') is not null),
  constraint app_release_notes_content_not_blank check (nullif(btrim(content), '') is not null),
  constraint app_release_notes_published_at_check check (status <> 'published' or published_at is not null)
);

create index if not exists app_release_notes_status_published_idx
  on public.app_release_notes (status, published_at desc);

create index if not exists app_release_notes_version_number_idx
  on public.app_release_notes (version_number);

create table if not exists public.app_notices (
  id uuid primary key default gen_random_uuid(),
  title text not null,
  message text not null,
  severity text not null default 'info',
  status text not null default 'draft',
  starts_at timestamptz,
  ends_at timestamptz,
  is_active boolean not null default false,
  audience_type text not null default 'all',
  condominium_id uuid references public.units(id) on delete set null,
  operator_id uuid references public.operators(id) on delete set null,
  shift text,
  requires_ack boolean not null default false,
  created_by uuid references public.admin_users(id) on delete set null,
  updated_by uuid references public.admin_users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_notices_title_not_blank check (nullif(btrim(title), '') is not null),
  constraint app_notices_message_not_blank check (nullif(btrim(message), '') is not null),
  constraint app_notices_severity_check check (severity in ('info', 'warning', 'critical', 'success')),
  constraint app_notices_status_check check (status in ('draft', 'active', 'expired', 'disabled')),
  constraint app_notices_audience_type_check check (audience_type in ('all', 'condominium', 'shift', 'user')),
  constraint app_notices_window_check check (ends_at is null or starts_at is null or ends_at > starts_at),
  constraint app_notices_active_status_check check (is_active = (status = 'active')),
  constraint app_notices_condominium_audience_check check (
    audience_type <> 'condominium' or condominium_id is not null
  ),
  constraint app_notices_shift_audience_check check (
    audience_type <> 'shift' or nullif(btrim(coalesce(shift, '')), '') is not null
  ),
  constraint app_notices_user_audience_check check (
    audience_type <> 'user' or operator_id is not null
  )
);

create index if not exists app_notices_status_window_idx
  on public.app_notices (status, starts_at, ends_at);

create index if not exists app_notices_severity_idx
  on public.app_notices (severity);

create index if not exists app_notices_audience_idx
  on public.app_notices (audience_type, condominium_id, operator_id, shift);

create table if not exists public.app_notice_acknowledgements (
  id uuid primary key default gen_random_uuid(),
  notice_id uuid not null references public.app_notices(id) on delete cascade,
  operator_id uuid not null references public.operators(id) on delete cascade,
  read_at timestamptz not null default now(),
  acknowledged_at timestamptz,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint app_notice_ack_notice_operator_uidx unique (notice_id, operator_id),
  constraint app_notice_ack_ack_after_read_check check (acknowledged_at is null or acknowledged_at >= read_at)
);

create index if not exists app_notice_ack_operator_idx
  on public.app_notice_acknowledgements (operator_id, read_at desc);

create or replace function public.current_operator_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select o.id
  from public.operators o
  where o.auth_user_id = (select auth.uid())
    and o.active = true
  limit 1;
$$;

create or replace function public.touch_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

create or replace function public.sync_app_release_note_metadata()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  v_release public.app_releases%rowtype;
  v_admin_id uuid;
begin
  select * into v_release
  from public.app_releases
  where id = new.app_release_id;

  if v_release.id is null then
    raise exception 'release_not_found';
  end if;

  new.version_number := v_release.version;
  v_admin_id := public.current_admin_user_id();

  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, v_admin_id);
  end if;

  new.updated_by := coalesce(v_admin_id, new.updated_by);
  new.updated_at := now();

  if new.status = 'published' and new.published_at is null then
    new.published_at := now();
  elsif new.status = 'draft' then
    new.published_at := null;
  end if;

  return new;
end;
$$;

create or replace function public.sync_app_notice_metadata()
returns trigger
language plpgsql
set search_path = public
as $$
declare
  v_admin_id uuid;
begin
  v_admin_id := public.current_admin_user_id();

  if tg_op = 'INSERT' then
    new.created_by := coalesce(new.created_by, v_admin_id);
  end if;

  new.updated_by := coalesce(v_admin_id, new.updated_by);
  new.updated_at := now();
  new.is_active := new.status = 'active';

  if new.status = 'active'
    and new.starts_at is not null
    and new.ends_at is not null
    and new.ends_at <= new.starts_at then
    raise exception 'notice_invalid_window';
  end if;

  return new;
end;
$$;

drop trigger if exists t_app_release_notes_metadata on public.app_release_notes;
create trigger t_app_release_notes_metadata
before insert or update on public.app_release_notes
for each row execute function public.sync_app_release_note_metadata();

drop trigger if exists t_app_notices_metadata on public.app_notices;
create trigger t_app_notices_metadata
before insert or update on public.app_notices
for each row execute function public.sync_app_notice_metadata();

drop trigger if exists t_app_notice_ack_updated_at on public.app_notice_acknowledgements;
create trigger t_app_notice_ack_updated_at
before update on public.app_notice_acknowledgements
for each row execute function public.touch_updated_at();

create or replace function public.upsert_app_release_note(
  p_app_release_id uuid,
  p_title text,
  p_summary text,
  p_content text,
  p_status text default 'draft'
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_note_id uuid;
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'draft');
begin
  if v_status not in ('draft', 'published') then
    raise exception 'invalid_release_note_status';
  end if;
  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'release_note_title_required';
  end if;
  if nullif(btrim(coalesce(p_summary, '')), '') is null then
    raise exception 'release_note_summary_required';
  end if;
  if nullif(btrim(coalesce(p_content, '')), '') is null then
    raise exception 'release_note_content_required';
  end if;
  if not exists (select 1 from public.app_releases where id = p_app_release_id) then
    raise exception 'release_not_found';
  end if;

  insert into public.app_release_notes (
    app_release_id, version_number, title, summary, content, status, published_at, created_by, updated_by
  )
  select
    r.id,
    r.version,
    btrim(p_title),
    btrim(p_summary),
    btrim(p_content),
    v_status,
    case when v_status = 'published' then now() else null end,
    v_admin_id,
    v_admin_id
  from public.app_releases r
  where r.id = p_app_release_id
  on conflict (app_release_id) do update
    set title = excluded.title,
        summary = excluded.summary,
        content = excluded.content,
        status = excluded.status,
        published_at = case
          when excluded.status = 'published' then coalesce(public.app_release_notes.published_at, now())
          else null
        end,
        updated_by = v_admin_id,
        updated_at = now()
  returning id into v_note_id;

  return v_note_id;
end;
$$;

create or replace function public.upsert_app_notice(
  p_notice_id uuid,
  p_title text,
  p_message text,
  p_severity text,
  p_status text,
  p_starts_at timestamptz default null,
  p_ends_at timestamptz default null,
  p_audience_type text default 'all',
  p_condominium_id uuid default null,
  p_operator_id uuid default null,
  p_shift text default null,
  p_requires_ack boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_notice_id uuid;
  v_severity text := coalesce(nullif(btrim(coalesce(p_severity, '')), ''), 'info');
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'draft');
  v_audience_type text := coalesce(nullif(btrim(coalesce(p_audience_type, '')), ''), 'all');
begin
  if nullif(btrim(coalesce(p_title, '')), '') is null then
    raise exception 'notice_title_required';
  end if;
  if nullif(btrim(coalesce(p_message, '')), '') is null then
    raise exception 'notice_message_required';
  end if;
  if v_severity not in ('info', 'warning', 'critical', 'success') then
    raise exception 'invalid_notice_severity';
  end if;
  if v_status not in ('draft', 'active', 'expired', 'disabled') then
    raise exception 'invalid_notice_status';
  end if;
  if v_audience_type not in ('all', 'condominium', 'shift', 'user') then
    raise exception 'invalid_notice_audience';
  end if;
  if p_ends_at is not null and p_starts_at is not null and p_ends_at <= p_starts_at then
    raise exception 'notice_invalid_window';
  end if;
  if v_status = 'active' and p_ends_at is not null and p_ends_at <= now() then
    raise exception 'notice_active_already_ended';
  end if;
  if v_audience_type = 'condominium' and p_condominium_id is null then
    raise exception 'notice_condominium_required';
  end if;
  if v_audience_type = 'shift' and nullif(btrim(coalesce(p_shift, '')), '') is null then
    raise exception 'notice_shift_required';
  end if;
  if v_audience_type = 'user' and p_operator_id is null then
    raise exception 'notice_operator_required';
  end if;

  if p_notice_id is null then
    insert into public.app_notices (
      title, message, severity, status, starts_at, ends_at, is_active,
      audience_type, condominium_id, operator_id, shift, requires_ack, created_by, updated_by
    ) values (
      btrim(p_title),
      btrim(p_message),
      v_severity,
      v_status,
      p_starts_at,
      p_ends_at,
      v_status = 'active',
      v_audience_type,
      case when v_audience_type = 'condominium' then p_condominium_id else null end,
      case when v_audience_type = 'user' then p_operator_id else null end,
      case when v_audience_type = 'shift' then nullif(btrim(coalesce(p_shift, '')), '') else null end,
      coalesce(p_requires_ack, false),
      v_admin_id,
      v_admin_id
    )
    returning id into v_notice_id;
  else
    update public.app_notices
    set title = btrim(p_title),
        message = btrim(p_message),
        severity = v_severity,
        status = v_status,
        starts_at = p_starts_at,
        ends_at = p_ends_at,
        is_active = v_status = 'active',
        audience_type = v_audience_type,
        condominium_id = case when v_audience_type = 'condominium' then p_condominium_id else null end,
        operator_id = case when v_audience_type = 'user' then p_operator_id else null end,
        shift = case when v_audience_type = 'shift' then nullif(btrim(coalesce(p_shift, '')), '') else null end,
        requires_ack = coalesce(p_requires_ack, false),
        updated_by = v_admin_id,
        updated_at = now()
    where id = p_notice_id
    returning id into v_notice_id;

    if v_notice_id is null then
      raise exception 'notice_not_found';
    end if;
  end if;

  return v_notice_id;
end;
$$;

create or replace function public.update_app_notice_status(p_notice_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = public
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_status text := nullif(btrim(coalesce(p_status, '')), '');
begin
  if v_status not in ('draft', 'active', 'expired', 'disabled') then
    raise exception 'invalid_notice_status';
  end if;

  update public.app_notices
  set status = v_status,
      is_active = v_status = 'active',
      ends_at = case
        when v_status = 'expired' and (ends_at is null or ends_at > now()) then now()
        else ends_at
      end,
      updated_by = v_admin_id,
      updated_at = now()
  where id = p_notice_id;

  if not found then
    raise exception 'notice_not_found';
  end if;
end;
$$;

create or replace function public.record_app_notice_acknowledgement(
  p_notice_id uuid,
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
    from public.app_notices n
    where n.id = p_notice_id
      and n.status = 'active'
      and n.is_active = true
      and (n.starts_at is null or n.starts_at <= now())
      and (n.ends_at is null or n.ends_at > now())
      and (
        n.audience_type = 'all'
        or (n.audience_type = 'condominium' and n.condominium_id = (
          select o.unit_id from public.operators o where o.id = v_operator_id
        ))
        or (n.audience_type = 'user' and n.operator_id = v_operator_id)
        or (
          n.audience_type = 'shift'
          and n.shift = (
            select case
              when lower(coalesce(s.name, '')) like '%diurno%' then 'day'
              when lower(coalesce(s.name, '')) like '%noturno%' then 'night'
              else 'other'
            end
            from public.operators o
            left join public.shifts s on s.id = o.default_shift_id
            where o.id = v_operator_id
            limit 1
          )
        )
      )
  ) then
    raise exception 'notice_not_found';
  end if;

  insert into public.app_notice_acknowledgements (
    notice_id, operator_id, read_at, acknowledged_at
  ) values (
    p_notice_id,
    v_operator_id,
    now(),
    case when coalesce(p_acknowledge, false) then now() else null end
  )
  on conflict (notice_id, operator_id) do update
    set read_at = coalesce(public.app_notice_acknowledgements.read_at, excluded.read_at),
        acknowledged_at = case
          when coalesce(p_acknowledge, false) then coalesce(public.app_notice_acknowledgements.acknowledged_at, now())
          else public.app_notice_acknowledgements.acknowledged_at
        end,
        updated_at = now()
  returning id into v_ack_id;

  return v_ack_id;
end;
$$;

alter table public.app_release_notes enable row level security;
alter table public.app_notices enable row level security;
alter table public.app_notice_acknowledgements enable row level security;

drop policy if exists app_release_notes_admin_select on public.app_release_notes;
create policy app_release_notes_admin_select
on public.app_release_notes
for select
to authenticated
using (public.is_admin());

drop policy if exists app_release_notes_operator_published_select on public.app_release_notes;
create policy app_release_notes_operator_published_select
on public.app_release_notes
for select
to authenticated
using (
  status = 'published'
  and exists (
    select 1
    from public.app_releases r
    where r.id = app_release_notes.app_release_id
      and r.status = 'released'
  )
);

drop policy if exists app_release_notes_release_admin_write on public.app_release_notes;
create policy app_release_notes_release_admin_write
on public.app_release_notes
for all
to authenticated
using (public.is_release_admin())
with check (public.is_release_admin());

drop policy if exists app_notices_admin_select on public.app_notices;
create policy app_notices_admin_select
on public.app_notices
for select
to authenticated
using (public.is_admin());

drop policy if exists app_notices_operator_active_select on public.app_notices;
create policy app_notices_operator_active_select
on public.app_notices
for select
to authenticated
using (
  status = 'active'
  and is_active = true
  and (starts_at is null or starts_at <= now())
  and (ends_at is null or ends_at > now())
  and (
    audience_type = 'all'
    or (
      audience_type = 'condominium'
      and condominium_id = (
        select o.unit_id
        from public.operators o
        where o.auth_user_id = (select auth.uid())
          and o.active = true
        limit 1
      )
    )
    or (
      audience_type = 'user'
      and operator_id = public.current_operator_id()
    )
    or (
      audience_type = 'shift'
      and shift = (
        select case
          when lower(coalesce(s.name, '')) like '%diurno%' then 'day'
          when lower(coalesce(s.name, '')) like '%noturno%' then 'night'
          else 'other'
        end
        from public.operators o
        left join public.shifts s on s.id = o.default_shift_id
        where o.auth_user_id = (select auth.uid())
          and o.active = true
        limit 1
      )
    )
  )
);

drop policy if exists app_notices_release_admin_write on public.app_notices;
create policy app_notices_release_admin_write
on public.app_notices
for all
to authenticated
using (public.is_release_admin())
with check (public.is_release_admin());

drop policy if exists app_notice_ack_admin_select on public.app_notice_acknowledgements;
create policy app_notice_ack_admin_select
on public.app_notice_acknowledgements
for select
to authenticated
using (public.is_admin());

drop policy if exists app_notice_ack_operator_select on public.app_notice_acknowledgements;
create policy app_notice_ack_operator_select
on public.app_notice_acknowledgements
for select
to authenticated
using (operator_id = public.current_operator_id());

drop policy if exists app_notice_ack_operator_insert on public.app_notice_acknowledgements;
create policy app_notice_ack_operator_insert
on public.app_notice_acknowledgements
for insert
to authenticated
with check (operator_id = public.current_operator_id());

drop policy if exists app_notice_ack_operator_update on public.app_notice_acknowledgements;
create policy app_notice_ack_operator_update
on public.app_notice_acknowledgements
for update
to authenticated
using (operator_id = public.current_operator_id())
with check (operator_id = public.current_operator_id());

revoke all on public.app_release_notes from anon;
revoke all on public.app_notices from anon;
revoke all on public.app_notice_acknowledgements from anon;

grant select, insert, update on public.app_release_notes to authenticated;
grant select, insert, update on public.app_notices to authenticated;
grant select, insert, update on public.app_notice_acknowledgements to authenticated;

revoke all on function public.current_operator_id() from public, anon;
revoke all on function public.touch_updated_at() from public, anon;
revoke all on function public.sync_app_release_note_metadata() from public, anon;
revoke all on function public.sync_app_notice_metadata() from public, anon;
revoke all on function public.upsert_app_release_note(uuid, text, text, text, text) from public, anon;
revoke all on function public.upsert_app_notice(uuid, text, text, text, text, timestamptz, timestamptz, text, uuid, uuid, text, boolean) from public, anon;
revoke all on function public.update_app_notice_status(uuid, text) from public, anon;
revoke all on function public.record_app_notice_acknowledgement(uuid, boolean) from public, anon;

grant execute on function public.current_operator_id() to authenticated;
grant execute on function public.upsert_app_release_note(uuid, text, text, text, text) to authenticated;
grant execute on function public.upsert_app_notice(uuid, text, text, text, text, timestamptz, timestamptz, text, uuid, uuid, text, boolean) to authenticated;
grant execute on function public.update_app_notice_status(uuid, text) to authenticated;
grant execute on function public.record_app_notice_acknowledgement(uuid, boolean) to authenticated;
