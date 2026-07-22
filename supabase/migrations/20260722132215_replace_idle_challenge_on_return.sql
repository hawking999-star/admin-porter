begin;

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
  v_shift_info jsonb;
  v_rules jsonb;
  v_target_status text;
  v_candidate uuid;
  v_response_seconds integer;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid()
    and active;

  if v_op.id is null then
    raise exception 'operador_invalido';
  end if;

  select * into v_session
  from public.operator_sessions
  where id = p_session_id
    and operator_id = v_op.id
    and status = 'active'
    and expires_at > pg_catalog.now();

  if v_session.id is null then
    raise exception 'sessao_invalida';
  end if;

  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtext(v_op.id::text));

  select * into v_idle_log
  from public.challenge_logs
  where operator_id = v_op.id
    and session_id = v_session.id
    and status = 'idle'
  order by created_at desc, id desc
  limit 1
  for update;

  if v_idle_log.id is null then
    return public.operator_challenge_state(
      pg_catalog.jsonb_build_object('session_id', v_session.id)
    );
  end if;

  update public.challenge_logs
     set status = 'expired',
         closed_at = coalesce(closed_at, pg_catalog.now()),
         revision = revision + 1,
         metadata = coalesce(metadata, '{}'::jsonb) || pg_catalog.jsonb_build_object(
           'idle_resolved_at', pg_catalog.now(),
           'idle_resolution', 'replacement_challenge'
         )
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
        and (b.blocked_until is null or b.blocked_until > pg_catalog.now())
    ) then 'blocked'
    when not coalesce((v_shift_info->>'in_shift')::boolean, true) then 'outside_shift'
    else 'active'
  end;

  perform private.set_challenge_operator_state(
    v_op.id, v_session.id, v_target_status, 'challenge_idle_return'
  );

  if v_target_status = 'active' then
    select c.id into v_candidate
    from public.challenges c
    where c.status = 'active'
      and (c.unit_id = v_op.unit_id or c.unit_id is null)
      and c.id <> v_idle_log.challenge_id
      and not exists (
        select 1
        from public.challenge_logs previous_log
        where previous_log.operator_id = v_op.id
          and previous_log.session_id = v_session.id
          and previous_log.challenge_id = c.id
      )
    order by pg_catalog.random()
    limit 1;

    if v_candidate is null then
      select c.id into v_candidate
      from public.challenges c
      where c.status = 'active'
        and (c.unit_id = v_op.unit_id or c.unit_id is null)
        and c.id <> v_idle_log.challenge_id
      order by pg_catalog.random()
      limit 1;
    end if;

    if v_candidate is not null then
      v_rules := private.challenge_rules(v_op.unit_id);
      v_response_seconds := greatest(
        coalesce((v_rules->>'response_seconds')::integer, 60), 1
      );

      insert into public.challenge_logs(
        challenge_id,
        operator_id,
        session_id,
        status,
        scheduled_for,
        pending_at,
        expires_at,
        metadata
      ) values (
        v_candidate,
        v_op.id,
        v_session.id,
        'pending',
        pg_catalog.now(),
        pg_catalog.now(),
        pg_catalog.now() + pg_catalog.make_interval(secs => v_response_seconds),
        pg_catalog.jsonb_build_object(
          'trigger', 'idle_return',
          'replaces_challenge_log_id', v_idle_log.id,
          'replaces_challenge_id', v_idle_log.challenge_id
        )
      );
    end if;
  end if;

  return private.challenge_payload(v_op.id, v_session.id);
end;
$$;

revoke all on function public.operator_challenge_resume_idle(uuid)
  from public, anon;
grant execute on function public.operator_challenge_resume_idle(uuid)
  to authenticated;

comment on function public.operator_challenge_resume_idle(uuid) is
  'Encerra a ociosidade e, quando o operador esta ativo, devolve imediatamente outro desafio sem duplicar ocorrencias.';

commit;
