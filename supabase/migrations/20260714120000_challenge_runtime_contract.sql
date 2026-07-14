-- Runtime contract for operator challenges. The server owns clocks, selection and penalties.

alter table public.challenges
  add column if not exists unit_id uuid references public.units(id) on delete cascade,
  add column if not exists status text not null default 'draft',
  add column if not exists block_seconds integer not null default 0,
  add column if not exists revision bigint not null default 1,
  add column if not exists created_by uuid references public.admin_users(id) on delete set null;

alter table public.challenge_logs
  add column if not exists scheduled_for timestamptz,
  add column if not exists displayed_at timestamptz,
  add column if not exists pending_at timestamptz,
  add column if not exists closed_at timestamptz,
  add column if not exists answer jsonb,
  add column if not exists answer_result text,
  add column if not exists abandoned_at timestamptz;

alter table public.challenge_logs drop constraint if exists challenge_logs_status_check;
alter table public.challenge_logs add constraint challenge_logs_status_check
  check (status in ('scheduled','pending','displayed','paused','answered','failed','expired','idle','abandoned'));

create index if not exists challenges_unit_status_idx on public.challenges(unit_id, status);
create index if not exists challenge_logs_operator_session_idx on public.challenge_logs(operator_id, session_id, created_at desc);
create unique index if not exists one_open_challenge_per_operator_idx on public.challenge_logs(operator_id)
  where status in ('scheduled','pending','displayed','paused','idle');

create or replace function private.challenge_rules(p_unit_id uuid)
returns jsonb language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select value from public.system_settings where active and key = 'challenge_rules' and scope_type = 'unit' and scope_id = p_unit_id order by revision desc limit 1),
    (select value from public.system_settings where active and key = 'challenge_rules' and scope_type = 'global' order by revision desc limit 1),
    '{"min_interval_seconds":180,"max_interval_seconds":300,"response_seconds":60,"abandon_block_seconds":300,"error_block_seconds":[300,900,3600]}'::jsonb
  )
$$;

create or replace function private.current_operator_challenge(p_operator_id uuid)
returns public.challenge_logs language sql stable security definer set search_path = '' as $$
  select cl.* from public.challenge_logs cl
  where cl.operator_id = p_operator_id and cl.status in ('scheduled','pending','displayed','paused','idle')
  order by cl.created_at desc limit 1
$$;

create or replace function private.challenge_payload(p_operator_id uuid, p_session_id uuid)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_log public.challenge_logs%rowtype; v_c public.challenges%rowtype; v_block public.operator_blocks%rowtype;
begin
  select * into v_block from public.operator_blocks where operator_id=p_operator_id and status='active' and (blocked_until is null or blocked_until>now()) order by started_at desc limit 1;
  if v_block.id is not null then return jsonb_build_object('next_screen','blocked','blocked_until',v_block.blocked_until,'block_reason',v_block.reason_code,'server_now',now()); end if;
  select * into v_log from private.current_operator_challenge(p_operator_id);
  if v_log.id is null then return jsonb_build_object('next_screen','player','server_now',now()); end if;
  select * into v_c from public.challenges where id=v_log.challenge_id;
  if v_log.status='idle' then return jsonb_build_object('next_screen','idle','challenge_log_id',v_log.id,'server_now',now()); end if;
  if v_log.status='paused' then return jsonb_build_object('next_screen','paused_by_call','challenge_log_id',v_log.id,'server_now',now()); end if;
  if v_log.status='scheduled' and v_log.scheduled_for>now() then return jsonb_build_object('next_screen','player','next_challenge_at',v_log.scheduled_for,'server_now',now()); end if;
  return jsonb_build_object('next_screen','challenge','server_now',now(),'challenge',jsonb_build_object('log_id',v_log.id,'id',v_c.id,'title',v_c.title,'prompt',v_c.prompt,'kind',v_c.kind,'answer_definition',v_c.answer_definition - 'correct','expires_at',v_log.expires_at));
end $$;

create or replace function public.operator_challenge_state(p_request jsonb)
returns jsonb language plpgsql security definer set search_path = '' as $$
declare v_op public.operators%rowtype; v_session uuid := nullif(p_request->>'session_id','')::uuid; v_rules jsonb; v_log public.challenge_logs%rowtype; v_delay int; v_candidate uuid;
begin
  select * into v_op from public.operators where auth_user_id=auth.uid() and active;
  if v_op.id is null then raise exception 'operador_invalido'; end if;
  if not exists(select 1 from public.operator_sessions where id=v_session and operator_id=v_op.id and status='active' and expires_at>now()) then raise exception 'sessao_invalida'; end if;
  -- Abandonment is applied only when the operator returns, as agreed.
  select * into v_log from public.challenge_logs where operator_id=v_op.id and status='abandoned' and closed_at is null order by abandoned_at desc limit 1;
  if v_log.id is not null then
    v_rules := private.challenge_rules(v_op.unit_id);
    insert into public.operator_blocks(operator_id,status,reason_code,blocked_until,metadata) values(v_op.id,'active','challenge_abandoned',now()+make_interval(secs=>coalesce((v_rules->>'abandon_block_seconds')::int,300)),jsonb_build_object('challenge_log_id',v_log.id));
    update public.challenge_logs set closed_at=now() where id=v_log.id;
    return private.challenge_payload(v_op.id,v_session);
  end if;
  select * into v_log from private.current_operator_challenge(v_op.id);
  if v_log.id is null then
    v_rules:=private.challenge_rules(v_op.unit_id);
    v_delay:=floor(random()*(greatest((v_rules->>'max_interval_seconds')::int,(v_rules->>'min_interval_seconds')::int)-(v_rules->>'min_interval_seconds')::int+1))::int+(v_rules->>'min_interval_seconds')::int;
    select id into v_candidate from public.challenges c where c.status='active' and (c.unit_id=v_op.unit_id or c.unit_id is null) and not exists(select 1 from public.challenge_logs l where l.operator_id=v_op.id and l.session_id=v_session and l.challenge_id=c.id) order by random() limit 1;
    if v_candidate is null then select id into v_candidate from public.challenges where status='active' and (unit_id=v_op.unit_id or unit_id is null) order by random() limit 1; end if;
    if v_candidate is not null then insert into public.challenge_logs(challenge_id,operator_id,session_id,status,scheduled_for,pending_at,expires_at) values(v_candidate,v_op.id,v_session,'scheduled',now()+make_interval(secs=>v_delay),now(),now()+make_interval(secs=>v_delay+coalesce((v_rules->>'response_seconds')::int,60))); end if;
  else
    update public.challenge_logs set status='pending', displayed_at=coalesce(displayed_at,now()) where id=v_log.id and status='scheduled' and scheduled_for<=now();
    update public.challenge_logs set status='idle', closed_at=now() where id=v_log.id and status in ('pending','displayed') and expires_at<=now();
  end if;
  return private.challenge_payload(v_op.id,v_session);
end $$;

create or replace function public.operator_challenge_displayed(p_log_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_op uuid;
begin select id into v_op from public.operators where auth_user_id=auth.uid() and active; update public.challenge_logs set status='displayed',displayed_at=coalesce(displayed_at,now()) where id=p_log_id and operator_id=v_op and status='pending' and expires_at>now(); return private.challenge_payload(v_op,null); end $$;

create or replace function public.operator_challenge_answer(p_log_id uuid, p_answer jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_op public.operators%rowtype; v_log public.challenge_logs%rowtype; v_c public.challenges%rowtype; v_rules jsonb; v_errors int; v_seconds int; v_correct boolean;
begin
 select * into v_op from public.operators where auth_user_id=auth.uid() and active; select * into v_log from public.challenge_logs where id=p_log_id and operator_id=v_op.id for update; if v_log.id is null or v_log.status not in ('pending','displayed') or v_log.expires_at<=now() then raise exception 'desafio_indisponivel'; end if;
 select * into v_c from public.challenges where id=v_log.challenge_id; v_correct:=lower(coalesce(p_answer->>'value',''))=lower(coalesce(v_c.answer_definition->>'correct',''));
 update public.challenge_logs set status=case when v_correct then 'answered' else 'failed' end, answer=p_answer, answer_result=case when v_correct then 'correct' else 'incorrect' end, answered_at=now(),closed_at=now() where id=v_log.id;
 if not v_correct then
   select count(*) into v_errors from public.challenge_logs where operator_id=v_op.id and session_id=v_log.session_id and status='failed'; v_rules:=private.challenge_rules(v_op.unit_id); v_seconds:=coalesce((v_rules->'error_block_seconds'->>greatest(least(v_errors, jsonb_array_length(v_rules->'error_block_seconds'))-1,0))::int,300);
   insert into public.operator_blocks(operator_id,status,reason_code,blocked_until,metadata) values(v_op.id,'active','challenge_incorrect',now()+make_interval(secs=>v_seconds),jsonb_build_object('challenge_log_id',v_log.id,'error_number',v_errors));
 end if; return private.challenge_payload(v_op.id,v_log.session_id);
end $$;

create or replace function public.operator_challenge_resume_idle(p_session_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare v_op uuid; begin select id into v_op from public.operators where auth_user_id=auth.uid() and active; update public.challenge_logs set status='expired',closed_at=coalesce(closed_at,now()) where operator_id=v_op and status='idle'; return public.operator_challenge_state(jsonb_build_object('session_id',p_session_id)); end $$;

create or replace function public.operator_challenge_session_ended(p_session_id uuid)
returns void language plpgsql security definer set search_path='' as $$
declare v_op uuid; begin select id into v_op from public.operators where auth_user_id=auth.uid(); update public.challenge_logs set status='abandoned',abandoned_at=now() where operator_id=v_op and session_id=p_session_id and status in ('pending','displayed','paused'); end $$;

create or replace function private.defer_challenge_after_call()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if old.status='paused' and new.status='pending' and old.pause_reason='call_active' then
    new.status := 'scheduled';
    new.scheduled_for := now() + interval '90 seconds';
    new.expires_at := new.scheduled_for + make_interval(secs => greatest(coalesce((select duration_seconds from public.challenges where id=new.challenge_id),60),15));
  end if;
  return new;
end $$;
drop trigger if exists challenge_defer_after_call on public.challenge_logs;
create trigger challenge_defer_after_call before update on public.challenge_logs for each row execute function private.defer_challenge_after_call();

create or replace function public.admin_save_challenge_rules(p_unit_id uuid, p_rules jsonb)
returns void language plpgsql security definer set search_path='' as $$
begin perform private.require_admin_for_backend(array['superadmin','operations_manager','challenge_manager'],p_unit_id); if coalesce((p_rules->>'min_interval_seconds')::int,0)<1 or coalesce((p_rules->>'max_interval_seconds')::int,0)<coalesce((p_rules->>'min_interval_seconds')::int,0) then raise exception 'janela_invalida'; end if; update public.system_settings set active=false,updated_at=now() where key='challenge_rules' and scope_type=case when p_unit_id is null then 'global' else 'unit' end and scope_id is not distinct from p_unit_id and active; insert into public.system_settings(scope_type,scope_id,key,value) values(case when p_unit_id is null then 'global' else 'unit' end,p_unit_id,'challenge_rules',p_rules); end $$;

create or replace function public.admin_upsert_challenge(p_challenge jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare v_id uuid:=nullif(p_challenge->>'id','')::uuid; v_admin public.admin_users%rowtype; begin v_admin:=private.require_admin_for_backend(array['superadmin','operations_manager','challenge_manager'],nullif(p_challenge->>'unit_id','')::uuid); if v_id is null then insert into public.challenges(title,prompt,kind,answer_definition,duration_seconds,block_seconds,status,unit_id,created_by) values(nullif(btrim(p_challenge->>'title'),''),nullif(btrim(p_challenge->>'prompt'),''),'multiple_choice',p_challenge->'answer_definition',coalesce((p_challenge->>'duration_seconds')::int,60),0,coalesce(p_challenge->>'status','draft'),nullif(p_challenge->>'unit_id','')::uuid,v_admin.id) returning id into v_id; else update public.challenges set title=nullif(btrim(p_challenge->>'title'),''),prompt=nullif(btrim(p_challenge->>'prompt'),''),answer_definition=p_challenge->'answer_definition',duration_seconds=coalesce((p_challenge->>'duration_seconds')::int,60),status=coalesce(p_challenge->>'status',status),unit_id=nullif(p_challenge->>'unit_id','')::uuid,revision=revision+1,updated_at=now() where id=v_id; end if; return v_id; end $$;

create or replace function public.admin_set_challenge_status(p_challenge_id uuid, p_status text)
returns void language plpgsql security definer set search_path='' as $$
declare v_unit uuid; begin select unit_id into v_unit from public.challenges where id=p_challenge_id; perform private.require_admin_for_backend(array['superadmin','operations_manager','challenge_manager'],v_unit); if p_status not in ('draft','active','inactive','archived') then raise exception 'status_invalido'; end if; update public.challenges set status=p_status,active=(p_status='active'),revision=revision+1,updated_at=now() where id=p_challenge_id; end $$;

revoke all on function private.challenge_rules(uuid),private.current_operator_challenge(uuid),private.challenge_payload(uuid,uuid) from public,anon,authenticated;
revoke all on function public.operator_challenge_state(jsonb),public.operator_challenge_displayed(uuid),public.operator_challenge_answer(uuid,jsonb),public.operator_challenge_resume_idle(uuid),public.operator_challenge_session_ended(uuid),public.admin_save_challenge_rules(uuid,jsonb),public.admin_upsert_challenge(jsonb),public.admin_set_challenge_status(uuid,text) from public,anon;
grant execute on function public.operator_challenge_state(jsonb),public.operator_challenge_displayed(uuid),public.operator_challenge_answer(uuid,jsonb),public.operator_challenge_resume_idle(uuid),public.operator_challenge_session_ended(uuid),public.admin_save_challenge_rules(uuid,jsonb),public.admin_upsert_challenge(jsonb),public.admin_set_challenge_status(uuid,text) to authenticated;
