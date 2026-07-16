-- Contract test for operator_challenge_answer_v2.
-- Run after 20260714233203_operator_challenge_answer_feedback_v2_contract.sql.
-- The transaction is always rolled back.

begin;

do $test$
declare
  v_operator public.operators%rowtype;
  v_other_operator public.operators%rowtype;
  v_session public.operator_sessions%rowtype;
  v_challenge public.challenges%rowtype;
  v_log public.challenge_logs%rowtype;
  v_snapshot jsonb;
  v_response jsonb;
  v_repeat jsonb;
  v_before_blocks integer;
  v_after_blocks integer;
begin
  select o.* into v_operator
  from public.operators o
  where o.active and o.auth_user_id is not null
  order by o.created_at
  limit 1;

  select o.* into v_other_operator
  from public.operators o
  where o.active and o.auth_user_id is not null and o.id <> v_operator.id
  order by o.created_at
  limit 1;

  if v_operator.id is null or v_other_operator.id is null then
    raise exception 'test_requires_two_active_operators';
  end if;

  if has_function_privilege('anon', 'public.operator_challenge_answer_v2(uuid,jsonb)', 'execute')
     or not has_function_privilege('authenticated', 'public.operator_challenge_answer_v2(uuid,jsonb)', 'execute') then
    raise exception 'operator_challenge_answer_v2_grants_invalid';
  end if;

  insert into public.challenges(title, prompt, kind, status, answer_definition)
  values (
    'Teste feedback v2',
    'Qual alternativa deve ser marcada?',
    'multiple_choice',
    'active',
    jsonb_build_object(
      'alternatives', jsonb_build_array('Alternativa A', 'Alternativa B', 'Alternativa C', 'Alternativa D'),
      'correct', 'A',
      'options', jsonb_build_array(
        jsonb_build_object('id', 'option_a', 'text', 'Alternativa A'),
        jsonb_build_object('id', 'option_b', 'text', 'Alternativa B'),
        jsonb_build_object('id', 'option_c', 'text', 'Alternativa C'),
        jsonb_build_object('id', 'option_d', 'text', 'Alternativa D')
      ),
      'correct_option_id', 'option_a'
    )
  ) returning * into v_challenge;

  insert into public.operator_sessions(operator_id, unit_id, status, expires_at)
  values (v_operator.id, v_operator.unit_id, 'active', now() + interval '1 hour')
  returning * into v_session;

  insert into public.challenge_logs(challenge_id, operator_id, session_id, status, expires_at)
  values (v_challenge.id, v_operator.id, v_session.id, 'displayed', now() + interval '10 minutes')
  returning * into v_log;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_operator.auth_user_id, 'role', 'authenticated')::text,
    true
  );

  v_snapshot := private.challenge_payload(v_operator.id, v_session.id);
  if v_snapshot#>>'{challenge,answer_definition,correct}' is not null
     or v_snapshot#>>'{challenge,answer_definition,correct_option_id}' is not null
     or v_snapshot#>>'{challenge,answer_definition,is_correct}' is not null
     or v_snapshot#>>'{challenge,answer_definition,correct_option_text}' is not null
     or v_snapshot#>>'{challenge,answer_definition,options,0,id}' <> 'option_a' then
    raise exception 'initial_snapshot_leaks_or_lacks_public_option_ids: %', v_snapshot;
  end if;

  -- The SQL test runner is an elevated database role, so it cannot emulate a
  -- browser REST request by selecting directly. Assert the effective RLS
  -- contract instead: only the admin policy may select either table.
  if exists (
    select 1
    from pg_policies
    where schemaname = 'public'
      and tablename in ('challenges', 'challenge_logs')
      and not (
        policyname = 'admin_all'
        and roles = array['authenticated']::name[]
        and cmd = 'ALL'
        and qual = 'is_admin()'
      )
  ) then
    raise exception 'challenge_tables_must_not_have_non_admin_rest_policy';
  end if;

  v_response := public.operator_challenge_answer_v2(
    v_log.id,
    jsonb_build_object('option_id', 'option_a')
  );
  if v_response->>'schema_version' <> '2'
     or v_response#>>'{answer_feedback,result}' <> 'correct'
     or not coalesce((v_response#>>'{answer_feedback,is_correct}')::boolean, false)
     or v_response#>>'{answer_feedback,selected_option_id}' <> 'option_a'
     or v_response#>>'{answer_feedback,correct_option_id}' <> 'option_a'
     or v_response#>>'{answer_feedback,correct_option_text}' <> 'Alternativa A'
     or v_response->'next_snapshot' is null then
    raise exception 'correct_answer_feedback_contract_invalid: %', v_response;
  end if;

  v_repeat := public.operator_challenge_answer_v2(
    v_log.id,
    jsonb_build_object('option_id', 'option_a')
  );
  if v_repeat <> v_response
     or (select count(*) from public.challenge_logs where id = v_log.id) <> 1 then
    raise exception 'correct_retry_must_return_the_same_response';
  end if;

  begin
    perform public.operator_challenge_answer_v2(
      v_log.id,
      jsonb_build_object('option_id', 'option_a', 'is_correct', false)
    );
    raise exception 'client_must_not_send_is_correct';
  exception when others then
    if sqlerrm <> 'resposta_invalida' then raise; end if;
  end;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_other_operator.auth_user_id, 'role', 'authenticated')::text,
    true
  );
  begin
    perform public.operator_challenge_answer_v2(v_log.id, jsonb_build_object('option_id', 'option_a'));
    raise exception 'other_operator_must_not_answer_this_challenge';
  exception when others then
    if sqlerrm <> 'desafio_indisponivel' then raise; end if;
  end;

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_operator.auth_user_id, 'role', 'authenticated')::text,
    true
  );
  insert into public.challenge_logs(challenge_id, operator_id, session_id, status, expires_at)
  values (v_challenge.id, v_operator.id, v_session.id, 'displayed', now() - interval '1 second')
  returning * into v_log;
  begin
    perform public.operator_challenge_answer_v2(v_log.id, jsonb_build_object('option_id', 'option_a'));
    raise exception 'expired_challenge_must_not_answer';
  exception when others then
    if sqlerrm <> 'desafio_indisponivel' then raise; end if;
  end;
  update public.challenge_logs
  set status = 'expired', closed_at = now()
  where id = v_log.id;

  insert into public.challenge_logs(challenge_id, operator_id, session_id, status, expires_at)
  values (v_challenge.id, v_operator.id, v_session.id, 'displayed', now() + interval '10 minutes')
  returning * into v_log;
  begin
    perform public.operator_challenge_answer_v2(v_log.id, jsonb_build_object('option_id', 'option_z'));
    raise exception 'option_from_another_question_must_be_rejected';
  exception when others then
    if sqlerrm <> 'resposta_invalida' then raise; end if;
  end;
  update public.challenge_logs
  set status = 'expired', closed_at = now()
  where id = v_log.id;

  insert into public.challenge_logs(challenge_id, operator_id, session_id, status, expires_at)
  values (v_challenge.id, v_operator.id, v_session.id, 'displayed', now() + interval '10 minutes')
  returning * into v_log;
  v_response := public.operator_challenge_answer(v_log.id, jsonb_build_object('value', 'A'));
  if v_response is null or (select answer_result from public.challenge_logs where id = v_log.id) <> 'correct' then
    raise exception 'legacy_operator_challenge_answer_regressed';
  end if;

  insert into public.challenge_logs(challenge_id, operator_id, session_id, status, expires_at)
  values (v_challenge.id, v_operator.id, v_session.id, 'displayed', now() + interval '10 minutes')
  returning * into v_log;
  select count(*) into v_before_blocks
  from public.operator_blocks
  where challenge_log_id = v_log.id;

  v_response := public.operator_challenge_answer_v2(
    v_log.id,
    jsonb_build_object('option_id', 'option_b')
  );
  if v_response#>>'{answer_feedback,result}' <> 'incorrect'
     or coalesce((v_response#>>'{answer_feedback,is_correct}')::boolean, true)
     or v_response#>>'{answer_feedback,selected_option_id}' <> 'option_b'
     or v_response#>>'{answer_feedback,correct_option_id}' <> 'option_a'
     or v_response#>>'{answer_feedback,correct_option_text}' <> 'Alternativa A'
     or v_response#>>'{next_snapshot,next_screen}' <> 'blocked' then
    raise exception 'incorrect_answer_feedback_contract_invalid: %', v_response;
  end if;

  v_repeat := public.operator_challenge_answer_v2(
    v_log.id,
    jsonb_build_object('option_id', 'option_b')
  );
  select count(*) into v_after_blocks
  from public.operator_blocks
  where challenge_log_id = v_log.id;
  if v_repeat <> v_response or v_after_blocks <> v_before_blocks + 1 then
    raise exception 'incorrect_retry_must_not_duplicate_penalty_or_response';
  end if;

  perform set_config('request.jwt.claims', '{}'::text, true);
  begin
    perform public.operator_challenge_answer_v2(v_log.id, jsonb_build_object('option_id', 'option_b'));
    raise exception 'unauthenticated_request_must_be_rejected';
  exception when others then
    if sqlerrm <> 'operador_invalido' then raise; end if;
  end;
end;
$test$;

rollback;

select 'operator_challenge_answer_feedback_v2_contract_ok' as result;
