-- Support two independent challenge delivery periods while keeping legacy
-- single-window rules valid. All scheduling remains based on server time.

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
  v_windows jsonb := p_rules->'active_windows';
  v_window jsonb;
  v_start time;
  v_end time;
  v_local_reference timestamp;
  v_window_start timestamp;
  v_window_end timestamp;
  v_candidate timestamp;
  v_best_candidate timestamp;
  v_day_offset integer;
begin
  v_local_reference := p_reference at time zone v_timezone;

  if jsonb_typeof(v_windows) is distinct from 'array'
     or jsonb_array_length(v_windows) = 0 then
    v_windows := jsonb_build_array(
      jsonb_build_object(
        'key', 'legacy',
        'enabled', true,
        'start', coalesce(nullif(p_rules->>'active_window_start', ''), '00:00'),
        'end', coalesce(nullif(p_rules->>'active_window_end', ''), '00:00')
      )
    );
  end if;

  -- Include yesterday for an overnight window that is still open and enough
  -- future days to always reach the next enabled period.
  for v_day_offset in -1..2 loop
    for v_window in
      select value
      from jsonb_array_elements(v_windows)
    loop
      if not coalesce((v_window->>'enabled')::boolean, true) then
        continue;
      end if;

      v_start := coalesce(nullif(v_window->>'start', '')::time, '00:00'::time);
      v_end := coalesce(nullif(v_window->>'end', '')::time, '00:00'::time);
      v_window_start := v_local_reference::date + v_day_offset + v_start;
      v_window_end := v_local_reference::date + v_day_offset + v_end;

      -- Equal times are retained only for legacy rules and mean a full day.
      if v_end <= v_start then
        v_window_end := v_window_end + interval '1 day';
      end if;

      if v_window_end <= v_local_reference then
        continue;
      end if;

      v_candidate := greatest(v_local_reference, v_window_start)
        + make_interval(secs => greatest(p_delay_seconds, 0));

      if v_candidate < v_window_end
         and (v_best_candidate is null or v_candidate < v_best_candidate) then
        v_best_candidate := v_candidate;
      end if;
    end loop;
  end loop;

  if v_best_candidate is null then
    raise exception 'janela_horario_sem_espaco';
  end if;

  return v_best_candidate at time zone v_timezone;
end
$$;

revoke all on function private.challenge_schedule_at(jsonb, integer, timestamptz)
  from public, anon, authenticated;

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
  v_windows_input jsonb := p_rules->'active_windows';
  v_windows jsonb := '[]'::jsonb;
  v_window jsonb;
  v_window_key text;
  v_window_enabled boolean;
  v_window_start_text text;
  v_window_end_text text;
  v_enabled_count integer := 0;
  v_seen_keys text[] := array[]::text[];
  v_first_start_minute integer;
  v_first_end_minute integer;
  v_current_start_minute integer;
  v_current_end_minute integer;
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

  if not exists (
    select 1
    from pg_catalog.pg_timezone_names
    where name = v_timezone
  ) then
    raise exception 'fuso_horario_invalido';
  end if;

  if jsonb_typeof(v_windows_input) = 'array' then
    if jsonb_array_length(v_windows_input) <> 2 then
      raise exception 'janelas_horario_invalidas';
    end if;

    for v_window in
      select value
      from jsonb_array_elements(v_windows_input)
    loop
      v_window_key := nullif(v_window->>'key', '');
      if v_window_key is null
         or v_window_key not in ('daytime', 'nighttime')
         or v_window_key = any(v_seen_keys) then
        raise exception 'janelas_horario_invalidas';
      end if;
      v_seen_keys := array_append(v_seen_keys, v_window_key);

      if coalesce(v_window->>'enabled', '') not in ('true', 'false') then
        raise exception 'janelas_horario_invalidas';
      end if;
      v_window_enabled := (v_window->>'enabled')::boolean;
      v_window_start_text := coalesce(nullif(v_window->>'start', ''), '');
      v_window_end_text := coalesce(nullif(v_window->>'end', ''), '');

      if v_window_start_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
         or v_window_end_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
        raise exception 'janela_horario_invalida';
      end if;

      v_start := v_window_start_text::time;
      v_end := v_window_end_text::time;

      if v_window_enabled then
        v_enabled_count := v_enabled_count + 1;
        if v_start = v_end then
          raise exception 'janela_horario_sem_duracao';
        end if;

        v_window_seconds := case
          when v_start < v_end then extract(epoch from (v_end - v_start))::integer
          else 86400 - extract(epoch from (v_start - v_end))::integer
        end;

        if v_max_interval >= v_window_seconds then
          raise exception 'intervalo_maior_que_janela_horaria';
        end if;

        v_current_start_minute := extract(hour from v_start)::integer * 60
          + extract(minute from v_start)::integer;
        v_current_end_minute := extract(hour from v_end)::integer * 60
          + extract(minute from v_end)::integer;
        if v_current_end_minute <= v_current_start_minute then
          v_current_end_minute := v_current_end_minute + 1440;
        end if;

        if v_first_start_minute is null then
          v_first_start_minute := v_current_start_minute;
          v_first_end_minute := v_current_end_minute;
        elsif greatest(v_first_start_minute, v_current_start_minute)
                < least(v_first_end_minute, v_current_end_minute)
           or greatest(v_first_start_minute, v_current_start_minute + 1440)
                < least(v_first_end_minute, v_current_end_minute + 1440)
           or greatest(v_first_start_minute, v_current_start_minute - 1440)
                < least(v_first_end_minute, v_current_end_minute - 1440) then
          raise exception 'janelas_horario_sobrepostas';
        end if;

        if v_enabled_count = 1 then
          v_start_text := v_window_start_text;
          v_end_text := v_window_end_text;
        end if;
      end if;

      v_windows := v_windows || jsonb_build_array(
        jsonb_build_object(
          'key', v_window_key,
          'enabled', v_window_enabled,
          'start', v_window_start_text,
          'end', v_window_end_text
        )
      );
    end loop;

    if v_enabled_count = 0 then
      raise exception 'janela_horario_sem_periodo_ativo';
    end if;
  else
    if v_start_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$'
       or v_end_text !~ '^([01][0-9]|2[0-3]):[0-5][0-9]$' then
      raise exception 'janela_horario_invalida';
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
  end if;

  -- Revision is transport metadata used for optimistic concurrency and must
  -- not become part of the effective challenge rules.
  v_rules := (p_rules - 'revision' - 'active_windows') || jsonb_build_object(
    'active_window_start', v_start_text,
    'active_window_end', v_end_text,
    'timezone', v_timezone
  );
  if jsonb_typeof(v_windows_input) = 'array' then
    v_rules := v_rules || jsonb_build_object('active_windows', v_windows);
  end if;

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

  -- Scheduled rows were calculated from the previous periods. Recalculate
  -- them immediately; pending/displayed/idle rows keep their lifecycle.
  with reschedule_targets as (
    select
      cl.id,
      private.challenge_schedule_at(
        v_rules,
        floor(random() * (v_max_interval - v_min_interval + 1))::integer
          + v_min_interval,
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
        'rules_scope_id', p_unit_id,
        'active_windows', coalesce(v_rules->'active_windows', '[]'::jsonb)
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
  'Saves one or two challenge delivery periods with revision control and reschedules affected scheduled challenges.';
