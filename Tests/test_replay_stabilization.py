import base64
import importlib.util
import json
from pathlib import Path
import tempfile
import unittest

import numpy as np

SPEC = importlib.util.spec_from_file_location("replay", Path(__file__).parents[1] / "tools/replay_stabilization.py")
replay = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(replay)


class ReplayTests(unittest.TestCase):
    def test_known_translation(self):
        source = np.random.default_rng(20).normal(100, 20, (288, 288)).astype("<f4")
        target = np.roll(source, (2, -3), (0, 1))
        result = replay.phase_shift(source, target)
        self.assertAlmostEqual(result[0], -3, delta=0.05)
        self.assertAlmostEqual(result[1], 2, delta=0.05)

    def test_flat_rejection(self):
        source = np.ones((288, 288)) * 50
        self.assertIsNone(replay.phase_shift(source, source))

    def test_local_trace(self):
        source = np.random.default_rng(20).normal(100, 20, (288, 288)).astype("<f4")
        encoded = base64.b64encode(source.tobytes()).decode("ascii")
        records = [
            {"type": "session", "app_build": "26", "format_version": 8},
            {"type": "frame", "calibration_state": "validated", "gyro_trust": 0.8, "analysis_ms": 3},
            {"type": "estimator_comparison", "t": 1, "grid_size": 288,
             "luma_encoding": "float32-le-base64", "reference_luma": encoded, "current_luma": encoded,
             "source_step": 2, "frame_w": 1080, "frame_h": 1920, "phase_dx": 0, "phase_dy": 0},
            *[{"type": "control", "name": "frame_presented", "presented": True,
               "presented_t": 100 + i / 30, "frame_age_ms": 25} for i in range(10)],
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in records) + "\n{truncated", encoding="utf-8")
            report = replay.analyze(path)
        self.assertEqual(report["malformed_lines"], 1)
        self.assertAlmostEqual(report["presented_fps"], 30)
        self.assertEqual(report["gyro_active_fraction"], 1)
        self.assertEqual(len(report["replayed_pairs"]), 1)
        self.assertLess(report["replayed_pairs"][0]["device_replay_difference_px"], 0.001)
        self.assertEqual(report["crop_pre_usage"]["count"], 0)
        self.assertEqual(report["crop_allocation_difference_output_fraction"]["high_y"]["count"], 0)

    def test_v9_crop_budget(self):
        records = [
            {"type": "session", "app_build": "27", "format_version": 9},
            {"type": "frame", "crop_requested_low_y": 0.22, "crop_applied_low_y": 0.20,
             "crop_requested_high_y": 0.03, "crop_applied_high_y": 0.03, "crop_pre_usage": 0.96},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in records), encoding="utf-8")
            report = replay.analyze(path)
        differences = report["crop_allocation_difference_output_fraction"]
        self.assertAlmostEqual(differences["low_y"]["max"], 0.02)
        self.assertEqual(differences["high_y"]["max"], 0)
        self.assertEqual(differences["high_x"]["count"], 0)
        self.assertAlmostEqual(report["crop_pre_usage"]["max"], 0.96)

    def test_v10_measurement_provenance(self):
        records = [
            {"type": "session", "app_build": "33", "format_version": 10},
            {"type": "frame", "visual_estimator": "phase", "lookahead_ms": 5, "rolling_enabled": False},
            {"type": "frame", "visual_estimator": "ncc", "lookahead_ms": 0, "rolling_enabled": False},
            {"type": "control", "name": "photo_context_match", "matched": True},
            {"type": "estimator_comparison", "production_estimator": "phase", "ncc_available": False,
             "phase_accepted": True},
        ]
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "trace.jsonl"
            path.write_text("\n".join(json.dumps(row) for row in records), encoding="utf-8")
            report = replay.analyze(path)
        self.assertEqual(report["visual_estimators"], {"phase": 1, "ncc": 1})
        self.assertEqual(report["rolling_enabled_frames"], 0)
        self.assertEqual(report["photo_context_matches"], {"matched": 1})
        self.assertEqual(report["ncc_phase_disagreement_source_px"]["count"], 0)


if __name__ == "__main__":
    unittest.main()
