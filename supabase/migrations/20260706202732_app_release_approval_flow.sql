create schema if not exists private;

do $$
begin
  if to_regclass('public.app_releases') is null and to_regclass('public.app_versions') is not null then
    alter table public.app_versions rename to app_releases;
  end if;
end $$;

create table if not exists public.app_releases (
  id uuid primary key default gen_random_uuid(),
  version text not null,
  platform text not null default 'win32-x64',
  channel text not null default 'stable',
  status text not null default 'draft',
  is_current boolean not null default false,
  mandatory boolean not null default true,
  minimum_version text,
  title text,
  release_notes text,
  manifest_key text,
  installer_key text,
  blockmap_key text,
  sha512 text,
  size_bytes bigint,
  created_by uuid,
  approved_by uuid,
  released_by uuid,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  approved_at timestamptz,
  released_at timestamptz,
  blocked_at timestamptz
);

alter table public.app_releases
  add column if not exists platform text not null default 'win32-x64',
  add column if not exists is_current boolean not null default false,
  add column if not exists mandatory boolean not null default true,
  add column if not exists minimum_version text,
  add column if not exists title text,
  add column if not exists manifest_key text,
  add column if not exists installer_key text,
  add column if not exists blockmap_key text,
  add column if not exists sha512 text,
  add column if not exists size_bytes bigint,
  add column if not exists created_by uuid,
  add column if not exists approved_by uuid,
  add column if not exists released_by uuid,
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists approved_at timestamptz,
  add column if not exists blocked_at timestamptz;

do $$
begin
  if exists (
    select 1
    from information_schema.columns
    where table_schema = 'public'
      and table_name = 'app_releases'
      and column_name = 'release_notes'
      and data_type = 'jsonb'
  ) then
    alter table public.app_releases
      alter column release_notes drop default;

    alter table public.app_releases
      alter column release_notes type text
      using case
        when release_notes is null or release_notes = '{}'::jsonb then null
        when jsonb_typeof(release_notes) = 'string' then trim(both '"' from release_notes::text)
        else release_notes::text
      end;
  end if;
end $$;

alter table public.app_releases
  alter column release_notes drop default;

alter table public.app_releases
  alter column channel set default 'stable',
  alter column status set default 'draft',
  alter column created_at set default now();

alter table public.app_releases drop constraint if exists app_versions_status_check;
alter table public.app_releases drop constraint if exists app_versions_version_platform_channel_key;
alter table public.app_releases drop constraint if exists app_releases_status_check;
alter table public.app_releases drop constraint if exists app_releases_version_semver_check;
alter table public.app_releases drop constraint if exists app_releases_minimum_version_semver_check;
alter table public.app_releases drop constraint if exists app_releases_size_bytes_check;

alter table public.app_releases
  add constraint app_releases_status_check
  check (status = any (array['draft','testing','approved','released','blocked','superseded'])),
  add constraint app_releases_version_semver_check
  check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'),
  add constraint app_releases_minimum_version_semver_check
  check (
    minimum_version is null
    or minimum_version ~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
  ),
  add constraint app_releases_size_bytes_check
  check (size_bytes is null or size_bytes > 0);

do $$
begin
  if not exists (
    select 1 from pg_constraint
    where conname = 'app_releases_created_by_fkey'
      and conrelid = 'public.app_releases'::regclass
  ) then
    alter table public.app_releases
      add constraint app_releases_created_by_fkey
      foreign key (created_by) references public.admin_users(id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'app_releases_approved_by_fkey'
      and conrelid = 'public.app_releases'::regclass
  ) then
    alter table public.app_releases
      add constraint app_releases_approved_by_fkey
      foreign key (approved_by) references public.admin_users(id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'app_releases_released_by_fkey'
      and conrelid = 'public.app_releases'::regclass
  ) then
    alter table public.app_releases
      add constraint app_releases_released_by_fkey
      foreign key (released_by) references public.admin_users(id);
  end if;

  if not exists (
    select 1 from pg_constraint
    where conname = 'app_releases_version_key'
      and conrelid = 'public.app_releases'::regclass
  ) then
    alter table public.app_releases
      add constraint app_releases_version_key unique (version);
  end if;
end $$;

create unique index if not exists app_releases_current_channel_uidx
  on public.app_releases (channel)
  where is_current = true;

create index if not exists app_releases_channel_status_idx
  on public.app_releases (channel, status, released_at desc);

create index if not exists app_releases_created_at_idx
  on public.app_releases (created_at desc);

with ranked as (
  select
    id,
    row_number() over (
      partition by channel
      order by released_at desc nulls last, created_at desc
    ) as rn
  from public.app_releases
  where status = 'released'
)
update public.app_releases r
set is_current = ranked.rn = 1
from ranked
where r.id = ranked.id;

create table if not exists public.app_release_audit (
  id uuid primary key default gen_random_uuid(),
  release_id uuid references public.app_releases(id) on delete set null,
  action text not null,
  previous_status text,
  new_status text,
  actor_id uuid references public.admin_users(id),
  metadata jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now(),
  constraint app_release_audit_action_check
    check (action = any (array['created','edited','approved','released','blocked','rollback','superseded']))
);

create index if not exists app_release_audit_release_created_idx
  on public.app_release_audit (release_id, created_at desc);

create or replace function public.current_admin_user_id()
returns uuid
language sql
stable
security definer
set search_path = public
as $$
  select a.id
  from public.admin_users a
  where a.auth_user_id = auth.uid()
    and a.active = true
  limit 1;
$$;

create or replace function public.is_release_admin()
returns boolean
language sql
stable
security definer
set search_path = public
as $$
  select exists (
    select 1
    from public.admin_users a
    where a.auth_user_id = auth.uid()
      and a.active = true
      and a.role in ('superadmin', 'release_manager')
  );
$$;

create or replace function private.app_release_required_ready(p_release public.app_releases)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_release.version is not null
     and p_release.version ~ '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?(\+[0-9A-Za-z.-]+)?$'
     and nullif(btrim(coalesce(p_release.manifest_key, '')), '') is not null
     and nullif(btrim(coalesce(p_release.installer_key, '')), '') is not null
     and nullif(btrim(coalesce(p_release.blockmap_key, '')), '') is not null
     and nullif(btrim(coalesce(p_release.sha512, '')), '') is not null
     and p_release.size_bytes is not null
     and p_release.size_bytes > 0;
$$;

create or replace function private.log_app_release_audit(
  p_release_id uuid,
  p_action text,
  p_previous_status text,
  p_new_status text,
  p_actor_id uuid,
  p_metadata jsonb default '{}'::jsonb
)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
begin
  insert into public.app_release_audit (
    release_id, action, previous_status, new_status, actor_id, metadata
  ) values (
    p_release_id,
    p_action,
    p_previous_status,
    p_new_status,
    p_actor_id,
    coalesce(p_metadata, '{}'::jsonb)
  );

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, reason, occurred_at
  ) values (
    p_actor_id,
    'app_release_' || p_action,
    'app_release',
    p_release_id,
    jsonb_build_object('status', p_previous_status),
    jsonb_build_object('status', p_new_status, 'metadata', coalesce(p_metadata, '{}'::jsonb)),
    nullif(coalesce(p_metadata->>'reason', ''), ''),
    now()
  );
end;
$$;

create or replace function private.require_release_admin()
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_admin_id uuid;
begin
  select public.current_admin_user_id() into v_admin_id;
  if v_admin_id is null or not public.is_release_admin() then
    raise exception 'forbidden';
  end if;
  return v_admin_id;
end;
$$;

create or replace function public.create_app_release(
  p_version text,
  p_title text default null,
  p_release_notes text default null,
  p_channel text default 'stable',
  p_mandatory boolean default true,
  p_minimum_version text default null,
  p_manifest_key text default null,
  p_installer_key text default null,
  p_blockmap_key text default null,
  p_sha512 text default null,
  p_size_bytes bigint default null,
  p_status text default 'draft'
)
returns uuid
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_release_id uuid;
  v_status text := coalesce(nullif(p_status, ''), 'draft');
begin
  if v_status not in ('draft', 'testing') then
    raise exception 'invalid_initial_status';
  end if;

  insert into public.app_releases (
    version, channel, status, mandatory, minimum_version, title, release_notes,
    manifest_key, installer_key, blockmap_key, sha512, size_bytes, created_by
  ) values (
    btrim(p_version),
    coalesce(nullif(btrim(p_channel), ''), 'stable'),
    v_status,
    coalesce(p_mandatory, true),
    nullif(btrim(coalesce(p_minimum_version, '')), ''),
    nullif(btrim(coalesce(p_title, '')), ''),
    nullif(btrim(coalesce(p_release_notes, '')), ''),
    nullif(btrim(coalesce(p_manifest_key, '')), ''),
    nullif(btrim(coalesce(p_installer_key, '')), ''),
    nullif(btrim(coalesce(p_blockmap_key, '')), ''),
    nullif(btrim(coalesce(p_sha512, '')), ''),
    p_size_bytes,
    v_admin_id
  )
  returning id into v_release_id;

  perform private.log_app_release_audit(
    v_release_id,
    'created',
    null,
    v_status,
    v_admin_id,
    jsonb_build_object('version', btrim(p_version), 'channel', coalesce(nullif(btrim(p_channel), ''), 'stable'))
  );

  return v_release_id;
end;
$$;

create or replace function public.update_app_release(
  p_release_id uuid,
  p_title text default null,
  p_release_notes text default null,
  p_mandatory boolean default null,
  p_minimum_version text default null,
  p_manifest_key text default null,
  p_installer_key text default null,
  p_blockmap_key text default null,
  p_sha512 text default null,
  p_size_bytes bigint default null,
  p_status text default null
)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_before public.app_releases%rowtype;
  v_after public.app_releases%rowtype;
  v_status text;
begin
  select * into v_before
  from public.app_releases
  where id = p_release_id
  for update;

  if v_before.id is null then
    raise exception 'release_not_found';
  end if;

  if v_before.status in ('released', 'blocked', 'superseded') then
    raise exception 'release_locked';
  end if;

  v_status := coalesce(nullif(p_status, ''), v_before.status);
  if v_status not in ('draft', 'testing', 'approved') then
    raise exception 'invalid_edit_status';
  end if;

  update public.app_releases
  set title = nullif(btrim(coalesce(p_title, title, '')), ''),
      release_notes = nullif(btrim(coalesce(p_release_notes, release_notes, '')), ''),
      mandatory = coalesce(p_mandatory, mandatory),
      minimum_version = nullif(btrim(coalesce(p_minimum_version, minimum_version, '')), ''),
      manifest_key = nullif(btrim(coalesce(p_manifest_key, manifest_key, '')), ''),
      installer_key = nullif(btrim(coalesce(p_installer_key, installer_key, '')), ''),
      blockmap_key = nullif(btrim(coalesce(p_blockmap_key, blockmap_key, '')), ''),
      sha512 = nullif(btrim(coalesce(p_sha512, sha512, '')), ''),
      size_bytes = coalesce(p_size_bytes, size_bytes),
      status = v_status,
      updated_at = now()
  where id = p_release_id
  returning * into v_after;

  perform private.log_app_release_audit(
    p_release_id,
    'edited',
    v_before.status,
    v_after.status,
    v_admin_id,
    jsonb_build_object('version', v_after.version, 'channel', v_after.channel)
  );
end;
$$;

create or replace function public.approve_app_release(p_release_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_release public.app_releases%rowtype;
begin
  select * into v_release
  from public.app_releases
  where id = p_release_id
  for update;

  if v_release.id is null then
    raise exception 'release_not_found';
  end if;
  if v_release.status not in ('draft', 'testing') then
    raise exception 'invalid_release_status';
  end if;
  if not private.app_release_required_ready(v_release) then
    raise exception 'release_required_fields_missing';
  end if;

  update public.app_releases
  set status = 'approved',
      approved_by = v_admin_id,
      approved_at = now(),
      updated_at = now()
  where id = p_release_id;

  perform private.log_app_release_audit(
    p_release_id,
    'approved',
    v_release.status,
    'approved',
    v_admin_id,
    jsonb_build_object('version', v_release.version, 'channel', v_release.channel)
  );
end;
$$;

create or replace function public.release_app_release(p_release_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_release public.app_releases%rowtype;
  v_previous public.app_releases%rowtype;
begin
  select * into v_release
  from public.app_releases
  where id = p_release_id
  for update;

  if v_release.id is null then
    raise exception 'release_not_found';
  end if;
  if v_release.status <> 'approved' then
    raise exception 'only_approved_release_can_be_released';
  end if;
  if not private.app_release_required_ready(v_release) then
    raise exception 'release_required_fields_missing';
  end if;

  perform pg_advisory_xact_lock(hashtext('app_release:' || v_release.channel));

  for v_previous in
    select *
    from public.app_releases
    where channel = v_release.channel
      and is_current = true
      and id <> p_release_id
    for update
  loop
    update public.app_releases
    set is_current = false,
        status = 'superseded',
        updated_at = now()
    where id = v_previous.id;

    perform private.log_app_release_audit(
      v_previous.id,
      'superseded',
      v_previous.status,
      'superseded',
      v_admin_id,
      jsonb_build_object('superseded_by', p_release_id, 'channel', v_release.channel)
    );
  end loop;

  update public.app_releases
  set status = 'released',
      is_current = true,
      released_by = v_admin_id,
      released_at = now(),
      updated_at = now()
  where id = p_release_id;

  update public.app_release_rules
  set latest_version = v_release.version,
      minimum_version = coalesce(v_release.minimum_version, minimum_version, v_release.version),
      update_policy = case when v_release.mandatory then 'required' else 'optional' end,
      active = true,
      updated_at = now()
  where scope_type = 'global'
    and scope_id is null
    and platform = v_release.platform
    and channel = v_release.channel;

  if not found then
    insert into public.app_release_rules (
      scope_type, scope_id, platform, channel, minimum_version, latest_version, update_policy, active, priority
    ) values (
      'global',
      null,
      v_release.platform,
      v_release.channel,
      coalesce(v_release.minimum_version, v_release.version),
      v_release.version,
      case when v_release.mandatory then 'required' else 'optional' end,
      true,
      10
    );
  end if;

  perform private.log_app_release_audit(
    p_release_id,
    'released',
    'approved',
    'released',
    v_admin_id,
    jsonb_build_object('version', v_release.version, 'channel', v_release.channel)
  );
end;
$$;

create or replace function public.block_app_release(p_release_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_release public.app_releases%rowtype;
begin
  if nullif(btrim(coalesce(p_reason, '')), '') is null then
    raise exception 'block_reason_required';
  end if;

  select * into v_release
  from public.app_releases
  where id = p_release_id
  for update;

  if v_release.id is null then
    raise exception 'release_not_found';
  end if;
  if v_release.status in ('blocked', 'superseded') then
    raise exception 'invalid_release_status';
  end if;

  update public.app_releases
  set status = 'blocked',
      is_current = false,
      blocked_at = now(),
      updated_at = now()
  where id = p_release_id;

  perform private.log_app_release_audit(
    p_release_id,
    'blocked',
    v_release.status,
    'blocked',
    v_admin_id,
    jsonb_build_object('reason', btrim(p_reason), 'was_current', v_release.is_current)
  );
end;
$$;

create or replace function public.rollback_app_release(p_target_release_id uuid)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_target public.app_releases%rowtype;
  v_previous public.app_releases%rowtype;
begin
  select * into v_target
  from public.app_releases
  where id = p_target_release_id
  for update;

  if v_target.id is null then
    raise exception 'release_not_found';
  end if;
  if v_target.status not in ('released', 'superseded') then
    raise exception 'rollback_target_not_released';
  end if;
  if not private.app_release_required_ready(v_target) then
    raise exception 'rollback_target_invalid';
  end if;

  perform pg_advisory_xact_lock(hashtext('app_release:' || v_target.channel));

  for v_previous in
    select *
    from public.app_releases
    where channel = v_target.channel
      and is_current = true
      and id <> p_target_release_id
    for update
  loop
    update public.app_releases
    set is_current = false,
        status = 'superseded',
        updated_at = now()
    where id = v_previous.id;

    perform private.log_app_release_audit(
      v_previous.id,
      'superseded',
      v_previous.status,
      'superseded',
      v_admin_id,
      jsonb_build_object('rollback_to', p_target_release_id, 'channel', v_target.channel)
    );
  end loop;

  update public.app_releases
  set status = 'released',
      is_current = true,
      released_by = v_admin_id,
      released_at = now(),
      updated_at = now()
  where id = p_target_release_id;

  update public.app_release_rules
  set latest_version = v_target.version,
      minimum_version = coalesce(v_target.minimum_version, minimum_version, v_target.version),
      update_policy = case when v_target.mandatory then 'required' else 'optional' end,
      active = true,
      updated_at = now()
  where scope_type = 'global'
    and scope_id is null
    and platform = v_target.platform
    and channel = v_target.channel;

  perform private.log_app_release_audit(
    p_target_release_id,
    'rollback',
    v_target.status,
    'released',
    v_admin_id,
    jsonb_build_object('version', v_target.version, 'channel', v_target.channel)
  );
end;
$$;

create or replace function public.prevent_released_app_release_file_changes()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  if old.status = 'released' and (
    old.version is distinct from new.version
    or old.manifest_key is distinct from new.manifest_key
    or old.installer_key is distinct from new.installer_key
    or old.blockmap_key is distinct from new.blockmap_key
    or old.sha512 is distinct from new.sha512
    or old.size_bytes is distinct from new.size_bytes
  ) then
    raise exception 'released_release_files_are_immutable';
  end if;
  return new;
end;
$$;

create or replace function public.touch_app_release_updated_at()
returns trigger
language plpgsql
set search_path = public
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

drop trigger if exists t_app_releases_immutable_files on public.app_releases;
create trigger t_app_releases_immutable_files
before update on public.app_releases
for each row execute function public.prevent_released_app_release_file_changes();

drop trigger if exists t_app_releases_updated_at on public.app_releases;
create trigger t_app_releases_updated_at
before update on public.app_releases
for each row execute function public.touch_app_release_updated_at();

alter table public.app_releases enable row level security;
alter table public.app_release_audit enable row level security;

drop policy if exists admin_all on public.app_releases;
drop policy if exists app_releases_admin_select on public.app_releases;
drop policy if exists app_releases_release_admin_write on public.app_releases;
create policy app_releases_admin_select
on public.app_releases
for select
to authenticated
using (public.is_admin());

create policy app_releases_release_admin_write
on public.app_releases
for all
to authenticated
using (public.is_release_admin())
with check (public.is_release_admin());

drop policy if exists app_release_audit_admin_select on public.app_release_audit;
create policy app_release_audit_admin_select
on public.app_release_audit
for select
to authenticated
using (public.is_admin());

revoke all on public.app_releases from anon;
revoke all on public.app_release_audit from anon;
grant select on public.app_releases to authenticated;
grant select on public.app_release_audit to authenticated;

revoke all on function public.current_admin_user_id() from public, anon;
revoke all on function public.is_release_admin() from public, anon;
revoke all on function private.app_release_required_ready(public.app_releases) from public, anon, authenticated;
revoke all on function private.log_app_release_audit(uuid, text, text, text, uuid, jsonb) from public, anon, authenticated;
revoke all on function private.require_release_admin() from public, anon, authenticated;

grant execute on function public.current_admin_user_id() to authenticated;
grant execute on function public.is_release_admin() to authenticated;

revoke all on function public.create_app_release(text, text, text, text, boolean, text, text, text, text, text, bigint, text) from public, anon;
revoke all on function public.update_app_release(uuid, text, text, boolean, text, text, text, text, text, bigint, text) from public, anon;
revoke all on function public.approve_app_release(uuid) from public, anon;
revoke all on function public.release_app_release(uuid) from public, anon;
revoke all on function public.block_app_release(uuid, text) from public, anon;
revoke all on function public.rollback_app_release(uuid) from public, anon;

grant execute on function public.create_app_release(text, text, text, text, boolean, text, text, text, text, text, bigint, text) to authenticated;
grant execute on function public.update_app_release(uuid, text, text, boolean, text, text, text, text, text, bigint, text) to authenticated;
grant execute on function public.approve_app_release(uuid) to authenticated;
grant execute on function public.release_app_release(uuid) to authenticated;
grant execute on function public.block_app_release(uuid, text) to authenticated;
grant execute on function public.rollback_app_release(uuid) to authenticated;

do $$
begin
  if to_regclass('public.app_versions') is null then
    execute $view$
      create view public.app_versions
      with (security_invoker = true)
      as
      select
        id,
        version,
        platform,
        channel,
        status,
        case
          when release_notes is null or release_notes = '' then '{}'::jsonb
          else jsonb_build_object('text', release_notes)
        end as release_notes,
        manifest_key as artifact_uri,
        sha512 as artifact_hash,
        null::text as signature,
        released_at,
        created_at
      from public.app_releases
    $view$;
    grant select on public.app_versions to authenticated;
  end if;
end $$;
