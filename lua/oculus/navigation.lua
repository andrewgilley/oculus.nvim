local M = {}
local key_names = { "up", "down", "left", "right", "inspect", "inspect_id" }

M.presets = {
  hjkl = {
    up = "k",
    down = "j",
    left = "h",
    right = "l",
    inspect = "i",
    inspect_id = "I",
  },
  ijkl = {
    up = "i",
    down = "k",
    left = "j",
    right = "l",
    inspect = "h",
    inspect_id = "H",
  },
}

M.default_style = "hjkl"

local function preset(style)
  style = type(style) == "string" and style:lower() or M.default_style
  return M.presets[style] and style or M.default_style
end

--- Resolves the navigation keys from the options table or a preset name.
-- Supports:
--   "hjkl" (default) -> up: k, down: j, left: h, right: l, inspect: i, inspect_id: I
--   "ijkl"           -> up: i, down: k, left: j, right: l, inspect: h, inspect_id: H
--   { style = "hjkl"|"ijkl", up = ..., down = ..., left = ..., right = ...,
--     inspect = ..., inspect_id = ... }
-- Keys missing from a table come from its `style` preset (hjkl by default).
-- The resolved `style` is the matching preset name, or "custom".
-- @param opts table|string|nil
-- @return table
function M.resolve(opts)
  if type(opts) == "string" then
    opts = { navigation = opts }
  end

  opts = opts or {}
  local nav = opts.navigation

  if nav == nil then
    nav = opts.navigation_keys
  end

  if type(nav) ~= "table" then
    nav = { style = nav }
  end

  local base = preset(nav.style)
  local keys = {}

  for _, name in ipairs(key_names) do
    local key = nav[name]

    keys[name] = type(key) == "string" and key ~= "" and key
      or M.presets[base][name]
  end

  for style, preset_keys in pairs(M.presets) do
    if vim.deep_equal(preset_keys, keys) then
      keys.style = style
      return keys
    end
  end

  keys.style = "custom"
  return keys
end

return M
