package com.fortune.vibramusic

import com.fortune.vibramusic.data.innertube.InnertubeParser
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
}
