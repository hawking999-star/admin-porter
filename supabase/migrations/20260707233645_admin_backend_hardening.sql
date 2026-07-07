create schema if not exists private;

create or replace function private.require_admin_for_backend(
  p_allowed_roles text[] default null,
  p_unit_id uuid default null
)
returns public.admin_users
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'acesso_negado';
  end if;

  if p_allowed_roles is not null and not (v_admin.role = any(p_allowed_roles)) then
    raise exception 'permissao_insuficiente';
  end if;

  if p_unit_id is not null
     and not public.is_superadmin()
     and not public.admin_can_manage_operator_unit(p_unit_id) then
    raise exception 'fora_do_escopo_da_unidade';
  end if;

  return v_admin;
end;
$$;

create or replace function public.admin_create_operator(
  p_auth_user_id uuid,
  p_display_name text,
  p_username text,
  p_unit_id uuid,
  p_role text,
  p_session_policy text,
  p_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_display_name text := nullif(btrim(coalesce(p_display_name, '')), '');
  v_username text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    p_unit_id
  );

  if p_auth_user_id is null then
    raise exception 'auth_user_required';
  end if;

  if v_display_name is null then
    raise exception 'display_name_required';
  end if;

  if v_username is null then
    raise exception 'username_required';
  end if;

  if v_username !~ '^[a-z0-9._-]{3,60}$' then
    raise exception 'username_invalid';
  end if;

  if p_role not in ('operador', 'supervisor') then
    raise exception 'operator_role_invalid';
  end if;

  if p_session_policy not in ('single', 'multi') then
    raise exception 'session_policy_invalid';
  end if;

  if not exists (select 1 from public.units where id = p_unit_id and active = true) then
    raise exception 'unit_not_found_or_inactive';
  end if;

  insert into public.operators (
    auth_user_id,
    display_name,
    username,
    unit_id,
    role,
    session_policy,
    active
  ) values (
    p_auth_user_id,
    v_display_name,
    v_username,
    p_unit_id,
    p_role,
    p_session_policy,
    coalesce(p_active, true)
  )
  returning * into v_operator;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data, occurred_at
  ) values (
    v_admin.id,
    'operator_created',
    'operator',
    v_operator.id,
    jsonb_build_object(
      'display_name', v_operator.display_name,
      'username', v_operator.username,
      'unit_id', v_operator.unit_id,
      'role', v_operator.role,
      'session_policy', v_operator.session_policy,
      'active', v_operator.active,
      'auth_user_id', v_operator.auth_user_id
    ),
    now()
  );

  return v_operator.id;
end;
$$;

create or replace function public.admin_update_operator(
  p_operator uuid,
  p_display_name text,
  p_username text,
  p_unit_id uuid,
  p_role text,
  p_session_policy text,
  p_active boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_before public.operators%rowtype;
  v_after public.operators%rowtype;
  v_display_name text := nullif(btrim(coalesce(p_display_name, '')), '');
  v_username text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  select * into v_before
  from public.operators
  where id = p_operator
  for update;

  if v_before.id is null then
    raise exception 'operator_not_found';
  end if;

  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    v_before.unit_id
  );

  perform private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    p_unit_id
  );

  if v_display_name is null then
    raise exception 'display_name_required';
  end if;

  if v_username is not null and v_username !~ '^[a-z0-9._-]{3,60}$' then
    raise exception 'username_invalid';
  end if;

  if p_role not in ('operador', 'supervisor') then
    raise exception 'operator_role_invalid';
  end if;

  if p_session_policy not in ('single', 'multi') then
    raise exception 'session_policy_invalid';
  end if;

  if not exists (select 1 from public.units where id = p_unit_id and active = true) then
    raise exception 'unit_not_found_or_inactive';
  end if;

  update public.operators
  set display_name = v_display_name,
      username = v_username,
      unit_id = p_unit_id,
      role = p_role,
      session_policy = p_session_policy,
      active = coalesce(p_active, active),
      updated_at = now()
  where id = p_operator
  returning * into v_after;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    case
      when v_before.active is distinct from v_after.active then 'operator_status_changed'
      else 'operator_updated'
    end,
    'operator',
    p_operator,
    jsonb_build_object(
      'display_name', v_before.display_name,
      'username', v_before.username,
      'unit_id', v_before.unit_id,
      'role', v_before.role,
      'session_policy', v_before.session_policy,
      'active', v_before.active
    ),
    jsonb_build_object(
      'display_name', v_after.display_name,
      'username', v_after.username,
      'unit_id', v_after.unit_id,
      'role', v_after.role,
      'session_policy', v_after.session_policy,
      'active', v_after.active
    ),
    now()
  );
end;
$$;

create or replace function public.admin_update_admin_user(
  p_admin_user uuid,
  p_display_name text,
  p_role text,
  p_active boolean,
  p_mfa_required boolean
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_before public.admin_users%rowtype;
  v_after public.admin_users%rowtype;
  v_display_name text := nullif(btrim(coalesce(p_display_name, '')), '');
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  if v_display_name is null then
    raise exception 'display_name_required';
  end if;

  if p_role not in (
    'superadmin',
    'unit_manager',
    'operations_manager',
    'content_manager',
    'challenge_manager',
    'release_manager',
    'auditor',
    'support_readonly'
  ) then
    raise exception 'admin_role_invalid';
  end if;

  select * into v_before
  from public.admin_users
  where id = p_admin_user
  for update;

  if v_before.id is null then
    raise exception 'admin_user_not_found';
  end if;

  if v_before.id = v_admin.id and coalesce(p_active, true) = false then
    raise exception 'cannot_deactivate_own_admin';
  end if;

  update public.admin_users
  set display_name = v_display_name,
      role = p_role,
      active = coalesce(p_active, active),
      mfa_required = coalesce(p_mfa_required, mfa_required)
  where id = p_admin_user
  returning * into v_after;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    case
      when v_before.active is distinct from v_after.active then 'admin_user_status_changed'
      else 'admin_user_updated'
    end,
    'admin_user',
    p_admin_user,
    jsonb_build_object(
      'display_name', v_before.display_name,
      'role', v_before.role,
      'active', v_before.active,
      'mfa_required', v_before.mfa_required
    ),
    jsonb_build_object(
      'display_name', v_after.display_name,
      'role', v_after.role,
      'active', v_after.active,
      'mfa_required', v_after.mfa_required
    ),
    now()
  );
end;
$$;

create or replace function public.admin_create_unit(
  p_code text,
  p_name text,
  p_address text default null,
  p_city text default null,
  p_state text default null,
  p_timezone text default 'America/Sao_Paulo',
  p_active boolean default true
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_unit public.units%rowtype;
  v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_timezone text := coalesce(nullif(btrim(coalesce(p_timezone, '')), ''), 'America/Sao_Paulo');
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    null
  );

  if v_code is null then
    raise exception 'unit_code_required';
  end if;

  if v_name is null then
    raise exception 'unit_name_required';
  end if;

  insert into public.units (
    code, name, address, city, state, timezone, active
  ) values (
    v_code,
    v_name,
    nullif(btrim(coalesce(p_address, '')), ''),
    nullif(btrim(coalesce(p_city, '')), ''),
    nullif(upper(btrim(coalesce(p_state, ''))), ''),
    v_timezone,
    coalesce(p_active, true)
  )
  returning * into v_unit;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data, occurred_at
  ) values (
    v_admin.id,
    'unit_created',
    'unit',
    v_unit.id,
    jsonb_build_object(
      'code', v_unit.code,
      'name', v_unit.name,
      'address', v_unit.address,
      'city', v_unit.city,
      'state', v_unit.state,
      'timezone', v_unit.timezone,
      'active', v_unit.active
    ),
    now()
  );

  return v_unit.id;
end;
$$;

create or replace function public.admin_update_unit(
  p_unit uuid,
  p_code text,
  p_name text,
  p_address text default null,
  p_city text default null,
  p_state text default null,
  p_timezone text default 'America/Sao_Paulo',
  p_active boolean default true
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_before public.units%rowtype;
  v_after public.units%rowtype;
  v_code text := nullif(upper(btrim(coalesce(p_code, ''))), '');
  v_name text := nullif(btrim(coalesce(p_name, '')), '');
  v_timezone text := coalesce(nullif(btrim(coalesce(p_timezone, '')), ''), 'America/Sao_Paulo');
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    p_unit
  );

  if v_code is null then
    raise exception 'unit_code_required';
  end if;

  if v_name is null then
    raise exception 'unit_name_required';
  end if;

  select * into v_before
  from public.units
  where id = p_unit
  for update;

  if v_before.id is null then
    raise exception 'unit_not_found';
  end if;

  update public.units
  set code = v_code,
      name = v_name,
      address = nullif(btrim(coalesce(p_address, '')), ''),
      city = nullif(btrim(coalesce(p_city, '')), ''),
      state = nullif(upper(btrim(coalesce(p_state, ''))), ''),
      timezone = v_timezone,
      active = coalesce(p_active, active),
      updated_at = now()
  where id = p_unit
  returning * into v_after;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    case
      when v_before.active is distinct from v_after.active then 'unit_status_changed'
      else 'unit_updated'
    end,
    'unit',
    p_unit,
    jsonb_build_object(
      'code', v_before.code,
      'name', v_before.name,
      'address', v_before.address,
      'city', v_before.city,
      'state', v_before.state,
      'timezone', v_before.timezone,
      'active', v_before.active
    ),
    jsonb_build_object(
      'code', v_after.code,
      'name', v_after.name,
      'address', v_after.address,
      'city', v_after.city,
      'state', v_after.state,
      'timezone', v_after.timezone,
      'active', v_after.active
    ),
    now()
  );
end;
$$;

create or replace function public.admin_update_feedback_status(
  p_feedback uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_before public.feedback%rowtype;
  v_after public.feedback%rowtype;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager','content_manager'],
    null
  );

  if p_status not in ('new', 'read', 'resolved') then
    raise exception 'feedback_status_invalid';
  end if;

  select * into v_before
  from public.feedback
  where id = p_feedback
  for update;

  if v_before.id is null then
    raise exception 'feedback_not_found';
  end if;

  update public.feedback
  set status = p_status,
      resolved_at = case when p_status = 'resolved' then now() else null end,
      updated_at = now()
  where id = p_feedback
  returning * into v_after;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    'feedback_status_changed',
    'feedback',
    p_feedback,
    jsonb_build_object('status', v_before.status, 'resolved_at', v_before.resolved_at),
    jsonb_build_object('status', v_after.status, 'resolved_at', v_after.resolved_at),
    now()
  );
end;
$$;

revoke all on function private.require_admin_for_backend(text[], uuid) from public, anon, authenticated;

revoke all on function public.admin_create_operator(uuid, text, text, uuid, text, text, boolean) from public, anon;
revoke all on function public.admin_update_operator(uuid, text, text, uuid, text, text, boolean) from public, anon;
revoke all on function public.admin_update_admin_user(uuid, text, text, boolean, boolean) from public, anon;
revoke all on function public.admin_create_unit(text, text, text, text, text, text, boolean) from public, anon;
revoke all on function public.admin_update_unit(uuid, text, text, text, text, text, text, boolean) from public, anon;
revoke all on function public.admin_update_feedback_status(uuid, text) from public, anon;

grant execute on function public.admin_create_operator(uuid, text, text, uuid, text, text, boolean) to authenticated;
grant execute on function public.admin_update_operator(uuid, text, text, uuid, text, text, boolean) to authenticated;
grant execute on function public.admin_update_admin_user(uuid, text, text, boolean, boolean) to authenticated;
grant execute on function public.admin_create_unit(text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.admin_update_unit(uuid, text, text, text, text, text, text, boolean) to authenticated;
grant execute on function public.admin_update_feedback_status(uuid, text) to authenticated;
