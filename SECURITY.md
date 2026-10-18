# Security Policy

## Supported Versions

| Version | Supported          |
| ------- | ------------------ |
| 1.8.x   | Yes                |
| < 1.8   | No                 |

## Reporting a Vulnerability

If you discover a security vulnerability within Vibra Music, please report it responsibly rather than opening a public issue.
Contact the project maintainers directly via GitHub Security Advisories or private developer channels.

Please provide:
- A description of the issue.
- Steps to reproduce or proof-of-concept material.
- Assessment of potential impact.

Maintainers aim to acknowledge reports within 48 hours and coordinate remediation before public release.

---

## Secrets and Credentials Configuration

Vibra Music is designed to run without hardcoded production credentials, tokens, or encryption secrets committed to source control.

### Required Secrets

| Secret Key | Description | Source / Location |
| --- | --- | --- |
| `SUPABASE_URL` | Endpoint for Vibra Social and backend services | `local.properties` or environment variable |
| `SUPABASE_ANON_KEY` | Public anonymous key for Supabase API requests | `local.properties` or environment variable |
| `SPOTIFY_SPDC` | Optional session cookie for Spotify Canvas fallback | `local.properties` or Desktop Secret Store |
| `LASTFM_API_KEY` | Optional Last.fm API Key for scrobbling | `local.properties` or environment variable |
| `LASTFM_SECRET` | Optional Last.fm API Secret | `local.properties` or environment variable |

### Local Development Setup

1. Copy `secrets.properties.example` or append properties to your `local.properties`:
   ```properties
   SUPABASE_URL=https://your-project.supabase.co
   SUPABASE_ANON_KEY=your-supabase-anon-key
   SPOTIFY_SPDC=your-optional-token
   ```
2. Build the project normally with Gradle (`./gradlew assembleDebug`). The build script automatically maps these properties into `BuildConfig` fields without exposing them to git.

### CI/CD Setup (GitHub Actions)

When building releases in CI:
1. Navigate to repository **Settings > Secrets and variables > Actions**.
2. Add secrets for `SUPABASE_URL`, `SUPABASE_ANON_KEY`, and any optional keys.
3. In your workflow step, map them as environment variables during Gradle invocation:
   ```yaml
   env:
     SUPABASE_URL: ${{ secrets.SUPABASE_URL }}
     SUPABASE_ANON_KEY: ${{ secrets.SUPABASE_ANON_KEY }}
     SPOTIFY_SPDC: ${{ secrets.SPOTIFY_SPDC }}
   run: ./gradlew assembleRelease
   ```

---

## Credential Invalidation and Rotation Guide

If any credential was previously committed or exposed publicly in commit history:

### 1. Supabase Credentials
- **Rotate the Anon Key**: In the Supabase Dashboard, go to **Project Settings > API** and rotate your API keys.
- **Enforce Row Level Security (RLS)**: Ensure all tables (`profiles`, `posts`, `post_likes`, `post_replies`, `follows`, `direct_messages`) have strict RLS policies enabled. Anonymous keys should never be able to bypass row ownership checks.

### 2. Spotify Session Tokens (`sp_dc`)
- **Revoke Session**: Log out from all active web sessions on [Spotify Account Overview](https://www.spotify.com/account/overview/) by selecting "Sign out everywhere".
- Clear local stored tokens in app settings (`clearSpotifyWebSession()`).

### 3. Git History Sanitization
- Even after code removal, keys exist in prior commits. For public repositories, rotating the credentials server-side is mandatory. Use tools like `git-filter-repo` or BFG Repo-Cleaner if rewriting upstream git history is required.
