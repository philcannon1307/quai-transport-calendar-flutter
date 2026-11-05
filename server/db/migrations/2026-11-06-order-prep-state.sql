begin;
-- Order prepared state ("À préparer" / "Préparé"): one shared flag per order + service date, with a 90-day history.
-- The server also creates these tables on first use (create table if not exists); this file is the same DDL for review
-- or for running by hand. Idempotent.
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

-- Rollback (manual, only if the feature is withdrawn; this deletes the prepared flags and their history):
--   drop table if exists order_prep_history;
--   drop table if exists order_prep_state;
