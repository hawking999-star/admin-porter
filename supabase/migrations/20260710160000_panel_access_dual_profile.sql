-- Acesso ao painel e acesso ao app viram dois selos independentes sobre o
-- mesmo auth.users. O banco já permite (operators.auth_user_id e
-- admin_users.auth_user_id são UNIQUE por tabela, mas independentes).
-- Aqui adicionamos duas RPCs, superadmin-only e auditadas, para promover
-- alguém de um lado para o outro sem precisar criar um login novo.

-- 1) Operador do app -> ganha acesso ao painel (como superadmin).
create or replace function public.admin_grant_panel_access(
  p_operator uuid,
  p_mfa_required boolean default false
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_existing public.admin_users%rowtype;
  v_result_id uuid;
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  select * into v_operator
  from public.operators
  where id = p_operator;

  if v_operator.id is null then
    raise exception 'operator_not_found';
  end if;

  if v_operator.auth_user_id is null then
    raise exception 'operator_has_no_login';
  end if;

  -- Já existe acesso ao painel para este login? Reativa como superadmin.
  select * into v_existing
  from public.admin_users
  where auth_user_id = v_operator.auth_user_id
  for update;

  if v_existing.id is not null then
    update public.admin_users
    set active = true,
        role = 'superadmin',
        mfa_required = coalesce(p_mfa_required, v_existing.mfa_required),
        updated_at = now()
    where id = v_existing.id;
    v_result_id := v_existing.id;
  else
    insert into public.admin_users (auth_user_id, display_name, role, active, mfa_required)
    values (v_operator.auth_user_id, v_operator.display_name, 'superadmin', true, coalesce(p_mfa_required, false))
    returning id into v_result_id;
  end if;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data, occurred_at
  ) values (
    v_admin.id,
    'panel_access_granted',
    'admin_user',
    v_result_id,
    jsonb_build_object(
      'from_operator', p_operator,
      'auth_user_id', v_operator.auth_user_id,
      'display_name', v_operator.display_name
    ),
    now()
  );

  return v_result_id;
end;
$$;

-- 2) Pessoa que só tem acesso ao painel -> ganha acesso ao app (perfil de operador).
create or replace function public.admin_grant_app_access(
  p_admin_user uuid,
  p_username text,
  p_unit_id uuid,
  p_role text default 'operador',
  p_session_policy text default 'single'
)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_target public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_username text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  select * into v_target
  from public.admin_users
  where id = p_admin_user;

  if v_target.id is null then
    raise exception 'admin_user_not_found';
  end if;

  if v_target.auth_user_id is null then
    raise exception 'admin_has_no_login';
  end if;

  if exists (select 1 from public.operators where auth_user_id = v_target.auth_user_id) then
    raise exception 'already_has_app_access';
  end if;

  if v_username is null then
    raise exception 'username_required';
  end if;

  if v_username !~ '^[a-z0-9._-]{3,60}$' then
    raise exception 'username_invalid';
  end if;

  if exists (select 1 from public.operators where username = v_username) then
    raise exception 'username_taken';
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
    auth_user_id, display_name, username, unit_id, role, session_policy, active
  ) values (
    v_target.auth_user_id, v_target.display_name, v_username, p_unit_id, p_role, p_session_policy, true
  )
  returning * into v_operator;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, after_data, occurred_at
  ) values (
    v_admin.id,
    'app_access_granted',
    'operator',
    v_operator.id,
    jsonb_build_object(
      'from_admin_user', p_admin_user,
      'auth_user_id', v_target.auth_user_id,
      'username', v_username,
      'unit_id', p_unit_id,
      'role', p_role
    ),
    now()
  );

  return v_operator.id;
end;
$$;

revoke all on function public.admin_grant_panel_access(uuid, boolean) from public, anon;
revoke all on function public.admin_grant_app_access(uuid, text, uuid, text, text) from public, anon;
grant execute on function public.admin_grant_panel_access(uuid, boolean) to authenticated;
grant execute on function public.admin_grant_app_access(uuid, text, uuid, text, text) to authenticated;
