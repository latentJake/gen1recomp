-- LUCI head tracking for the Dramatic Shape Voxel Mod.
--
-- A companion mod, deliberately NOT a fork: DRAMATIC_SHAPE exports its live
-- module namespace (main.lua:1208, mod.exports.lib) precisely so another
-- mod can drive it, and its Voxel3D.camera seam exists -- per its own
-- comment -- for "a tracked pose ... whose projection is an off-centre
-- frustum".  Forking was surveyed and rejected: the mod id is hard-coded
-- into its settings ids, save-data bucket, and log strings, so a renamed
-- fork silently loses the player's stored settings and day/night clock,
-- double-wraps Game:keypressed, and collides with the original in the
-- pipeline registry.  This file is ~150 lines against a stable seam
-- instead.
--
-- WHAT IT DOES.  While the LUCI TRACK option is ON and DRAMATIC_SHAPE's
-- VOXEL mode is rendering, the viewer's head pose (LUCI Bar broker,
-- ws://127.0.0.1:8765, luci.pose v1 -- see ~/luci-bar/docs/08-adapters.md)
-- steers the diorama camera: eyeSU.x/y swing the eye around the focus
-- point, eyeSU.z dollies in and out (rest distance at z = 0.6).
--
-- HOW.  Voxel3D.viewProjection(cx, cy, vw, vh) is the single per-frame
-- choke point that builds the camera (called from Voxel3D.beginScene).
-- We wrap it: when tracking is live and nobody else owns the camera
-- (Voxel3D.camera == nil -- FirstPerson/VR set it themselves on their
-- rungs and must win), we recompute the mod's own orbit rig with the eye
-- displaced by the head offset and hand it over via the supported
-- eye/focus/fov/up camera shape, then let the original run -- so all of
-- its side-state bookkeeping (vp, shadow fit, sky, water) happens through
-- the mod's own tested path, branch 2 of its camera dispatch.  No
-- matrices are built here at all; v2 can graduate to the view/proj-verbatim
-- branch with Mat4.fovProjection for a true asymmetric frustum once this
-- is confirmed live.
--
-- Orbit rig replicated from Voxel3D.lua:578-586:
--   eye = {cx, d*cos(a), cy + d*sin(a)}, focus = {cx, 0, cy},
--   d = FOCAL*vh, fov = 2*atan(1/(2*FOCAL)), world y up, camera right +x,
--   camera up = (0, sin a, -cos a).

local Json = require("src.link.Json")
-- engine_internals (declared in manifest.json): the engine's pipeline
-- registry, used only to steer the VOXEL ladder past its non-tracking
-- rungs while LUCI is on (SIMPLE CAMS)
local okPipelines, Pipelines = pcall(require, "src.render.Pipelines")

local HOST, PORT, PATH = "127.0.0.1", 8765, "/"

-- Tuning lives in the mod-manager OPTIONS page (mod.options:define below:
-- sensitivity, plane lift, smoothing, dolly, axis inverts, FrameHelper)
-- with session console overrides on top -- see mod.exports at the bottom.
-- Only the fixed baselines stay as constants here:
local SIGN_X, SIGN_Y = 1, 1   -- base axis signs (confirmed live 2026-08-06)
local Z_REST = 0.6            -- protocol rest eye z
local Z_MIN, Z_MAX = 0.6, 1.8 -- clamp on the dolly factor (z/Z_REST)
local NEAR_FRAC = 0.05        -- near clip as a fraction of eye->plane distance

-- WINDOW rung (preset 02): the screen is a fixed window into the diorama.
-- The window plane is perpendicular to the rung's view direction, sized so
-- one screen height = vh world pixels (the flat view's own framing), and
-- lifted toward the viewer from the focus point so the player sits just
-- behind the glass -- the "+2z" rig. Head motion translates the eye with a
-- FIXED orientation and the frustum shears about the plane
-- (Mat4.fovProjection), so at rest the frame is pixel-identical to the
-- orbit's, and off-center the world reads as inside the screen.

return function(mod)
  local ds = mod:find("DRAMATIC_SHAPE")
  if not (ds and ds.exports and ds.exports.lib) then
    mod.log:error("DRAMATIC_SHAPE not found or exports no lib -- "
      .. "install/enable it first; ds_luci drives its camera")
    return
  end
  local V = ds.exports.lib
  local okV3, Voxel3D = pcall(V.require, "Voxel3D")
  local okVS, Voxel = pcall(V.require, "VoxelState")
  local okM4, Mat4 = pcall(V.require, "Mat4")
  if not (okV3 and type(Voxel3D) == "table"
          and okVS and type(Voxel) == "table"
          and okM4 and type(Mat4) == "table") then
    mod.log:error("could not reach Voxel3D/VoxelState/Mat4 through "
      .. "DRAMATIC_SHAPE's exports (version drift?); doing nothing")
    return
  end

  local wsSource = mod:read("ws.lua")
  local chunk = wsSource and load(wsSource, "@" .. mod.path .. "/ws.lua")
  local okWS, WS = pcall(chunk or function() end)
  if not (okWS and type(WS) == "table") then
    mod.log:error("ws.lua missing or broken -- reinstall the mod")
    return
  end

  local level = 0
  local client = nil
  local latest = nil            -- newest valid luci.pose message
  local ex, ey, ez = 0, 0, Z_REST -- smoothed eye, Screen Units
  local wsStatus = "idle"       -- for the HUD

  -- Pose bias: the viewer's captured NEUTRAL posture.  The protocol's
  -- nominal rest is (0, 0, 0.6), but a real seated pose can rest well off
  -- that (observed live: ey +0.155, ez 1.2 -- "I have to lower my head to
  -- get the ideal view").  mods.exports.ds_luci.recenter() captures the
  -- current smoothed pose as neutral; recenter(false) clears it.
  local bx, by, bz = 0, 0, Z_REST
  local biasRestored = false
  local function biased()
    return ex - bx, ey - by, ez * (Z_REST / bz)
  end

  local function onMessage(text)
    local msg = Json.decode(text)
    if type(msg) ~= "table" then return end
    if msg.type ~= "luci.pose" or msg.version ~= 1 then return end
    latest = msg
  end

  local function tracking()
    local t = latest and latest.tracking
    return t == "active" or t == "synthetic" or t == "held"
  end

  -- ------- live tunables
  -- Two layers: the mod-manager OPTIONS page (F10 -> ds_luci -> Options,
  -- persisted, ladder values) and session-only console overrides that win
  -- over it and accept any number:
  --   mods.exports.ds_luci.set("lift", 3.5)   -- backtick console
  --   mods.exports.ds_luci.set("lift", nil)   -- back to the option row
  --   mods.exports.ds_luci.state()            -- dump everything live
  --
  -- Row order is deliberate: the first block is what a PLAYER should ever
  -- need (the shipped defaults are the tuned preset -- see
  -- docs/camera-presets.md); everything below SENSITIVITY is developer
  -- surface for tuning new presets and will likely be hidden or pruned
  -- for the public release.
  mod.options:define({
    -- ------- player-facing
    { key = "battle", label = "BATTLE TRACK", type = "choice", default = 2,
      choices = { { "OFF", 0 }, { "PAN", 1 }, { "LOCK", 2 } } },
    -- While LUCI TRACK is on, keep the VOXEL ladder to the five cameras
    -- that suit head tracking: flat OFF plus the four plain angle rungs
    -- (15/35/50/75).  FULL (a preset-applier that rewrites other rows)
    -- and the EXPERIMENTAL 1ST/3RD rungs are skipped over when cycling.
    { key = "simple", label = "SIMPLE CAMS", type = "toggle", default = true },
    { key = "xsens", label = "X SENS", type = "choice", default = 1.0,
      choices = { { "0.25", 0.25 }, { "0.5", 0.5 }, { "0.75", 0.75 },
                  { "1.0", 1.0 }, { "1.25", 1.25 }, { "1.5", 1.5 }, { "2.0", 2.0 } } },
    { key = "ysens", label = "Y SENS", type = "choice", default = 1.0,
      choices = { { "0.25", 0.25 }, { "0.5", 0.5 }, { "0.75", 0.75 },
                  { "1.0", 1.0 }, { "1.25", 1.25 }, { "1.5", 1.5 }, { "2.0", 2.0 } } },
    { key = "smooth", label = "SMOOTHING", type = "choice", default = 18,
      choices = { { "6", 6 }, { "9", 9 }, { "12", 12 }, { "18", 18 },
                  { "24", 24 }, { "36", 36 } } },
    -- ------- developer surface
    { key = "lift", label = "PLANE LIFT", type = "choice", default = 16,
      choices = { { "0", 0 }, { "2", 2 }, { "4", 4 }, { "8", 8 },
                  { "12", 12 }, { "16", 16 }, { "24", 24 }, { "32", 32 },
                  { "48", 48 } } },
    { key = "dist", label = "DIST", type = "choice", default = 3.0,
      choices = { { "0.5", 0.5 }, { "0.8", 0.8 }, { "1.0", 1.0 },
                  { "1.5", 1.5 }, { "2.0", 2.0 }, { "3.0", 3.0 },
                  { "4.0", 4.0 }, { "5.0", 5.0 }, { "7.0", 7.0 } } },
    { key = "vshift", label = "V SHIFT", type = "choice", default = 2,
      choices = { { "-16", -16 }, { "-8", -8 }, { "-4", -4 }, { "-2", -2 },
                  { "0", 0 }, { "2", 2 }, { "4", 4 }, { "8", 8 },
                  { "16", 16 }, { "24", 24 } } },
    { key = "truez", label = "TRUE Z", type = "toggle", default = true },
    { key = "dolly", label = "Z DOLLY", type = "toggle", default = false },
    { key = "invertx", label = "INVERT X", type = "toggle", default = false },
    { key = "inverty", label = "INVERT Y", type = "toggle", default = false },
    { key = "debug", label = "FRAMEHELPER", type = "choice", default = 0,
      choices = { { "OFF", 0 }, { "HUD", 1 }, { "RIG", 2 }, { "BOTH", 3 } } },
  })
  local overrides = {}
  local function knob(key)
    local v = overrides[key]
    if v ~= nil then return v end
    return mod.options:get(key)
  end
  -- effective values, refreshed once per update tick (fallbacks mirror
  -- the preset-03 schema defaults)
  local T = { lift = 16, xsens = 1, ysens = 1, smooth = 18, dist = 3,
              vshift = 2, dolly = false, truez = true,
              sx = 1, sy = 1, debug = 0 }
  local function refreshKnobs()
    T.lift = tonumber(knob("lift")) or 16
    T.xsens = tonumber(knob("xsens")) or 1
    T.ysens = tonumber(knob("ysens")) or 1
    T.smooth = tonumber(knob("smooth")) or 18
    T.dist = tonumber(knob("dist")) or 3
    T.vshift = tonumber(knob("vshift")) or 2
    T.dolly = knob("dolly") == true
    T.truez = knob("truez") ~= false
    -- legacy: the first battle knob was a toggle; a stored boolean maps
    -- onto the ladder (true -> LOCK, false -> OFF)
    local b = knob("battle")
    if b == true then T.battle = 2
    elseif b == false then T.battle = 0
    else T.battle = tonumber(b) or 2 end
    T.sx = (knob("invertx") == true and -1 or 1) * SIGN_X
    T.sy = (knob("inverty") == true and -1 or 1) * SIGN_Y
    T.debug = tonumber(knob("debug")) or 0
    T.simple = knob("simple") ~= false
  end

  -- who owned the camera on the last wrapped frame: "ours" while this
  -- mod's rig rendered, "foreign" while FirstPerson/3RD/VR held it (the
  -- 3RD and 1ST rungs of the VOXEL ladder look wildly different and are
  -- easy to land on by cycling key 3 -- this makes that visible)
  local camOwner = "none"

  -- this frame's rig, stashed by the camera builders for the FrameHelper
  local rig = nil

  -- ------- the two camera rigs
  -- Shared frame geometry: the rung's fixed basis.  The orbit never yaws,
  -- so it is analytic in the pitch alone (a = 0 straight down, rising
  -- toward horizontal): forward (0,-ca,-sa), right (1,0,0), up (0,sa,-ca).

  -- Rung 1, ORBIT (preset 01): eye swings around the focus point and the
  -- camera re-aims at it every frame.  Character-diorama feel; goes
  -- through the mod's own eye/focus/fov camera branch.
  local function orbitCamera(cx, cy, vw, vh)
    local a = Voxel.angle or 0
    local F = Voxel.FOCAL or 1.0
    local ca, sa = math.cos(a), math.sin(a)
    local bex, bey, bez = biased()
    local dolly = T.dolly and math.max(Z_MIN, math.min(Z_MAX, bez / Z_REST)) or 1
    local d = F * vh * dolly * T.dist
    local ox = T.sx * bex * T.xsens * vh
    local oy = T.sy * bey * T.ysens * vh
    rig = { mode = "ORBIT", stamp = love.timer.getTime(),
            focus = { cx, 0, cy }, D = d, vw = vw, vh = vh }
    return {
      eye = { cx + ox, d * ca + oy * sa, cy + d * sa - oy * ca },
      focus = { cx, 0, cy },
      fov = 2 * math.atan(1 / (2 * F)),
      up = { 0, sa, -ca },
    }
  end

  -- Rung 2, WINDOW (preset 02): fish-tank / Kooima off-axis.  The screen
  -- is a fixed window plane in the world; the eye TRANSLATES with the
  -- head at constant orientation and the frustum shears about the plane,
  -- so the world reads as sitting inside the screen -- the Verify /
  -- Sharp Viewer look, on the voxel diorama.
  --
  -- Geometry, per frame:
  --   plane center C = focus lifted PLANE_LIFT_CELLS*16 world px toward
  --     the viewer along -forward (the "+2z" player rig);
  --   plane extents = vw x vh world px (one screen height = vh, the flat
  --     view's own framing -- at rest this frame is pixel-identical to
  --     the orbit's);
  --   eye E = C + forward*(-D) + right*X + up*Y, D = FOCAL*vh*(z/Z_REST);
  --   view = lookAt(E, E + forward, up)  -- orientation NEVER re-aims;
  --   proj = fovProjection over the plane rect as seen from E: signed
  --     half-angles atan((+-half-extent - lateral offset)/D), left/down
  --     negative, exactly Mat4's OpenXR convention.  The mod's camera
  --     branch adds the canvas Y flip itself.
  -- eye/focus/fov ride along for the systems that reason about the camera
  -- (sky bands, water lean, billboard yaw); focus is the point straight
  -- ahead at plane distance so the attitude stays fixed under head motion.
  -- skyRay stays nil -> the classic frame-hung sky, same as the orbit.
  local function windowCamera(cx, cy, vw, vh)
    local a = Voxel.angle or 0
    local F = Voxel.FOCAL or 1.0
    local ca, sa = math.cos(a), math.sin(a)
    local fwd = { 0, -ca, -sa }
    local up = { 0, sa, -ca }
    local bex, bey, bez = biased()
    local X = T.sx * bex * T.xsens * vh
    local Y = T.sy * bey * T.ysens * vh
    -- TRUE Z: distance in the same SU mapping as x/y (1 SU = vh world px),
    -- the Metal-renderer-consistent geometry.  Else the rig-preserving
    -- FOCAL*vh rest distance, optionally z-modulated by the dolly.
    local D
    if T.truez then
      D = math.max(0.2, math.min(3.0, bez)) * vh
    else
      local dolly = T.dolly and math.max(Z_MIN, math.min(Z_MAX, bez / Z_REST)) or 1
      D = F * vh * dolly
    end
    D = D * T.dist -- DIST knob: dolly-zoom (plane framing fixed)
    local lift = T.lift * 16
    -- plane center: focus lifted toward the viewer, plus the V SHIFT
    -- recentering along the rig's up (positive -> window up-world ->
    -- character sits lower in frame)
    local vs = T.vshift * 16
    local C = { cx - fwd[1] * lift + up[1] * vs,
                -fwd[2] * lift + up[2] * vs,
                cy - fwd[3] * lift + up[3] * vs }
    local E = { C[1] - fwd[1] * D + X,
                C[2] - fwd[2] * D + up[2] * Y,
                C[3] - fwd[3] * D + up[3] * Y }
    local view = Mat4.lookAt(E, { E[1] + fwd[1], E[2] + fwd[2], E[3] + fwd[3] }, up)
    local hw, hh = vw * 0.5, vh * 0.5
    local proj = Mat4.fovProjection(
      math.atan((-hw - X) / D), math.atan((hw - X) / D),
      math.atan((hh - Y) / D), math.atan((-hh - Y) / D),
      math.max(1, D * NEAR_FRAC), D * 4 + 4096)
    -- everything the FrameHelper needs to draw this exact rig
    rig = { mode = "WINDOW", stamp = love.timer.getTime(),
            C = C, E = E, fwd = fwd, up = up, right = { 1, 0, 0 },
            hw = hw, hh = hh, D = D, X = X, Y = Y, lift = lift,
            near = math.max(1, D * NEAR_FRAC),
            focus = { cx, 0, cy }, vw = vw, vh = vh }
    return {
      view = view, proj = proj,
      eye = E,
      focus = { E[1] + fwd[1] * D, E[2] + fwd[2] * D, E[3] + fwd[3] * D },
      fov = 2 * math.atan(hh / D),
    }
  end

  -- Head parallax on a FOREIGN placed camera -- DRAMATIC_SHAPE's staged
  -- battle shot (BattleCam.rig: an eye/focus/fov camera set per frame).
  -- Translation-only: eye AND focus shift together along the shot's own
  -- right/up basis, so the framing keeps its aim and the parallax reads
  -- like leaning around the arena.  Scale: the shot's eye->focus distance
  -- stands in for the view size (there's no vw/vh notion of "screen" in a
  -- placed shot).  MUST build a copy -- the same camera table is consumed
  -- by viewProjection twice per frame (BattleScene and beginScene), so an
  -- in-place shift would compound; the owner's table is restored after.
  -- VR eyes (view/proj cameras) are never touched, and the 3RD/1ST
  -- free-roam rungs (FirstPerson's rig, Voxel.level 6/7) are left alone
  -- -- a mouse-steered head with a second head offset on top fights.
  local function offsetForeign(cam)
    local e, f = cam.eye, cam.focus
    local fx, fy, fz = f[1] - e[1], f[2] - e[2], f[3] - e[3]
    local len = math.sqrt(fx * fx + fy * fy + fz * fz)
    if len < 1e-6 then return nil end
    fx, fy, fz = fx / len, fy / len, fz / len
    -- right = fwd x worldUp; degenerate for a straight-down shot
    local rx, ry, rz = -fz, 0, fx
    local rlen = math.sqrt(rx * rx + rz * rz)
    if rlen < 1e-6 then return nil end
    rx, rz = rx / rlen, rz / rlen
    local ux = ry * fz - rz * fy
    local uy = rz * fx - rx * fz
    local uz = rx * fy - ry * fx
    local bex, bey = biased()
    local ox = T.sx * bex * T.xsens * len
    local oy = T.sy * bey * T.ysens * len
    local dx = rx * ox + ux * oy
    local dy = ry * ox + uy * oy
    local dz = rz * ox + uz * oy
    local out = {}
    for k, v in pairs(cam) do out[k] = v end
    out.eye = { e[1] + dx, e[2] + dy, e[3] + dz }
    out.focus = { f[1] + dx, f[2] + dy, f[3] + dz }
    return out
  end

  -- BATTLE LOCK: freeze the first staged shot of the battle as a fixed
  -- window and look into it off-axis -- the overworld WINDOW treatment on
  -- the battle's "diagonal" framing.  The window plane sits at the frozen
  -- shot's focus, perpendicular to its view axis, sized so the plane
  -- exactly fills the base frame at focus depth (hh = tan(fov/2)*len) --
  -- so at rest the framing is identical to the shot that was frozen.
  -- Head x/y translate the eye at CONSTANT orientation with the frustum
  -- sheared about the plane; head z (TRUE Z on) walks the eye in and out.
  -- The live shot the mod keeps rebuilding (including its mouse-steer
  -- orbit/zoom) is ignored until the battle's camera streak ends.
  local battleBase = nil
  local function battleWindow(cam, vw, vh)
    local now = love.timer.getTime()
    local B = battleBase
    if not B then
      local e, f = cam.eye, cam.focus
      local dxv = { f[1] - e[1], f[2] - e[2], f[3] - e[3] }
      local len = math.sqrt(dxv[1] ^ 2 + dxv[2] ^ 2 + dxv[3] ^ 2)
      if len < 1e-6 then return nil end
      local fwd = { dxv[1] / len, dxv[2] / len, dxv[3] / len }
      local rx, rz = -fwd[3], fwd[1] -- fwd x worldUp
      local rlen = math.sqrt(rx * rx + rz * rz)
      if rlen < 1e-6 then return nil end
      local right = { rx / rlen, 0, rz / rlen }
      local up = { right[2] * fwd[3] - right[3] * fwd[2],
                   right[3] * fwd[1] - right[1] * fwd[3],
                   right[1] * fwd[2] - right[2] * fwd[1] }
      local fov = cam.fov or 0.9
      B = { C = { f[1], f[2], f[3] }, fwd = fwd, right = right, up = up,
            len = len, hh = math.tan(fov * 0.5) * len,
            curve = cam.curve or 0 }
      battleBase = B
      -- one line per battle in the log: proof the LOCK rig engaged (the
      -- staged renderer failing AFTER this point is DS-side and lands in
      -- its own error feed)
      mod.log:info("battle LOCK engaged: len=%.0f fov=%.1fdeg", len,
                   math.deg(fov))
    end
    B.stamp = now
    local hh = B.hh
    local hw = hh * ((vh and vh > 0) and (vw / vh) or (16 / 9))
    local bex, bey, bez = biased()
    -- SU semantics against the window itself: 1 SU = one plane height
    local X = T.sx * bex * T.xsens * (2 * hh)
    local Y = T.sy * bey * T.ysens * (2 * hh)
    local D = B.len
    if T.truez then
      D = D * math.max(0.4, math.min(2.5, bez / Z_REST))
    end
    local C, fwd, up = B.C, B.fwd, B.up
    local E = { C[1] - fwd[1] * D + B.right[1] * X + up[1] * Y,
                C[2] - fwd[2] * D + B.right[2] * X + up[2] * Y,
                C[3] - fwd[3] * D + B.right[3] * X + up[3] * Y }
    local view = Mat4.lookAt(E,
      { E[1] + fwd[1], E[2] + fwd[2], E[3] + fwd[3] }, up)
    local proj = Mat4.fovProjection(
      math.atan((-hw - X) / D), math.atan((hw - X) / D),
      math.atan((hh - Y) / D), math.atan((-hh - Y) / D),
      math.max(1, D * NEAR_FRAC), D * 4 + 4096)
    -- The camera's ray fan for the sky's skybox path.  Every placed
    -- eye/focus battle camera before this one went through the branch
    -- that BUILDS a fan (Voxel3D.lua:545-573); a view/proj camera is
    -- expected to bring its own (VRRig does).  Supplying the symmetric-
    -- equivalent fan keeps the battle sky on the exact path it has
    -- always taken, closing the one behavioral gap vs branch 2.
    local tanY = hh / D
    local tanX = hw / D
    local skyRay = {
      base = { fwd[1] - B.right[1] * tanX + up[1] * tanY,
               fwd[2] - B.right[2] * tanX + up[2] * tanY,
               fwd[3] - B.right[3] * tanX + up[3] * tanY },
      du = { B.right[1] * 2 * tanX, B.right[2] * 2 * tanX, B.right[3] * 2 * tanX },
      dv = { up[1] * -2 * tanY, up[2] * -2 * tanY, up[3] * -2 * tanY },
    }
    return {
      view = view, proj = proj,
      eye = E,
      focus = { E[1] + fwd[1] * D, E[2] + fwd[2] * D, E[3] + fwd[3] * D },
      fov = 2 * math.atan(hh / D),
      curve = B.curve,
      skyRay = skyRay,
    }
  end

  -- ------- the camera wrap
  -- Installed once and left in place; the level/tracking gate inside keeps
  -- it a pure pass-through while OFF.  On hot reload the whole DS namespace
  -- rebuilds, so a fresh wrap lands on the fresh module table.
  local origVP = Voxel3D.viewProjection
  Voxel3D.viewProjection = function(cx, cy, vw, vh)
    if level > 0 and tracking() and Voxel3D.camera == nil then
      camOwner = "ours"
      Voxel3D.camera = (level >= 2 and windowCamera or orbitCamera)(cx, cy, vw, vh)
      local r1, r2, r3, r4 = origVP(cx, cy, vw, vh)
      Voxel3D.camera = nil
      return r1, r2, r3, r4
    end
    local cam = Voxel3D.camera
    if level > 0 and tracking() and T.battle > 0
        and cam and cam.eye and cam.focus and not (cam.view and cam.proj)
        and (tonumber(Voxel.level) or 0) < 6 then
      local replaced
      if T.battle >= 2 then
        replaced = battleWindow(cam, vw, vh)
        camOwner = replaced and "battle+lock" or camOwner
      else
        replaced = offsetForeign(cam)
        camOwner = replaced and "battle+pan" or camOwner
      end
      if replaced then
        Voxel3D.camera = replaced
        local r1, r2, r3, r4 = origVP(cx, cy, vw, vh)
        Voxel3D.camera = cam -- the owner's table back, exactly as it was
        return r1, r2, r3, r4
      end
    end
    camOwner = (level > 0 and cam ~= nil) and "foreign" or "none"
    return origVP(cx, cy, vw, vh)
  end

  local function activate()
    if client then return end
    client = WS.new(HOST, PORT, PATH)
    client.onMessage = onMessage
    client.onStatus = function(state, detail)
      wsStatus = state
      mod.log:info("luci: %s%s", state,
        detail and (" (" .. tostring(detail) .. ")") or "")
    end
    client:connect()
  end

  local function deactivate()
    if not client then return end
    client:close()
    client, latest = nil, nil
    wsStatus = "idle"
    ex, ey, ez = 0, 0, Z_REST
  end

  -- ------- FrameHelper
  -- Lesson from v1: the tracked camera's own frustum gizmos are INVISIBLE
  -- from inside that camera -- the window plane projects exactly onto the
  -- viewport border, and the near-rect corners sit on the eye->corner
  -- rays, which project to the same corners.  So the rig is shown from
  -- OUTSIDE instead, two ways:
  --
  --  * an in-world GRID on the window plane, projected through the mod's
  --    own Voxel3D.project (curve-correct, canvas-consistent).  The grid
  --    is the zero-parallax sheet made visible: when the rig is right it
  --    stays GLUED to the screen under head motion while the world shears
  --    behind it.  Anything swimming = not plane-anchored.
  --
  --  * a third-person INSET (pose-viewer style): a live side elevation of
  --    the rig -- eye, frustum, near plane, window plane, player -- drawn
  --    with plain 2D math in a corner box.
  local function planeGrid(canvas)
    if not (rig and rig.mode == "WINDOW" and Voxel3D.project) then return end
    local step = 32 -- world px between grid lines (2 cells)
    local C, right, up = rig.C, rig.right, rig.up
    local function P(s, t)
      return C[1] + right[1] * s + up[1] * t,
             C[2] + right[2] * s + up[2] * t,
             C[3] + right[3] * s + up[3] * t
    end
    -- Voxel3D.project answers in the voxel SCENE canvas's space, which is
    -- NOT the window: the mod's anti-aliasing renders the scene canvas
    -- supersampled (observed live: gizmos landing ~1.33x out from the
    -- origin).  Self-calibrate instead of guessing the factor: in this
    -- rig the plane center provably always projects to the exact frame
    -- center (the plane rect IS the viewport), so projected-C vs W/2, H/2
    -- gives the scene->window scale directly.  A manual override still
    -- wins if ever needed: mods.exports.ds_luci.set("gridscale", 2).
    local W, H = canvas:getDimensions()
    local cx0, cy0 = Voxel3D.project(P(0, 0))
    if not (cx0 and cx0 > 1 and cy0 > 1) then return end
    local k = tonumber(overrides.gridscale)
    local kx = k or (W * 0.5) / cx0
    local ky = k or (H * 0.5) / cy0
    love.graphics.setLineWidth(1)
    love.graphics.setColor(0.3, 1, 0.5, 0.35)
    for s = -rig.hw, rig.hw, step do
      local x1, y1 = Voxel3D.project(P(s, -rig.hh))
      local x2, y2 = Voxel3D.project(P(s, rig.hh))
      if x1 and x2 then love.graphics.line(x1 * kx, y1 * ky, x2 * kx, y2 * ky) end
    end
    for t = -rig.hh, rig.hh, step do
      local x1, y1 = Voxel3D.project(P(-rig.hw, t))
      local x2, y2 = Voxel3D.project(P(rig.hw, t))
      if x1 and x2 then love.graphics.line(x1 * kx, y1 * ky, x2 * kx, y2 * ky) end
    end
    -- plane center green cross (by construction: exact frame center);
    -- player anchor red cross (lift px behind the glass)
    love.graphics.setColor(0.3, 1, 0.5, 0.9)
    love.graphics.setLineWidth(2)
    love.graphics.line(W * 0.5 - 12, H * 0.5, W * 0.5 + 12, H * 0.5)
    love.graphics.line(W * 0.5, H * 0.5 - 12, W * 0.5, H * 0.5 + 12)
    local fx, fy = Voxel3D.project(rig.focus[1], rig.focus[2], rig.focus[3])
    if fx then
      love.graphics.setColor(1, 0.35, 0.35, 0.9)
      love.graphics.line(fx * kx - 10, fy * ky, fx * kx + 10, fy * ky)
      love.graphics.line(fx * kx, fy * ky - 10, fx * kx, fy * ky + 10)
    end
    love.graphics.setColor(1, 1, 1, 1)
    love.graphics.setLineWidth(1)
  end

  -- Side elevation in a corner box: u along the view axis (window plane
  -- at u = 0, eye negative, world positive), v along the rig's up.
  local function rigInset(canvas)
    if not (rig and rig.mode == "WINDOW") then return end
    local W = canvas:getDimensions()
    local bw, bh = 280, 200
    local bx, by = W - bw - 12, 12
    love.graphics.setColor(0, 0, 0, 0.6)
    love.graphics.rectangle("fill", bx, by, bw, bh)
    love.graphics.setColor(0.5, 0.5, 0.5, 0.8)
    love.graphics.rectangle("line", bx, by, bw, bh)
    local u0, u1 = -rig.D * 1.15, rig.hh
    local v0, v1 = -rig.hh * 1.3, rig.hh * 1.3
    local function M(u, v)
      return bx + (u - u0) / (u1 - u0) * bw,
             by + bh - (v - v0) / (v1 - v0) * bh
    end
    -- window plane: green vertical segment at u = 0
    local px1, py1 = M(0, -rig.hh)
    local px2, py2 = M(0, rig.hh)
    love.graphics.setLineWidth(2)
    love.graphics.setColor(0.3, 1, 0.4, 1)
    love.graphics.line(px1, py1, px2, py2)
    -- eye: yellow dot at (-D, Y); frustum edges to the plane ends
    local exx, exy = M(-rig.D, rig.Y)
    love.graphics.setColor(1, 0.9, 0.3, 1)
    love.graphics.circle("fill", exx, exy, 4)
    love.graphics.setColor(0.75, 0.75, 0.75, 0.8)
    love.graphics.setLineWidth(1)
    love.graphics.line(exx, exy, px1, py1)
    love.graphics.line(exx, exy, px2, py2)
    -- near plane: cyan segment where the frustum crosses u = near - D
    local tN = rig.near / rig.D
    local nx1, ny1 = M(rig.near - rig.D, rig.Y + (-rig.hh - rig.Y) * tN)
    local nx2, ny2 = M(rig.near - rig.D, rig.Y + (rig.hh - rig.Y) * tN)
    love.graphics.setColor(0.3, 0.9, 1, 1)
    love.graphics.setLineWidth(2)
    love.graphics.line(nx1, ny1, nx2, ny2)
    -- player: red dot at (+lift, 0), on a faint ground reference line
    local fx, fy = M(rig.lift, 0)
    love.graphics.setColor(0.6, 0.45, 0.3, 0.7)
    love.graphics.setLineWidth(1)
    local gx1, gy1 = M(rig.lift, -rig.hh * 1.2)
    local gx2, gy2 = M(rig.lift, rig.hh * 1.2)
    love.graphics.line(gx1, gy1, gx2, gy2)
    love.graphics.setColor(1, 0.35, 0.35, 1)
    love.graphics.circle("fill", fx, fy, 4)
    love.graphics.setColor(0.8, 0.8, 0.8, 1)
    love.graphics.print("side: eye+frustum / plane / player", bx + 8, by + bh - 20)
    love.graphics.setColor(1, 1, 1, 1)
  end

  local function drawRig(canvas)
    if not (rig and love.timer.getTime() - rig.stamp < 0.25) then return end
    planeGrid(canvas)
    rigInset(canvas)
  end

  local function drawHud(canvas)
    local lines = {
      ("LUCI %s  cam:%s  ws:%s  track:%s"):format(
        level >= 2 and "WINDOW" or "ORBIT", camOwner, wsStatus,
        latest and tostring(latest.tracking) or "none"),
      ("eye SU raw(%.3f %.3f %.3f) smooth(%.3f %.3f %.3f) bias(%.2f %.2f %.2f)"):format(
        latest and latest.eyeSU and latest.eyeSU.x or 0,
        latest and latest.eyeSU and latest.eyeSU.y or 0,
        latest and latest.eyeSU and latest.eyeSU.z or 0, ex, ey, ez,
        bx, by, bz),
      ("knobs lift=%s dist=%.2f vshift=%s xs=%.2f ys=%.2f smooth=%s dolly=%s truez=%s sx=%d sy=%d"):format(
        tostring(T.lift), T.dist, tostring(T.vshift), T.xsens, T.ysens,
        tostring(T.smooth), tostring(T.dolly), tostring(T.truez), T.sx, T.sy),
    }
    if rig then
      lines[#lines + 1] = ("rig %s D=%.0f X=%.1f Y=%.1f view %dx%d")
        :format(rig.mode, rig.D or 0, rig.X or 0, rig.Y or 0,
                rig.vw or 0, rig.vh or 0)
    end
    love.graphics.setColor(0, 0, 0, 0.55)
    love.graphics.rectangle("fill", 6, 6, 560, 16 * #lines + 10)
    love.graphics.setColor(0.6, 1, 0.7, 1)
    for i, line in ipairs(lines) do
      love.graphics.print(line, 12, 8 + (i - 1) * 16)
    end
    love.graphics.setColor(1, 1, 1, 1)
  end

  -- Pipeline: the LUCI TRACK ladder + the FrameHelper present pass.
  mod.content.render_pipelines:register("ds_luci", {
    label = "LUCI TRACK",
    -- rung 1 = preset 01 (eye orbits the character), rung 2 = preset 02
    -- (fixed-orientation off-axis window); hotkey 0 cycles all three
    levels = { "OFF", "ORBIT", "WINDOW" },
    hotkey = "0", -- engine owns 1-5; DRAMATIC_SHAPE claims 3,5,6,7,8,9
    priority = 4,
    -- Drawn onto the finished composite (guardRender fences our GPU
    -- state).  FRAMEHELPER off -> pure pass-through.
    present = function(canvas)
      if T.debug > 0 then
        love.graphics.setCanvas(canvas)
        love.graphics.origin()
        if T.debug == 2 or T.debug == 3 then drawRig(canvas) end
        if T.debug == 1 or T.debug == 3 then drawHud(canvas) end
        love.graphics.setCanvas()
      end
      return canvas
    end,
    update = function(dt, lvl)
      level = lvl
      refreshKnobs()
      -- restore a saved posture bias once per session, lazily -- the save
      -- bucket isn't guaranteed loaded at entry-chunk time
      if not biasRestored then
        biasRestored = true
        pcall(function()
          local b = mod.save:get("bias")
          if type(b) == "table" and tonumber(b[3]) then
            bx, by, bz = tonumber(b[1]) or 0, tonumber(b[2]) or 0,
                         math.max(0.2, tonumber(b[3]))
          end
        end)
        -- FIRST-RUN SETUP, once per save: a fresh player should land in
        -- the full experience without touching a menu -- voxel world on
        -- (75, the tuned preset's rung), DRAMATIC_SHAPE's staged 3D
        -- battles rescued if switched OFF (deliberate non-default
        -- choices like 2D-3D B / STADIUM are respected), and LUCI TRACK
        -- on WINDOW.  Every write goes through the owners' own paths
        -- (ModSetting / Pipelines), so it persists exactly like a menu
        -- change and the player's later choices stick -- this never runs
        -- again on this save.
        pcall(function()
          if mod.save:get("seeded_v1") then return end
          local okG, Game = pcall(require, "src.core.Game")
          Game = okG and Game or nil
          -- battles: setValue is DS's own "a preset, or an assertion"
          -- entry point -- persists exactly like a menu change
          local okOB, OB = pcall(V.require, "OverworldBattle")
          if okOB and OB and OB.setting and OB.setting.get
              and OB.setting:get() == false then
            OB.setting:setValue(true, Game) -- "2D-3D A", the staged default
          end
          if okPipelines and Pipelines then
            if Pipelines.get("voxel") and (Pipelines.level("voxel") or 0) == 0 then
              Pipelines.setLevel("voxel", 5) -- the 75-degree rung
            end
            if (Pipelines.level("ds_luci") or 0) == 0 then
              Pipelines.setLevel("ds_luci", 2) -- WINDOW
            end
            local opts = Game and Game.save and Game.save.options
            if opts then
              Pipelines.syncOptions(opts)
              pcall(function() Game:writeOptions() end)
            end
          end
          mod.save:set("seeded_v1", true)
          mod.log:info("first-run setup: voxel world, staged battles and "
            .. "LUCI WINDOW enabled")
        end)
      end
      -- a frozen battle base outlives its battle only briefly: no staged
      -- camera for half a second means the battle ended (or its scene
      -- broke), and the next battle freezes a fresh shot of its own
      if battleBase and battleBase.stamp
          and love.timer.getTime() - battleBase.stamp > 0.5 then
        battleBase = nil
      end
      -- SIMPLE CAMS: while LUCI is on, the VOXEL ladder is effectively
      -- OFF/15/35/50/75 -- cycling onto FULL (rung 1, a preset-applier)
      -- skips forward to 15, and onto the EXPERIMENTAL 1ST/3RD rungs
      -- (6/7) wraps to OFF, exactly as a five-rung ladder would.
      if lvl > 0 and T.simple and okPipelines and Pipelines then
        local pl = Pipelines.level("voxel")
        local redirect = (pl == 1 and 2) or ((pl == 6 or pl == 7) and 0) or nil
        if redirect then pcall(Pipelines.setLevel, "voxel", redirect) end
      end
      if lvl <= 0 then
        deactivate()
        return
      end
      activate()
      client:poll()
      -- ease toward the newest pose; on tracking "off" (or nothing yet),
      -- ease home instead.  Never buffer old frames (adapter contract).
      local tx, ty, tz = 0, 0, Z_REST
      if latest then
        local t = latest.tracking
        if t == "active" or t == "synthetic" then
          local e = latest.eyeSU or {}
          tx, ty = e.x or 0, e.y or 0
          tz = e.z or Z_REST
        elseif t == "held" then
          tx, ty, tz = ex, ey, ez -- hold the last smoothed pose
        end
      end
      local k = math.min(1, T.smooth * dt)
      ex, ey, ez = ex + (tx - ex) * k, ey + (ty - ey) * k, ez + (tz - ez) * k
    end,
  })

  -- ------- console surface (backtick console has `mods` in scope)
  --   mods.exports.ds_luci.state()          -> dump live state
  --   mods.exports.ds_luci.set("lift", 3.5) -> session override, any value
  --   mods.exports.ds_luci.set("lift", nil) -> clear, back to the option
  -- Keys: lift dist vshift xsens ysens smooth dolly truez invertx inverty
  --       debug gridscale
  mod.exports.set = function(key, value)
    overrides[key] = value
    refreshKnobs()
    return knob(key)
  end
  mod.exports.get = function(key) return knob(key) end
  -- Capture the CURRENT pose as the neutral posture ("sit how you like,
  -- then run this"): mods.exports.ds_luci.recenter().  recenter(false)
  -- restores the protocol's nominal (0, 0, 0.6) rest.  The bias persists
  -- in the game save's mod bucket (mod.save), so it survives restarts
  -- once the player saves; re-run after a posture/desk change.
  mod.exports.recenter = function(clear)
    if clear == false then
      bx, by, bz = 0, 0, Z_REST
      pcall(function() mod.save:set("bias", nil) end)
    else
      bx, by, bz = ex, ey, math.max(0.2, ez)
      pcall(function() mod.save:set("bias", { bx, by, bz }) end)
    end
    return bx, by, bz
  end
  mod.exports.state = function()
    return {
      level = level, ws = wsStatus, camOwner = camOwner,
      voxelAngle = Voxel.angle, voxelLevel = Voxel.level,
      tracking = latest and latest.tracking or "none",
      eye = { raw = latest and latest.eyeSU, smooth = { ex, ey, ez },
              bias = { bx, by, bz } },
      knobs = { lift = T.lift, dist = T.dist, vshift = T.vshift,
                xsens = T.xsens, ysens = T.ysens,
                smooth = T.smooth, dolly = T.dolly, truez = T.truez,
                battle = T.battle, sx = T.sx, sy = T.sy, debug = T.debug },
      battleBase = battleBase,
      rig = rig,
    }
  end
end
