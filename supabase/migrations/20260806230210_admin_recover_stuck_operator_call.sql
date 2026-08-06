-- Allows an authorized administrator to recover an operator whose local call
-- ended without the app delivering call_finished. The recovery intentionally
-- revokes the operational session so a stale local/MicroSIP state cannot
-- immediately publish the same call again.

create or replace function public.admin_recover_stuck_operator_call(
  p_operator_id uuid,
  p_expected_revision bigint
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_state public.operator_states%rowtype;
  v_session public.operator_sessions%rowtype;
  v_now timestamptz := pg_catalog.clock_timestamp();
  v_call_started_at timestamptz;
  v_event_id uuid := pg_catalog.gen_random_uuid();
  v_before jsonb;
  v_expired_challenges integer := 0;
  v_abandoned_challenges integer := 0;
begin
  if p_operator_id is null then
    raise exception using errcode = '22023', message = 'OPERATOR_ID_REQUIRED';
  end if;

  if p_expected_revision is null then
    raise exception using errcode = '22023', message = 'EXPECTED_REVISION_REQUIRED';
  end if;

  select operator_row.*
    into v_operator
  from public.operators operator_row
  where operator_row.id = p_operator_id;

  if v_operator.id is null then
    raise exception using errcode = 'P0002', message = 'OPERATOR_NOT_FOUND';
  end if;

  v_admin := private.require_admin_for_backend(
    array['superadmin', 'unit_manager', 'operations_manager'],
    v_operator.unit_id
  );

  perform pg_catalog.pg_advisory_xact_lock(
    pg_catalog.hashtext(p_operator_id::text)
  );

  select state_row.*
    into v_state
  from public.operator_states state_row
  where state_row.operator_id = p_operator_id
  for update;

  if v_state.operator_id is null then
    raise exception using errcode = 'P0002', message = 'OPERATOR_STATE_NOT_FOUND';
  end if;

  -- A retry after a successful recovery is harmless and does not duplicate
  -- history or audit records.
  if not coalesce(v_state.call_active, false)
     and v_state.status <> 'in_call' then
    return pg_catalog.jsonb_build_object(
      'result', 'already_resolved',
      'operator_id', p_operator_id,
      'status', v_state.status,
      'revision', v_state.revision
    );
  end if;

  -- Protect a newer call that may have started while the confirmation dialog
  -- was open in the Admin panel.
  if v_state.revision is distinct from p_expected_revision then
    raise exception using errcode = '40001', message = 'OPERATOR_STATE_CHANGED';
  end if;

  v_call_started_at := coalesce(
    v_state.call_started_at,
    v_state.effective_at
  );

  if v_call_started_at is null
     or v_call_started_at > v_now - interval '10 minutes' then
    raise exception using errcode = 'P0001', message = 'CALL_NOT_OVERDUE';
  end if;

  select session_row.*
    into v_session
  from public.operator_sessions session_row
  where session_row.id = v_state.session_id
    and session_row.operator_id = p_operator_id
  for update;

  v_before := pg_catalog.jsonb_build_object(
    'operator_state', pg_catalog.to_jsonb(v_state),
    'session', case
      when v_session.id is null then null
      else pg_catalog.to_jsonb(v_session)
    end
  );

  if v_session.id is not null and v_session.status = 'active' then
    update public.operator_sessions
       set status = 'revoked',
           ended_at = v_now,
           end_reason = 'admin_stuck_call_recovery',
           updated_at = v_now
     where id = v_session.id;
  end if;

  if v_session.id is not null then
    update public.challenge_logs
       set status = 'expired',
           closed_at = coalesce(closed_at, v_now),
           revision = revision + 1,
           metadata = coalesce(metadata, '{}'::jsonb)
             || pg_catalog.jsonb_build_object(
               'closed_reason', 'admin_stuck_call_recovery',
               'closed_at', v_now,
               'admin_user_id', v_admin.id,
               'recovery_event_id', v_event_id
             )
     where operator_id = p_operator_id
       and session_id = v_session.id
       and status in ('scheduled', 'idle');
    get diagnostics v_expired_challenges = row_count;

    update public.challenge_logs
       set status = 'abandoned',
           abandoned_at = coalesce(abandoned_at, v_now),
           closed_at = null,
           revision = revision + 1,
           metadata = coalesce(metadata, '{}'::jsonb)
             || pg_catalog.jsonb_build_object(
               'abandoned_reason', 'admin_stuck_call_recovery',
               'abandoned_at', v_now,
               'admin_user_id', v_admin.id,
               'recovery_event_id', v_event_id
             )
     where operator_id = p_operator_id
       and session_id = v_session.id
       and status in ('pending', 'displayed', 'paused');
    get diagnostics v_abandoned_challenges = row_count;
  end if;

  update public.operator_states
     set status = 'offline',
         activity = null,
         reason_code = 'admin_stuck_call_recovery',
         call_active = false,
         call_source = null,
         call_started_at = null,
         call_event_id = null,
         call_previous_status = null,
         effective_at = v_now,
         revision = revision + 1,
         updated_at = v_now
   where operator_id = p_operator_id
   returning * into v_state;

  insert into public.operator_status_history(
    operator_id,
    session_id,
    from_status,
    to_status,
    reason_code,
    source,
    occurred_at,
    state_revision,
    metadata
  ) values (
    p_operator_id,
    v_session.id,
    'in_call',
    'offline',
    'admin_stuck_call_recovery',
    'admin_panel',
    v_now,
    v_state.revision,
    pg_catalog.jsonb_build_object(
      'admin_user_id', v_admin.id,
      'recovery_event_id', v_event_id,
      'call_started_at', v_call_started_at,
      'call_source', v_before#>>'{operator_state,call_source}',
      'call_event_id', v_before#>>'{operator_state,call_event_id}'
    )
  );

  -- A distinct event type prevents the administrative recovery from being
  -- counted as a normal operator-delivered call.ended event.
  insert into public.operational_events(
    event_type,
    operator_id,
    session_id,
    unit_id,
    idempotency_key,
    occurred_at,
    payload
  ) values (
    'call.admin_forced_end',
    p_operator_id,
    v_session.id,
    v_operator.unit_id,
    v_event_id,
    v_now,
    pg_catalog.jsonb_build_object(
      'source', 'admin_panel',
      'admin_user_id', v_admin.id,
      'reason', 'admin_stuck_call_recovery',
      'expired_challenges', v_expired_challenges,
      'abandoned_challenges', v_abandoned_challenges
    )
  );

  insert into public.admin_audit_logs(
    admin_user_id,
    action,
    entity_type,
    entity_id,
    before_data,
    after_data,
    occurred_at
  ) values (
    v_admin.id,
    'operator_stuck_call_recovered',
    'operator',
    p_operator_id,
    v_before,
    pg_catalog.jsonb_build_object(
      'operator_state', pg_catalog.to_jsonb(v_state),
      'session_status', case
        when v_session.id is null then null
        when v_session.status = 'active' then 'revoked'
        else v_session.status
      end,
      'expired_challenges', v_expired_challenges,
      'abandoned_challenges', v_abandoned_challenges,
      'recovery_event_id', v_event_id
    ),
    v_now
  );

  return pg_catalog.jsonb_build_object(
    'result', 'resolved',
    'operator_id', p_operator_id,
    'status', v_state.status,
    'revision', v_state.revision,
    'session_id', v_session.id,
    'session_status', case
      when v_session.id is null then null
      when v_session.status = 'active' then 'revoked'
      else v_session.status
    end,
    'expired_challenges', v_expired_challenges,
    'abandoned_challenges', v_abandoned_challenges,
    'resolved_at', v_now
  );
end;
$$;

revoke all on function public.admin_recover_stuck_operator_call(uuid, bigint)
  from public, anon;
grant execute on function public.admin_recover_stuck_operator_call(uuid, bigint)
  to authenticated;

comment on function public.admin_recover_stuck_operator_call(uuid, bigint) is
  'Revokes an overdue in-call operator session, clears transient call state, closes session challenges, and records complete administrative audit evidence.';
