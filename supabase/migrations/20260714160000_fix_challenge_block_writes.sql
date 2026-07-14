-- Fix challenge penalties to match the current operator_blocks schema.
--
-- The runtime functions previously inserted a removed `metadata` column.
-- That made PostgreSQL roll back incorrect answers and abandonment penalties.

create or replace function public.operator_challenge_answer(
  p_log_id uuid,
  p_answer jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.operators%rowtype;
  v_log public.challenge_logs%rowtype;
  v_c public.challenges%rowtype;
  v_rules jsonb;
  v_errors integer;
  v_seconds integer;
  v_correct boolean;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;

  if v_op.id is null then
    raise exception 'operador_invalido';
  end if;

  select * into v_log
  from public.challenge_logs
  where id = p_log_id and operator_id = v_op.id
  for update;

  if v_log.id is null
     or v_log.status not in ('pending', 'displayed')
     or v_log.expires_at <= now() then
    raise exception 'desafio_indisponivel';
  end if;

  select * into v_c
  from public.challenges
  where id = v_log.challenge_id;

  v_correct := lower(coalesce(p_answer->>'value', ''))
    = lower(coalesce(v_c.answer_definition->>'correct', ''));

  update public.challenge_logs
  set status = case when v_correct then 'answered' else 'failed' end,
      answer = p_answer,
      answer_result = case when v_correct then 'correct' else 'incorrect' end,
      answered_at = now(),
      closed_at = now()
  where id = v_log.id;

  if not v_correct then
    select count(*) into v_errors
    from public.challenge_logs
    where operator_id = v_op.id
      and session_id = v_log.session_id
      and status = 'failed';

    v_rules := private.challenge_rules(v_op.unit_id);
    v_seconds := coalesce(
      (
        v_rules->'error_block_seconds'->>
        greatest(
          least(v_errors, jsonb_array_length(v_rules->'error_block_seconds')) - 1,
          0
        )
      )::integer,
      300
    );

    insert into public.operator_blocks(
      operator_id,
      session_id,
      challenge_log_id,
      status,
      reason_code,
      blocked_until
    )
    values (
      v_op.id,
      v_log.session_id,
      v_log.id,
      'active',
      'challenge_incorrect',
      now() + make_interval(secs => v_seconds)
    );
  end if;

  return private.challenge_payload(v_op.id, v_log.session_id);
end
$$;

create or replace function public.operator_challenge_state(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.operators%rowtype;
  v_session uuid := nullif(p_request->>'session_id', '')::uuid;
  v_rules jsonb;
  v_log public.challenge_logs%rowtype;
  v_delay integer;
  v_candidate uuid;
  v_scheduled_for timestamptz;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;

  if v_op.id is null then
    raise exception 'operador_invalido';
  end if;

  if not exists (
    select 1
    from public.operator_sessions
    where id = v_session
      and operator_id = v_op.id
      and status = 'active'
      and expires_at > now()
  ) then
    raise exception 'sessao_invalida';
  end if;

  select * into v_log
  from public.challenge_logs
  where operator_id = v_op.id
    and status = 'abandoned'
    and closed_at is null
  order by abandoned_at desc
  limit 1;

  if v_log.id is not null then
    v_rules := private.challenge_rules(v_op.unit_id);

    insert into public.operator_blocks(
      operator_id,
      session_id,
      challenge_log_id,
      status,
      reason_code,
      blocked_until
    )
    values (
      v_op.id,
      v_session,
      v_log.id,
      'active',
      'challenge_abandoned',
      now() + make_interval(
        secs => coalesce((v_rules->>'abandon_block_seconds')::integer, 300)
      )
    );

    update public.challenge_logs
    set closed_at = now()
    where id = v_log.id;

    return private.challenge_payload(v_op.id, v_session);
  end if;

  select * into v_log
  from private.current_operator_challenge(v_op.id);

  if v_log.id is null then
    v_rules := private.challenge_rules(v_op.unit_id);
    v_delay := floor(
      random() * (
        greatest(
          (v_rules->>'max_interval_seconds')::integer,
          (v_rules->>'min_interval_seconds')::integer
        ) - (v_rules->>'min_interval_seconds')::integer + 1
      )
    )::integer + (v_rules->>'min_interval_seconds')::integer;

    select id into v_candidate
    from public.challenges c
    where c.status = 'active'
      and (c.unit_id = v_op.unit_id or c.unit_id is null)
      and not exists (
        select 1
        from public.challenge_logs l
        where l.operator_id = v_op.id
          and l.session_id = v_session
          and l.challenge_id = c.id
      )
    order by random()
    limit 1;

    if v_candidate is null then
      select id into v_candidate
      from public.challenges
      where status = 'active'
        and (unit_id = v_op.unit_id or unit_id is null)
      order by random()
      limit 1;
    end if;

    if v_candidate is not null then
      v_scheduled_for := private.challenge_schedule_at(v_rules, v_delay, now());

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
        v_candidate,
        v_op.id,
        v_session,
        'scheduled',
        v_scheduled_for,
        now(),
        v_scheduled_for + make_interval(
          secs => coalesce((v_rules->>'response_seconds')::integer, 60)
        )
      );
    end if;
  else
    update public.challenge_logs
    set status = 'pending',
        displayed_at = coalesce(displayed_at, now())
    where id = v_log.id
      and status = 'scheduled'
      and scheduled_for <= now();

    update public.challenge_logs
    set status = 'idle',
        closed_at = now()
    where id = v_log.id
      and status in ('pending', 'displayed')
      and expires_at <= now();
  end if;

  return private.challenge_payload(v_op.id, v_session);
end
$$;

revoke all on function public.operator_challenge_answer(uuid, jsonb)
  from public, anon;
grant execute on function public.operator_challenge_answer(uuid, jsonb)
  to authenticated;

revoke all on function public.operator_challenge_state(jsonb)
  from public, anon;
grant execute on function public.operator_challenge_state(jsonb)
  to authenticated;

comment on function public.operator_challenge_answer(uuid, jsonb) is
  'Validates a challenge answer and creates a progressive block for an incorrect response.';

comment on function public.operator_challenge_state(jsonb) is
  'Reconciles the official challenge state and applies pending abandonment penalties.';
