-- Minimal receive-focused WebSocket client (RFC 6455) over LuaSocket.
--
-- LUCI Bar's broker is a one-way publisher (docs/08-adapters.md: "Direction:
-- LUCI Bar -> client"), so this only needs to do the opening handshake,
-- decode incoming TEXT frames, and reply to a PING. It never needs to frame
-- a JSON message of its own except a PONG. Non-blocking throughout: call
-- :poll() once per love.update, never blocks the frame.
--
-- Handshake crypto (SHA-1 + base64) comes from love.data, the same pair
-- src/import/RomImporter.lua uses for ROM SHA-1 verification -- no vendored
-- crypto needed.
--
-- LOVE embeds LuaJIT (Lua 5.1 grammar): no native &/|/~/<</>> operators, so
-- every bitwise op below goes through the `bit` library, same as
-- src/core/ChipSynth.lua.

local socket = require("socket")
local bit = require("bit")

local WS_GUID = "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"

local Client = {}
Client.__index = Client

local function randomKey()
  local bytes = {}
  for i = 1, 16 do bytes[i] = string.char(love.math.random(0, 255)) end
  return (love.data.encode("string", "base64", table.concat(bytes)):gsub("%s+", ""))
end

local function acceptKeyFor(clientKey)
  local digest = love.data.hash("sha1", clientKey .. WS_GUID)
  return (love.data.encode("string", "base64", digest):gsub("%s+", ""))
end

-- ------- frame encode/decode (RFC 6455 section 5) --------------------

local function maskBytes()
  local m = {}
  for i = 1, 4 do m[i] = love.math.random(0, 255) end
  return m
end

-- Client-to-server frames MUST be masked. Only used for PONG replies; the
-- pose stream itself is receive-only, so no other outgoing frame exists.
local function encodeFrame(opcode, payload)
  payload = payload or ""
  local len = #payload
  local out = { string.char(bit.bor(0x80, opcode)) } -- FIN=1, RSV=0
  if len < 126 then
    out[#out + 1] = string.char(bit.bor(0x80, len)) -- MASK=1
  elseif len < 65536 then
    out[#out + 1] = string.char(bit.bor(0x80, 126))
    out[#out + 1] = string.char(bit.band(bit.rshift(len, 8), 0xff),
                                 bit.band(len, 0xff))
  else
    out[#out + 1] = string.char(bit.bor(0x80, 127))
    for shift = 56, 0, -8 do
      out[#out + 1] = string.char(bit.band(bit.rshift(len, shift), 0xff))
    end
  end
  local m = maskBytes()
  for i = 1, 4 do out[#out + 1] = string.char(m[i]) end
  local masked = {}
  for i = 1, len do
    masked[i] = string.char(bit.bxor(payload:byte(i), m[((i - 1) % 4) + 1]))
  end
  out[#out + 1] = table.concat(masked)
  return table.concat(out)
end

-- Try to pull one complete frame off the front of `buf`. Returns
-- (opcode, payload, restOfBuffer) or nil when the buffer holds less than a
-- full frame (caller keeps buf unchanged and waits for more bytes).
-- 127-length (64-bit) frames are decoded via the low 32 bits only, via
-- bit.lshift's 32-bit domain -- fine for luci.pose's small JSON payloads,
-- which never approach even the 126-length (16-bit) branch in practice.
local function tryDecodeFrame(buf)
  if #buf < 2 then return nil end
  local b0, b1 = buf:byte(1, 2)
  local opcode = bit.band(b0, 0x0f)
  local masked = bit.band(b1, 0x80) ~= 0
  local len = bit.band(b1, 0x7f)
  local pos = 3
  if len == 126 then
    if #buf < pos + 1 then return nil end
    len = bit.bor(bit.lshift(buf:byte(pos), 8), buf:byte(pos + 1))
    pos = pos + 2
  elseif len == 127 then
    if #buf < pos + 7 then return nil end
    len = 0
    for i = 0, 7 do len = bit.bor(bit.lshift(len, 8), buf:byte(pos + i)) end
    pos = pos + 8
  end
  local maskKey
  if masked then
    if #buf < pos + 3 then return nil end
    maskKey = { buf:byte(pos, pos + 3) }
    pos = pos + 4
  end
  if #buf < pos + len - 1 then return nil end
  local payload = buf:sub(pos, pos + len - 1)
  if masked then
    local out = {}
    for i = 1, len do
      out[i] = string.char(bit.bxor(payload:byte(i), maskKey[((i - 1) % 4) + 1]))
    end
    payload = table.concat(out)
  end
  return opcode, payload, buf:sub(pos + len)
end

-- ------- client --------------------------------------------------------

-- host/port/path: the broker's fixed local endpoint (docs/08-adapters.md:
-- ws://127.0.0.1:8765). onMessage(text) fires per decoded TEXT frame;
-- onStatus(state, detail) fires on connecting/open/closed/error.
function Client.new(host, port, path)
  return setmetatable({
    host = host, port = port, path = path or "/",
    sock = nil, state = "closed", -- closed | connecting | handshaking | open
    recvBuf = "", reqSent = false,
    onMessage = nil, onStatus = nil,
  }, Client)
end

function Client:_status(state, detail)
  self.state = state
  if self.onStatus then self.onStatus(state, detail) end
end

function Client:connect()
  if self.state ~= "closed" then return end
  local sock, err = socket.tcp()
  if not sock then
    self:_status("error", err)
    return
  end
  sock:settimeout(0)
  self.sock = sock
  self.recvBuf, self.reqSent = "", false
  local key = randomKey()
  self.expectedAccept = acceptKeyFor(key)
  self.request = table.concat({
    "GET " .. self.path .. " HTTP/1.1",
    "Host: " .. self.host .. ":" .. self.port,
    "Upgrade: websocket",
    "Connection: Upgrade",
    "Sec-WebSocket-Key: " .. key,
    "Sec-WebSocket-Version: 13",
    "", "",
  }, "\r\n")
  local ok, cerr = sock:connect(self.host, self.port)
  if ok == 1 then
    self:_status("connecting")
  elseif cerr == "timeout" or (cerr and cerr:find("progress")) then
    self:_status("connecting")
  else
    self:_status("error", cerr or "connect failed")
    self:close()
  end
end

function Client:close()
  if self.sock then pcall(function() self.sock:close() end) end
  self.sock = nil
  self.recvBuf, self.reqSent = "", false
  self:_status("closed")
end

-- One non-blocking tick. Cheap to call every love.update: a closed socket
-- is a no-op, an idle open socket is one failed non-blocking recv.
function Client:poll()
  if not self.sock or self.state == "closed" then return end

  if not self.reqSent then
    -- writable check doubles as "the non-blocking connect finished"
    local _, writable = socket.select(nil, { self.sock }, 0)
    if writable and writable[1] then
      local sent, serr = self.sock:send(self.request)
      if not sent then
        self:_status("error", serr)
        self:close()
        return
      end
      self.reqSent = true
      self:_status("handshaking")
    end
    return
  end

  local chunk, err, partial = self.sock:receive(4096)
  local data = chunk or partial
  if data and #data > 0 then self.recvBuf = self.recvBuf .. data end
  if err == "closed" then
    self:_status("closed", "broker closed the connection")
    self:close()
    return
  end

  if self.state == "handshaking" then
    local headerEnd = self.recvBuf:find("\r\n\r\n", 1, true)
    if not headerEnd then return end
    local head = self.recvBuf:sub(1, headerEnd - 1)
    self.recvBuf = self.recvBuf:sub(headerEnd + 4)
    if not head:match("^HTTP/1%.1 101") then
      self:_status("error", "handshake rejected: " .. head:match("^[^\r\n]*"))
      self:close()
      return
    end
    local accept = head:match("[Ss]ec%-[Ww]eb[Ss]ocket%-[Aa]ccept:%s*([^\r\n]+)")
    if accept ~= self.expectedAccept then
      self:_status("error", "Sec-WebSocket-Accept mismatch")
      self:close()
      return
    end
    self:_status("open")
  end

  if self.state ~= "open" then return end
  while true do
    local opcode, payload, rest = tryDecodeFrame(self.recvBuf)
    if not opcode then break end
    self.recvBuf = rest
    if opcode == 0x1 then -- text
      if self.onMessage then self.onMessage(payload) end
    elseif opcode == 0x9 then -- ping -> pong
      pcall(function() self.sock:send(encodeFrame(0xA, payload)) end)
    elseif opcode == 0x8 then -- close
      self:_status("closed", "broker sent close")
      self:close()
      return
    end
    -- 0x2 binary, 0xA pong, 0x0 continuation: not used by luci.pose, ignored
  end
end

return Client
