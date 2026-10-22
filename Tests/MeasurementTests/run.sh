#!/usr/bin/env bash
set -euo pipefail
mkdir -p build/measurement-tests
ENGINE=PurooScopeCam/Services/FrameStabilizationEngine.swift
{
  printf 'import Foundation\nimport CoreGraphics\nimport CoreVideo\n'
  awk '/^struct TelescopeMagnificationOption:/ {copy=1} /^struct CaptureStatus:/ {copy=0} copy' PurooScopeCam/Models/CaptureModels.swift
  printf 'private enum FrameStabilizationEngine { static let visualGridSize = 288 }\n'
  awk '/^private struct VisualMotionObservation / {copy=1} /^private final class VisualEstimatorShadow / {copy=0} copy' "$ENGINE"
  awk '/^private struct GyroMotionCandidate / {copy=1} /^private struct FusedMotionDelta / {copy=0} copy' "$ENGINE"
  cat Tests/MeasurementTests/main.swift
} > build/measurement-tests/main.swift
swiftc -O -swift-version 5 PurooScopeCam/Models/StabilizationDiagnostics.swift PurooScopeCam/Services/PhaseCorrelationEstimator.swift build/measurement-tests/main.swift -o build/measurement-tests/test
build/measurement-tests/test
