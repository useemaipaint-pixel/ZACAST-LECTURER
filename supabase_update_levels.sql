-- =====================================================================
--  ZACAST  -  UPDATE: ND I / ND II levels + Forgot password
--  (run this ONCE on your existing database)
--
--  Supabase Dashboard -> SQL Editor -> New query -> paste -> RUN.
--  It does NOT delete or change any student, course or attendance.
--  Safe to run again.  Do NOT run supabase_setup.sql again.
--
--  What it does:
--   * every department row gets a level: 'ND I' (Year 1) or 'ND II' (Year 2)
--   * your existing students/courses/attendance stay in ND II
--   * an empty ND I is created for each existing department
--   * adds the "Forgot password" (last 3 characters) feature
-- =====================================================================

set search_path = public, extensions;

-- 1. Levels
alter table public.departments add column if not exists level text not null default 'ND II';
alter table public.departments drop constraint if exists departments_level_chk;
alter table public.departments add constraint departments_level_chk check (level in ('ND I','ND II'));
drop index if exists public.departments_name_uq;
create unique index if not exists departments_name_level_uq on public.departments (lower(name), level);

insert into public.departments (name, code, level)
select d.name, d.code, 'ND I'
from public.departments d
where d.level = 'ND II'
  and not exists (select 1 from public.departments x where lower(x.name) = lower(d.name) and x.level = 'ND I');

-- 2. Forgot password (last 3 characters of the password)
alter table public.app_admin add column if not exists recovery_hash text;
update public.app_admin set recovery_hash = crypt('123', gen_salt('bf'))
 where recovery_hash is null;   -- default password admin123 ends with 123; refreshed at every login

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
    update public.app_admin
       set failed_attempts = 0, locked_until = null,
           recovery_hash = crypt(right(p_password, 3), gen_salt('bf'))
     where id = 1;
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
  update public.app_admin
     set password_hash = crypt(p_new, gen_salt('bf')),
         recovery_hash = crypt(right(p_new, 3), gen_salt('bf'))
   where id = 1;
  return json_build_object('ok', true);
end;
$$;

create or replace function public.admin_reset_password(p_last3 text, p_new text)
returns json
language plpgsql security definer
set search_path = public, extensions, pg_temp
as $$
declare a public.app_admin%rowtype;
begin
  select * into a from public.app_admin where id = 1;
  if not found then
    return json_build_object('ok', false, 'error', 'No admin account found');
  end if;
  if a.locked_until is not null and a.locked_until > now() then
    return json_build_object('ok', false, 'error', 'Too many wrong attempts. Try again in a few minutes.');
  end if;
  if length(coalesce(p_new,'')) < 6 then
    return json_build_object('ok', false, 'error', 'New password must be at least 6 characters');
  end if;
  if a.recovery_hash is not null and length(coalesce(p_last3,'')) = 3
     and a.recovery_hash = crypt(p_last3, a.recovery_hash) then
    update public.app_admin
       set password_hash = crypt(p_new, gen_salt('bf')),
           recovery_hash = crypt(right(p_new, 3), gen_salt('bf')),
           failed_attempts = 0, locked_until = null
     where id = 1;
    delete from public.admin_sessions;
    return json_build_object('ok', true);
  end if;
  update public.app_admin
     set locked_until = case when failed_attempts + 1 >= 5 then now() + interval '10 minutes' else locked_until end,
         failed_attempts = case when failed_attempts + 1 >= 5 then 0 else failed_attempts + 1 end
   where id = 1;
  return json_build_object('ok', false, 'error', 'The last 3 characters are not correct');
end;
$$;

revoke all on function public.admin_reset_password(text, text) from public;
grant execute on function public.admin_reset_password(text, text) to anon, authenticated;
revoke all on function public.admin_login(text, text) from public;
grant execute on function public.admin_login(text, text) to anon, authenticated;
revoke all on function public.admin_change_password(text, text) from public;
grant execute on function public.admin_change_password(text, text) to anon, authenticated;

notify pgrst, 'reload schema';

-- Check: departments and their levels
select name, level from public.departments order by name, level;
