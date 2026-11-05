-- =====================================================================
-- ShopOps AI — friendly Telegram messages
-- Run ONCE in Supabase → SQL Editor → New query → Run.
--
-- Rewrites every message the bot sends so it reads like a real store,
-- and fixes the confirmation link (Telegram was eating the "_" in the
-- bot username). Function names and inputs are unchanged, so the n8n
-- workflows keep working without any edits.
-- =====================================================================

-- ---------- Helpers ----------

-- Escape characters Telegram's Markdown treats as formatting
create or replace function md(t text)
returns text language sql immutable as $$
  select replace(replace(replace(replace(coalesce(t, ''),
         '\', '\\'), '_', '\_'), '*', '\*'), '`', '\`');
$$;

-- 5200.00 -> ₹5,200
create or replace function inr(a numeric)
returns text language sql immutable as $$
  select '₹' || trim(to_char(round(coalesce(a, 0)), 'FM999,999,999,990'));
$$;

-- "asdf qwerty" -> "Asdf"
create or replace function first_name(n text)
returns text language sql immutable as $$
  select coalesce(nullif(initcap(split_part(trim(coalesce(n, '')), ' ', 1)), ''), 'there');
$$;

-- order status in plain words for customers
create or replace function status_words(s text)
returns text language sql immutable as $$
  select case s
    when 'confirmed'            then 'confirmed ✅ and being packed'
    when 'cancelled'            then 'cancelled'
    when 'pending_confirmation' then 'waiting for your confirmation'
    when 'on_hold'              then 'on hold, because it wasn''t confirmed in time'
    when 'new'                  then 'received and being checked'
    else replace(coalesce(s, 'being processed'), '_', ' ')
  end;
$$;

-- risk reasons in plain words for the store owner
create or replace function reason_words(r jsonb)
returns text language sql immutable as $$
  select coalesce(string_agg(
    case
      when x = 'new customer'      then 'first-time customer'
      when x = 'high-RTO pincode'  then 'pincode with many returned parcels'
      when x = 'high-value COD'    then 'large cash-on-delivery amount'
      when x like 'AI: %'          then 'AI flagged: ' || lower(substr(x, 5, 1)) || substr(x, 6)
      else x
    end, ', '), 'no specific reason') from jsonb_array_elements_text(coalesce(r, '[]'::jsonb)) x;
$$;

-- ---------- /admin ----------
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
    return jsonb_build_object('ok', true, 'message',
      '✅ *You''re set up as the store owner.*' || chr(10) || chr(10) ||
      'You''ll get new order alerts, support tickets and the daily report right here.');
  elsif v_existing = p_chat_id::text then
    return jsonb_build_object('ok', true, 'message',
      '👍 You''re already set up as the store owner. Alerts will keep coming here.');
  else
    return jsonb_build_object('ok', false, 'message',
      'Sorry, this store already has an owner set up.');
  end if;
end;
$$;

-- ---------- Customer opens the confirmation link ----------
create or replace function start_confirmation(p_order_number text, p_chat_id bigint)
returns jsonb
language plpgsql
as $$
declare
  v_order orders;
  v_customer customers;
  v_pay text;
begin
  select * into v_order from orders where upper(order_number) = upper(p_order_number);
  if v_order.id is null then
    return jsonb_build_object('found', false, 'ask', false,
      'text', 'Sorry, I couldn''t find order ' || md(p_order_number) || '. 🙁' || chr(10) || chr(10) ||
              'Please open the link from your order message again, or just type your question here and our team will help.');
  end if;

  select * into v_customer from customers where id = v_order.customer_id;

  -- link this Telegram chat to the order's customer
  update customers set telegram_chat_id = null
    where telegram_chat_id = p_chat_id and id <> v_customer.id;
  update customers set telegram_chat_id = p_chat_id where id = v_customer.id;

  v_pay := case when v_order.payment_method = 'cod' then 'Cash on Delivery' else 'Paid online' end;

  if v_order.status in ('pending_confirmation', 'on_hold') then
    return jsonb_build_object('found', true, 'ask', true, 'order_number', v_order.order_number,
      'text',
        'Hi ' || md(first_name(v_customer.name)) || '! 👋 Thanks for shopping with us.' || chr(10) || chr(10) ||
        'Please confirm your order so we can ship it:' || chr(10) || chr(10) ||
        '🧾 *Order:* ' || md(v_order.order_number) || chr(10) ||
        '💰 *Amount:* ' || inr(v_order.amount) || ' (' || v_pay || ')' || chr(10) ||
        '📍 *Deliver to:* ' || md(coalesce(v_order.address, '')) ||
          case when v_order.pincode is not null then ', ' || md(v_order.pincode) else '' end ||
        chr(10) || chr(10) || 'Tap a button below 👇');
  end if;

  return jsonb_build_object('found', true, 'ask', false, 'order_number', v_order.order_number,
    'text',
      'Hi ' || md(first_name(v_customer.name)) || '! 👋' || chr(10) || chr(10) ||
      'Your order ' || md(v_order.order_number) || ' is ' || status_words(v_order.status) || '.' || chr(10) || chr(10) ||
      'Have a question? Just type it here and I''ll help.');
end;
$$;

-- ---------- Customer taps Confirm / Cancel ----------
create or replace function decide_order(p_order_number text, p_chat_id bigint, p_action text)
returns jsonb
language plpgsql
as $$
declare
  v_order orders;
  v_name text;
  v_new text;
begin
  select o.* into v_order
  from orders o join customers c on c.id = o.customer_id
  where upper(o.order_number) = upper(p_order_number)
    and c.telegram_chat_id = p_chat_id;

  if v_order.id is null then
    return jsonb_build_object('ok', false, 'changed', false,
      'text', 'Sorry, I couldn''t match this order to your chat. Please open the confirmation link from your order message again.');
  end if;

  select first_name(name) into v_name from customers where id = v_order.customer_id;

  if v_order.status not in ('pending_confirmation', 'on_hold') then
    return jsonb_build_object('ok', true, 'changed', false, 'order_number', v_order.order_number,
      'status', v_order.status,
      'text', 'Your order ' || md(v_order.order_number) || ' is already ' || status_words(v_order.status) || '. Nothing else to do! 😊');
  end if;

  v_new := case when p_action = 'confirm' then 'confirmed' else 'cancelled' end;

  update orders set status = v_new, decided_at = now(), updated_at = now()
  where id = v_order.id;

  return jsonb_build_object('ok', true, 'changed', true, 'order_number', v_order.order_number,
    'status', v_new,
    'text', case when v_new = 'confirmed'
      then '✅ *Thank you, ' || md(v_name) || '!* Your order ' || md(v_order.order_number) ||
           ' is confirmed.' || chr(10) || chr(10) ||
           'We''re packing it now and will send you an update when it ships. 📦'
      else 'Your order ' || md(v_order.order_number) || ' has been cancelled. You won''t be charged anything.' ||
           chr(10) || chr(10) || 'If this was a mistake, just reply here and we''ll help. 🙏'
    end);
end;
$$;

-- ---------- Follow-ups (owner alerts, reminders, holds) ----------
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
  -- a) tell the owner about each new order that needs confirmation
  if v_admin is not null then
    for r in
      update orders set admin_notified = true
      where status = 'pending_confirmation' and admin_notified = false
      returning order_number, amount, payment_method, risk_score, risk_reasons
    loop
      v_tasks := v_tasks || jsonb_build_object(
        'kind', 'notify_admin', 'chat_id', v_admin, 'buttons', false, 'order_number', r.order_number,
        'text',
          '🔔 *New order needs confirmation*' || chr(10) || chr(10) ||
          '🧾 Order: ' || md(r.order_number) || chr(10) ||
          '💰 Amount: ' || inr(r.amount) || ' (' ||
            case when r.payment_method = 'cod' then 'Cash on Delivery' else 'Paid online' end || ')' || chr(10) ||
          '⚠️ Risk: ' || coalesce(r.risk_score, 0) || '/100' || chr(10) ||
          '📝 Why: ' || md(reason_words(r.risk_reasons)) || chr(10) || chr(10) ||
          'Send this link to the customer so they can confirm:' || chr(10) ||
          md('https://t.me/' || v_bot || '?start=' || r.order_number));
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
    returning o.order_number, o.amount, c.telegram_chat_id, c.name
  loop
    v_tasks := v_tasks || jsonb_build_object(
      'kind', 'remind_customer', 'chat_id', r.telegram_chat_id::text, 'buttons', true, 'order_number', r.order_number,
      'text',
        '⏰ Hi ' || md(first_name(r.name)) || ', just a friendly reminder!' || chr(10) || chr(10) ||
        'Your order ' || md(r.order_number) || ' (' || inr(r.amount) || ') is waiting for your confirmation. ' ||
        'Please tap a button below so we can ship it.');
  end loop;

  -- c) still no answer: put the order on hold and tell the owner
  for r in
    update orders set status = 'on_hold', updated_at = now()
    where status = 'pending_confirmation'
      and created_at < now() - make_interval(mins => v_hold)
    returning order_number, amount
  loop
    if v_admin is not null then
      v_tasks := v_tasks || jsonb_build_object(
        'kind', 'hold', 'chat_id', v_admin, 'buttons', false, 'order_number', r.order_number,
        'text',
          '⏸ *Order on hold*' || chr(10) || chr(10) ||
          'Order ' || md(r.order_number) || ' (' || inr(r.amount) || ') wasn''t confirmed in time.' || chr(10) ||
          'Please don''t ship it yet.');
    end if;
  end loop;

  return jsonb_build_object('tasks', v_tasks);
end;
$$;

-- ---------- Lock down + refresh ----------
revoke execute on all functions in schema public from public, anon, authenticated;
grant execute on all functions in schema public to service_role;
notify pgrst, 'reload schema';
