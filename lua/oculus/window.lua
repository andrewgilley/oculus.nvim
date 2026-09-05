local M = {}
local actions = require("oculus.actions")
local browser = require("oculus.browser")
local github = require("oculus.github")
local inspect = require("oculus.inspect")
local codeberg = require("oculus.codeberg")
local navigation = require("oculus.navigation")

local function activity_provider(contributor)
  if contributor and contributor.provider == "codeberg" then
    return codeberg
  end

  return github
end

local function provider_name(contributor)
  return contributor and contributor.provider == "codeberg"
      and "Codeberg"
    or "GitHub"
end

local function contributor_profile_url(contributor)
  local host = contributor and contributor.provider == "codeberg"
      and "https://codeberg.org/"
    or "https://github.com/"

  return host .. vim.uri_encode(contributor.username)
end

local ns = vim.api.nvim_create_namespace("oculus")
local preview_ns = vim.api.nvim_create_namespace("oculus_preview")

local contributor_selection_ns = vim.api.nvim_create_namespace(
  "oculus_contributor_selection"
)

local inspect_loading_ns = vim.api.nvim_create_namespace(
  "oculus_inspect_activity_loading"
)

local activity_page_loading_ns = vim.api.nvim_create_namespace(
  "oculus_activity_page_loading"
)

local activity_inspect_queue_ns = vim.api.nvim_create_namespace(
  "oculus_activity_inspect_queue"
)

local window_highlight_ns = vim.api.nvim_create_namespace(
  "oculus_window_highlights"
)

local sidebar_ns = vim.api.nvim_create_namespace(
  "oculus_window_sidebar"
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

local commit_activity_url
local load_project_activity
local load_project_issues
local target_on_cursor

local default_project_activity_types = {
  "push",
  "merged_pull_request",
  "assigned_issue",
}

local project_activity_categories = {
  { key = "push", label = "Pushed commits" },
  { key = "merged_pull_request", label = "Merged pull requests" },
  { key = "assigned_issue", label = "Assigned issues" },
}

local function project_activity_types_for(project)
  if project.activity_types ~= nil then
    return project.activity_types
  end

  return M.state.opts.project_activity_types
    or default_project_activity_types
end

local autocmd_group = vim.api.nvim_create_augroup(
  "OculusWindow",
  { clear = true }
)

M.state = {
  buf = nil,
  win = nil,
  footer_buf = nil,
  footer_win = nil,
  sidebar_buf = nil,
  sidebar_win = nil,
  sidebar_visible = nil,
  add_dialog_buf = nil,
  add_dialog_win = nil,
  add_input_buf = nil,
  add_input_win = nil,
  add_dialog_step = nil,
  closing_add_dialog = false,
  inspect_input_buf = nil,
  inspect_input_win = nil,
  closing_inspect_input = false,
  view = "contributors",
  contributor = nil,
  activity_scope = nil,
  activity_project = nil,
  events = nil,
  line_targets = {},
  inspect_targets = {},
  activity_title_lines = {},
  activity_expansion_targets = {},
  request_id = 0,
  preview_key = nil,
  preview_items = nil,
  preview_contributor = nil,
  preview_project = nil,
  contributors = {},
  community_view = "projects",
  selected_username = nil,
  selected_project = nil,
  moving_item = nil,
  contributor_offset = 1,
  filter_scope = nil,
  activity_cached = nil,
  activity_notice = nil,
  activity_error = nil,
  activity_loaded = false,
  activity_page = 1,
  activity_loaded_pages = 1,
  activity_page_size = 8,
  activity_source_events = nil,
  activity_has_past = nil,
  project_activity_feed = nil,
  activity_cursor_min_line = 1,
  activity_scroll_limit_line = nil,
  activity_commit_page = false,
  activity_issue_page = false,
  activity_return = nil,
  project_issue_return = nil,
  project_issue_feed = nil,
  activity_inspect_queue = {},
  activity_inspect_queue_active = nil,
  activity_inspect_queue_batch = nil,
  activity_inspect_queue_total = nil,
  activity_inspect_queue_index = nil,
  activity_inspect_queue_completed = nil,
  activity_inspect_queue_continuing = false,
  activity_inspect_queue_deferred_group = nil,
  activity_inspect_queue_number_options = nil,
  activity_inspect_queue_lookup = {},
  activity_inspect_queue_show_highlights = true,
  activity_queue_line_keys = {},
  activity_inspect_queue_scope = nil,
  activity_inspect_queue_running = false,
  activity_loading_timer = nil,
  activity_loading_frame = 1,
  restore_cursor = nil,
  restore_view = nil,
  shortcut_return = nil,
  opening_account_prompt = false,
  origin_tab = nil,
  origin_win = nil,
  origin_view = nil,
  origin_window_options = nil,
  highlight_source_win = nil,
  highlight_generation = 0,
  opts = {},
}

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function is_add_dialog_open()
  return is_valid_win(M.state.add_dialog_win)
end

local function is_inspect_input_open()
  return M.state.inspect_input_active == true
    or is_valid_win(M.state.inspect_input_win)
end

local function window_highlight_name(win, group)
  if not is_valid_win(win) then
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

  if is_valid_win(win) then
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

  if custom_oculus and next(custom_oculus) and custom_oculus.fg and custom_oculus.fg ~= M.state.synced_border_fg then
    current_border.fg = custom_oculus.fg

    if custom_oculus.bold ~= nil then
      current_border.bold = custom_oculus.bold
    end
  end

  if not current_border.fg then
    current_border.fg = current_normal.fg or 0xffffff
  end

  current_border.bg = current_normal.bg
  current_border.ctermbg = current_normal.ctermbg
  M.state.synced_border_fg = current_border.fg

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

  vim.api.nvim_set_hl(
    window_highlight_ns,
    "OculusMoveTarget",
    { fg = "#ff9e3b" }
  )

  vim.api.nvim_set_hl(window_highlight_ns, "OculusActivityQueued", {
    fg = "#fbd38d",
    bold = true,
  })
end

local function use_window_highlights(win)
  if is_valid_win(win) then
    vim.api.nvim_win_set_hl_ns(win, window_highlight_ns)
  end
end

function M.apply_window_highlights(win, source_win)
  if is_valid_win(source_win) then
    M.state.highlight_source_win = source_win
  end

  M.state.highlight_generation =
    (M.state.highlight_generation or 0) + 1

  sync_window_highlights(source_win or M.state.highlight_source_win)
  use_window_highlights(win)
end

function M.refresh_window_highlights(source_win)
  if is_valid_win(source_win) then
    M.state.highlight_source_win = source_win
  end

  source_win = source_win or M.state.highlight_source_win

  M.state.highlight_generation =
    (M.state.highlight_generation or 0) + 1

  local generation = M.state.highlight_generation
  sync_window_highlights(source_win)

  vim.schedule(function()
    if generation == M.state.highlight_generation then
      sync_window_highlights(source_win)
    end
  end)
end

local highlight_autocmd_group = vim.api.nvim_create_augroup(
  "OculusWindowHighlights",
  { clear = true }
)

vim.api.nvim_create_autocmd("ColorScheme", {
  group = highlight_autocmd_group,
  callback = function()
    M.refresh_window_highlights()
  end,
})

local activity_loading_frames = {
  "⠋",
  "⠙",
  "⠹",
  "⠸",
  "⠼",
  "⠴",
  "⠦",
  "⠧",
  "⠇",
  "⠏",
}

local function stop_activity_page_loading()
  local timer = M.state.activity_loading_timer
  M.state.activity_loading_timer = nil
  M.state.activity_loading_frame = 1

  if timer then
    pcall(timer.stop, timer)

    if not timer:is_closing() then
      timer:close()
    end
  end

  if is_valid_buf(M.state.buf) then
    vim.api.nvim_buf_clear_namespace(
      M.state.buf,
      activity_page_loading_ns,
      0,
      -1
    )
  end
end

local function draw_activity_page_loading()
  if M.state.view ~= "activity" or not is_valid_buf(M.state.buf) then
    return
  end

  local title_line = 3

  if vim.api.nvim_buf_line_count(M.state.buf) < title_line then
    return
  end

  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    activity_page_loading_ns,
    0,
    -1
  )

  vim.api.nvim_buf_set_extmark(
    M.state.buf,
    activity_page_loading_ns,
    title_line - 1,
    0,
    {
      virt_text = {
        {
          " " .. activity_loading_frames[M.state.activity_loading_frame],
          "DiagnosticInfo",
        },
      },
      virt_text_pos = "eol",
      hl_mode = "combine",
    }
  )
end

local function start_activity_page_loading()
  stop_activity_page_loading()
  draw_activity_page_loading()

  if is_valid_win(M.state.win) then
    vim.cmd("redraw")
  end

  local timer = vim.uv.new_timer()

  if not timer then
    return
  end

  M.state.activity_loading_timer = timer

  timer:start(80, 80, vim.schedule_wrap(function()
    if M.state.activity_loading_timer ~= timer then
      return
    end

    M.state.activity_loading_frame =
      (M.state.activity_loading_frame % #activity_loading_frames) + 1

    draw_activity_page_loading()
  end))
end

local function dimension(value, total, fallback, minimum)
  local result

  if type(value) == "number" and value > 0 and value <= 1 then
    result = math.floor(total * value)
  else
    result = tonumber(value) or math.floor(total * fallback)
  end

  return math.min(math.max(minimum, math.floor(result)), math.max(1, total - 4))
end

local function is_sidebar_visible()
  if vim.o.columns < 100 then
    return false
  end

  if M.state.sidebar_visible ~= nil then
    return M.state.sidebar_visible
  end

  local opts = M.state.opts or {}
  return opts.sidebar == true
end

local function make_win_config(opts)
  opts = opts or {}
  local total_width = dimension(opts.width, vim.o.columns, 0.89, 54)
  local height = dimension(opts.height, vim.o.lines, 0.80, 16)
  local row = math.max(0, math.min(opts.row or 1, vim.o.lines - height - 2))
  local show_sidebar = is_sidebar_visible()
  local sidebar_width = show_sidebar and (opts.sidebar_width or 26) or 0
  local gap = show_sidebar and 2 or 0
  local width = total_width - sidebar_width - gap
  local col = math.floor((vim.o.columns - total_width) / 2)

  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = opts.border or "rounded",
  }
end

function M.window_config(opts)
  return make_win_config(opts or {})
end

local function sidebar_win_config(opts)
  opts = opts or {}
  local total_width = dimension(opts.width, vim.o.columns, 0.89, 54)
  local height = dimension(opts.height, vim.o.lines, 0.80, 16)
  local row = math.max(0, math.min(opts.row or 1, vim.o.lines - height - 2))
  local sidebar_width = opts.sidebar_width or 26
  local gap = 2
  local main_width = total_width - sidebar_width - gap
  local main_col = math.floor((vim.o.columns - total_width) / 2)
  local col = main_col + main_width + gap

  return {
    relative = "editor",
    width = sidebar_width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    focusable = false,
    border = opts.border or "rounded",
  }
end

local function close_sidebar()
  if is_valid_win(M.state.sidebar_win) then
    vim.api.nvim_win_close(M.state.sidebar_win, true)
  end

  if is_valid_buf(M.state.sidebar_buf) then
    vim.api.nvim_buf_delete(M.state.sidebar_buf, { force = true })
  end

  M.state.sidebar_win = nil
  M.state.sidebar_buf = nil
end

local function make_sidebar_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus-sidebar"
  return buf
end

local function sidebar_sections_for_view(view)
  if is_inspect_input_open() then
    return {
      {
        title = "ACTIONS",
        items = {
          { "<CR>", "Inspect" },
          { "↑ / ↓", "History" },
        },
      },
      {
        title = "GENERAL",
        items = {
          { "<Esc>", "Cancel" },
          { "q", "Cancel" },
        },
      },
    }
  end

  if is_add_dialog_open() then
    if M.state.add_dialog_step == "input" then
      return {
        {
          title = "ACTIONS",
          items = {
            { "<CR>", "Submit" },
          },
        },
        {
          title = "GENERAL",
          items = {
            { "<Esc>", "Back" },
            { "q", "Cancel" },
          },
        },
      }
    else
      local nav = navigation.resolve(M.state.opts)
      local nav_down = nav.down .. " / ↓"
      local nav_up = nav.up .. " / ↑"

      return {
        {
          title = "ACTIONS",
          items = {
            { "<CR>", "Select" },
            { nav_down, "Next" },
            { nav_up, "Previous" },
          },
        },
        {
          title = "GENERAL",
          items = {
            { "<Esc>", "Cancel" },
          },
        },
      }
    end
  end

  local nav = navigation.resolve(M.state.opts)
  local nav_down = nav.down .. " / ↓"
  local nav_up = nav.up .. " / ↑"
  local nav_left = nav.left .. " / ←"
  local nav_right = nav.right .. " / ↵"

  if view == "contributors" then
    local showing_users = M.state.community_view == "users"

    return {
      {
        title = "NAVIGATION",
        items = {
          { nav_down, "Down" },
          { nav_up, "Up" },
          { nav_right, "Select" },
        },
      },
      {
        title = "ACTIONS",
        items = {
          { "v", showing_users and "Projects" or "Users" },
          { "a", "Add" },
          { nav.inspect_id, "Inspect ID" },
          { nav.investigate, "Investigate" },
          { nav.investigate_id, "Investigate ID" },
          { "r", "Remove" },
          { "m", "Move" },
          { "f", "Filters" },
          { "d", "Defaults" },
          { "o", "Profile" },
        },
      },
      {
        title = "GENERAL",
        items = {
          { "?", "Sidebar" },
          { "q", "Close" },
        },
      },
    }
  elseif view == "activity" then
    local actions = {
      { nav.inspect, "Inspect" },
      { nav.inspect_id, "Inspect ID" },
      { nav.investigate, "Investigate" },
      { nav.investigate_id, "Investigate ID" },
      { "Tab", "Queue" },
      { "b", "Browser" },
    }

    if not M.state.activity_commit_page then
      if M.state.activity_issue_page then
        actions[#actions + 1] = { "f", "Filters" }
      elseif M.state.activity_project then
        actions[#actions + 1] = { "u", "Issues" }
      end
    end

    actions[#actions + 1] = { "r", "Refresh" }
    actions[#actions + 1] = { "p", "Older" }

    return {
      {
        title = "NAVIGATION",
        items = {
          { nav_down, "Down" },
          { nav_up, "Up" },
          { nav_left, "Back" },
        },
      },
      {
        title = "INSPECT",
        items = actions,
      },
      {
        title = "GENERAL",
        items = {
          { "?", "Sidebar" },
          { "q", "Close" },
        },
      },
    }
  elseif view == "filters" then
    return {
      {
        title = "NAVIGATION",
        items = {
          { nav_down, "Down" },
          { nav_up, "Up" },
          { nav_left, "Back" },
        },
      },
      {
        title = "ACTIONS",
        items = {
          { "Space", "Toggle" },
          { "a", "All on" },
          { "n", "All off" },
          { "d", "Defaults" },
        },
      },
      {
        title = "GENERAL",
        items = {
          { "?", "Sidebar" },
          { "q", "Close" },
        },
      },
    }
  elseif view == "issue_filters" then
    return {
      {
        title = "NAVIGATION",
        items = {
          { nav_down, "Down" },
          { nav_up, "Up" },
          { nav_left, "Back" },
        },
      },
      {
        title = "ACTIONS",
        items = {
          { "Space", "Select" },
        },
      },
      {
        title = "GENERAL",
        items = {
          { "?", "Sidebar" },
          { "q", "Close" },
        },
      },
    }
  end

  return {
    {
      title = "NAVIGATION",
      items = {
        { nav_left, "Back" },
        { "?", "Back" },
      },
    },
    {
      title = "GENERAL",
      items = {
        { "?", "Sidebar" },
        { "q", "Close" },
      },
    },
  }
end

local function render_sidebar()
  if not is_sidebar_visible() then
    close_sidebar()
    return
  end

  if not is_valid_win(M.state.win) then
    return
  end

  local config = sidebar_win_config(M.state.opts)
  local buf = M.state.sidebar_buf

  if not is_valid_buf(buf) then
    buf = make_sidebar_buf()
    M.state.sidebar_buf = buf
  end

  local sections = sidebar_sections_for_view(M.state.view)
  local lines = {}
  local highlights = {}
  lines[#lines + 1] = ""

  for s_idx, section in ipairs(sections) do
    if s_idx > 1 then
      lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "  " .. section.title

    highlights[#highlights + 1] = {
      line = #lines,
      col_start = 2,
      col_end = -1,
      hl = "Title",
    }

    for _, item in ipairs(section.items) do
      local key = item[1]
      local desc = item[2]
      local key_width = vim.fn.strdisplaywidth(key)
      local pad = math.max(1, 9 - key_width)
      lines[#lines + 1] = "  " .. key .. string.rep(" ", pad) .. desc

      highlights[#highlights + 1] = {
        line = #lines,
        col_start = 2,
        col_end = 2 + #key,
        hl = "Identifier",
      }

      highlights[#highlights + 1] = {
        line = #lines,
        col_start = 2 + #key + pad,
        col_end = -1,
        hl = "Comment",
      }
    end
  end

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, sidebar_ns, 0, -1)

  for _, h in ipairs(highlights) do
    vim.api.nvim_buf_add_highlight(
      buf,
      sidebar_ns,
      h.hl,
      h.line - 1,
      h.col_start,
      h.col_end
    )
  end

  if is_valid_win(M.state.sidebar_win) then
    vim.api.nvim_win_set_config(M.state.sidebar_win, config)
  else
    M.state.sidebar_win = vim.api.nvim_open_win(buf, false, config)
  end

  local sw = M.state.sidebar_win
  vim.wo[sw].wrap = false
  vim.wo[sw].cursorline = false
  vim.wo[sw].number = false
  vim.wo[sw].relativenumber = false
  vim.wo[sw].signcolumn = "no"
  vim.wo[sw].winfixbuf = true

  vim.wo[sw].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
    "FloatBorder:OculusBorder",
    "FloatTitle:OculusBorder",
  }, ",")

  use_window_highlights(sw)
end

local function make_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus"
  return buf
end

local function close_activity_footer()
  if is_valid_win(M.state.footer_win) then
    vim.api.nvim_win_close(M.state.footer_win, true)
  end

  if is_valid_buf(M.state.footer_buf) then
    vim.api.nvim_buf_delete(M.state.footer_buf, { force = true })
  end

  M.state.footer_buf = nil
  M.state.footer_win = nil
end

local function make_footer_buf()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus"
  return buf
end

local function footer_win_config()
  if not is_valid_win(M.state.win) then
    return nil
  end

  local config = vim.api.nvim_win_get_config(M.state.win)
  local row = tonumber(config.row) or 0
  local col = tonumber(config.col) or 0
  local width = vim.api.nvim_win_get_width(M.state.win)
  local height = vim.api.nvim_win_get_height(M.state.win)

  return {
    relative = "editor",
    width = width,
    height = 2,
    row = row + height - 1,
    col = col + 1,
    style = "minimal",
    focusable = false,
    zindex = 60,
  }
end

local function footer_commands_text()
  local nav = navigation.resolve(M.state.opts)

  if M.state.view == "contributors" then
    local showing_users = M.state.community_view == "users"

    return showing_users
        and ("  v projects   a add   %s investigate   r remove   m move   ?: help"):format(nav.investigate)
      or ("  v users   a add   %s investigate   r remove   m move   ?: help"):format(nav.investigate)
  end

  local inspect_key = nav.inspect == nav.investigate and "h" or nav.inspect
  local activity_commands = ("  %s inspect   %s investigate   b browser"):format(inspect_key, nav.investigate)

  if not M.state.activity_commit_page then
    if M.state.activity_issue_page then
      activity_commands = activity_commands .. "   f filters"
    else
      if M.state.activity_project then
        activity_commands = activity_commands .. "   u issues"
      end
    end
  end

  return activity_commands
end

local inspect_input_default_title = "item ID#: "

local function get_inspect_input_title()
  local title = (M.state.opts and type(M.state.opts.inspect_input_title) == "string")
      and M.state.opts.inspect_input_title
    or inspect_input_default_title

  if not title:match("%s$") then
    title = title .. " "
  end

  return title
end

local function render_activity_footer(force)
  if is_sidebar_visible() and not force and not is_inspect_input_open() then
    close_activity_footer()
    return
  end

  local config = footer_win_config()

  if not config then
    return
  end

  local buf = M.state.footer_buf

  if not is_valid_buf(buf) then
    buf = make_footer_buf()
    M.state.footer_buf = buf
  end

  local width = config.width
  local activity_commands = footer_commands_text()
  local footer_line = activity_commands
  local title_start = nil
  local title_end = nil

  if is_inspect_input_open() then
    local tab_space = 4
    local title_str = get_inspect_input_title()
    title_start = #footer_line + tab_space
    footer_line = footer_line .. string.rep(" ", tab_space) .. title_str
    title_end = #footer_line
  end

  local lines = {
    "  " .. string.rep("─", math.max(1, width - 4)),
    footer_line,
  }

  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "WinSeparator", 0, 2, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 1, 2, #activity_commands)

  if title_start and title_end then
    local trimmed_len = #vim.trim(get_inspect_input_title())
    vim.api.nvim_buf_add_highlight(buf, ns, "Title", 1, title_start, title_start + trimmed_len)
  end

  if is_valid_win(M.state.footer_win) then
    vim.api.nvim_win_set_config(M.state.footer_win, config)
  else
    M.state.footer_win = vim.api.nvim_open_win(buf, false, config)
  end

  vim.wo[M.state.footer_win].wrap = false
  vim.wo[M.state.footer_win].cursorline = false

  vim.wo[M.state.footer_win].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
  }, ",")

  use_window_highlights(M.state.footer_win)
  vim.wo[M.state.footer_win].number = false
  vim.wo[M.state.footer_win].relativenumber = false
  vim.wo[M.state.footer_win].signcolumn = "no"
end

local function list_buffer_line_count()
  if not is_valid_win(M.state.win) or not is_valid_buf(M.state.buf) then
    return nil
  end

  if vim.api.nvim_win_get_buf(M.state.win) ~= M.state.buf then
    return nil
  end

  return vim.api.nvim_buf_line_count(M.state.buf)
end

local function update_activity_cursorline()
  if M.state.view ~= "activity" or not is_valid_win(M.state.win) then
    return
  end

  if vim.api.nvim_get_current_win() ~= M.state.win then
    return
  end

  local line_count = list_buffer_line_count()

  if not line_count then
    return
  end

  local footer_height = is_valid_win(M.state.footer_win) and 2 or 0

  local visible_rows = math.max(
    1,
    vim.api.nvim_win_get_height(M.state.win) - footer_height
  )

  local cursor = vim.api.nvim_win_get_cursor(M.state.win)

  local min_line = math.max(
    1,
    math.min(M.state.activity_cursor_min_line or 1, line_count)
  )

  if cursor[1] < min_line then
    cursor = { min_line, 0 }
    vim.api.nvim_win_set_cursor(M.state.win, cursor)
  end

  local limit_line = M.state.activity_scroll_limit_line

  if limit_line then
    limit_line = math.max(min_line, math.min(limit_line, line_count))

    if cursor[1] > limit_line then
      cursor = { limit_line, 0 }
      vim.api.nvim_win_set_cursor(M.state.win, cursor)
    end

    local max_topline = math.max(1, limit_line - visible_rows + 1)
    local view = vim.fn.winsaveview()

    if view.topline > max_topline then
      view.topline = max_topline
      vim.fn.winrestview(view)
    end
  end

  local cursor_row = vim.fn.winline()

  if cursor_row > visible_rows then
    local view = vim.fn.winsaveview()
    view.topline = view.topline + cursor_row - visible_rows
    vim.fn.winrestview(view)
    cursor_row = vim.fn.winline()
  end

  vim.wo[M.state.win].cursorline = cursor_row <= visible_rows
end

local function clamp_list_cursor()
  local line_count = list_buffer_line_count()

  if not line_count then
    return
  end

  if M.state.view == "contributors" then
    local selectable = {}
    local selected_line

    for line, target in pairs(M.state.line_targets) do
      if
        type(target) == "table"
        and type(line) == "number"
        and line >= 1
        and line <= line_count
      then
        selectable[#selectable + 1] = line

        if target.kind == "project" then
          if target.project.repository
            == (M.state.selected_project or {}).repository
          then
            selected_line = line
          end
        elseif target.username == M.state.selected_username then
          selected_line = line
        end
      end
    end

    table.sort(selectable)

    if #selectable == 0 then
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(M.state.win)

    if type(M.state.line_targets[cursor[1]]) == "table" then
      return
    end

    local line

    if selected_line and cursor[1] > selected_line then
      line = selectable[#selectable]

      for _, candidate in ipairs(selectable) do
        if candidate >= cursor[1] then
          line = candidate
          break
        end
      end
    elseif selected_line and cursor[1] < selected_line then
      line = selectable[1]

      for index = #selectable, 1, -1 do
        if selectable[index] <= cursor[1] then
          line = selectable[index]
          break
        end
      end
    else
      line = selectable[1]

      for _, candidate in ipairs(selectable) do
        if math.abs(candidate - cursor[1]) < math.abs(line - cursor[1]) then
          line = candidate
        end
      end
    end

    vim.api.nvim_win_set_cursor(M.state.win, { line, 0 })
    return
  end

  local min_line
  local max_line

  if M.state.view == "activity" then
    min_line = M.state.activity_cursor_min_line
    max_line = M.state.activity_scroll_limit_line
  elseif M.state.view == "filters"
    or M.state.view == "issue_filters"
  then
    for line, target in pairs(M.state.line_targets) do
      if
        type(target) == "table"
        and type(line) == "number"
        and line >= 1
        and line <= line_count
      then
        min_line = math.min(min_line or line, line)
        max_line = math.max(max_line or line, line)
      end
    end
  end

  if not min_line or not max_line then
    return
  end

  min_line = math.max(1, math.min(min_line, line_count))
  max_line = math.max(min_line, math.min(max_line, line_count))
  local cursor = vim.api.nvim_win_get_cursor(M.state.win)
  local line = math.min(math.max(cursor[1], min_line), max_line)

  if line ~= cursor[1] then
    vim.api.nvim_win_set_cursor(M.state.win, { line, 0 })
  end
end

local function set_lines(lines)
  if not is_valid_buf(M.state.buf) then
    return
  end

  vim.bo[M.state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(M.state.buf, 0, -1, false, lines)
  vim.bo[M.state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.state.buf, ns, 0, -1)
  vim.api.nvim_buf_clear_namespace(M.state.buf, preview_ns, 0, -1)

  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    contributor_selection_ns,
    0,
    -1
  )

  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    activity_inspect_queue_ns,
    0,
    -1
  )

  M.state.preview_items = nil
end

local function highlight(line, start_col, end_col, group)
  vim.api.nvim_buf_add_highlight(
    M.state.buf,
    ns,
    group,
    line - 1,
    start_col,
    end_col
  )
end

local function trim_to_width(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end

  if text:sub(-1) == '"' and width >= 2 then
    return vim.fn.strcharpart(text, 0, math.max(0, width - 2)) .. '…"'
  end

  return vim.fn.strcharpart(text, 0, math.max(1, width - 1)) .. "…"
end

local function pad_cell(text, width)
  local value = trim_to_width(text, width)
  local padding = math.max(0, width - vim.fn.strdisplaywidth(value))
  return value .. string.rep(" ", padding)
end

local function left_pad_cell(text, width)
  local value = trim_to_width(text, width)
  local padding = math.max(0, width - vim.fn.strdisplaywidth(value))
  return string.rep(" ", padding) .. value
end

local function display_contributors(contributors)
  local result = {}

  for _, contributor in ipairs(contributors or {}) do
    local copy = vim.deepcopy(contributor)
    copy.description = nil
    result[#result + 1] = copy
  end

  return result
end

local function display_projects(projects)
  local result = {}

  for _, project in ipairs(projects or {}) do
    if type(project) == "table"
      and type(project.repository) == "string"
      and project.repository ~= ""
    then
      result[#result + 1] = vim.deepcopy(project)
    end
  end

  return result
end

local function project_key(project)
  if type(project) ~= "table" or not project.repository then
    return nil
  end

  return (project.provider == "codeberg" and "codeberg" or "github")
    .. ":"
    .. project.repository:lower()
end

local function project_title(project)
  return project.repository
end

local function has_project(projects, candidate)
  local key = project_key(candidate)

  if not key then
    return false
  end

  for _, project in ipairs(projects or {}) do
    if project_key(project) == key then
      return true
    end
  end

  return false
end

local function contributor_key(contributor)
  if type(contributor) ~= "table" or not contributor.username then
    return nil
  end

  return ("%s:%s"):format(
    contributor.provider == "codeberg" and "codeberg" or "github",
    contributor.username:lower()
  )
end

local function has_contributor(contributors, candidate)
  local key = contributor_key(candidate)

  if not key then
    return false
  end

  for _, contributor in ipairs(contributors or {}) do
    if contributor_key(contributor) == key then
      return true
    end
  end

  return false
end

local function visible_contributors()
  return M.state.contributors
end

local function visible_projects()
  return display_projects(M.state.opts.projects)
end

local function utc_time(year, month, day, hour, minute, second)
  year = month <= 2 and year - 1 or year
  local era = math.floor(year / 400)
  local year_of_era = year - era * 400
  local month_index = month > 2 and month - 3 or month + 9
  local day_of_year = math.floor((153 * month_index + 2) / 5) + day - 1

  local day_of_era = year_of_era * 365
    + math.floor(year_of_era / 4)
    - math.floor(year_of_era / 100)
    + day_of_year

  local days = era * 146097 + day_of_era - 719468
  return days * 86400 + hour * 3600 + minute * 60 + second
end

-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 8 Parse activity timestamps with UTC offsets
local function activity_time(timestamp)
  if not timestamp then
    return "unknown time"
  end

  local year, month, day, hour, minute, second, offset_sign, offset_hour, offset_minute =
    timestamp:match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)([+-])(%d%d):(%d%d)$"
    )

  if not year then
    year, month, day, hour, minute, second = timestamp:match(
      "^(%d%d%d%d)%-(%d%d)%-(%d%d)T(%d%d):(%d%d):(%d%d)Z$"
    )
  end

  if not year then
    return timestamp
  end

  local local_time = utc_time(
    tonumber(year),
    tonumber(month),
    tonumber(day),
    tonumber(hour),
    tonumber(minute),
    tonumber(second)
  )

  if offset_sign then
    local offset = tonumber(offset_hour) * 3600 + tonumber(offset_minute) * 60
    local_time = local_time + (offset_sign == "+" and -offset or offset)
  end

  local event_date = os.date("*t", local_time)
  local time = os.date("%I:%M %p", local_time):gsub("^0", " ")

  local date = ("%02d/%02d/%02d"):format(
    event_date.month,
    event_date.day,
    event_date.year % 100
  )

  return date .. " — " .. time
end

-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 8
local function footer(lines, text)
  lines[#lines + 1] = "  " .. text
end

local function preview_left_width(window_width)
  local preferred = math.max(40, math.floor(window_width * 0.52))
  return math.max(30, math.min(preferred, window_width - 22))
end

local function is_formatted_preview(text)
  return text:match('^".*"$')
    or text:match('^PR #%d+ · ".*"$')
    or text:match("^• ")
end

local function event_detail(item)
  if item.detail then
    if type(item.detail) == "table" then
      return item.detail
    end

    local detail = item.detail

    if not is_formatted_preview(detail) then
      detail = '"' .. detail .. '"'
    end

    return detail
  end
end

local function quoted_detail_line(text)
  if text == "..." then
    return text
  end

  if is_formatted_preview(text) then
    return text
  end

  return '"' .. text .. '"'
end

local function event_summary(item)
  if item.summary then
    local summary = item.summary

    if not is_formatted_preview(summary) then
      summary = '"' .. summary .. '"'
    end

    return summary
  end
end

local function event_text(item, width)
  local detail = event_summary(item) or event_detail(item)

  if type(detail) == "table" then
    detail = nil
  end

  if detail then
    local separator = " · "

    if width then
      local separator_width = vim.fn.strdisplaywidth(separator)
      local text_width = vim.fn.strdisplaywidth(item.text)
      local detail_width = width - text_width - separator_width

      if detail_width < 1 then
        return item.text
      end

      return item.text .. separator .. trim_to_width(detail, detail_width)
    end

    return item.text .. separator .. detail
  end

  return item.text
end

local activity_timestamp_width = 19
local activity_timestamp_gap = "  "

local function activity_title_highlight_end(line)
  return math.max(
    0,
    #line - activity_timestamp_width - #activity_timestamp_gap
  )
end

local function activity_content_width(width)
  return math.max(
    1,
    width
      - activity_timestamp_width
      - vim.fn.strdisplaywidth(activity_timestamp_gap)
  )
end

local function activity_item_line(item, timestamp, width)
  local content_width = activity_content_width(width)
  local prefix = ("  %s  "):format(item.icon)
  local text_width = math.max(1, content_width - vim.fn.strdisplaywidth(prefix))
  local content = prefix .. event_text(item, text_width)

  return pad_cell(content, content_width)
    .. activity_timestamp_gap
    .. left_pad_cell(timestamp, activity_timestamp_width)
end

local function activity_loading_line(line, frame, has_timestamp)
  if not has_timestamp then
    local body = line:gsub("%s+$", "")
    return body .. " " .. frame, #body + 1
  end

  local timestamp_width = 19
  local gap_width = 2
  local tail_width = timestamp_width + gap_width

  if vim.fn.strdisplaywidth(line) <= tail_width then
    return line .. " " .. frame, #line + 1
  end

  local tail_start = vim.fn.strchars(line)
  local tail = ""

  while tail_start > 0
    and vim.fn.strdisplaywidth(tail) < tail_width
  do
    tail_start = tail_start - 1
    tail = vim.fn.strcharpart(line, tail_start)
  end

  local content = vim.fn.strcharpart(line, 0, tail_start)

  local content_width =
    vim.fn.strdisplaywidth(line) - vim.fn.strdisplaywidth(tail)

  local body = content:gsub("%s+$", "")
  local body_width = math.max(1, content_width - 2)
  body = trim_to_width(body, body_width)

  while vim.fn.strdisplaywidth(body) > body_width do
    body = vim.fn.strcharpart(
      body,
      0,
      math.max(0, vim.fn.strchars(body) - 1)
    )
  end

  local spinner_column = #body + 1

  return pad_cell(body .. " " .. frame, content_width) .. tail,
    spinner_column
end

local function preview_lines(item, width)
  local summary = event_summary(item)
  local detail = event_detail(item)

  if not summary and not detail then
    return nil
  end

  local indent = "     "
  local row_width = activity_content_width(width)

  local content_width = math.max(
    1,
    row_width - vim.fn.strdisplaywidth(indent)
  )

  local lines = {}
  local details = {}

  if summary then
    details[#details + 1] = { text = summary }
  end

  if type(detail) == "table" then
    for index, detail_item in ipairs(detail) do
      details[#details + 1] = {
        text = detail_item,
        detail_index = vim.trim(tostring(detail_item)) ~= "..."
            and index
          or nil,
      }
    end
  elseif detail and detail ~= summary then
    details[#details + 1] = { text = detail }
  end

  local detail_indices = {}

  for _, detail_item in ipairs(details) do
    local text = trim_to_width(
      quoted_detail_line(detail_item.text),
      content_width
    )

    lines[#lines + 1] = indent .. pad_cell(text, content_width)
    detail_indices[#lines] = detail_item.detail_index
  end

  return lines, detail_indices
end

local function without_preview(item)
  local result = vim.tbl_extend("force", {}, item)
  result.detail = nil
  result.summary = nil
  return result
end

local function project_push_author(event)
  local actor = type(event.actor) == "table" and event.actor or {}
  local handle = actor.login or actor.username or actor.handle

  if type(handle) == "string" and handle ~= "" then
    return "@" .. handle
  end

  if type(actor.name) == "string" and actor.name ~= "" then
    return actor.name
  end

  local commits = event.payload and event.payload.commits or {}
  local commit = commits[#commits]
  local author = type(commit) == "table" and commit.author or nil

  if type(author) == "table" then
    local author_handle = author.login or author.username

    if type(author_handle) == "string" and author_handle ~= "" then
      return "@" .. author_handle
    end

    author = author.name
  end

  return type(author) == "string" and author ~= "" and author or nil
end

local function activity_identity(value)
  if type(value) == "string" then
    return value ~= "" and value or nil
  end

  if type(value) ~= "table" then
    return nil
  end

  local handle = value.login or value.username or value.handle

  if type(handle) == "string" and handle ~= "" then
    return "@" .. handle:gsub("^@", "")
  end

  return type(value.name) == "string" and value.name ~= ""
      and value.name
    or nil
end

local function project_pull_request_title(event, text)
  local payload = event.payload or {}
  local pull_request = payload.pull_request or {}

  local merged = payload.action == "merged"
    or (payload.action == "closed" and (
      pull_request.merged == true
      or pull_request.merged_at ~= nil
      or pull_request.merged_by ~= nil
    ))

  if not merged then
    return text
  end

  local author = activity_identity(
    pull_request.user or pull_request.author
  )

  local merger = activity_identity(
    pull_request.merged_by or payload.merged_by or payload.merger
  )
    or activity_identity(event.actor)

  local number = pull_request.number or payload.number

  local repository = event.repo
    and (event.repo.name or event.repo.full_name)

  if merger and number and repository then
    if author and merger:lower() == author:lower() then
      return ("%s merged pr #%s in %s"):format(
        merger,
        number,
        repository
      )
    end

    if author then
      return ("%s merged pr #%s from %s in %s"):format(
        merger,
        number,
        author,
        repository
      )
    end

    return ("%s merged pr #%s in %s"):format(
      merger,
      number,
      repository
    )
  end

  return text
end

M._project_pull_request_title = project_pull_request_title

local function render_preview_panel(items)
  if
    M.state.view ~= "contributors"
    or not is_valid_buf(M.state.buf)
    or not is_valid_win(M.state.win)
  then
    return
  end

  vim.api.nvim_buf_clear_namespace(M.state.buf, preview_ns, 0, -1)
  M.state.preview_items = items
  local window_width = vim.api.nvim_win_get_width(M.state.win)
  local left_width = preview_left_width(window_width)
  local right_width = math.max(16, window_width - left_width - 3)
  local line_count = vim.api.nvim_buf_line_count(M.state.buf)

  for line = 1, line_count do
    local item = items[line]
    local text = item and trim_to_width(item[1], right_width - 1) or ""
    local group = item and item[2] or "NormalFloat"

    vim.api.nvim_buf_set_extmark(M.state.buf, preview_ns, line - 1, 0, {
      virt_text = {
        { "│", "WinSeparator" },
        { " " .. text, group },
      },
      virt_text_win_col = left_width,
      hl_mode = "combine",
    })
  end
end

local function preview_items(contributor)
  return {
    [2] = { "USER", "Title" },
    [4] = { "@" .. contributor.username, "Identifier" },
    [5] = { provider_name(contributor), "Comment" },
  }
end

local function wrapped_preview_text(text, width, limit)
  if type(text) ~= "string" or vim.trim(text) == "" then
    return {}
  end

  width = math.max(8, width or 32)
  limit = math.max(1, limit or 3)
  local words = vim.split(vim.trim(text):gsub("%s+", " "), " ")
  local lines = {}
  local index = 1

  while index <= #words and #lines < limit do
    local line = words[index]
    index = index + 1

    while index <= #words
      and vim.fn.strdisplaywidth(line .. " " .. words[index]) <= width
    do
      line = line .. " " .. words[index]
      index = index + 1
    end

    if #lines == limit - 1 and index <= #words then
      line = line .. " " .. table.concat(words, " ", index)
      index = #words + 1
    end

    lines[#lines + 1] = trim_to_width(line, width)
  end

  return lines
end

local function project_preview_items(project, width)
  local provider = project.provider == "codeberg" and "Codeberg" or "GitHub"

  local items = {
    [2] = { "PROJECT", "Title" },
    [4] = { project_title(project), "Identifier" },
    [5] = { provider, "Comment" },
  }

  for index, line in ipairs(wrapped_preview_text(
    project.description,
    width,
    3
  )) do
    items[6 + index] = { line, "Comment" }
  end

  return items
end

local function activity_types_for(contributor)
  local overrides = M.state.opts.user_activity_types or {}
  local username = contributor.username
  local user_types = overrides[username] or overrides[username:lower()]

  if user_types ~= nil then
    return user_types
  end

  if contributor.activity_types ~= nil then
    return contributor.activity_types
  end

  return M.state.opts.activity_types
end

local function queue_preview(contributor)
  if
    not contributor
    or M.state.view ~= "contributors"
  then
    return
  end

  local key = contributor_key(contributor)

  if M.state.preview_key == key then
    return
  end

  M.state.preview_key = key
  M.state.preview_contributor = contributor
  render_preview_panel(preview_items(contributor))
end

local function fetch_project_description(project, callback)
  if not project or not project.repository then
    if callback then
      callback(nil)
    end

    return
  end

  local provider = project.provider == "codeberg" and codeberg or github

  if not provider or type(provider.repository_info) ~= "function" then
    if callback then
      callback(nil)
    end

    return
  end

  provider.repository_info(
    project.repository,
    M.state.opts or {},
    function(info)
      local desc = info
          and type(info.description) == "string"
          and info.description
        or nil

      if callback then
        callback(desc)
      end
    end
  )
end

local function queue_project_preview(project)
  if not project or M.state.view ~= "contributors" then
    return
  end

  local key = project_key(project)

  if M.state.preview_key == key then
    return
  end

  M.state.preview_key = key
  M.state.preview_project = project
  local window_width = vim.api.nvim_win_get_width(M.state.win)
  local left_width = preview_left_width(window_width)
  local preview_width = math.max(15, window_width - left_width - 5)
  render_preview_panel(project_preview_items(project, preview_width))

  if not project.description or project.description == "" then
    fetch_project_description(project, function(desc)
      if
        desc
        and desc ~= ""
        and M.state.preview_key == key
        and is_valid_win(M.state.win)
      then
        project.description = desc
        persist_projects()
        render_preview_panel(project_preview_items(project, preview_width))
      end
    end)
  end
end

function M.load_project_descriptions(opts, callback)
  local config = opts or M.state.opts or {}
  local projects = config.projects or {}
  local pending = 0
  local updated_any = false

  for _, project in ipairs(projects) do
    if
      type(project) == "table"
      and type(project.repository) == "string"
      and project.repository ~= ""
      and (not project.description or project.description == "")
    then
      local provider = project.provider == "codeberg" and codeberg or github

      if provider and type(provider.repository_info) == "function" then
        pending = pending + 1

        provider.repository_info(project.repository, config, function(info)
          pending = pending - 1

          if
            info
            and type(info.description) == "string"
            and info.description ~= ""
          then
            if project.description ~= info.description then
              project.description = info.description
              updated_any = true

              if
                M.state.preview_project
                and project_key(M.state.preview_project) == project_key(project)
                and is_valid_win(M.state.win)
              then
                local window_width = vim.api.nvim_win_get_width(M.state.win)
                local left_width = preview_left_width(window_width)
                local preview_width = math.max(15, window_width - left_width - 5)

                render_preview_panel(
                  project_preview_items(project, preview_width)
                )
              end
            end
          end

          if pending == 0 then
            if updated_any and config.persist_projects then
              persist_projects()
            end

            if callback then
              callback(projects)
            end
          end
        end)
      end
    end
  end

  if pending == 0 and callback then
    callback(projects)
  end
end

local function update_contributor_selection()
  if not is_valid_buf(M.state.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    contributor_selection_ns,
    0,
    -1
  )

  if
    M.state.view ~= "contributors"
    or not is_valid_win(M.state.win)
  then
    return
  end

  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]

  if type(M.state.line_targets[line]) ~= "table" then
    return
  end

  local text = vim.api.nvim_buf_get_lines(
    M.state.buf,
    line - 1,
    line,
    false
  )[1] or ""

  local visible_text = text:gsub("%s+$", "")

  if #visible_text > 2 then
    local hl_group = M.state.moving_item and "OculusMoveTarget"
      or "OculusContributorSelected"

    vim.api.nvim_buf_set_extmark(
      M.state.buf,
      contributor_selection_ns,
      line - 1,
      2,
      {
        end_row = line - 1,
        end_col = #visible_text,
        hl_group = hl_group,
        hl_mode = "combine",
        priority = 10000,
      }
    )
  end
end

local function render_contributors()
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "contributors"
  M.state.contributor = nil
  M.state.activity_scope = nil
  M.state.activity_project = nil
  M.state.events = nil
  M.state.line_targets = {}
  M.state.preview_key = nil
  M.state.preview_project = nil
  local community_view = M.state.community_view or "projects"
  local showing_users = community_view == "users"

  local lines = {
    "",
    "  ACTIVITY",
    "",
    "",
  }

  local contributors = showing_users and visible_contributors() or {}

  local projects = not showing_users
      and visible_projects()
    or {}

  local left_width = preview_left_width(vim.api.nvim_win_get_width(M.state.win))
  local username_width = 5

  for _, contributor in ipairs(contributors) do
    username_width = math.max(username_width, #(contributor.username) + 1)
  end

  username_width = math.min(username_width, math.max(5, left_width - 2))
  local project_lines = {}
  local project_heading_line

  if not showing_users then
    project_heading_line = #lines + 1
    lines[#lines + 1] = "  PROJECTS"

    for _, project in ipairs(projects) do
      local line = #lines + 1

      lines[line] = pad_cell(
        "  " .. project_title(project),
        left_width
      )

      M.state.line_targets[line] = {
        kind = "project",
        project = project,
      }

      project_lines[#project_lines + 1] = line
    end

    if #projects == 0 then
      lines[#lines + 1] = "  No projects configured."
    end
  end

  local user_heading_line

  if showing_users then
    user_heading_line = #lines + 1
    lines[#lines + 1] = "  " .. pad_cell("USERS", username_width)
  end

  local selected_index = 1

  for index, contributor in ipairs(contributors) do
    if contributor.username == M.state.selected_username then
      selected_index = index
      break
    end
  end

  local list_limit = math.max(
    1,
    math.floor(tonumber(M.state.opts.contributor_list_limit) or 20)
  )

  local window_height = vim.api.nvim_win_get_height(M.state.win)
  local footer_space = is_sidebar_visible() and 0 or 4

  list_limit = math.min(
    list_limit,
    math.max(1, window_height - 7 - #project_lines - footer_space)
  )

  local max_offset = math.max(1, #contributors - list_limit + 1)

  local offset = math.min(
    math.max(1, M.state.contributor_offset or 1),
    max_offset
  )

  if selected_index < offset then
    offset = selected_index
  elseif selected_index >= offset + list_limit then
    offset = selected_index - list_limit + 1
  end

  M.state.contributor_offset = offset

  if showing_users then
    for index = offset, math.min(#contributors, offset + list_limit - 1) do
      local contributor = contributors[index]
      local line = #lines + 1
      local handle = "@" .. contributor.username
      local prefix = "  " .. pad_cell(handle, username_width)
      lines[line] = pad_cell(prefix, left_width)
      M.state.line_targets[line] = contributor
    end
  end

  if showing_users and #contributors == 0 then
    lines[#lines + 1] = "  No users added."
    lines[#lines + 1] = "  a add account"
  end

  local separator_line = nil
  local commands_line = nil

  if not is_sidebar_visible() then
    while #lines < window_height - 2 do
      lines[#lines + 1] = ""
    end

    lines[#lines + 1] = "  " .. string.rep("─", math.max(1, left_width - 2))
    separator_line = #lines
    local nav = navigation.resolve(M.state.opts)

    footer(lines, showing_users
        and ("v projects  a add  %s investigate  r remove  m move  ?: help"):format(nav.investigate)
      or ("v users  a add  %s investigate  r remove  m move  ?: help"):format(nav.investigate))

    commands_line = #lines
  else
    while #lines < window_height do
      lines[#lines + 1] = ""
    end
  end

  set_lines(lines)
  vim.wo[M.state.win].cursorline = false
  highlight(2, 2, -1, "Title")
  highlight(3, 2, -1, "Comment")

  if project_heading_line then
    highlight(project_heading_line, 2, -1, "Title")
  end

  if user_heading_line then
    highlight(user_heading_line, 2, -1, "Title")
  end

  for line, _ in pairs(M.state.line_targets) do
    local target = M.state.line_targets[line]

    highlight(
      line,
      2,
      target.kind == "project" and -1 or 2 + username_width,
      "Identifier"
    )
  end

  if separator_line then
    highlight(separator_line, 2, -1, "WinSeparator")
  end

  if commands_line then
    highlight(commands_line, 2, -1, "Comment")
  end

  local selected_line

  for line, target in pairs(M.state.line_targets) do
    if target.kind == "project"
      and target.project.repository
        == (M.state.selected_project or {}).repository
    then
      selected_line = line
      break
    elseif target.kind ~= "project"
      and target.username == M.state.selected_username
    then
      selected_line = line
      break
    end
  end

  if not selected_line then
    for line, target in pairs(M.state.line_targets) do
      if type(target) == "table"
        and (not selected_line or line < selected_line)
      then
        selected_line = line
      end
    end
  end

  if selected_line and is_valid_win(M.state.win) then
    local target = M.state.line_targets[selected_line]

    if target.kind == "project" then
      M.state.selected_project = target.project
      M.state.selected_username = nil
    else
      M.state.selected_project = nil
      M.state.selected_username = target.username
    end

    vim.api.nvim_win_set_cursor(M.state.win, { selected_line, 0 })

    if target.kind == "project" then
      queue_project_preview(target.project)
    else
      queue_preview(target)
    end

    update_contributor_selection()
  else
    local preview_contributor = M.state.preview_contributor
    local preview_project = M.state.preview_project

    if preview_project then
      queue_project_preview(preview_project)
    elseif preview_contributor then
      queue_preview(preview_contributor)
    else
      render_preview_panel({
        [2] = {
          showing_users and "USER" or "PROJECT",
          "Title",
        },
      })
    end
  end

  render_sidebar()
end

local function filter_type_set(scope)
  local types
  local categories

  if scope.project then
    types = project_activity_types_for(scope.project)
    categories = project_activity_categories
  elseif scope.global then
    types = M.state.opts.activity_types
    categories = actions.event_types
  else
    types = activity_types_for(scope)
    categories = actions.event_types
  end

  local enabled = {}

  if types == nil then
    for _, category in ipairs(categories) do
      enabled[category.key or category] = true
    end
  else
    for _, category in ipairs(types) do
      enabled[category] = true
    end
  end

  return enabled
end

local function persist_filter_config()
  if M.state.opts.persist_filters then
    local ok, err = require("oculus.storage").save(
      M.state.opts.state_file,
      M.state.opts
    )

    if not ok then
      vim.notify(
        "Oculus could not save activity filters: " .. tostring(err),
        vim.log.levels.ERROR
      )
    end
  end
end

local function persist_contributors()
  M.state.opts.contributors = vim.deepcopy(M.state.contributors)

  if not M.state.opts.persist_contributors then
    return
  end

  local ok, err = require("oculus.storage").save(
    M.state.opts.state_file,
    M.state.opts
  )

  if not ok then
    vim.notify(
      "Oculus could not save users: " .. tostring(err),
      vim.log.levels.ERROR
    )
  end
end

local function persist_projects()
  if not M.state.opts.persist_projects then
    return
  end

  local ok, err = require("oculus.storage").save(
    M.state.opts.state_file,
    M.state.opts
  )

  if not ok then
    vim.notify(
      "Oculus could not save projects: " .. tostring(err),
      vim.log.levels.ERROR
    )
  end
end

local function save_filter_type_set(scope, enabled)
  local types = {}

  local categories = scope.project
      and project_activity_categories
    or actions.event_types

  for _, category in ipairs(categories) do
    local key = category.key or category

    if enabled[key] then
      types[#types + 1] = key
    end
  end

  if scope.project then
    if scope.project.activity_types ~= nil then
      for _, project in ipairs(M.state.opts.projects or {}) do
        if project.repository == scope.project.repository then
          project.activity_types = types
          break
        end
      end
    else
      M.state.opts.project_activity_types = types
    end
  elseif scope.global then
    M.state.opts.activity_types = types
  else
    M.state.opts.user_activity_types = M.state.opts.user_activity_types or {}
    M.state.opts.user_activity_types[scope.username] = types
  end

  persist_filter_config()
end

local function render_filters(scope, selected_type)
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "filters"
  M.state.filter_scope = scope
  M.state.line_targets = {}

  local scope_name = scope.project
      and project_title(scope.project)
    or scope.global
      and "All contributors"
    or ("@" .. scope.username)

  local categories = scope.project
      and project_activity_categories
    or actions.event_types

  local enabled = filter_type_set(scope)

  local lines = {
    "",
    "  ACTIVITY TYPES",
    "  " .. scope_name,
    "  Checked event kinds are shown in previews and activity feeds.",
    "",
  }

  local selected_line

  for _, category in ipairs(categories) do
    local event_type = category.key or category
    local label = category.label or actions.type_label(event_type)
    local line = #lines + 1
    local checkbox = enabled[event_type] and "[x]" or "[ ]"

    lines[line] = ("  %s  %-28s %s"):format(
      checkbox,
      label,
      event_type
    )

    M.state.line_targets[line] = { event_type = event_type }

    if event_type == selected_type then
      selected_line = line
    end
  end

  local width = vim.api.nvim_win_get_width(M.state.win)
  local separator_line = nil
  local commands_line = nil

  if not is_sidebar_visible() then
    local nav = navigation.resolve(M.state.opts)
    lines[#lines + 1] = "  " .. string.rep("─", math.max(1, width - 4))
    separator_line = #lines
    footer(lines, ("? shortcuts   %s/← back   q close"):format(nav.left))
    commands_line = #lines
  end

  set_lines(lines)
  vim.wo[M.state.win].cursorline = true
  highlight(2, 2, -1, "Title")
  highlight(3, 2, -1, "Identifier")
  highlight(4, 2, -1, "Comment")

  for line, target in pairs(M.state.line_targets) do
    highlight(
      line,
      2,
      5,
      enabled[target.event_type] and "DiagnosticOk" or "Comment"
    )

    highlight(line, 7, 35, "Function")
    highlight(line, 36, -1, "Comment")
  end

  if separator_line then
    highlight(separator_line, 2, -1, "WinSeparator")
  end

  if commands_line then
    highlight(commands_line, 2, -1, "Comment")
  end

  render_sidebar()
  vim.api.nvim_win_set_cursor(M.state.win, { selected_line or 6, 0 })
end

local function toggle_filter_type()
  if M.state.view ~= "filters" then
    return
  end

  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local target = M.state.line_targets[line]

  if not target or not target.event_type then
    return
  end

  local enabled = filter_type_set(M.state.filter_scope)
  enabled[target.event_type] = not enabled[target.event_type]
  save_filter_type_set(M.state.filter_scope, enabled)
  render_filters(M.state.filter_scope, target.event_type)
end

local function set_all_filter_types(value)
  if M.state.view ~= "filters" then
    return
  end

  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local target = M.state.line_targets[line]
  local enabled = {}

  local categories = M.state.filter_scope.project
      and project_activity_categories
    or actions.event_types

  for _, category in ipairs(categories) do
    enabled[category.key or category] = value
  end

  save_filter_type_set(M.state.filter_scope, enabled)
  render_filters(M.state.filter_scope, target and target.event_type or nil)
end

local function reset_filter_types_to_default()
  if M.state.view == "filters"
    and M.state.filter_scope
    and M.state.filter_scope.project
  then
    M.state.opts.project_activity_types = nil
    persist_filter_config()
    render_filters(M.state.filter_scope)
    return
  end

  if M.state.view ~= "contributors" then
    return
  end

  M.state.opts.activity_types = nil
  M.state.opts.user_activity_types = {}
  persist_filter_config()
  render_contributors()
end

local issue_filter_options = {
  {
    heading = "STATUS",
    dimension = "state",
    choices = {
      { value = "all", label = "All issues" },
      { value = "open", label = "Open issues" },
      { value = "closed", label = "Closed issues" },
    },
  },
  {
    heading = "ASSIGNMENT",
    dimension = "assignment",
    choices = {
      { value = "all", label = "Any assignment" },
      { value = "assigned", label = "Assigned issues" },
      { value = "unassigned", label = "Unassigned issues" },
    },
  },
}

local function project_issue_filter_key(project)
  return table.concat({
    project.provider == "codeberg" and "codeberg" or "github",
    project.repository:lower(),
  }, ":")
end

local function project_issue_filters_for(project)
  M.state.opts.project_issue_filters =
    M.state.opts.project_issue_filters or {}

  local key = project_issue_filter_key(project)
  local filters = M.state.opts.project_issue_filters[key]

  if type(filters) ~= "table" then
    filters = { state = "open", assignment = "all" }
    M.state.opts.project_issue_filters[key] = filters
  end

  return filters
end

local function save_project_issue_filter(project, dimension, value)
  local filters = project_issue_filters_for(project)
  filters[dimension] = value
  M.state.project_issue_feed = nil
  persist_filter_config()
end

local function render_issue_filters(project, selected_dimension)
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "issue_filters"
  M.state.line_targets = {}
  local filters = project_issue_filters_for(project)

  local lines = {
    "",
    "  ISSUE FILTERS",
    "  " .. project_title(project),
    "",
  }

  local headings = { 2 }
  local selected_line

  for _, group in ipairs(issue_filter_options) do
    lines[#lines + 1] = "  " .. group.heading
    headings[#headings + 1] = #lines

    for _, choice in ipairs(group.choices) do
      local line = #lines + 1
      local active = filters[group.dimension] == choice.value

      lines[line] = ("  %s  %s"):format(
        active and "[x]" or "[ ]",
        choice.label
      )

      M.state.line_targets[line] = {
        issue_filter = true,
        project = project,
        dimension = group.dimension,
        value = choice.value,
      }

      if group.dimension == selected_dimension and active then
        selected_line = line
      end
    end

    lines[#lines + 1] = ""
  end

  local commands_line = nil

  if not is_sidebar_visible() then
    footer(lines, "<Space> select   q close")
    commands_line = #lines
  end

  set_lines(lines)
  vim.wo[M.state.win].cursorline = true

  for _, line in ipairs(headings) do
    highlight(line, 2, -1, line == 2 and "Title" or "Special")
  end

  highlight(3, 2, -1, "Comment")

  for line, target in pairs(M.state.line_targets) do
    local active = filters[target.dimension] == target.value

    highlight(
      line,
      2,
      5,
      active and "DiagnosticOk" or "Comment"
    )

    highlight(line, 7, -1, "Function")
  end

  if commands_line then
    highlight(commands_line, 0, -1, "Comment")
  end

  render_sidebar()
  vim.api.nvim_win_set_cursor(M.state.win, { selected_line or 6, 0 })
end

local function select_project_issue_filter()
  if M.state.view ~= "issue_filters" then
    return
  end

  local target = target_on_cursor()

  if type(target) ~= "table" or not target.issue_filter then
    return
  end

  save_project_issue_filter(
    target.project,
    target.dimension,
    target.value
  )

  render_issue_filters(target.project, target.dimension)
end

local function render_loading(target)
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "activity"
  M.state.activity_commit_page = false
  M.state.activity_issue_page = target.issues == true
  M.state.activity_return = nil
  M.state.activity_expansion_targets = {}
  M.state.activity_loaded = false
  M.state.activity_error = nil
  local project = target.kind == "project" and target.project or nil
  M.state.activity_scope = project and "project" or "user"
  M.state.activity_project = project
  M.state.contributor = project and nil or target

  local lines = project
      and {
        "",
        target.issues and "  ISSUES" or "  PROJECT",
        "  " .. project_title(project),
      }
    or {
      "",
      "  USER",
      "  @" .. target.username,
    }

  set_lines(lines)
  vim.wo[M.state.win].cursorline = true
  highlight(2, 2, -1, "Function")
  highlight(3, 2, -1, "Comment")
  start_activity_page_loading()
end

local function render_error(message)
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "activity"
  M.state.activity_commit_page = false
  M.state.activity_return = nil
  M.state.activity_expansion_targets = {}
  M.state.activity_loaded = false
  M.state.activity_error = message
  local project = M.state.activity_project

  local lines = project
      and {
        "",
        M.state.activity_issue_page and "  ISSUES" or "  PROJECT",
        "  " .. project_title(project),
        "",
        "  Could not load activity",
        "  " .. message,
      }
    or {
      "",
      "  USER",
      "  @" .. (M.state.contributor and M.state.contributor.username or ""),
      "",
      "  Could not load activity",
      "  " .. message,
    }

  if not is_sidebar_visible() then
    local nav = navigation.resolve(M.state.opts)
    footer(lines, ("? shortcuts   %s/← back   q close"):format(nav.left))
  end

  set_lines(lines)
  vim.wo[M.state.win].cursorline = true
  highlight(2, 2, -1, "Title")
  highlight(3, 2, -1, "Comment")
  highlight(5, 2, -1, "DiagnosticError")
  highlight(6, 2, -1, "Comment")
end

local function set_activity_inspect_queue_scope()
  local scope

  if M.state.activity_project then
    local project = M.state.activity_project

    scope = table.concat({
      "project",
      project.provider == "codeberg" and "codeberg" or "github",
      project.repository:lower(),
      M.state.activity_issue_page and "issues" or "activity",
    }, ":")
  elseif M.state.contributor then
    local contributor = M.state.contributor

    scope = table.concat({
      "user",
      contributor.provider == "codeberg" and "codeberg" or "github",
      contributor.username:lower(),
    }, ":")
  end

  if scope
    and M.state.activity_inspect_queue_scope ~= scope
    and not M.state.activity_inspect_queue_running
  then
    M.state.activity_inspect_queue = {}
    M.state.activity_inspect_queue_active = nil
    M.state.activity_inspect_queue_batch = nil
    M.state.activity_inspect_queue_total = nil
    M.state.activity_inspect_queue_index = nil
    M.state.activity_inspect_queue_completed = nil
    M.state.activity_inspect_queue_continuing = false
    M.state.activity_inspect_queue_deferred_group = nil
    M.state.activity_inspect_queue_number_options = nil
    M.state.activity_inspect_queue_lookup = {}
    M.state.activity_inspect_queue_show_highlights = true
    M.state.activity_inspect_queue_scope = scope
  end
end

local function render_activity(events, cached, notice, opts)
  stop_activity_page_loading()
  opts = opts or {}

  notice = type(notice) == "string" and notice ~= ""
      and notice
    or nil

  M.state.view = "activity"
  M.state.activity_commit_page = opts.commit_page == true

  if opts.issue_page ~= nil then
    M.state.activity_issue_page = opts.issue_page == true
  end

  set_activity_inspect_queue_scope()

  if not M.state.activity_commit_page then
    M.state.activity_return = nil
  end

  local contributor = M.state.contributor
  local project = M.state.activity_project
  M.state.events = events
  M.state.activity_cached = cached
  M.state.activity_notice = notice
  M.state.activity_loaded = true
  M.state.activity_error = nil
  M.state.line_targets = {}
  M.state.inspect_targets = {}
  M.state.activity_title_lines = {}
  M.state.activity_queue_line_keys = {}
  M.state.activity_expansion_targets = {}
  M.state.activity_events = {}
  M.state.activity_scroll_limit_line = nil
  local width = vim.api.nvim_win_get_width(M.state.win)
  local activity_page_number = M.state.activity_page or 1

  local activity_page_count = math.max(
    activity_page_number,
    M.state.activity_loaded_pages or 1
  )

  local context_suffix = not M.state.activity_commit_page
      and activity_page_count > 1
      and (" (%d/%d)"):format(
        activity_page_number,
        activity_page_count
      )
    or ""

  local lines = project
      and {
        "",
        M.state.activity_issue_page and "  ISSUES" or "  PROJECT",
        ("  %s · %s%s"):format(
          project_title(project),
          provider_name(project),
          context_suffix
        ),
      }
    or {
      "",
      "  USER",
      ("  %s · %s%s"):format(
        "@" .. contributor.username,
        provider_name(contributor),
        context_suffix
      ),
    }

  if notice then
    lines[#lines + 1] = "  " .. notice
  end

  lines[#lines + 1] = ""
  local first_event_line
  local scroll_limit_line
  local activity_line_kinds = {}

  for event_index, event in ipairs(events) do
    local item = actions.describe(event, {
      omit_single_commit_count = true,
    })

    if project
      and M.state.activity_issue_page
      and event.type == "IssuesEvent"
    then
      local issue = event.payload and event.payload.issue or {}
      local actor = event.actor or issue.user or {}
      local author = actor.login or actor.username or actor.name
      local state = issue.state == "closed" and "closed" or "open"

      item.text = ("%s%s issue #%s"):format(
        author and ("@" .. author .. " · ") or "",
        state,
        tostring(issue.number or "?")
      )

      item.detail = tostring(issue.title or "Untitled issue")
      item.summary = nil
    elseif project and event.type == "PushEvent" then
      local author = project_push_author(event)

      if author then
        item.text = author .. " " .. item.text
      end
    elseif event.type == "PullRequestEvent" then
      item.text = project_pull_request_title(event, item.text)
    end

    local inspect_context = inspect.activity_context(event)

    local expands_commits = not M.state.activity_commit_page
      and (
        event.type == "PullRequestEvent"
        or (
          event.type == "PushEvent"
          and #(event.payload and event.payload.commits or {}) > 1
        )
      )

    local event_line = #lines + 1
    local queue_key = tostring(event.id or item.url or event_index)
    M.state.activity_title_lines[event_line] = event_line
    M.state.activity_queue_line_keys[event_line] = queue_key .. ":title"

    if expands_commits then
      M.state.activity_expansion_targets[event_line] = event
    end

    first_event_line = first_event_line or event_line
    activity_line_kinds[event_line] = "main"
    local item_width = width - 2

    if item.detail or item.summary then
      lines[event_line] = activity_item_line(
        without_preview(item),
        activity_time(event.created_at),
        item_width
      )

      local detail_lines, detail_indices = preview_lines(item, item_width)

      if detail_lines then
        for detail_line_index, detail_line in ipairs(detail_lines) do
          lines[#lines + 1] = detail_line
          local detail_target = item.url

          if expands_commits then
            local commit_index = detail_indices[detail_line_index]

            local commit = commit_index
                and event.payload
                and event.payload.commits
                and event.payload.commits[commit_index]
              or nil

            detail_target = commit
                and type(commit.sha) == "string"
                and commit.sha ~= ""
                and commit_activity_url(event, commit.sha)
              or (item.group_url or item.url)
          end

          M.state.line_targets[#lines] = detail_target

          if expands_commits then
            M.state.activity_expansion_targets[#lines] = event
          end

          M.state.inspect_targets[#lines] = inspect_context
          M.state.activity_events[#lines] = event
          M.state.activity_title_lines[#lines] = event_line

          M.state.activity_queue_line_keys[#lines] = queue_key
            .. ":detail:"
            .. detail_line_index

          activity_line_kinds[#lines] = "preview"
        end
      end

      scroll_limit_line = #lines
    else
      lines[event_line] = activity_item_line(
        item,
        activity_time(event.created_at),
        item_width
      )

      scroll_limit_line = event_line
    end

    M.state.line_targets[event_line] = item.url
    M.state.inspect_targets[event_line] = inspect_context
    M.state.activity_events[event_line] = event

    if event_index < #events then
      lines[#lines + 1] = pad_cell("", item_width)
    end
  end

  if #events == 0 then
    lines[#lines + 1] = M.state.activity_page > 1
        and "  No past public activity was returned."
      or "  No recent public activity was returned."

    scroll_limit_line = #lines
  end

  M.state.activity_scroll_limit_line = scroll_limit_line
  set_lines(lines)
  render_activity_footer()
  vim.wo[M.state.win].scrolloff = 3
  highlight(2, 2, -1, "Function")
  highlight(3, 2, -1, "Comment")

  if notice then
    highlight(4, 2, -1, "DiagnosticWarn")
  end

  for line, kind in pairs(activity_line_kinds) do
    local text = lines[line]

    if text then
      if kind == "preview" then
        highlight(line, 0, -1, "OculusActivityPreview")
      elseif kind == "main" then
        highlight(line, 0, 5, "OculusActivityIcon")
      end
    end
  end

  for line in pairs(M.state.activity_title_lines) do
    local queue_key = M.state.activity_queue_line_keys[line]

    if M.state.activity_inspect_queue_show_highlights
      and queue_key
      and M.state.activity_inspect_queue_lookup[queue_key]
    then
      vim.api.nvim_buf_add_highlight(
        M.state.buf,
        activity_inspect_queue_ns,
        "OculusActivityQueued",
        line - 1,
        0,
        M.state.activity_title_lines[line] == line
            and activity_title_highlight_end(lines[line])
          or -1
      )
    end
  end

  if first_event_line then
    M.state.activity_cursor_min_line = first_event_line
    vim.api.nvim_win_set_cursor(M.state.win, { first_event_line, 0 })
  else
    M.state.activity_cursor_min_line = 2
  end

  render_sidebar()
  update_activity_cursorline()
end

commit_activity_url = function(event, sha)
  local url = type(event.url) == "string" and event.url or ""
  local prefix = url:match("^(.-/commit)/[^/?#]+")

  if prefix then
    return prefix .. "/" .. sha
  end

  local repo = event.repo and event.repo.name

  if repo then
    local activity_source = M.state.activity_project
      or M.state.contributor

    local host = provider_name(activity_source) == "Codeberg"
        and "https://codeberg.org/"
      or "https://github.com/"

    return host .. repo .. "/commit/" .. sha
  end

  return url
end

local function commit_activity_events(event)
  local result = {}
  local payload = event.payload or {}

  for index, commit in ipairs(payload.commits or {}) do
    local sha = commit.sha

    if type(sha) == "string" and sha ~= "" then
      local commit_event = vim.deepcopy(event)

      commit_event.id = ("%s:commit:%d:%s"):format(
        tostring(event.id or "push"),
        index,
        sha
      )

      commit_event.type = "PushEvent"

      commit_event.payload = {
        ref = payload.ref,
        before = payload.before,
        head = sha,
        size = 1,
        commits = { vim.deepcopy(commit) },
      }

      commit_event.url = commit_activity_url(event, sha)
      commit_event.group_url = nil
      commit_event.oculus_text = nil
      commit_event.oculus_detail = nil
      result[#result + 1] = commit_event
    end
  end

  return result
end

local function pull_request_commit_events(event, commits)
  local result = {}

  for index, commit in ipairs(commits or {}) do
    local sha = commit.sha

    if type(sha) == "string" and sha ~= "" then
      local details = type(commit.commit) == "table" and commit.commit or {}
      local author = type(details.author) == "table" and details.author or {}
      local account = type(commit.author) == "table" and commit.author or nil
      local commit_event = vim.deepcopy(event)

      commit_event.id = ("%s:commit:%d:%s"):format(
        tostring(event.id or "pull-request"),
        index,
        sha
      )

      commit_event.type = "PushEvent"
      commit_event.actor = account or { name = author.name }
      commit_event.created_at = author.date or event.created_at

      commit_event.payload = {
        head = sha,
        size = 1,
        commits = {
          {
            sha = sha,
            message = details.message or commit.message,
            author = account or { name = author.name },
          },
        },
      }

      commit_event.url = commit.html_url
        or commit_activity_url(event, sha)

      commit_event.group_url = nil
      commit_event.oculus_text = nil
      commit_event.oculus_detail = nil
      result[#result + 1] = commit_event
    end
  end

  return result
end

local function show_commit_activity(commits)
  if #commits == 0 then
    return false
  end

  M.state.activity_return = {
    events = M.state.events,
    cached = M.state.activity_cached,
    notice = M.state.activity_notice,
    cursor = is_valid_win(M.state.win)
        and vim.api.nvim_win_get_cursor(M.state.win)
      or nil,
    page = M.state.activity_page,
    source_events = M.state.activity_source_events,
  }

  render_activity(commits, false, nil, { commit_page = true })
  return true
end

local function open_commit_activity(event)
  return show_commit_activity(commit_activity_events(event))
end

local function open_pull_request_activity(event)
  local payload = event.payload or {}
  local pull_request = payload.pull_request or {}
  local repo = event.repo and event.repo.name
  local number = pull_request.number or payload.number
  local source = M.state.activity_project or M.state.contributor
  local provider = activity_provider(source)

  if not repo
    or not number
    or type(provider.pull_request_commits) ~= "function"
  then
    return false
  end

  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id
  start_activity_page_loading()

  provider.pull_request_commits(repo, number, M.state.opts, function(
    commits,
    err
  )
    if request_id ~= M.state.request_id
      or M.state.view ~= "activity"
      or M.state.activity_commit_page
      or not is_valid_win(M.state.win)
    then
      return
    end

    if not commits then
      stop_activity_page_loading()

      vim.notify(
        "Oculus: " .. tostring(err or "could not load pull request commits"),
        vim.log.levels.ERROR
      )

      return
    end

    if not show_commit_activity(
      pull_request_commit_events(event, commits)
    ) then
      stop_activity_page_loading()

      vim.notify(
        "Oculus: this pull request has no commits",
        vim.log.levels.INFO
      )
    end
  end)

  return true
end

local function render_shortcuts()
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "shortcuts"
  M.state.line_targets = {}

  local lines = {
    "",
    "  KEYBOARD SHORTCUTS",
    "  Commands available throughout Oculus",
  }

  local headings = { 2 }

  local function section(title, entries)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "  " .. title
    headings[#headings + 1] = #lines

    for _, entry in ipairs(entries) do
      lines[#lines + 1] = ("  %-22s %s"):format(entry[1], entry[2])
    end
  end

  local nav = navigation.resolve(M.state.opts)

  section("NAVIGATION", {
    { nav.up .. " / <Up>", "Select the previous item" },
    { nav.down .. " / <Down>", "Select the next item" },
    { nav.right .. " / <Right> / <CR>", "Select the current item" },
    { nav.left .. " / <Left>", "Return to the previous page" },
  })

  section("STARTUP LISTS", {
    { "v", "Switch between project and user lists" },
    { "a", "Add a GitHub or Codeberg project or account" },
    { nav.inspect_id, "Inspect an issue, PR, or commit by ID" },
    { nav.investigate, "Investigate the selected project repository" },
    { nav.investigate_id, "Investigate an issue, PR, commit, or project by ID" },
    { "r", "Remove the selected project or account" },
    { "m", "Move the selected project or account" },
    { "f", "Edit filters for the selected user or project" },
    { "F", "Edit global activity filters" },
    { "d", "Reset activity filters to defaults" },
    { "o", "Open the selected contributor profile" },
  })

  section("ACTIVITY", {
    { nav.inspect, "Inspect the selected change or issue" },
    { nav.inspect_id, "Inspect an issue, PR, or commit by ID" },
    { nav.investigate, "Investigate the selected change, issue, or repository" },
    { nav.investigate_id, "Investigate an issue, PR, commit, or project by ID" },
    { "Tab", "Queue activity for sequential inspection" },
    { "b", "Open the selected activity in a browser" },
    { "u", "Open a project's issue activity" },
    { "r", "Refresh the current activity page" },
    { "p", "Load the next eight older activity items" },
    { nav.right .. " / <Right>", "Open the next older activity page" },
    { "f", "Move forward, or filter a project issue page" },
  })

  section("FILTER CHECKLIST", {
    { "<Space> / l / <CR>", "Toggle the selected activity type" },
    { "a", "Enable every activity type" },
    { "n", "Disable every activity type" },
  })

  section("GENERAL", {
    { "s", "Toggle command sidebar" },
    { "?", "Open or close this shortcut page" },
    { "q / <Esc> / <C-c>", "Close Oculus" },
  })

  local commands_line = nil

  if not is_sidebar_visible() then
    lines[#lines + 1] = ""
    lines[#lines + 1] = ("  ? or %s/← back   q close"):format(nav.left)
    commands_line = #lines
  end

  set_lines(lines)
  vim.wo[M.state.win].cursorline = false

  for _, line in ipairs(headings) do
    highlight(line, 2, -1, line == 2 and "Title" or "Special")
  end

  highlight(3, 2, -1, "Comment")

  if commands_line then
    highlight(commands_line, 2, -1, "Comment")
  end

  render_sidebar()
  vim.api.nvim_win_set_cursor(M.state.win, { 2, 0 })
end

local function restore_cursor()
  local cursor = M.state.restore_cursor
  local view = M.state.restore_view

  if (not cursor and not view) or not is_valid_win(M.state.win) then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(M.state.buf)

  local line = math.min(math.max(
    cursor and cursor[1] or view and view.lnum or 1,
    1
  ), line_count)

  local column = math.max(
    cursor and cursor[2] or view and view.col or 0,
    0
  )

  if view then
    view.lnum = line
    view.col = column

    view.topline = math.min(
      math.max(view.topline or 1, 1),
      line_count
    )

    vim.api.nvim_win_call(M.state.win, function()
      vim.fn.winrestview(view)
    end)
  else
    vim.api.nvim_win_set_cursor(M.state.win, { line, column })
  end

  M.state.restore_cursor = nil
  M.state.restore_view = nil
end

local function contributor_by_username(username)
  if not username then
    return nil
  end

  for _, contributor in ipairs(M.state.contributors) do
    if contributor.username == username then
      return contributor
    end
  end

  return nil
end

local function activity_repository(event)
  local repository = event.repo
      and (event.repo.name or event.repo.full_name)
    or event.repository
      and (event.repository.full_name or event.repository.name)
    or ""

  return tostring(repository):lower()
end

local function activity_target_id(payload, target)
  local value = payload[target]

  if type(value) == "table" then
    return value.id or value.number
  end

  return nil
end

local function activity_dedupe_key(event)
  local payload = event.payload or {}
  local event_type = event.type or event.event_type or "ActivityEvent"
  local repository = activity_repository(event)

  if event_type == "PushEvent" then
    local before = payload.before
    local head = payload.head

    if type(head) == "string" and head ~= "" then
      return table.concat({ "push", repository, before or "", head }, ":")
    end

    local shas = {}

    for _, commit in ipairs(payload.commits or {}) do
      if type(commit.sha) == "string" and commit.sha ~= "" then
        shas[#shas + 1] = commit.sha
      end
    end

    if #shas > 0 then
      table.sort(shas)
      return table.concat({ "push", repository, table.concat(shas, ",") }, ":")
    end
  elseif event_type == "PullRequestEvent" then
    local pull_request = payload.pull_request or {}
    local number = pull_request.number or payload.number

    if number then
      local merged = payload.action == "merged"
        or (payload.action == "closed" and (
          pull_request.merged == true
          or pull_request.merged_at ~= nil
          or pull_request.merged_by ~= nil
        ))

      local action = merged and "merged" or payload.action or "updated"

      return table.concat({
        "pr",
        repository,
        number,
        action,
        merged and "" or event.created_at or "",
      }, ":")
    end
  elseif event_type == "IssuesEvent" then
    local number = activity_target_id(payload, "issue") or payload.number

    if number then
      return table.concat({
        "issue",
        repository,
        number,
        payload.action or "updated",
        event.created_at or "",
      }, ":")
    end
  end

  for _, target in ipairs({ "comment", "review", "release", "forkee" }) do
    local id = activity_target_id(payload, target)

    if id then
      return table.concat({ event_type, repository, target, id }, ":")
    end
  end

  if event_type == "CreateEvent" or event_type == "DeleteEvent" then
    local ref = payload.ref

    if ref then
      return table.concat({
        event_type,
        repository,
        payload.ref_type or "ref",
        ref,
        event.created_at or "",
      }, ":")
    end
  end

  if event.id ~= nil then
    return table.concat({ event_type, repository, event.id }, ":")
  end

  local url = event.url or event.group_url

  if type(url) == "string" and url ~= "" then
    return table.concat({
      event_type,
      repository,
      url,
      event.created_at or "",
    }, ":")
  end

  return table.concat({ event_type, repository, tostring(event) }, ":")
end

local function merge_missing_activity_values(current, duplicate)
  if type(current) ~= "table" or type(duplicate) ~= "table" then
    return
  end

  for key, value in pairs(duplicate) do
    local existing = current[key]

    if existing == nil or existing == "" then
      current[key] = vim.deepcopy(value)
    elseif type(existing) == "table" and type(value) == "table" then
      if vim.islist(existing) and #existing == 0 and #value > 0 then
        current[key] = vim.deepcopy(value)
      elseif not vim.islist(existing) and not vim.islist(value) then
        merge_missing_activity_values(existing, value)
      end
    end
  end
end

local function deduplicate_activity(events)
  local result = {}
  local seen = {}

  for _, event in ipairs(events or {}) do
    local key = activity_dedupe_key(event)
    local existing = seen[key]

    if existing then
      merge_missing_activity_values(existing, event)
    else
      result[#result + 1] = event
      seen[key] = event
    end
  end

  return result
end

M._activity_dedupe_key = activity_dedupe_key
M._deduplicate_activity = deduplicate_activity

local function activity_page(events, page, page_size)
  local result = {}
  local first = (page - 1) * page_size + 1
  local last = math.min(#events, first + page_size - 1)

  for index = first, last do
    result[#result + 1] = events[index]
  end

  return result
end

M._activity_page = activity_page

local function project_event_allowed(event, project)
  local enabled = {}

  for _, category in ipairs(project_activity_types_for(project) or {}) do
    enabled[category] = true
  end

  local payload = event.payload or {}
  local event_type = event.type or event.event_type

  if event_type == "PushEvent" then
    return enabled.push == true
  end

  if event_type == "PullRequestEvent" then
    local pull_request = payload.pull_request or {}

    local merged = pull_request.merged == true
      or pull_request.merged_at ~= nil
      or pull_request.merged_by ~= nil

    return enabled.merged_pull_request == true
      and (payload.action == "merged"
        or (payload.action == "closed" and merged))
  end

  if event_type == "IssuesEvent" then
    return enabled.assigned_issue == true
      and payload.action == "assigned"
  end

  return false
end

local function filter_project_events(events, project)
  local result = {}

  for _, event in ipairs(events or {}) do
    local event_repository = event.repo
        and (event.repo.name or event.repo.full_name)
      or event.repository
        and (event.repository.full_name or event.repository.name)
      or nil

    local repository_matches = type(event_repository) ~= "string"
      or event_repository == ""
      or event_repository:lower() == project.repository:lower()

    if repository_matches
      and project_event_allowed(event, project)
    then
      result[#result + 1] = event
    end
  end

  return deduplicate_activity(result)
end

M._filter_project_events = filter_project_events

local function add_project_feed_event(feed, event)
  local payload = event.payload or {}

  if event.type == "PushEvent" then
    local shas = {}

    for _, commit in ipairs(payload.commits or {}) do
      if type(commit.sha) == "string" and commit.sha ~= "" then
        shas[#shas + 1] = commit.sha
      end
    end

    if #shas == 0 and type(payload.head) == "string" then
      shas[1] = payload.head
    end

    if #shas > 0 then
      for _, sha in ipairs(shas) do
        if feed.seen_commits[sha] then
          return false
        end
      end

      for _, sha in ipairs(shas) do
        feed.seen_commits[sha] = true
      end
    end
  elseif event.type == "PullRequestEvent" then
    local pull_request = payload.pull_request or {}
    local number = pull_request.number or payload.number

    local merged = payload.action == "merged"
      or (payload.action == "closed" and (
        pull_request.merged == true
        or pull_request.merged_at ~= nil
        or pull_request.merged_by ~= nil
      ))

    if number and merged then
      local key = tostring(number)

      if feed.seen_pull_requests[key] then
        return false
      end

      feed.seen_pull_requests[key] = true
    end
  end

  local event_key = event.id and tostring(event.id) or nil

  if event_key and feed.seen[event_key] then
    return false
  end

  feed.events[#feed.events + 1] = event

  if event_key then
    feed.seen[event_key] = true
  end

  return true
end

load_project_activity = function(project, force, page)
  local previous_page = M.state.activity_page or 1

  local preserve_activity_page = page ~= nil
    and M.state.view == "activity"
    and M.state.activity_loaded
    and is_valid_buf(M.state.buf)

  M.state.view = "activity"
  M.state.activity_scope = "project"
  M.state.activity_project = project
  M.state.activity_issue_page = false
  M.state.contributor = nil

  if page == nil then
    M.state.activity_loaded_pages = 1
  end

  local requested_page = math.max(1, page or 1)
  M.state.activity_page = requested_page

  M.state.activity_page_size = math.max(
    1,
    math.floor(tonumber(M.state.opts.results_limit) or 8)
  )

  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id

  if preserve_activity_page then
    M.state.activity_error = nil
    start_activity_page_loading()
  else
    render_loading({ kind = "project", project = project })
  end

  local provider = project.provider == "codeberg" and codeberg or github

  local request_opts = vim.tbl_extend(
    "force",
    M.state.opts,
    { force = force or false }
  )

  request_opts.per_page = project.provider == "codeberg"
      and math.min(50, math.max(16, M.state.activity_page_size * 2))
    or 100

  local activity_types = vim.deepcopy(project_activity_types_for(project) or {})
  table.sort(activity_types)

  local feed_key = table.concat({
    project.provider == "codeberg" and "codeberg" or "github",
    project.repository:lower(),
    table.concat(activity_types, ","),
  }, ":")

  local feed = M.state.project_activity_feed

  if force or not feed or feed.key ~= feed_key then
    feed = {
      key = feed_key,
      events = {},
      seen = {},
      seen_commits = {},
      seen_pull_requests = {},
      next_page = 1,
      using_updates = project.provider == "codeberg"
        and type(provider.repository_updates) == "function",
      complete = #activity_types == 0,
      cached = true,
      notice = nil,
    }

    M.state.project_activity_feed = feed
  end

  local required_events = requested_page * M.state.activity_page_size
  local max_source_pages = 10
  request_opts.activity_types = activity_types

  local function use_repository_updates()
    if feed.using_updates
      or type(provider.repository_updates) ~= "function"
    then
      return false
    end

    local useful = false

    for _, category in ipairs(activity_types) do
      if category == "push" or category == "merged_pull_request" then
        useful = true
        break
      end
    end

    if not useful then
      return false
    end

    feed.using_updates = true
    feed.next_page = 1
    feed.complete = false
    return true
  end

  local function render_project_results()
    local filtered = filter_project_events(feed.events, project)

    local first_event =
      (requested_page - 1) * M.state.activity_page_size + 1

    if requested_page > 1 and #filtered < first_event then
      M.state.activity_page = math.max(1, previous_page)
    else
      M.state.activity_page = requested_page
    end

    M.state.activity_source_events = filtered

    M.state.activity_loaded_pages = math.max(
      M.state.activity_loaded_pages or 1,
      M.state.activity_page
    )

    local page_end = M.state.activity_page * M.state.activity_page_size
    M.state.activity_has_past = #filtered > page_end or not feed.complete

    local results = activity_page(
      filtered,
      M.state.activity_page,
      M.state.activity_page_size
    )

    render_activity(results, feed.cached, feed.notice)

    provider.enrich_pull_requests(results, request_opts, function(with_prs)
      if request_id ~= M.state.request_id
        or M.state.view ~= "activity"
        or M.state.activity_project ~= project
      then
        return
      end

      render_activity(with_prs, feed.cached, feed.notice)

      provider.enrich_pushes(with_prs, request_opts, function(enriched)
        if request_id ~= M.state.request_id
          or M.state.view ~= "activity"
          or M.state.activity_project ~= project
        then
          return
        end

        render_activity(enriched, feed.cached, feed.notice)
      end)
    end)
  end

  local function ensure_project_page()
    local filtered = filter_project_events(feed.events, project)

    if #filtered >= required_events or feed.complete then
      render_project_results()
      return
    end

    if feed.next_page > max_source_pages then
      if use_repository_updates() then
        ensure_project_page()
      else
        feed.complete = true
        render_project_results()
      end

      return
    end

    local source_page = feed.next_page
    request_opts.page = source_page

    local request = feed.using_updates
        and provider.repository_updates
      or provider.repository_events

    request(project.repository, request_opts, function(
      events,
      err,
      cached,
      notice
    )
      if request_id ~= M.state.request_id
        or M.state.view ~= "activity"
        or M.state.activity_project ~= project
        or not is_valid_win(M.state.win)
      then
        return
      end

      if err then
        render_error(err)
        return
      end

      local source = events or {}
      local allowed_before = #filter_project_events(feed.events, project)
      local added = 0

      for _, event in ipairs(source) do
        if add_project_feed_event(feed, event) then
          added = added + 1
        end
      end

      local allowed_added = #filter_project_events(feed.events, project)
        - allowed_before

      table.sort(feed.events, function(left, right)
        return tostring(left.created_at or "")
          > tostring(right.created_at or "")
      end)

      feed.next_page = source_page + 1
      feed.cached = feed.cached and cached == true
      feed.notice = feed.notice or notice

      if #source == 0 or added == 0 or allowed_added == 0 then
        if not use_repository_updates() then
          feed.complete = true
        end
      end

      ensure_project_page()
    end)
  end

  if type(provider.repository_events) ~= "function" then
    render_error("this provider does not support project activity")
    return
  end

  ensure_project_page()
end

local function project_issue_allowed(event, project)
  local filters = project_issue_filters_for(project)
  local issue = event.payload and event.payload.issue or {}

  local state = issue.state
    or (event.payload and event.payload.action == "closed" and "closed")
    or "open"

  if filters.state ~= "all" and filters.state ~= state then
    return false
  end

  local assigned = issue.assignee ~= nil
    or (type(issue.assignees) == "table" and #issue.assignees > 0)

  if filters.assignment == "assigned" and not assigned then
    return false
  end

  if filters.assignment == "unassigned" and assigned then
    return false
  end

  return true
end

local function filter_project_issues(events, project)
  local filtered = {}

  for _, event in ipairs(events or {}) do
    if event.type == "IssuesEvent"
      and project_issue_allowed(event, project)
    then
      filtered[#filtered + 1] = event
    end
  end

  return deduplicate_activity(filtered)
end

M._filter_project_issues = filter_project_issues

local function add_project_issue(feed, event)
  local issue = event.payload and event.payload.issue or {}

  local key = issue.number and tostring(issue.number)
    or event.id and tostring(event.id)

  if key and feed.seen[key] then
    return false
  end

  feed.events[#feed.events + 1] = event

  if key then
    feed.seen[key] = true
  end

  return true
end

load_project_issues = function(project, force, page)
  local previous_page = M.state.activity_page or 1

  local preserve_activity_page = page ~= nil
    and M.state.view == "activity"
    and M.state.activity_issue_page
    and M.state.activity_loaded
    and is_valid_buf(M.state.buf)

  M.state.view = "activity"
  M.state.activity_scope = "project"
  M.state.activity_project = project
  M.state.activity_issue_page = true
  M.state.activity_commit_page = false
  M.state.contributor = nil

  if page == nil then
    M.state.activity_loaded_pages = 1
  end

  local requested_page = math.max(1, page or 1)
  M.state.activity_page = requested_page

  M.state.activity_page_size = math.max(
    1,
    math.floor(tonumber(M.state.opts.results_limit) or 8)
  )

  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id

  if preserve_activity_page then
    M.state.activity_error = nil
    start_activity_page_loading()
  else
    render_loading({
      kind = "project",
      project = project,
      issues = true,
    })
  end

  local provider = project.provider == "codeberg" and codeberg or github

  if type(provider.repository_issues) ~= "function" then
    render_error("this provider does not support project issues")
    return
  end

  local filters = project_issue_filters_for(project)

  local request_opts = vim.tbl_extend(
    "force",
    M.state.opts,
    { force = force or false }
  )

  request_opts.per_page = project.provider == "codeberg" and 50 or 100
  request_opts.issue_state = filters.state

  local feed_key = table.concat({
    project_issue_filter_key(project),
    filters.state,
    filters.assignment,
  }, ":")

  local feed = M.state.project_issue_feed

  if force or not feed or feed.key ~= feed_key then
    feed = {
      key = feed_key,
      events = {},
      seen = {},
      next_page = 1,
      complete = false,
      cached = true,
    }

    M.state.project_issue_feed = feed
  end

  local required_events = requested_page * M.state.activity_page_size
  local max_source_pages = 10

  local function render_issue_results()
    local filtered = filter_project_issues(feed.events, project)

    local first_event =
      (requested_page - 1) * M.state.activity_page_size + 1

    if requested_page > 1 and #filtered < first_event then
      M.state.activity_page = math.max(1, previous_page)
    else
      M.state.activity_page = requested_page
    end

    M.state.activity_source_events = filtered

    M.state.activity_loaded_pages = math.max(
      M.state.activity_loaded_pages or 1,
      M.state.activity_page
    )

    local page_end = M.state.activity_page * M.state.activity_page_size
    M.state.activity_has_past = #filtered > page_end or not feed.complete

    render_activity(
      activity_page(
        filtered,
        M.state.activity_page,
        M.state.activity_page_size
      ),
      feed.cached,
      nil,
      { issue_page = true }
    )
  end

  local function ensure_issue_page()
    local filtered = filter_project_issues(feed.events, project)

    if #filtered >= required_events or feed.complete then
      render_issue_results()
      return
    end

    if feed.next_page > max_source_pages then
      feed.complete = true
      render_issue_results()
      return
    end

    local source_page = feed.next_page
    request_opts.page = source_page

    provider.repository_issues(project.repository, request_opts, function(
      events,
      err,
      cached,
      complete
    )
      if request_id ~= M.state.request_id
        or M.state.view ~= "activity"
        or not M.state.activity_issue_page
        or M.state.activity_project ~= project
        or not is_valid_win(M.state.win)
      then
        return
      end

      if err then
        render_error(err)
        return
      end

      local source = events or {}

      for _, event in ipairs(source) do
        add_project_issue(feed, event)
      end

      table.sort(feed.events, function(left, right)
        return tostring(left.created_at or "")
          > tostring(right.created_at or "")
      end)

      feed.next_page = source_page + 1
      feed.cached = feed.cached and cached == true

      if complete == true or (complete == nil and #source == 0) then
        feed.complete = true
      end

      ensure_issue_page()
    end)
  end

  ensure_issue_page()
end

local function load_activity(contributor, force, page)
  local preserve_activity_page = page ~= nil
    and M.state.view == "activity"
    and M.state.activity_loaded
    and is_valid_buf(M.state.buf)

  M.state.view = "activity"
  M.state.activity_scope = "user"
  M.state.activity_project = nil
  M.state.activity_has_past = nil
  M.state.contributor = contributor

  if page == nil then
    M.state.activity_loaded_pages = 1
  end

  M.state.activity_page = math.max(1, page or 1)

  M.state.activity_page_size = math.max(
    1,
    math.floor(tonumber(M.state.opts.results_limit) or 8)
  )

  M.state.request_id = M.state.request_id + 1
  local request_id = M.state.request_id

  if preserve_activity_page then
    M.state.activity_error = nil
    start_activity_page_loading()
  else
    render_loading(contributor)
  end

  local provider = activity_provider(contributor)

  local request_opts = vim.tbl_extend(
    "force",
    M.state.opts,
    { force = force or false }
  )

  local base_per_page =
    math.max(1, math.floor(tonumber(M.state.opts.per_page) or 30))

  request_opts.per_page = base_per_page
    + (M.state.activity_page - 1) * M.state.activity_page_size

  local callback = function(events, err, cached, notice)
    if request_id ~= M.state.request_id
      or M.state.view ~= "activity"
      or not is_valid_win(M.state.win)
    then
      return
    end

    if err then
      render_error(err)
    else
      local filtered = deduplicate_activity(
        actions.filter(events, activity_types_for(contributor))
      )

      M.state.activity_source_events = filtered

      M.state.activity_loaded_pages = math.max(
        M.state.activity_loaded_pages or 1,
        M.state.activity_page
      )

      local results = activity_page(
        filtered,
        M.state.activity_page,
        M.state.activity_page_size
      )

      render_activity(results, cached, notice)

      provider.enrich_pull_requests(results, request_opts, function(with_prs)
        if request_id ~= M.state.request_id or M.state.view ~= "activity" then
          return
        end

        render_activity(with_prs, cached, notice)

        provider.enrich_pushes(with_prs, request_opts, function(enriched)
          if request_id ~= M.state.request_id or M.state.view ~= "activity" then
            return
          end

          render_activity(enriched, cached, notice)
        end)
      end)
    end
  end

  provider.events(contributor.username, request_opts, callback)
end

local function next_activity_page()
  if
    M.state.view ~= "activity"
    or M.state.activity_commit_page
    or (not M.state.contributor and not M.state.activity_project)
  then
    return
  end

  local page = (M.state.activity_page or 1) + 1

  if M.state.activity_project then
    if M.state.activity_has_past == false then
      return
    end

    if M.state.activity_issue_page then
      load_project_issues(M.state.activity_project, false, page)
    else
      load_project_activity(M.state.activity_project, false, page)
    end
  else
    load_activity(M.state.contributor, false, page)
  end
end

local function previous_activity_page()
  if
    M.state.view ~= "activity"
    or M.state.activity_commit_page
    or (not M.state.contributor and not M.state.activity_project)
    or (M.state.activity_page or 1) == 1
  then
    return
  end

  local page = (M.state.activity_page or 1) - 1

  if M.state.activity_project then
    if M.state.activity_issue_page then
      load_project_issues(M.state.activity_project, false, page)
    else
      load_project_activity(M.state.activity_project, false, page)
    end
  else
    load_activity(M.state.contributor, false, page)
  end
end

local function refresh_activity()
  if M.state.view ~= "activity" or M.state.activity_commit_page then
    return
  end

  local page = M.state.activity_page or 1

  if M.state.activity_project then
    if M.state.activity_issue_page then
      load_project_issues(M.state.activity_project, true, page)
    else
      load_project_activity(M.state.activity_project, true, page)
    end
  elseif M.state.contributor then
    load_activity(M.state.contributor, true, page)
  end
end

local function add_contributor(contributor, target_contributor)
  local raw_user = vim.trim(tostring(contributor.username or ""))
  local detected_provider = nil

  if raw_user:match("codeberg%.org") then
    detected_provider = "codeberg"
  elseif raw_user:match("github%.com") then
    detected_provider = "github"
  end

  local cleaned = raw_user
    :gsub("^https?://[^/]+/", "")
    :gsub("^git@[^:]+:", "")
    :gsub("^ssh://[^/]+/", "")
    :gsub("^github%.com/", "")
    :gsub("^codeberg%.org/", "")
    :gsub("^@", "")
    :gsub("/+$", "")

  local username = cleaned:match("^([%w][%w%._%-]*)") or cleaned

  if
    username == ""
    or not username:match("^[%w][%w%._%-]*$")
  then
    vim.notify(
      "Oculus: enter a valid account handle",
      vim.log.levels.WARN
    )

    return false
  end

  local added = vim.deepcopy(contributor)
  added.username = username
  local prov = detected_provider or added.provider
  added.provider = prov == "codeberg" and "codeberg" or "github"
  added.name = added.name or username
  added.description = nil

  if has_contributor(M.state.contributors, added) then
    vim.notify(
      ("Oculus: @%s is already in your %s list"):format(
        username,
        provider_name(added)
      ),
      vim.log.levels.INFO
    )

    return false
  end

  local insert_index = nil

  if type(target_contributor) == "number" then
    insert_index = target_contributor
  elseif type(target_contributor) == "table" then
    local target_key = contributor_key(target_contributor)

    for index, existing in ipairs(M.state.contributors) do
      if contributor_key(existing) == target_key then
        insert_index = index + 1
        break
      end
    end
  end

  if
    insert_index
    and insert_index >= 1
    and insert_index <= #M.state.contributors + 1
  then
    table.insert(M.state.contributors, insert_index, added)
  else
    M.state.contributors[#M.state.contributors + 1] = added
  end

  M.state.opts.removed_contributors = vim.tbl_filter(function(key)
    return type(key) ~= "string"
      or key:lower() ~= contributor_key(added):lower()
  end, M.state.opts.removed_contributors or {})

  M.state.selected_username = added.username
  persist_contributors()
  return true
end

local function add_project(project, target_project)
  local raw_repo = vim.trim(tostring(project.repository or ""))
  local detected_provider = nil

  if raw_repo:match("codeberg%.org") then
    detected_provider = "codeberg"
  elseif raw_repo:match("github%.com") then
    detected_provider = "github"
  end

  local cleaned = raw_repo
    :gsub("^https?://[^/]+/", "")
    :gsub("^git@[^:]+:", "")
    :gsub("^ssh://[^/]+/", "")
    :gsub("^github%.com/", "")
    :gsub("^codeberg%.org/", "")
    :gsub("^/+", "")
    :gsub("/+$", "")
    :gsub("%.git$", "")

  local owner, repo_name = cleaned:match("^([%w%._%-]+)/([%w%._%-]+)")
  local repository = (owner and repo_name) and (owner .. "/" .. repo_name) or cleaned

  if not repository:match("^[%w%._%-]+/[%w%._%-]+$") then
    vim.notify(
      "Oculus: enter a repository as owner/repo",
      vim.log.levels.WARN
    )

    return false
  end

  local added = vim.deepcopy(project)
  added.repository = repository
  local prov = detected_provider or added.provider
  added.provider = prov == "codeberg" and "codeberg" or "github"
  added.name = added.name or repository:match("([^/]+)$")

  if has_project(M.state.opts.projects, added) then
    vim.notify(
      ("Oculus: %s is already in your %s project list"):format(
        repository,
        provider_name(added)
      ),
      vim.log.levels.INFO
    )

    return false
  end

  M.state.opts.projects = M.state.opts.projects or {}
  local insert_index = nil

  if type(target_project) == "number" then
    insert_index = target_project
  elseif type(target_project) == "table" then
    local target_key = project_key(target_project)

    for index, existing in ipairs(M.state.opts.projects) do
      if project_key(existing) == target_key then
        insert_index = index + 1
        break
      end
    end
  end

  if
    insert_index
    and insert_index >= 1
    and insert_index <= #M.state.opts.projects + 1
  then
    table.insert(M.state.opts.projects, insert_index, added)
  else
    M.state.opts.projects[#M.state.opts.projects + 1] = added
  end

  M.state.opts.removed_projects = vim.tbl_filter(function(key)
    return type(key) ~= "string"
      or key:lower() ~= project_key(added):lower()
  end, M.state.opts.removed_projects or {})

  M.state.selected_project = added
  persist_projects()

  if not added.description or added.description == "" then
    fetch_project_description(added, function(desc)
      if desc and desc ~= "" then
        added.description = desc
        persist_projects()

        if M.state.preview_project == added and is_valid_win(M.state.win) then
          local window_width = vim.api.nvim_win_get_width(M.state.win)
          local left_width = preview_left_width(window_width)
          local preview_width = math.max(15, window_width - left_width - 5)
          render_preview_panel(project_preview_items(added, preview_width))
        end
      end
    end)
  end

  return true
end

local add_dialog_ns = vim.api.nvim_create_namespace("oculus_add_dialog")

local function close_add_dialog()
  M.state.closing_add_dialog = true
  vim.cmd("stopinsert")

  if is_valid_win(M.state.add_input_win) then
    vim.api.nvim_win_close(M.state.add_input_win, true)
  end

  if is_valid_buf(M.state.add_input_buf) then
    vim.api.nvim_buf_delete(M.state.add_input_buf, { force = true })
  end

  M.state.add_input_win = nil
  M.state.add_input_buf = nil

  if is_valid_win(M.state.add_dialog_win) then
    vim.api.nvim_win_close(M.state.add_dialog_win, true)
  end

  if is_valid_buf(M.state.add_dialog_buf) then
    vim.api.nvim_buf_delete(M.state.add_dialog_buf, { force = true })
  end

  M.state.add_dialog_win = nil
  M.state.add_dialog_buf = nil
  M.state.add_dialog_step = nil

  if is_valid_win(M.state.win) then
    vim.api.nvim_set_current_win(M.state.win)
  end

  if is_valid_win(M.state.win) and is_sidebar_visible() then
    render_sidebar()
  end

  vim.schedule(function()
    M.state.closing_add_dialog = false
  end)
end

local function close_inspect_input()
  M.state.closing_inspect_input = true
  M.state.inspect_input_active = nil
  vim.cmd("stopinsert")

  if is_valid_win(M.state.inspect_input_win) then
    vim.api.nvim_win_close(M.state.inspect_input_win, true)
  end

  if is_valid_buf(M.state.inspect_input_buf) then
    vim.api.nvim_buf_delete(M.state.inspect_input_buf, { force = true })
  end

  M.state.inspect_input_win = nil
  M.state.inspect_input_buf = nil

  if is_valid_win(M.state.win) then
    vim.api.nvim_set_current_win(M.state.win)
  end

  if is_valid_win(M.state.win) and is_sidebar_visible() then
    close_activity_footer()
    render_sidebar()
  elseif is_valid_win(M.state.win) and M.state.view == "activity" then
    render_activity_footer()
  elseif is_valid_win(M.state.win) and M.state.view == "contributors" then
    close_activity_footer()
  end

  vim.schedule(function()
    M.state.closing_inspect_input = false
  end)
end

local function update_add_dialog_lines(adding_project, provider, step)
  if not is_valid_buf(M.state.add_dialog_buf) then
    return
  end

  step = step or M.state.add_dialog_step or "dropdown"
  local buf = M.state.add_dialog_buf
  vim.bo[buf].modifiable = true

  if step == "dropdown" then
    local gh_selected = provider == "github"
    local cb_selected = provider == "codeberg"
    local gh_prefix = gh_selected and "  ▸ ● " or "    ○ "
    local cb_prefix = cb_selected and "  ▸ ● " or "    ○ "

    local lines = {
      "",
      "  Platform ▾",
      "",
      gh_prefix .. "GitHub",
      cb_prefix .. "Codeberg",
      "",
      "",
      "",
      "  <Enter> select   <j/k> navigate   <Esc> cancel",
    }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, add_dialog_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Title", 1, 2, 10)
    vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Special", 1, 11, 14)

    if gh_selected then
      vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Special", 3, 2, 5)
      vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "DiagnosticOk", 3, 6, -1)
    else
      vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Comment", 3, 0, -1)
    end

    if cb_selected then
      vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Special", 4, 2, 5)
      vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "DiagnosticOk", 4, 6, -1)
    else
      vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Comment", 4, 0, -1)
    end

    vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Comment", 8, 2, -1)
  else
    local field_label = adding_project and "Repository (owner/repo):"
      or "User handle (@username):"

    local prov_label = provider == "codeberg" and "Codeberg" or "GitHub"

    local lines = {
      "",
      "  Platform:  " .. prov_label,
      "",
      "  " .. field_label,
      "",
      "",
      "",
      "",
      "  <Enter> submit   <Esc> back",
    }

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, add_dialog_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Comment", 1, 2, 11)
    vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "DiagnosticOk", 1, 13, -1)
    vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Identifier", 3, 2, -1)
    vim.api.nvim_buf_add_highlight(buf, add_dialog_ns, "Comment", 8, 2, -1)
  end
end

local function open_add_dialog()
  if M.state.view ~= "contributors" or not is_valid_win(M.state.win) then
    return
  end

  close_inspect_input()
  close_add_dialog()
  local adding_project = M.state.community_view == "projects"
  local cursor_target = target_on_cursor()

  local target_project = adding_project
      and cursor_target
      and cursor_target.kind == "project"
      and cursor_target.project
    or nil

  local target_contributor = not adding_project
      and cursor_target
      and cursor_target.kind ~= "project"
      and cursor_target
    or nil

  local parent_width = vim.api.nvim_win_get_width(M.state.win)
  local parent_height = vim.api.nvim_win_get_height(M.state.win)
  local dialog_width = math.min(50, math.max(34, parent_width - 6))
  local dialog_height = 9
  local dialog_row = math.min(1, math.max(0, parent_height - dialog_height - 1))
  local dialog_col = math.min(2, math.max(0, parent_width - dialog_width - 1))
  local input_width = math.max(10, dialog_width - 6)
  local input_col = 2
  local input_row = 4
  local d_buf = vim.api.nvim_create_buf(false, true)
  vim.bo[d_buf].buftype = "nofile"
  vim.bo[d_buf].bufhidden = "wipe"
  vim.bo[d_buf].swapfile = false
  vim.bo[d_buf].filetype = "oculus-add-dialog"
  M.state.add_dialog_buf = d_buf

  local d_win = vim.api.nvim_open_win(d_buf, false, {
    relative = "win",
    win = M.state.win,
    row = dialog_row,
    col = dialog_col,
    width = dialog_width,
    height = dialog_height,
    border = "rounded",
    style = "minimal",
    focusable = true,
    zindex = 70,
  })

  M.state.add_dialog_win = d_win
  use_window_highlights(d_win)
  vim.wo[d_win].winhighlight = "Normal:OculusNormal,NormalFloat:OculusNormal,FloatBorder:WinSeparator"
  vim.wo[d_win].wrap = false
  vim.wo[d_win].cursorline = false
  vim.wo[d_win].number = false
  vim.wo[d_win].relativenumber = false
  vim.wo[d_win].signcolumn = "no"
  local provider = "github"
  M.state.add_dialog_step = "dropdown"
  update_add_dialog_lines(adding_project, provider, "dropdown")
  vim.api.nvim_set_current_win(d_win)
  local platforms = { "github", "codeberg" }
  local go_to_input
  local go_to_dropdown

  local function select_provider(new_provider)
    provider = new_provider
    update_add_dialog_lines(adding_project, provider, "dropdown")
  end

  local function next_provider()
    local idx = 1

    for i, p in ipairs(platforms) do
      if p == provider then
        idx = i
        break
      end
    end

    idx = (idx % #platforms) + 1
    select_provider(platforms[idx])
  end

  local function prev_provider()
    local idx = 1

    for i, p in ipairs(platforms) do
      if p == provider then
        idx = i
        break
      end
    end

    idx = idx - 1

    if idx < 1 then
      idx = #platforms
    end

    select_provider(platforms[idx])
  end

  local function cancel()
    close_add_dialog()
  end

  local d_map_opts = { buffer = d_buf, nowait = true, silent = true }
  local nav = navigation.resolve(M.state.opts)

  vim.keymap.set("n", "<CR>", function()
    go_to_input()
  end, d_map_opts)

  vim.keymap.set("n", "<kEnter>", function()
    go_to_input()
  end, d_map_opts)

  vim.keymap.set("n", "<Space>", function()
    go_to_input()
  end, d_map_opts)

  vim.keymap.set("n", "<Esc>", cancel, d_map_opts)
  vim.keymap.set("n", "q", cancel, d_map_opts)
  vim.keymap.set("n", "<C-c>", cancel, d_map_opts)
  vim.keymap.set("n", "<Down>", next_provider, d_map_opts)
  vim.keymap.set("n", "<Up>", prev_provider, d_map_opts)
  vim.keymap.set("n", nav.down, next_provider, d_map_opts)
  vim.keymap.set("n", nav.up, prev_provider, d_map_opts)
  vim.keymap.set("n", "j", next_provider, d_map_opts)
  vim.keymap.set("n", "k", prev_provider, d_map_opts)
  vim.keymap.set("n", "<Tab>", next_provider, d_map_opts)
  vim.keymap.set("n", "<S-Tab>", prev_provider, d_map_opts)
  vim.keymap.set("n", "<C-n>", next_provider, d_map_opts)
  vim.keymap.set("n", "<C-p>", prev_provider, d_map_opts)
  vim.keymap.set("n", "1", function() select_provider("github") end, d_map_opts)
  vim.keymap.set("n", "g", function() select_provider("github") end, d_map_opts)
  vim.keymap.set("n", "G", function() select_provider("github") end, d_map_opts)
  vim.keymap.set("n", "2", function() select_provider("codeberg") end, d_map_opts)
  vim.keymap.set("n", "c", function() select_provider("codeberg") end, d_map_opts)
  vim.keymap.set("n", "C", function() select_provider("codeberg") end, d_map_opts)

  go_to_input = function()
    M.state.add_dialog_step = "input"
    update_add_dialog_lines(adding_project, provider, "input")
    local i_buf = vim.api.nvim_create_buf(false, true)
    vim.bo[i_buf].buftype = "nofile"
    vim.bo[i_buf].bufhidden = "wipe"
    vim.bo[i_buf].swapfile = false
    vim.bo[i_buf].filetype = "oculus-add-input"
    vim.bo[i_buf].modifiable = true
    M.state.add_input_buf = i_buf

    local i_win = vim.api.nvim_open_win(i_buf, false, {
      relative = "win",
      win = M.state.win,
      row = dialog_row + input_row,
      col = dialog_col + input_col,
      width = input_width,
      height = 1,
      border = "rounded",
      style = "minimal",
      focusable = true,
      zindex = 75,
    })

    M.state.add_input_win = i_win
    vim.api.nvim_set_current_win(i_win)
    use_window_highlights(i_win)
    vim.wo[i_win].winhighlight = "Normal:OculusNormal,NormalFloat:OculusNormal,FloatBorder:Identifier"
    vim.wo[i_win].wrap = false
    vim.wo[i_win].cursorline = false
    vim.wo[i_win].number = false
    vim.wo[i_win].relativenumber = false
    vim.wo[i_win].signcolumn = "no"

    local function submit()
      local lines = is_valid_buf(i_buf) and vim.api.nvim_buf_get_lines(i_buf, 0, 1, false) or {}
      local raw_val = lines[1] or ""
      local val = vim.trim(raw_val)
      local chosen_provider = provider
      close_add_dialog()

      if val == "" then
        return
      end

      local added = adding_project
          and add_project({
            repository = val,
            provider = chosen_provider,
          }, target_project)
        or add_contributor({
          username = val,
          provider = chosen_provider,
        }, target_contributor)

      if added and is_valid_win(M.state.win) then
        vim.api.nvim_set_current_win(M.state.win)
        render_contributors()
      end
    end

    local function on_insert_esc()
      local lines = is_valid_buf(i_buf) and vim.api.nvim_buf_get_lines(i_buf, 0, 1, false) or {}
      local raw_val = lines[1] or ""

      if vim.trim(raw_val) == "" then
        go_to_dropdown()
      else
        vim.cmd("stopinsert")
      end
    end

    local i_map_opts = { buffer = i_buf, nowait = true, silent = true }
    vim.keymap.set({ "i", "n" }, "<CR>", submit, i_map_opts)
    vim.keymap.set({ "i", "n" }, "<kEnter>", submit, i_map_opts)
    vim.keymap.set("i", "<Esc>", on_insert_esc, i_map_opts)
    vim.keymap.set("n", "<Esc>", go_to_dropdown, i_map_opts)
    vim.keymap.set("n", "q", cancel, i_map_opts)
    vim.keymap.set({ "i", "n" }, "<C-c>", cancel, i_map_opts)
    vim.cmd("startinsert!")

    vim.schedule(function()
      if is_valid_win(i_win) then
        vim.cmd("startinsert!")
      end
    end)

    if is_sidebar_visible() then
      render_sidebar()
    end
  end

  go_to_dropdown = function()
    M.state.add_dialog_step = "dropdown"
    vim.cmd("stopinsert")

    if is_valid_win(M.state.add_input_win) then
      vim.api.nvim_win_close(M.state.add_input_win, true)
    end

    if is_valid_buf(M.state.add_input_buf) then
      vim.api.nvim_buf_delete(M.state.add_input_buf, { force = true })
    end

    M.state.add_input_win = nil
    M.state.add_input_buf = nil
    update_add_dialog_lines(adding_project, provider, "dropdown")

    if is_valid_win(d_win) then
      vim.api.nvim_set_current_win(d_win)
    end

    if is_sidebar_visible() then
      render_sidebar()
    end
  end

  if is_sidebar_visible() then
    render_sidebar()
  end
end

local prompt_add_account = open_add_dialog

local function remember_removed(option, key)
  local removed = M.state.opts[option] or {}

  for _, existing in ipairs(removed) do
    if type(existing) == "string"
      and existing:lower() == key:lower()
    then
      return
    end
  end

  removed[#removed + 1] = key
  M.state.opts[option] = removed
end

local function remove_current_item()
  if M.state.view ~= "contributors" then
    return
  end

  local target = target_on_cursor()

  if type(target) ~= "table" then
    return
  end

  if target.kind == "project" then
    local key = project_key(target.project)

    if not key then
      return
    end

    for index, project in ipairs(M.state.opts.projects or {}) do
      if project_key(project) == key then
        table.remove(M.state.opts.projects, index)
        break
      end
    end

    remember_removed("removed_projects", key)
    M.state.selected_project = nil
    persist_projects()
    render_contributors()
    return
  end

  local key = contributor_key(target)

  if not key then
    return
  end

  for index, added in ipairs(M.state.contributors) do
    if contributor_key(added) == key then
      table.remove(M.state.contributors, index)
      break
    end
  end

  remember_removed("removed_contributors", key)
  M.state.selected_username = nil
  persist_contributors()
  render_contributors()
end

local function toggle_move_item()
  if M.state.view ~= "contributors" then
    return
  end

  local target = target_on_cursor()

  if not M.state.moving_item then
    if type(target) ~= "table" then
      return
    end

    if target.kind == "project" then
      M.state.moving_item = {
        kind = "project",
        project = target.project,
      }
    else
      M.state.moving_item = {
        kind = "contributor",
        contributor = target,
      }
    end

    update_contributor_selection()
    return
  end

  local moving_item = M.state.moving_item
  M.state.moving_item = nil

  if type(target) ~= "table" then
    update_contributor_selection()
    return
  end

  if moving_item.kind == "project" and target.kind == "project" then
    local source_key = project_key(moving_item.project)
    local dest_key = project_key(target.project)

    if source_key and dest_key and source_key ~= dest_key then
      local source_idx, dest_idx

      for idx, project in ipairs(M.state.opts.projects or {}) do
        local key = project_key(project)

        if key == source_key then
          source_idx = idx
        end

        if key == dest_key then
          dest_idx = idx
        end
      end

      if source_idx and dest_idx then
        local item = table.remove(M.state.opts.projects, source_idx)
        table.insert(M.state.opts.projects, dest_idx, item)
        M.state.selected_project = item
        persist_projects()
      end
    end
  elseif moving_item.kind == "contributor" and target.kind ~= "project" then
    local source_key = contributor_key(moving_item.contributor)
    local dest_key = contributor_key(target)

    if source_key and dest_key and source_key ~= dest_key then
      local source_idx, dest_idx

      for idx, contributor in ipairs(M.state.contributors or {}) do
        local key = contributor_key(contributor)

        if key == source_key then
          source_idx = idx
        end

        if key == dest_key then
          dest_idx = idx
        end
      end

      if source_idx and dest_idx then
        local item = table.remove(M.state.contributors, source_idx)
        table.insert(M.state.contributors, dest_idx, item)
        M.state.selected_username = item.username
        persist_contributors()
      end
    end
  end

  render_contributors()
end

target_on_cursor = function()
  if not is_valid_win(M.state.win) then
    return nil
  end

  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]

  if M.state.line_targets[line] then
    return M.state.line_targets[line]
  end
end

local function open_url(url)
  local ok, err = browser.open(url, M.state.opts)

  if not ok and err then
    vim.notify("Oculus: " .. tostring(err), vim.log.levels.ERROR)
  end
end

local function open_activity_expansion()
  if M.state.view ~= "activity" or not is_valid_win(M.state.win) then
    return false
  end

  local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local event = M.state.activity_expansion_targets[line]

  if not event then
    return false
  end

  if event.type == "PullRequestEvent" then
    return open_pull_request_activity(event)
  end

  return open_commit_activity(event)
end

local function select_current()
  local target = target_on_cursor()

  if M.state.view == "contributors" and type(target) == "table" then
    if target.kind == "project" then
      M.state.selected_project = target.project
      M.state.selected_username = nil
      M.state.project_issue_return = nil
      load_project_activity(target.project, false)
    else
      M.state.selected_project = nil
      M.state.selected_username = target.username
      load_activity(target, false)
    end
  elseif M.state.view == "activity" then
    open_activity_expansion()
  elseif M.state.view == "filters" then
    toggle_filter_type()
  elseif M.state.view == "issue_filters" then
    select_project_issue_filter()
  end
end

local function open_project_issue_activity()
  if M.state.view ~= "activity"
    or M.state.activity_commit_page
    or M.state.activity_issue_page
    or not M.state.activity_project
  then
    return
  end

  M.state.project_issue_return = {
    events = M.state.events,
    cached = M.state.activity_cached,
    notice = M.state.activity_notice,
    page = M.state.activity_page,
    loaded_pages = M.state.activity_loaded_pages,
    source_events = M.state.activity_source_events,
    has_past = M.state.activity_has_past,
    cursor = is_valid_win(M.state.win)
        and vim.api.nvim_win_get_cursor(M.state.win)
      or nil,
  }

  load_project_issues(M.state.activity_project, false)
end

local function open_filters(global)
  if global then
    render_filters({ global = true })
    return
  end

  local scope

  if M.state.view == "contributors" then
    local target = target_on_cursor()

    if type(target) == "table" and target.kind == "project" then
      scope = { project = target.project }
    else
      scope = target
    end
  elseif M.state.view == "activity" then
    scope = M.state.activity_project or M.state.contributor

    if M.state.activity_project then
      scope = { project = M.state.activity_project }
    end
  end

  if type(scope) == "table"
    and (scope.project or scope.username)
  then
    render_filters(scope)
  end
end

local function open_current()
  local target = target_on_cursor()

  if M.state.view == "contributors"
    and type(target) == "table"
    and target.kind ~= "project"
  then
    open_url(contributor_profile_url(target))
  end
end

local function open_activity_in_browser()
  if M.state.view ~= "activity" then
    return
  end

  local target = target_on_cursor()

  if type(target) == "string" then
    open_url(target)
  end
end

local function rebuild_activity_inspect_queue_lookup()
  local lookup = {}

  for _, entry in ipairs(M.state.activity_inspect_queue or {}) do
    lookup[entry.line_key or entry.url] = true
  end

  local active = M.state.activity_inspect_queue_active

  if active then
    lookup[active.line_key or active.url] = true
  end

  M.state.activity_inspect_queue_lookup = lookup
end

local function apply_activity_inspect_queue_highlights()
  if not is_valid_buf(M.state.buf) then
    return
  end

  vim.api.nvim_buf_clear_namespace(
    M.state.buf,
    activity_inspect_queue_ns,
    0,
    -1
  )

  if M.state.view ~= "activity"
    or not M.state.activity_inspect_queue_show_highlights
  then
    return
  end

  for line in pairs(M.state.activity_title_lines) do
    local queue_key = M.state.activity_queue_line_keys[line]

    if queue_key and M.state.activity_inspect_queue_lookup[queue_key] then
      vim.api.nvim_buf_add_highlight(
        M.state.buf,
        activity_inspect_queue_ns,
        "OculusActivityQueued",
        line - 1,
        0,
        M.state.activity_title_lines[line] == line
            and activity_title_highlight_end(
              vim.api.nvim_buf_get_lines(
                M.state.buf,
                line - 1,
                line,
                false
              )[1]
            )
          or -1
      )
    end
  end
end

local function toggle_activity_inspect_queue()
  if M.state.view ~= "activity"
    or M.state.activity_inspect_queue_running
  then
    return
  end

  local source_line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local title_line = M.state.activity_title_lines[source_line] or source_line
  local line_key = M.state.activity_queue_line_keys[title_line]
  local expanded_event = M.state.activity_expansion_targets[source_line]

  local commits = expanded_event
      and expanded_event.payload
      and expanded_event.payload.commits
    or {}

  if source_line ~= title_line
    and #commits > 1
    and M.state.line_targets[source_line]
      ~= M.state.line_targets[title_line]
  then
    line_key = M.state.activity_queue_line_keys[source_line]
  end

  local url = M.state.line_targets[source_line]
    or M.state.line_targets[title_line]

  local context = M.state.inspect_targets[source_line]
    or M.state.inspect_targets[title_line]

  if type(url) ~= "string"
    or not inspect._parse_target_url(url)
  then
    vim.notify(
      "Oculus: this activity does not have an inspectable target",
      vim.log.levels.WARN
    )

    return
  end

  local removed = false

  for index, entry in ipairs(M.state.activity_inspect_queue) do
    if entry.url == url then
      table.remove(M.state.activity_inspect_queue, index)
      removed = true
      break
    end
  end

  if not removed then
    local clean_title

    if type(M.state.lines) == "table" and M.state.lines[title_line] then
      local raw = M.state.lines[title_line]

      clean_title = vim.trim(
        raw:gsub("^%s*%d+:%d+%s*", ""):gsub("^%s*[-•▶✓*]%s*", "")
      )
    end

    local entry = {
      url = url,
      line_key = line_key,
      title = clean_title,
      context = type(context) == "table" and vim.deepcopy(context) or nil,
    }

    M.state.activity_inspect_queue[#M.state.activity_inspect_queue + 1] = entry

    if #M.state.activity_inspect_queue > 1
      and type(inspect.preload) == "function"
    then
      inspect.preload(entry.url, M.state.opts, entry.context)
    end
  end

  M.state.activity_inspect_queue_show_highlights = true
  rebuild_activity_inspect_queue_lookup()
  apply_activity_inspect_queue_highlights()
end

local open_next_queued_activity

local function navigate_inspect_queue(delta, group)
  local batch = M.state.activity_inspect_queue_batch

  if not batch or #batch <= 1 then
    return false
  end

  local current_idx = M.state.activity_inspect_queue_index or 1
  local target_idx = current_idx + delta

  if target_idx < 1 or target_idx > #batch then
    return false
  end

  local target_entry = batch[target_idx]

  if not target_entry then
    return false
  end

  local completed = {}

  for i = 1, target_idx - 1 do
    completed[#completed + 1] = batch[i]
  end

  M.state.activity_inspect_queue_completed = completed
  local remaining = {}

  for i = target_idx, #batch do
    remaining[#remaining + 1] = batch[i]
  end

  M.state.activity_inspect_queue = remaining
  M.state.activity_inspect_queue_index = target_idx - 1
  M.state.activity_inspect_queue_active = target_entry
  rebuild_activity_inspect_queue_lookup()
  apply_activity_inspect_queue_highlights()
  M.state.activity_inspect_queue_continuing = true
  M.state.activity_inspect_queue_deferred_group = group

  vim.schedule(function()
    M.state.activity_inspect_queue_continuing = nil

    if group then
      require("oculus.inspect")._close_inspection_workflow(group)
    end

    open_next_queued_activity(nil)
  end)

  return true
end

open_next_queued_activity = function(ui_lifecycle)
  if M.state.activity_inspect_queue_total == nil then
    local batch = {}

    for _, item in ipairs(M.state.activity_inspect_queue or {}) do
      batch[#batch + 1] = item
    end

    M.state.activity_inspect_queue_batch = batch
    M.state.activity_inspect_queue_total = #batch
    M.state.activity_inspect_queue_index = 0
    M.state.activity_inspect_queue_completed = {}
  end

  local entry = table.remove(M.state.activity_inspect_queue, 1)
  M.state.activity_inspect_queue_active = entry
  rebuild_activity_inspect_queue_lookup()
  apply_activity_inspect_queue_highlights()

  if not entry then
    M.state.activity_inspect_queue_running = false
    M.state.activity_inspect_queue_number_options = nil
    M.state.activity_inspect_queue_batch = nil
    M.state.activity_inspect_queue_total = nil
    M.state.activity_inspect_queue_index = nil
    M.state.activity_inspect_queue_completed = nil
    local deferred = M.state.activity_inspect_queue_deferred_group
    M.state.activity_inspect_queue_deferred_group = nil

    if deferred then
      vim.schedule(function()
        require("oculus.inspect")._close_inspection_workflow(deferred)
      end)
    end

    return true
  end

  M.state.activity_inspect_queue_index =
    (M.state.activity_inspect_queue_index or 0) + 1

  local function continue_queue()
    if M.state.activity_inspect_queue_continuing then
      return false
    end

    M.state.activity_inspect_queue_continuing = true

    if M.state.activity_inspect_queue_active == entry then
      if type(M.state.activity_inspect_queue_completed) == "table" then
        M.state.activity_inspect_queue_completed[
          #M.state.activity_inspect_queue_completed + 1
        ] = entry
      end

      M.state.activity_inspect_queue_active = nil
      rebuild_activity_inspect_queue_lookup()
      apply_activity_inspect_queue_highlights()
    end

    vim.schedule(function()
      M.state.activity_inspect_queue_continuing = nil
      open_next_queued_activity(nil)
    end)

    return true
  end

  local queue_info

  if (M.state.activity_inspect_queue_total or 0) > 1 then
    queue_info = {
      active = entry,
      active_index = M.state.activity_inspect_queue_index or 1,
      total = M.state.activity_inspect_queue_total or 1,
      items = vim.deepcopy(M.state.activity_inspect_queue or {}),
      completed = vim.deepcopy(
        M.state.activity_inspect_queue_completed or {}
      ),
    }
  end

  local lifecycle = {
    overview_on_open = M.state.activity_inspect_queue_deferred_group ~= nil,
    queue_info = queue_info,
    on_next_queue_item = function(group)
      return navigate_inspect_queue(1, group)
    end,
    on_previous_queue_item = function(group)
      return navigate_inspect_queue(-1, group)
    end,
    on_progress = ui_lifecycle and ui_lifecycle.on_progress or nil,
    on_complete = function(message)
      if not message then
        M.state.activity_inspect_queue_deferred_group = nil
        M.state.activity_inspect_queue_show_highlights = false
        apply_activity_inspect_queue_highlights()
      end

      if ui_lifecycle and ui_lifecycle.on_complete then
        ui_lifecycle.on_complete(message)
      elseif message then
        vim.notify("Oculus: " .. tostring(message), vim.log.levels.WARN)
      end

      if message then
        continue_queue()
      end
    end,
    on_closed = continue_queue,
    on_close_requested = function(group)
      if M.state.activity_inspect_queue_deferred_group == group then
        return true
      end

      if #M.state.activity_inspect_queue == 0 then
        return false
      end

      M.state.activity_inspect_queue_deferred_group = group
      return continue_queue() or true
    end,
  }

  local ok, err = inspect.open(
    entry.url,
    M.state.opts,
    entry.context,
    lifecycle,
    M.state.activity_inspect_queue_number_options
  )

  if not ok then
    if ui_lifecycle and ui_lifecycle.on_complete then
      ui_lifecycle.on_complete(err)
    elseif err then
      vim.notify("Oculus: " .. tostring(err), vim.log.levels.WARN)
    end

    continue_queue()
  end

  return ok, err
end

local function inspect_current()
  if M.state.view ~= "activity" then
    vim.notify(
      "Oculus: select a change or issue to inspect",
      vim.log.levels.WARN
    )

    return
  end

  local queued_entry = not M.state.activity_inspect_queue_running
      and M.state.activity_inspect_queue[1]
    or nil

  local target = queued_entry and queued_entry.url or target_on_cursor()

  if type(target) ~= "string" then
    vim.notify(
      "Oculus: this activity does not have an inspectable target",
      vim.log.levels.WARN
    )

    return
  end

  local source_line = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local loading_target = target
  local loading_line_key

  if queued_entry then
    local final_entry = M.state.activity_inspect_queue[
      #M.state.activity_inspect_queue
    ]

    loading_target = final_entry and final_entry.url or target
    loading_line_key = final_entry and final_entry.line_key or nil
    source_line = nil

    for candidate, line_key in pairs(M.state.activity_queue_line_keys) do
      if line_key == loading_line_key
        and M.state.line_targets[candidate] == loading_target
      then
        source_line = candidate
        break
      end
    end
  end

  local line = source_line
    and (
      queued_entry and source_line
      or (M.state.activity_title_lines[source_line] or source_line)
    )
    or nil

  local activity_buf = M.state.buf

  local activity_line = line and vim.api.nvim_buf_get_lines(
      activity_buf,
      line - 1,
      line,
      false
    )[1]
    or ""

  local function set_loading_line(text)
    if not line or not is_valid_buf(activity_buf) then
      return
    end

    local modifiable = vim.bo[activity_buf].modifiable
    vim.bo[activity_buf].modifiable = true

    vim.api.nvim_buf_set_lines(
      activity_buf,
      line - 1,
      line,
      false,
      { text }
    )

    vim.bo[activity_buf].modifiable = modifiable
    apply_activity_inspect_queue_highlights()
  end

  local function clear_spinner()
    if source_line
      and is_valid_buf(activity_buf)
      and M.state.buf == activity_buf
      and M.state.view == "activity"
      and M.state.line_targets[source_line] == loading_target
    then
      set_loading_line(activity_line)

      vim.api.nvim_buf_clear_namespace(
        activity_buf,
        inspect_loading_ns,
        0,
        -1
      )
    end
  end

  local lifecycle = {
      on_progress = function(frame)
        if not source_line
          or not is_valid_buf(activity_buf)
          or M.state.buf ~= activity_buf
          or M.state.view ~= "activity"
          or M.state.line_targets[source_line] ~= loading_target
        then
          return
        end

        clear_spinner()

        local loading_line, spinner_column =
          activity_loading_line(
            activity_line,
            frame,
            M.state.activity_title_lines[line] == line
          )

        set_loading_line(loading_line)

        vim.api.nvim_buf_add_highlight(
          activity_buf,
          inspect_loading_ns,
          "DiagnosticInfo",
          line - 1,
          spinner_column,
          spinner_column + #frame
        )

        vim.cmd("redraw")
      end,
      on_complete = function(message)
        clear_spinner()

        if message then
          vim.notify(
            "Oculus: " .. tostring(message),
            vim.log.levels.WARN
          )
        end
      end,
    }

  local ok, err

  if queued_entry then
    M.state.activity_inspect_queue_running = true
    M.state.activity_inspect_queue_total = nil
    M.state.activity_inspect_queue_index = nil
    M.state.activity_inspect_queue_completed = nil

    M.state.activity_inspect_queue_number_options =
      M.inspection_window_options()

    open_next_queued_activity(lifecycle)
    ok = true
  else
    ok, err = inspect.open(
      target,
      M.state.opts,
      M.state.inspect_targets[source_line]
        or M.state.inspect_targets[line],
      lifecycle
    )
  end

  if not ok and err then
    clear_spinner()
    vim.notify("Oculus: " .. err, vim.log.levels.WARN)
  end
end

local function investigate_current()
  local target = target_on_cursor()
  local line = is_valid_win(M.state.win) and vim.api.nvim_win_get_cursor(M.state.win)[1] or nil
  local source_line = line and (M.state.activity_title_lines[line] or line) or nil
  local inspect_target = source_line and (M.state.inspect_targets[source_line] or M.state.inspect_targets[line])

  local event = source_line and (
    (M.state.activity_events and (M.state.activity_events[source_line] or M.state.activity_events[line]))
    or M.state.activity_expansion_targets[source_line]
    or M.state.activity_expansion_targets[line]
  )

  local project = M.state.activity_project

  if not project and type(target) == "table" and target.kind == "project" then
    project = target.project or target
  end

  local context = {
    project = project,
    repository = project and project.repository,
    cwd = vim.fn.getcwd(),
    target_context = inspect_target,
    event = event,
  }

  require("oculus").investigate(target, M.state.opts, context)
end

local function prompt_investigate_by_id()
  local cursor_target = target_on_cursor()
  local project = M.state.activity_project

  if not project and type(cursor_target) == "table" and cursor_target.kind == "project" then
    project = cursor_target.project or cursor_target
  end

  vim.ui.input({ prompt = "Investigate (commit, PR #, issue, or empty for project): " }, function(input)
    if input == nil then
      return
    end

    local context = {
      project = project,
      repository = project and project.repository,
      cwd = vim.fn.getcwd(),
    }

    local target = vim.trim(input)

    if target == "" then
      target = nil
    end

    require("oculus").investigate(target, M.state.opts, context)
  end)
end

local function active_list_key()
  if M.state.view == "activity" then
    if M.state.activity_project then
      local repo = M.state.activity_project.repository
        or M.state.activity_project.name
        or "project"

      if M.state.activity_issue_page then
        return "issues:" .. repo
      elseif M.state.activity_commit_page then
        return "commits:" .. repo
      else
        return "activity:" .. repo
      end
    elseif M.state.contributor then
      local user = M.state.contributor.username or "user"
      return "user:" .. user
    end

    return "activity"
  elseif M.state.view == "contributors" then
    if M.state.community_view == "users" then
      return "community:users"
    end

    local target = target_on_cursor()

    if type(target) == "table" and target.kind == "project" then
      local proj = target.project or target
      local repo = proj.repository or proj.name

      if repo then
        return "project:" .. repo
      end
    end

    return "community:projects"
  elseif M.state.view == "issue_filters" and M.state.activity_project then
    local repo = M.state.activity_project.repository
      or M.state.activity_project.name
      or "project"

    return "issue_filters:" .. repo
  elseif M.state.view == "filters" then
    return "filters:" .. (M.state.filter_scope or "global")
  end

  return M.state.view or "default"
end

local function get_search_history(list_key)
  M.state.search_history = M.state.search_history
    or (M.state.opts and M.state.opts.search_history)
    or {}

  local entries = M.state.search_history[list_key]

  if entries and #entries > 0 then
    return vim.deepcopy(entries)
  end

  return {}
end

local function add_search_history(list_key, val)
  if not list_key or not val or val == "" then
    return
  end

  M.state.search_history = M.state.search_history
    or (M.state.opts and M.state.opts.search_history)
    or {}

  local entries = M.state.search_history[list_key] or {}

  for i = #entries, 1, -1 do
    if entries[i] == val then
      table.remove(entries, i)
    end
  end

  table.insert(entries, val)
  M.state.search_history[list_key] = entries

  if M.state.opts then
    M.state.opts.search_history = M.state.search_history

    if M.state.opts.state_file and M.state.opts.state_file ~= "" then
      pcall(require("oculus.storage").save, M.state.opts.state_file, M.state.opts)
    end
  end
end

local function open_inspect_input()
  if not is_valid_win(M.state.win) then
    return
  end

  close_add_dialog()
  close_inspect_input()
  M.state.inspect_input_active = true
  render_activity_footer(true)
  local project = M.state.activity_project

  if not project and M.state.view == "contributors" then
    local target = target_on_cursor()

    if type(target) == "table" and target.kind == "project" then
      project = target.project or target
    end
  end

  local list_key = active_list_key()
  local history_entries = get_search_history(list_key)
  local history_index = nil
  local current_draft = ""
  local commands = footer_commands_text()
  local last_cmd_end = #commands
  local tab_space = 4
  local title = get_inspect_input_title()
  local title_col = last_cmd_end + tab_space
  local input_col = title_col + #title
  local parent_win
  local input_row

  if is_valid_win(M.state.footer_win) then
    parent_win = M.state.footer_win
    input_row = 1
  else
    parent_win = M.state.win
    input_row = vim.api.nvim_win_get_height(M.state.win) - 1
  end

  local parent_width = vim.api.nvim_win_get_width(parent_win)

  if input_col + 6 > parent_width then
    input_col = math.max(0, parent_width - 8)
  end

  local input_width = math.max(4, parent_width - input_col - 2)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "oculus-inspect-input"
  vim.bo[buf].modifiable = true
  M.state.inspect_input_buf = buf

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "win",
    win = parent_win,
    row = input_row,
    col = input_col,
    width = input_width,
    height = 1,
    border = "none",
    style = "minimal",
    focusable = true,
    zindex = 75,
  })

  M.state.inspect_input_win = win
  vim.api.nvim_set_current_win(win)
  use_window_highlights(win)

  vim.wo[win].winhighlight =
    "Normal:OculusNormal,NormalFloat:OculusNormal"

  vim.wo[win].wrap = false
  vim.wo[win].cursorline = false
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"

  local function set_input_text(text)
    if not is_valid_buf(buf) then
      return
    end

    local mode_info = vim.api.nvim_get_mode()
    local was_insert = mode_info.mode:sub(1, 1) == "i"
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { text })

    if is_valid_win(win) then
      pcall(vim.api.nvim_win_set_cursor, win, { 1, #text })

      if was_insert then
        vim.cmd("startinsert!")
      end
    end
  end

  local function history_up()
    if #history_entries == 0 then
      return
    end

    if history_index == nil then
      local lines = is_valid_buf(buf) and vim.api.nvim_buf_get_lines(buf, 0, 1, false) or {}
      current_draft = lines[1] or ""
      history_index = #history_entries
    elseif history_index > 1 then
      history_index = history_index - 1
    else
      return
    end

    set_input_text(history_entries[history_index])
  end

  local function history_down()
    if #history_entries == 0 or history_index == nil then
      return
    end

    if history_index < #history_entries then
      history_index = history_index + 1
      set_input_text(history_entries[history_index])
    else
      history_index = nil
      set_input_text(current_draft)
    end
  end

  local function cancel()
    close_inspect_input()
  end

  local function submit()
    local lines = is_valid_buf(buf) and vim.api.nvim_buf_get_lines(buf, 0, 1, false) or {}
    local raw_val = lines[1] or ""
    local val = vim.trim(raw_val)
    close_inspect_input()

    if val == "" then
      return
    end

    add_search_history(list_key, val)

    local context = {
      project = project,
      repository = project and project.repository or nil,
      provider = project and project.provider or nil,
    }

    require("oculus").inspect(val, M.state.opts, context)
  end

  local function on_insert_esc()
    local lines = is_valid_buf(buf) and vim.api.nvim_buf_get_lines(buf, 0, 1, false) or {}
    local raw_val = lines[1] or ""

    if vim.trim(raw_val) == "" then
      cancel()
    else
      vim.cmd("stopinsert")
    end
  end

  local nav = navigation.resolve(M.state.opts)
  local map_opts = { buffer = buf, nowait = true, silent = true }
  vim.keymap.set({ "i", "n" }, "<CR>", submit, map_opts)
  vim.keymap.set({ "i", "n" }, "<kEnter>", submit, map_opts)
  vim.keymap.set({ "i", "n" }, "<Up>", history_up, map_opts)
  vim.keymap.set({ "i", "n" }, "<Down>", history_down, map_opts)
  vim.keymap.set({ "i", "n" }, "<C-p>", history_up, map_opts)
  vim.keymap.set({ "i", "n" }, "<C-n>", history_down, map_opts)
  vim.keymap.set("n", "k", history_up, map_opts)
  vim.keymap.set("n", "j", history_down, map_opts)

  if nav.up and nav.up ~= "i" and nav.up ~= "k" and nav.up ~= "j" then
    vim.keymap.set("n", nav.up, history_up, map_opts)
  end

  if nav.down and nav.down ~= "i" and nav.down ~= "j" and nav.down ~= "k" then
    vim.keymap.set("n", nav.down, history_down, map_opts)
  end

  vim.keymap.set("i", "<Esc>", on_insert_esc, map_opts)
  vim.keymap.set("n", "<Esc>", cancel, map_opts)
  vim.keymap.set("n", "q", cancel, map_opts)
  vim.keymap.set({ "i", "n" }, "<C-c>", cancel, map_opts)
  vim.cmd("startinsert!")

  vim.schedule(function()
    if is_valid_win(win) then
      vim.cmd("startinsert!")
    end
  end)

  if is_sidebar_visible() then
    render_sidebar()
  end
end

local prompt_inspect_by_id = open_inspect_input

local function toggle_sidebar()
  if not is_valid_win(M.state.win) then
    return
  end

  if vim.o.columns < 100 then
    vim.notify(
      "Oculus: Window width too narrow for command sidebar (< 100 columns)",
      vim.log.levels.WARN
    )

    return
  end

  if is_sidebar_visible() then
    M.state.sidebar_visible = false
    close_sidebar()
  else
    M.state.sidebar_visible = true
  end

  vim.api.nvim_win_set_config(M.state.win, make_win_config(M.state.opts))

  if M.state.view == "contributors" then
    render_contributors()
  elseif M.state.view == "activity" then
    local cursor = is_valid_win(M.state.win)
        and vim.api.nvim_win_get_cursor(M.state.win)
      or nil

    if M.state.events then
      render_activity(
        M.state.events,
        M.state.activity_cached,
        M.state.activity_notice,
        {
          commit_page = M.state.activity_commit_page,
          issue_page = M.state.activity_issue_page,
        }
      )
    else
      render_activity_footer()
      render_sidebar()
      update_activity_cursorline()
    end

    if cursor and is_valid_win(M.state.win) then
      pcall(vim.api.nvim_win_set_cursor, M.state.win, cursor)
    end
  elseif M.state.view == "filters" then
    render_filters(M.state.filter_scope)
  elseif M.state.view == "issue_filters" and M.state.activity_project then
    render_issue_filters(M.state.activity_project)
  elseif M.state.view == "shortcuts" then
    render_shortcuts()
  end
end

local function move_cursor(direction)
  if
    M.state.view ~= "contributors"
    and M.state.view ~= "filters"
    and M.state.view ~= "issue_filters"
    and M.state.view ~= "activity"
  then
    vim.cmd.normal({ direction > 0 and "j" or "k", bang = true })
    return
  end

  if M.state.view == "contributors" then
    local selectable = {}

    for line, candidate in pairs(M.state.line_targets) do
      if type(candidate) == "table" then
        selectable[#selectable + 1] = line
      end
    end

    table.sort(selectable)

    if #selectable > 0 then
      local current_line = vim.api.nvim_win_get_cursor(M.state.win)[1]
      local selected = selectable[direction > 0 and 1 or #selectable]

      for index, line in ipairs(selectable) do
        if line == current_line then
          selected = selectable[((index - 1 + direction)
            % #selectable) + 1]

          break
        elseif direction > 0 and line > current_line then
          selected = line
          break
        elseif direction < 0 and line < current_line then
          selected = line
        end
      end

      local candidate = M.state.line_targets[selected]

      if candidate.kind == "project" then
        M.state.selected_project = candidate.project
        M.state.selected_username = nil
      else
        M.state.selected_project = nil
        M.state.selected_username = candidate.username
      end

      render_contributors()
      return
    end
  end

  if M.state.view == "activity" then
    vim.cmd.normal({ direction > 0 and "j" or "k", bang = true })
    local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
    local min_line = M.state.activity_cursor_min_line or 2

    if line < min_line then
      vim.api.nvim_win_set_cursor(M.state.win, { min_line, 0 })
    end

    update_activity_cursorline()
    return
  end

  local selectable = {}

  for line, target in pairs(M.state.line_targets) do
    local contributor_target = M.state.view ~= "activity"
      and type(target) == "table"

    local activity_target = M.state.view == "activity"
      and type(target) == "string"

    if contributor_target or activity_target then
      selectable[#selectable + 1] = line
    end
  end

  table.sort(selectable)

  if #selectable == 0 then
    return
  end

  local current = vim.api.nvim_win_get_cursor(M.state.win)[1]
  local selected = direction > 0 and selectable[1] or selectable[#selectable]

  for index, line in ipairs(selectable) do
    if line == current then
      local next_index = ((index - 1 + direction) % #selectable) + 1
      selected = selectable[next_index]
      break
    elseif direction > 0 and line > current then
      selected = line
      break
    elseif direction < 0 and line < current then
      selected = line
    end
  end

  vim.api.nvim_win_set_cursor(M.state.win, { selected, 0 })
  local target = M.state.line_targets[selected]

  if M.state.view == "contributors" and type(target) == "table" then
    if target.kind == "project" then
      M.state.selected_project = target.project
      M.state.selected_username = nil
    else
      M.state.selected_project = nil
      M.state.selected_username = target.username
    end
  end

  if M.state.view == "contributors" and type(target) == "table" then
    if target.kind == "project" then
      queue_project_preview(target.project)
    else
      queue_preview(target)
    end
  end
end

local function go_back()
  if M.state.view == "issue_filters" and M.state.activity_project then
    M.state.request_id = M.state.request_id + 1
    load_project_issues(M.state.activity_project, false, 1)
    return
  end

  if M.state.view == "activity" and M.state.activity_issue_page then
    local return_state = M.state.project_issue_return
    M.state.project_issue_return = nil

    if not return_state then
      M.state.request_id = M.state.request_id + 1
      render_contributors()
      return
    end

    M.state.activity_page = return_state.page
    M.state.activity_loaded_pages = return_state.loaded_pages
    M.state.activity_source_events = return_state.source_events
    M.state.activity_has_past = return_state.has_past
    M.state.activity_issue_page = false

    render_activity(
      return_state.events,
      return_state.cached,
      return_state.notice,
      { issue_page = false }
    )

    if return_state.cursor and is_valid_win(M.state.win) then
      vim.api.nvim_win_set_cursor(M.state.win, return_state.cursor)
      update_activity_cursorline()
    end

    return
  end

  if M.state.view == "activity"
    and M.state.activity_commit_page
    and M.state.activity_return
  then
    local return_state = M.state.activity_return
    M.state.activity_return = nil
    M.state.activity_page = return_state.page
    M.state.activity_source_events = return_state.source_events

    render_activity(
      return_state.events,
      return_state.cached,
      return_state.notice
    )

    if return_state.cursor and is_valid_win(M.state.win) then
      vim.api.nvim_win_set_cursor(M.state.win, return_state.cursor)
      update_activity_cursorline()
    end

    return
  end

  if M.state.view == "shortcuts" and M.state.shortcut_return then
    local return_state = M.state.shortcut_return
    M.state.shortcut_return = nil

    if return_state.view == "activity"
      and (M.state.contributor or M.state.activity_project)
    then
      if M.state.activity_error then
        render_error(M.state.activity_error)
      elseif M.state.activity_loaded and M.state.events then
        render_activity(
          M.state.events,
          M.state.activity_cached,
          M.state.activity_notice,
          {
            commit_page = M.state.activity_commit_page,
            issue_page = M.state.activity_issue_page,
          }
        )
      elseif M.state.activity_project then
        load_project_activity(M.state.activity_project, false)
      else
        load_activity(M.state.contributor, false)
      end
    elseif return_state.view == "filters" and M.state.filter_scope then
      render_filters(M.state.filter_scope, return_state.selected_type)
    elseif return_state.view == "issue_filters"
      and M.state.activity_project
    then
      render_issue_filters(
        M.state.activity_project,
        return_state.selected_type
      )
    else
      render_contributors()
    end

    if return_state.cursor and is_valid_win(M.state.win) then
      local line_count = vim.api.nvim_buf_line_count(M.state.buf)

      vim.api.nvim_win_set_cursor(M.state.win, {
        math.min(return_state.cursor[1], line_count),
        return_state.cursor[2],
      })
    end
  elseif
    M.state.view == "activity"
    or M.state.view == "filters"
    or M.state.view == "issue_filters"
  then
    M.state.request_id = M.state.request_id + 1
    render_contributors()
  end
end

local function move_left()
  if M.state.view == "activity"
    and not M.state.activity_commit_page
    and (M.state.activity_page or 1) > 1
  then
    previous_activity_page()
    return
  end

  go_back()
end

local function move_right()
  if open_activity_expansion() then
    return
  end

  if M.state.view == "activity"
    and not M.state.activity_commit_page
  then
    if M.state.activity_project then
      local page = M.state.activity_page or 1

      if page < (M.state.activity_loaded_pages or 1) then
        if M.state.activity_issue_page then
          load_project_issues(M.state.activity_project, false, page + 1)
        else
          load_project_activity(M.state.activity_project, false, page + 1)
        end
      end

      return
    end

    next_activity_page()
    return
  end

  select_current()
end

local function toggle_shortcuts()
  if M.state.view == "shortcuts" then
    go_back()
    return
  end

  local selected_type

  if M.state.view == "filters" then
    local target = target_on_cursor()
    selected_type = target and target.event_type or nil
  elseif M.state.view == "issue_filters" then
    local target = target_on_cursor()
    selected_type = target and target.dimension or nil
  end

  M.state.shortcut_return = {
    view = M.state.view,
    cursor = is_valid_win(M.state.win)
        and vim.api.nvim_win_get_cursor(M.state.win)
      or nil,
    selected_type = selected_type,
  }

  if M.state.view == "activity" then
    M.state.request_id = M.state.request_id + 1
  end

  render_shortcuts()
end

local function toggle_community_view()
  if M.state.view ~= "contributors" then
    return
  end

  M.state.moving_item = nil

  if M.state.community_view == "users" then
    M.state.community_view = "projects"
    M.state.selected_username = nil
  else
    M.state.community_view = "users"
    M.state.selected_project = nil
    M.state.contributor_offset = 1
  end

  render_contributors()
end

local function map_keys(buf)
  local nav = navigation.resolve(M.state.opts)

  local map = function(lhs, rhs, desc)
    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = desc,
    })
  end

  map("<C-c>", M.close, "Close Oculus")
  map("q", M.close, "Close Oculus")

  map("<Esc>", function()
    if M.state.view == "contributors" and M.state.moving_item then
      M.state.moving_item = nil
      update_contributor_selection()
      return
    end

    M.close()
  end, "Close Oculus")

  map("?", toggle_sidebar, "Toggle Oculus command sidebar")
  map("s", toggle_sidebar, "Toggle Oculus command sidebar")
  map("v", toggle_community_view, "Switch Oculus project and user lists")

  map("m", function()
    if M.state.view == "contributors" then
      toggle_move_item()
    end
  end, "Move selected Oculus project or user")

  map("<CR>", select_current, "Select Oculus item")
  map(nav.right, move_right, "Move right in Oculus")
  map("<Right>", move_right, "Move right in Oculus")

  map("<Space>", function()
    if M.state.view == "issue_filters" then
      select_project_issue_filter()
    else
      toggle_filter_type()
    end
  end, "Toggle Oculus item")

  map("o", open_current, "Open Oculus contributor profile")
  map("b", open_activity_in_browser, "Open Oculus activity in browser")

  map("F", function()
    open_filters(true)
  end, "Edit global activity types")

  map("a", function()
    if M.state.view == "contributors" then
      prompt_add_account()
    else
      set_all_filter_types(true)
    end
  end, "Add an Oculus project or user, or enable all filters")

  map("n", function()
    set_all_filter_types(false)
  end, "Disable all Oculus activity filters")

  map("p", next_activity_page, "Load past Oculus activity")

  map("f", function()
    if M.state.view == "activity" and M.state.activity_issue_page then
      render_issue_filters(M.state.activity_project)
    elseif M.state.view == "activity" then
      previous_activity_page()
    else
      open_filters(false)
    end
  end, "Move forward or edit Oculus activity categories")

  map("r", function()
    if M.state.view == "contributors" then
      remove_current_item()
    else
      refresh_activity()
    end
  end, "Remove selected Oculus item or refresh activity")

  map("d", reset_filter_types_to_default, "Reset Oculus activity types")
  local inspect_key = nav.inspect == nav.investigate and "h" or nav.inspect
  local inspect_id_key = nav.inspect_id == nav.investigate_id and "H" or nav.inspect_id
  map(inspect_key, inspect_current, "Inspect Oculus change or issue")
  map(inspect_id_key, prompt_inspect_by_id, "Inspect issue, PR, commit, or project by ID")
  map(nav.investigate, investigate_current, "Investigate Oculus change or project")
  map(nav.investigate_id, prompt_investigate_by_id, "Investigate issue, PR, commit, or project by ID")

  if inspect_id_key ~= "H"
    and nav.left ~= "H"
    and nav.up ~= "H"
    and nav.down ~= "H"
    and nav.right ~= "H"
  then
    map("H", prompt_inspect_by_id, "Inspect issue, PR, commit, or project by ID")
  end

  map("<Tab>", toggle_activity_inspect_queue, "Queue Oculus activity inspection")
  map("u", open_project_issue_activity, "Open Oculus project issues")

  map(nav.down, function()
    move_cursor(1)
  end, "Move down in Oculus")

  if nav.up ~= nav.investigate then
    map(nav.up, function()
      move_cursor(-1)
    end, "Move up in Oculus")
  end

  map(nav.left, move_left, "Move left in Oculus")
  map("<Left>", move_left, "Move left in Oculus")

  map("<Down>", function()
    move_cursor(1)
  end, "Select next Oculus contributor")

  map("<Up>", function()
    move_cursor(-1)
  end, "Select previous Oculus contributor")

  map("<ScrollWheelDown>", function()
    move_cursor(1)
  end, "Scroll Oculus contributors down")

  map("<ScrollWheelUp>", function()
    move_cursor(-1)
  end, "Scroll Oculus contributors up")
end

function M.close()
  local origin_tab = M.state.origin_tab
  local origin_win = M.state.origin_win
  local origin_view = vim.deepcopy(M.state.origin_view)
  M.state.request_id = M.state.request_id + 1
  M.state.moving_item = nil
  stop_activity_page_loading()
  vim.api.nvim_clear_autocmds({ group = autocmd_group })

  if is_valid_buf(M.state.buf) then
    vim.api.nvim_buf_clear_namespace(
      M.state.buf,
      inspect_loading_ns,
      0,
      -1
    )
  end

  close_activity_footer()
  close_add_dialog()
  close_inspect_input()
  close_sidebar()

  if is_valid_win(M.state.win) then
    M.state.restore_cursor = vim.api.nvim_win_get_cursor(M.state.win)

    M.state.restore_view = vim.api.nvim_win_call(M.state.win, function()
      return vim.fn.winsaveview()
    end)

    if vim.api.nvim_get_current_win() ~= M.state.win then
      vim.api.nvim_set_current_win(M.state.win)
    end

    vim.api.nvim_win_close(M.state.win, true)
  end

  M.state.buf = nil
  M.state.win = nil
  M.state.sidebar_buf = nil
  M.state.sidebar_win = nil
  M.state.sidebar_visible = nil
  M.state.inspect_input_buf = nil
  M.state.inspect_input_win = nil
  M.state.closing_inspect_input = false
  M.state.line_targets = {}
  M.state.inspect_targets = {}
  M.state.activity_title_lines = {}
  M.state.activity_expansion_targets = {}
  M.state.preview_key = nil
  M.state.preview_items = nil
  M.state.preview_contributor = nil
  M.state.preview_project = nil
  M.state.selected_project = nil
  M.state.contributors = {}
  M.state.filter_scope = nil
  M.state.shortcut_return = nil
  M.state.opening_account_prompt = false

  if origin_tab and vim.api.nvim_tabpage_is_valid(origin_tab) then
    vim.api.nvim_set_current_tabpage(origin_tab)

    if is_valid_win(origin_win)
      and vim.api.nvim_win_get_tabpage(origin_win) == origin_tab
    then
      vim.api.nvim_set_current_win(origin_win)

      if origin_view then
        vim.api.nvim_win_call(origin_win, function()
          vim.fn.winrestview(origin_view)
        end)
      end
    end
  end
end

function M.inspection_window_options()
  if not is_valid_win(M.state.win) then
    return nil
  end

  local origin = M.state.origin_win

  if is_valid_win(origin) then
    return {
      number = vim.wo[origin].number,
      relativenumber = vim.wo[origin].relativenumber,
      winhighlight = vim.wo[origin].winhighlight,
    }
  end

  return vim.deepcopy(M.state.origin_window_options)
end

function M.open(opts)
  M.state.opts = opts or {}
  M.state.search_history = M.state.search_history or {}

  if type(M.state.opts.search_history) == "table" then
    for k, v in pairs(M.state.opts.search_history) do
      if not M.state.search_history[k] and type(v) == "table" then
        M.state.search_history[k] = vim.deepcopy(v)
      end
    end
  end

  if is_valid_win(M.state.win) then
    vim.api.nvim_set_current_win(M.state.win)
    update_activity_cursorline()
    return
  end

  local origin_win = vim.api.nvim_get_current_win()
  M.state.origin_tab = vim.api.nvim_get_current_tabpage()
  M.state.origin_win = origin_win
  M.state.highlight_source_win = origin_win
  M.refresh_window_highlights(origin_win)

  M.state.origin_view = vim.api.nvim_win_call(origin_win, function()
    return vim.fn.winsaveview()
  end)

  M.state.origin_window_options = {
    number = vim.wo[origin_win].number,
    relativenumber = vim.wo[origin_win].relativenumber,
    winhighlight = vim.wo[origin_win].winhighlight,
  }

  local buf = make_buf()
  local win = vim.api.nvim_open_win(buf, true, M.window_config(M.state.opts))
  M.state.buf = buf
  M.state.win = win
  M.state.contributors = display_contributors(M.state.opts.contributors)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"

  vim.api.nvim_set_hl(0, "OculusActivityIcon", {
    fg = "#fbd38d",
    bg = "NONE",
  })

  vim.api.nvim_set_hl(0, "OculusActivityPreview", {
    fg = "#9ae6b4",
    bg = "NONE",
  })

  vim.api.nvim_set_hl(0, "OculusContributorSelected", {
    fg = "#ffffff",
  })

  vim.api.nvim_set_hl(0, "OculusMoveTarget", {
    fg = "#ff9e3b",
  })

  vim.wo[win].winhighlight = table.concat({
    "Normal:OculusNormal",
    "NormalFloat:OculusNormal",
    "FloatBorder:OculusBorder",
    "FloatTitle:OculusBorder",
  }, ",")

  use_window_highlights(win)
  vim.wo[win].number = false
  vim.wo[win].relativenumber = false
  vim.wo[win].signcolumn = "no"
  vim.wo[win].winfixbuf = true
  map_keys(buf)

  if M.state.view == "issue_filters" and M.state.activity_project then
    render_issue_filters(M.state.activity_project)
    restore_cursor()
  elseif
    M.state.view == "activity"
    and (M.state.contributor or M.state.activity_project)
    and M.state.events
    and M.state.activity_loaded
  then
    local contributor = M.state.contributor
      and (contributor_by_username(M.state.contributor.username)
        or M.state.contributor)
      or nil

    M.state.contributor = contributor

    if M.state.activity_project then
      M.state.community_view = "projects"
      M.state.selected_project = M.state.activity_project
      M.state.selected_username = nil
    else
      M.state.community_view = "users"
      M.state.selected_username = contributor.username
    end

    render_activity(
      M.state.events,
      M.state.activity_cached,
      M.state.activity_notice,
      {
        commit_page = M.state.activity_commit_page,
        issue_page = M.state.activity_issue_page,
      }
    )

    restore_cursor()
  else
    M.state.community_view = "projects"
    render_contributors()
    restore_cursor()
  end

  M.load_project_descriptions(M.state.opts)
  vim.api.nvim_clear_autocmds({ group = autocmd_group })

  vim.api.nvim_create_autocmd("VimResized", {
    group = autocmd_group,
    buffer = buf,
    callback = function()
      if is_valid_win(M.state.win) then
        if is_valid_win(M.state.add_dialog_win) then
          close_add_dialog()
        end

        if is_valid_win(M.state.inspect_input_win) then
          close_inspect_input()
        end

        vim.api.nvim_win_set_config(M.state.win, make_win_config(M.state.opts))

        if is_sidebar_visible() then
          render_sidebar()
        else
          close_sidebar()
        end

        if M.state.view == "contributors" then
          render_contributors()
        elseif M.state.view == "activity" then
          render_activity_footer()
          update_activity_cursorline()
        elseif M.state.view == "filters" then
          render_filters(M.state.filter_scope)
        elseif M.state.view == "issue_filters" and M.state.activity_project then
          render_issue_filters(M.state.activity_project)
        elseif M.state.view == "shortcuts" then
          render_shortcuts()
        end
      end
    end,
  })

  vim.api.nvim_create_autocmd("CursorMoved", {
    group = autocmd_group,
    buffer = buf,
    callback = function()
      if not is_valid_win(M.state.win) then
        return
      end

      clamp_list_cursor()

      if M.state.view == "activity" then
        update_activity_cursorline()
        return
      end

      if
        M.state.view ~= "contributors"
      then
        return
      end

      local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
      local target = M.state.line_targets[line]

      if type(target) == "table" then
        if target.kind == "project" then
          M.state.selected_project = target.project
          M.state.selected_username = nil
          queue_project_preview(target.project)
        else
          M.state.selected_project = nil
          M.state.selected_username = target.username
          queue_preview(target)
        end
      end

      update_contributor_selection()
    end,
  })

  vim.api.nvim_create_autocmd("WinScrolled", {
    group = autocmd_group,
    callback = function(args)
      if
        M.state.view == "activity"
        and tonumber(args.match) == M.state.win
      then
        update_activity_cursorline()
      end
    end,
  })

  vim.api.nvim_create_autocmd("WinEnter", {
    group = autocmd_group,
    callback = function()
      local entered = vim.api.nvim_get_current_win()

      if not is_valid_win(M.state.win) then
        return
      end

      if entered == M.state.win
        or entered == M.state.sidebar_win
        or entered == M.state.footer_win
        or entered == M.state.add_dialog_win
        or entered == M.state.add_input_win
        or entered == M.state.inspect_input_win
        or is_add_dialog_open()
        or is_inspect_input_open()
        or M.state.closing_add_dialog
        or M.state.closing_inspect_input
      then
        if entered == M.state.win then
          update_activity_cursorline()
        end

        return
      end

      if M.state.opening_account_prompt then
        return
      end

      if vim.api.nvim_win_get_config(entered).relative ~= "" then
        vim.schedule(function()
          if is_valid_win(M.state.win) then
            M.close()
          end
        end)
      end
    end,
  })
end

function M.toggle(opts)
  if is_valid_win(M.state.win) then
    M.close()
  else
    M.open(opts)
  end
end

M._add_project = add_project
M._add_contributor = add_contributor
M._toggle_move_item = toggle_move_item
M._is_sidebar_visible = is_sidebar_visible
M._render_sidebar = render_sidebar
M._toggle_sidebar = toggle_sidebar
M._close_sidebar = close_sidebar
M._navigation = navigation
M._render_error = render_error
M._open_add_dialog = open_add_dialog
M._close_add_dialog = close_add_dialog
M._is_add_dialog_open = is_add_dialog_open
M._prompt_add_account = open_add_dialog
M._open_inspect_input = open_inspect_input
M._close_inspect_input = close_inspect_input
M._is_inspect_input_open = is_inspect_input_open
M._prompt_inspect_by_id = prompt_inspect_by_id
M._footer_commands_text = footer_commands_text
M._inspect_input_title = get_inspect_input_title
M._active_list_key = active_list_key
M._get_search_history = get_search_history
M._add_search_history = add_search_history
return M
