-- Top 5 operators by idle time and by block occurrences.
-- Uses the same admin scope, filters and non-destructive statistics reset marker.

create or replace function public.admin_operator_attention_leaderboard(
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
    return jsonb_build_object('idle', '[]'::jsonb, 'blocked', '[]'::jsonb);
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
  scoped_operators as (
    select * from visible_operators where v_shift = 'all' or shift_kind = v_shift
  ),
  last_status_before_period as (
    select distinct on (h.operator_id)
      h.operator_id, h.to_status, h.occurred_at
    from public.operator_status_history h
    join scoped_operators o on o.id = h.operator_id
    where h.occurred_at < v_start
    order by h.operator_id, h.occurred_at desc
  ),
  status_points as (
    select operator_id, to_status, occurred_at from last_status_before_period
    union all
    select h.operator_id, h.to_status, h.occurred_at
    from public.operator_status_history h
    join scoped_operators o on o.id = h.operator_id
    where h.occurred_at >= v_start and h.occurred_at < v_end
  ),
  status_ordered as (
    select
      operator_id,
      to_status,
      occurred_at,
      lead(occurred_at) over (partition by operator_id order by occurred_at) as next_at
    from status_points
  ),
  idle_agg as (
    select
      operator_id,
      count(*)::int as idle_events,
      coalesce(sum(extract(epoch from (
        least(coalesce(next_at, v_end), v_end) - greatest(occurred_at, v_start)
      )))::bigint, 0) as idle_seconds,
      max(occurred_at) as last_idle_at
    from status_ordered
    where to_status = 'idle'
      and greatest(occurred_at, v_start) < least(coalesce(next_at, v_end), v_end)
    group by operator_id
  ),
  block_agg as (
    select
      b.operator_id,
      count(*)::int as block_count,
      coalesce(sum(extract(epoch from (
        least(coalesce(b.finished_at, b.revoked_at, b.blocked_until, v_end), v_end)
        - greatest(b.started_at, v_start)
      )))::bigint, 0) as blocked_seconds,
      max(b.started_at) as last_block_at
    from public.operator_blocks b
    join scoped_operators o on o.id = b.operator_id
    where b.started_at < v_end
      and coalesce(b.finished_at, b.revoked_at, b.blocked_until, v_end) > v_start
    group by b.operator_id
  ),
  operator_metrics as (
    select
      o.id as operator_id,
      o.display_name as operator_name,
      o.unit_id,
      o.unit_name,
      o.unit_city,
      o.unit_state,
      o.unit_code,
      coalesce(i.idle_events, 0) as idle_events,
      coalesce(i.idle_seconds, 0) as idle_seconds,
      i.last_idle_at,
      coalesce(b.block_count, 0) as block_count,
      coalesce(b.blocked_seconds, 0) as blocked_seconds,
      b.last_block_at
    from scoped_operators o
    left join idle_agg i on i.operator_id = o.id
    left join block_agg b on b.operator_id = o.id
  ),
  idle_top as (
    select * from operator_metrics
    where idle_seconds > 0
    order by idle_seconds desc, idle_events desc, operator_name
    limit v_limit
  ),
  blocked_top as (
    select * from operator_metrics
    where block_count > 0
    order by block_count desc, blocked_seconds desc, operator_name
    limit v_limit
  )
  select jsonb_build_object(
    'idle', coalesce((
      select jsonb_agg(jsonb_build_object(
        'operator_id', operator_id,
        'operator_name', operator_name,
        'unit_id', unit_id,
        'unit_name', unit_name,
        'unit_city', unit_city,
        'unit_state', unit_state,
        'unit_code', unit_code,
        'idle_events', idle_events,
        'idle_seconds', idle_seconds,
        'last_idle_at', last_idle_at,
        'block_count', block_count,
        'blocked_seconds', blocked_seconds,
        'last_block_at', last_block_at
      ) order by idle_seconds desc, idle_events desc, operator_name)
      from idle_top
    ), '[]'::jsonb),
    'blocked', coalesce((
      select jsonb_agg(jsonb_build_object(
        'operator_id', operator_id,
        'operator_name', operator_name,
        'unit_id', unit_id,
        'unit_name', unit_name,
        'unit_city', unit_city,
        'unit_state', unit_state,
        'unit_code', unit_code,
        'idle_events', idle_events,
        'idle_seconds', idle_seconds,
        'last_idle_at', last_idle_at,
        'block_count', block_count,
        'blocked_seconds', blocked_seconds,
        'last_block_at', last_block_at
      ) order by block_count desc, blocked_seconds desc, operator_name)
      from blocked_top
    ), '[]'::jsonb)
  ) into v_payload;

  return v_payload;
end;
$$;

revoke all on function public.admin_operator_attention_leaderboard(jsonb) from public, anon;
grant execute on function public.admin_operator_attention_leaderboard(jsonb) to authenticated;
