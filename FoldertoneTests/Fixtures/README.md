# Synthetic audio fixtures

These one-second tones and the solid-color cover are generated, not personal music. MP3, FLAC, AAC, and ALAC fixtures contain a title, artist, album, and embedded artwork. WAV and AIFF cover uncompressed audio decoding.

`generate.py` records the exact generation procedure. Regeneration requires ffmpeg; running the app and tests does not. The generator refuses to overwrite existing audio files.
