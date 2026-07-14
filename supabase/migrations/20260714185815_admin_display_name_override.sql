begin;

create or replace function public.admin_update_operator_display_name(
  p_operator uuid,
  p_display_name text,
  p_reason text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_admin public.admin_users%rowtype;
  v_operator public.operators%rowtype;
  v_display_name text := nullif(btrim(regexp_replace(coalesce(p_display_name, ''), '[[:space:]]+', ' ', 'g')), '');
  v_reason text := btrim(regexp_replace(coalesce(p_reason, ''), '[[:space:]]+', ' ', 'g'));
  v_now timestamptz := clock_timestamp();
begin
  select * into v_operator
  from public.operators
  where id = p_operator
  for update;

  if v_operator.id is null then raise exception 'operator_not_found'; end if;
  v_admin := private.require_admin_for_backend(
    array['superadmin','unit_manager','operations_manager'],
    v_operator.unit_id
  );

  if v_display_name is null or char_length(v_display_name) < 3 or char_length(v_display_name) > 50 then
    raise exception 'display_name_length_invalid';
  end if;
  if char_length(v_reason) < 3 or char_length(v_reason) > 300 then
    raise exception 'display_name_admin_reason_invalid';
  end if;

  if v_display_name = v_operator.display_name then
    return jsonb_build_object(
      'success', true,
      'server_now', v_now,
      'data', jsonb_build_object('display_name', v_operator.display_name, 'changed', false),
      'error', null
    );
  end if;

  perform set_config('app.audit_source', 'admin_explicit', true);
  update public.operators
  set display_name = v_display_name,
      updated_at = v_now
  where id = v_operator.id;

  insert into public.admin_audit_logs (
    admin_user_id, action, entity_type, entity_id, before_data, after_data, reason, occurred_at
  ) values (
    v_admin.id,
    'operator_display_name_corrected',
    'operator',
    v_operator.id,
    jsonb_build_object('display_name', v_operator.display_name),
    jsonb_build_object('display_name', v_display_name),
    v_reason,
    v_now
  );

  return jsonb_build_object(
    'success', true,
    'server_now', clock_timestamp(),
    'data', jsonb_build_object('display_name', v_display_name, 'changed', true),
    'error', null
  );
end;
$$;

revoke all on function public.admin_update_operator_display_name(uuid, text, text)
  from public, anon, authenticated;
grant execute on function public.admin_update_operator_display_name(uuid, text, text)
  to authenticated;

commit;
