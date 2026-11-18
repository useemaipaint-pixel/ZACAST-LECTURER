-- =====================================================================
--  ZACAST  -  UPDATE v3.4: PROMOTE ND I -> ND II  +  ARCHIVE
--  (run this ONCE on your existing database)
--
--  Supabase Dashboard -> SQL Editor -> New query -> paste -> RUN.
--  It does NOT delete or change any student, course or attendance now.
--  Safe to run again.  Do NOT run supabase_setup.sql again.
--
--  What it adds:
--   * archive_batches : a table that keeps the finished ND II classes
--       (students + courses + attendance sessions + records, as a snapshot)
--   * admin_promote(p_base) : promotes ND I -> ND II in ONE step
--       (p_base = department name, or NULL = ALL departments)
--
--  What "Promote" does for each department (all or nothing - if anything
--  fails, NOTHING is changed):
--   1. the present ND II students are ARCHIVED (kept safely, never lost)
--   2. ND II is emptied (students + attendance) ready for the new class;
--      the ND II COURSES stay
--   3. ALL ND I students move to ND II
--   4. the old ND I attendance is saved inside the archive too, then ND I is
--      emptied (the ND I COURSES stay) ready for the new intake
-- =====================================================================

set search_path = public, extensions;

-- 1. Archive table ----------------------------------------------------
create table if not exists public.archive_batches (
  id               uuid primary key default gen_random_uuid(),
  department_name  text not null,
  department_code  text,
  label            text not null,
  student_count    int  not null default 0,
  data             jsonb not null default '{}'::jsonb,
  archived_at      timestamptz not null default now()
);
create index if not exists archive_batches_dept_idx on public.archive_batches (lower(department_name), archived_at desc);

alter table public.archive_batches enable row level security;
drop policy if exists "admin only" on public.archive_batches;
create policy "admin only" on public.archive_batches for all to anon, authenticated
  using (public.is_admin()) with check (public.is_admin());
grant select, insert, update, delete on public.archive_batches to anon, authenticated;

-- 2. Promote function -------------------------------------------------
create or replace function public.admin_promote(p_base text default null)
returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare
  r         record;
  d1        uuid;
  d2        uuid;
  n_prom    int;
  n_arch    int;
  snap      jsonb;
  tot_prom  int := 0;
  tot_arch  int := 0;
  tot_dept  int := 0;
  detail    jsonb := '[]'::jsonb;
begin
  if not public.is_admin() then
    raise exception 'Not logged in' using errcode = '42501';
  end if;

  for r in
    select distinct on (lower(name)) name, code
      from public.departments
     where p_base is null or lower(name) = lower(p_base)
     order by lower(name), created_at
  loop
    select id into d1 from public.departments where lower(name) = lower(r.name) and level = 'ND I';
    select id into d2 from public.departments where lower(name) = lower(r.name) and level = 'ND II';
    continue when d1 is null or d2 is null;

    n_arch := (select count(*) from public.students where department_id = d2);
    n_prom := (select count(*) from public.students where department_id = d1);
    continue when n_arch = 0 and n_prom = 0;   -- nothing to do for this department

    -- (1) archive the finishing ND II class (+ the old ND I attendance)
    if n_arch > 0 or exists (select 1 from public.attendance_sessions where department_id = d1) then
      snap := jsonb_build_object(
        'students', coalesce((select jsonb_agg(to_jsonb(s) order by s.serial) from public.students s where s.department_id = d2), '[]'::jsonb),
        'courses',  coalesce((select jsonb_agg(to_jsonb(c)) from public.courses c where c.department_id = d2), '[]'::jsonb),
        'sessions', coalesce((select jsonb_agg(to_jsonb(a)) from public.attendance_sessions a where a.department_id = d2), '[]'::jsonb),
        'records',  coalesce((select jsonb_agg(to_jsonb(t)) from public.attendance_records t where t.department_id = d2), '[]'::jsonb),
        'year1', jsonb_build_object(
          'students', coalesce((select jsonb_agg(to_jsonb(s) order by s.serial) from public.students s where s.department_id = d1), '[]'::jsonb),
          'courses',  coalesce((select jsonb_agg(to_jsonb(c)) from public.courses c where c.department_id = d1), '[]'::jsonb),
          'sessions', coalesce((select jsonb_agg(to_jsonb(a)) from public.attendance_sessions a where a.department_id = d1), '[]'::jsonb),
          'records',  coalesce((select jsonb_agg(to_jsonb(t)) from public.attendance_records t where t.department_id = d1), '[]'::jsonb)
        )
      );
      insert into public.archive_batches (department_name, department_code, label, student_count, data)
      values (r.name, r.code,
              case when n_arch > 0 then 'ND II graduates - ' else 'ND I attendance (before promotion) - ' end || to_char(now(), 'DD Mon YYYY'),
              n_arch, snap);
    end if;

    -- (2) empty ND II (students + attendance); its courses stay
    delete from public.attendance_records  where department_id = d2;
    delete from public.attendance_sessions where department_id = d2;
    delete from public.students            where department_id = d2;

    -- (3) ND I students become ND II students
    update public.students set department_id = d2 where department_id = d1;

    -- (4) empty ND I attendance (already saved in the archive); courses stay
    delete from public.attendance_records  where department_id = d1;
    delete from public.attendance_sessions where department_id = d1;

    tot_prom := tot_prom + n_prom;
    tot_arch := tot_arch + n_arch;
    tot_dept := tot_dept + 1;
    detail := detail || jsonb_build_array(jsonb_build_object('department', r.name, 'promoted', n_prom, 'archived', n_arch));
  end loop;

  return json_build_object('ok', true, 'departments', tot_dept, 'promoted', tot_prom, 'archived', tot_arch, 'detail', detail);
end;
$$;

revoke all on function public.admin_promote(text) from public;
grant execute on function public.admin_promote(text) to anon, authenticated;

notify pgrst, 'reload schema';

-- Check
select count(*) as archived_classes from public.archive_batches;
