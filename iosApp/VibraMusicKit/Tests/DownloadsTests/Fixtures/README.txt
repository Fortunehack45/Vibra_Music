Test fixtures for DownloadsTests. Load with FixtureLoader(bundle: .module).

tidal_starboy_lossless.mpd  Tidal's DASH manifest for The Weeknd's "Starboy" at quality=LOSSLESS
                            (September 2026, the Android OfflineDashTest's fixture), signed URLs
                            shortened. Timeline, timescale, $Number$ template and &amp; are verbatim.
itag140_init_segment.mp4    The first 1,019 bytes of dQw4w9WgXcQ itag 140 from googlevideo (ftyp, moov
                            with mvex, sidx; no samples), as recorded by StreamResolutionTests on
                            2026-09-26. Its moov declares 213.08 s in mvhd/tkhd/mdhd, which is what
                            FragmentedMP4Durations zeroes.

Everything else the tests need (AAC, FLAC and WAV files, fMP4 segments, covers) is generated on the
spot by DownloadTestSupport.swift with AVAudioFile / AVAssetWriter / CoreGraphics.
