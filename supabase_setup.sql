-- =====================================================================
--  ZACAST ATTENDANCE MANAGEMENT SYSTEM  -  Supabase setup
--  Zamfara College of Arts, Science and Technology, Gusau
--
--  HOW TO USE:  Supabase Dashboard -> SQL Editor -> New query ->
--  paste this WHOLE file -> press RUN.   (Safe to run again: it will not
--  duplicate anything.)
--
--  Default login after running:   username: admin    password: admin123
--  (change it inside the app: Settings > Change Password)
-- =====================================================================

create extension if not exists pgcrypto with schema extensions;
set search_path = public, extensions;

-- ---------------------------------------------------------------------
-- 0. Clean-up of an OLDER ZACAST setup (the per-lecturer "profiles /
--    owner_id" version).  It only runs if that old version is found, and
--    only removes ZACAST tables.  A fresh project skips this step.
-- ---------------------------------------------------------------------
do $$
begin
  if exists (
    select 1 from information_schema.columns
    where table_schema = 'public'
      and table_name in ('departments','students','attendance_sessions','attendance_records')
      and column_name = 'owner_id'
  ) then
    drop table if exists public.attendance_records, public.attendance_sessions,
                         public.students, public.departments, public.profiles cascade;
    begin
      drop trigger if exists on_auth_user_created on auth.users;
    exception when others then null;
    end;
    drop function if exists public.handle_new_user();
    drop function if exists public.touch_updated_at();
  end if;
end $$;

-- ---------------------------------------------------------------------
-- 1. TABLES
-- ---------------------------------------------------------------------

-- The single admin / lecturer account (name, photo, login)
create table if not exists public.app_admin (
  id               int primary key default 1 check (id = 1),
  username         text not null,
  full_name        text not null default 'Administrator',
  avatar           text,                       -- small profile photo (data URL)
  password_hash    text not null,
  failed_attempts  int  not null default 0,
  locked_until     timestamptz
);

-- Login sessions
create table if not exists public.admin_sessions (
  token       text primary key,
  created_at  timestamptz not null default now(),
  expires_at  timestamptz not null
);

-- Departments (Computer Science, ...). Add more from the app: Settings > Departments
create table if not exists public.departments (
  id          uuid primary key default gen_random_uuid(),
  name        text not null,
  code        text,
  created_at  timestamptz not null default now()
);
create unique index if not exists departments_name_uq on public.departments (lower(name));

-- Students (each one belongs to ONE department)
create table if not exists public.students (
  id             uuid primary key default gen_random_uuid(),
  department_id  uuid not null references public.departments(id) on delete cascade,
  serial         int  not null,
  name           text not null,
  adm_no         text not null,
  created_at     timestamptz not null default now(),
  constraint students_serial_uq unique (department_id, serial)
);
create unique index if not exists students_adm_uq on public.students (department_id, lower(adm_no));
create index if not exists students_dept_idx on public.students (department_id);

-- Attendance sessions (one per class / day), belong to ONE department
create table if not exists public.attendance_sessions (
  id             uuid primary key default gen_random_uuid(),
  department_id  uuid not null references public.departments(id) on delete cascade,
  course         text not null default '',
  semester       text not null default 'First Semester',
  date           date not null,
  time           time not null,
  day            text not null,
  status         text not null default 'In Progress',
  created_at     timestamptz not null default now(),
  completed_at   timestamptz
);
create index if not exists att_sessions_dept_idx on public.attendance_sessions (department_id, date desc);

-- Present / Absent marks
create table if not exists public.attendance_records (
  id             uuid primary key default gen_random_uuid(),
  department_id  uuid not null references public.departments(id) on delete cascade,
  session_id     uuid not null references public.attendance_sessions(id) on delete cascade,
  student_id     uuid not null references public.students(id) on delete cascade,
  status         text not null check (status in ('present','absent')),
  marked_at      timestamptz not null default now(),
  constraint att_records_uq unique (session_id, student_id)
);
create index if not exists att_records_dept_idx on public.attendance_records (department_id);

-- ---------------------------------------------------------------------
-- 2. SECURITY  (only a logged-in admin can read or write anything)
-- ---------------------------------------------------------------------

-- Is the caller a logged-in admin?  (the app sends its login token in the
-- "x-admin-token" request header)
create or replace function public.is_admin()
returns boolean
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare
  h text;
  t text;
begin
  h := current_setting('request.headers', true);
  if h is null or h = '' then return false; end if;
  t := coalesce(h::json ->> 'x-admin-token', '');
  if t = '' then return false; end if;
  return exists (select 1 from public.admin_sessions s where s.token = t and s.expires_at > now());
end;
$$;

alter table public.app_admin           enable row level security;
alter table public.admin_sessions      enable row level security;
alter table public.departments         enable row level security;
alter table public.students            enable row level security;
alter table public.attendance_sessions enable row level security;
alter table public.attendance_records  enable row level security;

-- admin tables: nobody can touch them directly (only the functions below)
revoke all on public.app_admin      from anon, authenticated;
revoke all on public.admin_sessions from anon, authenticated;

drop policy if exists "admin only" on public.departments;
drop policy if exists "admin only" on public.students;
drop policy if exists "admin only" on public.attendance_sessions;
drop policy if exists "admin only" on public.attendance_records;

create policy "admin only" on public.departments         for all to anon, authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin only" on public.students            for all to anon, authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin only" on public.attendance_sessions for all to anon, authenticated using (public.is_admin()) with check (public.is_admin());
create policy "admin only" on public.attendance_records  for all to anon, authenticated using (public.is_admin()) with check (public.is_admin());

grant select, insert, update, delete on public.departments, public.students,
      public.attendance_sessions, public.attendance_records to anon, authenticated;

-- ---------------------------------------------------------------------
-- 3. LOGIN FUNCTIONS
-- ---------------------------------------------------------------------

create or replace function public.admin_login(p_username text, p_password text)
returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  a public.app_admin%rowtype;
  tok text;
begin
  select * into a from public.app_admin where id = 1;
  if not found then
    return json_build_object('ok', false, 'error', 'No admin account found');
  end if;

  if a.locked_until is not null and a.locked_until > now() then
    return json_build_object('ok', false, 'error',
      'Too many wrong attempts. Try again in a few minutes.');
  end if;

  if lower(trim(coalesce(p_username,''))) = lower(a.username)
     and a.password_hash = crypt(coalesce(p_password,''), a.password_hash) then
    delete from public.admin_sessions where expires_at < now();
    tok := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
    insert into public.admin_sessions (token, expires_at) values (tok, now() + interval '30 days');
    update public.app_admin set failed_attempts = 0, locked_until = null where id = 1;
    return json_build_object('ok', true, 'token', tok,
      'username', a.username, 'full_name', a.full_name, 'avatar', a.avatar);
  end if;

  update public.app_admin
     set locked_until = case when failed_attempts + 1 >= 8 then now() + interval '5 minutes' else locked_until end,
         failed_attempts = case when failed_attempts + 1 >= 8 then 0 else failed_attempts + 1 end
   where id = 1;
  return json_build_object('ok', false, 'error', 'Invalid username or password');
end;
$$;

create or replace function public.admin_me()
returns json
language plpgsql stable security definer
set search_path = public, extensions, pg_temp
as $$
declare a public.app_admin%rowtype;
begin
  if not public.is_admin() then return null; end if;
  select * into a from public.app_admin where id = 1;
  return json_build_object('username', a.username, 'full_name', a.full_name, 'avatar', a.avatar);
end;
$$;

create or replace function public.admin_logout()
returns void
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare t text;
begin
  t := coalesce(nullif(current_setting('request.headers', true), '')::json ->> 'x-admin-token', '');
  if t <> '' then delete from public.admin_sessions where token = t; end if;
end;
$$;

-- Update name / username / photo.  Pass p_avatar = null to keep the photo,
-- or an empty string '' to remove it.
create or replace function public.admin_update_profile(p_full_name text, p_username text, p_avatar text default null)
returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
begin
  if not public.is_admin() then raise exception 'Not logged in' using errcode = '42501'; end if;
  if length(trim(coalesce(p_full_name,''))) = 0 then raise exception 'Full name is required'; end if;
  if length(trim(coalesce(p_username,''))) < 3 then raise exception 'Username must be at least 3 characters'; end if;
  if length(coalesce(p_avatar,'')) > 400000 then raise exception 'Photo is too large'; end if;
  update public.app_admin
     set full_name = trim(p_full_name),
         username  = trim(p_username),
         avatar    = case when p_avatar is null then avatar when p_avatar = '' then null else p_avatar end
   where id = 1;
  return public.admin_me();
end;
$$;

create or replace function public.admin_change_password(p_old text, p_new text)
returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare a public.app_admin%rowtype;
begin
  if not public.is_admin() then raise exception 'Not logged in' using errcode = '42501'; end if;
  select * into a from public.app_admin where id = 1;
  if a.password_hash <> crypt(coalesce(p_old,''), a.password_hash) then
    return json_build_object('ok', false, 'error', 'Current password does not match');
  end if;
  if length(coalesce(p_new,'')) < 6 then
    return json_build_object('ok', false, 'error', 'New password must be at least 6 characters');
  end if;
  update public.app_admin set password_hash = crypt(p_new, gen_salt('bf')) where id = 1;
  return json_build_object('ok', true);
end;
$$;

revoke all on function public.admin_login(text, text)                    from public;
revoke all on function public.admin_me()                                 from public;
revoke all on function public.admin_logout()                             from public;
revoke all on function public.admin_update_profile(text, text, text)     from public;
revoke all on function public.admin_change_password(text, text)          from public;
revoke all on function public.is_admin()                                 from public;
grant execute on function public.admin_login(text, text)                 to anon, authenticated;
grant execute on function public.admin_me()                              to anon, authenticated;
grant execute on function public.admin_logout()                          to anon, authenticated;
grant execute on function public.admin_update_profile(text, text, text)  to anon, authenticated;
grant execute on function public.admin_change_password(text, text)       to anon, authenticated;
grant execute on function public.is_admin()                              to anon, authenticated;

-- ---------------------------------------------------------------------
-- 4. STARTING DATA
-- ---------------------------------------------------------------------

-- Admin account  (username: admin   password: admin123)
insert into public.app_admin (id, username, full_name, password_hash)
values (1, 'admin', 'Administrator', crypt('admin123', gen_salt('bf')))
on conflict (id) do nothing;

-- First department
insert into public.departments (name, code)
values ('Computer Science', 'CSC')
on conflict do nothing;

-- Computer Science students: serial number, name, admission number (215 students)
insert into public.students (department_id, serial, name, adm_no)
select d.id, v.serial, v.name, v.adm_no
from public.departments d
cross join (values
  (1, 'AHMAD HADI', '35872'),
  (2, 'ABDULMUNADI YUSHA''U', '35882'),
  (3, 'AHMAD SHEHU', '35885'),
  (4, 'AMIRA MUHAMMAD', '35893'),
  (5, 'SAIFULLAHI BELLO', '35897'),
  (6, 'JAMILU ABUBAKAR', '35920'),
  (7, 'AHMAD ABDULAZIZ', '35950'),
  (8, 'ANISA MUHAMMAD', '35965'),
  (9, 'FAHAD AMINU', '35966'),
  (10, 'HAUWA''U SURAJO', '35968'),
  (11, 'MARDIYA ALIYU', '35969'),
  (12, 'HABIBA MUHAMMAD', '35984'),
  (13, 'MUHAMMAD ATTAHIRU', '36017'),
  (14, 'AISHA BELLO', '36026'),
  (15, 'SAIFULLAHI ABDULLAHI', '36028'),
  (16, 'MUHSIN RILWAN', '36029'),
  (17, 'HUSSAINI SALISU', '36030'),
  (18, 'ABUBAKAR YUSUF', '36060'),
  (19, 'FAIZA IBRAHIM SANI', '36073'),
  (20, 'MUHAMMAD YUSUF KANOMA', '36089'),
  (21, 'IBRAHIM YUSUF KANOMA', '36090'),
  (22, 'NUSAIBA TIJJANI', '36124'),
  (23, 'DAUDA UMAR', '36144'),
  (24, 'HALLIRU JAMILU DINAWA', '36146'),
  (25, 'ABDULWAHID NASIR MUSTAPHA', '36151'),
  (26, 'HAFSAT ABDULLAHI', '36152'),
  (27, 'SAUDATU HARUNA', '36162'),
  (28, 'ALIYU ABDULLAHI', '36165'),
  (29, 'ABDULLAHI AUWAL', '36166'),
  (30, 'SULEMAN ABDULLAHI', '36175'),
  (31, 'NURA ALMUSTAPHA', '36187'),
  (32, 'FATIMA NASIR KANOMA', '36190'),
  (33, 'MUHAMMAD HAMISU', '36191'),
  (34, 'MUHAMMAD ISMA''IL', '36192'),
  (35, 'MUSA YAKUB', '36193'),
  (36, 'SHAFI''U AHMAD', '36194'),
  (37, 'ABDURRAHMAN UMAR', '36196'),
  (38, 'AISHA ADAM', '36197'),
  (39, 'ABDULAHAD DAHIRU DAN MUSULMI', '36198'),
  (40, 'AHMAD AHMAD ALHASAN', '36199'),
  (41, 'USMAN ABUBAKAR MAI FENTI', '36201'),
  (42, 'FADIMATU KABIRU DINAWA', '36202'),
  (43, 'USMAN ADAM', '36203'),
  (44, 'NA IMA MUSA', '36204'),
  (45, 'AHMAD SHEHU', '36207'),
  (46, 'KABIRU BASHAR MAKAMA', '36208'),
  (47, 'SAIDU LAUWALI', '36209'),
  (48, 'UMAR SANI MORIKI', '36210'),
  (49, 'IBRAHIM BELLO', '36211'),
  (50, 'MUHAMMAD SAIFULLAHI BASHIR', '36212'),
  (51, 'HAJARU ABUBAKAR', '36214'),
  (52, 'ABUBAKAR HARUNA', '36215'),
  (53, 'FATIMA MUHAMMAD', '36217'),
  (54, 'UMAR IBRAHIM DAN TSOHO', '36218'),
  (55, 'AMINA ISMA''IL', '36221'),
  (56, 'NAFISA SALISU', '36222'),
  (57, 'UKASHA HARUNA LABBO', '36223'),
  (58, 'SALISU ABDULLAHI', '36224'),
  (59, 'MUSTAPHA HUSSAINI', '36226'),
  (60, 'LAMIN ABUBAKAR MASTER', '36227'),
  (61, 'ABBAS ABUBAKAR', '36229'),
  (62, 'UKASHA SALISU', '36322'),
  (63, 'KHALID MUBASHIR', '35967'),
  (64, 'AHMAD SULAIMAN', '36188'),
  (65, 'IBRAHIM MUHAMMAD ISHAQ', '36189'),
  (66, 'SHAMSU NURA', '36195'),
  (67, 'ABUBAKAR SAADU', '36200'),
  (68, 'SAMIR MUHAMMAD YAHAYA', '36205'),
  (69, 'BELLO USMAN', '36206'),
  (70, 'MUBARAK SANI', '36213'),
  (71, 'ABUBAKAR HASSAN', '36216'),
  (72, 'ABDULRAHMAN BELLO', '36220'),
  (73, 'JABIRU SHU''AIBU', '36225'),
  (74, 'NUSAIBA FADALU', '36228'),
  (75, 'UBAIDULLAHI USMAN DAHIRU', '36400'),
  (76, 'NURA BALA KANTIN SAUKI', '36401'),
  (77, 'UMAR SANI', '36402'),
  (78, 'MUDASSIR SHAFI''I', '36403'),
  (79, 'AHMAD ABUBAKAR', '36404'),
  (80, 'GHAZALI ABDULHAMID', '36405'),
  (81, 'KASIMU HALLIRU', '36406'),
  (82, 'MAHMUD ABDULLAHI', '36407'),
  (83, 'ISMA''IL ILIYASU ZURMI', '36408'),
  (84, 'ABUBAKAR ABDULLAHI HUSSAINI', '36409'),
  (85, 'ABUBAKAR USMAN', '36410'),
  (86, 'RABIU LAWAL IDRIS', '36411'),
  (87, 'USMAN KAMILU', '36412'),
  (88, 'SANUSI IBRAHIM', '36413'),
  (89, 'KHADIJA MUKHTAR', '35844'),
  (90, 'ASMA''U LAWAL RUWA', '36415'),
  (91, 'YAHAYA SAFIYANU', '36416'),
  (92, 'ABDULHAKEEM MUHAMMAD BALA', '36417'),
  (93, 'NAFI''U ABDULLAHI', '36418'),
  (94, 'MARYAM AMINU', '36419'),
  (95, 'AMIR ALIYU MAI LAFIYA', '36420'),
  (96, 'MIKAILU AHMED ABDULLAHI', '36421'),
  (97, 'AHMAD HALLIRU', '36422'),
  (98, 'ABUBAKAR UMAR', '36423'),
  (99, 'AISHA ABDULHAMID', '36424'),
  (100, 'HAUWA''U BELLO', '36425'),
  (101, 'IMRANA LAWAL', '36426'),
  (102, 'JUMMAI HARUNA', '36427'),
  (103, 'KABIRU TUKUR', '36428'),
  (104, 'SUBAI''A RABI''U', '36429'),
  (105, 'AHMAD BASIRU', '36430'),
  (106, 'HUSSAINI SALISU', '36431'),
  (107, 'ABDULLAHI ABDULHAMID ANKA', '36432'),
  (108, 'FATIMA SULAIMAN', '36433'),
  (109, 'SAFIYULLAHI SHEHU', '36434'),
  (110, 'YASIR HUSSAINI KYAMBARAWA', '36435'),
  (111, 'YUSUF ABDULLAHI', '36436'),
  (112, 'SANUSI ABDULLAHI', '36437'),
  (113, 'MUSTAPHA KABIRU KWATTA', '36438'),
  (114, 'MUSTAPHA USMAN', '36439'),
  (115, 'SULAIMAN ABDULRAHMAN', '36440'),
  (116, 'NAJA''ATU BELLO', '36441'),
  (117, 'IBRAHIM SADA ALA', '36442'),
  (118, 'ABUBAKAR ABUBAKAR NA''UKKU', '36443'),
  (119, 'ABDULRASHID SALIHU ANKA', '36444'),
  (120, 'ABDULMUMINU KABIRU', '36445'),
  (121, 'ABUBAKAR LAWALI', '36446'),
  (122, 'BASIRU ABUBAKAR', '36447'),
  (123, 'MUHAMMAD AUWAL', '36448'),
  (124, 'AHMAD AMINU DAN GUSAU', '36449'),
  (125, 'NAJA''ATU UMAR', '36450'),
  (126, 'TUJJANI ILIYASU', '36451'),
  (127, 'ABBAS NASIRU', '36452'),
  (128, 'ANAS BELLO', '36453'),
  (129, 'SAIFULLAHI BASHIRU', '36454'),
  (130, 'ISMAIL BELLO', '36455'),
  (131, 'IBRAHIM MAS''UD', '36456'),
  (132, 'AISHA IBRAHIM', '36457'),
  (133, 'ABUBAKAR RABIU MAKARANTA', '36458'),
  (134, 'ZUHAIRU MUHAMMAD', '36459'),
  (135, 'AHMAD ISMAIL', '36460'),
  (136, 'BUHARI IBRAHIM', '36461'),
  (137, 'ISAH IBRAHIM', '36462'),
  (138, 'UMAR MUHAMMAD SABO', '36463'),
  (139, 'SAHIB ABUBAKAR', '36464'),
  (140, 'ABDULRAHMAN AMINU', '36465'),
  (141, 'AMINU AMINU ABUBAKAR', '36466'),
  (142, 'YASIR HASSAN', '36467'),
  (143, 'ABDULAZIZ BALA', '36468'),
  (144, 'AHMAD TIJJANI', '36469'),
  (145, 'IBRAHIM TIJJANI MUHAMMAD', '36470'),
  (146, 'ZULAIHA MUHAMMAD', '36471'),
  (147, 'SULEMAN MUHAMMED', '36472'),
  (148, 'ABDULMALIK USMAN', '36473'),
  (149, 'MUHAMMAD YUSUF', '36474'),
  (150, 'ABDULAHAD DAHIRU MUHAMMAD', '36475'),
  (151, 'SHAFI''U LAWALI', '36476'),
  (152, 'SADIQU JAMILU', '36477'),
  (153, 'MUHAMMAD RABI''U', '36478'),
  (154, 'SADIK USMAN', '36479'),
  (155, 'ABDURRAHMAN YUSUF', '36480'),
  (156, 'BASHIRU IBRAHIM', '36481'),
  (157, 'ABUBAKAR ALIYU', '36482'),
  (158, 'AUWAL MUHAMMAD', '36483'),
  (159, 'ALIYU HUSSAINI', '36484'),
  (160, 'ALIYU ABBAS YAHUZA', '36485'),
  (161, 'MUS''AB AMINU SANI', '36486'),
  (162, 'YASIR ABUBAKAR', '36487'),
  (163, 'MARYAM IBRAHIM', '36488'),
  (164, 'ZAINAB IBRAHIM', '36489'),
  (165, 'UMAR SULAIMAN', '36490'),
  (166, 'ABDULKAHHAR SURAJO JELANI', '36491'),
  (167, 'UKASHA SURAJO', '36492'),
  (168, 'AHMAD ABDULLAHI SHEHU', '36493'),
  (169, 'AMINU SALISU', '36494'),
  (170, 'IBRAHIM AHMAD', '36495'),
  (171, 'SAMUEL OGAH STEPHEN', '36496'),
  (172, 'MURTALA ALIYU', '36497'),
  (173, 'ZAYYANU IBRAHIM MARU', '36498'),
  (174, 'BASHIR SANI', '36499'),
  (175, 'HUSSAINI ALMUSTAPHA MUHAMMAD', '36500'),
  (176, 'MALIKI BASHAR MAI LAFIYA', '36501'),
  (177, 'SHAMSIYA MUHAMMAD', '36502'),
  (178, 'SHARIF ABUBAKAR AHMAD', '36503'),
  (179, 'AISHA BALA', '36504'),
  (180, 'ABDULRAHIM MANSUR', '36505'),
  (181, 'ABDUSSALAM MUHAMMAD DAN ASABE', '36506'),
  (182, 'USMAN MUHAMMAD', '36507'),
  (183, 'AHMAD ABUBAKAR UMAR', '36508'),
  (184, 'ABUBAKAR SHEHU', '36509'),
  (185, 'AHMAD SALISU', '36510'),
  (186, 'ALIYU ABDULLAHI MAI KAJI', '36511'),
  (187, 'HUZAIFA IDRIS', '36512'),
  (188, 'BILAL MUHAMMAD', '36513'),
  (189, 'BELLO ABDULLAHI', '36514'),
  (190, 'ABRARA ABUBAKAR', '36515'),
  (191, 'AL-AMIN AMINU', '36516'),
  (192, 'ABDULLAHI ISMAIL', '36517'),
  (193, 'ABUBAKAR BELLO', '36518'),
  (194, 'HARUNA YOHANNA MUSA', '36519'),
  (195, 'AHMAD ABUBAKAR', '36520'),
  (196, 'IMRANA TUKUR', '36521'),
  (197, 'IBRAHIM YAHAYA', '36522'),
  (198, 'MARYAM UMAR', '36523'),
  (199, 'BELLO MUSA', '36524'),
  (200, 'ABUBAKAR ABDULLAHI', '36525'),
  (201, 'SULEIMAN HUSSAINI', '36526'),
  (202, 'ABDULRAHMAN BELLO', '36527'),
  (203, 'AL-AMIN YUSUF', '36528'),
  (204, 'ATTAHIRU IBRAHIM', '36529'),
  (205, 'ABUBAKAR FARUK GARBA', '36530'),
  (206, 'HABIBU AMINU MATAWALLE', '36531'),
  (207, 'MUHAMMAD ISHAKA UMAR', '36532'),
  (208, 'ABUBAKAR MUHAMMAD MODE', '36533'),
  (209, 'GAZALI ALIYU SANI', '36534'),
  (210, 'MUSA GALADIMA', '36535'),
  (211, 'ALIYU AHMAD', '36536'),
  (212, 'ABDULLAHI MUHAMMAD', '36537'),
  (213, 'MISBAHU MUHAMMAD AUWAL', '36538'),
  (214, 'YAZIDU SANI', '36539'),
  (215, 'MUHAMMAD MUNIR KABUGA', '36540')
) as v(serial, name, adm_no)
where lower(d.name) = 'computer science'
on conflict do nothing;

-- make the API see the new tables / functions immediately
notify pgrst, 'reload schema';

-- Check:  should show 215 for Computer Science
select d.name as department, count(s.id) as students
from public.departments d left join public.students s on s.department_id = d.id
group by d.name order by d.name;
