-- =====================================================================
-- ShopOps AI — core schema (Workflow 1: order intake)
-- Already run in Supabase. Kept here so the repo is complete.
-- =====================================================================

-- ========== TABLES ==========
create table customers (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  phone text unique not null,
  email text,
  telegram_chat_id bigint unique,
  created_at timestamptz default now()
);

create table orders (
  id uuid primary key default gen_random_uuid(),
  order_number text unique not null,
  customer_id uuid references customers(id),
  amount numeric(10,2) not null,
  payment_method text not null check (payment_method in ('cod','prepaid')),
  address text,
  pincode text,
  items jsonb default '[]',
  status text not null default 'new',
  risk_score int,
  risk_reasons jsonb,
  reminder_sent boolean default false,
  created_at timestamptz default now(),
  updated_at timestamptz default now()
);

create table messages (
  id bigserial primary key,
  chat_id bigint not null,
  role text not null check (role in ('user','bot')),
  text text,
  intent text,
  created_at timestamptz default now()
);

create table tickets (
  id bigserial primary key,
  order_id uuid references orders(id),
  chat_id bigint,
  type text,
  description text,
  status text default 'open',
  created_at timestamptz default now()
);

create table failed_runs (
  id bigserial primary key,
  workflow text,
  node text,
  error text,
  payload jsonb,
  retried boolean default false,
  created_at timestamptz default now()
);

-- Demo list of "high return" pincodes (sample data for testing)
create table risky_pincodes (
  pincode text primary key,
  rto_rate numeric
);
insert into risky_pincodes values ('110094', 0.38), ('400099', 0.31), ('500099', 0.29);

-- Lock tables down: only the secret server key can read/write
alter table customers enable row level security;
alter table orders enable row level security;
alter table messages enable row level security;
alter table tickets enable row level security;
alter table failed_runs enable row level security;
alter table risky_pincodes enable row level security;

-- ========== FUNCTION: save order + rule-based risk ==========
create or replace function create_order(p jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_customer_id uuid;
  v_order orders;
  v_prev_orders int;
  v_prev_cancelled int;
  v_risky_pin boolean;
  v_score int := 0;
  v_reasons text[] := '{}';
begin
  -- 1. create the customer, or update them if this phone already exists
  insert into customers (name, phone, email)
  values (p->>'name', p->>'phone', p->>'email')
  on conflict (phone) do update
    set name = excluded.name,
        email = coalesce(excluded.email, customers.email)
  returning id into v_customer_id;

  -- 2. save the order (if the same order number arrives twice, ignore it)
  insert into orders (order_number, customer_id, amount, payment_method, address, pincode, items)
  values (p->>'order_number', v_customer_id, (p->>'amount')::numeric,
          p->>'payment_method', p->>'address', p->>'pincode',
          coalesce(p->'items', '[]'::jsonb))
  on conflict (order_number) do nothing
  returning * into v_order;

  if v_order.id is null then
    select * into v_order from orders where order_number = p->>'order_number';
    return jsonb_build_object('duplicate', true, 'order', to_jsonb(v_order));
  end if;

  -- 3. look at this customer's past orders
  select count(*), count(*) filter (where status in ('cancelled','rto'))
    into v_prev_orders, v_prev_cancelled
  from orders where customer_id = v_customer_id and id <> v_order.id;

  select exists(select 1 from risky_pincodes where pincode = v_order.pincode)
    into v_risky_pin;

  -- 4. add up the risk score
  if v_prev_orders = 0 then
    v_score := v_score + 20; v_reasons := array_append(v_reasons, 'new customer');
  end if;
  if v_prev_cancelled > 0 then
    v_score := v_score + least(v_prev_cancelled * 25, 50);
    v_reasons := array_append(v_reasons, v_prev_cancelled || ' past cancelled/RTO orders');
  end if;
  if v_risky_pin then
    v_score := v_score + 30; v_reasons := array_append(v_reasons, 'high-RTO pincode');
  end if;
  if v_order.payment_method = 'cod' and v_order.amount > 3000 then
    v_score := v_score + 15; v_reasons := array_append(v_reasons, 'high-value COD');
  end if;

  return jsonb_build_object(
    'duplicate', false,
    'order', to_jsonb(v_order),
    'rule_score', v_score,
    'rule_reasons', to_jsonb(v_reasons)
  );
end;
$$;
