"""Read a local v8 trace and replay its bounded FFT/NCC comparison pairs.

Requires NumPy. Does not upload anything or claim accuracy from agreement.
The FFT implementation is an independent offline check, not the app binary.
"""

import argparse
import base64
from collections import Counter
import json
from pathlib import Path

import numpy as np


def phase_shift(reference, current):
    n = reference.shape[0]
    if reference.shape != current.shape or reference.shape != (n, n) or n < 256:
        raise ValueError("Expected equal square luminance grids of at least 256 pixels")
    y, x = np.mgrid[:256, :256]
    radius = np.hypot(x - 127.5, y - 127.5) / (n * 0.43)
    window = np.where(radius < 1, 0.5 * (1 + np.cos(np.pi * radius)), 0)
    offset = (n - 256) // 2

    def spectrum(grid):
        data = (grid[offset:offset + 256, offset:offset + 256] - grid.mean()) * window
        return np.fft.fft2(data), float(np.sum(data * data))

    fa, energy_a = spectrum(reference)
    fb, energy_b = spectrum(current)
    if min(energy_a, energy_b) <= 1:
        return None
    product = fa.conj() * fb
    magnitude = np.abs(product)
    product /= np.maximum(magnitude, max(float(magnitude.max()) * 0.0001, 0.000001))
    surface = np.fft.ifft2(product).real
    py, px = np.unravel_index(surface.argmax(), surface.shape)

    def subpixel(minus, center, plus):
        denominator = minus - 2 * center + plus
        return float(np.clip(0.5 * (minus - plus) / denominator, -0.5, 0.5)) if abs(denominator) > 1e-12 else 0

    peak = surface[py, px]
    dx = (px if px <= 128 else px - 256) + subpixel(surface[py, (px - 1) % 256], peak, surface[py, (px + 1) % 256])
    dy = (py if py <= 128 else py - 256) + subpixel(surface[(py - 1) % 256, px], peak, surface[(py + 1) % 256, px])
    return float(dx), float(dy)


def distribution(values):
    finite = np.asarray([v for v in values if np.isfinite(v)], dtype=float)
    if not finite.size:
        return {"count": 0}
    return {"count": int(finite.size), "median": float(np.median(finite)),
            "p95": float(np.percentile(finite, 95)), "max": float(finite.max())}


def analyze(path):
    states = Counter()
    modes = Counter()
    frames = 0
    active_gyro = 0
    presentation_times = []
    ages = []
    exposures = []
    analysis_ms = []
    gpu_ms = []
    disagreements = []
    replayed = []
    malformed = 0
    session = {}
    with Path(path).open(encoding="utf-8-sig") as stream:
        for line in stream:
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                malformed += 1
                continue
            kind = record.get("type")
            name = record.get("name")
            if kind == "session":
                session = {k: record.get(k) for k in ("app_build", "format_version", "pipeline")}
            elif kind == "frame":
                frames += 1
                states[record.get("calibration_state", "legacy_unknown")] += 1
                active_gyro += bool(record.get("gyro_trust", 0) > 0)
                analysis_ms.append(record.get("analysis_ms", 0))
            elif name == "capture_timing":
                modes[str(record.get("active_system_mode"))] += 1
                exposures.append(record.get("exposure_s", 0) * 1000)
            elif name == "frame_presented" and record.get("presented"):
                presentation_times.append(record["presented_t"])
                ages.append(record["frame_age_ms"])
            elif name == "frame_gpu":
                gpu_ms.append(record.get("gpu_ms", 0))
            elif kind == "estimator_comparison":
                if record.get("phase_accepted") and record.get("ncc_available"):
                    disagreements.append(float(np.hypot(
                        (record["phase_dx"] - record["ncc_dx"]) * record["frame_w"],
                        (record["phase_dy"] - record["ncc_dy"]) * record["frame_h"])))
                if "reference_luma" not in record:
                    continue
                n = int(record["grid_size"])
                if record.get("luma_encoding") != "float32-le-base64" or n != 288:
                    raise ValueError("Unsupported replay format")
                arrays = [np.frombuffer(base64.b64decode(record[key], validate=True), dtype="<f4").reshape(n, n)
                          for key in ("reference_luma", "current_luma")]
                result = phase_shift(*arrays)
                if result is not None:
                    sx, sy = (v * record["source_step"] for v in result)
                    replayed.append({"t": record["t"], "dx_source_px": sx, "dy_source_px": sy,
                        "device_replay_difference_px": float(np.hypot(
                            sx - record["phase_dx"] * record["frame_w"],
                            sy - record["phase_dy"] * record["frame_h"]))})
    times = np.asarray(sorted(set(presentation_times)))
    fps = float((times.size - 1) / (times[-1] - times[0])) if times.size > 1 else None
    return {"session": session, "frames": frames, "calibration_states": dict(states),
            "gyro_active_fraction": active_gyro / frames if frames else None,
            "actual_system_modes": dict(modes), "presented_fps": fps,
            "presentation_intervals_ms": distribution(np.diff(times) * 1000),
            "presentation_age_ms": distribution(ages), "exposure_ms": distribution(exposures),
            "analysis_ms": distribution(analysis_ms), "gpu_ms": distribution(gpu_ms),
            "ncc_phase_disagreement_source_px": distribution(disagreements),
            "replayed_pairs": replayed, "malformed_lines": malformed,
            "limitation": "Estimator agreement is not ground-truth accuracy; replay pairs do not form a full trajectory."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("trace", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    result = json.dumps(analyze(args.trace), ensure_ascii=False, indent=2, allow_nan=False)
    if args.output:
        args.output.write_text(result + "\n", encoding="utf-8")
    print(result)
