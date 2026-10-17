-- Vibra Music: Add social layer columns, notifications table, and user preferences

alter table public.posts
  add column if not exists image_urls jsonb default '[]'::jsonb,
  add column if not exists video_url text,
  add column if not exists audio_url text,
  add column if not exists gif_url text,
  add column if not exists is_review boolean default false,
  add column if not exists rating int default 0,
  add column if not exists tagged_artist text;

alter table public.post_comments
  add column if not exists gif_url text;

alter table public.direct_messages
  add column if not exists shared_playlist jsonb,
  add column if not exists image_url text,
  add column if not exists video_url text,
  add column if not exists audio_url text,
  add column if not exists gif_url text;

alter table public.user_listening_experience
  add column if not exists preferred_genres jsonb default '[]'::jsonb;

-- Notifications table
create table if not exists public.notifications (
    id text primary key,
    user_id text not null references public.profiles(id) on delete cascade,
    actor_id text not null references public.profiles(id) on delete cascade,
    actor_name text not null default 'A listener',
    actor_avatar text,
    actor_handle text not null default '',
    type text not null default 'LIKE',
    target_post_id text references public.posts(id) on delete cascade,
    message text not null default '',
    is_read boolean default false,
    created_at timestamptz default now()
);

create index if not exists idx_notifications_user on public.notifications (user_id, created_at desc);

alter table public.notifications enable row level security;

do $$
begin
  if not exists (
    select 1 from pg_policies where schemaname = 'public' and tablename = 'notifications' and policyname = 'Allow all on notifications'
  ) then
    create policy "Allow all on notifications" on public.notifications for all using (true) with check (true);
  end if;
end $$;

-- Add notifications to realtime publication if not already present
do $$
begin
  if not exists (
    select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'notifications'
  ) then
    alter publication supabase_realtime add table public.notifications;
  end if;
end $$;
