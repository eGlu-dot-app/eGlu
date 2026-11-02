#!/usr/bin/env python3
"""Edit native feature recordings without on-screen presentation graphics."""

import argparse
import json
import re
import subprocess
from pathlib import Path


WIDTH, HEIGHT, FPS = 1920, 1080, 30
BACKGROUND = "0x161713"


def run(*args):
    subprocess.run([str(arg) for arg in args], check=True)


def probe(path):
    return json.loads(subprocess.check_output([
        "ffprobe", "-v", "error", "-select_streams", "v:0", "-show_entries",
        "stream=width,height:format=duration", "-of", "json", str(path)
    ]))


def footage(source, start, end, output):
    info = probe(source)
    if not 0 <= start < end <= float(info["format"]["duration"]):
        raise ValueError(f"Edit outside native recording: {source} {start}..{end}")
    stream = info["streams"][0]
    scale = min(1760 / stream["width"], 980 / stream["height"])
    width = int(stream["width"] * scale) // 2 * 2
    height = int(stream["height"] * scale) // 2 * 2
    x, y = (WIDTH - width) // 2, (HEIGHT - height) // 2
    graph = (
        f"[1:v]setpts=PTS-STARTPTS,fps={FPS},scale={width}:{height}:flags=lanczos,"
        "setsar=1[v];"
        f"[0:v][v]overlay={x}:{y}:eof_action=repeat:format=auto,"
        "format=yuv420p[out]"
    )
    run("ffmpeg", "-y", "-v", "error", "-f", "lavfi", "-i",
        f"color=c={BACKGROUND}:s={WIDTH}x{HEIGHT}:r={FPS}",
        "-ss", start, "-t", end - start, "-i", source,
        "-filter_complex", graph, "-map", "[out]",
        "-frames:v", round((end - start) * FPS),
        "-c:v", "libx264", "-preset", "medium", "-crf", "19",
        "-profile:v", "high", "-pix_fmt", "yuv420p", "-r", FPS,
        "-g", 60, "-video_track_timescale", 30000, "-an", output)


def assemble(parts, output, chapters=()):
    listing = output.with_suffix(".txt")
    listing.write_text("".join(f"file '{part.resolve()}'\n" for part in parts))
    command = ["ffmpeg", "-y", "-v", "error", "-f", "concat", "-safe", "0",
               "-i", listing, "-f", "lavfi", "-i",
               "anullsrc=channel_layout=stereo:sample_rate=48000"]
    if chapters:
        metadata = output.with_suffix(".ffmetadata")
        metadata.write_text(";FFMETADATA1\n" + "".join(
            f"[CHAPTER]\nTIMEBASE=1/1000\nSTART={round(ch['start'] * 1000)}\n"
            f"END={round(ch['end'] * 1000)}\ntitle={ch['title']}\n"
            for ch in chapters))
        command += ["-i", metadata, "-map_metadata", "2", "-map_chapters", "2"]
    command += ["-map", "0:v", "-map", "1:a", "-c:v", "copy", "-c:a", "aac",
                "-b:a", "128k", "-ar", "48000", "-shortest", "-movflags", "+faststart", output]
    run(*command)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("edits", type=Path)
    parser.add_argument("clips", type=Path)
    parser.add_argument("output", type=Path)
    args = parser.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    cache = args.output / "work"
    cache.mkdir(exist_ok=True)
    features = args.output / "features"
    features.mkdir(exist_ok=True)
    edit = json.loads(args.edits.read_text())
    chapters, cuts, feature_files, master_parts = [], [], [], []
    clock = 0.0
    for number, scene in enumerate(edit["scenes"], 1):
        parts = []
        beginning = clock
        for index, cut in enumerate(scene["cuts"], 1):
            name = cut.get("source", scene["source"])
            part = cache / f"{number:02}-{index:02}.mp4"
            footage(args.clips / name, cut["in"], cut["out"], part)
            length = float(probe(part)["format"]["duration"])
            cuts.append({"feature": scene["title"], "device": cut.get("device", scene["device"]),
                         "source": name, "sourceIn": cut["in"], "sourceOut": cut["out"],
                         "start": round(clock, 6), "end": round(clock + length, 6)})
            clock += length
            parts.append(part)
            master_parts.append(part)
        chapters.append({"start": round(beginning, 6), "end": round(clock, 6),
                         "title": scene["title"]})
        slug = re.sub("[^a-z0-9]+", "-", scene["title"].lower()).strip("-")
        feature = features / f"{number:02}-{slug}.mp4"
        assemble(parts, feature)
        feature_files.append({"title": scene["title"], "file": str(feature.relative_to(args.output)),
                              "duration": float(probe(feature)["format"]["duration"])})
    video = args.output / "eGlu-showcase.mp4"
    assemble(master_parts, video, chapters)
    run("ffmpeg", "-y", "-v", "error", "-ss", chapters[2]["start"] + 8,
        "-i", video, "-frames:v", 1, args.output / "poster.png")
    (args.output / "timeline.json").write_text(json.dumps({
        "chapters": chapters, "cuts": cuts, "featureVideos": feature_files
    }, indent=2) + "\n")
    print(json.dumps({"video": str(video), "chapters": chapters, "featureVideos": feature_files}, indent=2))


if __name__ == "__main__":
    main()
