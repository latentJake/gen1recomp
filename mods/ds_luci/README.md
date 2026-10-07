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

## Battles

DRAMATIC_SHAPE's staged 3D battle camera (`BattleCam.rig`, an
eye/focus/fov placed shot rebuilt per frame) gets head coupling via the
**BATTLE TRACK** ladder (Options, default LOCK):

- **PAN** — offset the live shot's eye+focus together along its own
  right/up axes. Translation-only "leaning"; the mod's mouse-steer
  orbit/zoom stays active underneath. Confirmed working live but reads
  as mostly panning.
- **LOCK** — freeze the battle's first staged shot as a fixed **window
  into the arena** and look into it off-axis: the window plane sits at
  the frozen shot's focus, sized to exactly fill the base frame at focus
  depth, and head motion translates the eye at constant orientation with
  the frustum sheared about the plane (`Mat4.fovProjection`) — the same
  fish-tank treatment as the overworld WINDOW rung, on the battle's
  "diagonal" framing. Freezing also makes the mouse steering inert by
  construction: its perturbations of the live shot are never consumed.
  The frozen base expires half a second after the battle's camera streak
  ends, so every battle freezes a fresh shot.

VR eye cameras and the 1ST/3RD free-roam rigs are never touched in
either mode.

Notes from the battle-system survey (2026-08-06):

- The mod's BATTLES setting ladder is `2D-3D A / 2D-3D B / STADIUM A /
  STADIUM B / OFF`. The STADIUM rungs only appear after a one-time pack
  build that asks for a **Pokémon Stadium N64 ROM** (`baseroms/
  baserom.z64` in the save dir); declining hides them until next launch.
- The "broken 2D battle" signature — vanilla battle but with the player's
  mon showing its FRONT sprite in the back slot — means the 3D scene
  renderer threw and retired for that session (`session.broken`); the
  mod logs "draws on the plain battle background" and the F10 ERRORS feed
  attributes the cause. It is not produced by this mod: during a staged
  battle every camera call has the battle's rig installed, and ds_luci
  never replaces an installed camera (it only offsets a copy of it).

## Known limits

- Orbit rungs only: on 1ST/3RD rungs and in VR, DRAMATIC_SHAPE's own rigs
  own the camera and this mod steps aside automatically (that's the
  `Voxel3D.camera == nil` guard).
- `tracking: "held"` holds the last pose; `"off"` eases home.
- The wrap stays installed while the option is OFF (pure pass-through);
  hot-reload (`F5`) rebuilds both mods cleanly.
