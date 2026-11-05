begin;
-- Order change notice: change history overlay + division mailboxes.
create table if not exists order_changes (
  id                    uuid primary key default gen_random_uuid(),
  change_id             uuid not null,
  order_num             text not null,
  order_kind            text not null check (order_kind in ('SO','TO')),
  field                 text not null,
  old_value             text not null default '',
  new_value             text not null default '',
  reason                text not null default '',
  changed_by            text not null,
  changed_at            timestamptz not null default now(),
  request_hash          text not null,
  context               jsonb not null default '{}'::jsonb,
  notified_recipients   jsonb not null default '{}'::jsonb,
  email_status          text not null default 'pending'
);
create index if not exists order_changes_order_idx on order_changes (order_num, changed_at desc);
create index if not exists order_changes_change_idx on order_changes (change_id);
create index if not exists order_changes_hash_idx on order_changes (order_num, request_hash, changed_at desc);

create table if not exists division_contacts (
  division           text primary key,
  emails             text[] not null,
  location_keywords  text[] not null default '{}',
  updated_by         text,
  updated_at         timestamptz not null default now()
);
commit;

-- Rollback (manual, only if the feature is withdrawn; this deletes the change history):
--   drop table if exists order_changes;
--   drop table if exists division_contacts;
-- Needs PostgreSQL 13+ (gen_random_uuid) or the pgcrypto extension. Run this migration BEFORE deploying the code.
