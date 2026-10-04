package com.fortune.vibramusic

import com.fortune.vibramusic.data.innertube.InnertubeParser
import com.fortune.vibramusic.data.model.isPodcastSong
import kotlinx.serialization.json.Json
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Test

class PodcastEpisodeParsingTest {

    @Test
    fun `collectSongsDeep parses musicMultiRowListItemRenderer podcast episodes`() {
        val json = """
        {
          "contents": {
            "twoColumnBrowseResultsRenderer": {
              "secondaryContents": {
                "sectionListRenderer": {
                  "contents": [
                    {
                      "musicShelfRenderer": {
                        "contents": [
                          {
                            "musicMultiRowListItemRenderer": {
                              "title": {
                                "runs": [
                                  { "text": "Episode 1: The Beginning" }
                                ]
                              },
                              "subtitle": {
                                "runs": [
                                  { "text": "Dr. Insanity • Oct 3, 2026 • 45 min" }
                                ]
                              },
                              "onTap": {
                                "watchEndpoint": {
                                  "videoId": "ep_video_123"
                                }
                              },
                              "thumbnail": {
                                "musicThumbnailRenderer": {
                                  "thumbnail": {
                                    "thumbnails": [
                                      { "url": "https://example.com/ep1.jpg", "width": 540, "height": 540 }
                                    ]
                                  }
                                }
                              }
                            }
                          }
                        ]
                      }
                    }
                  ]
                }
              }
            }
          }
        }
        """.trimIndent()

        val parsed = InnertubeParser.collectSongsDeep(Json.parseToJsonElement(json))
        assertEquals(1, parsed.size)
        val ep = parsed[0]
        assertEquals("ep_video_123", ep.videoId)
        assertEquals("Episode 1: The Beginning", ep.title)
        assertNotNull(ep.durationText)
        assertEquals("https://example.com/ep1.jpg", ep.thumbnailUrl)
    }

    @Test
    fun `isDateOrNoise identifies dates tally duration and categories accurately`() {
        // Should be identified as date/noise
        org.junit.Assert.assertTrue(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("Aug 12"))
        org.junit.Assert.assertTrue(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("Oct 7, 2024"))
        org.junit.Assert.assertTrue(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("2 days ago"))
        org.junit.Assert.assertTrue(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("14K views"))
        org.junit.Assert.assertTrue(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("45 min"))
        org.junit.Assert.assertTrue(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("1:23:45"))
        org.junit.Assert.assertTrue(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("Livestreams"))
        org.junit.Assert.assertTrue(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("•"))

        // Should NOT be identified as date/noise (actual authors/channels)
        org.junit.Assert.assertFalse(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("Pop Smoke"))
        org.junit.Assert.assertFalse(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("The Daily"))
        org.junit.Assert.assertFalse(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("Huberman Lab"))
        org.junit.Assert.assertFalse(com.fortune.vibramusic.data.podcast.PodcastRepository.isDateOrNoise("Lex Fridman"))
    }

    @Test
    fun `parseCaptionTracks parses player caption tracks correctly`() {
        val playerJson = """
        {
          "captions": {
            "playerCaptionsTracklistRenderer": {
              "captionTracks": [
                {
                  "baseUrl": "https://www.youtube.com/api/timedtext?v=abc12345678",
                  "name": {
                    "runs": [
                      { "text": "English (auto-generated)" }
                    ]
                  },
                  "languageCode": "en",
                  "isTranslatable": true
                }
              ]
            }
          }
        }
        """.trimIndent()

        val parsed = com.fortune.vibramusic.data.innertube.InnertubeParser.parseCaptionTracks(
            kotlinx.serialization.json.Json.parseToJsonElement(playerJson) as kotlinx.serialization.json.JsonObject
        )
        assertEquals(1, parsed.size)
        assertEquals("en", parsed[0].languageCode)
        assertEquals("English (auto-generated)", parsed[0].name)
        assertEquals("https://www.youtube.com/api/timedtext?v=abc12345678", parsed[0].baseUrl)
    }

    @Test
    fun `isPodcastSong correctly identifies podcast songs`() {
        val podcastSong = com.fortune.vibramusic.data.model.Song(
            videoId = "pod123",
            title = "Podcast Episode",
            artist = "Host",
            thumbnailUrl = null,
            playbackSourceType = com.fortune.vibramusic.data.model.PlaybackSourceType.PODCASTS,
        )
        org.junit.Assert.assertTrue(podcastSong.isPodcastSong)

        val showSong = com.fortune.vibramusic.data.model.Song(
            videoId = "pod124",
            title = "Episode 2",
            artist = "Host",
            thumbnailUrl = null,
            albumId = "MPSPkds8932",
        )
        org.junit.Assert.assertTrue(showSong.isPodcastSong)

        val musicSong = com.fortune.vibramusic.data.model.Song(
            videoId = "music123",
            title = "Element",
            artist = "Pop Smoke",
            thumbnailUrl = null,
            albumId = "MPREb_98124",
        )
        org.junit.Assert.assertFalse(musicSong.isPodcastSong)
    }
}
