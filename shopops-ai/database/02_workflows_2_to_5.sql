-- =====================================================================
-- ShopOps AI — database additions for Workflows 2, 3, 4 and 5
-- Run this ONCE in Supabase → SQL Editor → New query → Run.
-- (01_schema.sql, which you already ran, must exist first.)
-- =====================================================================

-- ---------- 1. Small table changes ----------
alter table orders add column if not exists admin_notified boolean default false;
alter table orders add column if not exists decided_at timestamptz;

-- One Telegram account may be used to test several fake customers,
-- so a chat id no longer has to be unique.
alter table customers drop constraint if exists customers_telegram_chat_id_key;

-- ---------- 2. Settings (edit values here, not inside n8n) ----------
create table if not exists app_settings (
  key text primary key,
  value text not null
);
alter table app_settings enable row level security;

insert into app_settings (key, value) values
  ('bot_username', 'YOUR_BOT_USERNAME'),     -- <-- change: your bot's username, without @
  ('reminder_after_minutes', '1440'),        -- remind customer after 24 h (use 2 for demos)
  ('hold_after_minutes', '2880')             -- put order on hold after 48 h (use 4 for demos)
on conflict (key) do nothing;

-- ---------- 3. /admin command: register the store owner's chat ----------
create or replace function set_admin(p_chat_id bigint)
returns jsonb
language plpgsql
as $$
declare
  v_existing text;
begin
  select value into v_existing from app_settings where key = 'admin_chat_id';

  if v_existing is null then
    insert into app_settings (key, value) values ('admin_chat_id', p_chat_id::text);
    return jsonb_build_object('ok', true,
      'message', 'You are now the store admin. Alerts and daily reports will come to this chat.');
  elsif v_existing = p_chat_id::text then
    return jsonb_build_object('ok', true, 'message', 'You are already the store admin.');
  else
    return jsonb_build_object('ok', false, 'message', 'An admin is already registered for this store.');
  end if;
end;
$$;

-- ---------- 4. Customer opens t.me/<bot>?start=ORDER ----------
-- Links this Telegram chat to the order's customer and says what to show.
create or replace function start_confirmation(p_order_number text, p_chat_id bigint)
returns jsonb
language plpgsql
as $$
declare
  v_order orders;
  v_customer customers;
begin
  select * into v_order from orders where upper(order_number) = upper(p_order_number);
  if v_order.id is null then
    return jsonb_build_object('found', false, 'ask', false,
      'text', 'Sorry, I could not find order ' || p_order_number || '. Please check the link.');
  end if;

  select * into v_customer from customers where id = v_order.customer_id;

  -- move this chat to the right customer
  update customers set telegram_chat_id = null
    where telegram_chat_id = p_chat_id and id <> v_customer.id;
  update customers set telegram_chat_id = p_chat_id where id = v_customer.id;

  if v_order.status in ('pending_confirmation', 'on_hold') then
    return jsonb_build_object('found', true, 'ask', true, 'order_number', v_order.order_number,
      'text', 'Hi ' || v_customer.name || '! Please confirm your cash-on-delivery order '
              || v_order.order_number || ' for Rs ' || v_order.amount
              || ', to be delivered to: ' || coalesce(v_order.address, '') || ' - ' || coalesce(v_order.pincode, '') || '.');
  end if;

  return jsonb_build_object('found', true, 'ask', false, 'order_number', v_order.order_number,
    'text', 'Hi ' || v_customer.name || '! Your order ' || v_order.order_number || ' is currently: '
            || replace(v_order.status, '_', ' ') || '. You can ask me anything about it here.');
end;
$$;

-- ---------- 5. Customer presses Confirm / Cancel ----------
-- Only works for the customer linked to that order. Safe to press twice.
create or replace function decide_order(p_order_number text, p_chat_id bigint, p_action text)
returns jsonb
language plpgsql
as $$
declare
  v_order orders;
  v_new text;
begin
  select o.* into v_order
  from orders o join customers c on c.id = o.customer_id
  where upper(o.order_number) = upper(p_order_number)
    and c.telegram_chat_id = p_chat_id;

  if v_order.id is null then
    return jsonb_build_object('ok', false, 'changed', false,
      'text', 'This order is not linked to your chat. Please open the link from your order message.');
  end if;

  if v_order.status not in ('pending_confirmation', 'on_hold') then
    return jsonb_build_object('ok', true, 'changed', false, 'order_number', v_order.order_number,
      'status', v_order.status,
      'text', 'Order ' || v_order.order_number || ' is already ' || replace(v_order.status, '_', ' ') || '.');
  end if;

  v_new := case when p_action = 'confirm' then 'confirmed' else 'cancelled' end;

  update orders set status = v_new, decided_at = now(), updated_at = now()
  where id = v_order.id;

  return jsonb_build_object('ok', true, 'changed', true, 'order_number', v_order.order_number,
    'status', v_new,
    'text', case when v_new = 'confirmed'
                 then 'Thank you! Order ' || v_order.order_number || ' is confirmed and will be shipped soon.'
                 else 'Order ' || v_order.order_number || ' has been cancelled. Nothing will be delivered or charged.'
            end);
end;
$$;

-- ---------- 6. Support bot: everything the AI needs to answer ----------
create or replace function support_context(p_chat_id bigint)
returns jsonb
language sql
as $$
  select jsonb_build_object(
    'customer', (select jsonb_build_object('name', name)
                 from customers where telegram_chat_id = p_chat_id limit 1),
    'orders', coalesce((
        select jsonb_agg(x) from (
          select o.order_number, o.status, o.amount, o.payment_method,
                 (o.created_at at time zone 'Asia/Kolkata')::date as ordered_on
          from orders o join customers c on c.id = o.customer_id
          where c.telegram_chat_id = p_chat_id
          order by o.created_at desc
          limit 5
        ) x), '[]'::jsonb),
    'history', coalesce((
        select jsonb_agg(h order by h.created_at) from (
          select role, text, created_at
          from messages where chat_id = p_chat_id
          order by created_at desc
          limit 6
        ) h), '[]'::jsonb)
  );
$$;

-- ---------- 7. Support bot: save the conversation (+ ticket if needed) ----------
create or replace function save_support_turn(p jsonb)
returns jsonb
language plpgsql
as $$
declare
  v_chat bigint := (p->>'chat_id')::bigint;
  v_ticket_id bigint;
  v_order_id uuid;
begin
  insert into messages (chat_id, role, text, intent) values
    (v_chat, 'user', p->>'user_text', p->>'intent'),
    (v_chat, 'bot',  p->>'reply',     p->>'intent');

  if p->>'intent' in ('return_request', 'complaint') then
    -- attach the ticket to the order only if that order belongs to this chat
    select o.id into v_order_id
    from orders o join customers c on c.id = o.customer_id
    where upper(o.order_number) = upper(coalesce(p->>'order_number', ''))
      and c.telegram_chat_id = v_chat;

    insert into tickets (order_id, chat_id, type, description)
    values (v_order_id, v_chat, p->>'intent', p->>'user_text')
    returning id into v_ticket_id;
  end if;

  return jsonb_build_object(
    'ticket_id', v_ticket_id,
    'admin_chat_id', (select value from app_settings where key = 'admin_chat_id'));
end;
$$;

-- ---------- 8. Follow-ups: what needs a message right now? ----------
-- Marks each task as done in the same step, so two runs never send it twice.
create or replace function followup_tasks()
returns jsonb
language plpgsql
as $$
declare
  v_admin  text := (select value from app_settings where key = 'admin_chat_id');
  v_bot    text := (select value from app_settings where key = 'bot_username');
  v_remind int  := coalesce((select value::int from app_settings where key = 'reminder_after_minutes'), 1440);
  v_hold   int  := coalesce((select value::int from app_settings where key = 'hold_after_minutes'), 2880);
  v_tasks  jsonb := '[]'::jsonb;
  r record;
begin
  -- a) tell the admin about each new order that needs confirmation
  if v_admin is not null then
    for r in
      update orders set admin_notified = true
      where status = 'pending_confirmation' and admin_notified = false
      returning order_number, amount, risk_score,
        (select string_agg(value, ', ') from jsonb_array_elements_text(coalesce(risk_reasons, '[]'::jsonb))) as reasons
    loop
      v_tasks := v_tasks || jsonb_build_object(
        'kind', 'notify_admin', 'chat_id', v_admin, 'buttons', false, 'order_number', r.order_number,
        'text', 'New risky COD order ' || r.order_number || ' (Rs ' || r.amount || ', risk '
                || coalesce(r.risk_score, 0) || '/100)' || chr(10)
                || 'Why: ' || coalesce(r.reasons, 'n/a') || chr(10)
                || 'Send the customer this confirmation link: https://t.me/' || v_bot || '?start=' || r.order_number);
    end loop;
  end if;

  -- b) one reminder to customers who opened the link but did not answer
  for r in
    update orders o set reminder_sent = true
    from customers c
    where c.id = o.customer_id
      and o.status = 'pending_confirmation'
      and o.reminder_sent = false
      and c.telegram_chat_id is not null
      and o.created_at < now() - make_interval(mins => v_remind)
    returning o.order_number, o.amount, c.telegram_chat_id
  loop
    v_tasks := v_tasks || jsonb_build_object(
      'kind', 'remind_customer', 'chat_id', r.telegram_chat_id::text, 'buttons', true, 'order_number', r.order_number,
      'text', 'Reminder: your order ' || r.order_number || ' (Rs ' || r.amount
              || ') is waiting for your confirmation. It will be put on hold if not confirmed.');
  end loop;

  -- c) still no answer: put the order on hold and tell the admin
  for r in
    update orders set status = 'on_hold', updated_at = now()
    where status = 'pending_confirmation'
      and created_at < now() - make_interval(mins => v_hold)
    returning order_number, amount
  loop
    if v_admin is not null then
      v_tasks := v_tasks || jsonb_build_object(
        'kind', 'hold', 'chat_id', v_admin, 'buttons', false, 'order_number', r.order_number,
        'text', 'Order ' || r.order_number || ' (Rs ' || r.amount
                || ') was not confirmed in time and is now ON HOLD. Do not ship it yet.');
    end if;
  end loop;

  return jsonb_build_object('tasks', v_tasks);
end;
$$;

-- ---------- 9. Daily report numbers (India time) ----------
create or replace function daily_report()
returns jsonb
language sql
as $$
  with t as (
    select (date_trunc('day', now() at time zone 'Asia/Kolkata') at time zone 'Asia/Kolkata') as since
  ),
  o as (
    select orders.* from orders, t where orders.created_at >= t.since
  )
  select jsonb_build_object(
    'admin_chat_id',        (select value from app_settings where key = 'admin_chat_id'),
    'date',                 to_char(now() at time zone 'Asia/Kolkata', 'DD Mon YYYY'),
    'orders',               (select count(*) from o),
    'confirmed',            (select count(*) from o where status = 'confirmed'),
    'revenue_confirmed',    (select coalesce(sum(amount), 0) from o where status = 'confirmed'),
    'pending_confirmation', (select count(*) from o where status = 'pending_confirmation'),
    'cancelled',            (select count(*) from o where status = 'cancelled'),
    'on_hold',              (select count(*) from o where status = 'on_hold'),
    'cod_value_stopped',    (select coalesce(sum(amount), 0) from o
                             where payment_method = 'cod' and status in ('cancelled', 'on_hold')),
    'open_tickets',         (select count(*) from tickets where status = 'open'),
    'failed_runs_today',    (select count(*) from failed_runs, t where failed_runs.created_at >= t.since)
  );
$$;

-- ---------- 10. Error handler: log a failure ----------
create or replace function log_failure(p jsonb)
returns jsonb
language plpgsql
as $$
begin
  insert into failed_runs (workflow, node, error, payload)
  values (p->>'workflow', p->>'node', p->>'error', p->'payload');
  return jsonb_build_object('admin_chat_id', (select value from app_settings where key = 'admin_chat_id'));
end;
$$;

-- ---------- 11. Lock functions down ----------
-- Only your secret server key (used by n8n) may call these functions.
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;

-- make the API see the new functions immediately
notify pgrst, 'reload schema';
