# NativeScreen Specification (`spec/`)

This directory contains the cross-platform technical specifications, data schemas, mathematical models, engineering decision records, and platform implementation guides for **NativeScreen** (macOS & Windows).

## Document Index

1. **[`01-OVERVIEW-AND-ARCHITECTURE.md`](./01-OVERVIEW-AND-ARCHITECTURE.md)**
   - Core philosophy ("80% OS Native + 20% Custom Pro")
   - Performance budgets (`0.0%` Idle CPU, `< 120 MB` RAM, Zero-Copy GPU pipeline, Zero FFmpeg dependency)
   - 5-Layer System Architecture (macOS SwiftUI/Metal & Windows WinUI 3/Direct3D 11)
   - Non-Linear Editing (NLE) & Value-Type Snapshot Undo/Redo (`⌘Z` / `⇧⌘Z`)
   - Multi-project simultaneous editing architecture

2. **[`02-FILE-FORMAT-AND-SCHEMA.md`](./02-FILE-FORMAT-AND-SCHEMA.md)**
   - `.nativescreen` package bundle structure
   - Cross-platform normalized coordinate convention (`[0.0, 1.0]`)
   - Append-only `.jsonl` telemetry schemas (`cursor.jsonl`, `clicks.jsonl`, `keys.jsonl`, `window.jsonl`)
   - `recording/metadata.json` and `project.json` full specification

3. **[`03-CINEMATIC-ENGINE-AND-MATH.md`](./03-CINEMATIC-ENGINE-AND-MATH.md)**
   - 120Hz Spring Physics Solver (cursor glide, lookahead phase-lag compensation, active drag acceleration & virtual camera dolly/zoom)
   - Stationary `CursorMovesGroup` dead-zone clustering & screen-rect space interpolation
   - 6-Pass GPU Compositor pipeline (Background, Multi-Track Masks, SDF Rounded Screen Frame & Cached Drop Shadow, Cursor/Ripples, 1-Frame Shutter Motion Blur, Liquid Glass Loupe Shader, and 3D Keycap Overlay)

4. **[`04-UI-UX-AND-LEGAL-GUIDELINES.md`](./04-UI-UX-AND-LEGAL-GUIDELINES.md)**
   - Floating Recording HUD Bar (`NSPanel` / Acrylic)
   - Smart Window Picker Overlay (Z-order hit-testing, app icon, dimensions, `AXUIElement` window resize presets)
   - Main Editor layout & copyright/asset rules (System wallpapers from `/System/Library/Desktop Pictures/` copied to `.nativescreen/assets/` upon selection, procedural Mesh Gradients, synthesized click audio)

5. **[`05-FEATURE-CHECKLIST.md`](./05-FEATURE-CHECKLIST.md)**
   - Living interactive checklist (`- [ ]`) ordered by priority from **Phase 1 (MVP Core)** through **Phase 5 (Windows Port)**.
   - Check off items (`- [x]`) as they are implemented and verified.

6. **[`06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md`](./06-ENGINEERING-DECISIONS-AND-OPTIMIZATIONS.md)**
   - Architecture Decision Records (ADRs) & performance breakthroughs:
     - Hybrid Parallel Video Encoding (`VTCompressionSession` HW + Multi-core CPU)
     - Constant-Quality Keyframe Budgeting & `ITU_R_709_2` (Rec. 709) Color Space
     - Sequential Zero-Copy `420v` Decoding vs. Stateless Frame Generators
     - Materializing Lazy `CIImage` Graphs into VRAM `MTLTexture`s (`waitUntilCompleted` sync)
     - Uniform Shortest-Side Padding (`padByRatio`) for `Auto` Aspect Ratio
     - Telemetry Clock Synchronization (`t = 0.0 ms`) & Spring Phase-Lag Lookahead
     - Retained-Layer 120Hz `.hover-magnet` Button Physics & CSG Fillet Tooltip Geometry

7. **Platform-Specific Implementation Guides (`platforms/`):**
   - **[`platforms/macos-metal-videotoolbox.md`](./platforms/macos-metal-videotoolbox.md)** — macOS deep dive, API pitfalls, concurrency rules, and benchmarks (`AppKit`, `SwiftUI`, `Metal`, `CoreImage`, `AVFoundation`, `VideoToolbox`).
   - **[`platforms/windows-d3d11-mediafoundation.md`](./platforms/windows-d3d11-mediafoundation.md)** — Windows 11 translation guide (`WinUI 3`, `Direct3D 11`, `Direct2D`, `HLSL`, `Windows.Graphics.Capture`, `Media Foundation`).

8. **[`schemas/project.schema.json`](./schemas/project.schema.json)**
   - Formal JSON Schema (Draft 2020-12) for validating `project.json` inside `.nativescreen` bundles.
