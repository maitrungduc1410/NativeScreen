# AGENTS.md — NativeScreen Root Guide

This repository contains **NativeScreen**, a 100% native, high-performance screen recorder and cinematic demo video editor for macOS (SwiftUI + AppKit + Metal) and Windows (WinUI 3 + Direct3D 11).

## 1. Mandatory Reading Before Making Changes

Before implementing features or modifying data structures, consult the specifications in [`spec/`](./spec/README.md):
- [`spec/01-OVERVIEW-AND-ARCHITECTURE.md`](./spec/01-OVERVIEW-AND-ARCHITECTURE.md) — 5-Layer Architecture, NLE State Engine, Snapshot Undo/Redo, Multi-Window support, and `0.0%` Idle CPU budget.
- [`spec/02-FILE-FORMAT-AND-SCHEMA.md`](./spec/02-FILE-FORMAT-AND-SCHEMA.md) — `.nativescreen` package format, `[0.0, 1.0]` normalized coordinate convention, `.jsonl` telemetry schemas, and `project.json` schema.
- [`spec/03-CINEMATIC-ENGINE-AND-MATH.md`](./spec/03-CINEMATIC-ENGINE-AND-MATH.md) — 120Hz Spring Physics Solver, Auto-Zoom click clustering, and 6-Pass GPU Compositor pipeline.
- [`spec/04-UI-UX-AND-LEGAL-GUIDELINES.md`](./spec/04-UI-UX-AND-LEGAL-GUIDELINES.md) — "80% OS Native + 20% Custom Pro" UI guidelines, Window Picker Z-order overlay, and copyright & asset rules.
- [`spec/05-FEATURE-CHECKLIST.md`](./spec/05-FEATURE-CHECKLIST.md) — Master feature checklist ordered by priority.

## 2. Core Engineering Rules (All Platforms)

1. **Checklist Tracking:**
   - Whenever you complete and verify a feature from [`spec/05-FEATURE-CHECKLIST.md`](./spec/05-FEATURE-CHECKLIST.md), immediately mark its checkbox `[x]` in `spec/05-FEATURE-CHECKLIST.md`.
   - New features requested mid-development should be added to `spec/05-FEATURE-CHECKLIST.md` as well.
2. **Cross-Platform `.nativescreen` Compatibility:**
   - Never break the `.nativescreen` bundle layout (`project.json`, `assets/`, `recording/metadata.json`, `recording/telemetry/*.jsonl`).
   - All spatial coordinates in `project.json` and `telemetry/*.jsonl` MUST be normalized `[0.0, 1.0]`.
   - Raw recorded media and telemetry in `recording/` are **strictly immutable** after capture (Non-Linear Editing).
3. **Performance & Resource Discipline:**
   - **0.0% Idle CPU:** GPU preview views (`MTKView` on macOS, `SwapChainPanel` on Windows) must pause their render loop (`isPaused = true`) when playback is paused, rendering only on demand (`needsDisplay = true`).
   - **Zero FFmpeg:** Use native OS media frameworks (`ScreenCaptureKit`, `AVFoundation`, `VideoToolbox`, `Metal` on macOS; `Windows.Graphics.Capture`, `Media Foundation`, `Direct3D 11` on Windows).
4. **Privacy & Security Hygiene:**
   - Never commit machine-specific paths, local usernames, `xcuserdata`, or proprietary third-party assets.
   - Use Conventional Commits (`feat: ...`, `fix: ...`, `docs: ...`, `refactor: ...`) with author `Duc Trung Mai <maitrungduc1410@gmail.com>`.

## 3. Platform-Specific Agent Guides

- **macOS App (`NativeScreen/`):** Read [`NativeScreen/AGENTS.md`](./NativeScreen/AGENTS.md) before editing Swift/macOS code.
