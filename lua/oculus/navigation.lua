local M = {}

local defaults = {
  style = "ijkl",
  up = "i",
  down = "k",
  left = "j",
  right = "l",
  inspect = "h",
  inspect_id = "H",
  investigate = "x",
  investigate_id = "X",
}

--- Resolves the navigation configuration from options table or string.
-- Supports:
--   "ijkl" (default) -> up: i, down: k, left: j, right: l, inspect: h, inspect_id: H, investigate: x, investigate_id: X
--   "hjkl"           -> up: k, down: j, left: h, right: l, inspect: i, inspect_id: I, investigate: x, investigate_id: X
--   { up = ..., down = ..., left = ..., right = ..., inspect = ..., inspect_id = ..., investigate = ..., investigate_id = ... }
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

  if type(nav) == "string" then
    local style = nav:lower()

    if style == "hjkl" then
      return {
        style = "hjkl",
        up = "k",
        down = "j",
        left = "h",
        right = "l",
        inspect = "i",
        inspect_id = "I",
        investigate = "x",
        investigate_id = "X",
      }
    else
      return {
        style = "ijkl",
        up = "i",
        down = "k",
        left = "j",
        right = "l",
        inspect = "h",
        inspect_id = "H",
        investigate = "x",
        investigate_id = "X",
      }
    end
  end

  if type(nav) == "table" then
    local style = nav.style

    if style == nil then
      if nav.left == "h" or nav.up == "k" or nav.down == "j" then
        style = "hjkl"
      elseif nav.left == "j" or nav.up == "i" or nav.down == "k" then
        style = "ijkl"
      else
        style = "custom"
      end
    end

    local is_hjkl = style == "hjkl"
    local left = nav.left or (is_hjkl and "h" or "j")
    local down = nav.down or (is_hjkl and "j" or "k")
    local up = nav.up or (is_hjkl and "k" or "i")
    local right = nav.right or "l"
    local inspect = nav.inspect or (left == "h" and "i" or "h")
    local inspect_id = nav.inspect_id or (inspect == "i" and "I" or "H")
    local investigate = nav.investigate or "x"
    local investigate_id = nav.investigate_id or "X"

    return {
      style = style,
      up = up,
      down = down,
      left = left,
      right = right,
      inspect = inspect,
      inspect_id = inspect_id,
      investigate = investigate,
      investigate_id = investigate_id,
    }
  end

  return vim.deepcopy(defaults)
end

return M
