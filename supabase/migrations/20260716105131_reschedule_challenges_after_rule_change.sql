-- Make challenge-rule changes effective for already scheduled challenges and
-- prevent one admin from silently overwriting a newer rule snapshot.

alter table public.system_settings
  add column if not exists updated_by uuid;

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
  v_admin public.admin_users%rowtype;
  v_start_text text := coalesce(nullif(p_rules->>'active_window_start', ''), '00:00');
  v_end_text text := coalesce(nullif(p_rules->>'active_window_end', ''), '00:00');
  v_timezone text := coalesce(nullif(p_rules->>'timezone', ''), 'America/Sao_Paulo');
  v_start time;
  v_end time;
  v_window_seconds integer;
  v_rules jsonb;
  v_existing_id uuid;
  v_existing_revision bigint;
  v_expected_revision bigint := nullif(p_rules->>'revision', '')::bigint;
  v_min_interval integer;
  v_max_interval integer;
  v_response_seconds integer;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'operations_manager', 'challenge_manager'],
    p_unit_id
  );

  v_min_interval := coalesce((p_rules->>'min_interval_seconds')::integer, 0);
  v_max_interval := coalesce((p_rules->>'max_interval_seconds')::integer, 0);
  v_response_seconds := coalesce((p_rules->>'response_seconds')::integer, 0);

  if v_min_interval < 1 or v_max_interval < v_min_interval then
    raise exception 'janela_intervalo_invalida';
  end if;

  if v_response_seconds < 1 then
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
    select 1
    from pg_catalog.pg_timezone_names
    where name = v_timezone
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

    if v_max_interval >= v_window_seconds then
      raise exception 'intervalo_maior_que_janela_horaria';
    end if;
  end if;

  -- revision is transport metadata used for optimistic concurrency and must
  -- not become part of the effective challenge rules.
  v_rules := (p_rules - 'revision') || jsonb_build_object(
    'active_window_start', v_start_text,
    'active_window_end', v_end_text,
    'timezone', v_timezone
  );

  select id, revision
  into v_existing_id, v_existing_revision
  from public.system_settings
  where key = 'challenge_rules'
    and scope_type = case when p_unit_id is null then 'global' else 'unit' end
    and scope_id is not distinct from p_unit_id
  order by revision desc, updated_at desc, id desc
  limit 1
  for update;

  if v_existing_id is null then
    if coalesce(v_expected_revision, 0) <> 0 then
      raise exception 'challenge_rules_conflict';
    end if;

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
      v_admin.auth_user_id,
      now()
    );
  else
    if v_expected_revision is not null
       and v_expected_revision <> v_existing_revision then
      raise exception 'challenge_rules_conflict';
    end if;

    update public.system_settings
    set value = v_rules,
        active = true,
        revision = revision + 1,
        updated_by = v_admin.auth_user_id,
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

  -- Existing scheduled rows were created from the previous rules. Recalculate
  -- only those rows; challenges already pending/displayed/idle remain intact.
  with reschedule_targets as (
    select
      cl.id,
      private.challenge_schedule_at(
        v_rules,
        floor(
          random() * (v_max_interval - v_min_interval + 1)
        )::integer + v_min_interval,
        now()
      ) as next_scheduled_for
    from public.challenge_logs cl
    join public.operators o on o.id = cl.operator_id
    where cl.status = 'scheduled'
      and (
        (p_unit_id is not null and o.unit_id = p_unit_id)
        or (
          p_unit_id is null
          and not exists (
            select 1
            from public.system_settings unit_rules
            where unit_rules.key = 'challenge_rules'
              and unit_rules.scope_type = 'unit'
              and unit_rules.scope_id = o.unit_id
              and unit_rules.active
          )
        )
      )
  )
  update public.challenge_logs cl
  set scheduled_for = targets.next_scheduled_for,
      pending_at = now(),
      expires_at = targets.next_scheduled_for
        + make_interval(secs => v_response_seconds),
      metadata = coalesce(cl.metadata, '{}'::jsonb) || jsonb_build_object(
        'rescheduled_reason', 'challenge_rules_changed',
        'rescheduled_at', now(),
        'rules_scope', case when p_unit_id is null then 'global' else 'unit' end,
        'rules_scope_id', p_unit_id
      )
  from reschedule_targets targets
  where cl.id = targets.id
    and cl.status = 'scheduled';
end
$$;

revoke all on function public.admin_save_challenge_rules(uuid, jsonb)
  from public, anon;
grant execute on function public.admin_save_challenge_rules(uuid, jsonb)
  to authenticated;

comment on function public.admin_save_challenge_rules(uuid, jsonb) is
  'Saves challenge rules with optional revision concurrency control and reschedules affected scheduled challenges.';
