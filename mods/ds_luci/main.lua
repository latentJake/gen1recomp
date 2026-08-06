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

local HOST, PORT, PATH = "127.0.0.1", 8765, "/"

-- Screen Units -> fraction of the view height the eye displaces by.
-- AXIS SIGNS ARE FIRST GUESSES: run LUCI's axis test (move right/up/toward,
-- confirm each direction) and flip a sign here if one reads backwards.
local X_SENS, Y_SENS = 1.0, 1.0
local SIGN_X, SIGN_Y = 1, 1
local Z_REST = 0.6            -- protocol rest eye z
local Z_MIN, Z_MAX = 0.6, 1.8 -- clamp on the dolly factor (z/Z_REST)
local SMOOTH = 12             -- 1/s exponential ease toward the newest pose

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
  if not (okV3 and type(Voxel3D) == "table"
          and okVS and type(Voxel) == "table") then
    mod.log:error("could not reach Voxel3D/VoxelState through "
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

  -- ------- the camera wrap
  -- Installed once and left in place; the level/tracking gate inside keeps
  -- it a pure pass-through while OFF.  On hot reload the whole DS namespace
  -- rebuilds, so a fresh wrap lands on the fresh module table.
  local origVP = Voxel3D.viewProjection
  Voxel3D.viewProjection = function(cx, cy, vw, vh)
    if level > 0 and tracking() and Voxel3D.camera == nil then
      local a = Voxel.angle or 0
      local F = Voxel.FOCAL or 1.0
      local ca, sa = math.cos(a), math.sin(a)
      local dolly = math.max(Z_MIN, math.min(Z_MAX, ez / Z_REST))
      local d = F * vh * dolly
      local ox = SIGN_X * ex * X_SENS * vh
      local oy = SIGN_Y * ey * Y_SENS * vh
      -- displace along the orbit rig's right (+x) and up (0, sa, -ca)
      Voxel3D.camera = {
        eye = { cx + ox, d * ca + oy * sa, cy + d * sa - oy * ca },
        focus = { cx, 0, cy },
        fov = 2 * math.atan(1 / (2 * F)),
        up = { 0, sa, -ca },
      }
      local r1, r2, r3, r4 = origVP(cx, cy, vw, vh)
      Voxel3D.camera = nil
      return r1, r2, r3, r4
    end
    return origVP(cx, cy, vw, vh)
  end

  local function activate()
    if client then return end
    client = WS.new(HOST, PORT, PATH)
    client.onMessage = onMessage
    client.onStatus = function(state, detail)
      mod.log:info("luci: %s%s", state,
        detail and (" (" .. tostring(detail) .. ")") or "")
    end
    client:connect()
  end

  local function deactivate()
    if not client then return end
    client:close()
    client, latest = nil, nil
    ex, ey, ez = 0, 0, Z_REST
  end

  -- Present-only pipeline: no draw of its own, just the engine-supplied
  -- options row / hotkey / persistence / per-frame update for the option.
  mod.content.render_pipelines:register("ds_luci", {
    label = "LUCI TRACK",
    levels = { "OFF", "ON" },
    hotkey = "0", -- engine owns 1-5; DRAMATIC_SHAPE claims 3,5,6,7,8,9
    priority = 4,
    present = function(canvas) return canvas end,
    update = function(dt, lvl)
      level = lvl
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
      local k = math.min(1, SMOOTH * dt)
      ex, ey, ez = ex + (tx - ex) * k, ey + (ty - ey) * k, ez + (tz - ez) * k
    end,
  })
end
