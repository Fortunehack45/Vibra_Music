-- Vibra Music: Supabase Schema Migration for Social Layer, Music Quiz, and User Cloud Sync
-- Note: NO music audio files are stored in this database. Only tracks metadata, playlist relations,
-- user preferences, and social interaction data are stored.

-- Enable extensions
create extension if not exists "uuid-ossp";
create extension if not exists "pgcrypto";

-- 1. Profiles Table
create table if not exists public.profiles (
    id text primary key, -- YouTube account_id / channel_id / email hash
    handle text unique not null,
    display_name text not null,
    avatar_url text,
    bio text default '',
    referral_code text unique not null,
    invited_by text references public.profiles(id),
    invites_count int default 0,
    quiz_lives int default 5,
    last_life_refill timestamptz default now(),
    is_unlimited_lives boolean default false,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

-- 2. User Listening Experience & Connected Spotify Settings
create table if not exists public.user_listening_experience (
    user_id text primary key references public.profiles(id) on delete cascade,
    spotify_spdc_token text,
    spotify_connected boolean default false,
    audio_quality text default 'HIGH',
    equalizer_enabled boolean default false,
    equalizer_preset text default 'FLAT',
    eq_bands jsonb default '[]'::jsonb,
    volume_normalization boolean default true,
    bass_boost_percent int default 0,
    virtualizer_percent int default 0,
    pitch_cents int default 0,
    tempo_multiplier real default 1.0,
    auto_skip_silence boolean default false,
    lyrics_source text default 'DEFAULT',
    canvas_enabled boolean default true,
    repeat_mode int default 0,
    shuffle_enabled boolean default false,
    preferred_genres jsonb default '[]'::jsonb,
    updated_at timestamptz default now()
);

-- 3. User Liked Music Tracks (Metadata only, NO audio bytes stored)
create table if not exists public.user_liked_tracks (
    id uuid primary key default gen_random_uuid(),
    user_id text not null references public.profiles(id) on delete cascade,
    video_id text not null,
    title text not null,
    artist text not null,
    thumbnail_url text,
    duration_text text,
    liked_at timestamptz default now(),
    unique (user_id, video_id)
);

-- 4. User Playlists (Metadata & Container)
create table if not exists public.user_playlists (
    id text primary key,
    user_id text not null references public.profiles(id) on delete cascade,
    title text not null,
    description text default '',
    thumbnail_url text,
    track_count int default 0,
    created_at timestamptz default now(),
    updated_at timestamptz default now()
);

-- 5. User Playlist Tracks (Metadata only, NO audio bytes stored)
create table if not exists public.user_playlist_tracks (
    id uuid primary key default gen_random_uuid(),
    playlist_id text not null references public.user_playlists(id) on delete cascade,
    user_id text not null references public.profiles(id) on delete cascade,
    video_id text not null,
    title text not null,
    artist text not null,
    thumbnail_url text,
    duration_text text,
    position int default 0,
    added_at timestamptz default now()
);

-- 6. Favorite Artists
create table if not exists public.favorite_artists (
    id uuid primary key default gen_random_uuid(),
    user_id text not null references public.profiles(id) on delete cascade,
    artist_id text not null,
    artist_name text not null,
    artist_artwork text,
    created_at timestamptz default now(),
    unique (user_id, artist_id)
);

-- 7. Social Posts (Feed)
create table if not exists public.posts (
    id text primary key,
    author_id text not null references public.profiles(id) on delete cascade,
    content text not null default '',
    image_url text,
    image_urls jsonb default '[]'::jsonb,
    video_url text,
    audio_url text,
    gif_url text,
    is_review boolean default false,
    rating int default 0,
    tagged_artist text,
    music_track jsonb, -- {videoId, title, artist, thumbnailUrl, durationText}
    poll_data jsonb, -- {question, options: [{id, text, votes}]}
    quiz_result jsonb, -- {artistId, artistName, artistAvatar, score, totalQuestions, timeSeconds, percentile}
    repost_of_id text references public.posts(id) on delete set null,
    quote_of_id text references public.posts(id) on delete set null,
    likes_count int default 0,
    comments_count int default 0,
    reposts_count int default 0,
    created_at timestamptz default now()
);

-- 8. Post Likes
create table if not exists public.post_likes (
    post_id text references public.posts(id) on delete cascade,
    user_id text references public.profiles(id) on delete cascade,
    created_at timestamptz default now(),
    primary key (post_id, user_id)
);

-- 9. Post Comments & Replies
create table if not exists public.post_comments (
    id text primary key,
    post_id text not null references public.posts(id) on delete cascade,
    author_id text not null references public.profiles(id) on delete cascade,
    parent_id text references public.post_comments(id) on delete cascade,
    content text not null,
    gif_url text,
    likes_count int default 0,
    created_at timestamptz default now()
);

-- 10. Poll Votes
create table if not exists public.poll_votes (
    id uuid primary key default gen_random_uuid(),
    post_id text not null references public.posts(id) on delete cascade,
    user_id text not null references public.profiles(id) on delete cascade,
    option_index int not null,
    created_at timestamptz default now(),
    unique (post_id, user_id)
);

-- 11. Direct Messages (DMs)
create table if not exists public.direct_messages (
    id text primary key,
    sender_id text not null references public.profiles(id) on delete cascade,
    receiver_id text not null references public.profiles(id) on delete cascade,
    content text not null default '',
    shared_music jsonb,
    shared_playlist jsonb,
    image_url text,
    video_url text,
    audio_url text,
    gif_url text,
    is_read boolean default false,
    created_at timestamptz default now()
);

-- 12. Friendships
create table if not exists public.friendships (
    id uuid primary key default gen_random_uuid(),
    requester_id text not null references public.profiles(id) on delete cascade,
    receiver_id text not null references public.profiles(id) on delete cascade,
    status text not null check (status in ('PENDING', 'ACCEPTED', 'DECLINED', 'BLOCKED')),
    created_at timestamptz default now(),
    updated_at timestamptz default now(),
    unique (requester_id, receiver_id)
);

-- 13. Follows
create table if not exists public.follows (
    follower_id text not null references public.profiles(id) on delete cascade,
    following_id text not null references public.profiles(id) on delete cascade,
    created_at timestamptz default now(),
    primary key (follower_id, following_id)
);

-- 14. Quiz Leaderboards
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

-- 15. Notifications
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

-- Performance Indexes
create index if not exists idx_posts_created_at on public.posts (created_at desc);
create index if not exists idx_posts_author on public.posts (author_id);
create index if not exists idx_liked_user on public.user_liked_tracks (user_id, liked_at desc);
create index if not exists idx_playlist_user on public.user_playlists (user_id);
create index if not exists idx_playlist_tracks on public.user_playlist_tracks (playlist_id, position);
create index if not exists idx_dms_conversation on public.direct_messages (sender_id, receiver_id, created_at desc);
create index if not exists idx_leaderboard_artist on public.quiz_leaderboards (artist_id, score desc, time_seconds asc);
create index if not exists idx_friendships_lookup on public.friendships (requester_id, receiver_id, status);
create index if not exists idx_notifications_user on public.notifications (user_id, created_at desc);

-- Enable Row Level Security (RLS) on all tables
alter table public.profiles enable row level security;
alter table public.user_listening_experience enable row level security;
alter table public.user_liked_tracks enable row level security;
alter table public.user_playlists enable row level security;
alter table public.user_playlist_tracks enable row level security;
alter table public.favorite_artists enable row level security;
alter table public.posts enable row level security;
alter table public.post_likes enable row level security;
alter table public.post_comments enable row level security;
alter table public.poll_votes enable row level security;
alter table public.direct_messages enable row level security;
alter table public.friendships enable row level security;
alter table public.follows enable row level security;
alter table public.quiz_leaderboards enable row level security;
alter table public.notifications enable row level security;

-- Client-side access policies using service anon key
create policy "Allow all on profiles" on public.profiles for all using (true) with check (true);
create policy "Allow all on user_listening_experience" on public.user_listening_experience for all using (true) with check (true);
create policy "Allow all on user_liked_tracks" on public.user_liked_tracks for all using (true) with check (true);
create policy "Allow all on user_playlists" on public.user_playlists for all using (true) with check (true);
create policy "Allow all on user_playlist_tracks" on public.user_playlist_tracks for all using (true) with check (true);
create policy "Allow all on favorite_artists" on public.favorite_artists for all using (true) with check (true);
create policy "Allow all on posts" on public.posts for all using (true) with check (true);
create policy "Allow all on post_likes" on public.post_likes for all using (true) with check (true);
create policy "Allow all on post_comments" on public.post_comments for all using (true) with check (true);
create policy "Allow all on poll_votes" on public.poll_votes for all using (true) with check (true);
create policy "Allow all on direct_messages" on public.direct_messages for all using (true) with check (true);
create policy "Allow all on friendships" on public.friendships for all using (true) with check (true);
create policy "Allow all on follows" on public.follows for all using (true) with check (true);
create policy "Allow all on quiz_leaderboards" on public.quiz_leaderboards for all using (true) with check (true);
create policy "Allow all on notifications" on public.notifications for all using (true) with check (true);

-- Enable Realtime replication on public tables
alter publication supabase_realtime add table public.posts;
alter publication supabase_realtime add table public.post_comments;
alter publication supabase_realtime add table public.direct_messages;
alter publication supabase_realtime add table public.quiz_leaderboards;
alter publication supabase_realtime add table public.user_listening_experience;
alter publication supabase_realtime add table public.notifications;
