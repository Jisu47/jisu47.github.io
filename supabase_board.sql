-- Supabase schema for a single public board.
--
-- Intended usage:
-- 1. Run this file in the Supabase SQL Editor.
-- 2. Read board items from public.board_feed.
-- 3. Insert public board items into public.board_posts with:
--      author_name
--      optional title
--      body
--      optional link_url
-- 4. Create pinned or hidden posts in the Dashboard / SQL Editor only.
--
-- Notes:
-- - This file is safe for a fresh setup and also migrates the earlier
--   guestbook/news split schema into a single board schema.
-- - Use only the Supabase anon public key in the browser.
-- - Never expose the service_role key in client code.

create extension if not exists pgcrypto;

do $$
begin
  if not exists (
    select 1
    from pg_type
    where typnamespace = 'public'::regnamespace
      and typname = 'board_status'
  ) then
    create type public.board_status as enum ('published', 'hidden');
  end if;
end
$$;

create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at = now();
  return new;
end;
$$;

revoke execute on function public.set_updated_at() from public;
revoke execute on function public.set_updated_at() from anon, authenticated;

create table if not exists public.board_posts (
  id uuid primary key default gen_random_uuid(),
  status public.board_status not null default 'published',
  is_pinned boolean not null default false,
  author_name text not null,
  title text null,
  body text not null,
  link_url text null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  published_at timestamptz not null default now(),
  metadata jsonb not null default '{}'::jsonb
);

alter table public.board_posts
  add column if not exists status public.board_status not null default 'published',
  add column if not exists is_pinned boolean not null default false,
  add column if not exists author_name text,
  add column if not exists title text,
  add column if not exists body text,
  add column if not exists link_url text,
  add column if not exists created_at timestamptz not null default now(),
  add column if not exists updated_at timestamptz not null default now(),
  add column if not exists published_at timestamptz not null default now(),
  add column if not exists metadata jsonb not null default '{}'::jsonb;

update public.board_posts
set
  status = coalesce(status, 'published'),
  is_pinned = coalesce(is_pinned, false),
  author_name = coalesce(nullif(btrim(author_name), ''), 'anonymous'),
  body = coalesce(nullif(btrim(body), ''), '[empty]'),
  published_at = coalesce(published_at, created_at, now()),
  created_at = coalesce(created_at, now()),
  updated_at = coalesce(updated_at, now()),
  metadata = coalesce(metadata, '{}'::jsonb)
where
  status is null
  or is_pinned is null
  or author_name is null
  or body is null
  or created_at is null
  or updated_at is null
  or published_at is null
  or metadata is null;

alter table public.board_posts
  alter column author_name set not null,
  alter column body set not null;

alter table public.board_posts
  drop constraint if exists board_posts_author_name_chk,
  drop constraint if exists board_posts_body_chk,
  drop constraint if exists board_posts_title_chk,
  drop constraint if exists board_posts_link_url_chk,
  drop constraint if exists board_posts_guestbook_title_chk;

alter table public.board_posts
  add constraint board_posts_author_name_chk
    check (char_length(btrim(author_name)) between 1 and 40),
  add constraint board_posts_body_chk
    check (char_length(btrim(body)) between 1 and 4000),
  add constraint board_posts_title_chk
    check (title is null or char_length(btrim(title)) between 1 and 120),
  add constraint board_posts_link_url_chk
    check (link_url is null or link_url ~* '^https?://');

drop index if exists board_posts_kind_idx;

create index if not exists board_posts_feed_idx
  on public.board_posts (status, is_pinned desc, published_at desc, created_at desc);

drop trigger if exists board_posts_set_updated_at on public.board_posts;

create trigger board_posts_set_updated_at
before update on public.board_posts
for each row
execute function public.set_updated_at();

alter table public.board_posts enable row level security;

drop policy if exists "public can read published board posts" on public.board_posts;
drop policy if exists "public can insert guestbook posts only" on public.board_posts;
drop policy if exists "public can insert board posts only" on public.board_posts;
drop policy if exists "public cannot update board posts" on public.board_posts;
drop policy if exists "public cannot delete board posts" on public.board_posts;

revoke all on table public.board_posts from anon, authenticated;
grant select, insert on table public.board_posts to anon, authenticated;

create policy "public can read published board posts"
on public.board_posts
for select
to anon, authenticated
using (status = 'published');

create policy "public can insert board posts only"
on public.board_posts
for insert
to anon, authenticated
with check (
  status = 'published'
  and is_pinned = false
  and char_length(btrim(author_name)) between 1 and 40
  and (title is null or char_length(btrim(title)) between 1 and 120)
  and char_length(btrim(body)) between 1 and 1000
  and (link_url is null or link_url ~* '^https?://')
  and metadata = '{}'::jsonb
  and created_at >= now() - interval '5 minutes'
  and created_at <= now() + interval '5 minutes'
  and updated_at >= now() - interval '5 minutes'
  and updated_at <= now() + interval '5 minutes'
  and published_at >= now() - interval '5 minutes'
  and published_at <= now() + interval '5 minutes'
);

create policy "public cannot update board posts"
on public.board_posts
for update
to anon, authenticated
using (false)
with check (false);

create policy "public cannot delete board posts"
on public.board_posts
for delete
to anon, authenticated
using (false);

drop view if exists public.board_feed;

create view public.board_feed
with (security_invoker = true) as
select
  id,
  author_name,
  title,
  body,
  link_url,
  is_pinned,
  created_at,
  published_at,
  coalesce(published_at, created_at) as sort_time
from public.board_posts
where status = 'published';

revoke all on table public.board_feed from anon, authenticated;
grant select on table public.board_feed to anon, authenticated;

alter table public.board_posts
  drop column if exists kind;

drop type if exists public.board_kind;

comment on table public.board_posts is
'Single board table for public posts on the personal site.';

comment on view public.board_feed is
'Public read-only feed view for the site board.';

insert into public.board_posts (
  author_name,
  title,
  body,
  is_pinned
)
select
  'Jisu47',
  'Board ready',
  'First pinned post for the unified board.',
  true
where not exists (
  select 1
  from public.board_posts
  where title = 'Board ready'
);

-- Example public insert:
-- insert into public.board_posts (author_name, title, body, link_url)
-- values ('visitor', 'Hello', 'Nice to meet you.', null);
--
-- Example public read:
-- select *
-- from public.board_feed
-- order by is_pinned desc, sort_time desc;
