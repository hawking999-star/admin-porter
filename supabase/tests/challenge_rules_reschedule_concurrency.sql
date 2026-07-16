-- Contract test for multi-admin challenge-rule saves.
-- Run after 20260716105131_reschedule_challenges_after_rule_change.sql.
-- The transaction is always rolled back.

begin;

do $test$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_unit public.units%rowtype;
  v_session public.operator_sessions%rowtype;
  v_challenge public.challenges%rowtype;
  v_log public.challenge_logs%rowtype;
  v_admin_auth_id uuid := gen_random_uuid();
  v_operator_auth_id uuid := gen_random_uuid();
  v_current_revision bigint;
  v_rules jsonb;
begin
  insert into auth.users(id) values (v_admin_auth_id), (v_operator_auth_id);

  insert into public.units(code, name)
  values ('test-rules-' || substring(gen_random_uuid()::text, 1, 8), 'Unidade teste de regras')
  returning * into v_unit;

  insert into public.admin_users(auth_user_id, display_name, role, active)
  values (v_admin_auth_id, 'Admin teste de regras', 'superadmin', true)
  returning * into v_admin;

  insert into public.operators(
    auth_user_id,
    display_name,
    username,
    unit_id,
    active
  )
  values (
    v_operator_auth_id,
    'Operador teste de regras',
    'test_rules_' || substring(gen_random_uuid()::text, 1, 8),
    v_unit.id,
    true
  )
  returning * into v_operator;

  insert into public.operator_sessions(operator_id, unit_id, status, expires_at)
  values (v_operator.id, v_operator.unit_id, 'active', now() + interval '1 hour')
  returning * into v_session;

  insert into public.challenges(title, prompt, kind, status, unit_id, answer_definition)
  values (
    'Teste de reagendamento',
    'O agendamento deve acompanhar a regra mais recente.',
    'multiple_choice',
    'active',
    v_operator.unit_id,
    '{"alternatives":["A","B","C","D"],"correct":"A"}'::jsonb
  )
  returning * into v_challenge;

  insert into public.challenge_logs(
    challenge_id,
    operator_id,
    session_id,
    status,
    scheduled_for,
    pending_at,
    expires_at
  )
  values (
    v_challenge.id,
    v_operator.id,
    v_session.id,
    'scheduled',
    now() + interval '1 day',
    now(),
    now() + interval '1 day 1 minute'
  )
  returning * into v_log;

  select coalesce(max(revision), 0)
  into v_current_revision
  from public.system_settings
  where key = 'challenge_rules'
    and scope_type = 'unit'
    and scope_id = v_operator.unit_id;

  v_rules := jsonb_build_object(
    'revision', v_current_revision,
    'min_interval_seconds', 30,
    'max_interval_seconds', 30,
    'response_seconds', 60,
    'abandon_block_seconds', 300,
    'error_block_seconds', jsonb_build_array(300, 900, 3600),
    'active_window_start', '00:00',
    'active_window_end', '00:00',
    'timezone', 'America/Sao_Paulo'
  );

  perform set_config(
    'request.jwt.claims',
    json_build_object('sub', v_admin.auth_user_id, 'role', 'authenticated')::text,
    true
  );

  perform public.admin_save_challenge_rules(v_operator.unit_id, v_rules);

  select * into v_log
  from public.challenge_logs
  where id = v_log.id;

  if v_log.status <> 'scheduled'
     or v_log.scheduled_for < now() + interval '29 seconds'
     or v_log.scheduled_for > now() + interval '31 seconds'
     or v_log.expires_at <> v_log.scheduled_for + interval '60 seconds'
     or v_log.metadata->>'rescheduled_reason' <> 'challenge_rules_changed' then
    raise exception 'scheduled_challenge_not_recalculated: %', row_to_json(v_log);
  end if;

  begin
    perform public.admin_save_challenge_rules(v_operator.unit_id, v_rules);
    raise exception 'stale_admin_save_must_conflict';
  exception when others then
    if sqlerrm <> 'challenge_rules_conflict' then
      raise;
    end if;
  end;
end
$test$;

select 'challenge_rules_reschedule_concurrency_ok' as result;

rollback;
