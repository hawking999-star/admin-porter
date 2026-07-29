-- Logging in outside the effective shift is valid. The operator stays on the
-- player with operational status outside_shift, while the backend keeps every
-- challenge hidden and unscheduled until the shift becomes active.
do $$
declare
  v_function regprocedure;
  v_definition text;
  v_old text;
  v_new text;
begin
  v_function :=
    pg_catalog.to_regprocedure('private.challenge_payload(uuid,uuid)');

  if v_function is null then
    raise exception 'private.challenge_payload(uuid,uuid) does not exist';
  end if;

  select pg_catalog.pg_get_functiondef(v_function)
    into v_definition;

  v_old := $source$'next_screen', 'outside_shift'$source$;
  v_new := $source$'next_screen', 'player',
      'outside_shift', true,
      'challenge_mode', 'disabled'$source$;

  if pg_catalog.strpos(v_definition, v_old) = 0 then
    raise exception 'outside_shift challenge payload contract was not found';
  end if;

  execute pg_catalog.replace(v_definition, v_old, v_new);

  v_function :=
    pg_catalog.to_regprocedure(
      'private.operator_runtime_payload(uuid,uuid,text)'
    );

  if v_function is null then
    raise exception
      'private.operator_runtime_payload(uuid,uuid,text) does not exist';
  end if;

  select pg_catalog.pg_get_functiondef(v_function)
    into v_definition;

  v_old :=
    $source$when v_effective_status = 'outside_shift' then 'outside_shift'$source$;
  v_new :=
    $source$when v_effective_status = 'outside_shift' then 'player'$source$;

  if pg_catalog.strpos(v_definition, v_old) = 0 then
    raise exception 'outside_shift runtime payload contract was not found';
  end if;

  execute pg_catalog.replace(v_definition, v_old, v_new);
end;
$$;

comment on function private.challenge_payload(uuid, uuid) is
  'Returns the challenge snapshot. Outside shift keeps the player available with challenges disabled.';

comment on function private.operator_runtime_payload(uuid, uuid, text) is
  'Returns the operator runtime snapshot. Outside shift is a valid logged-in player state.';
