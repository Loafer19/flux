-- Flux peer desktop: mouse and keys from the mpv window into fluxd.
-- script-opts: flux_peer_input-fd=<N>  (child ExtraFiles → /dev/fd/N)
local opts = { fd = "0" }
require "mp.options".read_options(opts, "flux_peer_input")

local out = nil
local function open_out()
  if out then return true end
  local n = tonumber(opts.fd)
  if not n or n < 1 then
    mp.msg.error("flux_peer_input: missing fd")
    return false
  end
  local f, err = io.open("/dev/fd/" .. tostring(n), "w")
  if not f then
    mp.msg.error("flux_peer_input: " .. tostring(err))
    return false
  end
  out = f
  return true
end

local function emit(obj)
  if not open_out() then return end
  local parts = {}
  for k, v in pairs(obj) do
    local tv = type(v)
    if tv == "string" then
      parts[#parts + 1] = string.format("%q:%q", k, v)
    elseif tv == "boolean" then
      parts[#parts + 1] = string.format("%q:%s", k, v and "true" or "false")
    elseif tv == "number" then
      parts[#parts + 1] = string.format("%q:%.6g", k, v)
    end
  end
  out:write("{" .. table.concat(parts, ",") .. "}\n")
  out:flush()
end

local mods = { ctrl = false, alt = false, shift = false, super = false }
local function track_mod(key, field)
  mp.add_forced_key_binding(key, "flux-mod-" .. field, function(e)
    mods[field] = (e.event == "down" or e.event == "repeat")
  end, { complex = true })
end
track_mod("Ctrl", "ctrl")
track_mod("Alt", "alt")
track_mod("Shift", "shift")
track_mod("Meta", "super")

local function with_mods(obj)
  obj.ctrl = mods.ctrl
  obj.alt = mods.alt
  obj.shift = mods.shift
  obj["super"] = mods.super
  return obj
end

-- Video-normalized 0..1 under the cursor, or nil outside the picture.
local function video_point()
  local pos = mp.get_property_native("mouse-pos")
  if not pos or not pos.hover then return nil end
  local dim = mp.get_property_native("osd-dimensions")
  if not dim or not dim.w or not dim.h then return nil end
  local ml, mr, mt, mb = dim.ml or 0, dim.mr or 0, dim.mt or 0, dim.mb or 0
  local vw, vh = dim.w - ml - mr, dim.h - mt - mb
  if vw <= 0 or vh <= 0 then return nil end
  local x = (pos.x - ml) / vw
  local y = (pos.y - mt) / vh
  if x < 0 or x > 1 or y < 0 or y > 1 then return nil end
  return x, y, pos.x, pos.y
end

local last_x, last_y = -1, -1
mp.observe_property("mouse-pos", "native", function()
  local x, y, sx, sy = video_point()
  if not x then return end
  if math.abs(x - last_x) < 1e-4 and math.abs(y - last_y) < 1e-4 then return end
  last_x, last_y = x, y
  emit({ op = "pos", x = x, y = y, sx = sx, sy = sy })
end)

local function bind_btn(name, btn)
  mp.add_forced_key_binding(name, "flux-" .. btn, function(e)
    local x, y, sx, sy = video_point()
    if not x then return end
    emit({
      op = "btn", btn = btn, down = (e.event == "down"),
      x = x, y = y, sx = sx, sy = sy,
    })
  end, { complex = true })
end
bind_btn("MBTN_LEFT", "left")
bind_btn("MBTN_RIGHT", "right")
bind_btn("MBTN_MID", "middle")

local function bind_wheel(name, dx, dy)
  mp.add_forced_key_binding(name, "flux-" .. name, function(e)
    if e.event == "up" then return end
    local x, y = video_point()
    if not x then return end
    local scale = 1
    if e and e.scale and e.scale > 0 then scale = e.scale end
    emit({ op = "scroll", x = x, y = y, dx = dx * 3 * scale, dy = dy * 3 * scale })
  end, { complex = true, scalable = true })
end
bind_wheel("WHEEL_UP", 0, -1)
bind_wheel("WHEEL_DOWN", 0, 1)
bind_wheel("WHEEL_LEFT", -1, 0)
bind_wheel("WHEEL_RIGHT", 1, 0)

-- specialKey numbers match docs/remote-input.md and RemoteInput.Key.
local special = {
  BS = 1, BACKSPACE = 1, TAB = 2,
  LEFT = 4, UP = 5, RIGHT = 6, DOWN = 7,
  PGUP = 8, PGDWN = 9, HOME = 10, END = 11,
  ENTER = 12, KP_ENTER = 12, DEL = 13,
  F1 = 21, F2 = 22, F3 = 23, F4 = 24, F5 = 25, F6 = 26,
  F7 = 27, F8 = 28, F9 = 29, F10 = 30, F11 = 31, F12 = 32,
}

mp.add_forced_key_binding("ANY_UNICODE", "flux-unicode", function(e)
  if e.event ~= "down" and e.event ~= "repeat" then return end
  if not e.key_text or e.key_text == "" then return end
  emit(with_mods({ op = "key", text = e.key_text }))
end, { complex = true, repeatable = true })

for name, code in pairs(special) do
  mp.add_forced_key_binding(name, "flux-sp-" .. name, function(e)
    if e.event ~= "down" and e.event ~= "repeat" then return end
    emit(with_mods({ op = "special", code = code }))
  end, { complex = true, repeatable = true })
end

-- Escape to the peer; Ctrl+Escape closes the viewer.
mp.add_forced_key_binding("ESC", "flux-esc", function(e)
  if e.event ~= "down" and e.event ~= "repeat" then return end
  if mods.ctrl then
    mp.command("quit")
    return
  end
  emit(with_mods({ op = "special", code = 14 }))
end, { complex = true, repeatable = true })

mp.add_forced_key_binding("q", "flux-quit", function() mp.command("quit") end)

mp.msg.info("flux_peer_input ready (fd=" .. tostring(opts.fd) .. ")")
