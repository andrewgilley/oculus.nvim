-- The inspect overview: the floating summary of the item being inspected, its
-- footer commands, and the agent flows it launches — describing a change,
-- asking for patch locations, and opening a worktree for the fix. The window
-- itself is opened by the inspect module, which hands this one the helpers it
-- needs through setup().
local github = require("oculus.github")
local browser = require("oculus.browser")
local git = require("oculus.inspect.git")
local patch = require("oculus.inspect.patch")
local target = require("oculus.inspect.target")
local M = {}

function M.setup(inspect, internal)
  local function overview_window_config(config, _)
    config = vim.deepcopy(config or {})

    if config.exact_dimensions then
      config.footer = nil
      config.footer_pos = nil
      config.zindex = 70
      return config
    end

    if type(config.width) == "number" then
      local width = math.max(1, config.width - 12)

      config.col = (tonumber(config.col) or 0)
        + math.floor((config.width - width) / 2)

      config.width = width
    end

    if type(config.height) == "number" then
      local height = math.max(1, config.height - 3)

      config.row = (tonumber(config.row) or 0)
        + math.ceil((config.height - height) / 2)

      config.height = height
    end

    config.footer = nil
    config.footer_pos = nil
    config.zindex = 70
    return config
  end

  inspect._overview_ui = {
    footer_ns = vim.api.nvim_create_namespace("oculus_inspect_overview_footer"),
    agent_spinner_ns = vim.api.nvim_create_namespace(
      "oculus_inspect_overview_agent_spinner"
    ),
    agent_spinner_frames = {
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
    },
    section_labels = {
      Title = true,
      Description = true,
      Author = true,
      Commits = true,
      ["PR number"] = true,
      ["Issue number"] = true,
      Status = true,
      Reviews = true,
      Checks = true,
      Merge = true,
      ["Review threads"] = true,
      Date = true,
      Source = true,
      ["Agent description"] = true,
      ["Agent explanation"] = true,
      ["Agent suggestion"] = true,
    },
  }

  function inspect._overview_ui.persistence_key(group)
    local overview = group and group.overview or {}
    local details = overview.commit_details or {}

    local repository = overview.owner and overview.repo
        and (overview.owner .. "/" .. overview.repo)
      or overview.url
      or require("oculus.agent").repository(group)

    local identifier = overview.number
      or details.sha
      or overview.sha
      or overview.url

    if type(repository) ~= "string"
      or repository == ""
      or identifier == nil
    then
      return
    end

    return table.concat({
      tostring(overview.forge or "github"):lower(),
      repository:lower(),
      tostring(overview.kind or "activity"):lower(),
      tostring(identifier):lower(),
    }, ":")
  end

  function inspect._overview_ui.restore_persisted(group)
    local key = inspect._overview_ui.persistence_key(group)
    local cache = group and group.inspect_overviews or nil
    local saved = key and type(cache) == "table" and cache[key] or nil

    if type(saved) ~= "table" then
      return false
    end

    if type(saved.explanation) == "string" and saved.explanation ~= "" then
      group.overview_agent_explanation = saved.explanation
      group.overview_agent_explanation_model = saved.explanation_model

      group.overview_agent_explanation_telemetry = vim.deepcopy(
        saved.explanation_telemetry
      )
    end

    if type(saved.locations) == "table" then
      group.overview_agent_locations = {}

      for _, location in ipairs(saved.locations) do
        if #group.overview_agent_locations == 3 then
          break
        end

        if type(location) == "table"
          and type(location.path) == "string"
          and location.path ~= ""
        then
          group.overview_agent_locations[#group.overview_agent_locations + 1] = {
            path = location.path,
            line = tonumber(location.line),
            reason = location.reason,
          }
        end
      end

      group.overview_agent_patch_model = saved.patch_model

      group.overview_agent_patch_telemetry = vim.deepcopy(
        saved.patch_telemetry
      )

      group.overview_agent_selected_location_index =
        #group.overview_agent_locations > 0
          and math.min(
            math.max(tonumber(saved.selected_location) or 1, 1),
            #group.overview_agent_locations
          )
        or nil

      group.overview_agent_selected_locations = {}

      for _, index in ipairs(saved.selected_locations or {}) do
        index = tonumber(index)

        if index and group.overview_agent_locations[index] then
          group.overview_agent_selected_locations[index] = true
        end
      end
    end

    if group.overview_agent_locations ~= nil then
      group.overview_agent_request_kind = "patch_locations"
      group.overview_agent_mode = "patch_locations"
    elseif group.overview_agent_explanation then
      group.overview_agent_request_kind = "explanation"
      group.overview_agent_mode = "explanation"
    end

    return group.overview_agent_mode ~= nil
  end

  function inspect._overview_ui.persist(group)
    if not group or group.persist_inspect_overviews == false then
      return false
    end

    local key = inspect._overview_ui.persistence_key(group)

    if not key or type(group.state_file) ~= "string"
      or group.state_file == ""
    then
      return false
    end

    local cache = group.inspect_overviews

    if type(cache) ~= "table" then
      cache = {}
      group.inspect_overviews = cache
    end

    local selected = {}

    for index, enabled in pairs(
      group.overview_agent_selected_locations or {}
    ) do
      if enabled then
        selected[#selected + 1] = index
      end
    end

    table.sort(selected)

    cache[key] = {
      explanation = group.overview_agent_explanation,
      explanation_model = group.overview_agent_explanation_model,
      explanation_telemetry = vim.deepcopy(
        group.overview_agent_explanation_telemetry
      ),
      locations = vim.deepcopy(group.overview_agent_locations),
      patch_model = group.overview_agent_patch_model,
      patch_telemetry = vim.deepcopy(group.overview_agent_patch_telemetry),
      selected_location = group.overview_agent_selected_location_index,
      selected_locations = selected,
      updated_at = os.time(),
    }

    local config = group.persistence_config or {}
    config.inspect_overviews = cache

    local ok, err = require("oculus.storage").save(
      group.state_file,
      config
    )

    if not ok then
      vim.notify(
        "Oculus could not save inspect overview data: " .. tostring(err),
        vim.log.levels.ERROR
      )

      return false
    end

    return true
  end

  function inspect._overview_ui.float_lines(overview, width)
    local lines = internal.sidebar_overview_lines(overview, width)

    if lines[1] == "OVERVIEW" then
      table.remove(lines, 1)

      if lines[1] == "" then
        table.remove(lines, 1)
      end
    end

    return lines
  end

  function inspect._overview_ui.close_footer(group)
    if inspect._overview_ui.stop_close_spinner then
      inspect._overview_ui.stop_close_spinner(group)
    end

    local win = group.overview_footer_win
    local buf = group.overview_footer_buf
    group.overview_footer_win = nil
    group.overview_footer_buf = nil

    if win and vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_close(win, true)
    end

    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_delete(buf, { force = true })
    end
  end

  function inspect._overview_ui.render_footer(group)
    local overview_win = group.overview_win

    if not overview_win or not vim.api.nvim_win_is_valid(overview_win) then
      return
    end

    local overview_config = vim.api.nvim_win_get_config(overview_win)
    local width = vim.api.nvim_win_get_width(overview_win)
    local height = vim.api.nvim_win_get_height(overview_win)

    local config = {
      relative = "editor",
      width = width,
      height = 2,
      row = (tonumber(overview_config.row) or 0) + height - 1,
      col = (tonumber(overview_config.col) or 0) + 1,
      style = "minimal",
      focusable = false,
      zindex = (tonumber(overview_config.zindex) or 70) + 1,
    }

    local buf = group.overview_footer_buf

    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      buf = vim.api.nvim_create_buf(false, true)
      group.overview_footer_buf = buf
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].swapfile = false

      internal.without_reliquary(function()
        vim.bo[buf].filetype = "oculus-inspect-overview-footer"
      end)

      vim.b[buf].oculus_inspect_overview_footer = true
    end

    local issue_patches = require("oculus.agent").needs_patch_locations(group)

    local exit_spinner = group.overview_close_spinner_frame
        and inspect._overview_ui.agent_spinner_frames[
          group.overview_close_spinner_frame
        ]
      or nil

    local exit_command_label = exit_spinner
        and ("exit " .. exit_spinner)
      or "exit"

    local view_command_key = (group.chunk_view_mode == "sidebar")
        and "v"
      or "s"

    local view_command_label = (group.chunk_view_mode == "sidebar")
        and "virtual"
      or "sidebar"

    local left_commands = "  b browser   d describe"

    if issue_patches then
      left_commands = left_commands .. "   p path   w worktree"
    end

    if inspect._review.thread_count(group) > 0 then
      left_commands = left_commands
        .. (group.review_inline and "   r hide threads" or "   r threads")
    end

    left_commands = left_commands
      .. "   "
      .. view_command_key
      .. " "
      .. view_command_label
      .. "   e "
      .. exit_command_label

    local right_commands = ""

    if #(group.overview_agent_locations or {}) > 0
      and group.overview_agent_mode == "patch_locations"
    then
      right_commands = "<Space> toggle   <CR> open paths   "
    end

    right_commands = right_commands .. "c close"
    local left_display_width = vim.fn.strdisplaywidth(left_commands)
    local right_display_width = vim.fn.strdisplaywidth(right_commands)

    local padding = math.max(
      3,
      width
        - 2
        - left_display_width
        - right_display_width
    )

    local commands = left_commands .. string.rep(" ", padding) .. right_commands
    local exit_spinner_col

    if exit_spinner then
      local spinner_start = commands:find(exit_spinner, 1, true)
      exit_spinner_col = spinner_start and (spinner_start - 1) or nil
    end

    local footer_lines = {
      "  " .. string.rep("─", math.max(1, width - 4)),
      commands,
    }

    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, footer_lines)
    vim.bo[buf].modifiable = false

    vim.api.nvim_buf_clear_namespace(
      buf,
      inspect._overview_ui.footer_ns,
      0,
      -1
    )

    vim.api.nvim_buf_set_extmark(
      buf,
      inspect._overview_ui.footer_ns,
      0,
      2,
      {
        end_col = #footer_lines[1],
        hl_group = "Comment",
        priority = 100,
      }
    )

    vim.api.nvim_buf_set_extmark(
      buf,
      inspect._overview_ui.footer_ns,
      1,
      2,
      {
        end_col = #footer_lines[2],
        hl_group = "OculusNormal",
        priority = 100,
      }
    )

    if exit_spinner_col then
      vim.api.nvim_buf_set_extmark(
        buf,
        inspect._overview_ui.footer_ns,
        1,
        exit_spinner_col,
        {
          end_col = exit_spinner_col + #exit_spinner,
          hl_group = "DiagnosticInfo",
          priority = 110,
        }
      )
    end

    local footer_win = group.overview_footer_win

    if footer_win and vim.api.nvim_win_is_valid(footer_win) then
      vim.api.nvim_win_set_config(footer_win, config)
    else
      footer_win = internal.without_reliquary(function()
        return vim.api.nvim_open_win(buf, false, config)
      end)

      group.overview_footer_win = footer_win
    end

    vim.wo[footer_win].wrap = false
    vim.wo[footer_win].cursorline = false
    vim.wo[footer_win].number = false
    vim.wo[footer_win].relativenumber = false
    vim.wo[footer_win].signcolumn = "no"

    vim.wo[footer_win].winhighlight = table.concat({
      "Normal:OculusNormal",
      "NormalFloat:OculusNormal",
    }, ",")

    require("oculus.window").apply_overview_highlights(
      footer_win,
      group.overview_highlight_source_win
    )
  end

  function inspect._overview_ui.stop_close_spinner(group)
    local timer = group.overview_close_spinner_timer
    group.overview_close_spinner_timer = nil
    group.overview_close_spinner_frame = nil

    if timer then
      pcall(timer.stop, timer)

      if not timer:is_closing() then
        timer:close()
      end
    end
  end

  function inspect._overview_ui.start_close_spinner(group)
    if not internal.overview_window_is_open(group) then
      return
    end

    inspect._overview_ui.stop_close_spinner(group)
    group.overview_close_spinner_frame = 1
    inspect._overview_ui.render_footer(group)
    local timer = vim.uv.new_timer()

    if not timer then
      return
    end

    group.overview_close_spinner_timer = timer

    timer:start(80, 80, vim.schedule_wrap(function()
      if group.overview_close_spinner_timer ~= timer
        or not internal.overview_window_is_open(group)
      then
        return
      end

      group.overview_close_spinner_frame = (
        group.overview_close_spinner_frame
          % #inspect._overview_ui.agent_spinner_frames
      ) + 1

      inspect._overview_ui.render_footer(group)
    end))
  end

  function inspect._overview_ui.content_height(group)
    local win = group.overview_win

    if not win or not vim.api.nvim_win_is_valid(win) then
      return 1
    end

    local height = vim.api.nvim_win_get_height(win)
    local footer = group.overview_footer_win

    if footer and vim.api.nvim_win_is_valid(footer) then
      height = height - vim.api.nvim_win_get_height(footer)
    end

    return math.max(1, height)
  end

  function inspect._overview_ui.clamp_scroll(group)
    local win = group.overview_win
    local buf = group.overview_buf

    if not win
      or not buf
      or not vim.api.nvim_win_is_valid(win)
      or not vim.api.nvim_buf_is_valid(buf)
    then
      return false
    end

    local line_count = vim.api.nvim_buf_line_count(buf)
    local height = inspect._overview_ui.content_height(group)
    local max_topline = math.max(1, line_count - height + 2)
    local changed = false

    vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      local topline = math.max(1, math.min(max_topline, view.topline))
      local cursor = vim.api.nvim_win_get_cursor(win)
      local cursor_line = math.max(1, math.min(line_count, cursor[1]))

      if topline == view.topline
        and (view.topfill or 0) == 0
        and cursor_line == cursor[1]
      then
        return
      end

      view.topline = topline
      view.topfill = 0
      vim.fn.winrestview(view)

      if cursor_line ~= cursor[1] then
        vim.api.nvim_win_set_cursor(win, { cursor_line, cursor[2] })
      end

      changed = true
    end)

    return changed
  end

  function inspect._overview_ui.schedule_highlight_refresh(group)
    vim.schedule(function()
      if not internal.overview_window_is_open(group) then
        return
      end

      require("oculus.window").apply_overview_highlights(
        group.overview_win,
        group.overview_highlight_source_win
      )
    end)
  end

  function inspect._overview_ui.render(group)
    local buf = group.overview_buf

    if not buf or not vim.api.nvim_buf_is_valid(buf) then
      return
    end

    local lines = inspect._overview_ui.float_lines(
      group.overview,
      group.overview_content_width or 28
    )

    group.overview_agent_model_lines = nil
    group.overview_agent_heading_line = nil
    group.overview_agent_location_lines = nil
    group.overview_agent_location_heading_line = nil

    local function append_active_state(kind)
      if group.overview_agent_request_kind ~= kind then
        return false
      end

      if group.overview_agent_mode == "models" then
        local targets = {}

        for _, model in ipairs(group.overview_agent_models or {}) do
          lines[#lines + 1] = ("  %s  %s"):format(
            model.display_name,
            model.id
          )

          targets[#lines] = model
        end

        group.overview_agent_model_lines = targets
      elseif group.overview_agent_mode == "error" then
        internal.append_sidebar_text(
          lines,
          group.overview_agent_error or "Agent request failed.",
          group.overview_content_width or 28,
          "  "
        )
      end

      return group.overview_agent_mode == "models"
        or group.overview_agent_mode == "error"
        or group.overview_agent_mode == "generating"
        or group.overview_agent_mode == "loading_models"
    end

    local function append_explanation()
      local active = group.overview_agent_request_kind == "explanation"
        and group.overview_agent_mode ~= nil

      if not active and not group.overview_agent_explanation then
        return
      end

      lines[#lines + 1] = ""
      local heading = "  Agent description"

      if group.overview_agent_explanation_model
      then
        heading = heading
          .. " ("
          .. tostring(group.overview_agent_explanation_model)
          .. ")"
      end

      lines[#lines + 1] = heading

      if active then
        group.overview_agent_heading_line = #lines
      end

      if not append_active_state("explanation")
        and group.overview_agent_explanation
      then
        internal.append_sidebar_text(
          lines,
          group.overview_agent_explanation,
          group.overview_content_width or 28,
          "  "
        )
      end
    end

    local function append_patch_locations()
      local active = group.overview_agent_request_kind == "patch_locations"
        and group.overview_agent_mode ~= nil

      if not active and group.overview_agent_locations == nil then
        return
      end

      lines[#lines + 1] = ""
      local heading = "  Agent suggestion"

      if group.overview_agent_patch_model then
        heading = heading
          .. " ("
          .. tostring(group.overview_agent_patch_model)
          .. ")"
      end

      lines[#lines + 1] = heading
      group.overview_agent_location_heading_line = #lines

      if active then
        group.overview_agent_heading_line = #lines
      end

      if append_active_state("patch_locations") then
        return
      end

      local locations = group.overview_agent_locations or {}

      if #locations == 0 then
        lines[#lines + 1] = "  No likely locations identified."
        return
      end

      group.overview_agent_location_lines = {}

      group.overview_agent_selected_location_index = math.min(
        math.max(group.overview_agent_selected_location_index or 1, 1),
        #locations
      )

      for index, location in ipairs(locations) do
        local location_line = #lines + 1
        local display_path = location.path

        if location.line then
          display_path = display_path .. ":" .. tostring(location.line)
        end

        local selected_locations =
          group.overview_agent_selected_locations or {}

        local marker = selected_locations[index] and "[x]" or "[ ]"

        internal.append_sidebar_text(
          lines,
          ("%s %d. %s"):format(marker, index, display_path),
          group.overview_content_width or 28,
          "  "
        )

        group.overview_agent_location_lines[location_line] = {
          index = index,
          location = location,
        }

        if location.reason then
          internal.append_sidebar_text(
            lines,
            location.reason,
            group.overview_content_width or 28,
            "     "
          )
        end

        if index < #locations then
          lines[#lines + 1] = ""
        end
      end
    end

    append_explanation()
    append_patch_locations()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, internal.sidebar_ns, 0, -1)

    vim.api.nvim_buf_clear_namespace(
      buf,
      inspect._overview_ui.footer_ns,
      0,
      -1
    )

    vim.api.nvim_buf_clear_namespace(
      buf,
      inspect._overview_ui.agent_spinner_ns,
      0,
      -1
    )

    for index, line in ipairs(lines) do
      local label = line:match("^  (.-)%s*$")

      if inspect._overview_ui.section_labels[label]
        or (label and label:match("^Agent description"))
        or (label and label:match("^Agent explanation"))
        or (label and label:match("^Agent suggestion"))
      then
        vim.api.nvim_buf_set_extmark(buf, internal.sidebar_ns, index - 1, 2, {
          end_col = #line,
          hl_group = "OculusInspectOverviewSection",
          priority = 100,
        })
      end
    end

    local selected = group.overview_agent_selected_line

    if group.overview_agent_mode == "models"
      and selected
      and group.overview_agent_model_lines
      and group.overview_agent_model_lines[selected]
    then
      vim.api.nvim_buf_set_extmark(buf, internal.sidebar_ns, selected - 1, 2, {
        end_col = #(lines[selected] or ""),
        hl_group = "OculusInspectAgentModelSelected",
        hl_mode = "combine",
        priority = 90,
      })
    end

    if group.overview_agent_selected_location_index
      and group.overview_agent_mode == "patch_locations"
    then
      for line, target in pairs(
        group.overview_agent_location_lines or {}
      ) do
        if target.index == group.overview_agent_selected_location_index then
          vim.api.nvim_buf_set_extmark(buf, internal.sidebar_ns, line - 1, 2, {
            end_col = #(lines[line] or ""),
            hl_group = "OculusInspectAgentModelSelected",
            hl_mode = "combine",
            priority = 90,
          })

          break
        end
      end
    end

    if group.overview_agent_mode == "generating"
      or group.overview_agent_mode == "loading_models"
    then
      inspect._overview_ui.draw_agent_spinner(group)
    end

    if internal.overview_window_is_open(group)
      and vim.api.nvim_get_current_win() == group.overview_win
    then
      internal.hide_overview_cursor(group)
    end

    if internal.overview_window_is_open(group) then
      inspect._overview_ui.render_footer(group)
    end

    return lines
  end

  function inspect._overview_ui.draw_agent_spinner(group)
    local buf = group.overview_buf
    local line = group.overview_agent_heading_line

    if (group.overview_agent_mode ~= "generating"
        and group.overview_agent_mode ~= "loading_models")
      or not buf
      or not line
      or not vim.api.nvim_buf_is_valid(buf)
    then
      return
    end

    vim.api.nvim_buf_clear_namespace(
      buf,
      inspect._overview_ui.agent_spinner_ns,
      0,
      -1
    )

    local frames = inspect._overview_ui.agent_spinner_frames
    local frame = frames[group.overview_agent_spinner_frame or 1]

    vim.api.nvim_buf_set_extmark(
      buf,
      inspect._overview_ui.agent_spinner_ns,
      line - 1,
      0,
      {
        virt_text = { { " " .. frame, "DiagnosticInfo" } },
        virt_text_pos = "eol",
        hl_mode = "combine",
      }
    )
  end

  function inspect._overview_ui.stop_agent_spinner(group)
    local timer = group.overview_agent_spinner_timer
    group.overview_agent_spinner_timer = nil
    group.overview_agent_spinner_frame = nil

    if timer then
      pcall(timer.stop, timer)

      if not timer:is_closing() then
        timer:close()
      end
    end

    local buf = group.overview_buf

    if buf and vim.api.nvim_buf_is_valid(buf) then
      vim.api.nvim_buf_clear_namespace(
        buf,
        inspect._overview_ui.agent_spinner_ns,
        0,
        -1
      )
    end
  end

  function inspect._overview_ui.start_agent_spinner(group)
    inspect._overview_ui.stop_agent_spinner(group)
    group.overview_agent_spinner_frame = 1
    inspect._overview_ui.draw_agent_spinner(group)
    local timer = vim.uv.new_timer()

    if not timer then
      return
    end

    group.overview_agent_spinner_timer = timer

    timer:start(80, 80, vim.schedule_wrap(function()
      if group.overview_agent_spinner_timer ~= timer
        or (group.overview_agent_mode ~= "generating"
          and group.overview_agent_mode ~= "loading_models")
      then
        return
      end

      group.overview_agent_spinner_frame =
        (group.overview_agent_spinner_frame
          % #inspect._overview_ui.agent_spinner_frames) + 1

      inspect._overview_ui.draw_agent_spinner(group)
    end))
  end

  function inspect._overview_ui.scroll_to_bottom(group)
    local win = group.overview_win
    local buf = group.overview_buf

    if not win
      or not buf
      or not vim.api.nvim_win_is_valid(win)
      or not vim.api.nvim_buf_is_valid(buf)
    then
      return
    end

    local line_count = vim.api.nvim_buf_line_count(buf)
    local height = inspect._overview_ui.content_height(group)
    local topline = math.max(1, line_count - height + 2)
    vim.api.nvim_win_set_cursor(win, { line_count, 0 })

    vim.api.nvim_win_call(win, function()
      local view = vim.fn.winsaveview()
      view.topline = topline
      vim.fn.winrestview(view)
    end)
  end

  function inspect._overview_ui.close_agent_window(group, return_to_overview)
    inspect._overview_ui.stop_agent_spinner(group)
    group.overview_agent_model_lines = nil

    if return_to_overview and internal.overview_window_is_open(group) then
      vim.api.nvim_set_current_win(group.overview_win)
    end
  end

  function inspect._overview_ui.restore_model_selection(group)
    if group.overview_agent_mode ~= "models" then
      return false
    end

    local function restore(targets, selected_line)
      if targets and selected_line and targets[selected_line] then
        return selected_line
      end

      local first

      for line in pairs(targets or {}) do
        if not first or line < first then
          first = line
        end
      end

      return first
    end

    local changed = false

    if group.overview_agent_mode == "models" then
      local selected = restore(
        group.overview_agent_model_lines,
        group.overview_agent_selected_line
      )

      if selected ~= group.overview_agent_selected_line then
        group.overview_agent_selected_line = selected
        changed = true
      end
    end

    return changed
  end

  function inspect._overview_ui.render_models(group, models, err)
    if group.overview_agent_mode ~= "loading_models" then
      return
    end

    inspect._overview_ui.stop_agent_spinner(group)
    group.overview_agent_model_process = nil

    if err then
      group.overview_agent_mode = "error"

      group.overview_agent_error = "Could not load models: "
        .. tostring(err)

      inspect._overview_ui.render(group)
      inspect._overview_ui.scroll_to_bottom(group)
      return
    end

    group.overview_agent_mode = "models"
    group.overview_agent_models = models or {}
    inspect._overview_ui.render(group)
    local model_lines = {}

    for line in pairs(group.overview_agent_model_lines or {}) do
      model_lines[#model_lines + 1] = line
    end

    table.sort(model_lines)
    group.overview_agent_selected_line = model_lines[1]
    inspect._overview_ui.render(group)
    inspect._overview_ui.scroll_to_bottom(group)

    if group.overview_agent_selected_line
      and internal.overview_window_is_open(group)
    then
      vim.api.nvim_win_set_cursor(group.overview_win, {
        group.overview_agent_selected_line,
        0,
      })
    end
  end

  function inspect._overview_ui.select_agent_model(group)
    local model = group.overview_agent_model_lines
      and group.overview_agent_model_lines[group.overview_agent_selected_line]

    if model then
      if group.overview_agent_request_kind == "patch_locations" then
        inspect._overview_ui.open_patch_locations(group, model)
      else
        inspect._overview_ui.open_explanation(group, model)
      end
    end
  end

  function inspect._overview_ui.move_model_cursor(group, direction)
    local targets = group.overview_agent_model_lines or {}

    if group.overview_agent_mode ~= "models" then
      return
    end

    local lines = {}

    for line in pairs(targets) do
      lines[#lines + 1] = line
    end

    table.sort(lines)

    if #lines == 0 then
      return
    end

    local current = group.overview_agent_selected_line or lines[1]
    local current_index = 1

    for index, line in ipairs(lines) do
      if line >= current then
        current_index = index
        break
      end
    end

    local next_index = ((current_index + direction - 1) % #lines) + 1
    group.overview_agent_selected_line = lines[next_index]
    inspect._overview_ui.render(group)

    if internal.overview_window_is_open(group) then
      vim.api.nvim_win_set_cursor(group.overview_win, {
        group.overview_agent_selected_line,
        0,
      })
    end
  end

  function inspect._overview_ui.selected_patch_location(group)
    local selected = group.overview_agent_selected_location_index

    for line, target in pairs(
      group.overview_agent_location_lines or {}
    ) do
      if target.index == selected then
        return target.location, line
      end
    end
  end

  function inspect._overview_ui.focus_patch_locations(group)
    if group.overview_agent_mode == "patch_locations"
      or #(group.overview_agent_locations or {}) == 0
    then
      return false
    end

    group.overview_agent_request_kind = "patch_locations"
    group.overview_agent_mode = "patch_locations"

    group.overview_agent_selected_location_index = math.min(
      math.max(group.overview_agent_selected_location_index or 1, 1),
      #group.overview_agent_locations
    )

    inspect._overview_ui.render(group)
    local _, line = inspect._overview_ui.selected_patch_location(group)

    if line and internal.overview_window_is_open(group) then
      vim.api.nvim_set_current_win(group.overview_win)
      vim.api.nvim_win_set_cursor(group.overview_win, { line, 0 })
    end

    return true
  end

  function inspect._overview_ui.unfocus_patch_locations(group)
    if group.overview_agent_mode ~= "patch_locations"
      or group.overview_agent_request_kind ~= "patch_locations"
    then
      return false
    end

    group.overview_agent_mode = nil
    inspect._overview_ui.render(group)

    if internal.overview_window_is_open(group) then
      vim.api.nvim_set_current_win(group.overview_win)
      internal.hide_overview_cursor(group)
    end

    return true
  end

  function inspect._overview_ui.toggle_patch_locations_focus(group)
    if #(group.overview_agent_locations or {}) == 0 then
      return false
    end

    if group.overview_agent_mode == "patch_locations"
      and group.overview_agent_request_kind == "patch_locations"
    then
      inspect._overview_ui.unfocus_patch_locations(group)
    else
      inspect._overview_ui.focus_patch_locations(group)
    end

    return true
  end

  function inspect._overview_ui.move_location_cursor(group, direction)
    local locations = group.overview_agent_locations or {}

    if group.overview_agent_mode ~= "patch_locations"
      or group.overview_agent_request_kind ~= "patch_locations"
      or #locations == 0
    then
      return false
    end

    local current = group.overview_agent_selected_location_index or 1

    group.overview_agent_selected_location_index =
      ((current + direction - 1) % #locations) + 1

    inspect._overview_ui.render(group)
    local _, line = inspect._overview_ui.selected_patch_location(group)

    if line and internal.overview_window_is_open(group) then
      vim.api.nvim_win_set_cursor(group.overview_win, { line, 0 })
    end

    return true
  end

  function inspect._overview_ui.toggle_patch_location(group)
    local locations = group.overview_agent_locations or {}

    if group.overview_agent_mode ~= "patch_locations"
      or group.overview_agent_request_kind ~= "patch_locations"
    then
      return false
    end

    local index = group.overview_agent_selected_location_index

    if not index or not locations[index] then
      return false
    end

    group.overview_agent_selected_locations =
      group.overview_agent_selected_locations or {}

    group.overview_agent_selected_locations[index] =
      not group.overview_agent_selected_locations[index]
        and true
      or nil

    require("oculus.telemetry").record(
      "oculus.inspect.patch_location.toggle",
      {
        ["gen_ai.workflow.name"] = "oculus.inspect.patch_locations",
        ["oculus.patch_location.index"] = index,
        ["oculus.patch_location.selected"] =
          group.overview_agent_selected_locations[index] == true,
      },
      group.overview_agent_patch_telemetry
    )

    inspect._overview_ui.persist(group)
    inspect._overview_ui.render(group)
    local _, line = inspect._overview_ui.selected_patch_location(group)

    if line and internal.overview_window_is_open(group) then
      vim.api.nvim_win_set_cursor(group.overview_win, { line, 0 })
    end

    return true
  end

  function inspect._overview_ui.patch_location_path(group, location)
    local repository = require("oculus.agent").repository(group)

    if type(repository) ~= "string" or repository == "" then
      return nil, nil, "local repository information is unavailable"
    end

    local path = type(location) == "table" and location.path or nil

    if type(path) ~= "string" or vim.trim(path) == "" then
      return nil, nil, "this patch location has no path"
    end

    repository = vim.fs.normalize(repository)
    path = vim.trim(path):gsub("\\", "/"):gsub("^/+", "")
    local folder = vim.fs.basename(repository)

    if path:lower() == folder:lower() then
      path = ""
    elseif path:sub(1, #folder + 1):lower()
        == (folder .. "/"):lower()
    then
      path = path:sub(#folder + 2)
    end

    local absolute = vim.fs.normalize(vim.fs.joinpath(repository, path))
    local relative = internal.relative_path(repository, absolute)

    if not relative or relative == "" then
      return nil, nil, "the selected path is outside the repository"
    end

    return absolute, relative
  end

  function inspect._overview_ui.open_patch_location(group)
    if group.overview_agent_mode ~= "patch_locations"
      or group.overview_agent_request_kind ~= "patch_locations"
    then
      return false
    end

    local locations = group.overview_agent_locations or {}
    local selected = group.overview_agent_selected_locations or {}
    local targets = {}

    for index, location in ipairs(locations) do
      if selected[index] then
        targets[#targets + 1] = location
      end
    end

    if #targets == 0 then
      return false
    end

    local code_options = group.overview_code_window_options or {}
    local repository = require("oculus.agent").repository(group)
    local opened = {}

    for _, location in ipairs(targets) do
      local absolute, relative, path_err =
        inspect._overview_ui.patch_location_path(group, location)

      local stat = absolute and vim.uv.fs_stat(absolute) or nil

      if not absolute then
        vim.notify("Oculus: " .. tostring(path_err), vim.log.levels.WARN)
      elseif stat and stat.type == "directory" then
        vim.notify(
          "Oculus: the selected patch location is a directory",
          vim.log.levels.WARN
        )
      else
        local ok, open_err = pcall(
          vim.cmd,
          "tabedit " .. vim.fn.fnameescape(absolute)
        )

        if not ok then
          vim.notify(
            "Oculus: could not open patch location: " .. tostring(open_err),
            vim.log.levels.ERROR
          )
        else
          vim.cmd("tcd " .. vim.fn.fnameescape(repository))
          vim.bo.modifiable = true
          vim.bo.readonly = false
          local patch_win = vim.api.nvim_get_current_win()
          local patch_buf = vim.api.nvim_get_current_buf()

          for option, value in pairs(code_options) do
            if option ~= "highlight_namespace" then
              pcall(function()
                vim.wo[patch_win][option] = value
              end)
            end
          end

          vim.wo[patch_win].cursorline = true
          vim.wo[patch_win].cursorlineopt = "line"
          vim.wo[patch_win].statusline = ""
          vim.wo[patch_win].winfixbuf = false

          if require("oculus.window").is_oculus_highlight_namespace(
            vim.api.nvim_get_hl_ns({ winid = patch_win })
          ) then
            vim.api.nvim_win_set_hl_ns(
              patch_win,
              code_options.highlight_namespace or 0
            )
          end

          inspect._use_native_cursorline_highlighting(patch_win)
          local line_count = vim.api.nvim_buf_line_count(patch_buf)

          local target_line = math.max(
            1,
            math.min(tonumber(location.line) or 1, line_count)
          )

          local target_text = vim.api.nvim_buf_get_lines(
            patch_buf,
            target_line - 1,
            target_line,
            false
          )[1] or ""

          local target_column = #(target_text:match("^%s*") or "")

          vim.api.nvim_win_set_cursor(
            patch_win,
            { target_line, target_column }
          )

          if target_line > 10 then
            vim.api.nvim_win_call(patch_win, function()
              local keys = vim.api.nvim_replace_termcodes(
                "zt10<C-y>",
                true,
                false,
                true
              )

              vim.cmd("normal! " .. keys)
            end)
          end

          opened[#opened + 1] = {
            tab = vim.api.nvim_get_current_tabpage(),
            win = patch_win,
            buf = patch_buf,
            path = relative:gsub("\\", "/"),
            line = target_line,
            location = location,
          }
        end
      end
    end

    if #opened == 0 then
      require("oculus.telemetry").record(
        "oculus.inspect.patch_locations.open",
        {
          ["gen_ai.workflow.name"] = "oculus.inspect.patch_locations",
          ["oculus.patch_locations.requested"] = #targets,
          ["oculus.patch_locations.opened"] = 0,
        },
        group.overview_agent_patch_telemetry,
        "no_location_opened"
      )

      return false
    end

    require("oculus.telemetry").record(
      "oculus.inspect.patch_locations.open",
      {
        ["gen_ai.workflow.name"] = "oculus.inspect.patch_locations",
        ["oculus.patch_locations.requested"] = #targets,
        ["oculus.patch_locations.opened"] = #opened,
      },
      group.overview_agent_patch_telemetry,
      #opened < #targets and "partial_open" or nil
    )

    group.overview_patch_tabs = group.overview_patch_tabs or {}

    for _, patch in ipairs(opened) do
      group.overview_patch_tabs[#group.overview_patch_tabs + 1] = patch
    end

    group.overview_agent_mode = nil
    group.overview_return = nil
    internal.close_overview_window(group)
    local patch_group = inspect._overview_ui.prepare_patch_sidebar(group, opened)
    group.overview_patch_group = patch_group
    local first = opened[1]

    if vim.api.nvim_tabpage_is_valid(first.tab)
      and vim.api.nvim_win_is_valid(first.win)
    then
      vim.api.nvim_set_current_tabpage(first.tab)
      vim.api.nvim_set_current_win(first.win)
    end

    return true
  end

  function inspect._overview_ui.open_worktree_workflow(group, opts)
    opts = opts or {}
    local repository = require("oculus.agent").repository(group)

    if type(repository) ~= "string" or repository == "" then
      vim.notify(
        "Oculus: no repository available for worktree creation",
        vim.log.levels.WARN
      )

      return false
    end

    local default_branch = ""
    local overview = group.overview or {}

    local issue_num = overview.issue_number
      or (group.issue and group.issue.number)
      or (vim.t.oculus_inspect and vim.t.oculus_inspect.issue_number)

    if issue_num then
      default_branch = "fix-issue-" .. issue_num
    end

    local function proceed_with_branch(branch_name)
      if not branch_name or vim.trim(branch_name) == "" then
        return
      end

      branch_name = vim.trim(branch_name)
      local branch_slug = branch_name:gsub("[^%w%-_.]+", "-")

      local worktree_dir = vim.fs.joinpath(
        vim.fs.dirname(repository),
        vim.fs.basename(repository) .. "-" .. branch_slug
      )

      local function setup_worktree_files()
        local locations = group.overview_agent_locations or {}
        local selected = group.overview_agent_selected_locations or {}
        local targets = {}

        for index, location in ipairs(locations) do
          if selected[index] then
            targets[#targets + 1] = location
          end
        end

        if #targets == 0 and #locations > 0 then
          targets = locations
        end

        if #targets > 0 then
          local code_options = group.overview_code_window_options or {}
          local opened = {}

          for _, location in ipairs(targets) do
            local _, relative =
              inspect._overview_ui.patch_location_path(group, location)

            if not relative or relative == "" then
              relative = location.path or location.filename or location.file
            end

            if relative then
              local absolute = vim.fs.joinpath(worktree_dir, relative)

              local ok = pcall(
                vim.cmd,
                "tabedit " .. vim.fn.fnameescape(absolute)
              )

              if ok then
                vim.cmd("tcd " .. vim.fn.fnameescape(worktree_dir))
                local patch_win = vim.api.nvim_get_current_win()
                local patch_buf = vim.api.nvim_get_current_buf()
                vim.bo[patch_buf].buftype = ""
                vim.bo[patch_buf].modifiable = true
                vim.bo[patch_buf].readonly = false
                vim.b[patch_buf].oculus_inspect_repository = worktree_dir
                vim.b[patch_buf].oculus_inspect_directory = worktree_dir

                for option, value in pairs(code_options) do
                  if option ~= "highlight_namespace" then
                    pcall(function()
                      vim.wo[patch_win][option] = value
                    end)
                  end
                end

                vim.wo[patch_win].cursorline = true
                vim.wo[patch_win].cursorlineopt = "line"
                vim.wo[patch_win].statusline = ""
                vim.wo[patch_win].winfixbuf = false

                local target_line = math.max(
                  1,
                  math.min(
                    tonumber(location.line) or 1,
                    math.max(1, vim.api.nvim_buf_line_count(patch_buf))
                  )
                )

                vim.api.nvim_win_set_cursor(patch_win, { target_line, 0 })

                opened[#opened + 1] = {
                  tab = vim.api.nvim_get_current_tabpage(),
                  win = patch_win,
                  buf = patch_buf,
                  path = relative:gsub("\\", "/"),
                  line = target_line,
                  location = location,
                  repository = worktree_dir,
                  directory = worktree_dir,
                }
              end
            end
          end

          if #opened > 0 then
            group.overview_patch_tabs = group.overview_patch_tabs or {}

            for _, patch in ipairs(opened) do
              group.overview_patch_tabs[#group.overview_patch_tabs + 1] = patch
            end

            group.overview_agent_mode = nil
            group.overview_return = nil
            internal.close_overview_window(group)

            local patch_group =
              inspect._overview_ui.prepare_patch_sidebar(group, opened)

            group.overview_patch_group = patch_group
            local first = opened[1]

            if
              vim.api.nvim_tabpage_is_valid(first.tab)
              and vim.api.nvim_win_is_valid(first.win)
            then
              vim.api.nvim_set_current_tabpage(first.tab)
              vim.api.nvim_set_current_win(first.win)
            end

            return
          end
        end

        internal.close_overview_window(group)
        vim.cmd("tabedit")
        vim.cmd("tcd " .. vim.fn.fnameescape(worktree_dir))
        local ok, oil = pcall(require, "oil")

        if ok and oil and oil.open then
          oil.open(worktree_dir)
        else
          pcall(vim.cmd, "Oil " .. vim.fn.fnameescape(worktree_dir))
        end

        local oil_buf = vim.api.nvim_get_current_buf()

        local function handle_oil_selection()
          local entry

          local ok_entry, cur_entry = pcall(function()
            return oil.get_cursor_entry()
          end)

          if ok_entry and cur_entry then
            entry = cur_entry
          end

          if not entry or entry.type == "directory" then
            return false
          end

          local current_dir = (oil.get_current_dir and oil.get_current_dir())
            or worktree_dir

          local file_path = vim.fs.joinpath(current_dir, entry.name)
          local relative = file_path:sub(#worktree_dir + 2):gsub("\\", "/")
          vim.cmd("edit " .. vim.fn.fnameescape(file_path))
          vim.cmd("tcd " .. vim.fn.fnameescape(worktree_dir))
          local target_win = vim.api.nvim_get_current_win()
          local target_buf = vim.api.nvim_get_current_buf()
          vim.bo[target_buf].buftype = ""
          vim.bo[target_buf].modifiable = true
          vim.bo[target_buf].readonly = false
          vim.b[target_buf].oculus_inspect_repository = worktree_dir
          vim.b[target_buf].oculus_inspect_directory = worktree_dir

          local patch_item = {
            tab = vim.api.nvim_get_current_tabpage(),
            win = target_win,
            buf = target_buf,
            path = relative,
            line = 1,
            repository = worktree_dir,
            directory = worktree_dir,
          }

          group.overview_patch_tabs = group.overview_patch_tabs or {}
          group.overview_patch_tabs[#group.overview_patch_tabs + 1] = patch_item

          local patch_group =
            inspect._overview_ui.prepare_patch_sidebar(group, { patch_item })

          group.overview_patch_group = patch_group
          return true
        end

        for _, lhs in ipairs({ "<CR>", "l" }) do
          local original = vim.api.nvim_buf_call(oil_buf, function()
            return vim.fn.maparg(lhs, "n", false, true)
          end)

          vim.keymap.set("n", lhs, function()
            if handle_oil_selection() then
              return
            end

            if original and original.rhs and original.rhs ~= "" then
              vim.cmd(original.rhs)
            elseif original and original.callback then
              original.callback()
            end
          end, {
            buffer = oil_buf,
            nowait = true,
            silent = true,
            desc = "Select patch location in Oculus worktree",
          })
        end
      end

      if vim.uv.fs_stat(worktree_dir) then
        setup_worktree_files()
        return
      end

      git.run({
        "git",
        "-C",
        repository,
        "worktree",
        "add",
        "-b",
        branch_name,
        worktree_dir,
      }, function(_, err)
        if not err then
          setup_worktree_files()
          return
        end

        git.run({
          "git",
          "-C",
          repository,
          "worktree",
          "add",
          worktree_dir,
          branch_name,
        }, function(_, err2)
          if not err2 or vim.uv.fs_stat(worktree_dir) then
            setup_worktree_files()
            return
          end

          vim.notify(
            "Oculus: could not create worktree: " .. tostring(err2 or err),
            vim.log.levels.ERROR
          )
        end)
      end)
    end

    if opts.branch_name then
      proceed_with_branch(opts.branch_name)
    else
      vim.ui.input({
        prompt = "Worktree branch name: ",
        default = default_branch,
      }, function(input_val)
        proceed_with_branch(input_val)
      end)
    end

    return true
  end

  function inspect._overview_ui.open_model_picker(group, request_kind)
    if not internal.overview_window_is_open(group) then
      return
    end

    inspect._overview_ui.stop_agent_spinner(group)
    group.overview_agent_request_kind = request_kind or "explanation"
    group.overview_agent_mode = "loading_models"
    group.overview_agent_error = nil
    group.overview_agent_models = nil
    group.overview_agent_model_lines = nil
    group.overview_agent_selected_line = nil

    if group.overview_agent_request_kind == "patch_locations" then
      group.overview_agent_patch_model = nil
      group.overview_agent_selected_locations = nil
    else
      group.overview_agent_explanation_model = nil
    end

    inspect._overview_ui.render(group)
    inspect._overview_ui.scroll_to_bottom(group)
    inspect._overview_ui.start_agent_spinner(group)
    local responded = false

    local process, err = require("oculus.agent").models(function(models, load_err)
      responded = true
      inspect._overview_ui.render_models(group, models, load_err)
    end)

    if not process then
      inspect._overview_ui.render_models(group, nil, err)
    elseif not responded then
      group.overview_agent_model_process = process
    end
  end

  function inspect._overview_ui.open_browser(group)
    local url = group.overview and group.overview.url

    if type(url) ~= "string" or url == "" then
      vim.notify("Oculus: this item has no browser URL", vim.log.levels.WARN)
      return false
    end

    local ok, err = browser.open(url, group.browser_config or {})

    if not ok and err then
      vim.notify("Oculus: " .. tostring(err), vim.log.levels.ERROR)
      return false
    end

    return true
  end

  function inspect._overview_ui.render_explanation(
    group,
    model,
    text,
    err
  )
    if group.overview_agent_mode ~= "generating"
      or group.overview_agent_request_kind ~= "explanation"
    then
      return
    end

    inspect._overview_ui.stop_agent_spinner(group)
    group.overview_agent_explanation_model = model

    if text then
      group.overview_agent_mode = "explanation"
      group.overview_agent_explanation = text
      inspect._overview_ui.persist(group)
    else
      group.overview_agent_mode = "error"
      group.overview_agent_error = "Generation failed: " .. tostring(err)
    end

    inspect._overview_ui.render(group)
    inspect._overview_ui.scroll_to_bottom(group)
  end

  function inspect._overview_ui.agent_telemetry_attributes(group)
    local overview = group and group.overview or {}
    local changed_files = {}
    local patch_count = 0
    local patch_bytes = 0

    for _, session in ipairs(group or {}) do
      local file = session.change_file or session.parent_file

      if type(file) == "string" and file ~= "" then
        changed_files[file] = true
      end

      if type(session.patch) == "string" and session.patch ~= "" then
        patch_count = patch_count + 1
        patch_bytes = patch_bytes + #session.patch
      end
    end

    local changed_file_count = vim.tbl_count(changed_files)

    return {
      ["oculus.activity.kind"] = overview.kind
        or (group and group.kind)
        or "unknown",
      ["oculus.activity.forge"] = overview.forge or "unknown",
      ["oculus.activity.changed_file_count"] = changed_file_count,
      ["oculus.activity.patch_count"] = patch_count,
      ["oculus.activity.patch_bytes"] = patch_bytes,
      ["oculus.activity.has_file_changes"] = changed_file_count > 0,
    }
  end

  function inspect._overview_ui.open_explanation(group, model)
    local agent = require("oculus.agent")
    local repository = agent.repository(group)
    group.overview_agent_request_kind = "explanation"
    group.overview_agent_mode = "generating"
    group.overview_agent_models = nil
    group.overview_agent_model_lines = nil
    group.overview_agent_selected_line = nil
    group.overview_agent_explanation_model = model.id
    inspect._overview_ui.render(group)
    inspect._overview_ui.scroll_to_bottom(group)
    inspect._overview_ui.start_agent_spinner(group)

    if not repository then
      inspect._overview_ui.render_explanation(
        group,
        model.id,
        nil,
        "local repository information is unavailable"
      )

      return
    end

    group.overview_agent_pending = true
    local finished = false

    local function finish(explanation, err, metadata)
      if finished then
        return
      end

      finished = true
      group.overview_agent_pending = nil
      group.overview_agent_process = nil
      local normalized = agent.normalize_result(explanation, false, repository)
      local actual_model = metadata and metadata.model or model.id
      local telemetry_context = metadata and metadata.telemetry or nil
      group.overview_agent_explanation = normalized
      group.overview_agent_explanation_model = actual_model
      group.overview_agent_explanation_telemetry = telemetry_context

      require("oculus.telemetry").record(
        "oculus.inspect.agent_result.process",
        {
          ["gen_ai.workflow.name"] = "oculus.inspect.explanation",
          ["oculus.agent.result.valid"] = normalized ~= nil,
        },
        telemetry_context,
        normalized and nil or "invalid_output"
      )

      inspect._overview_ui.render_explanation(
        group,
        actual_model,
        normalized,
        err or "Agent returned no explanation"
      )
    end

    local process, err = agent.explain({
      cwd = repository,
      prompt = agent.prompt(group),
      model = model.id,
      workflow = "oculus.inspect.explanation",
      output_type = "text",
      telemetry_attributes = inspect._overview_ui.agent_telemetry_attributes(group),
    }, finish)

    if not process and not finished then
      finish(nil, err)
    elseif not finished then
      group.overview_agent_process = process
    end
  end

  function inspect._overview_ui.render_patch_locations(
    group,
    model,
    locations,
    err
  )
    if group.overview_agent_mode ~= "generating"
      or group.overview_agent_request_kind ~= "patch_locations"
    then
      return
    end

    inspect._overview_ui.stop_agent_spinner(group)
    group.overview_agent_patch_model = model

    if locations then
      group.overview_agent_mode = "patch_locations"
      group.overview_agent_locations = {}

      for index = 1, math.min(3, #locations) do
        group.overview_agent_locations[index] = locations[index]
      end

      group.overview_agent_selected_location_index =
        #group.overview_agent_locations > 0 and 1 or nil

      group.overview_agent_selected_locations = {}
      inspect._overview_ui.persist(group)
    else
      group.overview_agent_mode = "error"
      group.overview_agent_error = "Generation failed: " .. tostring(err)
    end

    inspect._overview_ui.render(group)
    inspect._overview_ui.scroll_to_bottom(group)
  end

  function inspect._overview_ui.open_patch_locations(group, model)
    local agent = require("oculus.agent")
    local repository = agent.repository(group)
    group.overview_agent_request_kind = "patch_locations"
    group.overview_agent_mode = "generating"
    group.overview_agent_models = nil
    group.overview_agent_model_lines = nil
    group.overview_agent_selected_line = nil
    group.overview_agent_patch_model = model.id
    inspect._overview_ui.render(group)
    inspect._overview_ui.scroll_to_bottom(group)
    inspect._overview_ui.start_agent_spinner(group)

    if not repository then
      inspect._overview_ui.render_patch_locations(
        group,
        model.id,
        nil,
        "local repository information is unavailable"
      )

      return
    end

    group.overview_agent_pending = true
    local finished = false

    local function finish(response, err, metadata)
      if finished then
        return
      end

      finished = true
      group.overview_agent_pending = nil
      group.overview_agent_process = nil
      local _, locations = agent.normalize_result(response, true, repository)
      local actual_model = metadata and metadata.model or model.id
      local telemetry_context = metadata and metadata.telemetry or nil
      group.overview_agent_patch_model = actual_model
      group.overview_agent_patch_telemetry = telemetry_context

      require("oculus.telemetry").record(
        "oculus.inspect.agent_result.process",
        {
          ["gen_ai.workflow.name"] = "oculus.inspect.patch_locations",
          ["oculus.agent.result.valid"] = response ~= nil,
          ["oculus.agent.result.location_count"] = #locations,
        },
        telemetry_context,
        response and nil or "invalid_output"
      )

      inspect._overview_ui.render_patch_locations(
        group,
        actual_model,
        response and locations or nil,
        err or "Agent returned no patch locations"
      )
    end

    local process, err = agent.explain({
      cwd = repository,
      prompt = agent.patch_locations_prompt(group),
      model = model.id,
      workflow = "oculus.inspect.patch_locations",
      output_type = "json",
      telemetry_attributes = inspect._overview_ui.agent_telemetry_attributes(group),
    }, finish)

    if not process and not finished then
      finish(nil, err)
    elseif not finished then
      group.overview_agent_process = process
    end
  end

  internal.overview_window_config = overview_window_config
  return inspect._overview_ui
end

return M
