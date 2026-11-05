-- Quai data schema for an owner-owned Postgres (Railway). Idempotent: safe to run twice.
-- Replaces the Lovable Cloud / Supabase project. No RLS, no roles, no extensions: the only client of
-- this database is the exchange server, which checks the session token before every query.
-- Run with:  psql "$DATABASE_URL" -f db/schema.sql      (or: npm run db:schema)

begin;

create table if not exists announcements (
  id          uuid primary key default gen_random_uuid(),
  title       text not null default '',
  body        text not null default '',
  title_fr    text,
  body_fr     text,
  is_active   boolean not null default true,
  created_at  timestamptz not null default now(),
  updated_at  timestamptz not null default now()
);

create table if not exists announcement_images (
  id               uuid primary key default gen_random_uuid(),
  announcement_id  uuid not null references announcements(id) on delete cascade,
  storage_url      text not null,
  created_at       timestamptz not null default now()
);
create index if not exists announcement_images_announcement_idx on announcement_images (announcement_id);

-- Kept for the import of old rows; the Flutter app does not use it.
create table if not exists order_photos (
  id            uuid primary key default gen_random_uuid(),
  so_num        text not null,
  storage_path  text not null,
  uploaded_by   text not null default '',
  created_at    timestamptz not null default now()
);

create table if not exists receipts (
  id            uuid primary key default gen_random_uuid(),
  created_at    timestamptz not null default now(),
  driver_name   text not null default '',
  carrier_name  text not null default '',
  note          text not null default '',
  storage_path  text not null,
  public_url    text not null,
  email_sent    boolean not null default false
);

create table if not exists order_adjustments (
  id                 uuid primary key default gen_random_uuid(),
  created_at         timestamptz not null default now(),
  order_num          text not null,
  order_kind         text not null default 'SO',
  carrier_name       text not null default '',
  reporter_name      text not null default '',
  items              jsonb not null default '[]'::jsonb,
  note               text not null default '',
  photo_url          text,
  transfer_locations jsonb,
  email_sent         boolean not null default false
);

create table if not exists delivery_history (
  so_num                 text primary key,
  so_id                  bigint,
  customer               text,
  service_type           text,
  service_type_id        bigint,
  status                 text,
  event_status           text,
  ship_date              date,
  event_start_date       date,
  city                   text,
  state                  text,
  shipping_location_id   bigint,
  shipping_location_name text,
  sale_location_id       bigint,
  sale_location_name     text,
  truck_id               bigint,
  truck_name             text,
  service_event_id       bigint,
  service_event_name     text,
  carrier_id             bigint,
  carrier_name           text,
  source                 text not null default 'app',
  created_at             timestamptz not null default now(),
  updated_at             timestamptz not null default now()
);
create index if not exists delivery_history_ship_date_idx on delivery_history (ship_date desc);
create index if not exists delivery_history_carrier_idx on delivery_history (carrier_name);

-- Uploaded pictures (receipts, BOL, change-report photos, announcement images). Small volume
-- (<= 8 MB each), so they live in Postgres: one backup covers everything, no extra storage service.
create table if not exists files (
  bucket        text not null,
  path          text not null,
  content_type  text not null,
  bytes         bytea not null,
  created_at    timestamptz not null default now(),
  primary key (bucket, path)
);

-- Email bookkeeping (replaces email_send_log, suppressed_emails, email_unsubscribe_tokens, pgmq).
create table if not exists email_send_log (
  id               uuid primary key default gen_random_uuid(),
  message_id       uuid not null,
  template_name    text not null,
  recipient_email  text not null,
  status           text not null check (status in ('pending','sent','failed','suppressed')),
  error_message    text,
  metadata         jsonb not null default '{}'::jsonb,
  created_at       timestamptz not null default now()
);
create index if not exists email_send_log_carrier_idx on email_send_log ((metadata->>'carrier'), created_at desc);
create index if not exists email_send_log_key_idx on email_send_log ((metadata->>'idempotency_key'));

create table if not exists suppressed_emails (
  email       text primary key,
  reason      text not null default 'unsubscribe',
  created_at  timestamptz not null default now()
);

create table if not exists email_unsubscribe_tokens (
  email       text primary key,
  token       text not null unique,
  used_at     timestamptz,
  created_at  timestamptz not null default now()
);

-- Who uploaded a picture (an email without a log row may only reference the caller's own uploads).
alter table files add column if not exists uploaded_by text;

-- Atomic idempotency: one pending/sent send per key (failed/suppressed rows may be retried).
create unique index if not exists email_send_log_key_uq on email_send_log ((metadata->>'idempotency_key')) where status in ('pending','sent');

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

-- Order prepared state: shared "Préparé" flag per order + service date, and its history (pruned after 90 days).
create table if not exists order_prep_state (
  order_num      text not null,
  service_date   text not null default '' check (service_date = '' or service_date ~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$'),
  prepared       boolean not null,
  updated_by     text not null default '',
  updated_label  text not null default '',
  updated_at     timestamptz not null default now(),
  primary key (order_num, service_date)
);
create index if not exists order_prep_state_date_idx on order_prep_state (service_date);

create table if not exists order_prep_history (
  id            bigserial primary key,
  order_num     text not null,
  service_date  text not null default '',
  prepared      boolean not null,
  actor         text not null,
  label         text not null default '',
  at            timestamptz not null default now()
);
create index if not exists order_prep_history_order_idx on order_prep_history (order_num, at desc);

commit;
