begin;

-- O formulário comum não corrige o nome cadastral. Essa mudança usa a RPC
-- dedicada abaixo, com justificativa e auditoria próprias.
create or replace function public.admin_update_operator_profile_v2(
  p_operator uuid,
  p_registered_name text,
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
  v_before public.operators%rowtype;
  v_registered_name text := nullif(btrim(regexp_replace(coalesce(p_registered_name, ''), '[[:space:]]+', ' ', 'g')), '');
  v_username text := nullif(lower(btrim(coalesce(p_username, ''))), '');
begin
  select * into v_before
  from public.operators
  where id = p_operator
  for update;

  if v_before.id is null then raise exception 'operator_not_found'; end if;

  perform private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    v_before.unit_id
  );
  perform private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    p_unit_id
  );

  if v_registered_name is null then raise exception 'registered_name_required'; end if;
  if v_registered_name is distinct from v_before.registered_name then
    raise exception 'registered_name_use_dedicated_rpc';
  end if;
  if v_username is not null and v_username !~ '^[a-z0-9._-]{3,60}$' then raise exception 'username_invalid'; end if;
  if p_role not in ('operador', 'supervisor') then raise exception 'operator_role_invalid'; end if;
  if p_session_policy not in ('single', 'multi') then raise exception 'session_policy_invalid'; end if;
  if not exists (select 1 from public.units where id = p_unit_id and active = true) then
    raise exception 'unit_not_found_or_inactive';
  end if;

  perform set_config('app.audit_source', 'admin_profile', true);
  update public.operators
  set username = v_username,
      unit_id = p_unit_id,
      role = p_role,
      session_policy = p_session_policy,
      active = coalesce(p_active, active),
      updated_at = clock_timestamp()
  where id = p_operator;
end;
$$;

create or replace function public.admin_correct_operator_registered_name(
  p_operator uuid,
  p_registered_name text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_registered_name text := nullif(btrim(regexp_replace(coalesce(p_registered_name, ''), '[[:space:]]+', ' ', 'g')), '');
  v_reason text := btrim(regexp_replace(coalesce(p_reason, ''), '[[:space:]]+', ' ', 'g'));
  v_now timestamptz := clock_timestamp();
begin
  select * into v_operator
  from public.operators
  where id = p_operator
  for update;

  if v_operator.id is null then raise exception 'operator_not_found'; end if;
  v_admin := private.require_admin_for_backend(array['superadmin'], v_operator.unit_id);

  if v_registered_name is null or char_length(v_registered_name) < 3 or char_length(v_registered_name) > 120 then
    raise exception 'registered_name_length_invalid';
  end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then
    raise exception 'registered_name_correction_reason_invalid';
  end if;

  if v_registered_name = v_operator.registered_name then
    return jsonb_build_object(
      'success', true,
      'server_now', v_now,
      'data', jsonb_build_object('registered_name', v_operator.registered_name, 'changed', false),
      'error', null
    );
  end if;

  perform set_config('app.audit_source', 'admin_explicit', true);
  update public.operators
  set registered_name = v_registered_name,
      updated_at = v_now
  where id = v_operator.id;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, reason, occurred_at
  ) values (
    v_admin.id,
    'operator_registered_name_corrected',
    'operator',
    v_operator.id,
    jsonb_build_object('registered_name', v_operator.registered_name),
    jsonb_build_object('registered_name', v_registered_name),
    v_reason,
    v_now
  );

  return jsonb_build_object(
    'success', true,
    'server_now', clock_timestamp(),
    'data', jsonb_build_object('registered_name', v_registered_name, 'changed', true),
    'error', null
  );
end;
$$;

-- Compara o mesmo nome sem caixa, acento ou pontuação simples e limita apenas
-- cinco nomes normalizados diferentes dentro de dez minutos.
create or replace function public.update_my_operator_display_name(p_display_name text)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid := auth.uid();
  v_operator public.operators%rowtype;
  v_display_name text;
  v_normalized_name text;
  v_compact_name text;
  v_normalized_current_name text;
  v_server_now timestamptz := clock_timestamp();
  v_last_applied_at timestamptz;
  v_next_change_at timestamptz;
  v_attempt_count integer;
  v_attempt_already_seen boolean;
  v_term public.operator_display_name_moderation_terms%rowtype;
begin
  if v_auth_user_id is null then
    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'NOT_AUTHENTICATED',
        'message', 'Sessao autenticada obrigatoria.',
        'retryable', false
      )
    );
  end if;

  v_display_name := btrim(regexp_replace(coalesce(p_display_name, ''), '[[:space:]]+', ' ', 'g'));

  if char_length(v_display_name) < 3 then
    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', case when v_display_name = '' then 'DISPLAY_NAME_REQUIRED' else 'DISPLAY_NAME_TOO_SHORT' end,
        'message', case when v_display_name = '' then 'Informe o nome de exibicao.' else 'O nome deve ter pelo menos 3 caracteres.' end,
        'retryable', false
      )
    );
  end if;

  if char_length(v_display_name) > 50 then
    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'DISPLAY_NAME_TOO_LONG',
        'message', 'O nome deve ter no maximo 50 caracteres.',
        'retryable', false
      )
    );
  end if;

  v_normalized_name := private.normalize_operator_display_name(v_display_name, false);
  v_compact_name := private.normalize_operator_display_name(v_display_name, true);

  select * into v_operator
  from public.operators
  where auth_user_id = v_auth_user_id
  for update;

  if v_operator.id is null then
    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'OPERATOR_NOT_FOUND',
        'message', 'Operador autenticado nao encontrado.',
        'retryable', false
      )
    );
  end if;

  v_normalized_current_name := private.normalize_operator_display_name(v_operator.display_name, false);

  select max(applied_at) into v_last_applied_at
  from public.operator_display_name_requests
  where operator_id = v_operator.id
    and applied_at is not null;

  v_next_change_at := case
    when v_last_applied_at is null then null
    else v_last_applied_at + interval '15 days'
  end;

  if v_normalized_current_name = v_normalized_name then
    return jsonb_build_object(
      'success', true,
      'server_now', clock_timestamp(),
      'data', jsonb_build_object(
        'display_name', v_operator.display_name,
        'changed', false,
        'moderation_status', 'allowed',
        'next_change_at', v_next_change_at
      ),
      'error', null
    );
  end if;

  select
    count(distinct request_row.normalized_name)::integer,
    coalesce(bool_or(request_row.normalized_name = v_normalized_name), false)
  into v_attempt_count, v_attempt_already_seen
  from public.operator_display_name_requests request_row
  where request_row.operator_id = v_operator.id
    and request_row.actor_type = 'operator'
    and request_row.occurred_at >= v_server_now - interval '10 minutes';

  if v_attempt_count >= 5 and not v_attempt_already_seen then
    insert into public.operator_display_name_requests (
      operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
      requested_name, normalized_name, compact_name, moderation_result,
      moderation_reason, review_status, source, occurred_at
    ) values (
      v_operator.id, v_operator.unit_id, v_auth_user_id, 'operator', v_operator.display_name,
      v_display_name, v_normalized_name, v_compact_name, 'rate_limited',
      'Limite de cinco nomes diferentes em dez minutos.', 'not_required', 'operator_app', v_server_now
    );

    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'DISPLAY_NAME_RATE_LIMITED',
        'message', 'Muitas tentativas. Aguarde alguns minutos para tentar novamente.',
        'retryable', true,
        'retry_at', (
          select min(request_row.occurred_at) + interval '10 minutes'
          from public.operator_display_name_requests request_row
          where request_row.operator_id = v_operator.id
            and request_row.actor_type = 'operator'
            and request_row.occurred_at >= v_server_now - interval '10 minutes'
        )
      )
    );
  end if;

  if v_next_change_at is not null and v_next_change_at > v_server_now then
    insert into public.operator_display_name_requests (
      operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
      requested_name, normalized_name, compact_name, moderation_result,
      moderation_reason, review_status, source, occurred_at
    ) values (
      v_operator.id, v_operator.unit_id, v_auth_user_id, 'operator', v_operator.display_name,
      v_display_name, v_normalized_name, v_compact_name, 'rate_limited',
      'Prazo de 15 dias ainda em andamento.', 'not_required', 'operator_app', v_server_now
    );

    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'DISPLAY_NAME_CHANGE_COOLDOWN',
        'message', 'O nome de exibicao so pode ser alterado uma vez a cada 15 dias.',
        'retryable', true,
        'retry_at', v_next_change_at
      )
    );
  end if;

  select * into v_term
  from public.operator_display_name_moderation_terms term_row
  where term_row.active = true
    and (
      (term_row.match_type = 'exact_name' and v_normalized_name = term_row.normalized_term)
      or (
        term_row.match_type = 'whole_word'
        and position(' ' || term_row.normalized_term || ' ' in ' ' || v_normalized_name || ' ') > 0
      )
      or (
        term_row.match_type = 'obfuscated'
        and char_length(term_row.compact_term) >= 3
        and position(term_row.compact_term in v_compact_name) > 0
      )
    )
  order by case term_row.match_type
    when 'exact_name' then 1
    when 'whole_word' then 2
    else 3
  end, char_length(term_row.normalized_term) desc
  limit 1;

  if v_term.id is not null then
    insert into public.operator_display_name_requests (
      operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
      requested_name, normalized_name, compact_name, moderation_result,
      moderation_term_id, moderation_reason, review_status, source, occurred_at
    ) values (
      v_operator.id, v_operator.unit_id, v_auth_user_id, 'operator', v_operator.display_name,
      v_display_name, v_normalized_name, v_compact_name, 'blocked',
      v_term.id, v_term.reason, 'pending', 'operator_app', v_server_now
    );

    return jsonb_build_object(
      'success', false, 'server_now', v_server_now, 'data', null,
      'error', jsonb_build_object(
        'code', 'DISPLAY_NAME_NOT_ALLOWED',
        'message', 'Esse nome de exibicao nao pode ser utilizado.',
        'retryable', false
      )
    );
  end if;

  insert into public.operator_display_name_requests (
    operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
    requested_name, normalized_name, compact_name, applied_name,
    moderation_result, review_status, source, occurred_at, applied_at
  ) values (
    v_operator.id, v_operator.unit_id, v_auth_user_id, 'operator', v_operator.display_name,
    v_display_name, v_normalized_name, v_compact_name, v_display_name,
    'allowed', 'not_required', 'operator_app', v_server_now, v_server_now
  );

  perform set_config('app.audit_source', 'operator_app', true);
  update public.operators
  set display_name = v_display_name,
      updated_at = v_server_now
  where id = v_operator.id;

  return jsonb_build_object(
    'success', true,
    'server_now', clock_timestamp(),
    'data', jsonb_build_object(
      'display_name', v_display_name,
      'changed', true,
      'moderation_status', 'allowed',
      'next_change_at', v_server_now + interval '15 days'
    ),
    'error', null
  );
end;
$$;

revoke all on function public.admin_correct_operator_registered_name(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.admin_correct_operator_registered_name(uuid, text, text)
  to authenticated;

revoke all on function public.admin_update_operator_profile_v2(uuid, text, text, uuid, text, text, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_update_operator_profile_v2(uuid, text, text, uuid, text, text, boolean)
  to authenticated;

revoke all on function public.update_my_operator_display_name(text)
  from public, anon, authenticated;
grant execute on function public.update_my_operator_display_name(text)
  to authenticated;

commit;
