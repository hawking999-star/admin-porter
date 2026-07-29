-- Regression contract: an authenticated operator outside the effective shift
-- must remain outside_shift and must not receive or display challenges.

begin;

do $test$
declare
  v_operator public.operators%rowtype;
  v_shift_id uuid := pg_catalog.gen_random_uuid();
  v_session_id uuid := pg_catalog.gen_random_uuid();
  v_challenge_id uuid := pg_catalog.gen_random_uuid();
  v_pending_log_id uuid := pg_catalog.gen_random_uuid();
  v_idle_log_id uuid := pg_catalog.gen_random_uuid();
  v_local_now timestamp := pg_catalog.now() at time zone 'America/Sao_Paulo';
  v_payload jsonb;
  v_open_count integer;
begin
  select operator_row.* into v_operator
  from public.operators operator_row
  where operator_row.active
    and operator_row.auth_user_id is not null
    and not exists (
      select 1
      from public.operator_sessions session_row
      where session_row.operator_id = operator_row.id
        and session_row.status = 'active'
        and session_row.expires_at > pg_catalog.now()
    )
    and not exists (
      select 1
      from public.operator_blocks block_row
      where block_row.operator_id = operator_row.id
        and block_row.status = 'active'
        and (
          block_row.blocked_until is null
          or block_row.blocked_until > pg_catalog.now()
        )
    )
  order by operator_row.created_at, operator_row.id
  limit 1;

  if v_operator.id is null then
    raise exception 'test_requires_an_active_operator_without_session_or_block';
  end if;

  update public.challenge_logs
     set status = 'expired',
         closed_at = coalesce(closed_at, pg_catalog.now())
   where operator_id = v_operator.id
     and status in ('scheduled', 'pending', 'displayed', 'paused', 'idle');

  insert into public.shifts(
    id,
    unit_id,
    name,
    starts_at,
    ends_at,
    days_of_week,
    timezone,
    active
  )
  values (
    v_shift_id,
    v_operator.unit_id,
    'Teste fora do turno',
    (v_local_now + interval '2 hours')::time,
    (v_local_now + interval '3 hours')::time,
    array[0, 1, 2, 3, 4, 5, 6],
    'America/Sao_Paulo',
    true
  );

  update public.operators
     set default_shift_id = v_shift_id
   where id = v_operator.id;

  insert into public.operator_sessions(
    id,
    operator_id,
    unit_id,
    shift_id,
    status,
    expires_at,
    last_heartbeat_at,
    app_version,
    contract_version
  )
  values (
    v_session_id,
    v_operator.id,
    v_operator.unit_id,
    v_shift_id,
    'active',
    pg_catalog.now() + interval '1 hour',
    pg_catalog.now(),
    'test-outside-shift',
    1
  );

  insert into public.operator_states(
    operator_id,
    session_id,
    status,
    activity,
    reason_code,
    effective_at,
    call_active
  )
  values (
    v_operator.id,
    v_session_id,
    'outside_shift',
    null,
    'test_setup',
    pg_catalog.now(),
    false
  )
  on conflict (operator_id) do update
    set session_id = excluded.session_id,
        status = excluded.status,
        activity = excluded.activity,
        reason_code = excluded.reason_code,
        effective_at = excluded.effective_at,
        call_active = false;

  insert into public.challenges(
    id,
    unit_id,
    title,
    prompt,
    kind,
    answer_definition,
    duration_seconds,
    status
  )
  values (
    v_challenge_id,
    v_operator.unit_id,
    'Teste guarda de turno',
    'Este desafio nao pode ser entregue fora do turno.',
    'multiple_choice',
    pg_catalog.jsonb_build_object(
      'alternatives', pg_catalog.jsonb_build_array('A', 'B', 'C', 'D'),
      'correct', 'A',
      'options', pg_catalog.jsonb_build_array(
        pg_catalog.jsonb_build_object('id', 'option_a', 'text', 'A'),
        pg_catalog.jsonb_build_object('id', 'option_b', 'text', 'B'),
        pg_catalog.jsonb_build_object('id', 'option_c', 'text', 'C'),
        pg_catalog.jsonb_build_object('id', 'option_d', 'text', 'D')
      ),
      'correct_option_id', 'option_a'
    ),
    60,
    'active'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_operator.auth_user_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  if private.operator_challenge_in_shift(
    v_operator.id,
    v_session_id
  ) is distinct from false then
    raise exception 'test_shift_must_be_outside';
  end if;

  v_payload := public.operator_challenge_state(
    pg_catalog.jsonb_build_object('session_id', v_session_id)
  );

  if v_payload->>'next_screen' <> 'outside_shift'
     or v_payload#>>'{operator_state,status}' <> 'outside_shift' then
    raise exception 'outside_shift_state_contract_failed: %', v_payload;
  end if;

  select count(*) into v_open_count
  from public.challenge_logs challenge_log
  where challenge_log.operator_id = v_operator.id
    and challenge_log.session_id = v_session_id
    and challenge_log.status in (
      'scheduled', 'pending', 'displayed', 'paused', 'idle'
    );

  if v_open_count <> 0 then
    raise exception 'challenge_was_scheduled_outside_shift';
  end if;

  insert into public.challenge_logs(
    id,
    challenge_id,
    operator_id,
    session_id,
    status,
    scheduled_for,
    pending_at,
    expires_at
  )
  values (
    v_pending_log_id,
    v_challenge_id,
    v_operator.id,
    v_session_id,
    'pending',
    pg_catalog.now(),
    pg_catalog.now(),
    pg_catalog.now() + interval '10 minutes'
  );

  v_payload := public.operator_challenge_displayed(v_pending_log_id);

  if v_payload->>'next_screen' <> 'outside_shift'
     or not exists (
       select 1
       from public.challenge_logs challenge_log
       where challenge_log.id = v_pending_log_id
         and challenge_log.status = 'expired'
         and challenge_log.metadata->>'closed_reason'
           = 'operator_outside_shift'
     ) then
    raise exception 'pending_challenge_was_exposed_outside_shift: %', v_payload;
  end if;

  insert into public.challenge_logs(
    id,
    challenge_id,
    operator_id,
    session_id,
    status,
    scheduled_for,
    pending_at,
    expires_at,
    closed_at
  )
  values (
    v_idle_log_id,
    v_challenge_id,
    v_operator.id,
    v_session_id,
    'idle',
    pg_catalog.now() - interval '2 minutes',
    pg_catalog.now() - interval '2 minutes',
    pg_catalog.now() - interval '1 minute',
    pg_catalog.now() - interval '1 minute'
  );

  update public.operator_states
     set status = 'idle',
         activity = 'challenge_idle',
         reason_code = 'challenge_expired',
         effective_at = pg_catalog.now()
   where operator_id = v_operator.id;

  v_payload := public.operator_challenge_state(
    pg_catalog.jsonb_build_object('session_id', v_session_id)
  );

  if v_payload->>'next_screen' <> 'outside_shift'
     or v_payload#>>'{operator_state,status}' <> 'outside_shift'
     or not exists (
       select 1
       from public.operator_states operator_state
       where operator_state.operator_id = v_operator.id
         and operator_state.status = 'outside_shift'
     )
     or not exists (
       select 1
       from public.challenge_logs challenge_log
       where challenge_log.id = v_idle_log_id
         and challenge_log.status = 'expired'
     ) then
    raise exception 'idle_overrode_outside_shift: %', v_payload;
  end if;
end;
$test$;

rollback;

select 'challenge_outside_shift_guard_ok' as result;
