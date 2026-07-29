-- Applied remotely as migration 20260729030303.
-- Challenges are only eligible while the operator is inside the shift attached
-- to the active session (falling back to the operator default shift).
-- This also prevents an expired challenge from overwriting outside_shift with
-- idle, which made the Admin overview report off-shift operators as idle.

create or replace function private.operator_challenge_in_shift(
  p_operator_id uuid,
  p_session_id uuid
)
returns boolean
language sql
stable
security definer
set search_path = ''
as $$
  select coalesce(
    (
      public._app_shift_info(
        coalesce(session_row.shift_id, operator_row.default_shift_id)
      )->>'in_shift'
    )::boolean,
    true
  )
  from public.operators operator_row
  left join public.operator_sessions session_row
    on session_row.id = p_session_id
   and session_row.operator_id = operator_row.id
  where operator_row.id = p_operator_id
$$;

revoke all on function private.operator_challenge_in_shift(uuid, uuid)
  from public, anon, authenticated;

create or replace function private.expire_operator_challenges_outside_shift(
  p_operator_id uuid,
  p_session_id uuid
)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
begin
  if coalesce(
    private.operator_challenge_in_shift(p_operator_id, p_session_id),
    true
  ) then
    return false;
  end if;

  update public.challenge_logs
     set status = 'expired',
         closed_at = coalesce(closed_at, pg_catalog.now()),
         revision = revision + 1,
         metadata = coalesce(metadata, '{}'::jsonb)
           || pg_catalog.jsonb_build_object(
             'closed_reason', 'operator_outside_shift',
             'closed_at', pg_catalog.now()
           )
   where operator_id = p_operator_id
     and session_id = p_session_id
     and status in ('scheduled', 'pending', 'displayed', 'paused', 'idle');

  return true;
end;
$$;

revoke all on function private.expire_operator_challenges_outside_shift(uuid, uuid)
  from public, anon, authenticated;

create or replace function private.challenge_operational_snapshot(
  p_operator_id uuid,
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_operator public.operators%rowtype;
  v_session public.operator_sessions%rowtype;
  v_state public.operator_states%rowtype;
  v_challenge public.challenge_logs%rowtype;
  v_block public.operator_blocks%rowtype;
  v_shift_info jsonb;
  v_target_status text;
  v_reason_code text;
  v_status_operacional text;
  v_finished_blocks integer := 0;
begin
  update public.operator_blocks
     set status = 'finished',
         finished_at = coalesce(finished_at, pg_catalog.now()),
         revision = revision + 1
   where operator_id = p_operator_id
     and status = 'active'
     and blocked_until is not null
     and blocked_until <= pg_catalog.now();
  get diagnostics v_finished_blocks = row_count;

  select * into v_operator
  from public.operators
  where id = p_operator_id;

  select * into v_session
  from public.operator_sessions
  where id = p_session_id
    and operator_id = p_operator_id;

  select * into v_state
  from public.operator_states
  where operator_id = p_operator_id;

  select * into v_block
  from public.operator_blocks
  where operator_id = p_operator_id
    and status = 'active'
    and (blocked_until is null or blocked_until > pg_catalog.now())
  order by started_at desc, id desc
  limit 1;

  v_shift_info := public._app_shift_info(
    coalesce(v_session.shift_id, v_operator.default_shift_id)
  );

  -- Defense in depth: every challenge payload closes a challenge that became
  -- ineligible because the operator's shift ended.
  perform private.expire_operator_challenges_outside_shift(
    p_operator_id,
    p_session_id
  );

  select * into v_challenge
  from private.current_operator_challenge(p_operator_id, p_session_id);

  if coalesce(v_state.call_active, false) then
    v_target_status := 'in_call';
    v_reason_code := 'call_active';
  elsif v_block.id is not null then
    v_target_status := 'blocked';
    v_reason_code := v_block.reason_code;
  elsif not coalesce((v_shift_info->>'in_shift')::boolean, true) then
    v_target_status := 'outside_shift';
    v_reason_code := 'outside_shift';
  elsif v_challenge.status = 'idle' then
    v_target_status := 'idle';
    v_reason_code := 'challenge_expired';
  else
    v_target_status := 'active';
    v_reason_code := case
      when v_finished_blocks > 0 then 'challenge_block_finished'
      else 'challenge_state_synced'
    end;
  end if;

  v_state := private.set_challenge_operator_state(
    p_operator_id,
    p_session_id,
    v_target_status,
    v_reason_code
  );

  v_status_operacional := case v_state.status
    when 'active' then 'ativo'
    when 'idle' then 'ocioso'
    when 'in_call' then 'em_atendimento'
    when 'blocked' then 'bloqueado'
    when 'outside_shift' then 'fora_do_turno'
    else v_state.status
  end;

  return pg_catalog.jsonb_build_object(
    'status_operacional', v_status_operacional,
    'operator_state', pg_catalog.jsonb_build_object(
      'status', v_state.status,
      'revision', v_state.revision,
      'effective_at', v_state.effective_at,
      'call_active', coalesce(v_state.call_active, false)
    )
  );
end;
$$;

revoke all on function private.challenge_operational_snapshot(uuid, uuid)
  from public, anon, authenticated;

create or replace function private.challenge_payload(
  p_operator_id uuid,
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_log public.challenge_logs%rowtype;
  v_challenge public.challenges%rowtype;
  v_block public.operator_blocks%rowtype;
  v_operational_snapshot jsonb;
  v_payload jsonb;
begin
  v_operational_snapshot := private.challenge_operational_snapshot(
    p_operator_id,
    p_session_id
  );

  select * into v_block
  from public.operator_blocks
  where operator_id = p_operator_id
    and status = 'active'
    and (blocked_until is null or blocked_until > pg_catalog.now())
  order by started_at desc, id desc
  limit 1;

  if v_block.id is not null then
    v_payload := pg_catalog.jsonb_build_object(
      'next_screen', 'blocked',
      'blocked_until', v_block.blocked_until,
      'block_reason', v_block.reason_code,
      'server_now', pg_catalog.now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  if v_operational_snapshot#>>'{operator_state,status}' = 'outside_shift' then
    v_payload := pg_catalog.jsonb_build_object(
      'next_screen', 'outside_shift',
      'server_now', pg_catalog.now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  select * into v_log
  from private.current_operator_challenge(p_operator_id, p_session_id);

  if v_log.id is null then
    v_payload := pg_catalog.jsonb_build_object(
      'next_screen', 'player',
      'server_now', pg_catalog.now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  select * into v_challenge
  from public.challenges
  where id = v_log.challenge_id;

  if v_log.status = 'idle' then
    v_payload := pg_catalog.jsonb_build_object(
      'next_screen', 'idle',
      'challenge_log_id', v_log.id,
      'server_now', pg_catalog.now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  if v_log.status = 'paused' then
    v_payload := pg_catalog.jsonb_build_object(
      'next_screen', 'paused_by_call',
      'challenge_log_id', v_log.id,
      'server_now', pg_catalog.now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  if v_log.status = 'scheduled' and v_log.scheduled_for > pg_catalog.now() then
    v_payload := pg_catalog.jsonb_build_object(
      'next_screen', 'player',
      'next_challenge_at', v_log.scheduled_for,
      'server_now', pg_catalog.now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  v_payload := pg_catalog.jsonb_build_object(
    'next_screen', 'challenge',
    'server_now', pg_catalog.now(),
    'challenge', pg_catalog.jsonb_build_object(
      'log_id', v_log.id,
      'id', v_challenge.id,
      'title', v_challenge.title,
      'prompt', v_challenge.prompt,
      'kind', v_challenge.kind,
      'answer_definition', pg_catalog.jsonb_build_object(
        'alternatives', v_challenge.answer_definition->'alternatives',
        'options', private.challenge_public_options(v_challenge.answer_definition)
      ),
      'expires_at', v_log.expires_at
    )
  );
  return v_payload || v_operational_snapshot;
end;
$$;

revoke all on function private.challenge_payload(uuid, uuid)
  from public, anon, authenticated;

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
  v_expired_log public.challenge_logs%rowtype;
  v_state public.operator_states%rowtype;
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
      and expires_at > pg_catalog.now()
  ) then
    raise exception 'sessao_invalida';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(v_op.id::text)
  );

  -- A challenge from another login must never contaminate this session.
  update public.challenge_logs
     set status = 'expired',
         closed_at = coalesce(closed_at, pg_catalog.now())
   where operator_id = v_op.id
     and session_id is distinct from v_session
     and status in ('scheduled', 'idle');

  update public.challenge_logs
     set status = 'abandoned',
         abandoned_at = coalesce(abandoned_at, pg_catalog.now()),
         closed_at = null
   where operator_id = v_op.id
     and session_id is distinct from v_session
     and status in ('pending', 'displayed', 'paused');

  -- The session remains valid outside the configured shift, but challenges do
  -- not. Exit before selecting or scheduling a challenge.
  if private.expire_operator_challenges_outside_shift(
    v_op.id,
    v_session
  ) then
    perform private.set_challenge_operator_state(
      v_op.id,
      v_session,
      'outside_shift',
      'challenge_outside_shift'
    );
    return private.challenge_payload(v_op.id, v_session);
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
      pg_catalog.now() + pg_catalog.make_interval(
        secs => coalesce((v_rules->>'abandon_block_seconds')::integer, 300)
      )
    );

    update public.challenge_logs
       set closed_at = pg_catalog.now()
     where id = v_log.id;

    perform private.set_challenge_operator_state(
      v_op.id,
      v_session,
      'blocked',
      'challenge_abandoned'
    );

    return private.challenge_payload(v_op.id, v_session);
  end if;

  select * into v_log
  from private.current_operator_challenge(v_op.id, v_session);

  -- Repair only a stale idle state. Other operational states stay authoritative.
  if v_log.id is null then
    select * into v_state
    from public.operator_states
    where operator_id = v_op.id;

    if v_state.status = 'idle' then
      perform private.set_challenge_operator_state(
        v_op.id,
        v_session,
        case
          when coalesce(v_state.call_active, false) then 'in_call'
          when exists (
            select 1
            from public.operator_blocks block_row
            where block_row.operator_id = v_op.id
              and block_row.status = 'active'
              and (
                block_row.blocked_until is null
                or block_row.blocked_until > pg_catalog.now()
              )
          ) then 'blocked'
          else 'active'
        end,
        'challenge_stale_idle_repaired'
      );
    end if;

    v_rules := private.challenge_rules(v_op.unit_id);
    v_delay := pg_catalog.floor(
      pg_catalog.random() * (
        pg_catalog.greatest(
          (v_rules->>'max_interval_seconds')::integer,
          (v_rules->>'min_interval_seconds')::integer
        ) - (v_rules->>'min_interval_seconds')::integer + 1
      )
    )::integer + (v_rules->>'min_interval_seconds')::integer;

    select id into v_candidate
    from public.challenges challenge_row
    where challenge_row.status = 'active'
      and (
        challenge_row.unit_id = v_op.unit_id
        or challenge_row.unit_id is null
      )
      and not exists (
        select 1
        from public.challenge_logs previous_log
        where previous_log.operator_id = v_op.id
          and previous_log.session_id = v_session
          and previous_log.challenge_id = challenge_row.id
      )
    order by pg_catalog.random()
    limit 1;

    if v_candidate is null then
      select id into v_candidate
      from public.challenges
      where status = 'active'
        and (unit_id = v_op.unit_id or unit_id is null)
      order by pg_catalog.random()
      limit 1;
    end if;

    if v_candidate is not null then
      v_scheduled_for := private.challenge_schedule_at(
        v_rules,
        v_delay,
        pg_catalog.now()
      );

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
        pg_catalog.now(),
        v_scheduled_for + pg_catalog.make_interval(
          secs => coalesce((v_rules->>'response_seconds')::integer, 60)
        )
      );
    end if;
  elsif v_log.status = 'idle' then
    perform private.set_challenge_operator_state(
      v_op.id,
      v_session,
      'idle',
      'challenge_expired'
    );
  else
    v_rules := private.challenge_rules(v_op.unit_id);

    update public.challenge_logs
       set status = 'pending',
           displayed_at = null,
           expires_at = pg_catalog.now() + pg_catalog.make_interval(
             secs => coalesce((v_rules->>'response_seconds')::integer, 60)
           )
     where id = v_log.id
       and status = 'scheduled'
       and scheduled_for <= pg_catalog.now();

    update public.challenge_logs
       set status = 'idle',
           closed_at = pg_catalog.now()
     where id = v_log.id
       and status in ('pending', 'displayed')
       and expires_at <= pg_catalog.now()
    returning * into v_expired_log;

    if v_expired_log.id is not null then
      perform private.set_challenge_operator_state(
        v_op.id,
        v_session,
        'idle',
        'challenge_expired'
      );
    end if;
  end if;

  return private.challenge_payload(v_op.id, v_session);
end;
$$;

revoke all on function public.operator_challenge_state(jsonb)
  from public, anon;
grant execute on function public.operator_challenge_state(jsonb)
  to authenticated;

create or replace function public.operator_challenge_displayed(p_log_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.operators%rowtype;
  v_log public.challenge_logs%rowtype;
  v_rules jsonb;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;

  if v_op.id is null then
    raise exception 'operador_invalido';
  end if;

  select challenge_log.* into v_log
  from public.challenge_logs challenge_log
  join public.operator_sessions session_row
    on session_row.id = challenge_log.session_id
   and session_row.operator_id = challenge_log.operator_id
   and session_row.status = 'active'
   and session_row.expires_at > pg_catalog.now()
  where challenge_log.id = p_log_id
    and challenge_log.operator_id = v_op.id
  for update of challenge_log;

  if v_log.id is null then
    raise exception 'desafio_indisponivel';
  end if;

  if private.expire_operator_challenges_outside_shift(
    v_op.id,
    v_log.session_id
  ) then
    perform private.set_challenge_operator_state(
      v_op.id,
      v_log.session_id,
      'outside_shift',
      'challenge_outside_shift'
    );
    return private.challenge_payload(v_op.id, v_log.session_id);
  end if;

  if v_log.status = 'pending' and v_log.expires_at > pg_catalog.now() then
    v_rules := private.challenge_rules(v_op.unit_id);

    update public.challenge_logs
       set status = 'displayed',
           displayed_at = pg_catalog.now(),
           expires_at = pg_catalog.now() + pg_catalog.make_interval(
             secs => coalesce((v_rules->>'response_seconds')::integer, 60)
           )
     where id = v_log.id;
  end if;

  return private.challenge_payload(v_op.id, v_log.session_id);
end;
$$;

revoke all on function public.operator_challenge_displayed(uuid)
  from public, anon;
grant execute on function public.operator_challenge_displayed(uuid)
  to authenticated;

create or replace function private.operator_runtime_payload(
  p_operator_id uuid,
  p_session_id uuid,
  p_result text
)
returns jsonb
language plpgsql
stable
set search_path = ''
as $$
declare
  v_state public.operator_states%rowtype;
  v_op public.operators%rowtype;
  v_sess public.operator_sessions%rowtype;
  v_shift_info jsonb;
  v_block public.operator_blocks%rowtype;
  v_challenge record;
  v_pending_challenge jsonb := null;
  v_effective_status text := 'offline';
  v_status_operacional text := 'offline';
  v_next_screen text := 'login';
  v_blocked_until timestamptz := null;
  v_expires_at timestamptz := null;
begin
  select * into v_op
  from public.operators
  where id = p_operator_id;

  select * into v_sess
  from public.operator_sessions
  where id = p_session_id
    and operator_id = p_operator_id;

  select * into v_state
  from public.operator_states
  where operator_id = p_operator_id;

  select * into v_block
  from public.operator_blocks
  where operator_id = p_operator_id
    and status = 'active'
    and (blocked_until is null or blocked_until > pg_catalog.now())
  order by started_at desc
  limit 1;

  v_shift_info := public._app_shift_info(
    coalesce(v_sess.shift_id, v_op.default_shift_id)
  );

  v_effective_status := case
    when coalesce(v_state.call_active, false) then 'in_call'
    when v_block.id is not null then 'blocked'
    when not coalesce((v_shift_info->>'in_shift')::boolean, true)
      then 'outside_shift'
    else coalesce(v_state.status, 'offline')
  end;

  if v_block.id is not null then
    v_blocked_until := v_block.blocked_until;
  end if;

  -- Even if a stale row exists, it is never exposed as a pending challenge
  -- while the effective status is outside_shift.
  if v_effective_status <> 'outside_shift' then
    select
      challenge_log.id,
      challenge_log.challenge_id,
      challenge_log.status,
      challenge_log.expires_at,
      challenge_log.paused_at,
      challenge_log.resumed_at,
      challenge_log.pause_reason,
      challenge_row.title,
      challenge_row.prompt,
      challenge_row.kind,
      challenge_row.answer_definition
    into v_challenge
    from public.challenge_logs challenge_log
    join public.challenges challenge_row
      on challenge_row.id = challenge_log.challenge_id
    where challenge_log.operator_id = p_operator_id
      and challenge_log.status in ('pending', 'displayed', 'paused')
      and (
        p_session_id is null
        or challenge_log.session_id is null
        or challenge_log.session_id = p_session_id
      )
    order by challenge_log.created_at desc
    limit 1;
  end if;

  if v_challenge.id is not null then
    v_expires_at := case
      when coalesce(v_state.call_active, false) then null
      else v_challenge.expires_at
    end;
    v_pending_challenge := pg_catalog.jsonb_build_object(
      'id', v_challenge.id,
      'challenge_id', v_challenge.challenge_id,
      'status', v_challenge.status,
      'title', v_challenge.title,
      'prompt', v_challenge.prompt,
      'kind', v_challenge.kind,
      'answer_definition', v_challenge.answer_definition,
      'expires_at', v_expires_at,
      'paused_at', v_challenge.paused_at,
      'pause_reason', v_challenge.pause_reason
    );
  end if;

  v_status_operacional := case v_effective_status
    when 'active' then 'ativo'
    when 'idle' then 'ocioso'
    when 'in_call' then 'em_atendimento'
    when 'blocked' then 'bloqueado'
    when 'outside_shift' then 'fora_do_turno'
    else 'offline'
  end;

  v_next_screen := case
    when v_effective_status = 'in_call' then 'call'
    when v_effective_status = 'blocked' then 'blocked'
    when v_effective_status = 'outside_shift' then 'outside_shift'
    when v_pending_challenge is not null then 'challenge'
    when v_effective_status = 'offline' then 'login'
    else 'player'
  end;

  return pg_catalog.jsonb_build_object(
    'result', p_result,
    'call_active', coalesce(v_state.call_active, false),
    'status_operacional', v_status_operacional,
    'server_now', pg_catalog.to_char(
      (pg_catalog.now() at time zone 'utc'),
      'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'
    ),
    'blocked_until', v_blocked_until,
    'pending_challenge', v_pending_challenge,
    'expires_at', v_expires_at,
    'next_screen', v_next_screen,
    'operator_state', pg_catalog.jsonb_build_object(
      'status', v_effective_status,
      'revision', coalesce(v_state.revision, 0),
      'effective_at', v_state.effective_at,
      'call_active', coalesce(v_state.call_active, false)
    ),
    'session', case
      when v_sess.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', v_sess.id,
        'status', v_sess.status,
        'expires_at', v_sess.expires_at
      )
    end,
    'shift', v_shift_info,
    'block', case
      when v_block.id is null then null
      else pg_catalog.jsonb_build_object(
        'id', v_block.id,
        'reason_code', v_block.reason_code,
        'blocked_until', v_block.blocked_until
      )
    end
  );
end;
$$;

revoke all on function private.operator_runtime_payload(uuid, uuid, text)
  from public, anon, authenticated;

comment on function private.operator_challenge_in_shift(uuid, uuid) is
  'Returns whether an operator session is currently eligible for challenges according to its effective shift.';

comment on function private.expire_operator_challenges_outside_shift(uuid, uuid) is
  'Closes every open challenge for a session that is currently outside its effective shift.';

comment on function public.operator_challenge_state(jsonb) is
  'Returns and mutates challenge state only for the authenticated active session and never schedules challenges outside its shift.';
