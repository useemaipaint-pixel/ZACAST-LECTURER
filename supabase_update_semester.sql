-- ZACAST - move EXISTING attendance to Second Semester (run ONCE)
-- Safe: it only runs the first time; running it again changes nothing.
create table if not exists public.zacast_migrations (name text primary key, done_at timestamptz default now());
alter table public.zacast_migrations enable row level security;

do $$
begin
  if not exists (select 1 from public.zacast_migrations where name = 'existing_to_second_semester') then
    update public.attendance_sessions set semester = 'Second Semester';
    insert into public.zacast_migrations (name) values ('existing_to_second_semester');
  end if;
end $$;

notify pgrst, 'reload schema';
select semester, count(*) as attendances from public.attendance_sessions group by semester;
