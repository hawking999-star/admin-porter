alter table public.app_releases
  add column if not exists blocked_by uuid,
  add column if not exists block_reason text;

update public.app_releases
set title = version
where nullif(btrim(coalesce(title, '')), '') is null;

alter table public.app_releases
  alter column title set not null;

alter table public.app_releases drop constraint if exists app_releases_version_semver_check;
alter table public.app_releases drop constraint if exists app_releases_minimum_version_semver_check;
alter table public.app_releases drop constraint if exists app_releases_title_not_blank_check;

alter table public.app_releases
  add constraint app_releases_version_semver_check
  check (version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'),
  add constraint app_releases_minimum_version_semver_check
  check (
    minimum_version is null
    or minimum_version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'
  ),
  add constraint app_releases_title_not_blank_check
  check (nullif(btrim(title), '') is not null);

do $$
begin
  if not exists (
    select 1
    from pg_constraint
    where conname = 'app_releases_blocked_by_fkey'
      and conrelid = 'public.app_releases'::regclass
  ) then
    alter table public.app_releases
      add constraint app_releases_blocked_by_fkey
      foreign key (blocked_by) references public.admin_users(id);
  end if;
end $$;

create or replace function private.app_release_required_ready(p_release public.app_releases)
returns boolean
language sql
immutable
set search_path = public
as $$
  select p_release.version is not null
     and p_release.version ~ '^[0-9]+\.[0-9]+\.[0-9]+$'
     and nullif(btrim(coalesce(p_release.title, '')), '') is not null
     and nullif(btrim(coalesce(p_release.manifest_key, '')), '') is not null
     and nullif(btrim(coalesce(p_release.installer_key, '')), '') is not null
     and nullif(btrim(coalesce(p_release.blockmap_key, '')), '') is not null
     and nullif(btrim(coalesce(p_release.sha512, '')), '') is not null
     and p_release.size_bytes is not null
     and p_release.size_bytes > 0;
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
  v_status text := coalesce(nullif(btrim(coalesce(p_status, '')), ''), 'draft');
  v_version text := nullif(btrim(coalesce(p_version, '')), '');
  v_title text := nullif(btrim(coalesce(p_title, '')), '');
  v_channel text := coalesce(nullif(btrim(coalesce(p_channel, '')), ''), 'stable');
begin
  if v_status not in ('draft', 'testing') then
    raise exception 'invalid_initial_status';
  end if;
  if v_version is null or v_version !~ '^[0-9]+\.[0-9]+\.[0-9]+$' then
    raise exception 'invalid_version';
  end if;
  if v_title is null then
    raise exception 'title_required';
  end if;

  insert into public.app_releases (
    version, channel, status, mandatory, minimum_version, title, release_notes,
    manifest_key, installer_key, blockmap_key, sha512, size_bytes, created_by
  ) values (
    v_version,
    v_channel,
    v_status,
    coalesce(p_mandatory, true),
    nullif(btrim(coalesce(p_minimum_version, '')), ''),
    v_title,
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
    jsonb_build_object('version', v_version, 'channel', v_channel)
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
  v_title text;
begin
  select * into v_before
  from public.app_releases
  where id = p_release_id
  for update;

  if v_before.id is null then
    raise exception 'release_not_found';
  end if;
  if v_before.status not in ('draft', 'testing') then
    raise exception 'release_locked';
  end if;

  v_status := coalesce(nullif(btrim(coalesce(p_status, '')), ''), v_before.status);
  if v_status not in ('draft', 'testing') then
    raise exception 'invalid_edit_status';
  end if;

  v_title := nullif(btrim(coalesce(p_title, v_before.title, '')), '');
  if v_title is null then
    raise exception 'title_required';
  end if;

  update public.app_releases
  set title = v_title,
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

create or replace function public.block_app_release(p_release_id uuid, p_reason text)
returns void
language plpgsql
security definer
set search_path = public, private
as $$
declare
  v_admin_id uuid := private.require_release_admin();
  v_release public.app_releases%rowtype;
  v_reason text := nullif(btrim(coalesce(p_reason, '')), '');
begin
  if v_reason is null then
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
      blocked_by = v_admin_id,
      blocked_at = now(),
      block_reason = v_reason,
      updated_at = now()
  where id = p_release_id;

  perform private.log_app_release_audit(
    p_release_id,
    'blocked',
    v_release.status,
    'blocked',
    v_admin_id,
    jsonb_build_object('reason', v_reason, 'was_current', v_release.is_current)
  );
end;
$$;

revoke all on function public.create_app_release(text, text, text, text, boolean, text, text, text, text, text, bigint, text) from public, anon;
revoke all on function public.update_app_release(uuid, text, text, boolean, text, text, text, text, text, bigint, text) from public, anon;
revoke all on function public.block_app_release(uuid, text) from public, anon;

grant execute on function public.create_app_release(text, text, text, text, boolean, text, text, text, text, text, bigint, text) to authenticated;
grant execute on function public.update_app_release(uuid, text, text, boolean, text, text, text, text, text, bigint, text) to authenticated;
grant execute on function public.block_app_release(uuid, text) to authenticated;
