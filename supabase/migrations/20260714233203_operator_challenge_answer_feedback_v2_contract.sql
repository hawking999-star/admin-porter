-- Versioned feedback contract for the Operator App challenge answer flow.
--
-- The legacy operator_challenge_answer(uuid, jsonb) remains intentionally
-- untouched. This migration adds stable option identifiers and a v2 wrapper
-- that delegates the state transition and penalties to that legacy RPC.

alter table public.challenge_logs
  add column if not exists answer_feedback jsonb;

-- Existing definitions stored an array of texts plus the correct A-D letter.
-- Keep both legacy members for the published App, while adding a canonical,
-- deterministic option id for every existing and future multiple-choice item.
update public.challenges c
set answer_definition = jsonb_set(
  jsonb_set(
    c.answer_definition,
    '{options}',
    jsonb_build_array(
      jsonb_build_object('id', 'option_a', 'text', c.answer_definition->'alternatives'->>0),
      jsonb_build_object('id', 'option_b', 'text', c.answer_definition->'alternatives'->>1),
      jsonb_build_object('id', 'option_c', 'text', c.answer_definition->'alternatives'->>2),
      jsonb_build_object('id', 'option_d', 'text', c.answer_definition->'alternatives'->>3)
    ),
    true
  ),
  '{correct_option_id}',
  to_jsonb('option_' || lower(coalesce(c.answer_definition->>'correct', ''))),
  true
)
where c.kind = 'multiple_choice';

create or replace function private.challenge_answer_definition_is_valid(
  p_answer_definition jsonb
)
returns boolean
language plpgsql
immutable
set search_path = ''
as $$
declare
  v_position integer;
  v_option jsonb;
begin
  if coalesce(jsonb_typeof(p_answer_definition), '') <> 'object'
     or coalesce(jsonb_typeof(p_answer_definition->'alternatives'), '') <> 'array'
     or jsonb_array_length(p_answer_definition->'alternatives') <> 4
     or coalesce(jsonb_typeof(p_answer_definition->'options'), '') <> 'array'
     or jsonb_array_length(p_answer_definition->'options') <> 4
     or upper(coalesce(p_answer_definition->>'correct', '')) not in ('A', 'B', 'C', 'D')
     or p_answer_definition->>'correct_option_id'
        <> 'option_' || lower(p_answer_definition->>'correct') then
    return false;
  end if;

  for v_position in 0..3 loop
    v_option := p_answer_definition->'options'->v_position;
    if nullif(btrim(p_answer_definition->'alternatives'->>v_position), '') is null
       or jsonb_typeof(v_option) <> 'object'
       or v_option->>'id' <> 'option_' || chr(ascii('a') + v_position)
       or nullif(btrim(v_option->>'text'), '') is null
       or v_option->>'text' is distinct from p_answer_definition->'alternatives'->>v_position then
      return false;
    end if;
  end loop;

  return true;
end;
$$;

-- Do not leave malformed legacy data publishable. Valid existing questions
-- preserve their answer verbatim; malformed active questions become drafts for
-- an administrator to correct before a future operator can receive them.
update public.challenges
set status = 'draft',
    revision = revision + 1,
    updated_at = now()
where kind = 'multiple_choice'
  and status = 'active'
  and not private.challenge_answer_definition_is_valid(answer_definition);

create or replace function private.challenge_public_options(
  p_answer_definition jsonb
)
returns jsonb
language sql
immutable
set search_path = ''
as $$
  select coalesce(
    jsonb_agg(
      jsonb_build_object('id', value->>'id', 'text', value->>'text')
      order by ordinality
    ),
    '[]'::jsonb
  )
  from jsonb_array_elements(coalesce(p_answer_definition->'options', '[]'::jsonb))
    with ordinality
$$;

-- Keep the old snapshot shape and add only the public stable ids.  Build this
-- object explicitly rather than subtracting keys, so no internal answer field
-- can reach the initial snapshot as definitions evolve.
create or replace function private.challenge_payload(
  p_operator_id uuid,
  p_session_id uuid
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_log public.challenge_logs%rowtype;
  v_challenge public.challenges%rowtype;
  v_block public.operator_blocks%rowtype;
  v_operational_snapshot jsonb;
  v_payload jsonb;
begin
  v_operational_snapshot := private.challenge_operational_snapshot(
    p_operator_id,
    p_session_id
  );

  select * into v_block
  from public.operator_blocks
  where operator_id = p_operator_id
    and status = 'active'
    and (blocked_until is null or blocked_until > now())
  order by started_at desc, id desc
  limit 1;

  if v_block.id is not null then
    v_payload := jsonb_build_object(
      'next_screen', 'blocked',
      'blocked_until', v_block.blocked_until,
      'block_reason', v_block.reason_code,
      'server_now', now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  select * into v_log
  from private.current_operator_challenge(p_operator_id, p_session_id);

  if v_log.id is null then
    v_payload := jsonb_build_object('next_screen', 'player', 'server_now', now());
    return v_payload || v_operational_snapshot;
  end if;

  select * into v_challenge
  from public.challenges
  where id = v_log.challenge_id;

  if v_log.status = 'idle' then
    v_payload := jsonb_build_object(
      'next_screen', 'idle',
      'challenge_log_id', v_log.id,
      'server_now', now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  if v_log.status = 'paused' then
    v_payload := jsonb_build_object(
      'next_screen', 'paused_by_call',
      'challenge_log_id', v_log.id,
      'server_now', now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  if v_log.status = 'scheduled' and v_log.scheduled_for > now() then
    v_payload := jsonb_build_object(
      'next_screen', 'player',
      'next_challenge_at', v_log.scheduled_for,
      'server_now', now()
    );
    return v_payload || v_operational_snapshot;
  end if;

  v_payload := jsonb_build_object(
    'next_screen', 'challenge',
    'server_now', now(),
    'challenge', jsonb_build_object(
      'log_id', v_log.id,
      'id', v_challenge.id,
      'title', v_challenge.title,
      'prompt', v_challenge.prompt,
      'kind', v_challenge.kind,
      'answer_definition', jsonb_build_object(
        'alternatives', v_challenge.answer_definition->'alternatives',
        'options', private.challenge_public_options(v_challenge.answer_definition)
      ),
      'expires_at', v_log.expires_at
    )
  );
  return v_payload || v_operational_snapshot;
end
$$;

create or replace function public.admin_upsert_challenge(p_challenge jsonb)
returns uuid
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_id uuid := nullif(p_challenge->>'id', '')::uuid;
  v_unit_id uuid := nullif(p_challenge->>'unit_id', '')::uuid;
  v_admin public.admin_users%rowtype;
  v_title text := nullif(btrim(p_challenge->>'title'), '');
  v_prompt text := nullif(btrim(p_challenge->>'prompt'), '');
  v_answer_definition jsonb := p_challenge->'answer_definition';
  v_options jsonb;
  v_correct text;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'operations_manager', 'challenge_manager'],
    v_unit_id
  );

  if v_title is null then raise exception 'titulo_obrigatorio'; end if;
  if v_prompt is null then raise exception 'enunciado_obrigatorio'; end if;
  if jsonb_typeof(v_answer_definition->'alternatives') <> 'array'
     or jsonb_array_length(v_answer_definition->'alternatives') <> 4 then
    raise exception 'respostas_invalidas';
  end if;

  -- The current Admin still posts alternatives plus the A-D correct letter.
  -- Generate fixed ids in that semantic order, so editing text never changes
  -- the saved correct choice and no frontend contract needs to change now.
  v_correct := upper(coalesce(v_answer_definition->>'correct', ''));
  v_options := jsonb_build_array(
    jsonb_build_object('id', 'option_a', 'text', v_answer_definition->'alternatives'->>0),
    jsonb_build_object('id', 'option_b', 'text', v_answer_definition->'alternatives'->>1),
    jsonb_build_object('id', 'option_c', 'text', v_answer_definition->'alternatives'->>2),
    jsonb_build_object('id', 'option_d', 'text', v_answer_definition->'alternatives'->>3)
  );
  v_answer_definition := jsonb_build_object(
    'alternatives', v_answer_definition->'alternatives',
    'correct', v_correct,
    'options', v_options,
    'correct_option_id', 'option_' || lower(v_correct)
  );

  if not private.challenge_answer_definition_is_valid(v_answer_definition) then
    raise exception 'respostas_invalidas';
  end if;

  if v_id is null then
    insert into public.challenges(title, prompt, kind, answer_definition, status, unit_id, created_by)
    values(v_title, v_prompt, 'multiple_choice', v_answer_definition,
      coalesce(p_challenge->>'status', 'draft'), v_unit_id, v_admin.id)
    returning id into v_id;
  else
    update public.challenges
    set title = v_title,
        prompt = v_prompt,
        answer_definition = v_answer_definition,
        status = coalesce(p_challenge->>'status', status),
        unit_id = v_unit_id,
        block_seconds = null,
        revision = revision + 1,
        updated_at = now()
    where id = v_id;
  end if;

  return v_id;
end
$$;

create or replace function public.operator_challenge_answer_v2(
  p_log_id uuid,
  p_answer jsonb
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_op public.operators%rowtype;
  v_log public.challenge_logs%rowtype;
  v_challenge public.challenges%rowtype;
  v_selected_option_id text;
  v_selected_option_text text;
  v_correct_option_id text;
  v_correct_option_text text;
  v_feedback jsonb;
  v_next_snapshot jsonb;
  v_response jsonb;
begin
  select * into v_op
  from public.operators
  where auth_user_id = auth.uid() and active;
  if v_op.id is null then raise exception 'operador_invalido'; end if;

  if coalesce(jsonb_typeof(p_answer), '') <> 'object'
     or not (p_answer ? 'option_id')
     or coalesce(jsonb_typeof(p_answer->'option_id'), '') <> 'string'
     or nullif(btrim(p_answer->>'option_id'), '') is null
     or (select count(*) from jsonb_object_keys(p_answer)) <> 1 then
    raise exception 'resposta_invalida';
  end if;
  v_selected_option_id := p_answer->>'option_id';

  select cl.* into v_log
  from public.challenge_logs cl
  join public.operator_sessions s
    on s.id = cl.session_id
   and s.operator_id = cl.operator_id
   and s.status = 'active'
   and s.expires_at > now()
  where cl.id = p_log_id
    and cl.operator_id = v_op.id
  for update of cl;

  if v_log.id is null then raise exception 'desafio_indisponivel'; end if;

  -- A v2 retry returns the exact response persisted by its first accepted call.
  if v_log.status in ('answered', 'failed') then
    v_response := v_log.answer_feedback;
    if jsonb_typeof(v_response) = 'object'
       and v_response->'answer_feedback'->>'selected_option_id' = v_selected_option_id then
      return v_response;
    end if;
    raise exception 'desafio_ja_finalizado';
  end if;

  if v_log.status not in ('pending', 'displayed') or v_log.expires_at <= now() then
    raise exception 'desafio_indisponivel';
  end if;

  select * into v_challenge
  from public.challenges
  where id = v_log.challenge_id;
  if v_challenge.id is null
     or not private.challenge_answer_definition_is_valid(v_challenge.answer_definition) then
    raise exception 'desafio_configuracao_invalida';
  end if;

  select option.value->>'text' into v_selected_option_text
  from jsonb_array_elements(v_challenge.answer_definition->'options') as option(value)
  where option.value->>'id' = v_selected_option_id;
  if v_selected_option_text is null then raise exception 'resposta_invalida'; end if;

  v_correct_option_id := v_challenge.answer_definition->>'correct_option_id';
  select option.value->>'text' into v_correct_option_text
  from jsonb_array_elements(v_challenge.answer_definition->'options') as option(value)
  where option.value->>'id' = v_correct_option_id;

  -- Delegate the write, penalty and next-state rules to the existing RPC.
  -- This is deliberately the legacy A-D value it already consumes.
  v_next_snapshot := public.operator_challenge_answer(
    p_log_id,
    jsonb_build_object('value', upper(right(v_selected_option_id, 1)))
  );

  select * into v_log
  from public.challenge_logs
  where id = p_log_id;

  v_feedback := jsonb_build_object(
    'result', case when v_log.answer_result = 'correct' then 'correct' else 'incorrect' end,
    'is_correct', v_log.answer_result = 'correct',
    'selected_option_id', v_selected_option_id,
    'correct_option_id', v_correct_option_id,
    'correct_option_text', v_correct_option_text,
    'answered_at', v_log.answered_at
  );
  v_response := jsonb_build_object(
    'schema_version', 2,
    'answer_feedback', v_feedback,
    'next_snapshot', v_next_snapshot
  );

  update public.challenge_logs
  set answer_feedback = v_response
  where id = p_log_id;

  return v_response;
end
$$;

revoke all on function private.challenge_answer_definition_is_valid(jsonb) from public, anon, authenticated;
revoke all on function private.challenge_public_options(jsonb) from public, anon, authenticated;
revoke all on function private.challenge_payload(uuid, uuid) from public, anon, authenticated;
revoke all on function public.admin_upsert_challenge(jsonb) from public, anon;
grant execute on function public.admin_upsert_challenge(jsonb) to authenticated;
revoke all on function public.operator_challenge_answer_v2(uuid, jsonb) from public, anon;
grant execute on function public.operator_challenge_answer_v2(uuid, jsonb) to authenticated;

comment on function public.operator_challenge_answer_v2(uuid, jsonb) is
  'Version 2 challenge answer contract. Accepts only {option_id}; returns official post-answer feedback and the unchanged legacy next snapshot.';
