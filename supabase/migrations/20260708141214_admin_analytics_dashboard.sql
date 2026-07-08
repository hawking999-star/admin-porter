create or replace function public.admin_analytics_dashboard(
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
  v_rank_page int := greatest(coalesce(nullif(p_request->>'ranking_page', '')::int, 1), 1);
  v_rank_page_size int := least(greatest(coalesce(nullif(p_request->>'ranking_page_size', '')::int, 50), 1), 50);
  v_rank_offset int;
  v_bucket_interval interval;
  v_bucket_grain text;
  v_payload jsonb;
begin
  select * into v_admin
  from public.admin_users
  where auth_user_id = auth.uid()
    and active = true
  limit 1;

  if v_admin.id is null then
    raise exception 'forbidden';
  end if;

  if v_shift not in ('all', 'day', 'night', 'other') then
    v_shift := 'all';
  end if;

  if v_end <= v_start then
    raise exception 'invalid_period';
  end if;

  v_rank_offset := (v_rank_page - 1) * v_rank_page_size;

  if v_end - v_start <= interval '2 days' then
    v_bucket_interval := interval '1 hour';
    v_bucket_grain := 'hour';
  else
    v_bucket_interval := interval '1 day';
    v_bucket_grain := 'day';
  end if;

  with visible_units as (
    select u.id, u.name, u.city, u.state, u.active
    from public.units u
    where u.active = true
      and (public.is_superadmin() or public.admin_can_manage_operator_unit(u.id))
      and (v_unit is null or u.id = v_unit)
  ),
  operator_base as (
    select
      o.id,
      o.display_name,
      o.unit_id,
      u.name as unit_name,
      s.id as shift_id,
      s.name as shift_name,
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
  visible_operators as (
    select *
    from operator_base
    where v_shift = 'all' or shift_kind = v_shift
  ),
  all_filter_units as (
    select u.id, u.name
    from public.units u
    where u.active = true
      and (public.is_superadmin() or public.admin_can_manage_operator_unit(u.id))
  ),
  all_filter_operators as (
    select o.id, o.display_name, o.unit_id
    from public.operators o
    join all_filter_units u on u.id = o.unit_id
    where o.active = true
  ),
  raw_sessions as (
    select
      s.id,
      s.operator_id,
      s.unit_id,
      s.shift_id,
      s.status,
      s.started_at,
      coalesce(
        s.ended_at,
        case
          when s.status = 'active' then least(now(), s.expires_at)
          else coalesce(s.updated_at, s.last_heartbeat_at, s.started_at)
        end
      ) as raw_end
    from public.operator_sessions s
    join visible_operators o on o.id = s.operator_id
    where s.started_at < v_end
      and coalesce(
        s.ended_at,
        case
          when s.status = 'active' then least(now(), s.expires_at)
          else coalesce(s.updated_at, s.last_heartbeat_at, s.started_at)
        end
      ) > v_start
  ),
  session_segments as (
    select
      id,
      operator_id,
      unit_id,
      shift_id,
      greatest(started_at, v_start) as seg_start,
      least(raw_end, v_end) as seg_end,
      started_at,
      raw_end
    from raw_sessions
    where raw_end > started_at
  ),
  session_agg as (
    select
      count(*)::int as total_sessions,
      count(distinct operator_id)::int as active_operators,
      coalesce(sum(extract(epoch from (seg_end - seg_start)))::bigint, 0) as online_seconds
    from session_segments
    where seg_end > seg_start
  ),
  ordered_status as (
    select
      h.operator_id,
      h.session_id,
      h.to_status as status,
      h.occurred_at,
      lead(h.occurred_at) over (partition by h.operator_id order by h.occurred_at, h.id) as next_at
    from public.operator_status_history h
    join visible_operators o on o.id = h.operator_id
    where h.occurred_at < v_end
  ),
  status_segments as (
    select
      operator_id,
      session_id,
      status,
      greatest(occurred_at, v_start) as seg_start,
      least(coalesce(next_at, v_end), v_end) as seg_end
    from ordered_status
    where coalesce(next_at, v_end) > v_start
      and occurred_at < v_end
  ),
  status_duration as (
    select
      coalesce(sum(extract(epoch from (seg_end - seg_start))) filter (where status = 'idle'), 0)::bigint as idle_seconds,
      coalesce(sum(extract(epoch from (seg_end - seg_start))) filter (where status = 'in_call'), 0)::bigint as call_seconds
    from status_segments
    where seg_end > seg_start
  ),
  challenge_scope as (
    select cl.*
    from public.challenge_logs cl
    join visible_operators o on o.id = cl.operator_id
    where cl.created_at >= v_start
      and cl.created_at < v_end
  ),
  challenge_agg as (
    select
      count(*)::int as received,
      count(*) filter (where answered_at is not null or status = 'answered')::int as answered,
      count(*) filter (where answer_result in ('correct', 'success', 'right', 'ok'))::int as correct
    from challenge_scope
  ),
  current_status as (
    select
      coalesce(st.status, 'offline') as status,
      count(*)::int as count
    from visible_operators o
    left join public.operator_states st on st.operator_id = o.id
    group by coalesce(st.status, 'offline')
  ),
  status_json as (
    select coalesce(jsonb_agg(
      jsonb_build_object(
        'status', status_name,
        'label', status_label,
        'count', coalesce(cs.count, 0)
      )
      order by sort_order
    ), '[]'::jsonb) as rows
    from (
      values
        ('active', 'Ativo', 1),
        ('in_call', 'Atendimento', 2),
        ('idle', 'Ocioso', 3),
        ('offline', 'Offline', 4)
    ) as expected(status_name, status_label, sort_order)
    left join current_status cs on cs.status = expected.status_name
  ),
  buckets as (
    select
      gs as bucket_start,
      least(gs + v_bucket_interval, v_end) as bucket_end
    from generate_series(date_trunc(v_bucket_grain, v_start), v_end, v_bucket_interval) gs
    where gs < v_end
  ),
  timeseries as (
    select
      b.bucket_start,
      coalesce((
        select count(*)::int
        from raw_sessions s
        where s.started_at >= b.bucket_start
          and s.started_at < b.bucket_end
      ), 0) as sessions,
      coalesce((
        select sum(extract(epoch from (least(s.seg_end, b.bucket_end) - greatest(s.seg_start, b.bucket_start))))::bigint
        from session_segments s
        where s.seg_start < b.bucket_end
          and s.seg_end > b.bucket_start
      ), 0) as online_seconds,
      coalesce((
        select sum(extract(epoch from (least(st.seg_end, b.bucket_end) - greatest(st.seg_start, b.bucket_start))))::bigint
        from status_segments st
        where st.status = 'idle'
          and st.seg_start < b.bucket_end
          and st.seg_end > b.bucket_start
      ), 0) as idle_seconds,
      coalesce((
        select sum(extract(epoch from (least(st.seg_end, b.bucket_end) - greatest(st.seg_start, b.bucket_start))))::bigint
        from status_segments st
        where st.status = 'in_call'
          and st.seg_start < b.bucket_end
          and st.seg_end > b.bucket_start
      ), 0) as call_seconds
    from buckets b
  ),
  unit_sessions as (
    select
      unit_id,
      count(*)::int as sessions,
      count(distinct operator_id)::int as active_operators,
      coalesce(sum(extract(epoch from (seg_end - seg_start)))::bigint, 0) as online_seconds
    from session_segments
    where seg_end > seg_start
    group by unit_id
  ),
  unit_status as (
    select
      o.unit_id,
      coalesce(sum(extract(epoch from (st.seg_end - st.seg_start))) filter (where st.status = 'idle'), 0)::bigint as idle_seconds,
      coalesce(sum(extract(epoch from (st.seg_end - st.seg_start))) filter (where st.status = 'in_call'), 0)::bigint as call_seconds
    from status_segments st
    join visible_operators o on o.id = st.operator_id
    where st.seg_end > st.seg_start
    group by o.unit_id
  ),
  unit_challenges as (
    select
      o.unit_id,
      count(*)::int as challenges_received,
      count(*) filter (where cl.answered_at is not null or cl.status = 'answered')::int as challenges_answered,
      count(*) filter (where cl.answer_result in ('correct', 'success', 'right', 'ok'))::int as challenges_correct
    from challenge_scope cl
    join visible_operators o on o.id = cl.operator_id
    group by o.unit_id
  ),
  condominium_rows as (
    select
      u.id as unit_id,
      u.name as unit_name,
      coalesce(us.active_operators, 0) as active_operators,
      coalesce(us.sessions, 0) as sessions,
      coalesce(us.online_seconds, 0) as online_seconds,
      coalesce(ust.idle_seconds, 0) as idle_seconds,
      coalesce(ust.call_seconds, 0) as call_seconds,
      coalesce(uc.challenges_answered, 0) as challenges_answered,
      coalesce(uc.challenges_received, 0) as challenges_received,
      coalesce(uc.challenges_correct, 0) as challenges_correct
    from (
      select distinct unit_id as id, unit_name as name
      from visible_operators
    ) u
    left join unit_sessions us on us.unit_id = u.id
    left join unit_status ust on ust.unit_id = u.id
    left join unit_challenges uc on uc.unit_id = u.id
  ),
  operator_sessions_agg as (
    select
      operator_id,
      count(*)::int as sessions,
      coalesce(sum(extract(epoch from (seg_end - seg_start)))::bigint, 0) as online_seconds,
      max(raw_end) as last_session_at
    from session_segments
    where seg_end > seg_start
    group by operator_id
  ),
  operator_status_agg as (
    select
      operator_id,
      coalesce(sum(extract(epoch from (seg_end - seg_start))) filter (where status = 'idle'), 0)::bigint as idle_seconds,
      coalesce(sum(extract(epoch from (seg_end - seg_start))) filter (where status = 'in_call'), 0)::bigint as call_seconds,
      max(seg_end) as last_status_at
    from status_segments
    where seg_end > seg_start
    group by operator_id
  ),
  operator_challenges as (
    select
      operator_id,
      count(*)::int as challenges_received,
      count(*) filter (where answered_at is not null or status = 'answered')::int as challenges_answered,
      count(*) filter (where answer_result in ('correct', 'success', 'right', 'ok'))::int as challenges_correct
    from challenge_scope
    group by operator_id
  ),
  ranking_all as (
    select
      o.id as operator_id,
      o.display_name as operator_name,
      o.unit_name,
      coalesce(os.sessions, 0) as sessions,
      coalesce(os.online_seconds, 0) as online_seconds,
      coalesce(ost.idle_seconds, 0) as idle_seconds,
      coalesce(ost.call_seconds, 0) as call_seconds,
      coalesce(oc.challenges_received, 0) as challenges_received,
      coalesce(oc.challenges_answered, 0) as challenges_answered,
      coalesce(oc.challenges_correct, 0) as challenges_correct,
      greatest(coalesce(os.last_session_at, '-infinity'::timestamptz), coalesce(ost.last_status_at, '-infinity'::timestamptz)) as last_event_at
    from visible_operators o
    left join operator_sessions_agg os on os.operator_id = o.id
    left join operator_status_agg ost on ost.operator_id = o.id
    left join operator_challenges oc on oc.operator_id = o.id
  ),
  ranking_count as (
    select count(*)::int as total from ranking_all
  ),
  ranking_page as (
    select *
    from ranking_all
    order by online_seconds desc, sessions desc, operator_name
    limit v_rank_page_size offset v_rank_offset
  ),
  music_source as (
    select
      false as available,
      'Nao existe log real de reproducao/interacao musical no schema atual; playlist_tracks representa biblioteca/importacao, nao playback.'::text as reason
  )
  select jsonb_build_object(
    'filters', jsonb_build_object(
      'start_at', v_start,
      'end_at', v_end,
      'unit_id', v_unit,
      'operator_id', v_operator,
      'shift', v_shift,
      'ranking_page', v_rank_page,
      'ranking_page_size', v_rank_page_size
    ),
    'filter_options', jsonb_build_object(
      'units', coalesce((
        select jsonb_agg(jsonb_build_object('id', id, 'name', name) order by name)
        from all_filter_units
      ), '[]'::jsonb),
      'operators', coalesce((
        select jsonb_agg(jsonb_build_object('id', id, 'display_name', display_name, 'unit_id', unit_id) order by display_name)
        from all_filter_operators
      ), '[]'::jsonb),
      'shifts', coalesce((
        select jsonb_agg(distinct jsonb_build_object('value', shift_kind, 'label',
          case shift_kind when 'day' then 'Diurno' when 'night' then 'Noturno' else 'Outro' end
        ))
        from operator_base
      ), '[]'::jsonb)
    ),
    'metrics', jsonb_build_object(
      'active_operators', coalesce((select active_operators from session_agg), 0),
      'total_sessions', coalesce((select total_sessions from session_agg), 0),
      'online_seconds', coalesce((select online_seconds from session_agg), 0),
      'idle_seconds', coalesce((select idle_seconds from status_duration), 0),
      'call_seconds', coalesce((select call_seconds from status_duration), 0),
      'challenge_response_rate', case
        when coalesce((select received from challenge_agg), 0) = 0 then null
        else round(((select answered from challenge_agg)::numeric / nullif((select received from challenge_agg), 0)) * 100, 1)
      end,
      'challenge_accuracy_rate', case
        when coalesce((select answered from challenge_agg), 0) = 0 then null
        else round(((select correct from challenge_agg)::numeric / nullif((select answered from challenge_agg), 0)) * 100, 1)
      end,
      'challenges_received', coalesce((select received from challenge_agg), 0),
      'challenges_answered', coalesce((select answered from challenge_agg), 0),
      'music_interactions', null,
      'music_interactions_available', (select available from music_source),
      'music_interactions_unavailable_reason', (select reason from music_source)
    ),
    'timeseries', coalesce((
      select jsonb_agg(jsonb_build_object(
        'bucket_start', bucket_start,
        'sessions', sessions,
        'online_seconds', online_seconds,
        'idle_seconds', idle_seconds,
        'call_seconds', call_seconds
      ) order by bucket_start)
      from timeseries
    ), '[]'::jsonb),
    'condominiums', coalesce((
      select jsonb_agg(jsonb_build_object(
        'unit_id', unit_id,
        'unit_name', unit_name,
        'active_operators', active_operators,
        'sessions', sessions,
        'online_seconds', online_seconds,
        'idle_seconds', idle_seconds,
        'call_seconds', call_seconds,
        'challenges_answered', challenges_answered,
        'challenges_received', challenges_received,
        'challenge_accuracy_rate', case when challenges_answered = 0 then null else round((challenges_correct::numeric / challenges_answered) * 100, 1) end
      ) order by unit_name)
      from condominium_rows
    ), '[]'::jsonb),
    'ranking', jsonb_build_object(
      'rows', coalesce((
        select jsonb_agg(jsonb_build_object(
          'operator_id', operator_id,
          'operator_name', operator_name,
          'unit_name', unit_name,
          'sessions', sessions,
          'online_seconds', online_seconds,
          'idle_seconds', idle_seconds,
          'call_seconds', call_seconds,
          'challenges_received', challenges_received,
          'challenges_answered', challenges_answered,
          'challenge_response_rate', case when challenges_received = 0 then null else round((challenges_answered::numeric / challenges_received) * 100, 1) end,
          'challenge_accuracy_rate', case when challenges_answered = 0 then null else round((challenges_correct::numeric / challenges_answered) * 100, 1) end,
          'last_event_at', nullif(last_event_at, '-infinity'::timestamptz)
        ) order by online_seconds desc, sessions desc, operator_name)
        from ranking_page
      ), '[]'::jsonb),
      'total', (select total from ranking_count),
      'page', v_rank_page,
      'page_size', v_rank_page_size
    ),
    'status_breakdown', (select rows from status_json),
    'sources', jsonb_build_array(
      jsonb_build_object('key', 'sessions', 'label', 'Sessoes', 'available', true, 'tables', jsonb_build_array('operator_sessions')),
      jsonb_build_object('key', 'status_durations', 'label', 'Tempo por status', 'available', true, 'tables', jsonb_build_array('operator_status_history', 'operator_states')),
      jsonb_build_object('key', 'challenges', 'label', 'Desafios', 'available', true, 'tables', jsonb_build_array('challenge_logs', 'challenges')),
      jsonb_build_object('key', 'music_playback', 'label', 'Reproducao musical', 'available', false, 'tables', jsonb_build_array(), 'reason', (select reason from music_source))
    )
  )
  into v_payload;

  return v_payload;
end;
$$;

revoke all on function public.admin_analytics_dashboard(jsonb) from public, anon;
grant execute on function public.admin_analytics_dashboard(jsonb) to authenticated;
