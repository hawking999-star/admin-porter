-- Challenge timing belongs to the effective global/unit rules, never to each challenge definition.

alter table public.challenges
  alter column block_seconds drop not null,
  alter column block_seconds drop default;

update public.challenges
set block_seconds = null
where block_seconds = 0;

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
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin','operations_manager','challenge_manager'],
    v_unit_id
  );

  if v_title is null then
    raise exception 'titulo_obrigatorio';
  end if;
  if v_prompt is null then
    raise exception 'enunciado_obrigatorio';
  end if;
  if jsonb_typeof(v_answer_definition->'alternatives') <> 'array'
     or jsonb_array_length(v_answer_definition->'alternatives') <> 4
     or coalesce(v_answer_definition->>'correct', '') not in ('A','B','C','D') then
    raise exception 'respostas_invalidas';
  end if;

  if v_id is null then
    insert into public.challenges(
      title,
      prompt,
      kind,
      answer_definition,
      status,
      unit_id,
      created_by
    )
    values(
      v_title,
      v_prompt,
      'multiple_choice',
      v_answer_definition,
      coalesce(p_challenge->>'status', 'draft'),
      v_unit_id,
      v_admin.id
    )
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
end;
$$;

create or replace function private.defer_challenge_after_call()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_response_seconds integer;
begin
  if old.status = 'paused'
     and new.status = 'pending'
     and old.pause_reason = 'call_active' then
    select coalesce((private.challenge_rules(o.unit_id)->>'response_seconds')::integer, 60)
    into v_response_seconds
    from public.operators o
    where o.id = new.operator_id;

    new.status := 'scheduled';
    new.scheduled_for := now() + interval '90 seconds';
    new.expires_at := new.scheduled_for + make_interval(secs => greatest(coalesce(v_response_seconds, 60), 15));
  end if;
  return new;
end;
$$;

revoke all on function public.admin_upsert_challenge(jsonb) from public, anon;
grant execute on function public.admin_upsert_challenge(jsonb) to authenticated;

revoke all on function private.defer_challenge_after_call() from public, anon, authenticated;
