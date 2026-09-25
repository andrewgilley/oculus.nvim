-- The Oculus window paints itself in the colours of the code it sits over, so
-- every window it opens takes its highlights from the window underneath. The
-- inspect overview gets its own namespace, derived from the code window's
-- colorscheme, so opening it never rewrites the shared Oculus namespace or the
-- global groups the inspect tab windows rely on.
local inspect = require("oculus.inspect")
local M = {}

local window_highlight_ns = vim.api.nvim_create_namespace(
  "oculus_window_highlights"
)

local window_highlight_groups = {
  "Normal",
  "NormalFloat",
  "FloatBorder",
  "FloatTitle",
  "FloatFooter",
  "CursorLine",
  "Title",
  "Comment",
  "Identifier",
  "Function",
  "Special",
  "DiagnosticError",
  "DiagnosticWarn",
  "DiagnosticInfo",
  "WinSeparator",
  "OculusInspectOverviewSection",
  "OculusInspectAgentModelSelected",
}

function M.setup(window, internal)
  local function window_highlight_name(win, group)
    if not internal.is_valid_win(win) then
      return group
    end

    for mapping in vim.wo[win].winhighlight:gmatch("[^,]+") do
      local source, target = mapping:match("^%s*([^:]+):([^:]+)%s*$")

      if source == group and target and target ~= "" then
        return target
      end
    end

    return group
  end

  local function source_highlight(win, group)
    local name = window_highlight_name(win, group)

    if internal.is_valid_win(win) then
      local namespace = vim.api.nvim_get_hl_ns({ winid = win })

      if namespace and namespace > 0 then
        local ok, definition = pcall(
          vim.api.nvim_get_hl,
          namespace,
          { name = name, link = false }
        )

        if ok and next(definition) then
          return definition
        end
      end
    end

    local ok, definition = pcall(
      vim.api.nvim_get_hl,
      0,
      { name = name, link = false }
    )

    if ok and next(definition) then
      return definition
    end

    return vim.api.nvim_get_hl(0, { name = group, link = false })
  end

  local function sync_window_highlights(source_win)
    local current_normal = {}
    local current_border = {}

    for _, group in ipairs(window_highlight_groups) do
      local definition = source_highlight(source_win, group)
      vim.api.nvim_set_hl(window_highlight_ns, group, definition)

      if group == "Normal" then
        current_normal = vim.deepcopy(definition)
      elseif group == "FloatBorder" then
        current_border = vim.deepcopy(definition)
      end
    end

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "OculusNormal",
      current_normal
    )

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "NormalFloat",
      current_normal
    )

    vim.api.nvim_set_hl(0, "OculusNormal", current_normal)
    local custom_oculus = source_highlight(source_win, "OculusBorder")

    -- OculusBorder is rewritten below, so only treat it as a new custom
    -- definition when it differs from what the last sync wrote; otherwise
    -- keep the remembered one so repeated syncs don't drop it.
    if not custom_oculus or not custom_oculus.fg then
      window.state.custom_border = nil
    elseif custom_oculus.fg ~= window.state.synced_border_fg then
      window.state.custom_border = {
        fg = custom_oculus.fg,
        bold = custom_oculus.bold,
      }
    end

    if window.state.custom_border then
      current_border.fg = window.state.custom_border.fg

      if window.state.custom_border.bold ~= nil then
        current_border.bold = window.state.custom_border.bold
      end
    end

    if not current_border.fg then
      current_border.fg = current_normal.fg or 0xffffff
    end

    current_border.bg = current_normal.bg
    current_border.ctermbg = current_normal.ctermbg
    window.state.synced_border_fg = current_border.fg

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "OculusBorder",
      current_border
    )

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "FloatBorder",
      current_border
    )

    vim.api.nvim_set_hl(0, "OculusBorder", current_border)

    vim.api.nvim_set_hl(window_highlight_ns, "OculusActivityIcon", {
      fg = "#fbd38d",
      bg = "NONE",
    })

    vim.api.nvim_set_hl(window_highlight_ns, "OculusActivityPreview", {
      fg = "#9ae6b4",
      bg = "NONE",
    })

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "OculusContributorSelected",
      { fg = "#ffffff" }
    )

    vim.api.nvim_set_hl(0, "OculusContributorSelected", {
      fg = "#ffffff",
    })

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "OculusMoveTarget",
      { fg = "#ff9e3b" }
    )

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "OculusDirectory",
      { link = "Directory", default = true }
    )

    vim.api.nvim_set_hl(0, "OculusDirectory", { link = "Directory", default = true })

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "OculusSectionTitle",
      { link = "Keyword", default = true }
    )

    vim.api.nvim_set_hl(0, "OculusSectionTitle", { link = "Keyword", default = true })

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "OculusAccounts",
      { link = "DiagnosticOk", default = true }
    )

    vim.api.nvim_set_hl(0, "OculusAccounts", { link = "DiagnosticOk", default = true })

    vim.api.nvim_set_hl(
      window_highlight_ns,
      "OculusSaved",
      { link = "DiagnosticWarn", default = true }
    )

    vim.api.nvim_set_hl(0, "OculusSaved", { link = "DiagnosticWarn", default = true })

    vim.api.nvim_set_hl(window_highlight_ns, "OculusActivityQueued", {
      fg = "#fbd38d",
      bold = true,
    })
  end

  local function use_window_highlights(win)
    if internal.is_valid_win(win) then
      vim.api.nvim_win_set_hl_ns(win, window_highlight_ns)
    end
  end

  function window.apply_window_highlights(win, source_win)
    if internal.is_valid_win(source_win) then
      window.state.highlight_source_win = source_win
    end

    window.state.highlight_generation =
      (window.state.highlight_generation or 0) + 1

    sync_window_highlights(source_win or window.state.highlight_source_win)
    use_window_highlights(win)
  end

  function window.refresh_window_highlights(source_win)
    if internal.is_valid_win(source_win) then
      window.state.highlight_source_win = source_win
    end

    source_win = source_win or window.state.highlight_source_win

    window.state.highlight_generation =
      (window.state.highlight_generation or 0) + 1

    local generation = window.state.highlight_generation
    sync_window_highlights(source_win)

    vim.schedule(function()
      if generation == window.state.highlight_generation then
        sync_window_highlights(source_win)
      end
    end)
  end

  -- The inspect overview gets its own namespace, derived from the code
  -- window's colorscheme, so opening it never rewrites the shared Oculus
  -- namespace or global groups that the inspect tab windows rely on.
  local function overview_highlight_namespace(source_ns)
    return vim.api.nvim_create_namespace(
      "oculus_overview_highlights_" .. tostring(source_ns or 0)
    )
  end

  function window.is_oculus_highlight_namespace(namespace)
    if not namespace or namespace <= 0 then
      return false
    end

    for name, id in pairs(vim.api.nvim_get_namespaces()) do
      if id == namespace then
        return name == "oculus_window_highlights"
          or name:find("^oculus_overview_highlights_") ~= nil
      end
    end

    return false
  end

  function window.apply_overview_highlights(win, source_win)
    if not internal.is_valid_win(win) then
      return
    end

    local source_ns = internal.is_valid_win(source_win)
        and vim.api.nvim_get_hl_ns({ winid = source_win })
      or 0

    if window.is_oculus_highlight_namespace(source_ns) then
      source_ns = 0
    end

    local namespace = overview_highlight_namespace(source_ns)

    if source_ns > 0 then
      for name, definition in pairs(vim.api.nvim_get_hl(source_ns, {})) do
        pcall(vim.api.nvim_set_hl, namespace, name, definition)
      end
    end

    local normal = source_highlight(source_win, "Normal")
    local border = vim.deepcopy(source_highlight(source_win, "FloatBorder"))

    if window.state.custom_border then
      border.fg = window.state.custom_border.fg

      if window.state.custom_border.bold ~= nil then
        border.bold = window.state.custom_border.bold
      end
    end

    border.fg = border.fg or normal.fg or 0xffffff
    border.bg = normal.bg
    border.ctermbg = normal.ctermbg

    for _, group in ipairs({ "Normal", "NormalFloat", "OculusNormal" }) do
      vim.api.nvim_set_hl(namespace, group, normal)
    end

    for _, group in ipairs({ "FloatBorder", "OculusBorder" }) do
      vim.api.nvim_set_hl(namespace, group, border)
    end

    vim.api.nvim_win_set_hl_ns(win, namespace)
    return namespace
  end

  local highlight_autocmd_group = vim.api.nvim_create_augroup(
    "OculusWindowHighlights",
    { clear = true }
  )

  vim.api.nvim_create_autocmd("ColorScheme", {
    group = highlight_autocmd_group,
    callback = function()
      window.refresh_window_highlights()
    end,
  })

  return {
    use_window_highlights = use_window_highlights,
    sync_window_highlights = sync_window_highlights,
  }
end

return M
