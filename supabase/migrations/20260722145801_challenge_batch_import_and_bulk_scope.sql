-- Atomic challenge CSV import and bulk management.
-- Validation and authorship live in Postgres so the Admin cannot create a
-- partially imported file or forge the acting administrator.

create or replace function public.admin_import_challenges_batch(
  p_challenges jsonb,
  p_unit_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_item jsonb;
  v_ordinality bigint;
  v_title text;
  v_prompt text;
  v_alternatives jsonb;
  v_correct text;
  v_answer_definition jsonb;
  v_id uuid;
  v_ids uuid[] := array[]::uuid[];
  v_count integer;
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'operations_manager', 'challenge_manager'],
    null
  );

  if p_unit_id is not null then
    if not exists (
      select 1 from public.units unit_row
      where unit_row.id = p_unit_id and unit_row.active = true
    ) then
      raise exception using errcode = '22023', message = 'CHALLENGE_BATCH_UNIT_NOT_FOUND';
    end if;

    if v_admin.role = 'operations_manager'
       and not public.admin_can_manage_operator_unit(p_unit_id) then
      raise exception using errcode = '42501', message = 'CHALLENGE_BATCH_OUTSIDE_UNIT_SCOPE';
    end if;
  end if;

  if jsonb_typeof(p_challenges) <> 'array' then
    raise exception using errcode = '22023', message = 'CHALLENGE_BATCH_ARRAY_REQUIRED';
  end if;

  v_count := jsonb_array_length(p_challenges);
  if v_count < 1 then
    raise exception using errcode = '22023', message = 'CHALLENGE_BATCH_EMPTY';
  end if;
  if v_count > 500 then
    raise exception using errcode = '22023', message = 'CHALLENGE_BATCH_LIMIT_EXCEEDED';
  end if;

  for v_item, v_ordinality in
    select item.value, item.ordinality
    from jsonb_array_elements(p_challenges) with ordinality as item(value, ordinality)
  loop
    if jsonb_typeof(v_item) <> 'object' then
      raise exception using
        errcode = '22023',
        message = format('CHALLENGE_BATCH_ROW_%s_OBJECT_REQUIRED', v_ordinality);
    end if;

    v_title := btrim(coalesce(v_item->>'title', ''));
    v_prompt := btrim(coalesce(v_item->>'prompt', ''));
    v_alternatives := v_item->'alternatives';
    v_correct := upper(btrim(coalesce(v_item->>'correct', '')));

    if v_title = '' then
      raise exception using errcode = '22023', message = format('CHALLENGE_BATCH_ROW_%s_TITLE_REQUIRED', v_ordinality);
    end if;
    if char_length(v_title) > 200 then
      raise exception using errcode = '22001', message = format('CHALLENGE_BATCH_ROW_%s_TITLE_TOO_LONG', v_ordinality);
    end if;
    if v_prompt = '' then
      raise exception using errcode = '22023', message = format('CHALLENGE_BATCH_ROW_%s_PROMPT_REQUIRED', v_ordinality);
    end if;
    if char_length(v_prompt) > 2000 then
      raise exception using errcode = '22001', message = format('CHALLENGE_BATCH_ROW_%s_PROMPT_TOO_LONG', v_ordinality);
    end if;
    if jsonb_typeof(v_alternatives) <> 'array'
       or jsonb_array_length(v_alternatives) <> 4 then
      raise exception using errcode = '22023', message = format('CHALLENGE_BATCH_ROW_%s_ALTERNATIVES_INVALID', v_ordinality);
    end if;
    if exists (
      select 1
      from jsonb_array_elements_text(v_alternatives) alternative(value)
      where btrim(alternative.value) = '' or char_length(btrim(alternative.value)) > 500
    ) then
      raise exception using errcode = '22023', message = format('CHALLENGE_BATCH_ROW_%s_ALTERNATIVES_INVALID', v_ordinality);
    end if;
    if v_correct not in ('A', 'B', 'C', 'D') then
      raise exception using errcode = '22023', message = format('CHALLENGE_BATCH_ROW_%s_CORRECT_INVALID', v_ordinality);
    end if;

    v_answer_definition := jsonb_build_object(
      'alternatives', v_alternatives,
      'correct', v_correct,
      'options', jsonb_build_array(
        jsonb_build_object('id', 'option_a', 'text', v_alternatives->>0),
        jsonb_build_object('id', 'option_b', 'text', v_alternatives->>1),
        jsonb_build_object('id', 'option_c', 'text', v_alternatives->>2),
        jsonb_build_object('id', 'option_d', 'text', v_alternatives->>3)
      ),
      'correct_option_id', 'option_' || lower(v_correct)
    );

    if not private.challenge_answer_definition_is_valid(v_answer_definition) then
      raise exception using errcode = '22023', message = format('CHALLENGE_BATCH_ROW_%s_ANSWER_INVALID', v_ordinality);
    end if;

    insert into public.challenges (
      unit_id,
      title,
      prompt,
      kind,
      answer_definition,
      status,
      created_by,
      revision,
      created_at,
      updated_at
    ) values (
      p_unit_id,
      v_title,
      v_prompt,
      'multiple_choice',
      v_answer_definition,
      'draft',
      v_admin.id,
      1,
      clock_timestamp(),
      clock_timestamp()
    )
    returning id into v_id;

    v_ids := array_append(v_ids, v_id);
  end loop;

  insert into public.admin_audit_logs (
    admin_user_id,
    action,
    entity_type,
    entity_id,
    after_data,
    occurred_at
  ) values (
    v_admin.id,
    'challenges_batch_imported',
    'challenge_batch',
    null,
    jsonb_build_object(
      'count', v_count,
      'unit_id', p_unit_id,
      'status', 'draft',
      'challenge_ids', to_jsonb(v_ids)
    ),
    clock_timestamp()
  );

  return jsonb_build_object(
    'imported', v_count,
    'unit_id', p_unit_id,
    'status', 'draft',
    'challenge_ids', to_jsonb(v_ids)
  );
end;
$$;

create or replace function public.admin_bulk_update_challenges(
  p_challenge_ids uuid[],
  p_status text default null,
  p_change_unit boolean default false,
  p_unit_id uuid default null
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_ids uuid[];
  v_expected integer;
  v_found integer;
  v_before jsonb;
  v_now timestamptz := clock_timestamp();
begin
  v_admin := private.require_admin_for_backend(
    array['superadmin', 'operations_manager', 'challenge_manager'],
    null
  );

  select coalesce(array_agg(distinct challenge_id order by challenge_id), array[]::uuid[])
    into v_ids
  from unnest(coalesce(p_challenge_ids, array[]::uuid[])) challenge_id
  where challenge_id is not null;

  v_expected := cardinality(v_ids);
  if v_expected < 1 then
    raise exception using errcode = '22023', message = 'CHALLENGE_BULK_SELECTION_REQUIRED';
  end if;
  if v_expected > 500 then
    raise exception using errcode = '22023', message = 'CHALLENGE_BULK_LIMIT_EXCEEDED';
  end if;
  if p_status is null and not coalesce(p_change_unit, false) then
    raise exception using errcode = '22023', message = 'CHALLENGE_BULK_CHANGE_REQUIRED';
  end if;
  if p_status is not null and p_status not in ('draft', 'active', 'inactive', 'archived') then
    raise exception using errcode = '22023', message = 'CHALLENGE_BULK_STATUS_INVALID';
  end if;

  if coalesce(p_change_unit, false) then
    if p_unit_id is null and v_admin.role not in ('superadmin', 'challenge_manager') then
      raise exception using errcode = '42501', message = 'CHALLENGE_BULK_GLOBAL_SCOPE_FORBIDDEN';
    end if;

    if p_unit_id is not null then
      if not exists (
        select 1 from public.units unit_row
        where unit_row.id = p_unit_id and unit_row.active = true
      ) then
        raise exception using errcode = '22023', message = 'CHALLENGE_BULK_UNIT_NOT_FOUND';
      end if;
      if v_admin.role = 'operations_manager'
         and not public.admin_can_manage_operator_unit(p_unit_id) then
        raise exception using errcode = '42501', message = 'CHALLENGE_BULK_OUTSIDE_TARGET_SCOPE';
      end if;
    end if;
  end if;

  perform 1
  from public.challenges challenge_row
  where challenge_row.id = any(v_ids)
  order by challenge_row.id
  for update;

  get diagnostics v_found = row_count;
  if v_found <> v_expected then
    raise exception using errcode = 'P0002', message = 'CHALLENGE_BULK_SELECTION_STALE';
  end if;

  if v_admin.role = 'operations_manager' and exists (
    select 1
    from public.challenges challenge_row
    where challenge_row.id = any(v_ids)
      and challenge_row.unit_id is not null
      and not public.admin_can_manage_operator_unit(challenge_row.unit_id)
  ) then
    raise exception using errcode = '42501', message = 'CHALLENGE_BULK_OUTSIDE_SOURCE_SCOPE';
  end if;

  if coalesce(p_change_unit, false)
     and v_admin.role = 'operations_manager'
     and exists (
       select 1 from public.challenges challenge_row
       where challenge_row.id = any(v_ids) and challenge_row.unit_id is null
     ) then
    raise exception using errcode = '42501', message = 'CHALLENGE_BULK_GLOBAL_SOURCE_FORBIDDEN';
  end if;

  select jsonb_agg(
    jsonb_build_object(
      'id', challenge_row.id,
      'status', challenge_row.status,
      'unit_id', challenge_row.unit_id,
      'revision', challenge_row.revision
    ) order by challenge_row.id
  )
    into v_before
  from public.challenges challenge_row
  where challenge_row.id = any(v_ids);

  update public.challenges challenge_row
  set status = coalesce(p_status, challenge_row.status),
      unit_id = case when coalesce(p_change_unit, false) then p_unit_id else challenge_row.unit_id end,
      revision = challenge_row.revision + 1,
      updated_at = v_now
  where challenge_row.id = any(v_ids);

  insert into public.admin_audit_logs (
    admin_user_id,
    action,
    entity_type,
    entity_id,
    before_data,
    after_data,
    occurred_at
  ) values (
    v_admin.id,
    'challenges_bulk_updated',
    'challenge_batch',
    null,
    jsonb_build_object('challenges', v_before),
    jsonb_build_object(
      'challenge_ids', to_jsonb(v_ids),
      'count', v_expected,
      'status', p_status,
      'unit_changed', coalesce(p_change_unit, false),
      'unit_id', case when coalesce(p_change_unit, false) then to_jsonb(p_unit_id) else null end
    ),
    v_now
  );

  return jsonb_build_object(
    'updated', v_expected,
    'status', p_status,
    'unit_changed', coalesce(p_change_unit, false),
    'unit_id', case when coalesce(p_change_unit, false) then to_jsonb(p_unit_id) else null end
  );
end;
$$;

revoke all on function public.admin_import_challenges_batch(jsonb, uuid) from public, anon;
grant execute on function public.admin_import_challenges_batch(jsonb, uuid) to authenticated;

revoke all on function public.admin_bulk_update_challenges(uuid[], text, boolean, uuid) from public, anon;
grant execute on function public.admin_bulk_update_challenges(uuid[], text, boolean, uuid) to authenticated;
