import argparse
from pathlib import Path
import struct
import subprocess

import torch
from silero_vad import get_speech_timestamps, load_silero_vad

RATE = 16000
LEAD_IN = round(0.100 * RATE)
TAIL = round(0.050 * RATE)
WINDOW = RATE // 100  # 10 ms


def refine_speech_end(audio, start, end):
    # Silero can keep a phrase open after its waveform has already faded.
    window_count = min(75, (end - start) // WINDOW)
    if window_count < 7:
        return end
    windows = audio[end - window_count * WINDOW:end].reshape(-1, WINDOW)
    power = windows.square().mean(dim=1)
    # Require both a low absolute level and a 28 dB drop from recent speech.
    quiet_power = min(10 ** (-38 / 10), power.max().item() * 10 ** (-28 / 10))
    quiet_windows = 0
    for value in reversed(power[-25:].tolist()):
        if value >= quiet_power:
            break
        quiet_windows += 1
    if quiet_windows < 6:
        return end
    return end - quiet_windows * WINDOW


def silence_intervals(speech, audio):
    total_samples = len(audio)
    previous_end = 0
    for interval in speech:
        start = max(0, interval["start"] - LEAD_IN)
        if start > previous_end:
            yield previous_end, start
        end = refine_speech_end(audio, interval["start"], interval["end"])
        previous_end = max(previous_end, min(total_samples, end + TAIL))
    if previous_end < total_samples:
        yield previous_end, total_samples


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("wav", type=Path)
    parser.add_argument("--ffmpeg", default="ffmpeg")
    args = parser.parse_args()

    pcm = subprocess.check_output([
        args.ffmpeg, "-v", "error", "-i", str(args.wav), "-map", "0:a:0",
        "-ac", "1", "-ar", str(RATE), "-f", "s16le", "-",
    ])
    samples = [sample / 32768 for (sample,) in struct.iter_unpack("<h", pcm)]
    if not samples:
        parser.error("El WAV no contiene muestras de audio.")

    audio = torch.tensor(samples, dtype=torch.float32)
    speech = get_speech_timestamps(
        audio, load_silero_vad(), sampling_rate=RATE,
        threshold=0.58, min_silence_duration_ms=80,
        speech_pad_ms=0,  # silence_intervals applies the margins once.
    )
    for start, end in silence_intervals(speech, audio):
        print(f"{start / RATE:.6f}\t{end / RATE:.6f}")


if __name__ == "__main__":
    main()
