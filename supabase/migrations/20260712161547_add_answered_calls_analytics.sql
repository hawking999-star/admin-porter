create or replace function public.admin_analytics_answered_calls(
  p_request jsonb default '{}'::jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_start timestamptz := coalesce(nullif(p_request->>'start_at', '')::timestamptz, date_trunc('day', now()));
  v_end timestamptz := coalesce(nullif(p_request->>'end_at', '')::timestamptz, now());
  v_unit uuid := nullif(p_request->>'unit_id', '')::uuid;
  v_operator uuid := nullif(p_request->>'operator_id', '')::uuid;
  v_shift text := coalesce(nullif(p_request->>'shift', ''), 'all');
  v_answered_calls integer;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  if v_end <= v_start then
    raise exception 'invalid_period';
  end if;

  if v_shift not in ('all', 'day', 'night', 'other') then
    v_shift := 'all';
  end if;

  with visible_operators as (
    select
      o.id,
      case
        when s.id is null then 'other'
        when s.name ilike '%noturn%' then 'night'
        when s.name ilike '%diurn%' then 'day'
        when s.starts_at is not null and s.ends_at is not null and s.ends_at <= s.starts_at then 'night'
        when s.starts_at is not null and s.ends_at is not null then 'day'
        else 'other'
      end as shift_kind
    from public.operators o
    join public.units u on u.id = o.unit_id and u.active = true
    left join public.shifts s on s.id = o.default_shift_id
    where o.active = true
      and (public.is_superadmin() or public.admin_can_manage_operator_unit(u.id))
      and (v_unit is null or o.unit_id = v_unit)
      and (v_operator is null or o.id = v_operator)
  )
  select count(*)::integer into v_answered_calls
  from public.operator_status_history h
  join visible_operators o on o.id = h.operator_id
  where h.to_status = 'in_call'
    and h.occurred_at >= v_start
    and h.occurred_at < v_end
    and (v_shift = 'all' or o.shift_kind = v_shift);

  return jsonb_build_object('answered_calls', coalesce(v_answered_calls, 0));
end;
$$;

revoke all on function public.admin_analytics_answered_calls(jsonb) from public, anon;
grant execute on function public.admin_analytics_answered_calls(jsonb) to authenticated;
