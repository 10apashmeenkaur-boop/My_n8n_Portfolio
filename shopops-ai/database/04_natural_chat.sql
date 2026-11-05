-- =====================================================================
-- ShopOps AI — natural-language customer chat (v2)
-- Run ONCE in Supabase → SQL Editor → New query → Run.
-- Needs 01, 02 and 03 SQL files to have been run first.
--
-- Adds:
--   * link_by_phone: customer shares their phone in Telegram → we find
--     their orders (no /start codes, no links needed)
--   * support_context v2: tells the AI whether the chat is linked, which
--     orders are waiting for confirmation, and the store's policies
--   * store_info setting: delivery / returns / payment info the AI can use
-- =====================================================================

-- ---------- Store information the AI is allowed to use ----------
-- Edit this text any time (Table Editor → app_settings → store_info).
insert into app_settings (key, value) values ('store_info',
'Store: ShopOps Demo Store (online fashion and footwear store in India).
Delivery: orders are shipped within 1-2 business days after confirmation. Delivery usually takes 3-7 business days depending on the city. Tracking details are shared by message once the order ships.
Payment: Cash on Delivery and online payment (UPI, cards). Cash on Delivery orders must be confirmed before they are shipped.
Cancellation: orders can be cancelled free of charge any time before they ship.
Returns: unused items in original packaging can be returned within 7 days of delivery. Refunds are processed within 5-7 business days after the return is picked up.
Support hours: Monday to Saturday, 10 AM to 7 PM. A team member replies to tickets within 24 hours.')
on conflict (key) do nothing;

-- ---------- Customer shares their phone number ----------
-- p_verified must be true only when the shared contact belongs to the
-- sender (checked in n8n: contact.user_id = from.id), so nobody can
-- claim someone else's orders by sharing another person's number.
create or replace function link_by_phone(p_chat_id bigint, p_phone text, p_verified boolean)
returns jsonb
language plpgsql
as $$
declare
  v_phone text := right(regexp_replace(coalesce(p_phone, ''), '\D', '', 'g'), 10);
  v_customer customers;
  v_order_number text;
begin
  if not coalesce(p_verified, false) then
    return jsonb_build_object('found', false, 'ask', false,
      'text', 'For your security, please tap the 📱 button below to share *your own* phone number.');
  end if;

  select * into v_customer from customers where phone = v_phone;

  if v_customer.id is null then
    return jsonb_build_object('found', false, 'ask', false,
      'text', 'Sorry, I couldn''t find any orders for this phone number. 🙁' || chr(10) || chr(10) ||
              'If you ordered with a different number, please contact the store and we''ll help.');
  end if;

  -- link this Telegram chat to the customer
  update customers set telegram_chat_id = null
    where telegram_chat_id = p_chat_id and id <> v_customer.id;
  update customers set telegram_chat_id = p_chat_id where id = v_customer.id;

  -- prefer an order waiting for confirmation, otherwise the latest order
  select order_number into v_order_number from orders
  where customer_id = v_customer.id
  order by (status in ('pending_confirmation', 'on_hold')) desc, created_at desc
  limit 1;

  if v_order_number is null then
    return jsonb_build_object('found', true, 'ask', false,
      'text', 'Hi ' || md(first_name(v_customer.name)) || '! 👋 I found your account, but there are no orders yet.' ||
              chr(10) || chr(10) || 'Ask me anything about the store.');
  end if;

  -- reuse the same friendly message + buttons as the order link
  return start_confirmation(v_order_number, p_chat_id) || jsonb_build_object('found', true);
end;
$$;

-- ---------- Everything the AI needs to answer one customer ----------
create or replace function support_context(p_chat_id bigint)
returns jsonb
language sql
as $$
  with c as (
    select * from customers where telegram_chat_id = p_chat_id limit 1
  )
  select jsonb_build_object(
    'linked', exists(select 1 from c),
    'customer', (select jsonb_build_object('name', first_name(name)) from c),
    'orders', coalesce((
        select jsonb_agg(x) from (
          select o.order_number, o.status, o.amount,
                 case when o.payment_method = 'cod' then 'Cash on Delivery' else 'Paid online' end as payment,
                 (o.created_at at time zone 'Asia/Kolkata')::date as ordered_on
          from orders o join c on c.id = o.customer_id
          order by o.created_at desc
          limit 5
        ) x), '[]'::jsonb),
    'pending', coalesce((
        select jsonb_agg(x) from (
          select o.order_number, o.amount
          from orders o join c on c.id = o.customer_id
          where o.status in ('pending_confirmation', 'on_hold')
          order by o.created_at desc
        ) x), '[]'::jsonb),
    'history', coalesce((
        select jsonb_agg(h order by h.created_at) from (
          select role, text, created_at
          from messages where chat_id = p_chat_id
          order by created_at desc
          limit 10
        ) h), '[]'::jsonb),
    'store_info', (select value from app_settings where key = 'store_info')
  );
$$;

-- ---------- Lock down + refresh ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;
notify pgrst, 'reload schema';
