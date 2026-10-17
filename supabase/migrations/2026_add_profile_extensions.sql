-- Vibra Music: Add extended profile fields for country, age, status bubble, and banner playlists

alter table public.profiles
  add column if not exists country text default '',
  add column if not exists age int,
  add column if not exists status_bubble text default '',
  add column if not exists banner_playlists jsonb default '[]'::jsonb;
