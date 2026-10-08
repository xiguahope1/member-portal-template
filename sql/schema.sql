-- Member Portal: database setup for Supabase
-- Run this once in the Supabase SQL editor. Then create two PRIVATE storage buckets
-- named `library` and `agreements`, and add yourself as an admin (see the bottom of this file).

create extension if not exists pgcrypto;

-- ===================== Tables =====================

create table if not exists public.admins (
  user_id uuid primary key references auth.users(id) on delete cascade
);

create sequence if not exists public.member_code_seq;

create table if not exists public.members (
  id                  uuid primary key default gen_random_uuid(),
  user_id             uuid unique references auth.users(id) on delete set null,
  member_code         text unique not null default ('M-' || lpad(nextval('public.member_code_seq')::text, 4, '0')),
  email               text unique not null,
  name                text not null default '',
  preferred           text default '',
  phone               text default '',
  university          text default '',
  chapter             text default '',
  timezone            text default '',
  linkedin            text default '',
  country             text default '',
  first_participation text default '',
  adult               text default '' check (adult in ('', 'yes', 'no')),
  vertical            text default '',
  division            text default '',
  role                text default '',
  approved            boolean not null default false,
  approved_at         timestamptz,
  revoked             boolean not null default false,
  revoked_at          timestamptz,
  signed_at           timestamptz,
  signed_name         text,
  signature           text,
  nda_version         text,
  nda_path            text,
  handbook_at         timestamptz,
  source              text not null default 'self',
  created_at          timestamptz not null default now(),
  updated_at          timestamptz not null default now()
);

create table if not exists public.resources (
  id             uuid primary key default gen_random_uuid(),
  title          text not null,
  description    text default '',
  division       text not null default 'All',
  file_path      text not null unique,
  file_name      text,
  file_type      text,
  file_size      bigint,
  allow_download boolean not null default false,
  created_at     timestamptz not null default now()
);

create table if not exists public.access_logs (
  id             bigint generated always as identity primary key,
  member_id      uuid references public.members(id) on delete set null,
  member_name    text,
  member_code    text,
  resource_id    uuid references public.resources(id) on delete set null,
  resource_title text,
  action         text not null check (action in ('view', 'download')),
  created_at     timestamptz not null default now()
);

-- ===================== Helper functions =====================

create or replace function public.is_admin() returns boolean
language sql stable security definer set search_path = public as $$
  select exists (select 1 from public.admins where user_id = auth.uid());
$$;

-- Links a signed-in user to a member row an admin created for their email.
create or replace function public.claim_member() returns void
language sql security definer set search_path = public as $$
  update public.members
     set user_id = auth.uid()
   where user_id is null
     and lower(email) = lower(auth.jwt() ->> 'email');
$$;

-- True when the current user is an active member allowed to see a given division.
create or replace function public.can_read_division(div text) returns boolean
language sql stable security definer set search_path = public as $$
  select exists (
    select 1 from public.members m
     where m.user_id = auth.uid()
       and m.approved and not m.revoked and m.signed_at is not null
       and (div = 'All' or div = m.division
            or (div = 'All Research' and m.vertical = 'Research')
            or (div = 'All Growth'   and m.vertical = 'Growth'))
  );
$$;

-- ===================== Triggers =====================

-- Members can edit their own details, but not their status, role or signature record.
create or replace function public.members_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  new.updated_at := now();
  -- Admins, and edits made from the dashboard or server (no signed-in user), skip the checks.
  if public.is_admin() or auth.uid() is null then return new; end if;

  if new.approved    is distinct from old.approved    or new.approved_at is distinct from old.approved_at
  or new.revoked     is distinct from old.revoked     or new.revoked_at  is distinct from old.revoked_at
  or new.vertical    is distinct from old.vertical    or new.division    is distinct from old.division
  or new.role        is distinct from old.role        or new.email       is distinct from old.email
  or new.member_code is distinct from old.member_code or new.user_id     is distinct from old.user_id
  or new.source      is distinct from old.source then
    raise exception 'permission denied';
  end if;

  if new.signed_at is distinct from old.signed_at
  or new.signature is distinct from old.signature
  or new.signed_name is distinct from old.signed_name
  or new.nda_path is distinct from old.nda_path then
    if old.signed_at is not null then raise exception 'Already signed'; end if;
    if not old.approved then raise exception 'The team has not approved you yet'; end if;
    if old.revoked then raise exception 'permission denied'; end if;
    if coalesce(old.adult, '') <> 'yes' then raise exception 'Members under 18 need a guardian to sign'; end if;
    if coalesce(old.name,'') = '' or coalesce(old.phone,'') = '' or coalesce(old.university,'') = ''
    or coalesce(old.chapter,'') = '' or coalesce(old.country,'') = '' or coalesce(old.timezone,'') = ''
    or coalesce(old.first_participation,'') = '' then
      raise exception 'Complete your details before signing';
    end if;
    new.signed_at := now();
  end if;
  return new;
end $$;

drop trigger if exists members_guard on public.members;
create trigger members_guard before update on public.members
  for each row execute function public.members_guard();

-- Self sign-ups always start unapproved and unsigned.
create or replace function public.members_insert_guard() returns trigger
language plpgsql security definer set search_path = public as $$
begin
  if not public.is_admin() and auth.uid() is not null then
    new.user_id := auth.uid();
    new.email := lower(auth.jwt() ->> 'email');
    new.approved := false; new.approved_at := null;
    new.revoked := false;  new.revoked_at := null;
    new.signed_at := null; new.signature := null; new.signed_name := null; new.nda_path := null;
    new.source := 'self';
  end if;
  return new;
end $$;

drop trigger if exists members_insert_guard on public.members;
create trigger members_insert_guard before insert on public.members
  for each row execute function public.members_insert_guard();

-- Fills in who opened the file, so members can't log on someone else's behalf.
create or replace function public.access_logs_fill() returns trigger
language plpgsql security definer set search_path = public as $$
declare m public.members;
begin
  select * into m from public.members where user_id = auth.uid();
  if m.id is null then raise exception 'permission denied'; end if;
  new.member_id := m.id; new.member_name := m.name; new.member_code := m.member_code;
  new.created_at := now();
  return new;
end $$;

drop trigger if exists access_logs_fill on public.access_logs;
create trigger access_logs_fill before insert on public.access_logs
  for each row execute function public.access_logs_fill();

-- ===================== Row-level security =====================

alter table public.admins      enable row level security;
alter table public.members     enable row level security;
alter table public.resources   enable row level security;
alter table public.access_logs enable row level security;

drop policy if exists "admins: admin read" on public.admins;
create policy "admins: admin read" on public.admins for select using (public.is_admin());

drop policy if exists "members: read own or admin" on public.members;
create policy "members: read own or admin" on public.members for select
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "members: insert self or admin" on public.members;
create policy "members: insert self or admin" on public.members for insert
  with check (public.is_admin() or not exists (select 1 from public.members where user_id = auth.uid()));

drop policy if exists "members: update own or admin" on public.members;
create policy "members: update own or admin" on public.members for update
  using (user_id = auth.uid() or public.is_admin());

drop policy if exists "members: admin delete" on public.members;
create policy "members: admin delete" on public.members for delete using (public.is_admin());

drop policy if exists "resources: active members or admin read" on public.resources;
create policy "resources: active members or admin read" on public.resources for select
  using (public.is_admin() or public.can_read_division(division));

drop policy if exists "resources: admin write" on public.resources;
create policy "resources: admin write" on public.resources for all
  using (public.is_admin()) with check (public.is_admin());

drop policy if exists "access_logs: members insert" on public.access_logs;
create policy "access_logs: members insert" on public.access_logs for insert
  with check (exists (select 1 from public.members where user_id = auth.uid()));

drop policy if exists "access_logs: admin read" on public.access_logs;
create policy "access_logs: admin read" on public.access_logs for select using (public.is_admin());

-- ===================== Storage =====================
-- Create the `library` and `agreements` buckets first (Storage > New bucket, keep "Public" off).

drop policy if exists "library: read if resource visible" on storage.objects;
create policy "library: read if resource visible" on storage.objects for select
  using (bucket_id = 'library' and exists (select 1 from public.resources r where r.file_path = storage.objects.name));

drop policy if exists "library: admin write" on storage.objects;
create policy "library: admin write" on storage.objects for all
  using (bucket_id = 'library' and public.is_admin())
  with check (bucket_id = 'library' and public.is_admin());

drop policy if exists "agreements: own folder upload" on storage.objects;
create policy "agreements: own folder upload" on storage.objects for insert
  with check (bucket_id = 'agreements' and (storage.foldername(name))[1] = auth.uid()::text);

drop policy if exists "agreements: own or admin read" on storage.objects;
create policy "agreements: own or admin read" on storage.objects for select
  using (bucket_id = 'agreements' and ((storage.foldername(name))[1] = auth.uid()::text or public.is_admin()));

-- ===================== Realtime =====================

alter publication supabase_realtime add table public.members, public.resources;

-- ===================== Make yourself an admin =====================
-- Sign up through the portal first, then run (with your own email):
--   insert into public.admins (user_id) select id from auth.users where email = 'you@example.com';

-- ===================== Admin: create a member's login =====================
-- Used by the "Add member" button. It creates a confirmed login with the starting password
-- (keep it in sync with DEFAULT_TEMP_PASSWORD in index.html) and flags it so the member
-- must choose their own password on first login.
-- Note: this writes to Supabase's auth schema directly. It works on current Supabase projects,
-- but it isn't an official API. The alternative is inviting users from the dashboard.
create or replace function public.admin_create_login(p_email text, p_name text default '')
returns jsonb language plpgsql security definer set search_path = public, auth, extensions as $$
declare
  v_email text := lower(trim(p_email));
  v_id uuid;
  v_password text := 'ChangeMe-2026!';
begin
  if not public.is_admin() then raise exception 'permission denied'; end if;
  select id into v_id from auth.users where lower(email) = v_email;
  if v_id is not null then
    update public.members set user_id = v_id where lower(email) = v_email and user_id is null;
    return jsonb_build_object('created', false);
  end if;
  v_id := gen_random_uuid();
  insert into auth.users (instance_id, id, aud, role, email, encrypted_password, email_confirmed_at,
                          raw_app_meta_data, raw_user_meta_data, created_at, updated_at,
                          confirmation_token, recovery_token, email_change_token_new, email_change)
  values ('00000000-0000-0000-0000-000000000000', v_id, 'authenticated', 'authenticated', v_email,
          crypt(v_password, gen_salt('bf')), now(),
          '{"provider":"email","providers":["email"]}',
          jsonb_build_object('name', p_name, 'must_change_password', true),
          now(), now(), '', '', '', '');
  insert into auth.identities (id, user_id, provider_id, identity_data, provider, last_sign_in_at, created_at, updated_at)
  values (gen_random_uuid(), v_id, v_id::text, jsonb_build_object('sub', v_id::text, 'email', v_email),
          'email', now(), now(), now());
  update public.members set user_id = v_id where lower(email) = v_email and user_id is null;
  return jsonb_build_object('created', true);
end $$;
