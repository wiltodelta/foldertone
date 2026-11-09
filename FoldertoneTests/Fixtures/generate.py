"""Regenerate synthetic codec and metadata fixtures using ffmpeg."""

import argparse
import logging
import struct
import subprocess
import zlib
from pathlib import Path

log = logging.getLogger(__name__)


def generate(output: Path) -> None:
    output.mkdir(parents=True, exist_ok=True)
    names = ["MP3.mp3", "FLAC.flac", "AAC.m4a", "ALAC.m4a", "WAV.wav", "AIFF.aiff"]
    if any((output / name).exists() for name in names):
        raise FileExistsError("Remove the synthetic audio fixtures explicitly before regenerating them")

    def chunk(kind: bytes, data: bytes) -> bytes:
        return struct.pack(">I", len(data)) + kind + data + struct.pack(">I", zlib.crc32(kind + data))

    cover = output / "cover.png"
    scanlines = b"".join(b"\x00" + bytes([104, 74, 208]) * 32 for _ in range(32))
    cover.write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", 32, 32, 8, 2, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(scanlines))
        + chunk(b"IEND", b"")
    )
    codecs = ["libmp3lame", "flac", "aac", "alac", "pcm_s16le", "pcm_s16be"]
    for name, codec in zip(names, codecs):
        label = name.split(".", 1)[0]
        command = [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi",
            "-i", "sine=frequency=440:sample_rate=44100:duration=1", "-i", str(cover),
            "-map", "0:a", "-c:a", codec,
            "-metadata", f"title=Tagged {label}", "-metadata", "artist=Fixture artist",
            "-metadata", "album=Fixture album",
        ]
        if codec in {"libmp3lame", "flac", "aac", "alac"}:
            command += ["-map", "1:v", "-c:v", "png", "-disposition:v", "attached_pic"]
        command.append(str(output / name))
        subprocess.run(command, check=True)
        log.info("Created %s", name)


if __name__ == "__main__":
    logging.basicConfig(level=logging.INFO)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--output", type=Path, default=Path(__file__).parent)
    generate(parser.parse_args().output)
