-- GREATEST is PostgreSQL expression syntax, not a schema-qualified function.
-- Preserve the live RPC definition and replace only the invalid call introduced
-- by 20260729030303_guard_challenges_outside_operator_shift.sql.
do $$
declare
  v_function regprocedure :=
    pg_catalog.to_regprocedure('public.operator_challenge_state(jsonb)');
  v_definition text;
  v_invalid_call constant text := 'pg_catalog.greatest(';
begin
  if v_function is null then
    raise exception 'public.operator_challenge_state(jsonb) does not exist';
  end if;

  select pg_catalog.pg_get_functiondef(v_function)
    into v_definition;

  if pg_catalog.strpos(v_definition, v_invalid_call) > 0 then
    execute pg_catalog.replace(
      v_definition,
      v_invalid_call,
      'greatest('
    );
  end if;
end;
$$;
