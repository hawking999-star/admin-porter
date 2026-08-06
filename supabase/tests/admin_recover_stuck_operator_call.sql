begin;

do $test$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_challenge_id uuid;
  v_session_id uuid := pg_catalog.gen_random_uuid();
  v_expired_session_id uuid := pg_catalog.gen_random_uuid();
  v_recent_session_id uuid := pg_catalog.gen_random_uuid();
  v_paused_log_id uuid := pg_catalog.gen_random_uuid();
  v_idle_log_id uuid := pg_catalog.gen_random_uuid();
  v_revision bigint;
  v_payload jsonb;
  v_audit_count integer;
  v_event_count integer;
begin
  if pg_catalog.has_function_privilege(
    'anon',
    'public.admin_recover_stuck_operator_call(uuid,bigint)',
    'execute'
  ) then
    raise exception 'anon_must_not_execute_admin_recover_stuck_operator_call';
  end if;

  if not pg_catalog.has_function_privilege(
    'authenticated',
    'public.admin_recover_stuck_operator_call(uuid,bigint)',
    'execute'
  ) then
    raise exception 'authenticated_admin_must_execute_admin_recover_stuck_operator_call';
  end if;

  select admin_row.*
    into v_admin
  from public.admin_users admin_row
  where admin_row.active
    and admin_row.role = 'superadmin'
    and admin_row.auth_user_id is not null
  order by admin_row.created_at, admin_row.id
  limit 1;

  if v_admin.id is null then
    raise exception 'test_requires_active_superadmin';
  end if;

  select operator_row.*
    into v_operator
  from public.operators operator_row
  where operator_row.active
    and operator_row.auth_user_id is not null
    and operator_row.unit_id is not null
    and not exists (
      select 1
      from public.operator_sessions session_row
      where session_row.operator_id = operator_row.id
        and session_row.status = 'active'
        and session_row.expires_at > pg_catalog.now()
    )
  order by operator_row.created_at, operator_row.id
  limit 1;

  if v_operator.id is null then
    raise exception 'test_requires_active_operator_without_current_session';
  end if;

  select challenge_row.id
    into v_challenge_id
  from public.challenges challenge_row
  order by challenge_row.created_at, challenge_row.id
  limit 1;

  if v_challenge_id is null then
    raise exception 'test_requires_one_challenge';
  end if;

  update public.operator_sessions
     set status = 'revoked',
         ended_at = pg_catalog.now(),
         end_reason = 'test_setup',
         updated_at = pg_catalog.now()
   where operator_id = v_operator.id
     and status = 'active';

  update public.challenge_logs
     set status = case
           when status in ('scheduled', 'idle') then 'expired'
           else 'abandoned'
         end,
         closed_at = case
           when status in ('scheduled', 'idle') then coalesce(closed_at, pg_catalog.now())
           else null
         end,
         abandoned_at = case
           when status in ('pending', 'displayed', 'paused') then coalesce(abandoned_at, pg_catalog.now())
           else abandoned_at
         end,
         revision = revision + 1
   where operator_id = v_operator.id
     and status in ('scheduled', 'pending', 'displayed', 'paused', 'idle');

  insert into public.operator_sessions(
    id,
    operator_id,
    unit_id,
    status,
    expires_at,
    last_heartbeat_at,
    app_version,
    contract_version
  ) values (
    v_session_id,
    v_operator.id,
    v_operator.unit_id,
    'active',
    pg_catalog.now() + interval '1 hour',
    pg_catalog.now(),
    'test-admin-call-recovery',
    1
  );

  insert into public.operator_states(
    operator_id,
    session_id,
    status,
    activity,
    reason_code,
    effective_at,
    call_active,
    call_source,
    call_started_at,
    call_event_id,
    call_previous_status
  ) values (
    v_operator.id,
    v_session_id,
    'in_call',
    'call',
    'call_active',
    pg_catalog.now() - interval '20 minutes',
    true,
    'microsip',
    pg_catalog.now() - interval '20 minutes',
    pg_catalog.gen_random_uuid(),
    'active'
  )
  on conflict (operator_id) do update
    set session_id = excluded.session_id,
        status = excluded.status,
        activity = excluded.activity,
        reason_code = excluded.reason_code,
        effective_at = excluded.effective_at,
        call_active = excluded.call_active,
        call_source = excluded.call_source,
        call_started_at = excluded.call_started_at,
        call_event_id = excluded.call_event_id,
        call_previous_status = excluded.call_previous_status,
        revision = public.operator_states.revision + 1,
        updated_at = pg_catalog.now()
  returning revision into v_revision;

  insert into public.challenge_logs(
    id,
    challenge_id,
    operator_id,
    session_id,
    status,
    paused_at,
    pause_reason,
    expires_at
  ) values (
    v_paused_log_id,
    v_challenge_id,
    v_operator.id,
    v_session_id,
    'paused',
    pg_catalog.now() - interval '19 minutes',
    'call_active',
    pg_catalog.now() + interval '1 hour'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_admin.auth_user_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_payload := public.admin_recover_stuck_operator_call(
    v_operator.id,
    v_revision
  );

  if v_payload->>'result' <> 'resolved'
     or v_payload->>'status' <> 'offline'
     or v_payload->>'session_status' <> 'revoked' then
    raise exception 'active_session_recovery_contract_failed: %', v_payload;
  end if;

  if not exists (
    select 1
    from public.operator_sessions session_row
    where session_row.id = v_session_id
      and session_row.status = 'revoked'
      and session_row.end_reason = 'admin_stuck_call_recovery'
      and session_row.ended_at is not null
  ) then
    raise exception 'active_session_was_not_revoked';
  end if;

  if not exists (
    select 1
    from public.operator_states state_row
    where state_row.operator_id = v_operator.id
      and state_row.status = 'offline'
      and state_row.call_active = false
      and state_row.activity is null
      and state_row.call_source is null
      and state_row.call_started_at is null
      and state_row.call_event_id is null
      and state_row.call_previous_status is null
      and state_row.reason_code = 'admin_stuck_call_recovery'
  ) then
    raise exception 'operator_transient_call_state_was_not_cleared';
  end if;

  if not exists (
    select 1
    from public.challenge_logs challenge_log
    where challenge_log.id = v_paused_log_id
      and challenge_log.status = 'abandoned'
      and challenge_log.metadata->>'abandoned_reason' = 'admin_stuck_call_recovery'
  ) then
    raise exception 'paused_challenge_was_not_abandoned';
  end if;

  select pg_catalog.count(*)::integer
    into v_audit_count
  from public.admin_audit_logs audit_log
  where audit_log.admin_user_id = v_admin.id
    and audit_log.action = 'operator_stuck_call_recovered'
    and audit_log.entity_id = v_operator.id;

  select pg_catalog.count(*)::integer
    into v_event_count
  from public.operational_events event_row
  where event_row.operator_id = v_operator.id
    and event_row.event_type = 'call.admin_forced_end';

  if v_audit_count <> 1 or v_event_count <> 1 then
    raise exception 'recovery_audit_evidence_missing: audit %, event %', v_audit_count, v_event_count;
  end if;

  if not exists (
    select 1
    from public.operator_status_history history_row
    where history_row.operator_id = v_operator.id
      and history_row.session_id = v_session_id
      and history_row.from_status = 'in_call'
      and history_row.to_status = 'offline'
      and history_row.reason_code = 'admin_stuck_call_recovery'
      and history_row.source = 'admin_panel'
  ) then
    raise exception 'operator_status_history_evidence_missing';
  end if;

  v_payload := public.admin_recover_stuck_operator_call(
    v_operator.id,
    v_revision
  );

  if v_payload->>'result' <> 'already_resolved' then
    raise exception 'recovery_retry_must_be_idempotent: %', v_payload;
  end if;

  if (
    select pg_catalog.count(*)
    from public.admin_audit_logs audit_log
    where audit_log.admin_user_id = v_admin.id
      and audit_log.action = 'operator_stuck_call_recovered'
      and audit_log.entity_id = v_operator.id
  ) <> 1 then
    raise exception 'idempotent_retry_duplicated_audit_log';
  end if;

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_operator.auth_user_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_payload := public.reconcile_operator_state(
    pg_catalog.jsonb_build_object(
      'request_id', pg_catalog.gen_random_uuid(),
      'session_id', v_session_id,
      'app_version', 'test-admin-call-recovery'
    )
  );

  if v_payload#>>'{error,code}' <> 'SESSION_REVOKED' then
    raise exception 'revoked_session_did_not_force_new_login: %', v_payload;
  end if;

  -- Recreate the production defect: an expired-by-time session still marked
  -- active and an idle challenge paused behind the stuck call.
  insert into public.operator_sessions(
    id,
    operator_id,
    unit_id,
    status,
    expires_at,
    last_heartbeat_at,
    app_version,
    contract_version
  ) values (
    v_expired_session_id,
    v_operator.id,
    v_operator.unit_id,
    'active',
    pg_catalog.now() - interval '1 hour',
    pg_catalog.now() - interval '2 hours',
    'test-expired-admin-call-recovery',
    1
  );

  update public.operator_states
     set session_id = v_expired_session_id,
         status = 'in_call',
         activity = 'call',
         reason_code = 'call_active',
         call_active = true,
         call_source = 'microsip',
         call_started_at = pg_catalog.now() - interval '2 hours',
         call_event_id = pg_catalog.gen_random_uuid(),
         call_previous_status = 'idle',
         effective_at = pg_catalog.now() - interval '2 hours',
         revision = revision + 1,
         updated_at = pg_catalog.now()
   where operator_id = v_operator.id
   returning revision into v_revision;

  insert into public.challenge_logs(
    id,
    challenge_id,
    operator_id,
    session_id,
    status,
    expires_at,
    closed_at
  ) values (
    v_idle_log_id,
    v_challenge_id,
    v_operator.id,
    v_expired_session_id,
    'idle',
    pg_catalog.now() - interval '90 minutes',
    pg_catalog.now() - interval '90 minutes'
  );

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_admin.auth_user_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  v_payload := public.admin_recover_stuck_operator_call(
    v_operator.id,
    v_revision
  );

  if v_payload->>'result' <> 'resolved'
     or v_payload->>'session_status' <> 'revoked'
     or (v_payload->>'expired_challenges')::integer <> 1 then
    raise exception 'expired_session_recovery_contract_failed: %', v_payload;
  end if;

  if not exists (
    select 1
    from public.challenge_logs challenge_log
    where challenge_log.id = v_idle_log_id
      and challenge_log.status = 'expired'
      and challenge_log.metadata->>'closed_reason' = 'admin_stuck_call_recovery'
  ) then
    raise exception 'idle_challenge_was_not_expired';
  end if;

  -- A signed-in operator who is not an admin cannot use the privileged RPC.
  update public.operator_states
     set session_id = v_expired_session_id,
         status = 'in_call',
         call_active = true,
         call_started_at = pg_catalog.now() - interval '20 minutes',
         effective_at = pg_catalog.now() - interval '20 minutes',
         revision = revision + 1
   where operator_id = v_operator.id
   returning revision into v_revision;

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', pg_catalog.gen_random_uuid()::text,
      'role', 'authenticated'
    )::text,
    true
  );

  begin
    perform public.admin_recover_stuck_operator_call(v_operator.id, v_revision);
    raise exception 'non_admin_call_unexpectedly_succeeded';
  exception
    when others then
      if sqlerrm <> 'acesso_negado' then
        raise;
      end if;
  end;

  -- Unit managers without the target unit in unit_scope remain denied by the
  -- existing admin_can_manage_operator_unit contract.
  update public.admin_users
     set role = 'unit_manager',
         unit_scope = array[]::uuid[]
   where id = v_admin.id;

  perform pg_catalog.set_config(
    'request.jwt.claims',
    pg_catalog.jsonb_build_object(
      'sub', v_admin.auth_user_id::text,
      'role', 'authenticated'
    )::text,
    true
  );

  begin
    perform public.admin_recover_stuck_operator_call(v_operator.id, v_revision);
    raise exception 'out_of_scope_unit_manager_unexpectedly_succeeded';
  exception
    when others then
      if sqlerrm <> 'fora_do_escopo_da_unidade' then
        raise;
      end if;
  end;

  update public.admin_users
     set role = 'superadmin',
         unit_scope = v_admin.unit_scope
   where id = v_admin.id;

  -- A recent call is never eligible, even for a superadmin.
  insert into public.operator_sessions(
    id,
    operator_id,
    unit_id,
    status,
    expires_at,
    last_heartbeat_at,
    app_version,
    contract_version
  ) values (
    v_recent_session_id,
    v_operator.id,
    v_operator.unit_id,
    'active',
    pg_catalog.now() + interval '1 hour',
    pg_catalog.now(),
    'test-recent-admin-call-recovery',
    1
  );

  update public.operator_states
     set session_id = v_recent_session_id,
         status = 'in_call',
         activity = 'call',
         reason_code = 'call_active',
         call_active = true,
         call_source = 'microsip',
         call_started_at = pg_catalog.now() - interval '5 minutes',
         call_event_id = pg_catalog.gen_random_uuid(),
         call_previous_status = 'active',
         effective_at = pg_catalog.now() - interval '5 minutes',
         revision = revision + 1,
         updated_at = pg_catalog.now()
   where operator_id = v_operator.id
   returning revision into v_revision;

  begin
    perform public.admin_recover_stuck_operator_call(v_operator.id, v_revision);
    raise exception 'recent_call_unexpectedly_succeeded';
  exception
    when others then
      if sqlerrm <> 'CALL_NOT_OVERDUE' then
        raise;
      end if;
  end;

  -- Optimistic concurrency protects a new call started after the
  -- administrator opened the confirmation dialog.
  update public.operator_states
     set call_started_at = pg_catalog.now() - interval '1 minute',
         call_event_id = pg_catalog.gen_random_uuid(),
         effective_at = pg_catalog.now() - interval '1 minute',
         revision = revision + 1
   where operator_id = v_operator.id
   returning revision into v_revision;

  begin
    perform public.admin_recover_stuck_operator_call(
      v_operator.id,
      v_revision - 1
    );
    raise exception 'stale_revision_unexpectedly_succeeded';
  exception
    when others then
      if sqlerrm <> 'OPERATOR_STATE_CHANGED' then
        raise;
      end if;
  end;

  if not exists (
    select 1
    from public.operator_states state_row
    where state_row.operator_id = v_operator.id
      and state_row.session_id = v_recent_session_id
      and state_row.status = 'in_call'
      and state_row.call_active = true
      and state_row.call_started_at > pg_catalog.now() - interval '10 minutes'
  ) then
    raise exception 'new_call_was_modified_by_stale_recovery';
  end if;
end;
$test$;

rollback;

select 'ok - admin stuck operator call recovery is safe and audited' as result;
