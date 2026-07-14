begin;

create or replace function public.audit_admin_change()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin uuid;
  v_entity uuid;
  v_source text := nullif(
    pg_catalog.current_setting('app.audit_source', true),
    ''
  );
begin
  select admin_row.id
    into v_admin
    from public.admin_users as admin_row
   where admin_row.auth_user_id = auth.uid();

  if tg_op = 'DELETE' then
    v_entity := old.id;
  else
    v_entity := new.id;
  end if;

  insert into public.admin_audit_logs(
    admin_user_id,
    action,
    entity_type,
    entity_id,
    before_data,
    after_data,
    reason
  ) values (
    v_admin,
    pg_catalog.lower(tg_op),
    tg_table_name,
    v_entity,
    case when tg_op in ('UPDATE', 'DELETE') then pg_catalog.to_jsonb(old) else null end,
    case when tg_op in ('INSERT', 'UPDATE') then pg_catalog.to_jsonb(new) else null end,
    v_source
  );

  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

create or replace function public.update_my_operator_display_name(p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid := auth.uid();
  v_operator_id uuid;
  v_previous_name text;
  v_display_name text;
  v_server_now timestamptz := pg_catalog.clock_timestamp();
  v_changed boolean := false;
begin
  if v_auth_user_id is null then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'server_now', v_server_now,
      'data', null,
      'error', pg_catalog.jsonb_build_object(
        'code', 'NOT_AUTHENTICATED',
        'message', 'Sessao autenticada obrigatoria.',
        'retryable', false
      )
    );
  end if;

  v_display_name := pg_catalog.btrim(
    pg_catalog.regexp_replace(coalesce(p_display_name, ''), '[[:space:]]+', ' ', 'g')
  );

  if pg_catalog.char_length(v_display_name) < 3 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'server_now', v_server_now,
      'data', null,
      'error', pg_catalog.jsonb_build_object(
        'code', case when v_display_name = '' then 'DISPLAY_NAME_REQUIRED' else 'DISPLAY_NAME_TOO_SHORT' end,
        'message', case when v_display_name = '' then 'Informe o nome de exibicao.' else 'O nome deve ter pelo menos 3 caracteres.' end,
        'retryable', false
      )
    );
  end if;

  if pg_catalog.char_length(v_display_name) > 50 then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'server_now', v_server_now,
      'data', null,
      'error', pg_catalog.jsonb_build_object(
        'code', 'DISPLAY_NAME_TOO_LONG',
        'message', 'O nome deve ter no maximo 50 caracteres.',
        'retryable', false
      )
    );
  end if;

  select operator_row.id, operator_row.display_name
    into v_operator_id, v_previous_name
    from public.operators as operator_row
   where operator_row.auth_user_id = v_auth_user_id
   for update;

  if not found then
    return pg_catalog.jsonb_build_object(
      'success', false,
      'server_now', v_server_now,
      'data', null,
      'error', pg_catalog.jsonb_build_object(
        'code', 'OPERATOR_NOT_FOUND',
        'message', 'Operador autenticado nao encontrado.',
        'retryable', false
      )
    );
  end if;

  v_changed := v_previous_name is distinct from v_display_name;
  if v_changed then
    perform pg_catalog.set_config('app.audit_source', 'operator_app', true);
    update public.operators
       set display_name = v_display_name
     where id = v_operator_id;
  end if;

  return pg_catalog.jsonb_build_object(
    'success', true,
    'server_now', pg_catalog.clock_timestamp(),
    'data', pg_catalog.jsonb_build_object(
      'display_name', v_display_name,
      'changed', v_changed
    ),
    'error', null
  );
end;
$$;

revoke all on function public.audit_admin_change() from public, anon;
grant execute on function public.audit_admin_change() to authenticated;

revoke all on function public.update_my_operator_display_name(text) from public, anon;
grant execute on function public.update_my_operator_display_name(text) to authenticated;

commit;
