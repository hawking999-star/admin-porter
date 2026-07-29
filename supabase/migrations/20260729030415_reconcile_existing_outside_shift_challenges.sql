-- Applied remotely as migration 20260729030415.
-- One-time reconciliation for sessions that were already stuck in idle before
-- the outside-shift challenge guard was deployed.

do $$
declare
  v_session record;
  v_target_status text;
begin
  for v_session in
    select
      session_row.id as session_id,
      session_row.operator_id,
      coalesce(operator_state.call_active, false) as call_active
    from public.operator_sessions session_row
    join public.operators operator_row
      on operator_row.id = session_row.operator_id
    left join public.operator_states operator_state
      on operator_state.operator_id = session_row.operator_id
    where session_row.status = 'active'
      and session_row.expires_at > pg_catalog.now()
      and private.operator_challenge_in_shift(
        session_row.operator_id,
        session_row.id
      ) = false
  loop
    perform pg_catalog.pg_advisory_xact_lock(
      pg_catalog.hashtext(v_session.operator_id::text)
    );

    perform private.expire_operator_challenges_outside_shift(
      v_session.operator_id,
      v_session.session_id
    );

    v_target_status := case
      when v_session.call_active then 'in_call'
      when exists (
        select 1
        from public.operator_blocks block_row
        where block_row.operator_id = v_session.operator_id
          and block_row.status = 'active'
          and (
            block_row.blocked_until is null
            or block_row.blocked_until > pg_catalog.now()
          )
      ) then 'blocked'
      else 'outside_shift'
    end;

    perform private.set_challenge_operator_state(
      v_session.operator_id,
      v_session.session_id,
      v_target_status,
      'outside_shift_reconciled'
    );
  end loop;
end;
$$;
