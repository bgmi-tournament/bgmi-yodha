-- BGMI YODHA: final browser-access permissions for Supabase Data API
-- Safe to run after the tables/RLS already exist.

-- Table privileges for the website's authenticated users.
grant select on public.matches to anon, authenticated;
grant select, insert, update on public.profiles to authenticated;
grant select, insert on public.entries to authenticated;
grant select on public.rooms to authenticated;
grant select on public.wallets to authenticated;
grant select on public.wallet_transactions to authenticated;
grant select, insert on public.withdrawals to authenticated;
grant select on public.notifications to authenticated;

-- Admin privileges used by the BGMI YODHA admin panel.
grant all on public.entries to authenticated;
grant all on public.rooms to authenticated;
grant all on public.wallets to authenticated;
grant all on public.wallet_transactions to authenticated;
grant all on public.withdrawals to authenticated;
grant all on public.notifications to authenticated;

-- Identity columns need sequence access for inserts.
grant usage, select on all sequences in schema public to authenticated;

-- Allow a newly authenticated user to create only their own profile/wallet row.
-- The id=user check prevents creating rows for another user.
do $$
begin
  if not exists (select 1 from pg_policies where schemaname='public' and tablename='profiles' and policyname='Users can insert own profile') then
    create policy "Users can insert own profile"
    on public.profiles for insert to authenticated
    with check (id = auth.uid());
  end if;

  if not exists (select 1 from pg_policies where schemaname='public' and tablename='wallets' and policyname='Users can create own wallet') then
    create policy "Users can create own wallet"
    on public.wallets for insert to authenticated
    with check (user_id = auth.uid());
  end if;
end $$;

-- ===== BGMI YODHA FINAL SAFETY RPCs =====
-- These functions make slot assignment, winnings and withdrawals safer than client-side balance math.

alter table public.wallet_transactions
  add column if not exists reference_id bigint;

create unique index if not exists wallet_transactions_unique_reference
on public.wallet_transactions(user_id, type, reference_id)
where reference_id is not null;

create or replace function public.admin_verify_entry(p_entry_id bigint)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  e public.entries%rowtype;
  m public.matches%rowtype;
  next_slot integer;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  select * into e from public.entries where id=p_entry_id for update;
  if not found then raise exception 'Entry not found'; end if;
  if e.payment_status='verified' then
    return json_build_object('slot_number',e.slot_number,'status','verified');
  end if;
  select * into m from public.matches where id=e.match_id for update;
  if not found then raise exception 'Match not found'; end if;
  if (select count(*) from public.entries where match_id=e.match_id and payment_status='verified') >= m.slots then
    raise exception 'Match is full';
  end if;
  select coalesce(max(slot_number),0)+1 into next_slot
  from public.entries where match_id=e.match_id and payment_status='verified';
  update public.entries
    set payment_status='verified',slot_number=next_slot,verified_at=now()
    where id=p_entry_id;
  insert into public.notifications(user_id,title,message)
    values(e.user_id,'Tournament Entry Verified',format('Match %s entry verified. Your slot is %s.',m.match_number,next_slot));
  return json_build_object('slot_number',next_slot,'status','verified');
end;
$$;

grant execute on function public.admin_verify_entry(bigint) to authenticated;

create or replace function public.admin_credit_winning(p_entry_id bigint, p_amount numeric)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  e public.entries%rowtype;
  current_balance numeric;
  tx_id bigint;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  if p_amount <= 0 then raise exception 'Winning amount must be greater than zero'; end if;
  select * into e from public.entries where id=p_entry_id;
  if not found then raise exception 'Entry not found'; end if;
  if e.payment_status <> 'verified' then raise exception 'Entry must be verified first'; end if;
  if exists(select 1 from public.wallet_transactions where user_id=e.user_id and type='win' and reference_id=p_entry_id) then
    raise exception 'Winning for this entry is already credited';
  end if;
  select balance into current_balance from public.wallets where user_id=e.user_id for update;
  if current_balance is null then
    insert into public.wallets(user_id,balance) values(e.user_id,p_amount)
    on conflict(user_id) do update set balance=public.wallets.balance+p_amount,updated_at=now();
  else
    update public.wallets set balance=current_balance+p_amount,updated_at=now() where user_id=e.user_id;
  end if;
  insert into public.wallet_transactions(user_id,type,amount,description,reference_id)
    values(e.user_id,'win',p_amount,format('Match %s winnings',e.match_id),p_entry_id)
    returning id into tx_id;
  insert into public.notifications(user_id,title,message)
    values(e.user_id,'Winnings Credited',format('₹%s winnings credited to your wallet.',to_char(p_amount,'FM999999990.00')));
  return json_build_object('transaction_id',tx_id,'amount',p_amount);
end;
$$;

grant execute on function public.admin_credit_winning(bigint,numeric) to authenticated;

create or replace function public.request_withdrawal(p_amount numeric, p_upi_id text)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  uid uuid := auth.uid();
  bal numeric;
  pending numeric;
  wid bigint;
begin
  if uid is null then raise exception 'Login required'; end if;
  if p_amount < 30 then raise exception 'Minimum withdrawal is ₹30'; end if;
  if coalesce(trim(p_upi_id),'')='' then raise exception 'UPI ID is required'; end if;
  select balance into bal from public.wallets where user_id=uid for update;
  if bal is null then bal:=0; end if;
  select coalesce(sum(amount),0) into pending from public.withdrawals where user_id=uid and status='pending';
  if bal - pending < p_amount then raise exception 'Insufficient available winnings balance'; end if;
  insert into public.withdrawals(user_id,amount,upi_id,status)
    values(uid,p_amount,trim(p_upi_id),'pending') returning id into wid;
  insert into public.notifications(user_id,title,message)
    values(uid,'Withdrawal Request Submitted',format('₹%s withdrawal request received.',to_char(p_amount,'FM999999990.00')));
  return json_build_object('withdrawal_id',wid,'status','pending');
end;
$$;

grant execute on function public.request_withdrawal(numeric,text) to authenticated;

create or replace function public.admin_mark_withdrawal_paid(p_withdrawal_id bigint)
returns json
language plpgsql
security definer
set search_path = public
as $$
declare
  w public.withdrawals%rowtype;
  bal numeric;
  tx_id bigint;
begin
  if not public.is_admin() then raise exception 'Admin access required'; end if;
  select * into w from public.withdrawals where id=p_withdrawal_id for update;
  if not found then raise exception 'Withdrawal not found'; end if;
  if w.status='paid' then return json_build_object('status','paid'); end if;
  if w.status <> 'pending' then raise exception 'Withdrawal is not pending'; end if;
  select balance into bal from public.wallets where user_id=w.user_id for update;
  if coalesce(bal,0) < w.amount then raise exception 'Insufficient wallet balance for payout'; end if;
  update public.wallets set balance=bal-w.amount,updated_at=now() where user_id=w.user_id;
  update public.withdrawals set status='paid',processed_at=now() where id=p_withdrawal_id;
  insert into public.wallet_transactions(user_id,type,amount,description,reference_id)
    values(w.user_id,'withdrawal',-w.amount,format('Withdrawal #%s',w.id),w.id)
    on conflict (user_id,type,reference_id) do nothing
    returning id into tx_id;
  insert into public.notifications(user_id,title,message)
    values(w.user_id,'Withdrawal Paid',format('₹%s withdrawal has been paid.',to_char(w.amount,'FM999999990.00')));
  return json_build_object('status','paid','transaction_id',tx_id);
end;
$$;

grant execute on function public.admin_mark_withdrawal_paid(bigint) to authenticated;
