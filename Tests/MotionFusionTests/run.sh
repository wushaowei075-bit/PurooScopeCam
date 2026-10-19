#!/usr/bin/env bash
set -euo pipefail

ENGINE=${1:-PurooScopeCam/Services/FrameStabilizationEngine.swift}
mkdir -p build/motion-tests
{
  printf 'import Foundation\nimport CoreGraphics\n'
  awk '/^struct TelescopeMagnificationOption:/ {copy=1} /^enum StabilityBand:/ {copy=0} copy' PurooScopeCam/Models/CaptureModels.swift
  awk '/^private struct VisualMotionObservation / {copy=1} /^private final class SubpixelFrameMotionTracker / {copy=0} copy' "$ENGINE"
  awk '/^private struct GyroMotionCandidate / {copy=1} /^private struct UnitQuaternion / {copy=0} copy' "$ENGINE"
  awk '/^private struct FusedMotionDelta / {copy=1} copy' "$ENGINE"
  cat Tests/MotionFusionTests/main.swift
} > build/motion-tests/main.swift
swiftc -swift-version 5 build/motion-tests/main.swift -o build/motion-tests/test
build/motion-tests/test "${2:-}"
