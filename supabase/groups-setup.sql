-- مذاكرتي: الكروبات + الرومات + رسائل الكروب + التحديات بين الأصدقاء
-- شغّله مرة واحدة في Supabase > SQL Editor، بعد friends-setup.sql و moderation-setup.sql و weekly-board-setup.sql.
-- آمن لإعادة التشغيل. الخصوصية: ما يرجع أي كود (ID) ولا uid للتطبيق، فقط الاسم والصورة، وأي إجراء على عضو يتم برمز عشوائي (ref).

-- ================= الجداول =================
create table if not exists public.fr_groups (
  id bigserial primary key,
  owner uuid not null references auth.users(id) on delete cascade,
  name text not null,
  code text unique not null,
  code_locked boolean not null default false,
  created_at timestamptz not null default now()
);
create table if not exists public.fr_group_members (
  group_id bigint not null references public.fr_groups(id) on delete cascade,
  uid uuid not null references auth.users(id) on delete cascade,
  role text not null default 'member',            -- admin | member
  joined_at timestamptz not null default now(),
  primary key (group_id, uid)
);
create index if not exists fr_gm_uid on public.fr_group_members (uid);

create table if not exists public.fr_rooms (
  id bigserial primary key,
  group_id bigint not null references public.fr_groups(id) on delete cascade,
  name text not null,
  kind text not null default 'public',            -- public (كل أعضاء الكروب) | private (بدعوة)
  created_by uuid not null references auth.users(id) on delete cascade,
  created_at timestamptz not null default now(),
  last_active timestamptz not null default now()
);
create index if not exists fr_rooms_group on public.fr_rooms (group_id);

create table if not exists public.fr_room_members (
  room_id bigint not null references public.fr_rooms(id) on delete cascade,
  uid uuid not null references auth.users(id) on delete cascade,
  status text not null default 'idle',            -- idle | studying | stopped | done
  subject text,
  ends_at timestamptz,
  beat_at timestamptz,
  changed_at timestamptz not null default now(),
  primary key (room_id, uid)
);

create table if not exists public.fr_gmsgs (
  id bigserial primary key,
  group_id bigint not null references public.fr_groups(id) on delete cascade,
  room_id bigint references public.fr_rooms(id) on delete cascade,   -- null = دردشة الكروب
  from_uid uuid not null references auth.users(id) on delete cascade,
  body text not null,
  at timestamptz not null default now()
);
create index if not exists fr_gmsgs_scope on public.fr_gmsgs (group_id, room_id, id);
create index if not exists fr_gmsgs_at on public.fr_gmsgs (at);

-- عدّاد الرسائل اليومي (30 لكل شخص بمجموع كل الكروبات والرومات). اليوم بتوقيت بغداد.
create table if not exists public.fr_gm_quota (
  uid uuid not null references auth.users(id) on delete cascade,
  day date not null,
  n int not null default 0,
  primary key (uid, day)
);

-- بلاغات الكروبات: يشوفها أدمن الكروب (ومنشئ الروم لبلاغات رومه)، ونسخة تروح لـ fr_reports لك أنت
create table if not exists public.fr_group_reports (
  id bigserial primary key,
  group_id bigint not null references public.fr_groups(id) on delete cascade,
  room_id bigint references public.fr_rooms(id) on delete set null,
  room_creator uuid,
  reporter uuid not null references auth.users(id) on delete cascade,
  reported uuid not null references auth.users(id) on delete cascade,
  reason text not null,
  snapshot jsonb not null default '[]'::jsonb,
  status text not null default 'new',             -- new | dismissed | kicked
  at timestamptz not null default now()
);
create index if not exists fr_group_reports_g on public.fr_group_reports (group_id, status, at);

-- التحديات 1 ضد 1 بين صديقين: بالنقاط (نفس نقاط الترتيب) خلال عدد أيام
create table if not exists public.fr_challenges (
  id bigserial primary key,
  from_uid uuid not null references auth.users(id) on delete cascade,
  to_uid uuid not null references auth.users(id) on delete cascade,
  days int not null default 7,
  status text not null default 'pending',         -- pending | active | declined
  start_day date,
  created_at timestamptz not null default now()
);
create index if not exists fr_ch_from on public.fr_challenges (from_uid);
create index if not exists fr_ch_to on public.fr_challenges (to_uid);

-- إشعارات (دفع): كل صف = إشعار واحد. الـEdge Function (send-push) يقرأه عبر Webhook (Insert) على هذا الجدول.
create table if not exists public.fr_notifs (
  id bigserial primary key,
  from_uid uuid not null references auth.users(id) on delete cascade,
  to_uid uuid not null references auth.users(id) on delete cascade,
  topic text not null,                            -- group | challenge | challenge_ok
  body text,
  at timestamptz not null default now()
);
create index if not exists fr_notifs_at on public.fr_notifs (at);

alter table public.fr_groups enable row level security;
alter table public.fr_group_members enable row level security;
alter table public.fr_rooms enable row level security;
alter table public.fr_room_members enable row level security;
alter table public.fr_gmsgs enable row level security;
alter table public.fr_gm_quota enable row level security;
alter table public.fr_group_reports enable row level security;
alter table public.fr_challenges enable row level security;
alter table public.fr_notifs enable row level security;
-- بدون سياسات: الوصول فقط عبر الدوال أدناه

-- ================= مساعدات داخلية =================
create or replace function public.mz_ref(p_uid uuid, p_scope bigint)
returns text language sql immutable as $$ select left(md5(p_uid::text || ':' || p_scope::text || ':mz-g'), 12) $$;

create or replace function public.mz_is_member(p_group bigint, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from fr_group_members where group_id = p_group and uid = p_uid) $$;

create or replace function public.mz_is_admin(p_group bigint, p_uid uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from fr_group_members where group_id = p_group and uid = p_uid and role = 'admin') $$;

-- هل بينهم حظر (بأي اتجاه)؟ يُستخدم لإخفاء رسائل وأسماء المحظورين
create or replace function public.mz_blocked(p_a uuid, p_b uuid)
returns boolean language sql stable security definer set search_path = public as $$
  select exists (select 1 from fr_blocks where (blocker = p_a and blocked = p_b) or (blocker = p_b and blocked = p_a)) $$;

-- حذف الرومات الخاملة (نص ساعة بدون نشاط) والرسائل الأقدم من 7 أيام
create or replace function public.mz_cleanup()
returns void language plpgsql security definer set search_path = public as $$
begin
  delete from fr_rooms where last_active < now() - interval '30 minutes';
  delete from fr_gmsgs where at < now() - interval '7 days';
  delete from fr_gm_quota where day < current_date - 3;
  delete from fr_notifs where at < now() - interval '2 days';
end $$;

-- حالة العضو بالروم كما يراها الكل: green | red | done | idle
create or replace function public.mz_state(p_status text, p_ends timestamptz, p_beat timestamptz)
returns text language sql stable as $$
  select case
    when p_status = 'studying' and p_ends > now() and p_beat > now() - interval '15 minutes' then 'green'
    when p_status = 'studying' and p_ends > now() then 'red'     -- انقطعت إشارة الحياة
    when p_status = 'studying' then 'done'                       -- خلص وقته
    when p_status = 'stopped' then 'red'
    when p_status = 'done' then 'done'
    else 'idle' end $$;

-- ================= الكروبات =================
create or replace function public.create_group(p_name text)
returns bigint language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); nm text := left(btrim(coalesce(p_name,'')), 40); c text; n int := 0; gid bigint;
        alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if char_length(nm) < 2 then raise exception 'bad_name'; end if;
  if not exists (select 1 from fr_profiles where uid = me) then raise exception 'no_profile'; end if;
  if (select count(*) from fr_groups where owner = me) >= 3 then raise exception 'too_many_groups'; end if;
  loop
    c := '';
    for i in 1..8 loop c := c || substr(alpha, 1 + floor(random() * length(alpha))::int, 1); end loop;
    exit when not exists (select 1 from fr_groups where code = c);
    n := n + 1; if n > 50 then raise exception 'code_failed'; end if;
  end loop;
  insert into fr_groups(owner, name, code) values (me, nm, c) returning id into gid;
  insert into fr_group_members(group_id, uid, role) values (gid, me, 'admin');
  return gid;
end $$;

create or replace function public.join_group(p_code text)
returns bigint language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g record;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not exists (select 1 from fr_profiles where uid = me) then raise exception 'no_profile'; end if;
  -- تحديد المحاولات (مشترك مع طلبات الصداقة): كل محاولة تنحسب، أكثر من 15 خلال 10 دقائق = رفض
  delete from fr_attempts where at < now() - interval '1 day';
  if (select count(*) from fr_attempts where uid = me and at > now() - interval '10 minutes') >= 15 then
    raise exception 'rate_limited';
  end if;
  insert into fr_attempts(uid) values (me);
  select * into g from fr_groups where code = upper(regexp_replace(coalesce(p_code,''), '[^A-Za-z0-9]', '', 'g'));
  if not found then raise exception 'bad_code'; end if;
  if g.code_locked then raise exception 'bad_code'; end if;
  if mz_is_member(g.id, me) then return g.id; end if;
  if (select count(*) from fr_group_members where uid = me) >= 10 then raise exception 'too_many_memberships'; end if;
  if (select count(*) from fr_group_members where group_id = g.id) >= 30 then raise exception 'group_full'; end if;
  insert into fr_group_members(group_id, uid) values (g.id, me);
  return g.id;
end $$;

create or replace function public.add_to_group(p_group bigint, p_friend_code text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o uuid;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_admin(p_group, me) then raise exception 'not_admin'; end if;
  select uid into o from fr_profiles where code = upper(btrim(coalesce(p_friend_code,'')));
  if o is null or not exists (select 1 from fr_friends where a = me and b = o) then raise exception 'not_friend'; end if;
  if mz_is_member(p_group, o) then return 'already'; end if;
  if (select count(*) from fr_group_members where group_id = p_group) >= 30 then raise exception 'group_full'; end if;
  if (select count(*) from fr_group_members where uid = o) >= 10 then raise exception 'too_many_memberships'; end if;
  insert into fr_group_members(group_id, uid) values (p_group, o);
  insert into fr_notifs(from_uid, to_uid, topic, body) values (me, o, 'group', (select name from fr_groups where id = p_group));
  return 'ok';
end $$;

create or replace function public.leave_group(p_group bigint)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); owner_uid uuid;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select owner into owner_uid from fr_groups where id = p_group;
  if owner_uid = me then
    -- المنشئ يطلع: يُنقل الإشراف لأقدم عضو، وإذا ماكو أحد يُحذف الكروب
    delete from fr_group_members where group_id = p_group and uid = me;
    update fr_groups set owner = (select uid from fr_group_members where group_id = p_group order by (role = 'admin') desc, joined_at limit 1)
     where id = p_group and exists (select 1 from fr_group_members where group_id = p_group);
    update fr_group_members set role = 'admin'
     where group_id = p_group and uid = (select owner from fr_groups where id = p_group);
    delete from fr_groups where id = p_group and not exists (select 1 from fr_group_members where group_id = p_group);
  else
    delete from fr_group_members where group_id = p_group and uid = me;
  end if;
  delete from fr_room_members where uid = me and room_id in (select id from fr_rooms where group_id = p_group);
  return 'ok';
end $$;

create or replace function public.delete_group(p_group bigint)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not_authenticated'; end if;
  delete from fr_groups where id = p_group and owner = me;
  if not found then raise exception 'not_owner'; end if;
  return 'ok';
end $$;

create or replace function public.kick_member(p_group bigint, p_ref text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o uuid;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_admin(p_group, me) then raise exception 'not_admin'; end if;
  select uid into o from fr_group_members where group_id = p_group and mz_ref(uid, p_group) = btrim(coalesce(p_ref,''));
  if o is null or o = me then raise exception 'bad_target'; end if;
  if o = (select owner from fr_groups where id = p_group) then raise exception 'bad_target'; end if;
  delete from fr_group_members where group_id = p_group and uid = o;
  delete from fr_room_members where uid = o and room_id in (select id from fr_rooms where group_id = p_group);
  return 'ok';
end $$;

create or replace function public.set_group_code(p_group bigint, p_lock boolean, p_reset boolean default false)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); c text; n int := 0; alpha text := 'ABCDEFGHJKLMNPQRSTUVWXYZ23456789';
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_admin(p_group, me) then raise exception 'not_admin'; end if;
  if coalesce(p_reset, false) then
    loop
      c := '';
      for i in 1..8 loop c := c || substr(alpha, 1 + floor(random() * length(alpha))::int, 1); end loop;
      exit when not exists (select 1 from fr_groups where code = c);
      n := n + 1; if n > 50 then raise exception 'code_failed'; end if;
    end loop;
    update fr_groups set code = c where id = p_group;
  end if;
  update fr_groups set code_locked = coalesce(p_lock, code_locked) where id = p_group;
  return 'ok';
end $$;

create or replace function public.get_my_groups()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r jsonb;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', g.id, 'name', g.name, 'role', m.role,
      'members', (select count(*) from fr_group_members x where x.group_id = g.id),
      'rooms', (select count(*) from fr_rooms rr where rr.group_id = g.id and rr.last_active > now() - interval '30 minutes')
    ) order by g.created_at), '[]'::jsonb) into r
  from fr_group_members m join fr_groups g on g.id = m.group_id
  where m.uid = me;
  return r;
end $$;

-- تفاصيل كروب: الأعضاء (اسم + صورة + ref) + الرومات النشطة. الكود يظهر للأدمن فقط.
create or replace function public.get_group(p_group bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); g record; isadm boolean; r jsonb;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_member(p_group, me) then raise exception 'not_member'; end if;
  perform mz_cleanup();
  select * into g from fr_groups where id = p_group;
  if not found then raise exception 'not_member'; end if;
  isadm := mz_is_admin(p_group, me);
  select jsonb_build_object(
    'id', g.id, 'name', g.name, 'admin', isadm, 'owner', g.owner = me,
    'code', case when isadm then g.code else null end,
    'locked', case when isadm then g.code_locked else null end,
    'reports', case when isadm then (select count(*) from fr_group_reports where group_id = p_group and status = 'new') else 0 end,
    'members', coalesce((select jsonb_agg(jsonb_build_object(
          'name', left(coalesce(p.name,''),40), 'photo', p.photo, 'role', m.role, 'me', m.uid = me,
          'ref', case when m.uid = me then null else mz_ref(m.uid, p_group) end
        ) order by (m.role = 'admin') desc, m.joined_at)
        from fr_group_members m join fr_profiles p on p.uid = m.uid where m.group_id = p_group and (m.uid = me or not mz_blocked(me, m.uid))), '[]'::jsonb),
    'rooms', coalesce((select jsonb_agg(jsonb_build_object(
          'id', rm.id, 'name', rm.name, 'kind', rm.kind,
          'mine', exists (select 1 from fr_room_members x where x.room_id = rm.id and x.uid = me),
          'green', (select count(*) from fr_room_members x where x.room_id = rm.id and mz_state(x.status, x.ends_at, x.beat_at) = 'green'),
          'count', (select count(*) from fr_room_members x where x.room_id = rm.id)
        ) order by rm.created_at)
        from fr_rooms rm
        where rm.group_id = p_group
          and (rm.kind = 'public' or isadm or rm.created_by = me
               or exists (select 1 from fr_room_members x where x.room_id = rm.id and x.uid = me))), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- ================= الرومات =================
create or replace function public.create_room(p_group bigint, p_name text, p_kind text)
returns bigint language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); nm text := left(btrim(coalesce(p_name,'')), 40); rid bigint;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_member(p_group, me) then raise exception 'not_member'; end if;
  perform mz_cleanup();
  if char_length(nm) < 2 then raise exception 'bad_name'; end if;
  if (select count(*) from fr_rooms where group_id = p_group) >= 8 then raise exception 'too_many_rooms'; end if;
  if (select count(*) from fr_rooms where created_by = me and last_active > now() - interval '30 minutes') >= 3 then
    raise exception 'too_many_rooms';
  end if;
  insert into fr_rooms(group_id, name, kind, created_by)
  values (p_group, nm, case when p_kind = 'private' then 'private' else 'public' end, me) returning id into rid;
  insert into fr_room_members(room_id, uid) values (rid, me);
  return rid;
end $$;

create or replace function public.join_room(p_room bigint)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); rm record;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select * into rm from fr_rooms where id = p_room;
  if not found or not mz_is_member(rm.group_id, me) then raise exception 'not_member'; end if;
  if exists (select 1 from fr_room_members where room_id = p_room and uid = me) then return 'ok'; end if;
  if rm.kind = 'private' and not (mz_is_admin(rm.group_id, me) or rm.created_by = me) then raise exception 'private_room'; end if;
  insert into fr_room_members(room_id, uid) values (p_room, me);
  update fr_rooms set last_active = now() where id = p_room;
  return 'ok';
end $$;

create or replace function public.invite_to_room(p_room bigint, p_ref text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); rm record; o uuid;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select * into rm from fr_rooms where id = p_room;
  if not found or not (rm.created_by = me or mz_is_admin(rm.group_id, me)) then raise exception 'not_admin'; end if;
  select uid into o from fr_group_members where group_id = rm.group_id and mz_ref(uid, rm.group_id) = btrim(coalesce(p_ref,''));
  if o is null then raise exception 'bad_target'; end if;
  insert into fr_room_members(room_id, uid) values (p_room, o) on conflict do nothing;
  return 'ok';
end $$;

create or replace function public.leave_room(p_room bigint)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid();
begin
  if me is null then raise exception 'not_authenticated'; end if;
  delete from fr_room_members where room_id = p_room and uid = me;
  return 'ok';
end $$;

-- p_mode: start (أخضر) | stop (أحمر) | done (خلص وقته) | beat (إشارة حياة). p_minutes = الوقت المتبقي بالدقائق.
create or replace function public.room_state(p_room bigint, p_mode text, p_subject text default null, p_minutes int default null)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); rm record; mm int := least(greatest(coalesce(p_minutes, 30), 1), 240);
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select * into rm from fr_rooms where id = p_room;
  if not found or not mz_is_member(rm.group_id, me) then raise exception 'not_member'; end if;
  if not exists (select 1 from fr_room_members where room_id = p_room and uid = me) then
    if rm.kind = 'private' and not (mz_is_admin(rm.group_id, me) or rm.created_by = me) then raise exception 'private_room'; end if;
    insert into fr_room_members(room_id, uid) values (p_room, me);
  end if;
  if p_mode = 'start' then
    update fr_room_members set status = 'studying', subject = left(btrim(coalesce(p_subject,'')), 40),
           ends_at = now() + make_interval(mins => mm), beat_at = now(), changed_at = now()
     where room_id = p_room and uid = me;
  elsif p_mode = 'beat' then
    update fr_room_members set beat_at = now(),
           ends_at = case when p_minutes is not null then now() + make_interval(mins => mm) else ends_at end
     where room_id = p_room and uid = me and status = 'studying';
  elsif p_mode = 'stop' then
    update fr_room_members set status = 'stopped', changed_at = now() where room_id = p_room and uid = me and status = 'studying';
  elsif p_mode = 'done' then
    update fr_room_members set status = 'done', changed_at = now() where room_id = p_room and uid = me and status = 'studying';
  else raise exception 'bad_mode'; end if;
  update fr_rooms set last_active = now() where id = p_room;
  return 'ok';
end $$;

create or replace function public.get_room(p_room bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); rm record; r jsonb;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select * into rm from fr_rooms where id = p_room;
  if not found or not mz_is_member(rm.group_id, me) then raise exception 'gone'; end if;
  if rm.kind = 'private' and not exists (select 1 from fr_room_members where room_id = p_room and uid = me)
     and not (mz_is_admin(rm.group_id, me) or rm.created_by = me) then raise exception 'private_room'; end if;
  select jsonb_build_object(
    'id', rm.id, 'name', rm.name, 'kind', rm.kind, 'group', rm.group_id,
    'admin', (rm.created_by = me or mz_is_admin(rm.group_id, me)),
    'joined', exists (select 1 from fr_room_members where room_id = p_room and uid = me),
    'members', coalesce((select jsonb_agg(jsonb_build_object(
        'name', left(coalesce(p.name,''),40), 'photo', p.photo, 'me', x.uid = me,
        'ref', case when x.uid = me then null else mz_ref(x.uid, rm.group_id) end,
        'state', mz_state(x.status, x.ends_at, x.beat_at),
        'subject', case when mz_state(x.status, x.ends_at, x.beat_at) in ('green','red') then x.subject else null end,
        'left', case when mz_state(x.status, x.ends_at, x.beat_at) in ('green','red')
                     then greatest(0, ceil(extract(epoch from (x.ends_at - now())) / 60))::int else null end
      ) order by (mz_state(x.status, x.ends_at, x.beat_at) = 'green') desc, x.changed_at desc)
      from fr_room_members x join fr_profiles p on p.uid = x.uid where x.room_id = p_room and (x.uid = me or not mz_blocked(me, x.uid))), '[]'::jsonb),
    -- أعضاء الكروب غير الموجودين بالروم (للدعوة بالرومات الخاصة)
    'invitable', case when (rm.created_by = me or mz_is_admin(rm.group_id, me)) and rm.kind = 'private' then
      coalesce((select jsonb_agg(jsonb_build_object('name', left(coalesce(p.name,''),40), 'photo', p.photo, 'ref', mz_ref(m.uid, rm.group_id)))
        from fr_group_members m join fr_profiles p on p.uid = m.uid
        where m.group_id = rm.group_id and m.uid <> me and not mz_blocked(me, m.uid)
          and not exists (select 1 from fr_room_members x where x.room_id = p_room and x.uid = m.uid)), '[]'::jsonb)
      else '[]'::jsonb end
  ) into r;
  return r;
end $$;

-- ================= الرسائل (بدون حد حروف عملي: سقف تقني 1000، والحد الحقيقي 30 رسالة باليوم لكل شخص) =================
create or replace function public.send_gmsg(p_group bigint, p_room bigint, p_text text)
returns int language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); t text := btrim(coalesce(p_text,'')); d date := (now() at time zone 'Asia/Baghdad')::date; used int;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_member(p_group, me) then raise exception 'not_member'; end if;
  if p_room is not null and not exists (select 1 from fr_room_members x join fr_rooms rm on rm.id = x.room_id
        where x.room_id = p_room and x.uid = me and rm.group_id = p_group) then raise exception 'not_in_room'; end if;
  if t = '' or char_length(t) > 1000 then raise exception 'bad_text'; end if;
  insert into fr_gm_quota(uid, day, n) values (me, d, 0) on conflict do nothing;
  update fr_gm_quota set n = n + 1 where uid = me and day = d and n < 30 returning n into used;
  if used is null then raise exception 'quota_exceeded'; end if;
  insert into fr_gmsgs(group_id, room_id, from_uid, body) values (p_group, p_room, me, t);
  if p_room is not null then update fr_rooms set last_active = now() where id = p_room; end if;
  return 30 - used;
end $$;

create or replace function public.get_gmsgs(p_group bigint, p_room bigint, p_after bigint default 0)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); d date := (now() at time zone 'Asia/Baghdad')::date; r jsonb; used int;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_member(p_group, me) then raise exception 'not_member'; end if;
  if p_room is not null and not exists (select 1 from fr_room_members x join fr_rooms rm on rm.id = x.room_id
        where x.room_id = p_room and x.uid = me and rm.group_id = p_group) then raise exception 'not_in_room'; end if;
  select coalesce(n, 0) into used from fr_gm_quota where uid = me and day = d;
  select jsonb_build_object(
    'left', 30 - coalesce(used, 0),
    'msgs', coalesce((select jsonb_agg(jsonb_build_object(
        'id', m.id, 'body', m.body, 'at', m.at, 'me', m.from_uid = me,
        'name', left(coalesce(p.name,''),40), 'photo', p.photo,
        'ref', case when m.from_uid = me then null else mz_ref(m.from_uid, p_group) end
      ) order by m.id)
      from (select * from fr_gmsgs where group_id = p_group and room_id is not distinct from p_room and id > coalesce(p_after, 0)
              and not mz_blocked(me, from_uid)
            order by id desc limit 80) m join fr_profiles p on p.uid = m.from_uid), '[]'::jsonb)
  ) into r;
  return r;
end $$;

-- ================= الإبلاغ: يوصل لأدمن الكروب (أو منشئ الروم) + نسخة لـ fr_reports =================
create or replace function public.report_group_member(p_group bigint, p_room bigint, p_ref text, p_reason text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o uuid; r text; creator uuid; snap jsonb; nm text;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_member(p_group, me) then raise exception 'not_member'; end if;
  select uid into o from fr_group_members where group_id = p_group and mz_ref(uid, p_group) = btrim(coalesce(p_ref,''));
  if o is null or o = me then raise exception 'bad_target'; end if;
  r := case when p_reason in ('spam','abuse','inappropriate','other') then p_reason else 'other' end;
  if (select count(*) from fr_group_reports where reporter = me and at > now() - interval '1 day') >= 10 then
    raise exception 'rate_limited';
  end if;
  if p_room is not null then select created_by into creator from fr_rooms where id = p_room and group_id = p_group; end if;
  select left(coalesce(name,''),40) into nm from fr_profiles where uid = o;
  select coalesce(jsonb_agg(jsonb_build_object('at', m.at, 'kind', 'group', 'body', m.body) order by m.id), '[]'::jsonb) into snap
    from (select id, at, body from fr_gmsgs where group_id = p_group and from_uid = o order by id desc limit 5) m;
  snap := jsonb_build_array(jsonb_build_object('at', now(), 'kind', 'name', 'body', nm)) || snap;
  insert into fr_group_reports(group_id, room_id, room_creator, reporter, reported, reason, snapshot)
  values (p_group, p_room, creator, me, o, r, snap);
  insert into fr_reports(reporter, reported, reason, snapshot) values (me, o, r, snap);   -- نسخة لك أنت (المطوّر)
  return 'ok';
end $$;

create or replace function public.get_group_reports(p_group bigint)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r jsonb;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_member(p_group, me) then raise exception 'not_member'; end if;
  select coalesce(jsonb_agg(jsonb_build_object(
      'id', x.id, 'reason', x.reason, 'at', x.at, 'name', coalesce(x.snapshot->0->>'body',''),
      'room', (select name from fr_rooms where id = x.room_id),
      'msgs', (select coalesce(jsonb_agg(e->>'body' order by i), '[]'::jsonb) from jsonb_array_elements(x.snapshot) with ordinality t(e, i) where i > 1),
      'ref', mz_ref(x.reported, p_group)
    ) order by x.at desc), '[]'::jsonb) into r
  from fr_group_reports x
  where x.group_id = p_group and x.status = 'new'
    and (mz_is_admin(p_group, me) or x.room_creator = me)
    and x.reported <> me;
  return r;
end $$;

create or replace function public.resolve_group_report(p_report bigint, p_kick boolean)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); x record;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select * into x from fr_group_reports where id = p_report;
  if not found or not (mz_is_admin(x.group_id, me) or x.room_creator = me) then raise exception 'not_admin'; end if;
  if coalesce(p_kick, false) then
    if mz_is_admin(x.group_id, me) and x.reported <> (select owner from fr_groups where id = x.group_id) then
      delete from fr_group_members where group_id = x.group_id and uid = x.reported;
      delete from fr_room_members where uid = x.reported and room_id in (select id from fr_rooms where group_id = x.group_id);
    elsif x.room_id is not null then
      delete from fr_room_members where room_id = x.room_id and uid = x.reported;   -- منشئ الروم يطرد من رومه فقط
    end if;
    update fr_group_reports set status = 'kicked' where id = p_report;
  else
    update fr_group_reports set status = 'dismissed' where id = p_report;
  end if;
  return 'ok';
end $$;

-- ================= التحديات 1 ضد 1 =================
create or replace function public.send_challenge(p_friend_code text, p_days int)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o uuid; d int := case when p_days in (3, 7) then p_days else 7 end;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  select uid into o from fr_profiles where code = upper(btrim(coalesce(p_friend_code,'')));
  if o is null or not exists (select 1 from fr_friends where a = me and b = o) then raise exception 'not_friend'; end if;
  if exists (select 1 from fr_challenges where status in ('pending','active')
       and ((from_uid = me and to_uid = o) or (from_uid = o and to_uid = me))) then return 'already'; end if;
  if (select count(*) from fr_challenges where (from_uid = me or to_uid = me) and status in ('pending','active')) >= 5 then
    raise exception 'too_many';
  end if;
  insert into fr_challenges(from_uid, to_uid, days) values (me, o, d);
  insert into fr_notifs(from_uid, to_uid, topic, body) values (me, o, 'challenge', d::text);
  return 'sent';
end $$;

create or replace function public.respond_challenge(p_id bigint, p_accept boolean)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o uuid;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if coalesce(p_accept, false) then
    update fr_challenges set status = 'active', start_day = (now() at time zone 'Asia/Baghdad')::date
     where id = p_id and to_uid = me and status = 'pending' returning from_uid into o;
    if o is not null then insert into fr_notifs(from_uid, to_uid, topic, body) values (me, o, 'challenge_ok', null); end if;
  else
    delete from fr_challenges where id = p_id and (to_uid = me or from_uid = me);
  end if;
  return 'ok';
end $$;

-- كل تحدياتي: النقاط تُحسب من نقاط الطرفين خلال أيام التحدي. التحدي المنتهي يبقى يوم ثم يختفي.
create or replace function public.get_challenges()
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); r jsonb; tday date := (now() at time zone 'Asia/Baghdad')::date;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  delete from fr_challenges where status = 'active' and start_day + days + 1 < tday;
  select coalesce(jsonb_agg(x order by (x->>'id')::bigint desc), '[]'::jsonb) into r from (
    select jsonb_build_object(
      'id', c.id, 'status', c.status, 'days', c.days, 'mine', c.from_uid = me,
      'start', c.start_day,
      'left', case when c.status = 'active' then greatest(0, c.start_day + c.days - tday) else null end,
      'over', c.status = 'active' and tday >= c.start_day + c.days,
      'code', p.code, 'name', p.name, 'photo', p.photo,
      'my', case when c.status = 'active' then coalesce((select sum(least(e.value::int, 1450)) from jsonb_each_text(pm.pts) as e(key, value)
              where e.key >= to_char(c.start_day, 'YYYY-MM-DD') and e.key <= to_char(c.start_day + c.days - 1, 'YYYY-MM-DD')), 0) end,
      'their', case when c.status = 'active' then coalesce((select sum(least(e.value::int, 1450)) from jsonb_each_text(p.pts) as e(key, value)
              where e.key >= to_char(c.start_day, 'YYYY-MM-DD') and e.key <= to_char(c.start_day + c.days - 1, 'YYYY-MM-DD')), 0) end
    ) as x
    from fr_challenges c
    join fr_profiles p on p.uid = case when c.from_uid = me then c.to_uid else c.from_uid end
    join fr_profiles pm on pm.uid = me
    where (c.from_uid = me or c.to_uid = me) and c.status in ('pending','active')
  ) s;
  return r;
end $$;

-- ================= حظر عضو من داخل الكروب/الروم (يخفي رسائله وهو يخفي رسائلك، ويفك الصداقة) =================
create or replace function public.block_group_member(p_group bigint, p_ref text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o uuid;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_member(p_group, me) then raise exception 'not_member'; end if;
  select uid into o from fr_group_members where group_id = p_group and mz_ref(uid, p_group) = btrim(coalesce(p_ref,''));
  if o is null or o = me then raise exception 'bad_target'; end if;
  insert into fr_blocks(blocker, blocked) values (me, o) on conflict do nothing;
  delete from fr_requests where (from_uid = me and to_uid = o) or (from_uid = o and to_uid = me);
  delete from fr_friends where (a = me and b = o) or (a = o and b = me);
  delete from fr_messages where (from_uid = me and to_uid = o) or (from_uid = o and to_uid = me);
  delete from fr_reads where (reader = me and peer = o) or (reader = o and peer = me);
  delete from fr_challenges where (from_uid = me and to_uid = o) or (from_uid = o and to_uid = me);
  return 'ok';
end $$;

-- ================= ترتيب الكروب الأسبوعي بالنقاط (لأعضاء الكروب فقط) =================
create or replace function public.get_group_board(p_group bigint, p_from date, p_to date)
returns jsonb language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); wa text; wb text; r jsonb;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_member(p_group, me) then raise exception 'not_member'; end if;
  if p_from is null or p_to is null or p_to < p_from or p_to - p_from > 6 then raise exception 'bad_range'; end if;
  wa := to_char(p_from, 'YYYY-MM-DD'); wb := to_char(p_to, 'YYYY-MM-DD');
  with s as (
    select p.uid, p.name, p.photo,
           coalesce((select sum(least((e.value)::int, 1450)) from jsonb_each_text(p.pts) as e(key, value)
                      where e.key >= wa and e.key <= wb), 0) as pts
      from fr_group_members m join fr_profiles p on p.uid = m.uid
     where m.group_id = p_group and (m.uid = me or not mz_blocked(me, m.uid))
  ), ranked as (
    select uid, name, photo, pts, rank() over (order by pts desc) as rk from s
  )
  select coalesce(jsonb_agg(jsonb_build_object(
           'rank', rk, 'name', left(coalesce(name, ''), 40), 'photo', photo, 'pts', pts, 'me', uid = me
         ) order by rk, name), '[]'::jsonb) into r from ranked;
  return r;
end $$;

-- ================= إعادة تسمية الكروب (أدمن) / تعيين أو إزالة أدمن (المنشئ فقط) =================
create or replace function public.rename_group(p_group bigint, p_name text)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); nm text := left(btrim(coalesce(p_name,'')), 40);
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if not mz_is_admin(p_group, me) then raise exception 'not_admin'; end if;
  if char_length(nm) < 2 then raise exception 'bad_name'; end if;
  update fr_groups set name = nm where id = p_group;
  return 'ok';
end $$;

create or replace function public.set_member_role(p_group bigint, p_ref text, p_admin boolean)
returns text language plpgsql security definer set search_path = public as $$
declare me uuid := auth.uid(); o uuid;
begin
  if me is null then raise exception 'not_authenticated'; end if;
  if (select owner from fr_groups where id = p_group) is distinct from me then raise exception 'not_admin'; end if;
  select uid into o from fr_group_members where group_id = p_group and mz_ref(uid, p_group) = btrim(coalesce(p_ref,''));
  if o is null or o = me then raise exception 'bad_target'; end if;
  update fr_group_members set role = case when coalesce(p_admin, false) then 'admin' else 'member' end
   where group_id = p_group and uid = o;
  return 'ok';
end $$;

revoke all on function
  public.create_group(text), public.join_group(text), public.add_to_group(bigint, text), public.leave_group(bigint),
  public.delete_group(bigint), public.kick_member(bigint, text), public.set_group_code(bigint, boolean, boolean),
  public.get_my_groups(), public.get_group(bigint), public.create_room(bigint, text, text), public.join_room(bigint),
  public.invite_to_room(bigint, text), public.leave_room(bigint), public.room_state(bigint, text, text, int),
  public.get_room(bigint), public.send_gmsg(bigint, bigint, text), public.get_gmsgs(bigint, bigint, bigint),
  public.report_group_member(bigint, bigint, text, text), public.get_group_reports(bigint),
  public.resolve_group_report(bigint, boolean), public.send_challenge(text, int), public.respond_challenge(bigint, boolean),
  public.get_challenges(), public.mz_cleanup(), public.mz_is_member(bigint, uuid), public.mz_is_admin(bigint, uuid),
  public.mz_blocked(uuid, uuid), public.block_group_member(bigint, text), public.get_group_board(bigint, date, date),
  public.rename_group(bigint, text), public.set_member_role(bigint, text, boolean)
  from public, anon, authenticated;
grant execute on function
  public.create_group(text), public.join_group(text), public.add_to_group(bigint, text), public.leave_group(bigint),
  public.delete_group(bigint), public.kick_member(bigint, text), public.set_group_code(bigint, boolean, boolean),
  public.get_my_groups(), public.get_group(bigint), public.create_room(bigint, text, text), public.join_room(bigint),
  public.invite_to_room(bigint, text), public.leave_room(bigint), public.room_state(bigint, text, text, int),
  public.get_room(bigint), public.send_gmsg(bigint, bigint, text), public.get_gmsgs(bigint, bigint, bigint),
  public.report_group_member(bigint, bigint, text, text), public.get_group_reports(bigint),
  public.resolve_group_report(bigint, boolean), public.send_challenge(text, int), public.respond_challenge(bigint, boolean),
  public.get_challenges(), public.block_group_member(bigint, text), public.get_group_board(bigint, date, date),
  public.rename_group(bigint, text), public.set_member_role(bigint, text, boolean)
  to authenticated;

-- تنظيف دوري اختياري كل 10 دقايق (إذا pg_cron مفعّل عندك). وإذا ما اشتغل ما يضر: الدوال تنظّف نفسها عند الاستخدام.
do $$ begin
  perform cron.schedule('mz-groups-cleanup', '*/10 * * * *', 'select public.mz_cleanup()');
exception when others then null; end $$;
