-- مذاكرتي: الترتيب الأسبوعي العام بالنقاط (شغّله مرة واحدة في Supabase > SQL Editor). آمن لإعادة التشغيل.
-- يحتاج friends-setup.sql قبله، و moderation-setup.sql (جدول fr_reports) حتى يشتغل زر الإبلاغ.
-- النقاط: نقطة لكل دقيقة مذاكرة + 10 مكافأة لكل يوم فيه إنجاز. تُحسب على جهاز الطالب وتُرسل هنا،
-- والسيرفر يتحقق منها (سقف يومي، وتواريخ حديثة فقط).
-- الخصوصية: الترتيب اختياري (opt-in). اللي يوافق يظهر اسمه وصورته فقط. الكود (ID) ما يرجع من السيرفر نهائياً.

-- نسخة «الأصدقاء فقط» القديمة ما نحتاجها
drop function if exists public.get_weekly_board(date, date);

alter table public.fr_profiles add column if not exists pts jsonb not null default '{}'::jsonb;
alter table public.fr_profiles add column if not exists board_on boolean not null default false;
create index if not exists fr_profiles_board on public.fr_profiles (board_on) where board_on;

-- ========== sync_points: يحفظ نقاط آخر أيام (مفتاح = تاريخ اليوم YYYY-MM-DD) ==========
create or replace function public.sync_points(p_pts jsonb)
returns text language plpgsql security definer set search_path = public as $$
declare
  me uuid := auth.uid();
  cur jsonb;
  res jsonb := '{}'::jsonb;
  k text; v text; d date; n int := 0;
  lo date := current_date - 9;     -- أيام أقدم من هذا ما تتغيّر (تبقى كما هي)
  hi date := current_date + 2;     -- هامش لفرق التوقيت
  keep date := current_date - 40;  -- نحتفظ بآخر 40 يوم فقط
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if jsonb_typeof(coalesce(p_pts, '{}'::jsonb)) <> 'object' then raise exception 'bad_input'; end if;
  select coalesce(pts, '{}'::jsonb) into cur from fr_profiles where uid = me;
  if not found then raise exception 'no_profile'; end if;

  for k, v in select key, value from jsonb_each_text(cur) loop
    if k ~ '^\d{4}-\d{2}-\d{2}$' then
      d := k::date;
      if d >= keep and d < lo and v ~ '^\d{1,4}$' then res := res || jsonb_build_object(k, v::int); end if;
    end if;
  end loop;

  for k, v in select key, value from jsonb_each_text(p_pts) loop
    n := n + 1; exit when n > 40;
    if k ~ '^\d{4}-\d{2}-\d{2}$' and v ~ '^\d{1,6}$' then
      d := k::date;
      if d >= lo and d <= hi then res := res || jsonb_build_object(k, least(v::int, 1450)); end if;
    end if;
  end loop;

  update fr_profiles set pts = res where uid = me;
  return 'ok';
end $$;

-- ========== set_board: الانضمام للترتيب العام أو الانسحاب منه ==========
create or replace function public.set_board(p_on boolean)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not_authenticated'; end if;
  update fr_profiles set board_on = coalesce(p_on, false) where uid = me;
  if not found then raise exception 'no_profile'; end if;
  return 'ok';
end $$;

-- ========== get_global_board: أعلى 30 + ترتيبك أنت، لأسبوع محدد ==========
-- يرجع فقط: الاسم والصورة والنقاط والترتيب. لا كود ولا uid. 'ref' رمز عشوائي للإبلاغ فقط ولا يُعرض.
create or replace function public.get_global_board(p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); wa text; wb text; r jsonb;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 6 then raise exception 'bad_range'; end if;
  wa := to_char(p_from, 'YYYY-MM-DD'); wb := to_char(p_to, 'YYYY-MM-DD');
  with s as (
    select p.uid, p.name, p.photo,
           coalesce((select sum(least((e.value)::int, 1450)) from jsonb_each_text(p.pts) as e(key, value)
                      where e.key >= wa and e.key <= wb), 0) as pts
      from fr_profiles p
     where p.board_on
       and (p.uid = me or not exists (select 1 from fr_blocks b where (b.blocker = me and b.blocked = p.uid) or (b.blocker = p.uid and b.blocked = me)))
  ), ranked as (
    select uid, name, photo, pts, rank() over (order by pts desc) as rk from s where pts > 0
  )
  select jsonb_build_object(
    'top', coalesce((select jsonb_agg(jsonb_build_object(
                'rank', t.rk, 'name', left(coalesce(t.name, ''), 40), 'photo', t.photo, 'pts', t.pts,
                'me', t.uid = me,
                'ref', case when t.uid = me then null else left(md5(t.uid::text || 'mz-board'), 12) end
              ) order by t.rk, t.name)
              from (select * from ranked order by rk, name limit 30) t), '[]'::jsonb),
    'on', coalesce((select board_on from fr_profiles where uid = me), false),
    'me', (select jsonb_build_object('rank', rk, 'pts', pts) from ranked where uid = me),
    'total', (select count(*) from ranked)
  ) into r;
  return r;
end $$;

-- ========== report_board_user: إبلاغ عن اسم/صورة غير لائقة بالترتيب ==========
-- 3 بلاغات من 3 أشخاص مختلفين خلال 7 أيام تخفي الشخص من الترتيب تلقائياً (والبلاغات تبقى لمراجعتك).
create or replace function public.report_board_user(p_ref text, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o uuid; r text; nm text;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select uid, name into o, nm from fr_profiles
   where board_on and left(md5(uid::text || 'mz-board'), 12) = lower(btrim(coalesce(p_ref, '')));
  if o is null or o = me then raise exception 'bad_target'; end if;
  r := case when p_reason in ('spam','abuse','inappropriate','other') then p_reason else 'other' end;
  if (select count(*) from fr_reports where reporter = me and at > now() - interval '1 day') >= 10 then
    raise exception 'rate_limited';
  end if;
  insert into fr_reports(reporter, reported, reason, snapshot)
  values (me, o, r, jsonb_build_array(jsonb_build_object('at', now(), 'kind', 'board', 'body', left(coalesce(nm, ''), 40))));
  if (select count(distinct reporter) from fr_reports where reported = o and at > now() - interval '7 days') >= 3 then
    update fr_profiles set board_on = false where uid = o;
  end if;
  return 'ok';
end $$;

revoke all on function public.sync_points(jsonb), public.set_board(boolean),
  public.get_global_board(date, date), public.report_board_user(text, text) from public, anon;
grant execute on function public.sync_points(jsonb), public.set_board(boolean),
  public.get_global_board(date, date), public.report_board_user(text, text) to authenticated;
