-- Supabase-compatible shim, so `schema.sql` can be applied to a plain
-- PostgreSQL server and tested without a Supabase project.
--
-- Why this file exists: `schema.sql` is the thing that actually ships, and the
-- interesting parts of it — the RLS policies and `upsert_memo`'s coalesce
-- logic — are exactly the kind of code that fails silently. A wrong policy
-- does not raise; it returns other people's rows. The only way to know is to
-- run the real SQL on a real server, so everything Supabase would normally
-- provide is recreated here and nothing in `schema.sql` is modified.
--
-- The definitions below follow Supabase's own, in particular:
--
--  * `auth.uid()` reads the request's JWT claims out of a session GUC, which
--    is what lets a test impersonate a user with `set local request.jwt.claims`.
--  * `storage.foldername()` returns the path segments *excluding* the
--    filename, so `foldername('<uid>/<memo>.m4a')[1]` is the owner.
--
-- Tests must `set role authenticated`: RLS is bypassed for superusers and for
-- the table owner, so running as `postgres` would make every policy assertion
-- pass regardless of whether the policies are correct.

create extension if not exists "pgcrypto";

-- ---------------------------------------------------------------------------
-- Roles Supabase exposes to clients
-- ---------------------------------------------------------------------------

do $$
begin
    if not exists (select 1 from pg_roles where rolname = 'anon') then
        create role anon nologin noinherit;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'authenticated') then
        create role authenticated nologin noinherit;
    end if;
    if not exists (select 1 from pg_roles where rolname = 'service_role') then
        create role service_role nologin noinherit bypassrls;
    end if;
end
$$;

-- ---------------------------------------------------------------------------
-- auth
-- ---------------------------------------------------------------------------

create schema if not exists auth;

create table if not exists auth.users (
    id    uuid primary key default gen_random_uuid(),
    email text unique
);

-- Supabase's definition, kept verbatim in behaviour: the sub claim of the
-- request's JWT, or null when unauthenticated. Returning null matters — every
-- policy compares `auth.uid() = user_id`, and null never equals anything, so
-- an unauthenticated request sees nothing rather than everything.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
    select coalesce(
        nullif(current_setting('request.jwt.claim.sub', true), ''),
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'sub')
    )::uuid
$$;

create or replace function auth.role()
returns text
language sql
stable
as $$
    select coalesce(
        nullif(current_setting('request.jwt.claim.role', true), ''),
        (nullif(current_setting('request.jwt.claims', true), '')::jsonb ->> 'role')
    )::text
$$;

-- ---------------------------------------------------------------------------
-- storage
-- ---------------------------------------------------------------------------

create schema if not exists storage;

create table if not exists storage.buckets (
    id                 text primary key,
    name               text not null,
    public             boolean default false,
    file_size_limit    bigint,
    allowed_mime_types text[],
    created_at         timestamptz default now()
);

create table if not exists storage.objects (
    id         uuid primary key default gen_random_uuid(),
    bucket_id  text references storage.buckets (id),
    name       text,
    owner      uuid,
    created_at timestamptz default now(),
    metadata   jsonb
);

alter table storage.objects enable row level security;

-- Path segments minus the filename, matching Supabase.
create or replace function storage.foldername(name text)
returns text[]
language plpgsql
immutable
as $$
declare
    parts text[];
begin
    select string_to_array(name, '/') into parts;
    return parts[1 : array_length(parts, 1) - 1];
end
$$;

-- ---------------------------------------------------------------------------
-- Grants Supabase applies for the client roles
-- ---------------------------------------------------------------------------

grant usage on schema public, auth, storage to anon, authenticated, service_role;
grant select on auth.users to authenticated, service_role;

grant select, insert, update, delete on storage.objects
    to anon, authenticated, service_role;
grant select on storage.buckets to anon, authenticated, service_role;

-- Applied again after schema.sql, since public.memos does not exist yet.
