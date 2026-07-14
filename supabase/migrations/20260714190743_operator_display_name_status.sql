begin;

-- Snapshot exclusivo do Operador autenticado. Permite ao App explicar o prazo
-- de troca e a ultima decisao administrativa sem expor termos de moderacao.
create or replace function public.get_my_operator_display_name_status()
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_auth_user_id uuid := auth.uid();
  v_operator public.operators%rowtype;
  v_last_applied_at timestamptz;
  v_next_change_at timestamptz;
  v_review public.operator_display_name_requests%rowtype;
  v_now timestamptz := clock_timestamp();
begin
  if v_auth_user_id is null then
    return jsonb_build_object(
      'success', false,
      'server_now', v_now,
      'data', null,
      'error', jsonb_build_object(
        'code', 'NOT_AUTHENTICATED',
        'message', 'Sessao autenticada obrigatoria.',
        'retryable', false
      )
    );
  end if;

  select * into v_operator
  from public.operators
  where auth_user_id = v_auth_user_id;

  if v_operator.id is null then
    return jsonb_build_object(
      'success', false,
      'server_now', v_now,
      'data', null,
      'error', jsonb_build_object(
        'code', 'OPERATOR_NOT_FOUND',
        'message', 'Operador nao encontrado para esta sessao.',
        'retryable', false
      )
    );
  end if;

  select max(request_row.applied_at) into v_last_applied_at
  from public.operator_display_name_requests request_row
  where request_row.operator_id = v_operator.id
    and request_row.applied_at is not null;

  v_next_change_at := case
    when v_last_applied_at is null then null
    else v_last_applied_at + interval '15 days'
  end;

  -- A decisao pendente ou mais recente e a unica informacao de moderacao
  -- devolvida ao App. O termo que causou o bloqueio nunca sai do servidor.
  select * into v_review
  from public.operator_display_name_requests request_row
  where request_row.operator_id = v_operator.id
    and request_row.review_status in ('pending', 'approved', 'rejected')
  order by coalesce(request_row.reviewed_at, request_row.occurred_at) desc, request_row.id desc
  limit 1;

  return jsonb_build_object(
    'success', true,
    'server_now', v_now,
    'data', jsonb_build_object(
      'display_name', v_operator.display_name,
      'next_change_at', v_next_change_at,
      'can_change_now', coalesce(v_next_change_at <= v_now, true),
      'review', case
        when v_review.id is null then null
        else jsonb_build_object(
          'request_id', v_review.id,
          'requested_name', v_review.requested_name,
          'status', v_review.review_status,
          'reviewed_at', v_review.reviewed_at,
          'message', case v_review.review_status
            when 'pending' then 'Sua solicitacao de nome esta em analise.'
            when 'approved' then 'Sua solicitacao de nome foi aprovada.'
            else 'Sua solicitacao de nome foi negada pelo Administrador.'
          end,
          'reason', case
            when v_review.review_status in ('approved', 'rejected') then v_review.review_reason
            else null
          end
        )
      end
    ),
    'error', null
  );
end;
$$;

revoke all on function public.get_my_operator_display_name_status()
  from public, anon, authenticated;
grant execute on function public.get_my_operator_display_name_status()
  to authenticated;

commit;
