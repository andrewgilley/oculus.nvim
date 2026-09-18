-- Plugins that switch the colorscheme per filetype get two things from an
-- inspection: the code's colorscheme on inspected buffers, which are scratch
-- buffers such plugins normally skip, and a pause while Oculus builds its own
-- floats, whose scratch buffers would otherwise pull in a fallback scheme.
--
-- The plugin is described by an adapter, set with the `inspect_colorscheme`
-- option:
--
--   inspect_colorscheme = {
--     apply = function(buf) end,          -- colour one buffer for its filetype
--     enabled = function() return true end,
--     set_enabled = function(enabled) end,
--   }
--
-- Set it to false to turn the integration off. When it is not set,
-- reliquary.nvim is used if it is installed.
local M = {}

local function reliquary(load)
  local module = package.loaded.reliquary

  if not module and load then
    local ok, loaded = pcall(require, "reliquary")
    module = ok and loaded or nil
  end

  if type(module) ~= "table" or type(module.config) ~= "table" then
    return nil
  end

  return {
    apply = type(module.apply) == "function" and module.apply or nil,
    enabled = function()
      return module.config.enabled
    end,
    set_enabled = function(enabled)
      module.config.enabled = enabled
    end,
  }
end

-- The adapter in use, or nil. `load` also loads an installed but not yet
-- required plugin, which only applying a colorscheme should do.
function M.adapter(load)
  local config = (package.loaded.oculus or {}).config or {}
  local configured = config.inspect_colorscheme

  if configured == false then
    return nil
  end

  if type(configured) == "table" then
    return configured
  end

  return reliquary(load)
end

-- Colours an inspected buffer for its filetype. `groups` are the open
-- inspections: one of them may have the plugin paused, and the buffer should
-- still get the colorscheme the plugin would have used.
function M.apply(buf, groups)
  local adapter = M.adapter(true)

  if not adapter or type(adapter.apply) ~= "function" then
    return
  end

  local enabled = adapter.enabled and adapter.enabled()
  local intended = enabled

  for _, group in ipairs(groups or {}) do
    if group.colorscheme_suspended then
      intended = group.colorscheme_suspended.enabled
      break
    end
  end

  local buftype = vim.bo[buf].buftype
  vim.bo[buf].buftype = ""

  if adapter.set_enabled then
    adapter.set_enabled(intended)
  end

  pcall(adapter.apply, buf)

  if adapter.set_enabled then
    adapter.set_enabled(enabled)
  end

  vim.bo[buf].buftype = buftype
end

-- Pauses the plugin for as long as an inspection's overview is open.
function M.suspend(group)
  local adapter = M.adapter(false)

  if not adapter or not adapter.set_enabled or group.colorscheme_suspended then
    return
  end

  group.colorscheme_suspended = {
    enabled = adapter.enabled and adapter.enabled(),
  }

  adapter.set_enabled(false)
end

function M.resume(group)
  local saved = group.colorscheme_suspended
  local adapter = M.adapter(false)
  group.colorscheme_suspended = nil

  if saved and adapter and adapter.set_enabled then
    adapter.set_enabled(saved.enabled)
  end
end

-- Runs callback with the plugin paused, for windows opened in between.
function M.without(callback)
  local adapter = M.adapter(false)

  if not adapter or not adapter.set_enabled then
    return callback()
  end

  local enabled = adapter.enabled and adapter.enabled()
  adapter.set_enabled(false)
  local ok, result = pcall(callback)
  adapter.set_enabled(enabled)

  if not ok then
    error(result, 0)
  end

  return result
end

return M
