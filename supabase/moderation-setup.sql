-- مذاكرتي: حذف الحساب + الإبلاغ عن مستخدم (شغّله مرة واحدة في Supabase > SQL Editor). آمن لإعادة التشغيل.
-- يحتاج أن يكون friends-setup.sql مشغّلاً قبله (يعتمد على جداول fr_*).

-- ========== 1) الإبلاغ ==========
create table if not exists public.fr_reports (
  id bigserial primary key,
  reporter uuid not null references auth.users(id) on delete cascade,
  reported uuid not null references auth.users(id) on delete cascade,
  reason text not null,
  snapshot jsonb not null default '[]'::jsonb,   -- آخر 10 رسائل أرسلها المبلَّغ عنه للمبلِّغ (الرسائل تنحذف تلقائياً بعد 7 أيام)
  status text not null default 'new',            -- new | reviewed | actioned (تغيّره يدوياً)
  at timestamptz not null default now()
);
create index if not exists fr_reports_reported on public.fr_reports (reported, at);
create index if not exists fr_reports_reporter on public.fr_reports (reporter, at);

-- لا سياسات: لا أحد يقرأ البلاغات من التطبيق. تراجعها أنت من Supabase > Table Editor
alter table public.fr_reports enable row level security;

create or replace function public.report_user(p_code text, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o uuid; r text; snap jsonb;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select uid into o from fr_profiles where code = upper(btrim(coalesce(p_code,'')));
  if o is null or o = me then raise exception 'bad_target'; end if;
  -- يبلّغ فقط عن صديق أو عن شخص أرسل له رسائل (يمنع البلاغات العشوائية بتخمين الأكواد)
  if not exists (select 1 from fr_friends where a = me and b = o)
     and not exists (select 1 from fr_messages where from_uid = o and to_uid = me) then
    raise exception 'bad_target';
  end if;
  r := case when p_reason in ('spam','abuse','inappropriate','other') then p_reason else 'other' end;
  if (select count(*) from fr_reports where reporter = me and at > now() - interval '1 day') >= 10 then
    raise exception 'rate_limited';
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('at', m.at, 'kind', m.kind, 'body', m.body) order by m.id), '[]'::jsonb)
    into snap
    from (select id, at, kind, body from fr_messages where from_uid = o and to_uid = me order by id desc limit 10) m;
  insert into fr_reports(reporter, reported, reason, snapshot) values (me, o, r, snap);
  return 'ok';
end $$;

-- ========== 2) حذف الحساب ==========
-- يحذف المستخدم من auth.users، وكل جداول الأصدقاء (fr_*) وfcm_tokens مربوطة بـ on delete cascade فتنحذف معه.
-- جدول بيانات المستخدم القديم (user_data / push_subs) من إعدادك السابق: يُحذف منه إن وُجد، وإن اختلف اسم العمود يُتخطّى بدون خطأ.
create or replace function public.delete_my_account()
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not_authenticated'; end if;
  begin execute 'delete from public.user_data where user_id = $1' using me; exception when others then null; end;
  begin execute 'delete from public.push_subs where user_id = $1' using me; exception when others then null; end;
  delete from auth.users where id = me;
  return 'ok';
end $$;

revoke all on function public.report_user(text,text), public.delete_my_account() from public, anon;
grant execute on function public.report_user(text,text), public.delete_my_account() to authenticated;

-- لمراجعة البلاغات: select * from public.fr_reports order by at desc;
