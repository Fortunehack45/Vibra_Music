-- Vibra Music: Supabase Schema Migration for Social Layer & Music Quiz

-- Enable uuid generation
create extension if not exists "uuid-ossp";

-- 1. Profiles Table
create table if not exists public.profiles (
    id text primary key, -- YouTube account_id / channel_id
    handle text unique not null,
    display_name text not null,
    avatar_url text,
    bio text default '',
    favorite_artists jsonb default '[]'::jsonb,
    referral_code text unique not null,
    invited_by text references public.profiles(id),
    invites_count int default 0,
    quiz_lives int default 5,
    last_life_refill timestamptz default now(),
    is_unlimited_lives boolean default false,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

-- 2. Friendships
create table if not exists public.friendships (
    id uuid primary key default gen_random_uuid(),
    requester_id text not null references public.profiles(id) on delete cascade,
    receiver_id text not null references public.profiles(id) on delete cascade,
    status text not null check (status in ('pending', 'accepted', 'declined', 'blocked')),
    created_at timestamptz default now(),
    updated_at timestamptz default now(),
    unique (requester_id, receiver_id)
);

-- 3. Social Posts (Feed)
create table if not exists public.posts (
    id uuid primary key default gen_random_uuid(),
    author_id text not null references public.profiles(id) on delete cascade,
    content text not null,
    image_url text,
    music_track jsonb, -- {videoId, title, artist, thumbnailUrl, durationText}
    poll_data jsonb, -- {question, options: [{id, text, votes: [userId]}]}
    quiz_result jsonb, -- {artistId, artistName, artistAvatar, score, totalQuestions, timeSeconds, percentile}
    repost_of_id uuid references public.posts(id) on delete set null,
    quote_of_id uuid references public.posts(id) on delete set null,
    likes_count int default 0,
    comments_count int default 0,
    reposts_count int default 0,
    created_at timestamptz default now()
);

-- 4. Post Likes
create table if not exists public.post_likes (
    post_id uuid references public.posts(id) on delete cascade,
    user_id text references public.profiles(id) on delete cascade,
    created_at timestamptz default now(),
    primary key (post_id, user_id)
);

-- 5. Post Comments & Replies
create table if not exists public.post_comments (
    id uuid primary key default gen_random_uuid(),
    post_id uuid not null references public.posts(id) on delete cascade,
    author_id text not null references public.profiles(id) on delete cascade,
    parent_id uuid references public.post_comments(id) on delete cascade,
    content text not null,
    likes_count int default 0,
    created_at timestamptz default now()
);

-- 6. Direct Messages (DMs)
create table if not exists public.direct_messages (
    id uuid primary key default gen_random_uuid(),
    sender_id text not null references public.profiles(id) on delete cascade,
    receiver_id text not null references public.profiles(id) on delete cascade,
    content text not null,
    shared_music jsonb,
    is_read boolean default false,
    created_at timestamptz default now()
);

-- 7. Quiz Leaderboards
create table if not exists public.quiz_leaderboards (
    id uuid primary key default gen_random_uuid(),
    user_id text not null references public.profiles(id) on delete cascade,
    artist_id text not null,
    artist_name text not null,
    artist_avatar text,
    score int not null,
    total_questions int not null default 10,
    time_seconds numeric(8, 3) not null,
    percentile int default 50,
    created_at timestamptz default now()
);

-- Performance Indexes
create index if not exists idx_posts_created_at on public.posts (created_at desc);
create index if not exists idx_posts_author on public.posts (author_id);
create index if not exists idx_dms_conversation on public.direct_messages (sender_id, receiver_id, created_at desc);
create index if not exists idx_leaderboard_artist on public.quiz_leaderboards (artist_id, score desc, time_seconds asc);
create index if not exists idx_friendships_lookup on public.friendships (requester_id, receiver_id, status);

-- Enable Row Level Security (RLS)
alter table public.profiles enable row level security;
alter table public.friendships enable row level security;
alter table public.posts enable row level security;
alter table public.post_likes enable row level security;
alter table public.post_comments enable row level security;
alter table public.direct_messages enable row level security;
alter table public.quiz_leaderboards enable row level security;

-- Permissive public policies for client access using service anon key
create policy "Allow read on profiles" on public.profiles for select using (true);
create policy "Allow upsert on profiles" on public.profiles for all using (true);

create policy "Allow read on posts" on public.posts for select using (true);
create policy "Allow insert on posts" on public.posts for insert with check (true);
create policy "Allow update on posts" on public.posts for update using (true);

create policy "Allow read on post_likes" on public.post_likes for select using (true);
create policy "Allow all on post_likes" on public.post_likes for all using (true);

create policy "Allow read on post_comments" on public.post_comments for select using (true);
create policy "Allow insert on post_comments" on public.post_comments for insert with check (true);

create policy "Allow read on friendships" on public.friendships for select using (true);
create policy "Allow all on friendships" on public.friendships for all using (true);

create policy "Allow read on direct_messages" on public.direct_messages for select using (true);
create policy "Allow insert on direct_messages" on public.direct_messages for insert with check (true);
create policy "Allow update on direct_messages" on public.direct_messages for update using (true);

create policy "Allow read on quiz_leaderboards" on public.quiz_leaderboards for select using (true);
create policy "Allow insert on quiz_leaderboards" on public.quiz_leaderboards for insert with check (true);

-- Enable Realtime replication on public tables
alter publication supabase_realtime add table public.posts;
alter publication supabase_realtime add table public.post_comments;
alter publication supabase_realtime add table public.direct_messages;
alter publication supabase_realtime add table public.quiz_leaderboards;
