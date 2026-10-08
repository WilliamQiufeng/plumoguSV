#!/usr/bin/env python3
"""Turn an MP3 into a Quaver long-note spectrum visualizer."""

import argparse
import json
import shutil
import subprocess
from pathlib import Path

import numpy as np


SAMPLE_RATE = 22050
FFT_SIZE = 2048


def decode_audio(path):
    process = subprocess.run(
        [
            "ffmpeg", "-hide_banner", "-loglevel", "error", "-i", str(path),
            "-vn", "-ac", "1", "-ar", str(SAMPLE_RATE), "-f", "f32le", "pipe:1",
        ],
        capture_output=True,
        check=False,
    )
    if process.returncode:
        raise ValueError(process.stderr.decode(errors="replace").strip() or "FFmpeg could not decode the MP3")
    return np.frombuffer(process.stdout, dtype="<f4")


def band_values(audio, head_ms, keys, fps):
    times = [round(frame * 1000 / fps, 3) for frame in range(int(head_ms * fps / 1000) + 1)]
    times = [time for time in times if time < head_ms] + [head_ms]
    frequencies = np.fft.rfftfreq(FFT_SIZE, 1 / SAMPLE_RATE)
    edges = np.geomspace(40, 8000, keys + 1)
    bands = [(frequencies >= low) & (frequencies < high) for low, high in zip(edges[:-1], edges[1:])]
    window = np.hanning(FFT_SIZE)
    amplitudes = np.zeros((len(times), keys))

    for row, time in enumerate(times):
        center = round(time * SAMPLE_RATE / 1000)
        left = center - FFT_SIZE // 2
        start, end = max(0, left), min(len(audio), left + FFT_SIZE)
        frame = np.zeros(FFT_SIZE)
        frame[start - left : end - left] = audio[start:end]
        spectrum = np.abs(np.fft.rfft(frame * window))
        for column, band in enumerate(bands):
            amplitudes[row, column] = np.sqrt(np.mean(spectrum[band] ** 2))

    reference = np.percentile(amplitudes, 95, axis=0)
    values = np.clip(np.sqrt(amplitudes / np.maximum(reference, 1e-12)), 0, 1)
    values[-1] = 1  # Leave the LN bodies visible after the music stops.
    return times, values


def make_qua(title, audio_file, end_ms, length_ms, zero_length_ms, times, values):
    keys = values.shape[1]
    head_ms = end_ms
    lines = [
        f"AudioFile: {json.dumps(audio_file)}",
        f"Mode: Keys{keys}",
        f"Title: {json.dumps(title, ensure_ascii=False)}",
        'Artist: "Unknown"',
        'Creator: "mp3_bars_to_qua"',
        'DifficultyName: "Spectrum"',
        "LegacyLNRendering: true",
        "BPMDoesNotAffectScrollVelocity: true",
        "InitialScrollVelocity: 1",
        "TimingPoints:",
        "- StartTime: 0",
        "  Bpm: 120",
        "SliderVelocities: []",
        "ScrollSpeedFactors: []",
        "HitObjects:",
    ]
    for lane in range(1, keys + 1):
        lines.extend((
            f"- StartTime: {head_ms}",
            f"  EndTime: {end_ms + length_ms}",
            f"  Lane: {lane}",
            f"  TimingGroup: bar_{lane}",
        ))

    lines.append("TimingGroups:")
    for lane in range(1, keys + 1):
        lines.extend((
            f"  bar_{lane}: !ScrollGroup",
            "    InitialScrollVelocity: 0",
            "    ScrollVelocities:",
            f"    - StartTime: {head_ms - 1}",
            "      Multiplier: 100",
            f"    - StartTime: {head_ms}",
            "      Multiplier: 1",
            "    ScrollSpeedFactors:",
        ))
        for time, value in zip(times, values[:, lane - 1]):
            lines.extend((f"    - StartTime: {time}", f"      Multiplier: {value + zero_length_ms:.4f}"))
    return "\n".join(lines) + "\n"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("mp3", type=Path)
    parser.add_argument("--keys", type=int, default=10, help="number of frequency bars, 1–10 (default: 10)")
    parser.add_argument("--ln-length-ms", type=int, default=200, help="LN length in milliseconds (default: 200)")
    parser.add_argument("--ln-zero-factor", type=float, default=0.01, help="LN base factor (default: 0.01)")
    parser.add_argument("--fps", type=int, default=15, help="SSF samples per second (default: 15)")
    parser.add_argument("--out-dir", type=Path, help="output folder (default: <mp3 name>_bars)")
    args = parser.parse_args()
    source = args.mp3.expanduser().resolve()
    if not source.is_file() or source.suffix.lower() != ".mp3":
        parser.error("mp3 must be an existing MP3 file")
    if not 1 <= args.keys <= 10 or args.ln_length_ms <= 0 or not 1 <= args.fps <= 60:
        parser.error("keys must be 1–10, LN length positive, and fps 1–60")
    out_dir = (args.out_dir or Path(f"{source.stem}_bars")).expanduser().resolve()
    qua_path = out_dir / "bars.qua"
    audio_path = out_dir / "audio.mp3"
    if qua_path.exists() or (audio_path.exists() and audio_path != source):
        parser.error(f"output already exists in {out_dir}")

    try:
        audio = decode_audio(source)
    except (OSError, ValueError) as error:
        parser.error(str(error))
    end_ms = round(len(audio) * 1000 / SAMPLE_RATE)
    if end_ms <= 1:
        parser.error("the MP3 must be longer than the 1 ms pre-teleport")
    head_ms = end_ms
    times, values = band_values(audio, head_ms, args.keys, args.fps)
    qua = make_qua(source.stem, audio_path.name, end_ms, args.ln_length_ms, args.ln_zero_factor, times, values)

    out_dir.mkdir(parents=True, exist_ok=True)
    if audio_path != source:
        shutil.copy2(source, audio_path)
    qua_path.write_text(qua, encoding="utf-8")
    print(f"Wrote {qua_path} ({args.keys} bars, {len(times)} SSF points per bar)")


if __name__ == "__main__":
    main()
