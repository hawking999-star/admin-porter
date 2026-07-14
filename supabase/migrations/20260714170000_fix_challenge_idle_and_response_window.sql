-- Align the challenge countdown with the moment it is delivered and keep the
-- operational status synchronized with the idle challenge screen.

create or replace function private.set_challenge_operator_state(
  p_operator_id uuid,
  p_session_id uuid,
  p_status text,
  p_reason_code text
)
returns public.operator_states
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_previous public.operator_states%rowtype;
  v_current public.operator_states%rowtype;
  v_target_status text := p_status;
begin
  if v_target_status not in (
    'active', 'in_call', 'idle', 'blocked', 'outside_shift', 'offline'
  ) then
    raise exception 'status_operacional_invalido';
  end if;

  select * into v_previous
  from public.operator_states
  where operator_id = p_operator_id
  for update;

  if coalesce(v_previous.call_active, false) and v_target_status <> 'in_call' then
    v_target_status := 'in_call';
  end if;

  if v_previous.operator_id is null then
    insert into public.operator_states(
      operator_id,
      session_id,
      status,
      activity,
      reason_code,
      call_active,
      effective_at,
      revision,
      updated_at
    )
    values (
      p_operator_id,
      p_session_id,
      v_target_status,
      case when v_target_status = 'idle' then 'challenge_idle' else null end,
      p_reason_code,
      false,
      now(),
      1,
      now()
    )
    returning * into v_current;

    insert into public.operator_status_history(
      operator_id,
      session_id,
      from_status,
      to_status,
      reason_code,
      source,
      occurred_at,
      state_revision
    )
    values (
      p_operator_id,
      p_session_id,
      null,
      v_target_status,
      p_reason_code,
      'challenge_backend',
      now(),
      v_current.revision
    );
  elsif v_previous.status is distinct from v_target_status
     or v_previous.session_id is distinct from p_session_id then
    update public.operator_states
    set session_id = p_session_id,
        status = v_target_status,
        activity = case when v_target_status = 'idle' then 'challenge_idle' else null end,
        reason_code = p_reason_code,
        effective_at = now(),
        revision = revision + 1,
        updated_at = now()
    where operator_id = p_operator_id
    returning * into v_current;

    insert into public.operator_status_history(
      operator_id,
      session_id,
      from_status,
      to_status,
      reason_code,
      source,
      occurred_at,
      state_revision
    )
    values (
      p_operator_id,
      p_session_id,
      v_previous.status,
      v_target_status,
      p_reason_code,
      'challenge_backend',
      now(),
      v_current.revision
    );
  else
    v_current := v_previous;
  end if;

  return v_current;
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

  select * into v_log
  from public.challenge_logs
  where id = p_log_id and operator_id = v_op.id
  for update;

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

create or replace function public.operator_challenge_resume_idle(p_session_id uuid)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.operators%rowtype;
  v_session public.operator_sessions%rowtype;
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

  update public.challenge_logs
  set status = 'expired',
      closed_at = coalesce(closed_at, now())
  where operator_id = v_op.id
    and session_id = v_session.id
    and status = 'idle';

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

create or replace function public.reconcile_operator_state(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_req_id text := p_request->>'request_id';
  v_session_id uuid := nullif(p_request->>'session_id','')::uuid;
  v_app_version text := coalesce(p_request->>'app_version','');
  v_op record;
  v_sess record;
  v_shift_info jsonb;
  v_ver jsonb;
  v_blocked boolean;
  v_idle boolean;
  v_in_shift boolean;
  v_state text;
  v_prev record;
  v_config_rev bigint;
  v_playback boolean;
  v_shift_json jsonb;
  v_shift uuid;
  v_unit record;
  v_unit_json jsonb;
  v_call_active boolean := false;
begin
  if v_uid is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Sessao de autenticacao ausente.'),null);
  end if;

  select * into v_op from public.operators where auth_user_id=v_uid;
  if not found or v_op.active is not true then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Operador nao encontrado ou inativo.'),null);
  end if;

  select * into v_unit from public.units where id=v_op.unit_id;
  v_unit_json := case when v_unit.id is null then null
    else jsonb_build_object('id',v_unit.id,'code',v_unit.code,'name',v_unit.name,'timezone',v_unit.timezone,'active',v_unit.active) end;

  select * into v_sess from public.operator_sessions where id=v_session_id;
  if not found or v_sess.operator_id <> v_op.id then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_REVOKED','message','Sessao nao encontrada.'),null);
  end if;
  if v_sess.status='revoked' then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_REVOKED','message','Sessao revogada.'),null);
  end if;
  if v_sess.status='ended' then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_REVOKED','message','Sessao encerrada.'),null);
  end if;
  if v_sess.status='expired' or v_sess.expires_at<=now() then
    update public.operator_sessions set status='expired', updated_at=now() where id=v_sess.id and status='active';
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_EXPIRED','message','Sessao expirada.'),null);
  end if;

  update public.operator_sessions
  set last_heartbeat_at=now(),
      app_version=coalesce(nullif(v_app_version,''),app_version),
      updated_at=now()
  where id=v_sess.id;

  v_shift := coalesce(v_sess.shift_id, v_op.default_shift_id);
  if v_sess.shift_id is null and v_shift is not null then
    update public.operator_sessions set shift_id=v_shift, updated_at=now() where id=v_sess.id;
  end if;

  v_blocked := exists(
    select 1 from public.operator_blocks b
    where b.operator_id=v_op.id
      and b.status='active'
      and (b.blocked_until is null or b.blocked_until>now())
  );
  v_idle := exists(
    select 1 from public.challenge_logs cl
    where cl.operator_id=v_op.id
      and cl.session_id=v_sess.id
      and cl.status='idle'
  );
  v_shift_info := public._app_shift_info(v_shift);
  v_in_shift := coalesce((v_shift_info->>'in_shift')::boolean, true);
  v_ver := public._app_version_check(v_op.unit_id, v_app_version, null, null);

  select * into v_prev from public.operator_states where operator_id=v_op.id;
  v_call_active := coalesce(v_prev.call_active, false);
  v_state := case
    when v_call_active then 'in_call'
    when v_blocked then 'blocked'
    when not v_in_shift then 'outside_shift'
    when v_idle then 'idle'
    else 'active'
  end;

  if not found then
    insert into public.operator_states(operator_id,session_id,status,call_active,effective_at,revision,updated_at)
      values(v_op.id,v_sess.id,v_state,false,now(),1,now());
    select * into v_prev from public.operator_states where operator_id=v_op.id;
  elsif v_prev.status is distinct from v_state or v_prev.session_id is distinct from v_sess.id then
    update public.operator_states
       set status=v_state,
           session_id=v_sess.id,
           activity=case when v_state='idle' then 'challenge_idle' else null end,
           reason_code=case when v_state='idle' then 'challenge_expired' else 'reconcile' end,
           effective_at=case when call_active then effective_at else now() end,
           revision=revision+1,
           updated_at=now()
     where operator_id=v_op.id
     returning * into v_prev;
    insert into public.operator_status_history(operator_id,session_id,from_status,to_status,reason_code,source,state_revision)
      values(v_op.id,v_sess.id,null,v_state,case when v_state='idle' then 'challenge_expired' else 'reconcile' end,'backend',v_prev.revision);
  end if;

  select coalesce(max(revision),0) into v_config_rev
  from public.system_settings
  where active=true and (scope_type='global' or (scope_type='unit' and scope_id=v_op.unit_id));

  v_playback := v_state='active'
    and v_in_shift
    and not v_blocked
    and not coalesce(v_prev.call_active,false)
    and (v_ver->>'allowed')::boolean;
  v_shift_json := v_shift_info;

  return public._app_envelope(v_req_id,true,
    jsonb_build_object(
      'session',jsonb_build_object('id',v_sess.id,'status',v_sess.status,'expires_at',v_sess.expires_at),
      'unit',v_unit_json,
      'operator',jsonb_build_object('id',v_op.id,'display_name',v_op.display_name),
      'operator_state',jsonb_build_object('status',v_state,'revision',v_prev.revision,'call_active',coalesce(v_prev.call_active,false)),
      'shift',v_shift_json,
      'version',jsonb_build_object('allowed',(v_ver->>'allowed')::boolean,'update_policy',v_ver->>'update_policy'),
      'playback_allowed',v_playback,
      'configuration',jsonb_build_object('revision',v_config_rev),
      'challenge',null,
      'block',null,
      'call',jsonb_build_object('active',coalesce(v_prev.call_active,false),'source',v_prev.call_source,'started_at',v_prev.call_started_at)
    ),
    null,
    jsonb_build_object('revision',v_prev.revision)
  );
exception when others then
  return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end
$$;

revoke all on function private.set_challenge_operator_state(uuid, uuid, text, text)
  from public, anon, authenticated;

revoke all on function public.operator_challenge_state(jsonb)
  from public, anon;
grant execute on function public.operator_challenge_state(jsonb)
  to authenticated;

revoke all on function public.operator_challenge_displayed(uuid)
  from public, anon;
grant execute on function public.operator_challenge_displayed(uuid)
  to authenticated;

revoke all on function public.operator_challenge_resume_idle(uuid)
  from public, anon;
grant execute on function public.operator_challenge_resume_idle(uuid)
  to authenticated;

revoke all on function public.reconcile_operator_state(jsonb)
  from public, anon;
grant execute on function public.reconcile_operator_state(jsonb)
  to authenticated;

comment on function public.operator_challenge_displayed(uuid) is
  'Confirms first display and starts the full configured response window exactly once.';

comment on function public.operator_challenge_resume_idle(uuid) is
  'Acknowledges challenge idleness, restores the official operational status and returns the next challenge snapshot.';
