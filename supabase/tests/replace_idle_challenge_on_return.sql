begin;

do $$
declare
  v_operator public.operators%rowtype;
  v_session_id uuid := gen_random_uuid();
  v_idle_challenge_id uuid := gen_random_uuid();
  v_replacement_challenge_id uuid := gen_random_uuid();
  v_idle_log_id uuid := gen_random_uuid();
  v_first_log_id uuid;
  v_second_log_id uuid;
  v_payload jsonb;
  v_open_count integer;
begin
  if has_function_privilege('anon', 'public.operator_challenge_resume_idle(uuid)', 'execute') then
    raise exception 'anon nao deve executar operator_challenge_resume_idle';
  end if;

  if not has_function_privilege('authenticated', 'public.operator_challenge_resume_idle(uuid)', 'execute') then
    raise exception 'authenticated deve executar operator_challenge_resume_idle';
  end if;

  select o.* into v_operator
  from public.operators o
  where o.active
    and o.auth_user_id is not null
    and not exists (
      select 1
      from public.operator_sessions s
      where s.operator_id = o.id
        and s.status = 'active'
        and s.expires_at > now()
    )
    and not exists (
      select 1
      from public.operator_blocks b
      where b.operator_id = o.id
        and b.status = 'active'
        and (b.blocked_until is null or b.blocked_until > now())
    )
  order by o.created_at, o.id
  limit 1;

  if v_operator.id is null then
    raise exception 'teste requer um operador ativo sem sessao ou bloqueio ativo';
  end if;

  update public.challenge_logs
     set status = 'expired',
         closed_at = coalesce(closed_at, now()),
         revision = revision + 1
   where operator_id = v_operator.id
     and status in ('scheduled', 'pending', 'displayed', 'paused', 'idle');

  update public.operators
     set default_shift_id = null
   where id = v_operator.id;

  insert into public.operator_sessions(
    id, operator_id, unit_id, shift_id, status, expires_at,
    last_heartbeat_at, app_version, contract_version
  ) values (
    v_session_id, v_operator.id, v_operator.unit_id, null, 'active',
    now() + interval '1 hour', now(), 'test-idle-replacement', 1
  );

  insert into public.operator_states(
    operator_id, session_id, status, activity, reason_code,
    effective_at, call_active
  ) values (
    v_operator.id, v_session_id, 'idle', 'idle', 'challenge_timeout',
    now(), false
  )
  on conflict (operator_id) do update
    set session_id = excluded.session_id,
        status = excluded.status,
        activity = excluded.activity,
        reason_code = excluded.reason_code,
        effective_at = excluded.effective_at,
        call_active = false;

  insert into public.challenges(
    id, unit_id, title, prompt, kind, answer_definition,
    duration_seconds, status
  ) values
  (
    v_idle_challenge_id,
    v_operator.unit_id,
    'Teste ociosidade A',
    'Desafio que ficou ocioso',
    'multiple_choice',
    jsonb_build_object(
      'alternatives', jsonb_build_array('A', 'B', 'C', 'D'),
      'correct', 'A',
      'options', jsonb_build_array(
        jsonb_build_object('id', 'option_a', 'text', 'A'),
        jsonb_build_object('id', 'option_b', 'text', 'B'),
        jsonb_build_object('id', 'option_c', 'text', 'C'),
        jsonb_build_object('id', 'option_d', 'text', 'D')
      ),
      'correct_option_id', 'option_a'
    ),
    60,
    'active'
  ),
  (
    v_replacement_challenge_id,
    v_operator.unit_id,
    'Teste ociosidade B',
    'Desafio substituto',
    'multiple_choice',
    jsonb_build_object(
      'alternatives', jsonb_build_array('A', 'B', 'C', 'D'),
      'correct', 'A',
      'options', jsonb_build_array(
        jsonb_build_object('id', 'option_a', 'text', 'A'),
        jsonb_build_object('id', 'option_b', 'text', 'B'),
        jsonb_build_object('id', 'option_c', 'text', 'C'),
        jsonb_build_object('id', 'option_d', 'text', 'D')
      ),
      'correct_option_id', 'option_a'
    ),
    60,
    'active'
  );

  insert into public.challenge_logs(
    id, challenge_id, operator_id, session_id, status,
    scheduled_for, pending_at, expires_at
  ) values (
    v_idle_log_id, v_idle_challenge_id, v_operator.id, v_session_id, 'idle',
    now() - interval '2 minutes', now() - interval '2 minutes',
    now() + interval '10 minutes'
  );

  perform set_config(
    'request.jwt.claims',
    jsonb_build_object(
      'sub', v_operator.auth_user_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_payload := public.operator_challenge_resume_idle(v_session_id);
  v_first_log_id := nullif(v_payload->'challenge'->>'log_id', '')::uuid;

  if v_payload->>'next_screen' <> 'challenge' then
    raise exception 'esperava next_screen challenge, recebeu %', v_payload->>'next_screen';
  end if;

  if nullif(v_payload->'challenge'->>'id', '')::uuid = v_idle_challenge_id then
    raise exception 'o desafio perdido foi reapresentado';
  end if;

  if v_first_log_id is null then
    raise exception 'desafio substituto sem log_id';
  end if;

  if not exists (
    select 1
    from public.challenge_logs l
    where l.id = v_idle_log_id
      and l.status = 'expired'
      and l.metadata->>'idle_resolution' = 'replacement_challenge'
  ) then
    raise exception 'ocorrencia ociosa nao foi encerrada com auditoria';
  end if;

  v_payload := public.operator_challenge_resume_idle(v_session_id);
  v_second_log_id := nullif(v_payload->'challenge'->>'log_id', '')::uuid;

  if v_second_log_id is distinct from v_first_log_id then
    raise exception 'segundo clique criou outra ocorrencia: % != %', v_second_log_id, v_first_log_id;
  end if;

  select count(*) into v_open_count
  from public.challenge_logs l
  where l.operator_id = v_operator.id
    and l.status in ('scheduled', 'pending', 'displayed', 'paused', 'idle');

  if v_open_count <> 1 then
    raise exception 'esperava uma unica ocorrencia aberta, recebeu %', v_open_count;
  end if;

end;
$$;

rollback;

select 'ok - idle return replaces the lost challenge exactly once' as result;
