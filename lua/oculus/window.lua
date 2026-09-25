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

local sidebar_ns = vim.api.nvim_create_namespace(
  "oculus_window_sidebar"
)

local commit_activity_url
local load_project_activity
local load_project_issues
local milestone_view = {}
local saved_view = { ns = vim.api.nvim_create_namespace("oculus_saved_items") }
-- `accounts` lists the signed-in accounts in the start screen's sidebar.
local work_view = { accounts = { requested = {} } }
local target_on_cursor
local render_directory
local persist_projects

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
  if project.path then
    return { "push" }
  end

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
  closing = false,
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
  selected_directory = nil,
  current_directory = nil,
  directory_return = nil,
  collapsed_project_directories = {},
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
  project_milestones = nil,
  selected_milestone = nil,
  milestone_offset = 1,
  milestone_return = nil,
  milestone_items_feed = nil,
  activity_milestone = nil,
  activity_saved = false,
  saved_entries = nil,
  saved_expanded_source = nil,
  work_lists = nil,
  selected_work = nil,
  work_offset = 1,
  work_return = nil,
  work_items_feed = nil,
  activity_work = nil,
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
  restore_view_name = nil,
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

local window_highlights = require("oculus.window.highlight").setup(M, {
  is_valid_win = is_valid_win,
})

local use_window_highlights = window_highlights.use_window_highlights
local sync_window_highlights = window_highlights.sync_window_highlights

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

  -- A callable option is resolved at open time so a size can follow the editor.
  -- A failing or nonnumeric result falls back exactly as an absent option does.
  if type(value) == "function" then
    local ok, computed = pcall(value, total)
    value = ok and computed or nil
  end

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
    border = opts.main_border or opts.border or "rounded",
  }
end

function M.window_config(opts)
  return make_win_config(opts or {})
end

-- The whole Oculus footprint: the main window plus any sidebar and the gap
-- between them. Standalone views float at this size so they cover the same
-- region as the main window whether or not the sidebar is currently shown.
local function full_win_config(opts)
  opts = opts or {}
  local width = dimension(opts.width, vim.o.columns, 0.89, 54)
  local height = dimension(opts.height, vim.o.lines, 0.80, 16)
  local row = math.max(0, math.min(opts.row or 1, vim.o.lines - height - 2))

  return {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = math.max(0, math.floor((vim.o.columns - width) / 2)),
    style = "minimal",
    border = opts.main_border or opts.border or "rounded",
  }
end

function M.full_window_config(opts)
  return full_win_config(opts or {})
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
        items = showing_users and {
          { "p", "Projects" },
          { "w", "My work" },
          { "W", "Workspace" },
          { "s", "Saved" },
          { "a", "Add" },
          { nav.inspect_id, "Inspect ID" },
          { "r", "Rename" },
          { "R", "Remove" },
          { "m", "Move" },
          { "f", "Filters" },
          { "d", "Defaults" },
          { "o", "Profile" },
        } or {
          { "u", "Users" },
          { "w", "My work" },
          { "W", "Workspace" },
          { "s", "Saved" },
          { "a", "Add" },
          { "f", "Folder" },
          { "M", "Move Dir" },
          { nav.inspect_id, "Inspect ID" },
          { "<C-r>", "Refresh desc" },
          { "r", "Rename" },
          { "R", "Remove" },
          { "m", "Move" },
          { "F", "Filters" },
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
      { "Tab", "Queue" },
      { "b", "Browser" },
    }

    if not M.state.activity_commit_page then
      if M.state.activity_issue_page then
        actions[#actions + 1] = { "f", "Filters" }
        actions[#actions + 1] = { "m", "Milestones" }
      elseif M.state.activity_project and not M.state.activity_milestone then
        actions[#actions + 1] = { "u", "Issues" }
      end
    end

    actions[#actions + 1] = {
      "s",
      M.state.activity_saved and "Unsave" or "Save",
    }

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
  elseif view == "milestones" or view == "work" then
    return {
      {
        title = "NAVIGATION",
        items = {
          { nav_down, "Down" },
          { nav_up, "Up" },
          { nav_left, "Back" },
          { nav_right, "Open" },
        },
      },
      {
        title = "ACTIONS",
        items = {
          { "b", "Browser" },
          { "r", "Refresh" },
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
  elseif view == "directory" then
    return {
      {
        title = "NAVIGATION",
        items = {
          { nav_down, "Down" },
          { nav_up, "Up" },
          { nav_left, "Back" },
          { "CR", "Select" },
        },
      },
      {
        title = "PROJECTS",
        items = {
          { "w", "My work" },
          { "s", "Saved" },
          { "a", "Add" },
          { "M", "Move Dir" },
          { nav.inspect_id, "Inspect ID" },
          { "r", "Rename" },
          { "R", "Remove" },
          { "m", "Move" },
          { "F", "Filters" },
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

  -- On the start screen the signed-in accounts sit at the bottom of the sidebar.
  local accounts = M.state.view == "contributors" and work_view.accounts.lines() or {}

  if #accounts > 0 then
    lines[#lines + 1] = ""

    while #lines < config.height - #accounts - 1 do
      lines[#lines + 1] = ""
    end

    for _, account in ipairs(accounts) do
      lines[#lines + 1] = "  " .. account
      highlights[#highlights + 1] = { line = #lines, col_start = 2, col_end = -1, hl = "OculusAccounts" }
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

-- Confirmation prompts that temporarily replace the list footer commands.
-- Removing is the default answer, so Enter confirms like y.
local footer_prompt = { keys = "y remove  n cancel" }

-- The commands listed in the current page's footer.
local function page_commands_text()
  local nav = navigation.resolve(M.state.opts)

  if M.state.view == "contributors" then
    local showing_users = M.state.community_view == "users"

    return showing_users
        and "  p projects   w work   s saved   m move   ?: help"
      or "  u users   w work   s saved   f folder   m move   ?: help"
  elseif M.state.view == "directory" then
    return ("  %s/← back   a add   r rename   R remove   m move   ?: help"):format(
      nav.left
    )
  elseif M.state.view == "milestones" or M.state.view == "work" then
    return ("  %s/← back   ⏎ open   b browser   r refresh   ?: help"):format(
      nav.left
    )
  elseif M.state.view == "filters" then
    return ("  %s/← back   ⏎ toggle   a all   n none   ?: help"):format(nav.left)
  elseif M.state.view == "issue_filters" then
    return ("  %s/← back   ⏎ select   ?: help"):format(nav.left)
  elseif M.state.view == "activity" and M.state.activity_error then
    return ("  %s/← back   ?: help"):format(nav.left)
  end

  local inspect_key = nav.inspect
  local activity_commands = ("  %s inspect   b browser"):format(inspect_key)

  if not M.state.activity_commit_page then
    if M.state.activity_issue_page then
      activity_commands = activity_commands .. "   f filters   m milestones"
    else
      if M.state.activity_project and not M.state.activity_milestone then
        activity_commands = activity_commands .. "   u issues"
      end
    end
  end

  activity_commands = activity_commands
    .. (M.state.activity_saved and "   s unsave" or "   s save")

  return activity_commands
end

-- The footer commands, or the pending prompt that temporarily replaces them.
local function footer_commands_text()
  if M.state.footer_prompt then
    return ("  %s  %s"):format(M.state.footer_prompt.question, footer_prompt.keys)
  end

  return page_commands_text()
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
  -- Activity pages list their commands in this floating footer; other pages
  -- draw their own footer rows and only float it for prompts and input.
  local lists_commands = M.state.view == "activity" and not is_sidebar_visible()

  if not force
    and not lists_commands
    and not M.state.footer_prompt
    and not is_inspect_input_open()
  then
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
  vim.api.nvim_buf_add_highlight(buf, ns, "Comment", 0, 2, -1)
  vim.api.nvim_buf_add_highlight(buf, ns, "OculusNormal", 1, 2, #activity_commands)

  if M.state.footer_prompt then
    local question_end = 2 + #M.state.footer_prompt.question
    vim.api.nvim_buf_add_highlight(buf, ns, "WarningMsg", 1, 2, question_end)
  end

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

  if M.state.view == "contributors"
    or M.state.view == "directory"
    or M.state.view == "milestones"
    or M.state.view == "work"
  then
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
        elseif target.kind == "directory" or target.kind == "directory_empty" then
          if (target.name or target.directory) == M.state.selected_directory then
            selected_line = line
          end
        elseif target.kind == "milestone" then
          if target.milestone.id == M.state.selected_milestone then
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

  vim.api.nvim_buf_clear_namespace(M.state.buf, saved_view.ns, 0, -1)
  M.state.preview_items = nil
  -- A redraw replaces the list footer, so any pending prompt is abandoned.
  M.state.footer_prompt = nil
  M.state.list_footer_line = nil
  M.state.list_footer_text = nil
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
    .. (project.path and ("/" .. project.path:lower()) or "")
end

local function project_title(project)
  return project.repository .. (project.path and ("/" .. project.path) or "")
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
  local projects = display_projects(M.state.opts.projects)

  if M.state.workspace_filter_enabled ~= false then
    local ws = require("oculus.workspace").get_active(M.state.opts)

    if ws then
      projects = require("oculus.workspace").filter_projects(M.state.opts, projects)
    end
  end

  return projects
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
-- Fit a commands row within `width` by dropping whole commands from the end,
-- keeping the trailing help hint, rather than cutting a command in half.
local function fit_commands(text, width)
  local commands = vim.split(vim.trim(text), "   ", { plain = true })
  local help = commands[#commands] == "?: help" and table.remove(commands) or nil

  while #commands > 0 do
    local shown = vim.list_extend(vim.list_slice(commands), { help })
    local line = "  " .. table.concat(shown, "   ")

    if vim.fn.strdisplaywidth(line) <= width then
      return line
    end

    table.remove(commands)
  end

  return trim_to_width("  " .. (help or ""), width)
end

-- Pad a page to the window height and end it with the command footer: a
-- separator and the page's commands on the bottom rows, kept within `width`
-- so they stay clear of the preview. The sidebar lists the commands itself,
-- so pages have no footer while it is visible. Returns the commands row.
local function footer(lines, width)
  local window_height = vim.api.nvim_win_get_height(M.state.win)

  if is_sidebar_visible() then
    while #lines < window_height do
      lines[#lines + 1] = ""
    end

    return nil
  end

  while #lines < window_height - 2 do
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "  " .. string.rep("─", math.max(1, width - 2))
  lines[#lines + 1] = pad_cell(fit_commands(page_commands_text(), width - 1), width)
  return #lines
end

-- Record and highlight the footer drawn by footer() once its page is set, so
-- confirmation prompts can take over the commands row.
local function paint_footer(commands_line)
  M.state.list_footer_line = commands_line

  M.state.list_footer_text = commands_line
    and vim.api.nvim_buf_get_lines(M.state.buf, commands_line - 1, commands_line, false)[1]

  if commands_line then
    highlight(commands_line - 1, 2, -1, "WinSeparator")
    highlight(commands_line, 2, -1, "OculusNormal")
  end
end

local function preview_left_width(window_width)
  local preferred = math.max(40, math.floor(window_width * 0.52))
  return math.max(30, math.min(preferred, window_width - 22))
end

-- Draw the list footer row: the pending prompt when one is open, otherwise
-- the commands it temporarily replaced. With the sidebar visible the list
-- has no commands row, so the prompt uses the floating footer instead.
function footer_prompt.paint()
  local prompt = M.state.footer_prompt
  local line = M.state.list_footer_line

  if not line then
    render_activity_footer()
    return
  end

  if not is_valid_buf(M.state.buf) or not is_valid_win(M.state.win) then
    return
  end

  local text = M.state.list_footer_text or ""
  local question_end = nil

  if prompt then
    local width = preview_left_width(vim.api.nvim_win_get_width(M.state.win)) - 1
    -- Shorten the question rather than the keys so the answers stay visible.
    local question = trim_to_width("  " .. prompt.question, math.max(3, width - #footer_prompt.keys - 2))
    text = question .. "  " .. footer_prompt.keys
    question_end = #question
  end

  local current = vim.api.nvim_buf_get_lines(M.state.buf, line - 1, line, false)[1] or ""
  vim.bo[M.state.buf].modifiable = true
  -- Replace the text in place so preview extmarks on this row survive.
  vim.api.nvim_buf_set_text(M.state.buf, line - 1, 0, line - 1, #current, { text })
  vim.bo[M.state.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(M.state.buf, ns, line - 1, line)
  highlight(line, 2, -1, "OculusNormal")

  if question_end then
    highlight(line, 2, question_end, "WarningMsg")
  end
end

function footer_prompt.show(prompt)
  M.state.footer_prompt = prompt
  footer_prompt.paint()
end

function footer_prompt.dismiss()
  if not M.state.footer_prompt then
    return false
  end

  M.state.footer_prompt = nil
  footer_prompt.paint()
  return true
end

function footer_prompt.confirm()
  local prompt = M.state.footer_prompt

  if not prompt then
    return false
  end

  footer_prompt.dismiss()
  prompt.confirm()
  return true
end

local preview = require("oculus.window.preview").setup(M, {
  preview_ns = preview_ns,
  trim_to_width = trim_to_width,
  preview_left_width = preview_left_width,
  pad_cell = pad_cell,
  left_pad_cell = left_pad_cell,
  project_title = project_title,
  project_key = project_key,
  persist_projects = persist_projects,
  is_valid_win = is_valid_win,
  is_valid_buf = is_valid_buf,
  provider_name = provider_name,
  visible_projects = visible_projects,
  contributor_key = contributor_key,
})

local activity_title_highlight_end = preview.activity_title_highlight_end
local activity_item_line = preview.activity_item_line
local activity_loading_line = preview.activity_loading_line
local preview_lines = preview.preview_lines
local without_preview = preview.without_preview
local project_push_author = preview.project_push_author
local project_pull_request_title = preview.project_pull_request_title
local render_preview_panel = preview.render_preview_panel
local preview_items = preview.preview_items
local wrapped_preview_text = preview.wrapped_preview_text
local project_preview_items = preview.project_preview_items
local directory_preview_items = preview.directory_preview_items
local queue_directory_preview = preview.queue_directory_preview
local activity_types_for = preview.activity_types_for
local queue_preview = preview.queue_preview
local fetch_project_description = preview.fetch_project_description
local queue_project_preview = preview.queue_project_preview

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
    (
      M.state.view ~= "contributors"
      and M.state.view ~= "directory"
      and M.state.view ~= "milestones"
      and M.state.view ~= "work"
    )
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
    local hl_group = (M.state.moving_item or M.state.tracking_move) and "OculusMoveTarget"
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

local function startup_project_items()
  M.state.opts = M.state.opts or {}
  local dirs = M.state.opts.project_directories or {}
  local all_projects = visible_projects()
  local dir_map = {}
  local dir_keys = {}
  local active_ws = require("oculus.workspace").get_active(M.state.opts)
  local filter_active = active_ws and M.state.workspace_filter_enabled ~= false

  for _, d in ipairs(dirs) do
    if type(d) == "string" and d ~= "" then
      local show_dir = true

      if filter_active then
        show_dir = false

        for _, p in ipairs(all_projects) do
          if p.directory and p.directory:lower() == d:lower() then
            show_dir = true
            break
          end
        end
      end

      if show_dir then
        local key = "dir:" .. d:lower()

        if not dir_map[key] then
          dir_map[key] = { kind = "directory", name = d }
          dir_keys[#dir_keys + 1] = key
        end
      end
    end
  end

  local proj_map = {}
  local proj_keys = {}

  for _, p in ipairs(all_projects) do
    if not p.directory or p.directory == "" then
      local pkey = project_key(p)

      if pkey then
        local key = "proj:" .. pkey:lower()

        if not proj_map[key] then
          proj_map[key] = { kind = "project", project = p }
          proj_keys[#proj_keys + 1] = key
        end
      end
    end
  end

  local ordered_items = {}
  local seen_keys = {}
  local new_project_order = {}

  for _, key in ipairs(M.state.opts.project_order or {}) do
    if type(key) == "string" then
      local lkey = key:lower()

      if not seen_keys[lkey] then
        if dir_map[lkey] then
          ordered_items[#ordered_items + 1] = dir_map[lkey]
          seen_keys[lkey] = true
          new_project_order[#new_project_order + 1] = lkey
        elseif proj_map[lkey] then
          ordered_items[#ordered_items + 1] = proj_map[lkey]
          seen_keys[lkey] = true
          new_project_order[#new_project_order + 1] = lkey
        end
      end
    end
  end

  for _, key in ipairs(dir_keys) do
    if not seen_keys[key] then
      ordered_items[#ordered_items + 1] = dir_map[key]
      seen_keys[key] = true
      new_project_order[#new_project_order + 1] = key
    end
  end

  for _, key in ipairs(proj_keys) do
    if not seen_keys[key] then
      ordered_items[#ordered_items + 1] = proj_map[key]
      seen_keys[key] = true
      new_project_order[#new_project_order + 1] = key
    end
  end

  M.state.opts.project_order = new_project_order
  return ordered_items
end

-- One entry per forge signed in with a token, e.g. "GitHub: @octocat", in
-- GitHub, Codeberg order.
function work_view.accounts.lines()
  local auth = require("oculus.auth")
  local lines = {}

  for _, provider in ipairs({ "github", "codeberg" }) do
    local viewer = auth.cached_viewer(provider, M.state.opts)

    if viewer then
      lines[#lines + 1] = ("%s: @%s"):format(provider_name(viewer), viewer.login)
    end
  end

  return lines
end

-- Look each signed-in forge up once per window, redrawing the sidebar when an
-- account arrives; a failed lookup waits for the next time the window opens.
function work_view.accounts.render()
  local auth = require("oculus.auth")

  for _, provider in ipairs({ "github", "codeberg" }) do
    if not work_view.accounts.requested[provider]
      and not auth.cached_viewer(provider, M.state.opts)
      and auth.token(provider, M.state.opts)
    then
      work_view.accounts.requested[provider] = true

      auth.viewer(provider, M.state.opts, function(viewer)
        if viewer and M.state.view == "contributors" then
          render_sidebar()
        end
      end)
    end
  end
end

local function render_contributors()
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "contributors"
  M.state.contributor = nil
  M.state.activity_scope = nil
  M.state.activity_project = nil
  M.state.activity_milestone = nil
  M.state.activity_saved = false
  M.state.activity_work = nil
  M.state.events = nil
  M.state.line_targets = {}
  M.state.preview_key = nil
  M.state.preview_project = nil

  if M.state.opts.tracking_file then
    local lines = require("oculus.tracking_ui").render(M.state)
    local left_width = preview_left_width(vim.api.nvim_win_get_width(M.state.win))
    for index, line in ipairs(lines) do lines[index] = pad_cell(trim_to_width(line, left_width - 1), left_width) end
    local window_height = vim.api.nvim_win_get_height(M.state.win)
    local commands_line = footer(lines, left_width)
    set_lines(lines)
    paint_footer(commands_line)
    work_view.accounts.render()
    vim.wo[M.state.win].cursorline = false

    if lines[2] and lines[2] ~= "" then
      highlight(2, 2, -1, "Title")
    end

    -- Give tracked items the same highlights as their preview entries.
    for line, target in pairs(M.state.line_targets) do
      if target.kind == "tracking_group" then
        highlight(line, 2, -1, "OculusDirectory")
      elseif target.kind == "project" or target.username then
        highlight(line, 2, -1, "Identifier")
      end
    end

    -- Leaving a group lands on that group's row; otherwise start at the top.
    local first, selected

    for line, target in pairs(M.state.line_targets) do
      first = math.min(first or line, line)
      if M.state.tracking_selected and target.tracking_index == M.state.tracking_selected then selected = line end
    end

    M.state.tracking_selected = nil
    local cursor_line = selected or first

    if cursor_line then
      vim.api.nvim_win_set_cursor(M.state.win, {cursor_line, 0})
      local target = M.state.line_targets[cursor_line]

      if target.kind == "project" then queue_project_preview(target.project)
      elseif target.username then queue_preview(target)
      else
        local max_visible = math.max(1, window_height - 6)
        render_preview_panel(require("oculus.tracking_ui").preview_items(M.state, target, max_visible))
      end
    else render_preview_panel({[2]={"TRACKING", "Title"}}) end

    update_contributor_selection()
    render_sidebar()
    return
  end

  local community_view = M.state.community_view or "projects"
  local showing_users = community_view == "users"
  local active_ws = require("oculus.workspace").get_active(M.state.opts)
  local title_text

  if showing_users then
    title_text = "  USERS"
  elseif active_ws and M.state.workspace_filter_enabled ~= false then
    title_text = "  PROJECTS · " .. active_ws.name:upper()
  else
    title_text = "  PROJECTS"
  end

  local lines = {
    "",
    title_text,
    "",
  }

  local contributors = showing_users and visible_contributors() or {}
  local left_width = preview_left_width(vim.api.nvim_win_get_width(M.state.win))
  local username_width = 5

  for _, contributor in ipairs(contributors) do
    username_width = math.max(username_width, #(contributor.username) + 1)
  end

  username_width = math.min(username_width, math.max(5, left_width - 2))
  local project_lines = {}
  local project_heading_line

  if not showing_users then
    project_heading_line = 2
    local items = startup_project_items()

    if #items == 0 and active_ws and M.state.workspace_filter_enabled ~= false then
      lines[#lines + 1] = pad_cell("  (no projects in workspace '" .. active_ws.name .. "')", left_width)
    end

    for _, item in ipairs(items) do
      local line = #lines + 1

      if item.kind == "directory" then
        lines[line] = pad_cell("  " .. item.name, left_width)

        M.state.line_targets[line] = {
          kind = "directory",
          name = item.name,
        }
      else
        lines[line] = pad_cell(
          "  " .. project_title(item.project),
          left_width
        )

        M.state.line_targets[line] = {
          kind = "project",
          project = item.project,
        }
      end

      project_lines[#project_lines + 1] = line
    end

    if #items == 0 then
      lines[#lines + 1] = "  No projects configured."
    end
  end

  local user_heading_line

  if showing_users then
    user_heading_line = 2
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

  local commands_line = footer(lines, left_width)
  set_lines(lines)
  paint_footer(commands_line)
  work_view.accounts.render()
  vim.wo[M.state.win].cursorline = false

  if project_heading_line then
    highlight(project_heading_line, 2, -1, "OculusSectionTitle")
  end

  if user_heading_line then
    highlight(user_heading_line, 2, -1, "OculusSectionTitle")
  end

  for line, _ in pairs(M.state.line_targets) do
    local target = M.state.line_targets[line]

    if target.kind == "directory" then
      highlight(line, 2, -1, "OculusDirectory")
    elseif target.kind == "directory_empty" then
      highlight(line, 4, -1, "Comment")
    elseif target.kind == "project" then
      highlight(line, 2, -1, "Identifier")
    else
      highlight(line, 2, 2 + username_width, "Identifier")
    end
  end

  local selected_line

  for line, target in pairs(M.state.line_targets) do
    if target.kind == "project"
      and target.project.repository
        == (M.state.selected_project or {}).repository
    then
      selected_line = line
      break
    elseif (target.kind == "directory" or target.kind == "directory_empty")
      and (target.name or target.directory) == M.state.selected_directory
    then
      selected_line = line
      break
    elseif target.kind ~= "project"
      and target.kind ~= "directory"
      and target.kind ~= "directory_empty"
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
      M.state.selected_directory = nil
    elseif target.kind == "directory" or target.kind == "directory_empty" then
      M.state.selected_project = nil
      M.state.selected_username = nil
      M.state.selected_directory = target.name or target.directory
    else
      M.state.selected_project = nil
      M.state.selected_username = target.username
      M.state.selected_directory = nil
    end

    vim.api.nvim_win_set_cursor(M.state.win, { selected_line, 0 })

    if target.kind == "project" then
      queue_project_preview(target.project)
    elseif target.kind == "directory" or target.kind == "directory_empty" then
      queue_directory_preview(target.name or target.directory)
    else
      queue_preview(target)
    end

    update_contributor_selection()
  else
    local preview_contributor = M.state.preview_contributor
    local preview_project = M.state.preview_project
    local preview_directory = M.state.selected_directory

    if preview_project then
      queue_project_preview(preview_project)
    elseif preview_directory then
      queue_directory_preview(preview_directory)
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

local function reset_to_initial_page()
  stop_activity_page_loading()
  close_activity_footer()
  M.state.view = "contributors"
  M.state.community_view = "projects"
  M.state.contributor = nil
  M.state.activity_scope = nil
  M.state.activity_project = nil
  M.state.activity_milestone = nil
  M.state.activity_saved = false
  M.state.activity_work = nil
  M.state.events = nil
  M.state.line_targets = {}
  M.state.inspect_targets = {}
  M.state.activity_title_lines = {}
  M.state.activity_expansion_targets = {}
  M.state.preview_key = nil
  M.state.preview_items = nil
  M.state.preview_contributor = nil
  M.state.preview_project = nil
  M.state.selected_username = nil
  M.state.selected_project = nil
  M.state.selected_directory = nil
  M.state.current_directory = nil
  M.state.directory_return = nil
  M.state.moving_item = nil
  M.state.contributor_offset = 1
  M.state.filter_scope = nil
  M.state.activity_cached = nil
  M.state.activity_notice = nil
  M.state.activity_error = nil
  M.state.activity_loaded = false
  M.state.activity_page = 1
  M.state.activity_loaded_pages = 1
  M.state.activity_source_events = nil
  M.state.activity_has_past = nil
  M.state.project_activity_feed = nil
  M.state.activity_commit_page = false
  M.state.activity_issue_page = false
  M.state.activity_return = nil
  M.state.project_issue_return = nil
  M.state.project_issue_feed = nil
  M.state.project_milestones = nil
  M.state.selected_milestone = nil
  M.state.milestone_offset = 1
  M.state.milestone_return = nil
  M.state.milestone_items_feed = nil
  M.state.saved_entries = nil
  M.state.saved_expanded_source = nil
  M.state.work_lists = nil
  M.state.selected_work = nil
  M.state.work_offset = 1
  M.state.work_return = nil
  M.state.work_items_feed = nil
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
  M.state.activity_queue_line_keys = {}
  M.state.activity_inspect_queue_scope = nil
  M.state.activity_inspect_queue_running = false
  M.state.restore_cursor = nil
  M.state.restore_view = nil
  M.state.restore_view_name = nil
  M.state.shortcut_return = nil
  M.state.tracking_move = nil
  M.state.tracking_selected = nil

  if is_valid_win(M.state.win) then
    render_contributors()
  end
end

M.reset_to_initial_page = reset_to_initial_page

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

function persist_projects()
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

local directories = require("oculus.window.directories").setup(M, {
  project_key = project_key,
  project_title = project_title,
  render_contributors = render_contributors,
  render_sidebar = render_sidebar,
  persist_projects = persist_projects,
  target_on_cursor = target_on_cursor,
  visible_projects = visible_projects,
  update_contributor_selection = update_contributor_selection,
  queue_project_preview = queue_project_preview,
  queue_directory_preview = queue_directory_preview,
  preview_left_width = preview_left_width,
  is_valid_win = is_valid_win,
  is_sidebar_visible = is_sidebar_visible,
  stop_activity_page_loading = stop_activity_page_loading,
  close_activity_footer = close_activity_footer,
  set_lines = set_lines,
  highlight = highlight,
  pad_cell = pad_cell,
  footer = footer,
  paint_footer = paint_footer,
})

render_directory = directories.render_directory
local create_project_directory = directories.create_project_directory
local remove_project_directory = directories.remove_project_directory
local move_project_to_directory = directories.move_project_to_directory
local move_to_parent_directory = directories.move_to_parent_directory
local toggle_project_directory = directories.toggle_project_directory
local prompt_create_directory = directories.prompt_create_directory

local prompt_move_project_to_directory =
  directories.prompt_move_project_to_directory

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

  local commands_line = footer(lines, vim.api.nvim_win_get_width(M.state.win) - 2)
  set_lines(lines)
  paint_footer(commands_line)
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

  if M.state.view ~= "contributors"
    and not (M.state.view == "filters" and M.state.filter_scope and M.state.filter_scope.global)
  then
    return
  end

  M.state.opts.activity_types = nil
  M.state.opts.user_activity_types = {}
  persist_filter_config()

  if M.state.view == "filters" then
    render_filters(M.state.filter_scope)
  else
    render_contributors()
  end
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

  local commands_line = footer(lines, vim.api.nvim_win_get_width(M.state.win) - 2)
  set_lines(lines)
  paint_footer(commands_line)
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
  M.state.activity_milestone = target.milestone
  M.state.activity_saved = false
  M.state.activity_work = nil
  M.state.activity_return = nil
  M.state.activity_expansion_targets = {}
  M.state.activity_loaded = false
  M.state.activity_error = nil
  local work = target.kind == "work" and target.work or nil
  M.state.activity_work = work
  local project = target.kind == "project" and target.project or nil
  M.state.activity_scope = work and "work" or project and "project" or "user"
  M.state.activity_project = project
  M.state.contributor = (project or work) and nil or target

  local lines = work and work_view.header(work)
    or project
      and {
        "",
        target.milestone and "  MILESTONE"
          or target.issues and "  ISSUES"
          or "  PROJECT",
        "  " .. (
          target.milestone
              and (target.milestone.title .. " · " .. project_title(project))
            or project_title(project)
        ),
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
  local milestone = M.state.activity_milestone
  local work = M.state.activity_work

  local lines = work
      and vim.list_extend(work_view.header(work), {
        "",
        "  Could not load activity",
        "  " .. message,
      })
    or project
      and {
        "",
        milestone and "  MILESTONE"
          or M.state.activity_issue_page and "  ISSUES"
          or "  PROJECT",
        "  " .. (
          milestone and (milestone.title .. " · " .. project_title(project))
            or project_title(project)
        ),
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

  set_lines(lines)
  render_activity_footer()
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
      M.state.activity_milestone
          and ("milestone:" .. tostring(M.state.activity_milestone.id))
        or M.state.activity_issue_page and "issues"
        or "activity",
    }, ":")
  elseif M.state.activity_saved then
    scope = "saved"
  elseif M.state.activity_work then
    scope = "work:" .. M.state.activity_work.key
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

  local milestone = project and M.state.activity_milestone or nil
  local saved_page = M.state.activity_saved == true

  local saved_count = saved_page
      and #require("oculus.saved").items()
    or 0

  local work = M.state.activity_work

  local lines = work
      and work_view.header(work, context_suffix)
    or saved_page
      and {
        "",
        "  SAVED",
        ("  %d saved item%s%s"):format(
          saved_count,
          saved_count == 1 and "" or "s",
          context_suffix
        ),
      }
    or project
      and {
        "",
        milestone and "  MILESTONE"
          or M.state.activity_issue_page and "  ISSUES"
          or "  PROJECT",
        ("  %s · %s%s"):format(
          milestone and milestone.title or project_title(project),
          milestone and project_title(project) or provider_name(project),
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

    local event_project = project
    local saved_project_issue = false

    if saved_page or work then
      local source = saved_view.source_for(event)
      event_project = source and source.kind == "project" and source or nil

      saved_project_issue = event_project ~= nil
        and type(event.id) == "string"
        and event.id:match("^project%-issue:") ~= nil
    end

    if event_project
      and (M.state.activity_issue_page or milestone or saved_project_issue)
      and event.type == "IssuesEvent"
    then
      local issue = event.payload and event.payload.issue or {}
      local actor = event.actor or issue.user or {}
      local author = actor.login or actor.username or actor.name
      local state = issue.state == "closed" and "closed" or "open"

      if type(issue.pull_request) == "table" then
        state = issue.pull_request.merged and "merged" or state
      end

      item.text = ("%s%s %s #%s"):format(
        author and ("@" .. author .. " · ") or "",
        state,
        type(issue.pull_request) == "table" and "pull request" or "issue",
        tostring(issue.number or "?")
      )

      if saved_project_issue then
        item.text = item.text .. " in " .. event_project.repository
      end

      item.detail = tostring(issue.title or "Untitled issue")
      item.summary = nil
    elseif event_project and event.type == "PushEvent" then
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
    lines[#lines + 1] = work
        and "  Nothing here right now."
      or saved_page
        and "  No saved items. Press S on an activity item to save it."
      or milestone
        and "  This milestone has no issues or pull requests."
      or M.state.activity_page > 1
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

  saved_view.mark()
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
    local activity_source = saved_view.source_for(event)

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
  M.state.saved_expanded_source = M.state.activity_saved
      and saved_view.source_for(event)
    or nil

  return show_commit_activity(commit_activity_events(event))
end

local function open_pull_request_activity(event)
  local payload = event.payload or {}
  local pull_request = payload.pull_request or {}
  local repo = event.repo and event.repo.name
  local number = pull_request.number or payload.number
  local source = saved_view.source_for(event)
  local provider = activity_provider(source)
  M.state.saved_expanded_source = M.state.activity_saved and source or nil

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
  local ret = M.state.shortcut_return
  local from_view = ret and ret.view or "contributors"
  local comm_view = ret and ret.community_view or M.state.community_view or "projects"
  local subtitle

  if from_view == "contributors" then
    subtitle = (comm_view == "users") and "Commands for Users" or "Commands for Projects"
  elseif from_view == "directory" then
    subtitle = "Commands for Folder"
  elseif from_view == "activity" then
    subtitle = "Commands for Activity"
  elseif from_view == "milestones" then
    subtitle = "Commands for Milestones"
  elseif from_view == "work" then
    subtitle = "Commands for My Work"
  elseif from_view == "filters" then
    subtitle = "Commands for Activity Filters"
  elseif from_view == "issue_filters" then
    subtitle = "Commands for Issue Filters"
  else
    subtitle = "Commands available in Oculus"
  end

  local sections = {}

  local function section(title, entries)
    sections[#sections + 1] = {
      title = title,
      entries = entries,
    }
  end

  local nav = navigation.resolve(M.state.opts)

  if from_view == "contributors" then
    if comm_view == "users" then
      section("NAVIGATION", {
        { nav.up .. " / <Up>", "Select the previous user" },
        { nav.down .. " / <Down>", "Select the next user" },
        { nav.right .. " / <Right> / <CR>", "Select the current user" },
      })

      section("ACTIONS", {
        { "p", "Switch to project list" },
        { "w", "Open your work: review requests, PRs, mentions" },
        { "s", "Open saved activity items" },
        { "m", "Move the selected user" },
        { "a", "Add a GitHub or Codeberg account" },
        { nav.inspect_id, "Inspect an issue, PR, or commit by ID" },
        { "r", "Rename the selected account" },
        { "R", "Remove the selected account" },
        { "f", "Edit filters for the selected user" },
        { "F", "Edit global activity filters" },
        { "d", "Reset activity filters to defaults" },
        { "o", "Open the selected contributor profile" },
      })

      section("GENERAL", {
        { "? / " .. nav.left .. " / <Left>", "Return to user list" },
        { "q / <Esc> / <C-c>", "Close Oculus" },
      })
    else
      section("NAVIGATION", {
        { nav.up .. " / <Up>", "Select the previous item" },
        { nav.down .. " / <Down>", "Select the next item" },
        { nav.right .. " / <Right> / <CR>", "Select the current item" },
      })

      section("ACTIONS", {
        { "u", "Switch to user list" },
        { "w", "Open your work: review requests, PRs, mentions" },
        { "W", "Select or switch project workspace" },
        { "s", "Open saved activity items" },
        { "f", "Create a project folder" },
        { "m", "Move the selected project or folder" },
        { "M", "Move project to folder" },
        { "a", "Add a GitHub or Codeberg project" },
        { nav.inspect_id, "Inspect an issue, PR, or commit by ID" },
        { "<C-r>", "Refresh project descriptions from forge" },
        { "r", "Rename the selected project or folder" },
        { "R", "Remove the selected project or folder" },
        { "F", "Edit global activity filters" },
        { "d", "Reset activity filters to defaults" },
        { "o", "Open the selected contributor profile" },
      })

      section("GENERAL", {
        { "? / " .. nav.left .. " / <Left>", "Return to project list" },
        { "q / <Esc> / <C-c>", "Close Oculus" },
      })
    end
  elseif from_view == "directory" then
    section("NAVIGATION", {
      { nav.up .. " / <Up>", "Select the previous project" },
      { nav.down .. " / <Down>", "Select the next project" },
      { nav.right .. " / <Right> / <CR>", "Select the current project" },
      { nav.left .. " / <Left>", "Return to project list" },
    })

    section("ACTIONS", {
      { "w", "Open your work: review requests, PRs, mentions" },
      { "s", "Open saved activity items" },
      { "a", "Add a GitHub or Codeberg project" },
      { "r", "Rename the selected project" },
      { "R", "Remove the selected project" },
      { "m", "Move the selected project" },
      { "M", "Move project to folder" },
      { "f", "Create a project folder" },
      { nav.inspect_id, "Inspect an issue, PR, or commit by ID" },
      { "F", "Edit global activity filters" },
      { "d", "Reset activity filters to defaults" },
      { "o", "Open the selected contributor profile" },
    })

    section("GENERAL", {
      { "? / " .. nav.left .. " / <Left>", "Return to folder" },
      { "q / <Esc> / <C-c>", "Close Oculus" },
    })
  elseif from_view == "activity" then
    section("NAVIGATION", {
      { nav.up .. " / <Up>", "Select the previous item" },
      { nav.down .. " / <Down>", "Select the next item" },
      { nav.left .. " / <Left>", "Return to the previous page" },
      { nav.right .. " / <Right>", "Open the next older activity page" },
    })

    local actions = {
      { nav.inspect, "Inspect the selected change or issue" },
      { nav.inspect_id, "Inspect an issue, PR, commit, or project by ID" },
      { "Tab", "Queue activity for sequential inspection" },
      { "b", "Open the selected activity in a browser" },
      { "s", (ret and ret.activity_saved) and "Unsave activity item" or "Save activity item" },
      { "r", "Refresh the current activity page" },
      { "p", "Load the next eight older activity items" },
    }

    if ret and ret.activity_issue_page then
      actions[#actions + 1] = { "f", "Filter issue activity" }
      actions[#actions + 1] = { "m", "Open project milestones" }
    elseif ret and ret.activity_project and not ret.activity_milestone and not ret.activity_commit_page then
      actions[#actions + 1] = { "u", "Open project issues" }
    end

    section("ACTIONS", actions)

    section("GENERAL", {
      { "? / " .. nav.left .. " / <Left>", "Return to activity" },
      { "q / <Esc> / <C-c>", "Close Oculus" },
    })
  elseif from_view == "milestones" then
    section("NAVIGATION", {
      { nav.up .. " / <Up>", "Select the previous milestone" },
      { nav.down .. " / <Down>", "Select the next milestone" },
      { nav.right .. " / <Right> / <CR>", "Open the selected milestone" },
      { nav.left .. " / <Left>", "Return to the previous page" },
    })

    section("ACTIONS", {
      { "b", "Open the selected milestone in a browser" },
      { "r", "Refresh milestones" },
    })

    section("GENERAL", {
      { "? / " .. nav.left .. " / <Left>", "Return to milestones" },
      { "q / <Esc> / <C-c>", "Close Oculus" },
    })
  elseif from_view == "work" then
    section("NAVIGATION", {
      { nav.up .. " / <Up>", "Select the previous item" },
      { nav.down .. " / <Down>", "Select the next item" },
      { nav.right .. " / <Right> / <CR>", "Open the selected item" },
      { nav.left .. " / <Left>", "Return to the previous page" },
    })

    section("ACTIONS", {
      { "b", "Open the selected item in a browser" },
      { "r", "Refresh work items" },
    })

    section("GENERAL", {
      { "? / " .. nav.left .. " / <Left>", "Return to work" },
      { "q / <Esc> / <C-c>", "Close Oculus" },
    })
  elseif from_view == "filters" then
    section("NAVIGATION", {
      { nav.up .. " / <Up>", "Select the previous filter" },
      { nav.down .. " / <Down>", "Select the next filter" },
      { nav.left .. " / <Left>", "Return to the previous page" },
    })

    section("ACTIONS", {
      { "<Space> / l / <CR>", "Toggle the selected activity type" },
      { "a", "Enable every activity type" },
      { "n", "Disable every activity type" },
      { "d", "Reset activity filters to defaults" },
    })

    section("GENERAL", {
      { "? / " .. nav.left .. " / <Left>", "Return to filters" },
      { "q / <Esc> / <C-c>", "Close Oculus" },
    })
  elseif from_view == "issue_filters" then
    section("NAVIGATION", {
      { nav.up .. " / <Up>", "Select the previous filter option" },
      { nav.down .. " / <Down>", "Select the next filter option" },
      { nav.left .. " / <Left>", "Return to the previous page" },
    })

    section("ACTIONS", {
      { "<Space> / <CR>", "Select filter option" },
    })

    section("GENERAL", {
      { "? / " .. nav.left .. " / <Left>", "Return to issue filters" },
      { "q / <Esc> / <C-c>", "Close Oculus" },
    })
  else
    section("NAVIGATION", {
      { nav.up .. " / <Up>", "Select the previous item" },
      { nav.down .. " / <Down>", "Select the next item" },
      { nav.right .. " / <Right> / <CR>", "Select the current item" },
      { nav.left .. " / <Left>", "Return to the previous page" },
    })

    section("GENERAL", {
      { "? / " .. nav.left .. " / <Left>", "Return to Oculus" },
      { "q / <Esc> / <C-c>", "Close Oculus" },
    })
  end

  local win_width = is_valid_win(M.state.win) and vim.api.nvim_win_get_width(M.state.win) or 80
  local win_height = is_valid_win(M.state.win) and vim.api.nvim_win_get_height(M.state.win) or 25
  local footer_height = is_valid_win(M.state.footer_win) and 2 or 0
  local avail_height = math.max(1, win_height - 4 - footer_height)
  local items = {}

  for s_idx, sec in ipairs(sections) do
    if s_idx > 1 then
      items[#items + 1] = { type = "blank" }
    end

    items[#items + 1] = {
      type = "header",
      title = sec.title,
    }

    for _, entry in ipairs(sec.entries) do
      items[#items + 1] = {
        type = "entry",
        key = entry[1],
        desc = entry[2],
        section_title = sec.title,
      }
    end
  end

  local sec_key_widths = {}

  for _, sec in ipairs(sections) do
    local max_k = 0

    for _, entry in ipairs(sec.entries) do
      max_k = math.max(max_k, #entry[1])
    end

    sec_key_widths[sec.title] = max_k + 2
  end

  local function partition_into_columns(num_cols)
    local target_rows = math.ceil(#items / num_cols)
    local max_rows = math.min(avail_height, target_rows)

    if max_rows < target_rows and avail_height > 0 then
      max_rows = avail_height
    end

    local cols = {}

    for c = 1, num_cols do
      cols[c] = {}
    end

    local cur_col = 1

    for _, item in ipairs(items) do
      if #cols[cur_col] >= max_rows and cur_col < num_cols then
        cur_col = cur_col + 1
      end

      if item.type == "header" and #cols[cur_col] == max_rows - 1 and cur_col < num_cols then
        cur_col = cur_col + 1
      end

      if #cols[cur_col] == 0 and item.type == "blank" then
        -- skip leading blank
      else
        if #cols[cur_col] == 0 and item.type == "entry" and item.section_title then
          cols[cur_col][#cols[cur_col] + 1] = {
            type = "header",
            title = item.section_title .. " (cont.)",
          }
        end

        cols[cur_col][#cols[cur_col] + 1] = item
      end
    end

    local col_widths = {}

    for c = 1, num_cols do
      local max_w = 0

      for _, el in ipairs(cols[c]) do
        if el.type == "header" then
          max_w = math.max(max_w, #el.title)
        elseif el.type == "entry" then
          local base_kw = sec_key_widths[el.section_title] or 4
          local kw = num_cols == 1 and math.max(base_kw, 22) or math.max(base_kw, 4)
          max_w = math.max(max_w, kw + #el.desc)
        end
      end

      col_widths[c] = max_w
    end

    local gap = 3
    local total_w = 2

    for c = 1, num_cols do
      total_w = total_w + col_widths[c]

      if c < num_cols then
        total_w = total_w + gap
      end
    end

    return cols, col_widths, total_w
  end

  local chosen_cols = 1
  local chosen_data = nil
  local candidates = {}

  if win_width >= 140 and #items >= 24 then
    candidates = { 3, 2, 1 }
  elseif win_width >= 90 and #items >= 10 then
    candidates = { 2, 1 }
  else
    candidates = { 1 }
  end

  for _, c_count in ipairs(candidates) do
    local cols, col_widths, total_w = partition_into_columns(c_count)

    if c_count == 1 or total_w <= win_width then
      chosen_cols = c_count

      chosen_data = {
        cols = cols,
        col_widths = col_widths,
      }

      break
    end
  end

  local lines = {
    "",
    "  KEYBOARD SHORTCUTS",
    "  " .. subtitle,
    "",
  }

  local header_count = #lines
  local heading_spans = {}
  local cols = chosen_data.cols
  local col_widths = chosen_data.col_widths
  local gap = 3
  local max_col_len = 0

  for c = 1, chosen_cols do
    max_col_len = math.max(max_col_len, #cols[c])
  end

  for r = 1, max_col_len do
    local line_parts = {}
    local current_col_offset = 2

    for c = 1, chosen_cols do
      local el = cols[c][r]
      local cell_text = ""

      if el then
        if el.type == "header" then
          cell_text = el.title

          heading_spans[#heading_spans + 1] = {
            line = header_count + r,
            col_start = current_col_offset,
            col_end = current_col_offset + #el.title,
          }
        elseif el.type == "entry" then
          local base_kw = sec_key_widths[el.section_title] or 4
          local kw = chosen_cols == 1 and math.max(base_kw, 22) or math.max(base_kw, 4)
          cell_text = ("%-" .. kw .. "s%s"):format(el.key, el.desc)
        end
      end

      if c == 1 then
        line_parts[#line_parts + 1] = "  " .. cell_text
      else
        line_parts[#line_parts + 1] = cell_text
      end

      if c < chosen_cols then
        local pad = col_widths[c] - #cell_text + gap
        line_parts[#line_parts + 1] = string.rep(" ", math.max(pad, gap))
        current_col_offset = current_col_offset + col_widths[c] + gap
      end
    end

    local raw_line = table.concat(line_parts)
    lines[#lines + 1] = raw_line:gsub("%s+$", "")
  end

  set_lines(lines)
  vim.wo[M.state.win].cursorline = false
  highlight(2, 2, -1, "Title")
  highlight(3, 2, -1, "Comment")

  for _, span in ipairs(heading_spans) do
    highlight(span.line, span.col_start, span.col_end, "Special")
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
  M.state.restore_view_name = nil
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

local activity = require("oculus.window.activity").setup(M, {
  render_activity = render_activity,
  render_error = render_error,
  render_loading = render_loading,
  project_activity_types_for = project_activity_types_for,
  project_issue_filters_for = project_issue_filters_for,
  project_issue_filter_key = project_issue_filter_key,
  start_activity_page_loading = start_activity_page_loading,
  is_valid_win = is_valid_win,
  is_valid_buf = is_valid_buf,
})

local activity_dedupe_key = activity.dedupe_key
local deduplicate_activity = activity.deduplicate
local activity_page = activity.page
local add_project_issue = activity.add_project_issue
load_project_activity = activity.load_project_activity
load_project_issues = activity.load_project_issues

local view_internal = {
  highlight = highlight,
  activity_page = activity_page,
  trim_to_width = trim_to_width,
  pad_cell = pad_cell,
  footer = footer,
  paint_footer = paint_footer,
  preview_items = preview_items,
  queue_preview = queue_preview,
  preview_left_width = preview_left_width,
  render_preview_panel = render_preview_panel,
  wrapped_preview_text = wrapped_preview_text,
  set_lines = set_lines,
  is_valid_win = is_valid_win,
  is_valid_buf = is_valid_buf,
  is_sidebar_visible = is_sidebar_visible,
  stop_activity_page_loading = stop_activity_page_loading,
  close_activity_footer = close_activity_footer,
  provider_name = provider_name,
  project_title = project_title,
  project_issue_filter_key = project_issue_filter_key,
  render_sidebar = render_sidebar,
  update_contributor_selection = update_contributor_selection,
  render_activity = render_activity,
  update_activity_cursorline = update_activity_cursorline,
  activity_dedupe_key = activity_dedupe_key,
  add_project_issue = add_project_issue,
  deduplicate_activity = deduplicate_activity,
  render_error = render_error,
  render_loading = render_loading,
  start_activity_page_loading = start_activity_page_loading,
}

require("oculus.window.milestones").setup(M, milestone_view, view_internal)
require("oculus.window.work").setup(M, work_view, view_internal)
require("oculus.window.saved").setup(M, saved_view, view_internal)

local function load_activity(contributor, force, page)
  local preserve_activity_page = page ~= nil
    and M.state.view == "activity"
    and M.state.activity_loaded
    and is_valid_buf(M.state.buf)

  M.state.view = "activity"
  M.state.activity_scope = "user"
  M.state.activity_project = nil
  M.state.activity_milestone = nil
  M.state.activity_saved = false
  M.state.activity_work = nil
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
  if M.state.view == "activity"
    and M.state.activity_work
    and not M.state.activity_commit_page
  then
    if M.state.activity_has_past ~= false then
      work_view.load_items(
        M.state.activity_work,
        false,
        (M.state.activity_page or 1) + 1
      )
    end

    return
  end

  if M.state.view == "activity"
    and M.state.activity_saved
    and not M.state.activity_commit_page
  then
    if M.state.activity_has_past then
      saved_view.open((M.state.activity_page or 1) + 1)
    end

    return
  end

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

    if M.state.activity_milestone then
      milestone_view.load_items(
        M.state.activity_project,
        M.state.activity_milestone,
        false,
        page
      )
    elseif M.state.activity_issue_page then
      load_project_issues(M.state.activity_project, false, page)
    else
      load_project_activity(M.state.activity_project, false, page)
    end
  else
    load_activity(M.state.contributor, false, page)
  end
end

local function previous_activity_page()
  if M.state.view == "activity"
    and M.state.activity_work
    and not M.state.activity_commit_page
  then
    if (M.state.activity_page or 1) > 1 then
      work_view.load_items(
        M.state.activity_work,
        false,
        (M.state.activity_page or 1) - 1
      )
    end

    return
  end

  if M.state.view == "activity"
    and M.state.activity_saved
    and not M.state.activity_commit_page
  then
    if (M.state.activity_page or 1) > 1 then
      saved_view.open((M.state.activity_page or 1) - 1)
    end

    return
  end

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
    if M.state.activity_milestone then
      milestone_view.load_items(
        M.state.activity_project,
        M.state.activity_milestone,
        false,
        page
      )
    elseif M.state.activity_issue_page then
      load_project_issues(M.state.activity_project, false, page)
    else
      load_project_activity(M.state.activity_project, false, page)
    end
  else
    load_activity(M.state.contributor, false, page)
  end
end

local function refresh_activity()
  if M.state.view == "milestones" and M.state.project_milestones then
    milestone_view.load(M.state.project_milestones.project, true)
    return
  end

  if M.state.view == "work" then
    work_view.load(true)
    return
  end

  if M.state.view ~= "activity" or M.state.activity_commit_page then
    return
  end

  local page = M.state.activity_page or 1

  if M.state.activity_saved then
    saved_view.open(page, vim.api.nvim_win_get_cursor(M.state.win))
  elseif M.state.activity_work then
    work_view.load_items(M.state.activity_work, true, page)
  elseif M.state.activity_project then
    if M.state.activity_milestone then
      milestone_view.load_items(
        M.state.activity_project,
        M.state.activity_milestone,
        true,
        page
      )
    elseif M.state.activity_issue_page then
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

  if M.state.opts.tracking_file then
    return require("oculus.tracking_ui").add(M.state, added, "users")
  end

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

  local owner, repo_name, rest = cleaned:match("^([%w%._%-]+)/([%w%._%-]+)(.*)$")
  local repository = (owner and repo_name) and (owner .. "/" .. repo_name) or cleaned
  local path = project.path

  if rest and rest ~= "" then
    local branch_path = rest:match("^/tree/[^/]+/(.+)$")
    path = branch_path or rest:match("^/(.+)$")
  end

  if not repository:match("^[%w%._%-]+/[%w%._%-]+$") then
    vim.notify(
      "Oculus: enter a repository as owner/repo",
      vim.log.levels.WARN
    )

    return false
  end

  if path and (detected_provider == "codeberg" or project.provider == "codeberg"
    or not path:match("^[%w_.%-]+([/%w_.%-]*)$")
    or path:find("//", 1, true)
    or path:match("/$")) then
    vim.notify("Oculus: enter a valid GitHub directory path", vim.log.levels.WARN)
    return false
  end

  if path then
    for component in path:gmatch("[^/]+") do
      if component == "." or component == ".." then
        vim.notify("Oculus: enter a valid GitHub directory path", vim.log.levels.WARN)
        return false
      end
    end
  end

  local added = vim.deepcopy(project)
  added.repository = repository
  added.path = path
  local prov = detected_provider or added.provider
  added.provider = prov == "codeberg" and "codeberg" or "github"
  added.name = added.name or (path and path:match("([^/]+)$")) or repo_name

  if M.state.opts.tracking_file then
    return require("oculus.tracking_ui").add(M.state, added, "projects")
  end

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

  if not M.state.closing then
    if is_valid_win(M.state.win) and is_sidebar_visible() then
      close_activity_footer()
      render_sidebar()
    elseif is_valid_win(M.state.win) then
      render_activity_footer()
    end
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
  if
    (M.state.view ~= "contributors" and M.state.view ~= "directory")
    or not is_valid_win(M.state.win)
  then
    return
  end

  close_inspect_input()
  close_add_dialog()
  local current_dir = M.state.view == "directory" and M.state.current_directory or nil
  local adding_project = current_dir ~= nil or M.state.community_view == "projects"
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
            directory = current_dir,
          }, target_project)
        or add_contributor({
          username = val,
          provider = chosen_provider,
        }, target_contributor)

      if added and is_valid_win(M.state.win) then
        vim.api.nvim_set_current_win(M.state.win)

        if current_dir then
          render_directory(current_dir)
        else
          render_contributors()
        end
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
  if M.state.view ~= "contributors" and M.state.view ~= "directory" then
    return
  end

  local target = target_on_cursor()

  if type(target) ~= "table" then
    return
  end

  if target.kind == "directory" or target.kind == "directory_empty" then
    local dir_name = target.name or target.directory

    if dir_name then
      remove_project_directory(dir_name)
    end

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

    if M.state.opts.project_order then
      local proj_k = "proj:" .. key:lower()

      for i = #M.state.opts.project_order, 1, -1 do
        if M.state.opts.project_order[i]:lower() == proj_k then
          table.remove(M.state.opts.project_order, i)
        end
      end
    end

    remember_removed("removed_projects", key)
    M.state.selected_project = nil
    persist_projects()

    if M.state.view == "directory" and M.state.current_directory then
      render_directory(M.state.current_directory)
    else
      render_contributors()
    end

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

function footer_prompt.removal_question(target)
  if M.state.opts.tracking_file and M.state.view == "contributors" then
    return require("oculus.tracking_ui").removal_question(M.state, target)
  elseif target.kind == "directory" or target.kind == "directory_empty" then
    local name = target.name or target.directory
    return name and ('Remove folder "%s"?'):format(name)
  elseif target.kind == "project" then
    return ('Remove "%s"?'):format(project_title(target.project))
  elseif target.username then
    return ('Remove "@%s"?'):format(target.username)
  end
end

-- Removal waits for an answer in the footer (Enter or y removes); moving the cursor or pressing
-- any other key dismisses the prompt without removing anything.
local function request_removal()
  local target = target_on_cursor()
  local question = type(target) == "table" and footer_prompt.removal_question(target)

  if not question then
    return
  end

  footer_prompt.show({
    question = question,
    cursor = vim.api.nvim_win_get_cursor(M.state.win),
    confirm = function()
      if not require("oculus.tracking_ui").handle(M.state, "remove", target_on_cursor()) then
        remove_current_item()
      end

      update_contributor_selection()
    end,
  })
end

local function toggle_move_item()
  if M.state.view ~= "contributors" and M.state.view ~= "directory" then
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
    elseif target.kind == "directory" or target.kind == "directory_empty" then
      M.state.moving_item = {
        kind = "directory",
        name = target.name or target.directory,
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

  if M.state.view == "contributors" and (M.state.community_view or "projects") == "projects" then
    local function get_startup_item_key(item)
      if type(item) ~= "table" then
        return nil
      end

      if item.kind == "project" and item.project then
        local pkey = project_key(item.project)
        return pkey and ("proj:" .. pkey:lower()) or nil
      elseif item.kind == "directory" or item.kind == "directory_empty" then
        local name = item.name or item.directory
        return name and ("dir:" .. name:lower()) or nil
      end

      return nil
    end

    local source_key = get_startup_item_key(moving_item)
    local dest_key = get_startup_item_key(target)

    if source_key and dest_key and source_key ~= dest_key then
      startup_project_items()
      local source_idx, dest_idx

      for idx, k in ipairs(M.state.opts.project_order or {}) do
        if k == source_key then
          source_idx = idx
        end

        if k == dest_key then
          dest_idx = idx
        end
      end

      if source_idx and dest_idx and source_idx ~= dest_idx then
        local moved_k = table.remove(M.state.opts.project_order, source_idx)
        table.insert(M.state.opts.project_order, dest_idx, moved_k)

        if moving_item.kind == "project" and target.kind == "project" then
          local p_source_k = project_key(moving_item.project)
          local p_dest_k = project_key(target.project)
          local p_s_idx, p_d_idx

          for idx, p in ipairs(M.state.opts.projects or {}) do
            local k = project_key(p)

            if k == p_source_k then
              p_s_idx = idx
            end

            if k == p_dest_k then
              p_d_idx = idx
            end
          end

          if p_s_idx and p_d_idx and p_s_idx ~= p_d_idx then
            local p_item = table.remove(M.state.opts.projects, p_s_idx)
            table.insert(M.state.opts.projects, p_d_idx, p_item)
          end
        elseif moving_item.kind == "directory" and (target.kind == "directory" or target.kind == "directory_empty") then
          local d_source_name = (moving_item.name or moving_item.directory):lower()
          local d_dest_name = (target.name or target.directory):lower()
          local d_s_idx, d_d_idx

          for idx, d in ipairs(M.state.opts.project_directories or {}) do
            if type(d) == "string" and d:lower() == d_source_name then
              d_s_idx = idx
            end

            if type(d) == "string" and d:lower() == d_dest_name then
              d_d_idx = idx
            end
          end

          if d_s_idx and d_d_idx and d_s_idx ~= d_d_idx then
            local d_item = table.remove(M.state.opts.project_directories, d_s_idx)
            table.insert(M.state.opts.project_directories, d_d_idx, d_item)
          end
        end

        if moving_item.kind == "project" then
          M.state.selected_project = moving_item.project
          M.state.selected_directory = nil
        else
          M.state.selected_directory = moving_item.name or moving_item.directory
          M.state.selected_project = nil
        end

        persist_projects()
        render_contributors()
        return
      end
    end
  elseif M.state.view == "directory" then
    if moving_item.kind == "project" and target.kind == "project" then
      local source_k = project_key(moving_item.project)
      local dest_k = project_key(target.project)

      if source_k and dest_k and source_k ~= dest_k then
        local s_idx, d_idx

        for idx, p in ipairs(M.state.opts.projects or {}) do
          local k = project_key(p)

          if k == source_k then
            s_idx = idx
          end

          if k == dest_k then
            d_idx = idx
          end
        end

        if s_idx and d_idx and s_idx ~= d_idx then
          local item = table.remove(M.state.opts.projects, s_idx)
          table.insert(M.state.opts.projects, d_idx, item)
          M.state.selected_project = item
          persist_projects()
          render_directory(M.state.current_directory)
          return
        end
      end
    end
  elseif moving_item.kind == "contributor" and target.kind ~= "project" and target.kind ~= "directory" and target.kind ~= "directory_empty" then
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
        render_contributors()
        return
      end
    end
  end

  if M.state.view == "directory" and M.state.current_directory then
    render_directory(M.state.current_directory)
  else
    render_contributors()
  end
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
    if target.kind == "directory" or target.kind == "directory_empty" then
      local dir_name = target.name or target.directory

      if dir_name then
        render_directory(dir_name)
      end

      return
    elseif target.kind == "project" then
      M.state.selected_project = target.project
      M.state.selected_username = nil
      M.state.selected_directory = nil
      M.state.project_issue_return = nil
      M.state.directory_return = nil
      load_project_activity(target.project, false)
    else
      M.state.selected_project = nil
      M.state.selected_username = target.username
      M.state.selected_directory = nil
      M.state.directory_return = nil
      load_activity(target, false)
    end
  elseif M.state.view == "directory" and type(target) == "table" then
    if target.kind == "project" then
      M.state.selected_project = target.project
      M.state.selected_username = nil
      M.state.selected_directory = nil
      M.state.project_issue_return = nil
      M.state.directory_return = M.state.current_directory
      load_project_activity(target.project, false)
    end
  elseif M.state.view == "activity" then
    open_activity_expansion()
  elseif M.state.view == "filters" then
    toggle_filter_type()
  elseif M.state.view == "issue_filters" then
    select_project_issue_filter()
  elseif M.state.view == "milestones"
    and type(target) == "table"
    and target.kind == "milestone"
  then
    M.state.selected_milestone = target.milestone.id

    milestone_view.load_items(
      M.state.project_milestones.project,
      target.milestone,
      false
    )
  elseif M.state.view == "work"
    and type(target) == "table"
    and target.kind == "work"
  then
    M.state.selected_work = target.entry.key
    work_view.load_items(target.entry, false)
  end
end

local function open_project_issue_activity()
  if M.state.view ~= "activity"
    or M.state.activity_commit_page
    or M.state.activity_issue_page
    or M.state.activity_milestone
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

function milestone_view.open()
  if M.state.view ~= "activity"
    or M.state.activity_commit_page
    or not M.state.activity_issue_page
    or not M.state.activity_project
  then
    return
  end

  M.state.milestone_return = {
    project = M.state.activity_project,
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

  milestone_view.load(M.state.activity_project, false)
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
  if M.state.view == "work" then
    local target = target_on_cursor()

    if type(target) == "table" and target.kind == "work" then
      open_url(work_view.web_url(target.entry))
    end

    return
  end

  if M.state.view == "milestones" then
    local target = target_on_cursor()

    if type(target) == "table"
      and target.kind == "milestone"
      and target.milestone.html_url
    then
      open_url(target.milestone.html_url)
    end

    return
  end

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
      reset_to_initial_page()

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
        reset_to_initial_page()
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

local function active_list_key()
  if M.state.view == "activity" then
    if M.state.activity_saved then
      return "saved"
    elseif M.state.activity_work then
      return "work:" .. M.state.activity_work.key
    elseif M.state.activity_project then
      local repo = M.state.activity_project.repository
        or M.state.activity_project.name
        or "project"

      if M.state.activity_milestone then
        return "milestone:" .. repo .. ":"
          .. tostring(M.state.activity_milestone.id)
      elseif M.state.activity_issue_page then
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
  elseif M.state.view == "directory" then
    return "directory:" .. (M.state.current_directory or "default")
  elseif M.state.view == "milestones" and M.state.project_milestones then
    local project = M.state.project_milestones.project
    return "milestones:" .. (project.repository or project.name or "project")
  elseif M.state.view == "work" then
    return "work"
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

  if not project and (M.state.view == "contributors" or M.state.view == "directory") then
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
  -- Keys that enter Insert mode keep their meaning in the input.
  local insert_keys = { i = true, I = true, a = true, A = true }

  if not insert_keys[nav.up] then
    vim.keymap.set("n", nav.up, history_up, map_opts)
  end

  if not insert_keys[nav.down] then
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
  elseif M.state.view == "milestones" then
    milestone_view.render()
  elseif M.state.view == "work" then
    work_view.render()
  elseif M.state.view == "shortcuts" then
    render_shortcuts()
  end
end

local function move_cursor(direction)
  if
    M.state.view ~= "contributors"
    and M.state.view ~= "directory"
    and M.state.view ~= "filters"
    and M.state.view ~= "issue_filters"
    and M.state.view ~= "activity"
    and M.state.view ~= "milestones"
    and M.state.view ~= "work"
  then
    vim.cmd.normal({ direction > 0 and "j" or "k", bang = true })
    return
  end

  if M.state.view == "milestones" then
    milestone_view.select_adjacent(direction)
    return
  end

  if M.state.view == "work" then
    work_view.select_adjacent(direction)
    return
  end

  if M.state.view == "contributors" or M.state.view == "directory" then
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

      if M.state.opts.tracking_file then
        vim.api.nvim_win_set_cursor(M.state.win, {selected, 0})
        vim.api.nvim_exec_autocmds("CursorMoved", {buffer=M.state.buf})
        return
      end

      local candidate = M.state.line_targets[selected]

      if candidate.kind == "project" then
        M.state.selected_project = candidate.project
        M.state.selected_username = nil
        M.state.selected_directory = nil
      elseif candidate.kind == "directory" or candidate.kind == "directory_empty" then
        M.state.selected_project = nil
        M.state.selected_username = nil
        M.state.selected_directory = candidate.name or candidate.directory
      else
        M.state.selected_project = nil
        M.state.selected_username = candidate.username
        M.state.selected_directory = nil
      end

      if M.state.view == "directory" and M.state.current_directory then
        render_directory(M.state.current_directory)
      else
        render_contributors()
      end

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
  if M.state.view == "activity"
    and M.state.activity_work
    and not M.state.activity_commit_page
  then
    M.state.request_id = M.state.request_id + 1
    M.state.activity_work = nil
    work_view.render()
    return
  end

  if M.state.view == "work" then
    M.state.request_id = M.state.request_id + 1
    local dir_name = M.state.work_return
    M.state.work_return = nil

    if dir_name then
      render_directory(dir_name)
    else
      render_contributors()
    end

    return
  end

  if M.state.view == "activity" and M.state.activity_milestone then
    M.state.request_id = M.state.request_id + 1
    M.state.activity_milestone = nil
    milestone_view.render()
    return
  end

  if M.state.view == "milestones" then
    local return_state = M.state.milestone_return
    local list = M.state.project_milestones
    M.state.milestone_return = nil
    M.state.request_id = M.state.request_id + 1

    local project = return_state and return_state.project
      or (list and list.project)

    if not project then
      render_contributors()
      return
    end

    if not return_state or not return_state.events then
      load_project_issues(project, false, return_state and return_state.page)
      return
    end

    M.state.activity_scope = "project"
    M.state.activity_project = project
    M.state.contributor = nil
    M.state.activity_page = return_state.page
    M.state.activity_loaded_pages = return_state.loaded_pages
    M.state.activity_source_events = return_state.source_events
    M.state.activity_has_past = return_state.has_past

    render_activity(
      return_state.events,
      return_state.cached,
      return_state.notice,
      { issue_page = true }
    )

    if return_state.cursor and is_valid_win(M.state.win) then
      pcall(vim.api.nvim_win_set_cursor, M.state.win, return_state.cursor)
      update_activity_cursorline()
    end

    return
  end

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
      and M.state.activity_saved
      and not M.state.activity_commit_page
    then
      saved_view.open(M.state.activity_page)
    elseif return_state.view == "activity"
      and (
        M.state.contributor
        or M.state.activity_project
        or M.state.activity_work
      )
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
      elseif M.state.activity_work then
        work_view.load_items(M.state.activity_work, false)
      elseif M.state.activity_project then
        load_project_activity(M.state.activity_project, false)
      else
        load_activity(M.state.contributor, false)
      end
    elseif return_state.view == "work" and M.state.work_lists then
      work_view.render()
    elseif return_state.view == "filters" and M.state.filter_scope then
      render_filters(M.state.filter_scope, return_state.selected_type)
    elseif return_state.view == "milestones" and M.state.project_milestones then
      milestone_view.render()
    elseif return_state.view == "issue_filters"
      and M.state.activity_project
    then
      render_issue_filters(
        M.state.activity_project,
        return_state.selected_type
      )
    elseif return_state.view == "directory" and return_state.current_directory then
      render_directory(return_state.current_directory)
    else
      if return_state.community_view then
        M.state.community_view = return_state.community_view
      end

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
    or M.state.view == "directory"
  then
    M.state.request_id = M.state.request_id + 1

    if M.state.view == "directory" then
      local prev_dir = M.state.current_directory
      M.state.current_directory = nil
      M.state.directory_return = nil
      M.state.selected_directory = prev_dir
      render_contributors()
    elseif M.state.directory_return then
      local dir_name = M.state.directory_return
      M.state.directory_return = nil
      render_directory(dir_name)
    else
      render_contributors()
    end
  end
end

local function move_left()
  if
    (M.state.view == "directory" or M.state.view == "contributors")
    and M.state.moving_item
    and M.state.moving_item.kind == "project"
  then
    local moving_proj = M.state.moving_item.project

    if moving_proj and (moving_proj.directory or M.state.current_directory) then
      move_to_parent_directory(moving_proj)
      return
    end
  end

  if M.state.view == "contributors" then
    return
  end

  if M.state.view == "directory"
    or M.state.view == "milestones"
    or M.state.view == "work"
  then
    go_back()
    return
  end

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

  if M.state.view == "contributors" then
    local target = target_on_cursor()

    if type(target) == "table" and (target.kind == "directory" or target.kind == "directory_empty") then
      local dir_name = target.name or target.directory

      if dir_name then
        if M.state.moving_item and M.state.moving_item.kind == "project" then
          local moving_project = M.state.moving_item.project
          M.state.moving_item = nil
          move_project_to_directory(moving_project, dir_name)
          return
        end

        M.state.moving_item = nil
        render_directory(dir_name)
        return
      end
    end
  end

  if M.state.view == "activity"
    and not M.state.activity_commit_page
  then
    if M.state.activity_work then
      if (M.state.activity_page or 1) < (M.state.activity_loaded_pages or 1) then
        next_activity_page()
      end

      return
    end

    if M.state.activity_project then
      local page = M.state.activity_page or 1

      if page < (M.state.activity_loaded_pages or 1) then
        if M.state.activity_milestone then
          milestone_view.load_items(
            M.state.activity_project,
            M.state.activity_milestone,
            false,
            page + 1
          )
        elseif M.state.activity_issue_page then
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
    community_view = M.state.community_view,
    cursor = is_valid_win(M.state.win)
        and vim.api.nvim_win_get_cursor(M.state.win)
      or nil,
    selected_type = selected_type,
    activity_commit_page = M.state.activity_commit_page,
    activity_issue_page = M.state.activity_issue_page,
    activity_project = M.state.activity_project,
    activity_milestone = M.state.activity_milestone,
    activity_saved = M.state.activity_saved,
    activity_work = M.state.activity_work,
    current_directory = M.state.current_directory,
  }

  if M.state.view == "activity" then
    M.state.request_id = M.state.request_id + 1
  end

  render_shortcuts()
end

local function toggle_community_view()
  M.state.tracking_move = nil

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

local function prompt_select_workspace()
  local workspace = require("oculus.workspace")
  local all = workspace.list(M.state.opts)
  local active = workspace.get_active(M.state.opts)
  local filter_active = M.state.workspace_filter_enabled ~= false
  local items = {}

  if active then
    items[#items + 1] = {
      kind = "clear",
      label = "✕ Clear active workspace (show all projects)",
    }

    items[#items + 1] = {
      kind = "toggle_filter",
      label = filter_active and "⊘ Toggle workspace filter (currently: ON -> turn OFF)"
        or "⊙ Toggle workspace filter (currently: OFF -> turn ON)",
    }
  end

  for _, ws in ipairs(all) do
    local is_active = active and (active.name:lower() == ws.name:lower())
    local count = #(ws.projects or {})
    local desc = (ws.description and ws.description ~= "") and (" - " .. ws.description) or ""
    local proj_str = string.format(" [%d project%s]", count, count == 1 and "" or "s")
    local mark = is_active and "* " or "  "
    local active_tag = is_active and " (active)" or ""

    items[#items + 1] = {
      kind = "select",
      ws = ws,
      label = string.format("%s%s%s%s%s", mark, ws.name, active_tag, desc, proj_str),
    }
  end

  items[#items + 1] = {
    kind = "new",
    label = "+ Create new workspace…",
  }

  vim.ui.select(items, {
    prompt = "Oculus Workspace:",
    format_item = function(item)
      return item.label
    end,
  }, function(choice)
    if not choice then
      return
    end

    if choice.kind == "clear" then
      workspace.set_active(M.state.opts, nil)

      if is_valid_win(M.state.win) then
        if M.state.opts.tracking_file then
          M.refresh_tracking()
        else
          render_contributors()
        end
      end

      vim.notify("Oculus: Active workspace cleared.", vim.log.levels.INFO)
    elseif choice.kind == "toggle_filter" then
      M.state.workspace_filter_enabled = not filter_active

      if is_valid_win(M.state.win) then
        if M.state.opts.tracking_file then
          M.refresh_tracking()
        else
          render_contributors()
        end
      end

      local status_str = M.state.workspace_filter_enabled and "enabled" or "disabled"
      vim.notify("Oculus: Workspace filter " .. status_str .. ".", vim.log.levels.INFO)
    elseif choice.kind == "select" then
      workspace.set_active(M.state.opts, choice.ws.name)
      M.state.workspace_filter_enabled = true

      if is_valid_win(M.state.win) then
        if M.state.opts.tracking_file then
          M.refresh_tracking()
        else
          render_contributors()
        end
      end

      local count = #(choice.ws.projects or {})
      vim.notify(string.format("Oculus: Switched to workspace '%s' (%d project%s).", choice.ws.name, count, count == 1 and "" or "s"), vim.log.levels.INFO)
    elseif choice.kind == "new" then
      vim.ui.input({ prompt = "New workspace name: " }, function(name)
        if not name or vim.trim(name) == "" then
          return
        end

        name = vim.trim(name)
        local ws, err = workspace.add(M.state.opts, name, { projects = {} })

        if ws then
          workspace.set_active(M.state.opts, name)
          M.state.workspace_filter_enabled = true

          if is_valid_win(M.state.win) then
            if M.state.opts.tracking_file then
              M.refresh_tracking()
            else
              render_contributors()
            end
          end

          vim.notify(string.format("Oculus: Created and activated workspace '%s'.", name), vim.log.levels.INFO)
        else
          vim.notify("Oculus: " .. tostring(err), vim.log.levels.ERROR)
        end
      end)
    end
  end)
end

local function map_keys(buf)
  local nav = navigation.resolve(M.state.opts)

  local map = function(lhs, rhs, desc)
    local original = rhs

    rhs = function()
      local actions = { ["<CR>"]="enter", ["<Right>"]="right", [nav.right]="right",
        ["<Left>"]="left", [nav.left]="left", ["<BS>"]="left", f="group", K="group", D="group", m="move", M="destination", ["<Esc>"]="cancel" }

      if M.state.footer_prompt then
        if lhs == "y" or lhs == "<CR>" then
          footer_prompt.confirm()
          return
        end

        footer_prompt.dismiss()

        if lhs == "n" or lhs == "<Esc>" then
          return
        end
      end

      if actions[lhs] and require("oculus.tracking_ui").handle(M.state, actions[lhs], target_on_cursor()) then
        update_contributor_selection()
        return
      end

      return original()
    end

    vim.keymap.set("n", lhs, rhs, {
      buffer = buf,
      nowait = true,
      silent = true,
      desc = desc,
    })
  end

  map("<C-c>", M.close, "Close Oculus")

  map("q", function()
    if M.state.view == "shortcuts" then
      go_back()
      return
    end

    M.close()
  end, "Close Oculus")

  map("<Esc>", function()
    if (M.state.view == "contributors" or M.state.view == "directory") and M.state.moving_item then
      M.state.moving_item = nil
      update_contributor_selection()
      return
    end

    if M.state.view == "directory"
      or M.state.view == "milestones"
      or M.state.view == "work"
      or M.state.view == "shortcuts"
    then
      go_back()
      return
    end

    M.close()
  end, "Close Oculus")

  map("?", toggle_shortcuts, "Show Oculus keyboard shortcuts")
  map("v", toggle_community_view, "Switch Oculus project and user lists")

  map("W", function()
    if M.state.view == "contributors" or M.state.view == "directory" then
      prompt_select_workspace()
    end
  end, "Select or switch Oculus project workspace")

  map("m", function()
    if M.state.view == "contributors" or M.state.view == "directory" then
      toggle_move_item()
    elseif M.state.view == "activity" and M.state.activity_issue_page then
      milestone_view.open()
    end
  end, "Move selected Oculus project or user, or open project milestones")

  map("M", function()
    if (M.state.view == "contributors" and M.state.community_view == "projects")
      or M.state.view == "directory"
    then
      prompt_move_project_to_directory()
    end
  end, "Move project to directory")

  map("K", function()
    if (M.state.view == "contributors" and M.state.community_view == "projects")
      or M.state.view == "directory"
    then
      prompt_create_directory()
    end
  end, "Create project directory")

  map("D", function()
    if (M.state.view == "contributors" and M.state.community_view == "projects")
      or M.state.view == "directory"
    then
      prompt_create_directory()
    end
  end, "Create project directory")

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
    if
      (M.state.view == "contributors" and M.state.community_view == "projects")
      or M.state.view == "directory"
    then
      open_filters(false)
    else
      open_filters(true)
    end
  end, "Edit activity filters")

  map("a", function()
    if M.state.view == "contributors" or M.state.view == "directory" then
      prompt_add_account()
    else
      set_all_filter_types(true)
    end
  end, "Add an Oculus project or user, or enable all filters")

  map("n", function()
    set_all_filter_types(false)
  end, "Disable all Oculus activity filters")

  map("p", function()
    if M.state.view == "contributors" then
      if M.state.community_view == "users" then
        toggle_community_view()
      end
    else
      next_activity_page()
    end
  end, "Load past Oculus activity")

  map("f", function()
    if M.state.view == "activity" and M.state.activity_issue_page then
      render_issue_filters(M.state.activity_project)
    elseif M.state.view == "activity" then
      previous_activity_page()
    elseif
      (M.state.view == "contributors" and M.state.community_view == "projects")
      or M.state.view == "directory"
    then
      prompt_create_directory()
    else
      open_filters(false)
    end
  end, "Move forward or edit Oculus activity categories")

  map("y", function() end, "Confirm Oculus footer prompt")

  map("r", function()
    if M.state.view == "contributors" or M.state.view == "directory" then
      M.rename()
    else
      refresh_activity()
    end
  end, "Rename selected Oculus item or refresh activity")

  map("R", function()
    if M.state.view == "contributors" or M.state.view == "directory" then
      request_removal()
    end
  end, "Remove the selected Oculus group or item")

  local function refresh_project_descriptions_action()
    local target = target_on_cursor()
    local repo = nil

    if type(target) == "table" and target.kind == "project" and target.project then
      repo = target.project.repository or target.project.name
    end

    M.refresh_project_descriptions(repo, function(projects, updated)
      if repo then
        if #projects > 0 then
          vim.notify(string.format("Oculus: Refreshed project description for '%s'.", repo), vim.log.levels.INFO)
        else
          vim.notify(string.format("Oculus: Project '%s' not found.", repo), vim.log.levels.WARN)
        end
      else
        local count = type(projects) == "table" and #projects or 0

        if count == 0 then
          vim.notify("Oculus: No saved projects to refresh.", vim.log.levels.INFO)
        else
          vim.notify(string.format("Oculus: Refreshed descriptions for %d saved project%s.", count, count == 1 and "" or "s"), vim.log.levels.INFO)
        end
      end
    end)
  end

  map("<C-r>", refresh_project_descriptions_action, "Refresh project description of selected or saved projects")
  map("gR", refresh_project_descriptions_action, "Refresh project description of selected or saved projects")

  local refresh_nav_key = type(M.state.opts) == "table"
      and type(M.state.opts.navigation) == "table"
      and M.state.opts.navigation.refresh_descriptions

  if refresh_nav_key and refresh_nav_key ~= "<C-r>" and refresh_nav_key ~= "gR" then
    map(refresh_nav_key, refresh_project_descriptions_action, "Refresh project description of selected or saved projects")
  end

  map("d", reset_filter_types_to_default, "Reset Oculus activity types")
  local inspect_key = nav.inspect
  local inspect_id_key = nav.inspect_id
  map(inspect_key, inspect_current, "Inspect Oculus change or issue")
  map(inspect_id_key, prompt_inspect_by_id, "Inspect issue, PR, commit, or project by ID")
  map("<Tab>", toggle_activity_inspect_queue, "Queue Oculus activity inspection")

  map("w", function()
    if M.state.view == "contributors" or M.state.view == "directory" then
      work_view.open()
    end
  end, "Open your Oculus work: review requests, pull requests, assignments, mentions")

  map("s", function()
    if M.state.view == "activity" then
      saved_view.toggle()
    elseif M.state.view == "contributors" or M.state.view == "directory" then
      saved_view.open()
    end
  end, "Save or unsave an Oculus activity item, or open saved items")

  map("u", function()
    if M.state.view == "contributors" then
      if M.state.community_view ~= "users" then
        toggle_community_view()
      end
    else
      open_project_issue_activity()
    end
  end, "Open Oculus project issues")

  map(nav.down, function()
    move_cursor(1)
  end, "Move down in Oculus")

  map(nav.up, function()
    move_cursor(-1)
  end, "Move up in Oculus")

  map(nav.left, move_left, "Move left in Oculus")
  map("<Left>", move_left, "Move left in Oculus")
  map("<BS>", move_left, "Go back in Oculus")

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
  if M.state.closing then
    return
  end

  M.state.closing = true
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

  close_add_dialog()
  close_inspect_input()
  close_sidebar()
  close_activity_footer()

  if is_valid_win(M.state.win) then
    M.state.restore_cursor = vim.api.nvim_win_get_cursor(M.state.win)

    M.state.restore_view = vim.api.nvim_win_call(M.state.win, function()
      return vim.fn.winsaveview()
    end)

    M.state.restore_view_name = M.state.view

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

  M.state.closing = false
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
  work_view.accounts.requested = {}
  M.state.buf = buf
  M.state.win = win
  M.state.contributors = display_contributors(M.state.opts.contributors)
  vim.wo[win].wrap = false
  vim.wo[win].cursorline = true
  vim.wo[win].cursorlineopt = "line"

  vim.api.nvim_set_hl(0, "OculusActivityIcon", {
    link = "WarningMsg",
    default = true,
  })

  vim.api.nvim_set_hl(0, "OculusActivityPreview", {
    link = "DiagnosticOk",
    default = true,
  })

  vim.api.nvim_set_hl(0, "OculusMoveTarget", {
    link = "DiagnosticWarn",
    default = true,
  })

  vim.api.nvim_set_hl(0, "OculusDirectory", {
    link = "Directory",
    default = true,
  })

  vim.api.nvim_set_hl(0, "OculusSectionTitle", {
    link = "Keyword",
    default = true,
  })

  vim.api.nvim_set_hl(0, "OculusAccounts", {
    link = "DiagnosticOk",
    default = true,
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

    if M.state.restore_view_name == "issue_filters" then
      restore_cursor()
    else
      M.state.restore_cursor = nil
      M.state.restore_view = nil
      M.state.restore_view_name = nil
    end
  elseif M.state.view == "milestones" and M.state.project_milestones then
    milestone_view.render()
  elseif M.state.view == "work" and M.state.work_lists then
    work_view.render()
  elseif M.state.view == "activity"
    and M.state.activity_work
    and not M.state.activity_commit_page
  then
    -- The new buffer is empty, so draw the feed from scratch.
    M.state.activity_loaded = false
    work_view.load_items(M.state.activity_work, false, M.state.activity_page)

    if M.state.restore_view_name == "activity" then
      restore_cursor()
    else
      M.state.restore_cursor = nil
      M.state.restore_view = nil
      M.state.restore_view_name = nil
    end
  elseif M.state.view == "activity"
    and M.state.activity_saved
    and not M.state.activity_commit_page
  then
    saved_view.open(M.state.activity_page)

    if M.state.restore_view_name == "activity" then
      restore_cursor()
    else
      M.state.restore_cursor = nil
      M.state.restore_view = nil
      M.state.restore_view_name = nil
    end
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

    if M.state.restore_view_name == "activity" then
      restore_cursor()
    else
      M.state.restore_cursor = nil
      M.state.restore_view = nil
      M.state.restore_view_name = nil
    end
  else
    M.state.community_view = "projects"
    render_contributors()

    if M.state.restore_view_name == "contributors" then
      restore_cursor()
      clamp_list_cursor()
      vim.api.nvim_exec_autocmds("CursorMoved", { buffer = buf })
    else
      M.state.restore_cursor = nil
      M.state.restore_view = nil
      M.state.restore_view_name = nil
    end
  end

  if not M.state.opts.tracking_file then M.load_project_descriptions(M.state.opts) end
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
        elseif M.state.view == "milestones" then
          milestone_view.render()
        elseif M.state.view == "work" then
          work_view.render()
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

      if M.state.footer_prompt
        and not vim.deep_equal(vim.api.nvim_win_get_cursor(M.state.win), M.state.footer_prompt.cursor)
      then
        footer_prompt.dismiss()
      end

      clamp_list_cursor()

      if M.state.view == "activity" then
        update_activity_cursorline()
        return
      end

      if M.state.view == "work" then
        local target = M.state.line_targets[
          vim.api.nvim_win_get_cursor(M.state.win)[1]
        ]

        if type(target) == "table" and target.kind == "work" then
          M.state.selected_work = target.entry.key
          work_view.queue_preview(target.entry)
        end

        update_contributor_selection()
        return
      end

      if M.state.view == "milestones" then
        local target = M.state.line_targets[
          vim.api.nvim_win_get_cursor(M.state.win)[1]
        ]

        if type(target) == "table" and target.kind == "milestone" then
          M.state.selected_milestone = target.milestone.id
          milestone_view.queue_preview(target.milestone)
        end

        update_contributor_selection()
        return
      end

      if
        M.state.view ~= "contributors"
        and M.state.view ~= "directory"
      then
        return
      end

      local line = vim.api.nvim_win_get_cursor(M.state.win)[1]
      local target = M.state.line_targets[line]

      if target and target.kind == "tracking_group" then
        M.state.preview_key = nil
        local max_visible = math.max(1, vim.api.nvim_win_get_height(M.state.win) - 6)
        render_preview_panel(require("oculus.tracking_ui").preview_items(M.state, target, max_visible))
        update_contributor_selection()
        return
      end

      if type(target) == "table" then
        if target.kind == "project" then
          M.state.selected_project = target.project
          M.state.selected_username = nil
          M.state.selected_directory = nil
          queue_project_preview(target.project)
        elseif target.kind == "directory" or target.kind == "directory_empty" then
          M.state.selected_project = nil
          M.state.selected_username = nil
          M.state.selected_directory = target.name or target.directory
          queue_directory_preview(target.name or target.directory)
        else
          M.state.selected_project = nil
          M.state.selected_username = target.username
          M.state.selected_directory = nil
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
M.close_activity_footer = close_activity_footer
M.render_activity_footer = render_activity_footer
M._toggle_shortcuts = toggle_shortcuts
M._render_shortcuts = render_shortcuts

function M.rename(name)
  if not is_valid_win(M.state.win) or (M.state.view ~= "contributors" and M.state.view ~= "directory") then
    vim.notify("Oculus: open a Projects or Users list and select an item to rename", vim.log.levels.WARN)
    return false
  end

  if M.state.opts.tracking_file then return require("oculus.tracking_ui").rename(M.state, name) end
  vim.notify("Oculus: renaming requires a tracking_file", vim.log.levels.WARN)
  return false
end

function M.refresh_tracking()
  if is_valid_win(M.state.win) then
    M.state.contributors = display_contributors(M.state.opts.contributors)
    render_contributors()
  end
end

-- Open the Oculus window straight on one project's activity feed. `target` is
-- "owner/repo", "github:owner/repo" or "codeberg:owner/repo"; untracked
-- repositories and GitHub directories open too.
function M.open_project(target, opts)
  local provider, repository = tostring(target or ""):match("^(%a+):(.+)$")
  repository = vim.trim(repository or tostring(target or ""))
  local path

  if not provider or provider == "github" then
    local owner, name, directory = repository:match("^([%w_.%-]+)/([%w_.%-]+)/(.+)$")

    if owner then
      repository = owner .. "/" .. name
      path = directory
    end
  end

  if not repository:match("^[%w_.%-]+/[%w_.%-]+$") then
    return false, "expected owner/repo, github:owner/repo or codeberg:owner/repo"
  end

  if provider and provider ~= "github" and provider ~= "codeberg" then
    return false, "provider must be github or codeberg"
  end

  if path then
    if not path:match("^[%w_.%-]+([/%w_.%-]*)$") or path:find("//", 1, true)
      or path:match("/$") then
      return false, "expected a valid GitHub directory path"
    end

    for component in path:gmatch("[^/]+") do
      if component == "." or component == ".." then
        return false, "expected a valid GitHub directory path"
      end
    end
  end

  M.open(opts)
  local project = nil

  for _, candidate in ipairs(M.state.opts.projects or {}) do
    if
      type(candidate.repository) == "string"
      and candidate.repository:lower() == repository:lower()
      and (candidate.path or ""):lower() == (path or ""):lower()
      and (not provider or (candidate.provider or "github") == provider)
    then
      project = candidate
      break
    end
  end

  load_project_activity(project or {
    repository = repository,
    path = path,
    provider = provider or "github",
  })

  return true
end

function M.open_user(target, opts)
  local provider, username = tostring(target or ""):match("^(%a+):(.+)$")
  username = vim.trim(username or tostring(target or "")):gsub("^@", "")

  if not username:match("^[%w][%w_.%-]*$") then
    return false, "expected login, github:login or codeberg:login"
  end

  if provider and provider ~= "github" and provider ~= "codeberg" then
    return false, "provider must be github or codeberg"
  end

  M.open(opts)

  -- "me" is the signed-in account, as in forge search queries.
  if username:lower() == "me" then
    provider = provider or "github"

    require("oculus.auth").viewer(provider, M.state.opts, function(viewer, err)
      if not viewer then
        vim.notify("Oculus: " .. tostring(err), vim.log.levels.ERROR)
      elseif is_valid_win(M.state.win) then
        M.open_user(provider .. ":" .. viewer.login, M.state.opts)
      end
    end)

    return true
  end

  local contributor = nil

  for _, candidate in ipairs(M.state.contributors or M.state.opts.contributors or {}) do
    if
      type(candidate.username) == "string"
      and candidate.username:lower() == username:lower()
      and (not provider or (candidate.provider or "github") == provider)
    then
      contributor = candidate
      break
    end
  end

  contributor = contributor or {
    username = username,
    provider = provider or "github",
  }

  M.state.selected_username = contributor.username
  load_activity(contributor)
  return true
end

-- Open the Oculus window on your work: review requests, your pull requests,
-- and issues and pull requests assigned to you or mentioning you.
function M.open_work(opts)
  M.open(opts)
  work_view.open()
  return true
end

M.create_project_directory = create_project_directory
M.remove_project_directory = remove_project_directory
M.move_project_to_directory = move_project_to_directory
M.toggle_project_directory = toggle_project_directory
M.open_project_directory = render_directory
M._render_directory = render_directory
M.prompt_create_directory = prompt_create_directory
M.prompt_move_project_to_directory = prompt_move_project_to_directory
M._create_project_directory = create_project_directory
M._remove_project_directory = remove_project_directory
M._move_project_to_directory = move_project_to_directory
M.move_to_parent_directory = move_to_parent_directory
M._move_to_parent_directory = move_to_parent_directory
M._startup_project_items = startup_project_items
M._directory_preview_items = directory_preview_items
M.refresh_project_descriptions = preview.refresh_project_descriptions

function M.toggle_workspace_filter()
  M.state.workspace_filter_enabled = not (M.state.workspace_filter_enabled ~= false)

  if is_valid_win(M.state.win) then
    if M.state.opts and M.state.opts.tracking_file then
      M.refresh_tracking()
    else
      render_contributors()
    end
  end

  return M.state.workspace_filter_enabled
end

M.prompt_select_workspace = prompt_select_workspace
return M
