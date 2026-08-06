# Diorama / LUCI project notes

Working notes for the head-tracked "diorama mode" build of gen1recomp.
Baseline confirmed live 2026-08-06: smooth head tracking driving the
Dramatic Shape voxel camera. This file is the state of the world + the
roadmap; per-mod detail lives in `mods/ds_luci/README.md`.

## What this repo is

A clone of [bryanthaboi/gen1recomp](https://github.com/bryanthaboi/gen1recomp)
(branch `diorama-luci`, origin pointed at upstream for syncing) used to
develop LUCI-coupled rendering. The sibling clone `~/Gen1/gen1recomp` is
kept vanilla.

## The working stack

```
LUCI Bar (~/luci-bar, macOS app or `luci-bar-broker` CLI)
  └─ ws://127.0.0.1:8765  ·  luci.pose v1 JSON  ·  60 Hz, latest-only
      └─ mods/ds_luci  (this repo — ws.lua RFC-6455 client + camera glue)
          └─ DRAMATIC_SHAPE v1.6.2  (installed in the shared save dir:
             ~/Library/Application Support/LOVE/pokemon-love2d/mods/)
              └─ Voxel3D.camera seam → its own tested camera path
                  └─ gen1recomp render_pipelines engine
```

- `ds_luci` wraps `Voxel3D.viewProjection` (the one per-frame camera choke
  point) and, when LUCI TRACK is ON + tracking live + nobody else owns the
  camera, hands over an `eye/focus/fov/up` camera with the eye displaced by
  the smoothed head pose. Orbit rig replicated from `Voxel3D.lua:578-586`:
  `eye = {cx, d·cos a, cy + d·sin a}`, `focus = {cx, 0, cy}`,
  `d = FOCAL·vh`, `fov = 2·atan(1/(2·FOCAL))`.
- Head x/y displace the eye along the rig's right/up; head z scales `d`
  (dolly, clamped 0.6–1.8×). Focus stays pinned → the eye *orbits* the
  focus point. Smoothing: 12/s exponential ease toward the newest pose
  only (per LUCI's adapter contract, never buffer old frames).
- On 1ST/3RD/VR rungs, DRAMATIC_SHAPE's own rigs set `Voxel3D.camera`
  first and ds_luci steps aside automatically.

## Hard-won facts (don't re-learn these)

- **The engine's mod hotkeys**: engine owns keys 1–5 (`3` = its flat TILT);
  DRAMATIC_SHAPE deliberately *claims* `3` for VOXEL via a `Game:keypressed`
  wrap and also uses 5/7/8/9 for its settings; its `tiltshift` sits on `6`.
  ds_luci uses `0`. When in doubt, use the OPTIONS rows, not hotkeys.
- **A disabled mod is silent**: `mods.<id> = false` in `options.lua` means
  no errors, no rows, nothing — indistinguishable from "broken" until you
  check F10. This produced a full "incompatible?" debugging round.
- **Both builds share one save dir** (`pokemon-love2d` identity): options,
  saves, and installed mods (incl. DRAMATIC_SHAPE) are common to the
  vanilla clone, this clone, and the official app.
- **A drawWorld pipeline owns the whole frame** and its returned canvas is
  composited as a **window-resolution image, 1:1** (`Renderer.lua:856`).
  Two world pipelines can't run at once — enabling one force-disables the
  other (and the engine TILT). My earlier hand-rolled `voxel_world` mod was
  fighting DRAMATIC_SHAPE exactly this way.
- **LÖVE embeds LuaJIT** — Lua 5.1 grammar, `bit` library, no 5.3 bitwise
  operators. `love.data.hash/encode` cover SHA-1 + base64 (used for the
  WebSocket handshake, no vendored crypto).
- **Headless ground truth**: `brew install luajit`, then the loader-diag
  script (see ds_luci README) boots the real `src/mods/Loader.lua` over the
  real mods folders with `tests/love_stub.lua`. GUI runs from this sandbox
  hang before executing any Lua — use the diag or ask for an in-game check.
- **LUCI Bar identifies native receivers by executable path** — all plain
  `love .` runs share the `/Applications/love.app` identity/approval.
- The `luci-bar-broker` CLI's synthetic sources are
  `camera, dolly, lookAround, nod, still, sway` (docs say "synthetic";
  that name doesn't exist).

## The projection-anchor question (next design topic)

Today the anchor is effectively **the character**: the engine camera
centers the player, `focus = {cx, 0, cy}` is the screen-center ground
point, and the whole rig (near plane included, via the mod's own
perspective setup) rides that focus. Head motion orbits *around the
player*.

For a real volumetric/off-axis-volume feel, the thing that should be
anchored is **the screen plane itself**: the display surface is a fixed
window into the diorama box, the world sits at some depth behind (and
maybe slightly in front of) that plane, and the head pose skews an
asymmetric frustum *about the plane* rather than orbiting a character
point. Kooima's generalized-perspective formulation (already ported in
`~/luci-bar` / Sharp Viewer's `OffAxisProjection.swift`, and available
in-mod as `Mat4.fovProjection(angleLeft, angleRight, angleUp, angleDown,
near, far)` — OpenXR-style signed half-angles) is the target math.
Design choices to expose in the debug menu rather than decide blind:

- what the screen plane maps to in world units (world px per screen
  height — today implicitly `vh`),
- where the plane sits relative to the focus point (at the player's feet?
  at a fixed scene depth? user-slidable),
- near-plane distance policy (fixed vs derived from head z),
- eye-orbit (current, re-aims at focus) vs pure-translation off-axis
  (fixed view orientation + skewed frustum) — feel A/B.

## Roadmap

1. **Debug menu** (next): an in-game panel for camera experiments —
   live readout of `eyeSU`/derived camera, sliders/steppers for
   X/Y/Z sensitivity, smoothing, dolly clamps, anchor mode, plane depth,
   near plane. Likely a `ModSetting`-style page in ds_luci (DRAMATIC_SHAPE's
   `lib/ModSetting.lua` is the pattern to copy) plus the dev console for
   free-form pokes.
2. **FrameHelper**: draw the live frustum/plane gizmos into the scene to
   eyeball that the projection is right — near-plane rectangle, screen
   plane rectangle, eye point + ray to focus, at minimum. Path: ds_luci
   already has a `present` stage on its pipeline; project gizmo corners
   through the live `Voxel3D.vp` and draw `love.graphics.line` overlays.
   (Same role as the frame helpers we've built for the Metal viewer.)
3. **True off-axis v2**: graduate from the eye/focus/fov orbit camera to
   the `view`/`proj`-verbatim branch of `Voxel3D.camera` with
   `Mat4.fovProjection` — fixed view orientation, frustum skewed by head
   pose about the screen plane. This is the fish-tank-VR configuration the
   volumetric goal actually wants.
4. **Physical calibration**: use `eyeMeters` + the `screen` block from the
   pose stream (when present) to map real display size instead of the
   normalized `eyeSU` assumption.
5. **Upstream candidates**: ds_luci is small and additive — worth asking
   the Dramatic Shape author (and/or bois.icu Discord) about interest once
   the debug round settles the design.

## Version pin (the confirmed-working combo)

| piece | version / state |
| --- | --- |
| gen1recomp engine | upstream `dev` @ `112120e` (v0.0.0-dev source run) |
| LÖVE | 11.5, notarized binary from the official 0.1.75 release app |
| DRAMATIC_SHAPE | 1.6.2 (save-dir install) |
| ds_luci | 0.1.0 — this commit |
| LUCI Bar | ~/luci-bar working tree, pose protocol v1 |
| ROM | Red (US), SHA-1 `ea9bcae6…` imported |
