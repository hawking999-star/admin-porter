-- Contract tests for two independent daily challenge windows.
-- The transaction is always rolled back.

begin;

do $test$
declare
  v_rules jsonb := jsonb_build_object(
    'active_windows', jsonb_build_array(
      jsonb_build_object('key', 'daytime', 'enabled', true, 'start', '06:00', 'end', '11:30'),
      jsonb_build_object('key', 'nighttime', 'enabled', true, 'start', '18:00', 'end', '23:30')
    ),
    'timezone', 'America/Sao_Paulo'
  );
  v_actual timestamptz;
begin
  v_actual := private.challenge_schedule_at(
    v_rules,
    1200,
    '2026-07-22 10:00:00-03'::timestamptz
  );
  if v_actual <> '2026-07-22 10:20:00-03'::timestamptz then
    raise exception 'daytime_window_failed: %', v_actual;
  end if;

  v_actual := private.challenge_schedule_at(
    v_rules,
    1200,
    '2026-07-22 11:20:00-03'::timestamptz
  );
  if v_actual <> '2026-07-22 18:20:00-03'::timestamptz then
    raise exception 'daytime_gap_failed: %', v_actual;
  end if;

  v_actual := private.challenge_schedule_at(
    v_rules,
    1200,
    '2026-07-22 12:00:00-03'::timestamptz
  );
  if v_actual <> '2026-07-22 18:20:00-03'::timestamptz then
    raise exception 'between_windows_failed: %', v_actual;
  end if;

  v_actual := private.challenge_schedule_at(
    v_rules,
    1200,
    '2026-07-22 23:20:00-03'::timestamptz
  );
  if v_actual <> '2026-07-23 06:20:00-03'::timestamptz then
    raise exception 'overnight_gap_failed: %', v_actual;
  end if;

  v_actual := private.challenge_schedule_at(
    '{"active_window_start":"00:00","active_window_end":"00:00","timezone":"America/Sao_Paulo"}'::jsonb,
    1200,
    '2026-07-22 23:50:00-03'::timestamptz
  );
  if v_actual <> '2026-07-23 00:10:00-03'::timestamptz then
    raise exception 'legacy_24_hour_window_failed: %', v_actual;
  end if;
end
$test$;

select 'challenge_multiple_active_windows_ok' as result;

rollback;
