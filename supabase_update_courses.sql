-- =====================================================================
--  ZACAST  -  UPDATE: COURSES  (run this ONCE on your existing database)
--
--  Supabase Dashboard -> SQL Editor -> New query -> paste -> RUN.
--  It does NOT delete or change any student, department or attendance.
--  Safe to run again.
--
--  What it adds:
--   * a "courses" table (every department has its own courses)
--   * a course_id on each attendance (attendance is always for ONE course)
--   * old attendances that had a course typed in are linked to a course
--     automatically (a course is created for each name used before)
-- =====================================================================

set search_path = public, extensions;

-- 1. Courses (each belongs to ONE department)
create table if not exists public.courses (
  id             uuid primary key default gen_random_uuid(),
  department_id  uuid not null references public.departments(id) on delete cascade,
  code           text not null,
  title          text,
  created_at     timestamptz not null default now()
);
create unique index if not exists courses_code_uq on public.courses (department_id, lower(code));
create index if not exists courses_dept_idx on public.courses (department_id);

-- 2. Every attendance can belong to a course
--    (deleting a course keeps its attendance records, they just become "not linked")
alter table public.attendance_sessions
  add column if not exists course_id uuid references public.courses(id) on delete set null;
create index if not exists att_sessions_course_idx on public.attendance_sessions (course_id);

-- 3. Security: only the logged-in admin can use courses
alter table public.courses enable row level security;
drop policy if exists "admin only" on public.courses;
create policy "admin only" on public.courses for all to anon, authenticated
  using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.courses to anon, authenticated;

-- 4. Link OLD attendances that already had a course name typed in
insert into public.courses (department_id, code)
select distinct on (department_id, lower(trim(course))) department_id, trim(course)
from public.attendance_sessions
where trim(course) <> '' and course_id is null
order by department_id, lower(trim(course)), created_at
on conflict do nothing;

update public.attendance_sessions s
   set course_id = c.id,
       course    = c.code
  from public.courses c
 where s.course_id is null
   and trim(s.course) <> ''
   and c.department_id = s.department_id
   and lower(c.code) = lower(trim(s.course));

-- make the API see the new table / column immediately
notify pgrst, 'reload schema';

-- Check: courses per department
select d.name as department, count(c.id) as courses
from public.departments d left join public.courses c on c.department_id = d.id
group by d.name order by d.name;
