create schema if not exists private;

alter table public.operator_states
  add column if not exists call_active boolean not null default false,
  add column if not exists call_source text,
  add column if not exists call_started_at timestamptz,
  add column if not exists call_event_id uuid,
  add column if not exists call_previous_status text;

create index if not exists operator_states_call_active_idx
  on public.operator_states (call_active, updated_at)
  where call_active = true;

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
    and (blocked_until is null or blocked_until > now())
  order by started_at desc
  limit 1;

  if v_block.id is not null then
    v_blocked_until := v_block.blocked_until;
  end if;

  select
    cl.id,
    cl.challenge_id,
    cl.status,
    cl.expires_at,
    cl.paused_at,
    cl.resumed_at,
    cl.pause_reason,
    c.title,
    c.prompt,
    c.kind,
    c.answer_definition
  into v_challenge
  from public.challenge_logs cl
  join public.challenges c on c.id = cl.challenge_id
  where cl.operator_id = p_operator_id
    and cl.status in ('pending', 'displayed', 'paused')
    and (p_session_id is null or cl.session_id is null or cl.session_id = p_session_id)
  order by cl.created_at desc
  limit 1;

  if v_challenge.id is not null then
    v_expires_at := case
      when coalesce(v_state.call_active, false) then null
      else v_challenge.expires_at
    end;
    v_pending_challenge := jsonb_build_object(
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

  v_status_operacional := case coalesce(v_state.status, 'offline')
    when 'active' then 'ativo'
    when 'idle' then 'ocioso'
    when 'in_call' then 'em_atendimento'
    when 'blocked' then 'bloqueado'
    when 'outside_shift' then 'fora_do_turno'
    else 'offline'
  end;

  v_next_screen := case
    when coalesce(v_state.call_active, false) then 'call'
    when v_block.id is not null then 'blocked'
    when v_pending_challenge is not null then 'challenge'
    when coalesce(v_state.status, 'offline') = 'outside_shift' then 'outside_shift'
    when coalesce(v_state.status, 'offline') = 'offline' then 'login'
    else 'player'
  end;

  v_shift_info := public._app_shift_info(coalesce(v_sess.shift_id, v_op.default_shift_id));

  return jsonb_build_object(
    'result', p_result,
    'call_active', coalesce(v_state.call_active, false),
    'status_operacional', v_status_operacional,
    'server_now', to_char((now() at time zone 'utc'),'YYYY-MM-DD"T"HH24:MI:SS.MS"Z"'),
    'blocked_until', v_blocked_until,
    'pending_challenge', v_pending_challenge,
    'expires_at', v_expires_at,
    'next_screen', v_next_screen,
    'operator_state', jsonb_build_object(
      'status', coalesce(v_state.status, 'offline'),
      'revision', coalesce(v_state.revision, 0),
      'effective_at', v_state.effective_at,
      'call_active', coalesce(v_state.call_active, false)
    ),
    'session', case when v_sess.id is null then null else jsonb_build_object(
      'id', v_sess.id,
      'status', v_sess.status,
      'expires_at', v_sess.expires_at
    ) end,
    'shift', v_shift_info,
    'block', case when v_block.id is null then null else jsonb_build_object(
      'id', v_block.id,
      'reason_code', v_block.reason_code,
      'blocked_until', v_block.blocked_until
    ) end
  );
end;
$$;

create or replace function public.operator_operational_event(p_request jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_uid uuid := auth.uid();
  v_req_id text := p_request->>'request_id';
  v_event text := p_request->>'event';
  v_event_id uuid := nullif(p_request->>'event_id', '')::uuid;
  v_source text := coalesce(nullif(p_request->>'source', ''), 'local');
  v_occurred_at timestamptz := coalesce(nullif(p_request->>'occurred_at', '')::timestamptz, now());
  v_metadata jsonb := coalesce(p_request->'metadata', '{}'::jsonb);
  v_session_id uuid := nullif(p_request->>'session_id', '')::uuid;
  v_device_id uuid := nullif(p_request->>'device_id', '')::uuid;
  v_op public.operators%rowtype;
  v_sess public.operator_sessions%rowtype;
  v_state public.operator_states%rowtype;
  v_previous_status text;
  v_target_status text;
  v_shift_info jsonb;
  v_blocked boolean;
  v_in_shift boolean;
  v_result text := 'applied';
  v_payload jsonb;
  v_response jsonb;
  v_changed boolean := false;
begin
  if v_uid is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Sessao de autenticacao ausente.'),null);
  end if;

  if v_event not in ('call_started', 'call_finished') then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_EVENT','message','Evento operacional invalido.'),null);
  end if;

  if v_event_id is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','EVENT_ID_REQUIRED','message','event_id e obrigatorio.'),null);
  end if;

  select * into v_op
  from public.operators
  where auth_user_id = v_uid;

  if not found or v_op.active is not true then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INVALID_CREDENTIALS','message','Operador nao encontrado ou inativo.'),null);
  end if;

  if exists (
    select 1
    from public.app_request_idempotency
    where idempotency_key = v_event_id
      and rpc_name = 'operator_operational_event'
  ) then
    select * into v_sess
    from public.operator_sessions
    where operator_id = v_op.id
      and status = 'active'
    order by started_at desc
    limit 1;

    v_payload := private.operator_runtime_payload(v_op.id, coalesce(v_session_id, v_sess.id), 'duplicate');
    return public._app_envelope(v_req_id,true,v_payload,null,jsonb_build_object('duplicate',true));
  end if;

  perform pg_advisory_xact_lock(hashtext(v_op.id::text));

  if v_session_id is not null then
    select * into v_sess
    from public.operator_sessions
    where id = v_session_id
      and operator_id = v_op.id;
  else
    select * into v_sess
    from public.operator_sessions
    where operator_id = v_op.id
      and status = 'active'
      and expires_at > now()
    order by started_at desc
    limit 1;
  end if;

  if v_sess.id is null then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_NOT_FOUND','message','Sessao ativa nao encontrada.'),null);
  end if;

  if v_sess.status <> 'active' or v_sess.expires_at <= now() then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','SESSION_NOT_ACTIVE','message','Sessao nao esta ativa.'),null);
  end if;

  select * into v_state
  from public.operator_states
  where operator_id = v_op.id
  for update;

  if v_state.operator_id is null then
    insert into public.operator_states(
      operator_id, session_id, status, call_active, effective_at, revision, updated_at
    )
    values (
      v_op.id, v_sess.id, 'active', false, now(), 1, now()
    )
    returning * into v_state;
  end if;

  if v_event = 'call_started' then
    if coalesce(v_state.call_active, false) or v_state.status = 'in_call' then
      v_result := 'no_change';
    else
      v_previous_status := v_state.status;

      update public.operator_states
      set status = 'in_call',
          activity = 'call',
          reason_code = 'call_active',
          session_id = v_sess.id,
          call_active = true,
          call_source = v_source,
          call_started_at = v_occurred_at,
          call_event_id = v_event_id,
          call_previous_status = v_previous_status,
          effective_at = v_occurred_at,
          revision = revision + 1,
          updated_at = now()
      where operator_id = v_op.id
      returning * into v_state;

      insert into public.operator_status_history(
        operator_id, session_id, from_status, to_status, reason_code, source, occurred_at, state_revision, metadata
      )
      values (
        v_op.id, v_sess.id, v_previous_status, 'in_call', 'call_started', v_source, v_occurred_at, v_state.revision,
        jsonb_build_object('event_id', v_event_id, 'metadata', v_metadata)
      );

      update public.challenge_logs
      set status = 'paused',
          paused_at = coalesce(paused_at, v_occurred_at),
          pause_reason = 'call_active',
          revision = revision + 1
      where operator_id = v_op.id
        and status in ('pending', 'displayed')
        and (session_id is null or session_id = v_sess.id);

      insert into public.operational_events(
        event_type, operator_id, session_id, device_id, unit_id, idempotency_key,
        client_sent_at, occurred_at, payload
      )
      values (
        'call.started', v_op.id, v_sess.id, v_device_id, v_op.unit_id, v_event_id,
        v_occurred_at, v_occurred_at,
        jsonb_build_object('event', v_event, 'source', v_source, 'metadata', v_metadata)
      )
      on conflict do nothing;

      v_changed := true;
    end if;
  else
    if not coalesce(v_state.call_active, false) and v_state.status <> 'in_call' then
      v_result := 'no_change';
    else
      v_previous_status := v_state.status;
      v_blocked := exists (
        select 1
        from public.operator_blocks b
        where b.operator_id = v_op.id
          and b.status = 'active'
          and (b.blocked_until is null or b.blocked_until > now())
      );
      v_shift_info := public._app_shift_info(coalesce(v_sess.shift_id, v_op.default_shift_id));
      v_in_shift := coalesce((v_shift_info->>'in_shift')::boolean, true);
      v_target_status := case
        when v_blocked then 'blocked'
        when not v_in_shift then 'outside_shift'
        when v_state.call_previous_status = 'idle' then 'idle'
        else 'active'
      end;

      update public.challenge_logs cl
      set status = 'pending',
          resumed_at = v_occurred_at,
          expires_at = v_occurred_at + make_interval(secs => greatest(coalesce(c.duration_seconds, 60), 15)),
          revision = cl.revision + 1
      from public.challenges c
      where c.id = cl.challenge_id
        and cl.operator_id = v_op.id
        and cl.status = 'paused'
        and cl.pause_reason = 'call_active'
        and (cl.session_id is null or cl.session_id = v_sess.id);

      update public.operator_states
      set status = v_target_status,
          activity = null,
          reason_code = 'call_finished',
          session_id = v_sess.id,
          call_active = false,
          call_source = null,
          call_event_id = v_event_id,
          call_previous_status = null,
          effective_at = v_occurred_at,
          revision = revision + 1,
          updated_at = now()
      where operator_id = v_op.id
      returning * into v_state;

      insert into public.operator_status_history(
        operator_id, session_id, from_status, to_status, reason_code, source, occurred_at, state_revision, metadata
      )
      values (
        v_op.id, v_sess.id, v_previous_status, v_target_status, 'call_finished', v_source, v_occurred_at, v_state.revision,
        jsonb_build_object('event_id', v_event_id, 'metadata', v_metadata)
      );

      insert into public.operational_events(
        event_type, operator_id, session_id, device_id, unit_id, idempotency_key,
        client_sent_at, occurred_at, payload
      )
      values (
        'call.ended', v_op.id, v_sess.id, v_device_id, v_op.unit_id, v_event_id,
        v_occurred_at, v_occurred_at,
        jsonb_build_object('event', v_event, 'source', v_source, 'metadata', v_metadata)
      )
      on conflict do nothing;

      v_changed := true;
    end if;
  end if;

  v_payload := private.operator_runtime_payload(v_op.id, v_sess.id, v_result);
  v_response := public._app_envelope(
    v_req_id,
    true,
    v_payload,
    null,
    jsonb_build_object('changed', v_changed, 'event_id', v_event_id)
  );

  insert into public.app_request_idempotency(
    idempotency_key, rpc_name, operator_id, request_hash, response
  )
  values (
    v_event_id,
    'operator_operational_event',
    v_op.id,
    md5(v_event || '|' || v_source || '|' || coalesce(v_session_id::text, '') || '|' || v_metadata::text),
    v_response
  )
  on conflict do nothing;

  return v_response;
exception
  when unique_violation then
    v_payload := private.operator_runtime_payload(v_op.id, coalesce(v_session_id, v_sess.id), 'duplicate');
    return public._app_envelope(v_req_id,true,v_payload,null,jsonb_build_object('duplicate',true));
  when others then
    return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end;
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
  v_op record; v_sess record; v_shift_info jsonb; v_ver jsonb;
  v_blocked boolean; v_in_shift boolean; v_state text; v_prev record;
  v_config_rev bigint; v_playback boolean; v_shift_json jsonb; v_shift uuid;
  v_unit record; v_unit_json jsonb; v_call_active boolean := false;
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
  update public.operator_sessions set last_heartbeat_at=now(), app_version=coalesce(nullif(v_app_version,''),app_version), updated_at=now() where id=v_sess.id;
  v_shift := coalesce(v_sess.shift_id, v_op.default_shift_id);
  if v_sess.shift_id is null and v_shift is not null then
    update public.operator_sessions set shift_id = v_shift, updated_at = now() where id = v_sess.id;
  end if;
  v_blocked := exists(select 1 from public.operator_blocks b where b.operator_id=v_op.id and b.status='active' and (b.blocked_until is null or b.blocked_until>now()));
  v_shift_info := public._app_shift_info(v_shift);
  v_in_shift := coalesce((v_shift_info->>'in_shift')::boolean, true);
  v_ver := public._app_version_check(v_op.unit_id, v_app_version, null, null);
  select * into v_prev from public.operator_states where operator_id=v_op.id;
  v_call_active := coalesce(v_prev.call_active, false);
  v_state := case
    when v_call_active then 'in_call'
    when v_blocked then 'blocked'
    when not v_in_shift then 'outside_shift'
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
           effective_at=case when call_active then effective_at else now() end,
           revision=revision+1,
           updated_at=now()
     where operator_id=v_op.id
     returning * into v_prev;
    insert into public.operator_status_history(operator_id,session_id,from_status,to_status,reason_code,source,state_revision)
      values(v_op.id,v_sess.id,null,v_state,'reconcile','backend',v_prev.revision);
  end if;
  select coalesce(max(revision),0) into v_config_rev from public.system_settings
    where active=true and (scope_type='global' or (scope_type='unit' and scope_id=v_op.unit_id));
  v_playback := v_in_shift and not v_blocked and not coalesce(v_prev.call_active,false) and (v_ver->>'allowed')::boolean;
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
      'challenge',null,'block',null,
      'call',jsonb_build_object('active',coalesce(v_prev.call_active,false),'source',v_prev.call_source,'started_at',v_prev.call_started_at)
    ),
    null,
    jsonb_build_object('revision',v_prev.revision)
  );
exception when others then
  return public._app_envelope(v_req_id,false,null,jsonb_build_object('code','INTERNAL_ERROR','message',SQLERRM),null);
end;
$$;

revoke all on function private.operator_runtime_payload(uuid, uuid, text) from public, anon, authenticated;
revoke all on function public.operator_operational_event(jsonb) from public, anon;
grant execute on function public.operator_operational_event(jsonb) to authenticated;

revoke all on function public.reconcile_operator_state(jsonb) from public, anon;
grant execute on function public.reconcile_operator_state(jsonb) to authenticated;
