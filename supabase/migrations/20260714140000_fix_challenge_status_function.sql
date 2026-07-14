create or replace function public.admin_set_challenge_status(
  p_challenge_id uuid,
  p_status text
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_unit uuid;
begin
  select unit_id
    into v_unit
  from public.challenges
  where id = p_challenge_id;

  if not found then
    raise exception 'desafio_nao_encontrado';
  end if;

  perform private.require_admin_for_backend(
    array['superadmin', 'operations_manager', 'challenge_manager'],
    v_unit
  );

  if p_status not in ('draft', 'active', 'inactive', 'archived') then
    raise exception 'status_invalido';
  end if;

  update public.challenges
  set status = p_status,
      revision = revision + 1,
      updated_at = now()
  where id = p_challenge_id;
end
$$;

comment on function public.admin_set_challenge_status(uuid, text) is
  'Atualiza o status do desafio. A tabela usa status como fonte unica de verdade.';
