Test fixtures for PlaybackPolicyTests.

audio/ holds short generated test tones (sines plus a little noise, so the lossy encoders have
something to spend bits on), encoded with macOS afconvert so AudioFormatMeasurementTests can
measure real files through AVFoundation:

  flac_24_96.flac         afconvert -f flac -d flac            24-bit / 96 kHz, 0.25 s
  flac_24_96_in_mp4.m4a   afconvert -f m4af -d flac            FLAC inside MP4 (dfLa), as Tidal serves it
  alac_16_44.m4a          afconvert -f m4af -d alac            16-bit / 44.1 kHz, 0.5 s
  aac_256.m4a             afconvert -f m4af -d aac  -b 256000 -s 0
  heaac_64.m4a            afconvert -f m4af -d aach -b 64000  -s 0   the "Low" rung
  opus_160.caf            afconvert -f caff -d opus -b 160000
  pcm_16_44.wav           16-bit / 44.1 kHz PCM
