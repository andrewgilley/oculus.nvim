local M = {}

-- Vim's hjkl layout. Each command can be bound to another key in setup().
M.defaults = {
  up = "k",
  down = "j",
  left = "h",
  right = "l",
  inspect = "i",
  inspect_id = "I",
}

--- Resolves the key for each navigation command from the options table.
-- `opts.navigation` maps commands to keys:
--   { up = ..., down = ..., left = ..., right = ..., inspect = ..., inspect_id = ... }
-- Commands missing from it keep their default key.
-- @param opts table|nil
-- @return table
function M.resolve(opts)
  local nav = type(opts) == "table" and opts.navigation or nil
  local keys = {}

  for name, default in pairs(M.defaults) do
    local key = type(nav) == "table" and nav[name] or nil
    keys[name] = type(key) == "string" and key ~= "" and key or default
  end

  return keys
end

return M
