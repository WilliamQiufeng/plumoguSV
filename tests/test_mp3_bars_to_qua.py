"""End-to-end smoke check for the standalone spectrum map generator."""

import re
import subprocess
import sys
import tempfile
from pathlib import Path


def main():
    script = Path(__file__).resolve().parents[1] / "scripts/mp3_bars_to_qua.py"
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        mp3 = root / "tone.mp3"
        output = root / "map"
        subprocess.run(
            ["ffmpeg", "-hide_banner", "-loglevel", "error", "-f", "lavfi", "-i",
             "sine=frequency=440:duration=2", "-codec:a", "libmp3lame", str(mp3)],
            check=True,
        )
        subprocess.run(
            [sys.executable, str(script), str(mp3), "--ln-length-ms", "750",
             "--out-dir", str(output)],
            check=True,
        )
        qua = (output / "bars.qua").read_text()
        assert (output / "audio.mp3").read_bytes() == mp3.read_bytes()
        assert "Mode: Keys10" in qua and "LegacyLNRendering: true" in qua
        assert qua.count(": !ScrollGroup") == 10
        assert qua.count("    InitialScrollVelocity: 0") == 10
        notes = re.findall(r"^- StartTime: (\d+)\n  EndTime: (\d+)\n  Lane: (\d+)\n  TimingGroup: bar_(\d+)$", qua, re.M)
        assert len(notes) == 10
        head = int(notes[0][0])
        assert all(int(start) == head and int(end) == head + 750 and lane == group
                   for start, end, lane, group in notes)
        for lane in range(1, 11):
            group = qua.split(f"  bar_{lane}: !ScrollGroup\n", 1)[1].split("  bar_", 1)[0]
            assert f"    - StartTime: {head - 1}\n      Multiplier: 100" in group
            assert f"    - StartTime: {head}\n      Multiplier: 1" in group
            factors = re.findall(r"      Multiplier: (\d+\.\d{4})", group)
            assert len(factors) > 2 and all(0 <= float(value) <= 1 for value in factors)
            assert factors[-1] == "1.0000"


if __name__ == "__main__":
    main()
