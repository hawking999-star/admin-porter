-- Non-destructive statistics reset and challenge-performance leaderboard.
-- Historical rows remain intact; reports clamp their start date to this marker.

create or replace function private.statistics_reset_at()
returns timestamptz
language sql
stable
security definer
set search_path = ''
as $$
  select nullif(value->>'reset_at', '')::timestamptz
  from public.system_settings
  where key = 'statistics_reset'
    and scope_type = 'global'
    and scope_id is null
    and active = true
  order by revision desc, created_at desc
  limit 1
$$;

create or replace function public.admin_statistics_reset_info()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
begin
  perform private.require_admin_for_backend(null, null);
  return jsonb_build_object('reset_at', private.statistics_reset_at());
end;
$$;

create or replace function public.admin_reset_statistics()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_now timestamptz := clock_timestamp();
  v_before jsonb;
  v_revision bigint;
begin
  v_admin := private.require_admin_for_backend(array['superadmin'], null);

  select value, revision
  into v_before, v_revision
  from public.system_settings
  where key = 'statistics_reset'
    and scope_type = 'global'
    and scope_id is null
    and active = true
  order by revision desc, created_at desc
  limit 1
  for update;

  update public.system_settings
  set active = false,
      updated_at = v_now
  where key = 'statistics_reset'
    and scope_type = 'global'
    and scope_id is null
    and active = true;

  insert into public.system_settings (
    scope_type, scope_id, key, value, revision, active, created_at, updated_at
  ) values (
    'global', null, 'statistics_reset', jsonb_build_object('reset_at', v_now),
    coalesce(v_revision, 0) + 1, true, v_now, v_now
  );

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, before_data, after_data, occurred_at
  ) values (
    v_admin.id,
    'statistics_reset',
    'analytics',
    v_before,
    jsonb_build_object('reset_at', v_now),
    v_now
  );

  return jsonb_build_object('reset_at', v_now);
end;
$$;

create or replace function public.admin_challenge_leaderboard(
  p_request jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_start timestamptz := coalesce(nullif(p_request->>'start_at', '')::timestamptz, date_trunc('day', now()));
  v_end timestamptz := coalesce(nullif(p_request->>'end_at', '')::timestamptz, now());
  v_unit uuid := nullif(p_request->>'unit_id', '')::uuid;
  v_operator uuid := nullif(p_request->>'operator_id', '')::uuid;
  v_shift text := coalesce(nullif(p_request->>'shift', ''), 'all');
  v_limit int := least(greatest(coalesce(nullif(p_request->>'ranking_page_size', '')::int, 5), 1), 50);
  v_reset timestamptz;
  v_payload jsonb;
begin
  perform private.require_admin_for_backend(null, v_unit);

  if v_shift not in ('all', 'day', 'night', 'other') then
    v_shift := 'all';
  end if;

  v_reset := private.statistics_reset_at();
  if v_reset is not null and v_reset > v_start then
    v_start := v_reset;
  end if;

  if v_end <= v_start then
    return jsonb_build_object('rows', '[]'::jsonb, 'total', 0, 'page', 1, 'page_size', v_limit);
  end if;

  with visible_units as (
    select u.id, u.name, u.city, u.state, u.code
    from public.units u
    where u.active = true
      and (public.is_superadmin() or public.admin_can_manage_operator_unit(u.id))
      and (v_unit is null or u.id = v_unit)
  ),
  visible_operators as (
    select
      o.id,
      o.display_name,
      o.unit_id,
      u.name as unit_name,
      u.city as unit_city,
      u.state as unit_state,
      u.code as unit_code,
      case
        when s.id is null then 'other'
        when s.name ilike '%noturn%' then 'night'
        when s.name ilike '%diurn%' then 'day'
        when s.starts_at is not null and s.ends_at is not null and s.ends_at <= s.starts_at then 'night'
        when s.starts_at is not null and s.ends_at is not null then 'day'
        else 'other'
      end as shift_kind
    from public.operators o
    join visible_units u on u.id = o.unit_id
    left join public.shifts s on s.id = o.default_shift_id
    where o.active = true
      and (v_operator is null or o.id = v_operator)
  ),
  challenge_agg as (
    select
      o.id as operator_id,
      o.display_name as operator_name,
      o.unit_id,
      o.unit_name,
      o.unit_city,
      o.unit_state,
      o.unit_code,
      count(cl.id)::int as challenges_received,
      count(cl.id) filter (where cl.answered_at is not null)::int as challenges_answered,
      count(cl.id) filter (where cl.answer_result in ('correct', 'success', 'right', 'ok'))::int as challenges_correct,
      max(coalesce(cl.answered_at, cl.displayed_at, cl.created_at)) as last_challenge_at
    from visible_operators o
    join public.challenge_logs cl
      on cl.operator_id = o.id
     and cl.created_at >= v_start
     and cl.created_at <= v_end
    where (v_shift = 'all' or o.shift_kind = v_shift)
    group by o.id, o.display_name, o.unit_id, o.unit_name, o.unit_city, o.unit_state, o.unit_code
  ),
  eligible as (
    select *,
      round((challenges_correct::numeric / nullif(challenges_answered, 0)) * 100, 1) as challenge_accuracy_rate
    from challenge_agg
    where challenges_answered > 0
  ),
  page_rows as (
    select *
    from eligible
    order by challenge_accuracy_rate desc, challenges_answered desc, challenges_correct desc, operator_name
    limit v_limit
  )
  select jsonb_build_object(
    'rows', coalesce((
      select jsonb_agg(jsonb_build_object(
        'operator_id', operator_id,
        'operator_name', operator_name,
        'unit_id', unit_id,
        'unit_name', unit_name,
        'unit_city', unit_city,
        'unit_state', unit_state,
        'unit_code', unit_code,
        'challenges_received', challenges_received,
        'challenges_answered', challenges_answered,
        'challenges_correct', challenges_correct,
        'challenge_accuracy_rate', challenge_accuracy_rate,
        'last_challenge_at', last_challenge_at
      ) order by challenge_accuracy_rate desc, challenges_answered desc, challenges_correct desc, operator_name)
      from page_rows
    ), '[]'::jsonb),
    'total', (select count(*) from eligible),
    'page', 1,
    'page_size', v_limit
  ) into v_payload;

  return v_payload;
end;
$$;

revoke all on function private.statistics_reset_at() from public, anon, authenticated;
revoke all on function public.admin_statistics_reset_info() from public, anon;
revoke all on function public.admin_reset_statistics() from public, anon;
revoke all on function public.admin_challenge_leaderboard(jsonb) from public, anon;

grant execute on function public.admin_statistics_reset_info() to authenticated;
grant execute on function public.admin_reset_statistics() to authenticated;
grant execute on function public.admin_challenge_leaderboard(jsonb) to authenticated;
