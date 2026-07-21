-- Contrato de nome de exibição do Operador.
-- Executar somente depois da migration operator_display_name_moderation.
-- Todas as alterações são revertidas ao final.

begin;

do $test$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_original_display_name text;
  v_original_registered_name text;
  v_candidate text;
  v_blocked_name text := 'Nome ruimcodex Teste';
  v_response jsonb;
  v_request_id uuid;
  v_term_id uuid;
  v_count integer;
  v_audit_before integer;
  v_audit_after integer;
  v_applied_at timestamptz;
  v_conflict_request_id uuid;
begin
  select * into v_admin
  from public.admin_users
  where active = true and role = 'superadmin' and auth_user_id is not null
  order by created_at
  limit 1;

  select * into v_operator
  from public.operators
  where active = true and auth_user_id is not null
  order by created_at
  limit 1;

  if v_admin.id is null or v_operator.id is null then
    raise exception 'test_requires_active_superadmin_and_operator';
  end if;

  if has_table_privilege('authenticated', 'public.operator_display_name_requests', 'select')
     or has_table_privilege('authenticated', 'public.operator_display_name_moderation_terms', 'select')
     or has_table_privilege('anon', 'public.operator_display_name_requests', 'select')
     or has_table_privilege('anon', 'public.operator_display_name_moderation_terms', 'select') then
    raise exception 'moderation_tables_must_not_have_direct_app_access';
  end if;

  if position(
    'for update' in lower(pg_get_functiondef('public.update_my_operator_display_name(text)'::regprocedure))
  ) = 0 then
    raise exception 'display_name_update_must_lock_operator_row';
  end if;

  if has_function_privilege('anon', 'public.update_my_operator_display_name(text)', 'execute')
     or not has_function_privilege('authenticated', 'public.update_my_operator_display_name(text)', 'execute')
     or has_function_privilege('authenticated', 'public.audit_admin_change()', 'execute') then
    raise exception 'display_name_function_grants_invalid';
  end if;

  v_original_display_name := v_operator.display_name;
  v_original_registered_name := v_operator.registered_name;
  v_candidate := 'Teste Nome ' || substring(replace(v_operator.id::text, '-', '') from 1 for 8);

  delete from public.operator_display_name_requests where operator_id = v_operator.id;
  delete from public.operator_display_name_moderation_terms where term = 'ruimcodex';

  select count(*) into v_audit_before
  from public.admin_audit_logs
  where entity_id = v_operator.id;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_operator.auth_user_id, 'role', 'authenticated')::text,
    true
  );

  v_response := public.update_my_operator_display_name('  ' || replace(v_candidate, ' ', '   ') || '  ');
  if not coalesce((v_response->>'success')::boolean, false) then
    raise exception 'valid_name_failed: %', v_response;
  end if;
  if v_response#>>'{data,display_name}' <> v_candidate
     or v_response#>>'{data,moderation_status}' <> 'allowed'
     or not coalesce((v_response#>>'{data,changed}')::boolean, false) then
    raise exception 'valid_name_contract_invalid: %', v_response;
  end if;

  select count(*) into v_count
  from public.operator_display_name_requests
  where operator_id = v_operator.id and applied_name = v_candidate;
  if v_count <> 1 then raise exception 'valid_change_must_create_one_history_row'; end if;

  select count(*) into v_audit_after
  from public.admin_audit_logs
  where entity_id = v_operator.id;
  if v_audit_after <> v_audit_before then
    raise exception 'operator_change_must_not_create_admin_audit';
  end if;

  select applied_at into v_applied_at
  from public.operator_display_name_requests
  where operator_id = v_operator.id and applied_name = v_candidate;
  if (v_response#>>'{data,next_change_at}')::timestamptz <> v_applied_at + interval '15 days' then
    raise exception 'success_cooldown_must_be_exactly_15_days';
  end if;

  v_response := public.update_my_operator_display_name(v_candidate);
  if not coalesce((v_response->>'success')::boolean, false)
     or coalesce((v_response#>>'{data,changed}')::boolean, true) then
    raise exception 'unchanged_name_contract_invalid: %', v_response;
  end if;
  select count(*) into v_count
  from public.operator_display_name_requests
  where operator_id = v_operator.id and applied_name = v_candidate;
  if v_count <> 1 then raise exception 'unchanged_name_created_duplicate_history'; end if;

  v_response := public.update_my_operator_display_name(
    lower(replace(v_candidate, ' ', ' - '))
  );
  if not coalesce((v_response->>'success')::boolean, false)
     or coalesce((v_response#>>'{data,changed}')::boolean, true)
     or v_response#>>'{data,display_name}' <> v_candidate then
    raise exception 'case_and_punctuation_equivalent_name_invalid: %', v_response;
  end if;

  v_response := public.update_my_operator_display_name(v_candidate || ' Novo');
  if v_response#>>'{error,code}' <> 'DISPLAY_NAME_CHANGE_COOLDOWN'
     or v_response#>>'{error,retry_at}' is null then
    raise exception 'cooldown_contract_invalid: %', v_response;
  end if;

  perform set_config('app.audit_source', 'operator_app', true);
  update public.operators set display_name = v_original_display_name where id = v_operator.id;
  delete from public.operator_display_name_requests where operator_id = v_operator.id;

  insert into public.operator_display_name_moderation_terms (
    term, normalized_term, compact_term, match_type, active, reason,
    created_by_admin_id, updated_by_admin_id
  ) values (
    'ruimcodex', 'ruimcodex', 'ruimcodex', 'whole_word', true,
    'Termo criado para o teste transacional.', v_admin.id, v_admin.id
  ) returning id into v_term_id;

  v_response := public.update_my_operator_display_name('Nome ruimcodextra Teste');
  if not coalesce((v_response->>'success')::boolean, false) then
    raise exception 'whole_word_must_not_block_substring: %', v_response;
  end if;

  perform set_config('app.audit_source', 'operator_app', true);
  update public.operators set display_name = v_original_display_name where id = v_operator.id;
  delete from public.operator_display_name_requests where operator_id = v_operator.id;

  v_response := public.update_my_operator_display_name(v_blocked_name);
  if v_response#>>'{error,code}' <> 'DISPLAY_NAME_NOT_ALLOWED' then
    raise exception 'blocked_name_contract_invalid: %', v_response;
  end if;
  if (select display_name from public.operators where id = v_operator.id) <> v_original_display_name then
    raise exception 'blocked_name_was_applied';
  end if;

  select id into v_request_id
  from public.operator_display_name_requests
  where operator_id = v_operator.id and moderation_result = 'blocked'
  order by occurred_at desc
  limit 1;
  if v_request_id is null then raise exception 'blocked_attempt_missing_from_history'; end if;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_admin.auth_user_id, 'role', 'authenticated')::text,
    true
  );
  v_response := public.admin_review_operator_display_name_request(jsonb_build_object(
    'request_id', v_request_id,
    'decision', 'approve',
    'reason', 'Excecao aprovada no teste transacional.'
  ));
  if not coalesce((v_response->>'success')::boolean, false) then
    raise exception 'approval_failed: %', v_response;
  end if;
  if (select display_name from public.operators where id = v_operator.id) <> v_blocked_name then
    raise exception 'approved_name_was_not_applied';
  end if;
  if (select review_status from public.operator_display_name_requests where id = v_request_id) <> 'approved' then
    raise exception 'approval_history_not_updated';
  end if;
  select applied_at into v_applied_at
  from public.operator_display_name_requests
  where id = v_request_id;
  if (v_response#>>'{data,next_change_at}')::timestamptz <> v_applied_at + interval '15 days' then
    raise exception 'approval_must_restart_exact_15_day_cooldown';
  end if;

  insert into public.operator_display_name_requests (
    operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
    requested_name, normalized_name, compact_name, moderation_result,
    moderation_reason, review_status, source
  ) values (
    v_operator.id, v_operator.unit_id, v_operator.auth_user_id, 'operator', v_blocked_name,
    'Outro Nome Bloqueado', 'outro nome bloqueado', 'outronomebloqueado', 'blocked',
    'Teste de rejeicao.', 'pending', 'operator_app'
  ) returning id into v_request_id;

  v_response := public.admin_review_operator_display_name_request(jsonb_build_object(
    'request_id', v_request_id,
    'decision', 'reject',
    'reason', 'Solicitacao rejeitada no teste transacional.'
  ));
  if not coalesce((v_response->>'success')::boolean, false)
     or (select review_status from public.operator_display_name_requests where id = v_request_id) <> 'rejected' then
    raise exception 'rejection_contract_invalid: %', v_response;
  end if;

  insert into public.operator_display_name_requests (
    operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
    requested_name, normalized_name, compact_name, moderation_result,
    moderation_reason, review_status, source
  ) values (
    v_operator.id, v_operator.unit_id, v_operator.auth_user_id, 'operator', v_blocked_name,
    'Nome Antigo Bloqueado', 'nome antigo bloqueado', 'nomeantigobloqueado', 'blocked',
    'Teste de conflito.', 'pending', 'operator_app'
  ) returning id into v_conflict_request_id;

  perform set_config('app.audit_source', 'operator_app', true);
  update public.operators set display_name = 'Nome Atual Mais Recente' where id = v_operator.id;
  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_admin.auth_user_id, 'role', 'authenticated')::text,
    true
  );
  v_response := public.admin_review_operator_display_name_request(jsonb_build_object(
    'request_id', v_conflict_request_id,
    'decision', 'approve',
    'reason', 'Tentativa de aprovar solicitacao antiga.'
  ));
  if v_response#>>'{error,code}' <> 'DISPLAY_NAME_REVIEW_CONFLICT' then
    raise exception 'stale_approval_must_return_conflict: %', v_response;
  end if;

  perform set_config('app.audit_source', 'operator_app', true);
  update public.operators set display_name = v_original_display_name where id = v_operator.id;
  delete from public.operator_display_name_requests where operator_id = v_operator.id;
  delete from public.operator_display_name_moderation_terms where id = v_term_id;

  insert into public.operator_display_name_moderation_terms (
    term, normalized_term, compact_term, match_type, active, reason,
    created_by_admin_id, updated_by_admin_id
  ) values (
    'Márcio Teste', 'marcio teste', 'marcioteste', 'exact_name', true,
    'Teste de acento e caixa.', v_admin.id, v_admin.id
  ) returning id into v_term_id;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_operator.auth_user_id, 'role', 'authenticated')::text,
    true
  );
  v_response := public.update_my_operator_display_name('MARCIO TESTE');
  if v_response#>>'{error,code}' <> 'DISPLAY_NAME_NOT_ALLOWED' then
    raise exception 'accent_and_case_moderation_failed: %', v_response;
  end if;

  delete from public.operator_display_name_requests where operator_id = v_operator.id;
  delete from public.operator_display_name_moderation_terms where id = v_term_id;
  insert into public.operator_display_name_moderation_terms (
    term, normalized_term, compact_term, match_type, active, reason,
    created_by_admin_id, updated_by_admin_id
  ) values (
    'codexruim', 'codexruim', 'codexruim', 'obfuscated', true,
    'Teste de ofuscacao.', v_admin.id, v_admin.id
  ) returning id into v_term_id;

  v_response := public.update_my_operator_display_name('c.o-d e_x r u!i?m');
  if v_response#>>'{error,code}' <> 'DISPLAY_NAME_NOT_ALLOWED' then
    raise exception 'obfuscated_moderation_failed: %', v_response;
  end if;

  delete from public.operator_display_name_requests where operator_id = v_operator.id;

  delete from public.operator_display_name_requests where operator_id = v_operator.id;
  for v_count in 1..5 loop
    insert into public.operator_display_name_requests (
      operator_id, unit_id, actor_auth_user_id, actor_type, previous_name,
      requested_name, normalized_name, compact_name, moderation_result,
      moderation_reason, review_status, source, occurred_at
    ) values (
      v_operator.id, v_operator.unit_id, v_operator.auth_user_id, 'operator', v_blocked_name,
      'Tentativa ' || v_count, 'tentativa ' || v_count, 'tentativa' || v_count,
      'rate_limited', 'Teste de limite.', 'not_required', 'operator_app', clock_timestamp()
    );
  end loop;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_operator.auth_user_id, 'role', 'authenticated')::text,
    true
  );
  v_response := public.update_my_operator_display_name('Outro Nome Valido');
  if v_response#>>'{error,code}' <> 'DISPLAY_NAME_RATE_LIMITED'
     or v_response#>>'{error,retry_at}' is null then
    raise exception 'rate_limit_contract_invalid: %', v_response;
  end if;

  if (select registered_name from public.operators where id = v_operator.id) <> v_original_registered_name then
    raise exception 'registered_name_was_changed_by_operator_flow';
  end if;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_admin.auth_user_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.admin_update_operator_profile_v2(
      v_operator.id,
      v_original_registered_name || ' Invalido',
      v_operator.username,
      v_operator.unit_id,
      v_operator.role,
      v_operator.session_policy,
      v_operator.active
    );
    raise exception 'common_profile_rpc_must_not_change_registered_name';
  exception
    when others then
      if sqlerrm <> 'registered_name_use_dedicated_rpc' then raise; end if;
  end;

  v_response := public.admin_correct_operator_registered_name(
    v_operator.id,
    v_original_registered_name || ' Corrigido',
    'Correcao validada pelo teste transacional.'
  );
  if not coalesce((v_response->>'success')::boolean, false)
     or (select registered_name from public.operators where id = v_operator.id) <> v_original_registered_name || ' Corrigido'
     or (select display_name from public.operators where id = v_operator.id) <> v_original_display_name then
    raise exception 'dedicated_registered_name_correction_invalid: %', v_response;
  end if;
end;
$test$;

rollback;

select 'operator_display_name_contract_ok' as result;
