Test fixtures for AudioCacheTests.

googlevideo_android_vr_range.json   A live ANDROID_VR 1.65.10 itag 140 URL and the exchange for a 512 KB
                                    range on it (206), plus the 403 a 2 MB range drew. Captured 2026-09-26;
                                    the ip query parameter is redacted.
itag140_init_segment.mp4            The first 1,019 bytes of dQw4w9WgXcQ itag 140 (ftyp, moov with mvex, sidx;
                                    no samples), as recorded by StreamResolutionTests on 2026-09-26. Its moov
                                    declares 213.08 s in mvhd/tkhd/mdhd, which AVFoundation adds to the
                                    fragments' own length.
