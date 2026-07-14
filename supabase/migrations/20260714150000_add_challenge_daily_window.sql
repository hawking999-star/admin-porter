-- Restrict new challenge schedules to an admin-defined daily window.

create or replace function private.challenge_schedule_at(
  p_rules jsonb,
  p_delay_seconds integer,
  p_reference timestamptz default now()
)
returns timestamptz
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_timezone text := coalesce(nullif(p_rules->>'timezone', ''), 'America/Sao_Paulo');
  v_start time := coalesce(nullif(p_rules->>'active_window_start', '')::time, '00:00'::time);
  v_end time := coalesce(nullif(p_rules->>'active_window_end', '')::time, '00:00'::time);
  v_local_reference timestamp;
  v_local_base timestamp;
  v_local_candidate timestamp;
  v_end_boundary timestamp;
begin
  v_local_reference := p_reference at time zone v_timezone;

  -- Equal times mean an unrestricted 24-hour window.
  if v_start = v_end then
    return p_reference + make_interval(secs => greatest(p_delay_seconds, 0));
  end if;

  if v_start < v_end then
    if v_local_reference::time < v_start then
      v_local_base := v_local_reference::date + v_start;
    elsif v_local_reference::time >= v_end then
      v_local_base := (v_local_reference::date + 1) + v_start;
    else
      v_local_base := v_local_reference;
    end if;

    v_local_candidate := v_local_base + make_interval(secs => greatest(p_delay_seconds, 0));
    v_end_boundary := v_local_base::date + v_end;

    if v_local_candidate >= v_end_boundary then
      v_local_candidate := (v_local_base::date + 1) + v_start
        + make_interval(secs => greatest(p_delay_seconds, 0));
    end if;
  else
    -- Overnight window, for example 18:00-06:00.
    if v_local_reference::time >= v_start or v_local_reference::time < v_end then
      v_local_base := v_local_reference;
    else
      v_local_base := v_local_reference::date + v_start;
    end if;

    v_local_candidate := v_local_base + make_interval(secs => greatest(p_delay_seconds, 0));
    if v_local_base::time >= v_start then
      v_end_boundary := (v_local_base::date + 1) + v_end;
    else
      v_end_boundary := v_local_base::date + v_end;
    end if;

    if v_local_candidate >= v_end_boundary then
      v_local_candidate := v_end_boundary::date + v_start
        + make_interval(secs => greatest(p_delay_seconds, 0));
    end if;
  end if;

  return v_local_candidate at time zone v_timezone;
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
begin
  perform private.require_admin_for_backend(
    array['superadmin','operations_manager','challenge_manager'],
    p_unit_id
  );

  if coalesce((p_rules->>'min_interval_seconds')::integer, 0) < 1
     or coalesce((p_rules->>'max_interval_seconds')::integer, 0)
        < coalesce((p_rules->>'min_interval_seconds')::integer, 0) then
    raise exception 'janela_intervalo_invalida';
  end if;

  if v_start_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
     or v_end_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
    raise exception 'janela_horario_invalida';
  end if;

  if not exists (select 1 from pg_catalog.pg_timezone_names where name = v_timezone) then
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

  update public.system_settings
  set active = false,
      updated_at = now()
  where key = 'challenge_rules'
    and scope_type = case when p_unit_id is null then 'global' else 'unit' end
    and scope_id is not distinct from p_unit_id
    and active;

  insert into public.system_settings(scope_type, scope_id, key, value)
  values (
    case when p_unit_id is null then 'global' else 'unit' end,
    p_unit_id,
    'challenge_rules',
    v_rules
  );
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
  v_session uuid := nullif(p_request->>'session_id','')::uuid;
  v_rules jsonb;
  v_log public.challenge_logs%rowtype;
  v_delay integer;
  v_candidate uuid;
  v_scheduled_for timestamptz;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;

  if v_op.id is null then raise exception 'operador_invalido'; end if;
  if not exists (
    select 1 from public.operator_sessions
    where id = v_session and operator_id = v_op.id
      and status = 'active' and expires_at > now()
  ) then raise exception 'sessao_invalida'; end if;

  select * into v_log
  from public.challenge_logs
  where operator_id = v_op.id and status = 'abandoned' and closed_at is null
  order by abandoned_at desc limit 1;

  if v_log.id is not null then
    v_rules := private.challenge_rules(v_op.unit_id);
    insert into public.operator_blocks(operator_id,status,reason_code,blocked_until,metadata)
    values (
      v_op.id,
      'active',
      'challenge_abandoned',
      now() + make_interval(secs => coalesce((v_rules->>'abandon_block_seconds')::integer, 300)),
      jsonb_build_object('challenge_log_id', v_log.id)
    );
    update public.challenge_logs set closed_at = now() where id = v_log.id;
    return private.challenge_payload(v_op.id, v_session);
  end if;

  select * into v_log from private.current_operator_challenge(v_op.id);
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
        select 1 from public.challenge_logs l
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
        challenge_id, operator_id, session_id, status,
        scheduled_for, pending_at, expires_at
      )
      values (
        v_candidate, v_op.id, v_session, 'scheduled',
        v_scheduled_for, now(),
        v_scheduled_for + make_interval(secs => coalesce((v_rules->>'response_seconds')::integer, 60))
      );
    end if;
  else
    update public.challenge_logs
    set status = 'pending', displayed_at = coalesce(displayed_at, now())
    where id = v_log.id and status = 'scheduled' and scheduled_for <= now();

    update public.challenge_logs
    set status = 'idle', closed_at = now()
    where id = v_log.id
      and status in ('pending','displayed') and expires_at <= now();
  end if;

  return private.challenge_payload(v_op.id, v_session);
end
$$;

revoke all on function private.challenge_schedule_at(jsonb, integer, timestamptz)
  from public, anon, authenticated;
revoke all on function public.admin_save_challenge_rules(uuid, jsonb)
  from public, anon;
grant execute on function public.admin_save_challenge_rules(uuid, jsonb)
  to authenticated;
revoke all on function public.operator_challenge_state(jsonb)
  from public, anon;
grant execute on function public.operator_challenge_state(jsonb)
  to authenticated;

comment on function private.challenge_schedule_at(jsonb, integer, timestamptz) is
  'Schedules a challenge inside the configured local daily window.';
