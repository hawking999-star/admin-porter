-- Isolate every challenge lifecycle to its authenticated active session.
-- This also makes idle acknowledgement idempotent and fixes challenge rule saves.

create or replace function private.current_operator_challenge(
  p_operator_id uuid,
  p_session_id uuid
)
returns public.challenge_logs
language sql
stable
security definer
set search_path = ''
as $$
  select cl.*
  from public.challenge_logs cl
  where cl.operator_id = p_operator_id
    and cl.session_id = p_session_id
    and cl.status in ('scheduled', 'pending', 'displayed', 'paused', 'idle')
  order by cl.created_at desc
  limit 1
$$;

-- Keep the legacy private signature safe for any existing internal caller.
create or replace function private.current_operator_challenge(p_operator_id uuid)
returns public.challenge_logs
language sql
stable
security definer
set search_path = ''
as $$
  select cl.*
  from public.challenge_logs cl
  join public.operator_sessions s
    on s.id = cl.session_id
   and s.operator_id = cl.operator_id
   and s.status = 'active'
   and s.expires_at > now()
  where cl.operator_id = p_operator_id
    and cl.status in ('scheduled', 'pending', 'displayed', 'paused', 'idle')
  order by s.started_at desc, cl.created_at desc
  limit 1
$$;

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
begin
  select * into v_block
  from public.operator_blocks
  where operator_id = p_operator_id
    and status = 'active'
    and (blocked_until is null or blocked_until > now())
  order by started_at desc
  limit 1;

  if v_block.id is not null then
    return jsonb_build_object(
      'next_screen', 'blocked',
      'blocked_until', v_block.blocked_until,
      'block_reason', v_block.reason_code,
      'server_now', now()
    );
  end if;

  select * into v_log
  from private.current_operator_challenge(p_operator_id, p_session_id);

  if v_log.id is null then
    return jsonb_build_object('next_screen', 'player', 'server_now', now());
  end if;

  select * into v_challenge
  from public.challenges
  where id = v_log.challenge_id;

  if v_log.status = 'idle' then
    return jsonb_build_object(
      'next_screen', 'idle',
      'challenge_log_id', v_log.id,
      'server_now', now()
    );
  end if;

  if v_log.status = 'paused' then
    return jsonb_build_object(
      'next_screen', 'paused_by_call',
      'challenge_log_id', v_log.id,
      'server_now', now()
    );
  end if;

  if v_log.status = 'scheduled' and v_log.scheduled_for > now() then
    return jsonb_build_object(
      'next_screen', 'player',
      'next_challenge_at', v_log.scheduled_for,
      'server_now', now()
    );
  end if;

  return jsonb_build_object(
    'next_screen', 'challenge',
    'server_now', now(),
    'challenge', jsonb_build_object(
      'log_id', v_log.id,
      'id', v_challenge.id,
      'title', v_challenge.title,
      'prompt', v_challenge.prompt,
      'kind', v_challenge.kind,
      'answer_definition', v_challenge.answer_definition - 'correct',
      'expires_at', v_log.expires_at
    )
  );
end
$$;

create or replace function public.admin_save_challenge_rules(
  p_unit_id uuid,
  p_rules jsonb
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_start_text text := coalesce(nullif(p_rules->>'active_window_start', ''), '00:00');
  v_end_text text := coalesce(nullif(p_rules->>'active_window_end', ''), '00:00');
  v_timezone text := coalesce(nullif(p_rules->>'timezone', ''), 'America/Sao_Paulo');
  v_start time;
  v_end time;
  v_window_seconds integer;
  v_rules jsonb;
  v_existing_id uuid;
begin
  perform private.require_admin_for_backend(
    array['superadmin', 'operations_manager', 'challenge_manager'],
    p_unit_id
  );

  if coalesce((p_rules->>'min_interval_seconds')::integer, 0) < 1
     or coalesce((p_rules->>'max_interval_seconds')::integer, 0)
        < coalesce((p_rules->>'min_interval_seconds')::integer, 0) then
    raise exception 'janela_intervalo_invalida';
  end if;

  if coalesce((p_rules->>'response_seconds')::integer, 0) < 1 then
    raise exception 'tempo_resposta_invalido';
  end if;

  if coalesce((p_rules->>'abandon_block_seconds')::integer, -1) < 0 then
    raise exception 'tempo_abandono_invalido';
  end if;

  if v_start_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or v_end_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'janela_horario_invalida';
  end if;

  if not exists (
    select 1 from pg_catalog.pg_timezone_names where name = v_timezone
  ) then
    raise exception 'fuso_horario_invalido';
  end if;

  v_start := v_start_text::time;
  v_end := v_end_text::time;

  if v_start <> v_end then
    v_window_seconds := case
      when v_start < v_end then extract(epoch from (v_end - v_start))::integer
      else 86400 - extract(epoch from (v_start - v_end))::integer
    end;

    if (p_rules->>'max_interval_seconds')::integer >= v_window_seconds then
      raise exception 'intervalo_maior_que_janela_horaria';
    end if;
  end if;

  v_rules := p_rules || jsonb_build_object(
    'active_window_start', v_start_text,
    'active_window_end', v_end_text,
    'timezone', v_timezone
  );

  select id into v_existing_id
  from public.system_settings
  where key = 'challenge_rules'
    and scope_type = case when p_unit_id is null then 'global' else 'unit' end
    and scope_id is not distinct from p_unit_id
  order by revision desc, updated_at desc, id desc
  limit 1
  for update;

  if v_existing_id is null then
    insert into public.system_settings(
      scope_type,
      scope_id,
      key,
      value,
      active,
      revision,
      updated_by,
      updated_at
    )
    values (
      case when p_unit_id is null then 'global' else 'unit' end,
      p_unit_id,
      'challenge_rules',
      v_rules,
      true,
      1,
      auth.uid(),
      now()
    );
  else
    update public.system_settings
    set value = v_rules,
        active = true,
        revision = revision + 1,
        updated_by = auth.uid(),
        updated_at = now()
    where id = v_existing_id;

    update public.system_settings
    set active = false,
        updated_at = now()
    where key = 'challenge_rules'
      and scope_type = case when p_unit_id is null then 'global' else 'unit' end
      and scope_id is not distinct from p_unit_id
      and id <> v_existing_id
      and active;
  end if;
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
  v_expired_log public.challenge_logs%rowtype;
  v_state public.operator_states%rowtype;
  v_shift_info jsonb;
  v_target_status text;
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

  perform pg_advisory_xact_lock(hashtext(v_op.id::text));

  -- A challenge from another login must never contaminate this session.
  update public.challenge_logs
  set status = 'expired',
      closed_at = coalesce(closed_at, now())
  where operator_id = v_op.id
    and session_id is distinct from v_session
    and status in ('scheduled', 'idle');

  update public.challenge_logs
  set status = 'abandoned',
      abandoned_at = coalesce(abandoned_at, now()),
      closed_at = null
  where operator_id = v_op.id
    and session_id is distinct from v_session
    and status in ('pending', 'displayed', 'paused');

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
      v_shift_info := public._app_shift_info(
        coalesce(
          (select shift_id from public.operator_sessions where id = v_session),
          v_op.default_shift_id
        )
      );

      v_target_status := case
        when coalesce(v_state.call_active, false) then 'in_call'
        when exists (
          select 1
          from public.operator_blocks b
          where b.operator_id = v_op.id
            and b.status = 'active'
            and (b.blocked_until is null or b.blocked_until > now())
        ) then 'blocked'
        when not coalesce((v_shift_info->>'in_shift')::boolean, true) then 'outside_shift'
        else 'active'
      end;

      perform private.set_challenge_operator_state(
        v_op.id,
        v_session,
        v_target_status,
        'challenge_stale_idle_repaired'
      );
    end if;

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
        expires_at = now() + make_interval(
          secs => coalesce((v_rules->>'response_seconds')::integer, 60)
        )
    where id = v_log.id
      and status = 'scheduled'
      and scheduled_for <= now();

    update public.challenge_logs
    set status = 'idle',
        closed_at = now()
    where id = v_log.id
      and status in ('pending', 'displayed')
      and expires_at <= now()
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
end
$$;

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

  select cl.* into v_log
  from public.challenge_logs cl
  join public.operator_sessions s
    on s.id = cl.session_id
   and s.operator_id = cl.operator_id
   and s.status = 'active'
   and s.expires_at > now()
  where cl.id = p_log_id
    and cl.operator_id = v_op.id
  for update of cl;

  if v_log.id is null then
    raise exception 'desafio_indisponivel';
  end if;

  if v_log.status = 'pending' and v_log.expires_at > now() then
    v_rules := private.challenge_rules(v_op.unit_id);

    update public.challenge_logs
    set status = 'displayed',
        displayed_at = now(),
        expires_at = now() + make_interval(
          secs => coalesce((v_rules->>'response_seconds')::integer, 60)
        )
    where id = v_log.id
    returning * into v_log;
  end if;

  return private.challenge_payload(v_op.id, v_log.session_id);
end
$$;

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
  v_challenge public.challenges%rowtype;
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

  select cl.* into v_log
  from public.challenge_logs cl
  join public.operator_sessions s
    on s.id = cl.session_id
   and s.operator_id = cl.operator_id
   and s.status = 'active'
   and s.expires_at > now()
  where cl.id = p_log_id
    and cl.operator_id = v_op.id
  for update of cl;

  if v_log.id is null
     or v_log.status not in ('pending', 'displayed')
     or v_log.expires_at <= now() then
    raise exception 'desafio_indisponivel';
  end if;

  select * into v_challenge
  from public.challenges
  where id = v_log.challenge_id;

  v_correct := lower(coalesce(p_answer->>'value', ''))
    = lower(coalesce(v_challenge.answer_definition->>'correct', ''));

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

create or replace function public.operator_challenge_resume_idle(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.operators%rowtype;
  v_session public.operator_sessions%rowtype;
  v_idle_log public.challenge_logs%rowtype;
  v_previous public.operator_states%rowtype;
  v_current public.operator_states%rowtype;
  v_shift_info jsonb;
  v_target_status text;
  v_status_operacional text;
  v_payload jsonb;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;

  if v_op.id is null then
    raise exception 'operador_invalido';
  end if;

  select * into v_session
  from public.operator_sessions
  where id = p_session_id
    and operator_id = v_op.id
    and status = 'active'
    and expires_at > now();

  if v_session.id is null then
    raise exception 'sessao_invalida';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_op.id::text));

  select * into v_idle_log
  from public.challenge_logs
  where operator_id = v_op.id
    and session_id = v_session.id
    and status = 'idle'
  order by created_at desc
  limit 1
  for update;

  -- Repeated clicks/calls are read-only after the first successful acknowledgement.
  if v_idle_log.id is null then
    v_payload := public.operator_challenge_state(
      jsonb_build_object('session_id', v_session.id)
    );

    select * into v_current
    from public.operator_states
    where operator_id = v_op.id;

    v_status_operacional := case v_current.status
      when 'active' then 'ativo'
      when 'idle' then 'ocioso'
      when 'in_call' then 'em_atendimento'
      when 'blocked' then 'bloqueado'
      when 'outside_shift' then 'fora_do_turno'
      else 'offline'
    end;

    return v_payload || jsonb_build_object(
      'status_operacional', v_status_operacional,
      'operator_state', jsonb_build_object(
        'status', v_current.status,
        'revision', v_current.revision,
        'effective_at', v_current.effective_at,
        'call_active', coalesce(v_current.call_active, false)
      )
    );
  end if;

  update public.challenge_logs
  set status = 'expired',
      closed_at = coalesce(closed_at, now())
  where id = v_idle_log.id;

  select * into v_previous
  from public.operator_states
  where operator_id = v_op.id;

  v_shift_info := public._app_shift_info(
    coalesce(v_session.shift_id, v_op.default_shift_id)
  );

  v_target_status := case
    when coalesce(v_previous.call_active, false) then 'in_call'
    when exists (
      select 1
      from public.operator_blocks b
      where b.operator_id = v_op.id
        and b.status = 'active'
        and (b.blocked_until is null or b.blocked_until > now())
    ) then 'blocked'
    when not coalesce((v_shift_info->>'in_shift')::boolean, true) then 'outside_shift'
    else 'active'
  end;

  v_current := private.set_challenge_operator_state(
    v_op.id,
    v_session.id,
    v_target_status,
    'challenge_idle_return'
  );

  v_payload := public.operator_challenge_state(
    jsonb_build_object('session_id', v_session.id)
  );

  v_status_operacional := case v_current.status
    when 'active' then 'ativo'
    when 'idle' then 'ocioso'
    when 'in_call' then 'em_atendimento'
    when 'blocked' then 'bloqueado'
    when 'outside_shift' then 'fora_do_turno'
    else 'offline'
  end;

  return v_payload || jsonb_build_object(
    'status_operacional', v_status_operacional,
    'operator_state', jsonb_build_object(
      'status', v_current.status,
      'revision', v_current.revision,
      'effective_at', v_current.effective_at,
      'call_active', coalesce(v_current.call_active, false)
    )
  );
end
$$;

create or replace function public.operator_challenge_session_ended(p_session_id uuid)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op uuid;
begin
  select id into v_op
  from public.operators
  where auth_user_id = auth.uid();

  if v_op is null or not exists (
    select 1
    from public.operator_sessions
    where id = p_session_id and operator_id = v_op
  ) then
    raise exception 'sessao_invalida';
  end if;

  perform pg_advisory_xact_lock(hashtext(v_op::text));

  update public.challenge_logs
  set status = 'expired',
      closed_at = coalesce(closed_at, now())
  where operator_id = v_op
    and session_id = p_session_id
    and status in ('scheduled', 'idle');

  update public.challenge_logs
  set status = 'abandoned',
      abandoned_at = coalesce(abandoned_at, now()),
      closed_at = null
  where operator_id = v_op
    and session_id = p_session_id
    and status in ('pending', 'displayed', 'paused');
end
$$;

-- Repair stale open records left by the previous cross-session behavior.
update public.challenge_logs cl
set status = 'expired',
    closed_at = coalesce(cl.closed_at, now())
from public.operator_sessions s
where s.id = cl.session_id
  and (s.status <> 'active' or s.expires_at <= now())
  and cl.status in ('scheduled', 'idle');

update public.challenge_logs cl
set status = 'abandoned',
    abandoned_at = coalesce(cl.abandoned_at, now()),
    closed_at = null
from public.operator_sessions s
where s.id = cl.session_id
  and (s.status <> 'active' or s.expires_at <= now())
  and cl.status in ('pending', 'displayed', 'paused');

revoke all on function private.current_operator_challenge(uuid, uuid)
  from public, anon, authenticated;
revoke all on function private.current_operator_challenge(uuid)
  from public, anon, authenticated;
revoke all on function private.challenge_payload(uuid, uuid)
  from public, anon, authenticated;

revoke all on function public.admin_save_challenge_rules(uuid, jsonb)
  from public, anon;
grant execute on function public.admin_save_challenge_rules(uuid, jsonb)
  to authenticated;

revoke all on function public.operator_challenge_state(jsonb)
  from public, anon;
grant execute on function public.operator_challenge_state(jsonb)
  to authenticated;

revoke all on function public.operator_challenge_displayed(uuid)
  from public, anon;
grant execute on function public.operator_challenge_displayed(uuid)
  to authenticated;

revoke all on function public.operator_challenge_answer(uuid, jsonb)
  from public, anon;
grant execute on function public.operator_challenge_answer(uuid, jsonb)
  to authenticated;

revoke all on function public.operator_challenge_resume_idle(uuid)
  from public, anon;
grant execute on function public.operator_challenge_resume_idle(uuid)
  to authenticated;

revoke all on function public.operator_challenge_session_ended(uuid)
  from public, anon;
grant execute on function public.operator_challenge_session_ended(uuid)
  to authenticated;

comment on function public.admin_save_challenge_rules(uuid, jsonb) is
  'Updates the single rule row for a scope, preserving revision and avoiding duplicate-key failures.';

comment on function public.operator_challenge_resume_idle(uuid) is
  'Acknowledges one idle challenge once; repeated calls are idempotent and cannot toggle state.';

comment on function public.operator_challenge_state(jsonb) is
  'Returns and mutates challenge state only for the authenticated active operator session.';
