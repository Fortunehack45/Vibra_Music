package com.fortune.vibramusic.data.supabase

import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Test

class SupabaseParsingTest {

    @Test
    fun `parsePosts handles post with all null attachments without returning null strings`() {
        val rawJson = """
            [
              {
                "id": "post-1",
                "author_id": "user-1",
                "content": "Just listening to music",
                "music_track": null,
                "poll_data": null,
                "image_urls": null,
                "image_url": null,
                "video_url": null,
                "audio_url": null,
                "gif_url": null,
                "profiles": null,
                "tagged_artist": null,
                "quote_of_id": null,
                "repost_of_id": null,
                "likes_count": 0,
                "comments_count": 0,
                "reposts_count": 0,
                "created_at": "2026-10-17T10:00:00Z"
              }
            ]
        """.trimIndent()

        val posts = SupabaseService.parsePosts(rawJson, currentUserId = "user-1")
        assertEquals(1, posts.size)

        val post = posts.first()
        assertEquals("post-1", post.id)
        assertEquals("user-1", post.authorId)
        assertEquals("Just listening to music", post.content)
        assertNull(post.musicTrack)
        assertNull(post.pollData)
        assertTrue(post.imageUrls.isEmpty())
        assertNull(post.imageUrl)
        assertNull(post.videoUrl)
        assertNull(post.audioUrl)
        assertNull(post.gifUrl)
        assertNull(post.author)
        assertNull(post.taggedArtist)
        assertNull(post.quoteOfId)
        assertNull(post.repostOfId)

        // Ensure literal "null" string never leaked
        assertNotEquals("null", post.videoUrl)
        assertNotEquals("null", post.audioUrl)
        assertNotEquals("null", post.gifUrl)
        assertNotEquals("null", post.imageUrl)
        assertNotEquals("null", post.taggedArtist)
    }

    @Test
    fun `parsePosts skips malformed row in a list of 3 posts and parses the other 2`() {
        val rawJson = """
            [
              {
                "id": "post-1",
                "author_id": "user-1",
                "content": "Post 1",
                "likes_count": 5
              },
              {
                "id": "post-2",
                "likes_count": "abc"
              },
              {
                "id": "post-3",
                "author_id": "user-3",
                "content": "Post 3",
                "likes_count": 12
              }
            ]
        """.trimIndent()

        val posts = SupabaseService.parsePosts(rawJson, currentUserId = "user-1")
        assertEquals(2, posts.size)
        assertEquals("post-1", posts[0].id)
        assertEquals("post-3", posts[1].id)
    }

    @Test
    fun `parsePosts parses populated music_track and poll_data correctly`() {
        val rawJson = """
            [
              {
                "id": "post-pop",
                "author_id": "user-2",
                "content": "Listen and vote!",
                "music_track": {
                  "video_id": "vid_xyz",
                  "title": "Midnight City",
                  "artist": "M83",
                  "thumbnail_url": "https://example.com/thumb.jpg",
                  "duration_text": "4:04"
                },
                "poll_data": {
                  "question": "Which synth lead is best?",
                  "options": [
                    { "text": "Option 1", "votes": 14 },
                    { "text": "Option 2", "votes": 26 }
                  ]
                },
                "profiles": {
                  "id": "user-2",
                  "handle": "synthwave",
                  "display_name": "Synth Wave",
                  "avatar_url": "https://example.com/avatar.jpg"
                }
              }
            ]
        """.trimIndent()

        val posts = SupabaseService.parsePosts(rawJson, currentUserId = "user-1")
        assertEquals(1, posts.size)

        val post = posts.first()
        val track = post.musicTrack
        assertNotNull(track)
        assertEquals("vid_xyz", track?.videoId)
        assertEquals("Midnight City", track?.title)
        assertEquals("M83", track?.artist)
        assertEquals("https://example.com/thumb.jpg", track?.thumbnailUrl)
        assertEquals("4:04", track?.durationText)

        val poll = post.pollData
        assertNotNull(poll)
        assertEquals("Which synth lead is best?", poll?.question)
        assertEquals(2, poll?.options?.size)
        assertEquals(40, poll?.totalVotes)
        assertEquals("Option 1", poll?.options?.get(0)?.text)
        assertEquals(14, poll?.options?.get(0)?.votes)

        val author = post.author
        assertNotNull(author)
        assertEquals("synthwave", author?.handle)
        assertEquals("Synth Wave", author?.displayName)
        assertEquals("https://example.com/avatar.jpg", author?.avatarUrl)
    }

    @Test
    fun `parseDirectMessages handles null attachments and extracts media tags`() {
        val rawJson = """
            [
              {
                "id": "dm-101",
                "sender_id": "user-1",
                "receiver_id": "user-2",
                "content": "[image:https://example.com/art.png] Check this album cover",
                "shared_music": null,
                "shared_playlist": null,
                "image_url": null,
                "video_url": null,
                "audio_url": null,
                "gif_url": null,
                "is_read": false,
                "created_at": "2026-10-17T10:15:00Z"
              }
            ]
        """.trimIndent()

        val dms = SupabaseService.parseDirectMessages(rawJson)
        assertEquals(1, dms.size)

        val dm = dms.first()
        assertEquals("dm-101", dm.id)
        assertNull(dm.sharedMusic)
        assertNull(dm.sharedPlaylist)
        assertEquals("https://example.com/art.png", dm.imageUrl)
        assertEquals("Check this album cover", dm.content)
        assertNotEquals("null", dm.imageUrl)
    }

    @Test
    fun `parseComments handles null parent_id and null profile with fallback author`() {
        val rawJson = """
            [
              {
                "id": "comm-201",
                "post_id": "post-1",
                "author_id": "deleted-user-88",
                "content": "Great track!",
                "parent_id": null,
                "profiles": null,
                "gif_url": null,
                "likes_count": 2,
                "created_at": "2026-10-17T10:20:00Z"
              }
            ]
        """.trimIndent()

        val comments = SupabaseService.parseComments(rawJson)
        assertEquals(1, comments.size)

        val comment = comments.first()
        assertEquals("comm-201", comment.id)
        assertNull(comment.parentId)
        assertNotNull(comment.author)
        assertEquals("deleted-user-88", comment.author?.id)
        assertEquals("Listener", comment.author?.displayName)
        assertNull(comment.author?.avatarUrl)
        assertNotEquals("null", comment.gifUrl)
    }

    @Test
    fun `parsePosts handles PostgREST error body gracefully without throwing`() {
        val errorJson = """
            {
              "code": "42703",
              "details": null,
              "hint": null,
              "message": "column posts.non_existent does not exist"
            }
        """.trimIndent()

        val posts = SupabaseService.parsePosts(errorJson, currentUserId = "user-1")
        assertTrue(posts.isEmpty())

        val comments = SupabaseService.parseComments(errorJson)
        assertTrue(comments.isEmpty())

        val dms = SupabaseService.parseDirectMessages(errorJson)
        assertTrue(dms.isEmpty())
    }
}
