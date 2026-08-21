-- The parts of a fresh Supabase project that these migrations touch, and
-- nothing more. This is not a Supabase clone: it is the smallest environment in
-- which the schema's row-level security behaves the way it will in production.
--
-- What is faithful here (all of it is core Postgres, so it reproduces exactly):
-- the RLS engine, the auth.uid() definition, the API roles and which of them
-- carry BYPASSRLS, and RETURNING's interaction with the SELECT policy.
--
-- What is NOT modelled: GoTrue (identity linking, Apple's private relay, the
-- name-only-on-first-authorization behaviour), pg_cron, PostgREST's default
-- Prefer headers, and Supabase's exact GUC names in every edge case. Nothing in
-- these tests depends on any of them.

create extension if not exists pgcrypto;

grant usage on schema public to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on tables to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on functions to anon, authenticated, service_role;
alter default privileges in schema public
  grant all on sequences to anon, authenticated, service_role;

create schema if not exists auth;
grant usage on schema auth to anon, authenticated, service_role;

-- Only the columns the migrations read. Supabase's real auth.users has many
-- more, all of them irrelevant to this schema, which is the point of profiles.
create table if not exists auth.users (
  id uuid primary key default gen_random_uuid(),
  email text,
  raw_user_meta_data jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);

-- Supabase's auth.uid(): the `sub` claim of the request's JWT, read out of the
-- GUC PostgREST sets per request.
create or replace function auth.uid()
returns uuid
language sql
stable
as $$
  select nullif(
    coalesce(
      current_setting('request.jwt.claim.sub', true),
      (current_setting('request.jwt.claims', true)::jsonb ->> 'sub')
    ),
    ''
  )::uuid;
$$;

grant execute on function auth.uid() to anon, authenticated, service_role;
