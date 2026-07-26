-- O contrato histórico do App calculava lifecycle_status diretamente a partir
-- do status imutável do job original. Depois de uma remediação manual, use o
-- status geral reconciliado para que o App não continue exibindo "Falha".
alter function public.get_my_playlist_requests(jsonb)
  rename to get_my_playlist_requests_phase_manual_retry_impl;

revoke all on function public.get_my_playlist_requests_phase_manual_retry_impl(jsonb)
  from public, anon, authenticated;

create function public.get_my_playlist_requests(p_request jsonb default '{}'::jsonb)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_payload jsonb;
  v_requests jsonb;
begin
  v_payload := public.get_my_playlist_requests_phase_manual_retry_impl(p_request);
  if coalesce((v_payload->>'success')::boolean, false) is not true then
    return v_payload;
  end if;

  select coalesce(
    jsonb_agg(
      request_row || jsonb_build_object(
        'lifecycle_status',
        case request_row->>'general_status'
          when 'pending' then 'awaiting_approval'
          when 'rejected' then 'rejected'
          when 'completed' then 'completed'
          when 'partially_completed' then 'failed'
          when 'failed' then 'failed'
          else 'in_progress'
        end
      )
      order by request_row->>'created_at' desc, request_row->>'id' desc
    ),
    '[]'::jsonb
  )
  into v_requests
  from jsonb_array_elements(
    coalesce(v_payload#>'{data,requests}', '[]'::jsonb)
  ) request_row;

  return jsonb_set(v_payload, '{data,requests}', v_requests, true);
end;
$$;

revoke all on function public.get_my_playlist_requests(jsonb)
  from public, anon;
grant execute on function public.get_my_playlist_requests(jsonb)
  to authenticated;
