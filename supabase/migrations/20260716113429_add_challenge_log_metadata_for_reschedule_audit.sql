-- Production predates the local baseline column used to audit challenge
-- reschedules. Add it without changing existing challenge lifecycle data.

alter table public.challenge_logs
  add column if not exists metadata jsonb not null default '{}'::jsonb;

comment on column public.challenge_logs.metadata is
  'Server-side challenge lifecycle metadata, including rule-change reschedule audit fields.';
