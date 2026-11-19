-- YanN Chat: aman dijalankan berkali-kali (reset dulu, lalu buat ulang).
-- PERINGATAN: baris RESET di bawah menghapus semua profil & pesan yang ada.
-- Sebelumnya: Authentication > Providers > Email > matikan "Confirm email"

-- ===== RESET =====
drop trigger if exists on_auth_user_created on auth.users;
drop table if exists public.messages cascade;
drop table if exists public.profiles cascade;
drop function if exists public.handle_new() cascade;
drop function if exists public.guard() cascade;
drop function if exists public.is_dev() cascade;
drop policy if exists "voice upload" on storage.objects;
-- ===== BUAT ULANG =====

create table public.profiles(
  id uuid primary key references auth.users on delete cascade,
  code text unique not null,
  name text not null,
  bio text default '',
  verified boolean default false,
  premium boolean default false,
  is_dev boolean default false,
  banned boolean default false,
  badge text,
  created_at timestamptz default now()
);
alter table public.profiles enable row level security;

create function public.is_dev() returns boolean language sql security definer
set search_path=public stable as $$
  select coalesce((select is_dev from public.profiles where id=auth.uid()),false) $$;

create policy "read all" on public.profiles for select to authenticated using(true);
create policy "update own" on public.profiles for update to authenticated
  using(id=auth.uid()) with check(id=auth.uid());
create policy "dev update" on public.profiles for update to authenticated
  using(public.is_dev()) with check(true);

-- user biasa tidak bisa mengubah badge/status sendiri (auth.uid() null = SQL Editor, boleh)
create function public.guard() returns trigger language plpgsql security definer
set search_path=public as $$
begin
  if auth.uid() is not null and not public.is_dev() then
    new.verified:=old.verified; new.premium:=old.premium; new.is_dev:=old.is_dev;
    new.banned:=old.banned; new.badge:=old.badge; new.code:=old.code;
  end if;
  return new;
end $$;
create trigger guard_profiles before update on public.profiles
  for each row execute function public.guard();

create function public.handle_new() returns trigger language plpgsql security definer
set search_path=public,auth as $$
begin
  insert into public.profiles(id,code,name)
  values(new.id, upper(split_part(new.email,'@',1)), coalesce(new.raw_user_meta_data->>'name','User'));
  return new;
end $$;
create trigger on_auth_user_created after insert on auth.users
  for each row execute function public.handle_new();

create table public.messages(
  id bigint generated always as identity primary key,
  from_id uuid not null default auth.uid() references public.profiles(id) on delete cascade,
  to_id uuid not null references public.profiles(id) on delete cascade,
  kind text not null default 'text' check(kind in('text','sticker','voice')),
  body text default '',
  url text,
  dur int,
  created_at timestamptz default now()
);
create index on public.messages(to_id,created_at);
create index on public.messages(from_id,created_at);
alter table public.messages enable row level security;
create policy "send" on public.messages for insert to authenticated
  with check(from_id=auth.uid() and not exists(select 1 from public.profiles where id=auth.uid() and banned));
create policy "read own" on public.messages for select to authenticated
  using(from_id=auth.uid() or to_id=auth.uid());

do $$ begin
  begin alter publication supabase_realtime add table public.messages; exception when duplicate_object then null; end;
  begin alter publication supabase_realtime add table public.profiles; exception when duplicate_object then null; end;
end $$;

-- penyimpanan pesan suara
insert into storage.buckets(id,name,public) values('voice','voice',true) on conflict do nothing;
create policy "voice upload" on storage.objects for insert to authenticated
  with check(bucket_id='voice' and (storage.foldername(name))[1]=auth.uid()::text);

-- JADIKAN AKUNMU DEVELOPER (daftar dulu di aplikasi, lalu ganti kodenya):
-- update public.profiles set is_dev=true, verified=true where code='YN-126072';

-- izin akses (penting di project baru)
alter function public.handle_new() owner to postgres;
grant usage on schema public to supabase_auth_admin, authenticated;
grant execute on function public.handle_new() to supabase_auth_admin;
grant all on public.profiles to supabase_auth_admin;
grant select, update on public.profiles to authenticated;
grant select, insert on public.messages to authenticated;
grant usage, select on all sequences in schema public to authenticated;
