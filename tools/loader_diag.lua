-- Headless ground-truth diagnostic: boot the real mod Loader over the real
-- on-disk mods (repo mods/ unioned with the save-dir mods/, the same merge
-- love.filesystem performs), then print every mod's final state and reason.
-- Run from the repo root: luajit <this file> <saveDirModsPath>

package.path = "./?.lua;./?/init.lua;" .. package.path
love = love or require("tests.love_stub")

local SAVEDIR = assert(arg[1], "pass the save-dir mods path")
local lfsRoots = { ".", SAVEDIR } -- save dir SECOND: first-found wins below,
-- but love.filesystem gives the SAVE DIR precedence, so list it first:
lfsRoots = { SAVEDIR, "." }

local function hostPath(root, path) return root .. "/" .. path end

local function fileInfo(p)
  local f = io.open(p, "rb")
  if f then
    local size = f:seek("end")
    f:close()
    -- directories on macOS open too; a dir read fails, so probe with a
    -- directory listing instead
  end
  local pipe = io.popen('test -d "' .. p .. '" && echo dir || (test -f "' .. p .. '" && echo file)')
  local kind = pipe:read("*l")
  pipe:close()
  if kind == "dir" then return { type = "directory" } end
  if kind == "file" then return { type = "file" } end
  return nil
end

local fs = {
  read = function(path)
    for _, root in ipairs(lfsRoots) do
      local f = io.open(hostPath(root, path), "rb")
      if f then
        local body = f:read("*a")
        f:close()
        return body
      end
    end
    return nil
  end,
  getInfo = function(path)
    for _, root in ipairs(lfsRoots) do
      local info = fileInfo(hostPath(root, path))
      if info then return info end
    end
    return nil
  end,
  load = function(path)
    for _, root in ipairs(lfsRoots) do
      local f = io.open(hostPath(root, path), "rb")
      if f then
        local body = f:read("*a")
        f:close()
        return load(body, "@" .. path)
      end
    end
    return nil, path .. " not found"
  end,
  getDirectoryItems = function(path)
    local seen, out = {}, {}
    for _, root in ipairs(lfsRoots) do
      local pipe = io.popen('ls -1 "' .. hostPath(root, path) .. '" 2>/dev/null')
      for line in pipe:lines() do
        if not seen[line] then
          seen[line] = true
          out[#out + 1] = line
        end
      end
      pipe:close()
    end
    return out
  end,
  write = function() return true end,
  createDirectory = function() return true end,
}

local Loader = require("src.mods.Loader")
local loader = Loader.new({ fs = fs, dev = true })

-- minimal data table with every registry target the merge writes into
local data = setmetatable({}, { __index = function(t, k)
  local v = {}
  rawset(t, k, v)
  return v
end })

local ok, err = pcall(function() return loader:load(data) end)
print("loader:load ->", ok, err)
print("")
print("== per-mod states ==")
for id, mod in pairs(loader.mods) do
  print(string.format("%-24s state=%-10s reason=%s",
    id, tostring(mod.state), tostring(mod.reason or "")))
end
print("")
print("== errors list ==")
for _, e in ipairs(loader.errors or {}) do
  print(string.format("[%s] %s: %s", tostring(e.state or e.kind),
    tostring(e.id or "?"), tostring(e.reason or e.message or "")))
end
print("")
print("== registered render pipelines ==")
for id, def in pairs(data.render_pipelines or {}) do
  if type(def) == "table" and id:sub(1, 1) ~= "_" then
    print("  " .. id, "hotkey=" .. tostring(def.hotkey),
      "priority=" .. tostring(def.priority))
  end
end
