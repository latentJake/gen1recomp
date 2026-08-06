# ds_luci — LUCI head tracking for the Dramatic Shape Voxel Mod

Couples [DRAMATIC_SHAPE](https://github.com/DramaticShape/DramaticShapeVoxelMod)'s
3D diorama camera to LUCI Bar's local head-pose broker. Head x/y swings the
eye around the diorama's focus point; head z (distance from screen) dollies
in and out. The result: the voxel overworld behaves like a diorama in a box
behind the monitor.

**Status: CONFIRMED WORKING LIVE (2026-08-06).** Smooth head tracking with
the voxel mode on, default constants, axis signs correct as shipped. This
version (0.1.0) is the working baseline; see `DIORAMA-NOTES.md` at the repo
root for the state of the whole project and what's next.

> Gotcha that cost a debugging round: a mod that is *disabled* in
> `options.lua` (`mods.ds_luci = false`) produces **zero errors anywhere**
> — it just silently doesn't exist. Before assuming a load failure, check
> the F10 manager's toggle. Ground truth when needed:
> `luajit <scratch>/loader_diag.lua "<save-dir>"` boots the real Loader
> headless over the real mods and prints every mod's state.

## Why a companion mod, not a fork

DRAMATIC_SHAPE was surveyed for forking and it's the wrong move:

- It **exports its live module namespace** (`mod.exports.lib` with a
  memoized `V.require`) — the author explicitly built an external-drive
  surface.
- Its `Voxel3D.camera` seam exists, per its own source comment, for
  *"a tracked pose ... whose projection is an off-centre frustum"* — this
  exact use case.
- A fork is hazardous: the `DRAMATIC_SHAPE` id is hard-coded into its
  settings ids, its `save.modData` bucket (a renamed fork silently loses
  your stored settings and day/night clock), its log strings, and its
  `Game:keypressed` hotkey wrap (a fork double-registers keys 5/7/8/9 and
  collides with the original's `voxel`/`tiltshift` pipeline ids).
- It's actively developed (v1.6.2); a fork dies the day upstream ships
  v1.7.

So this is ~150 lines against a stable seam instead, and DRAMATIC_SHAPE
updates keep working underneath it.

## How it drives the camera

`Voxel3D.viewProjection(cx, cy, vw, vh)` is the one per-frame choke point
where the mod builds its camera. This mod wraps it: when LUCI TRACK is ON,
tracking is live, and nobody else owns the camera (`Voxel3D.camera == nil`
— FirstPerson/3rd-person/VR rungs set it themselves and must win), it
recomputes the mod's own orbit rig with the eye displaced by the smoothed
head offset and hands it over through the mod's *supported*
`eye/focus/fov/up` camera shape, then calls the original. All the mod's own
side-state (shadow fit, sky, water) flows through its own tested path.

No matrices are built here. A v2 can graduate to the `view`/`proj`-verbatim
camera branch with `Mat4.fovProjection` (the mod ships an OpenXR-style
asymmetric-frustum helper) for a true fish-tank off-axis projection — the
current eye-orbit approach re-aims at the focus each frame, which reads
almost identically at normal head offsets and is far harder to get wrong.

## Setup

1. Install/enable **DRAMATIC_SHAPE** (hard dependency — this mod refuses to
   load without it) and confirm its VOXEL mode works on its own first.
2. Enable **ds_luci** in the mod manager (`F10`).
3. Have LUCI Bar running (or `cd ~/luci-bar/tracker && swift run
   luci-bar-broker --source sway` for a synthetic test feed).
4. In free-roam: turn **VOXEL** on (its hotkey `3`, or Options), then
   **LUCI TRACK** on (hotkey `0`, or Options).
5. First connection ever from this app: approve the receiver on the LUCI
   Bar island (it glows; hover → Allow).

## Tuning

Constants at the top of `main.lua`:

- `X_SENS` / `Y_SENS` — how far the eye swings per Screen Unit of head
  motion.
- `SIGN_X` / `SIGN_Y` — **axis-test these first**: move your head right and
  up; if the world parallaxes the wrong way, flip the sign.
- `Z_MIN`/`Z_MAX` — clamp on the head-distance dolly factor.
- `SMOOTH` — pose easing rate (per LUCI's contract this interpolates toward
  the *newest* pose only, never buffers old ones).

## Known limits

- Orbit rungs only: on 1ST/3RD rungs and in VR, DRAMATIC_SHAPE's own rigs
  own the camera and this mod steps aside automatically (that's the
  `Voxel3D.camera == nil` guard).
- `tracking: "held"` holds the last pose; `"off"` eases home.
- The wrap stays installed while the option is OFF (pure pass-through);
  hot-reload (`F5`) rebuilds both mods cleanly.
