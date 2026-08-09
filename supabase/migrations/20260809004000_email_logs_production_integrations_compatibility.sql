alter table public.email_logs
  add column if not exists entity_type text,
  add column if not exists entity_id uuid,
  add column if not exists sent_at timestamptz,
  add column if not exists provider_response jsonb not null default '{}'::jsonb;
