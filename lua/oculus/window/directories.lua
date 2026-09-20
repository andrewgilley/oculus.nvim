-- The groups projects are organised into: creating and removing one, moving a
-- project between them, and the prompts that ask for a name or a destination.
-- The tracking file itself is written by oculus.tracking.
local actions = require("oculus.actions")
local navigation = require("oculus.navigation")
local M = {}

function M.setup(window, internal)
  local function create_project_directory(name)
    if window.state.opts.tracking_file then
      return require("oculus.tracking_ui").add(window.state, {name=name, children={}})
    end

    if type(name) ~= "string" then
      return false, "directory name must be a string"
    end

    local trimmed = vim.trim(name)

    if trimmed == "" then
      return false, "directory name cannot be empty"
    end

    window.state.opts = window.state.opts or {}
    window.state.opts.project_directories = window.state.opts.project_directories or {}

    for _, d in ipairs(window.state.opts.project_directories) do
      if type(d) == "string" and d:lower() == trimmed:lower() then
        return false, "directory already exists"
      end
    end

    table.insert(window.state.opts.project_directories, trimmed)
    window.state.opts.project_order = window.state.opts.project_order or {}
    table.insert(window.state.opts.project_order, "dir:" .. trimmed:lower())
    window.state.collapsed_project_directories = window.state.collapsed_project_directories or {}
    window.state.collapsed_project_directories[trimmed] = false
    window.state.selected_directory = trimmed
    window.state.selected_project = nil
    window.state.selected_username = nil
    internal.persist_projects()

    if internal.is_valid_win(window.state.win) then
      if window.state.view == "directory" and window.state.current_directory then
        M.render_directory(window.state.current_directory)
      elseif window.state.view == "contributors" then
        internal.render_contributors()
      end
    end

    return true
  end

  local function remove_project_directory(name)
    if type(name) ~= "string" or vim.trim(name) == "" then
      return false, "invalid directory name"
    end

    local trimmed = vim.trim(name):lower()
    window.state.opts = window.state.opts or {}
    local dirs = window.state.opts.project_directories or {}
    local found_idx = nil

    for idx, d in ipairs(dirs) do
      if type(d) == "string" and d:lower() == trimmed then
        found_idx = idx
        break
      end
    end

    if not found_idx then
      return false, "directory not found"
    end

    local removed_name = table.remove(dirs, found_idx)

    if window.state.opts.project_order then
      local dir_k = "dir:" .. trimmed

      for i = #window.state.opts.project_order, 1, -1 do
        if window.state.opts.project_order[i]:lower() == dir_k then
          table.remove(window.state.opts.project_order, i)
        end
      end
    end

    for _, p in ipairs(window.state.opts.projects or {}) do
      if p.directory and p.directory:lower() == trimmed then
        p.directory = nil
      end
    end

    if window.state.collapsed_project_directories then
      window.state.collapsed_project_directories[removed_name] = nil
    end

    if window.state.selected_directory and window.state.selected_directory:lower() == trimmed then
      window.state.selected_directory = nil
    end

    if window.state.current_directory and window.state.current_directory:lower() == trimmed then
      window.state.current_directory = nil
      window.state.directory_return = nil
    end

    internal.persist_projects()

    if internal.is_valid_win(window.state.win) then
      if window.state.view == "directory" then
        if window.state.current_directory then
          M.render_directory(window.state.current_directory)
        else
          internal.render_contributors()
        end
      elseif window.state.view == "contributors" then
        internal.render_contributors()
      end
    end

    return true
  end

  local function move_project_to_directory(project_or_key, dir_name)
    if window.state.opts.tracking_file then
      return require("oculus.tracking_ui").move_named(window.state, project_or_key, dir_name)
    end

    window.state.opts = window.state.opts or {}
    local projects = window.state.opts.projects or {}
    local target_project = nil

    if type(project_or_key) == "table" then
      local key = internal.project_key(project_or_key)

      for _, p in ipairs(projects) do
        if internal.project_key(p) == key then
          target_project = p
          break
        end
      end
    elseif type(project_or_key) == "string" and project_or_key ~= "" then
      local key = project_or_key:lower()

      for _, p in ipairs(projects) do
        if (p.repository and p.repository:lower() == key)
          or (p.name and p.name:lower() == key)
          or (internal.project_key(p) and internal.project_key(p):lower() == key)
        then
          target_project = p
          break
        end
      end
    elseif not project_or_key then
      target_project = window.state.selected_project

      if not target_project then
        local cur_target = internal.target_on_cursor()

        if type(cur_target) == "table" and cur_target.kind == "project" then
          target_project = cur_target.project
        end
      end
    end

    if not target_project then
      return false, "project not found"
    end

    local clean_dir = nil

    if type(dir_name) == "string" then
      clean_dir = vim.trim(dir_name)

      if clean_dir == "" or clean_dir == "/" or clean_dir:lower() == "root" then
        clean_dir = nil
      end
    end

    if clean_dir then
      window.state.opts.project_directories = window.state.opts.project_directories or {}
      local exists = false
      local canonical_name = clean_dir

      for _, d in ipairs(window.state.opts.project_directories) do
        if type(d) == "string" and d:lower() == clean_dir:lower() then
          exists = true
          canonical_name = d
          break
        end
      end

      if not exists then
        table.insert(window.state.opts.project_directories, clean_dir)
        window.state.opts.project_order = window.state.opts.project_order or {}
        table.insert(window.state.opts.project_order, "dir:" .. clean_dir:lower())
      end

      target_project.directory = canonical_name
      window.state.collapsed_project_directories = window.state.collapsed_project_directories or {}
      window.state.collapsed_project_directories[canonical_name] = false

      if window.state.opts.project_order then
        local proj_k = "proj:" .. (internal.project_key(target_project) or ""):lower()

        for i = #window.state.opts.project_order, 1, -1 do
          if window.state.opts.project_order[i]:lower() == proj_k then
            table.remove(window.state.opts.project_order, i)
          end
        end
      end

      if window.state.view == "contributors" then
        window.state.selected_directory = canonical_name
        window.state.selected_project = nil
      else
        window.state.selected_project = target_project
        window.state.selected_directory = nil
      end
    else
      local old_dir = target_project.directory
      target_project.directory = nil
      window.state.selected_project = target_project
      window.state.selected_directory = nil

      if window.state.opts.project_order then
        local proj_k = "proj:" .. (internal.project_key(target_project) or ""):lower()

        for i = #window.state.opts.project_order, 1, -1 do
          if window.state.opts.project_order[i]:lower() == proj_k then
            table.remove(window.state.opts.project_order, i)
          end
        end

        local inserted = false

        if old_dir and old_dir ~= "" then
          local dir_k = "dir:" .. old_dir:lower()

          for idx, k in ipairs(window.state.opts.project_order) do
            if k:lower() == dir_k then
              table.insert(window.state.opts.project_order, idx + 1, proj_k)
              inserted = true
              break
            end
          end
        end

        if not inserted then
          table.insert(window.state.opts.project_order, proj_k)
        end
      end
    end

    window.state.selected_username = nil
    internal.persist_projects()

    if internal.is_valid_win(window.state.win) then
      if window.state.view == "directory" and window.state.current_directory then
        M.render_directory(window.state.current_directory)
      elseif window.state.view == "contributors" then
        internal.render_contributors()
      end
    end

    return true
  end

  local function move_to_parent_directory(moving_project)
    if not moving_project then
      return false
    end

    local old_dir = moving_project.directory or window.state.current_directory
    moving_project.directory = nil
    window.state.moving_item = nil
    window.state.opts = window.state.opts or {}
    local projects = window.state.opts.projects or {}
    local pkey = internal.project_key(moving_project)

    for _, p in ipairs(projects) do
      if internal.project_key(p) == pkey then
        p.directory = nil
        break
      end
    end

    if window.state.opts.project_order then
      local proj_k = pkey and ("proj:" .. pkey:lower()) or nil

      if proj_k then
        for i = #window.state.opts.project_order, 1, -1 do
          if window.state.opts.project_order[i]:lower() == proj_k then
            table.remove(window.state.opts.project_order, i)
          end
        end

        local inserted = false

        if old_dir and old_dir ~= "" then
          local dir_k = "dir:" .. old_dir:lower()

          for idx, k in ipairs(window.state.opts.project_order) do
            if k:lower() == dir_k then
              table.insert(window.state.opts.project_order, idx + 1, proj_k)
              inserted = true
              break
            end
          end
        end

        if not inserted then
          table.insert(window.state.opts.project_order, proj_k)
        end
      end
    end

    window.state.current_directory = nil
    window.state.directory_return = nil
    window.state.selected_project = moving_project
    window.state.selected_directory = nil
    window.state.selected_username = nil
    internal.persist_projects()

    if internal.is_valid_win(window.state.win) then
      internal.render_contributors()
    end

    return true
  end

  function M.render_directory(dir_name)
    if not dir_name or dir_name == "" then
      internal.render_contributors()
      return
    end

    internal.stop_activity_page_loading()
    internal.close_activity_footer()
    window.state.view = "directory"
    window.state.current_directory = dir_name
    window.state.contributor = nil
    window.state.activity_scope = nil
    window.state.activity_project = nil
    window.state.events = nil
    window.state.line_targets = {}
    window.state.preview_key = nil
    window.state.preview_project = nil
    local all_projects = internal.visible_projects()
    local child_projects = {}

    for _, project in ipairs(all_projects) do
      if project.directory and project.directory:lower() == dir_name:lower() then
        child_projects[#child_projects + 1] = project
      end
    end

    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local window_height = vim.api.nvim_win_get_height(window.state.win)

    local lines = {
      "",
      "  DIRECTORY",
      "  " .. dir_name,
      "",
      "  PROJECTS",
    }

    local project_lines = {}

    for _, project in ipairs(child_projects) do
      local line = #lines + 1
      lines[line] = internal.pad_cell("  " .. internal.project_title(project), left_width)

      window.state.line_targets[line] = {
        kind = "project",
        project = project,
        directory = dir_name,
      }

      project_lines[#project_lines + 1] = line
    end

    if #child_projects == 0 then
      local empty_line = #lines + 1
      lines[empty_line] = internal.pad_cell("  (empty)", left_width)

      window.state.line_targets[empty_line] = {
        kind = "directory_empty",
        directory = dir_name,
      }

      project_lines[#project_lines + 1] = empty_line
    end

    while #lines < window_height do
      lines[#lines + 1] = ""
    end

    internal.set_lines(lines)
    window.state.list_footer_line = nil
    window.state.list_footer_text = nil
    vim.wo[window.state.win].cursorline = false
    internal.highlight(2, 2, -1, "Title")
    internal.highlight(3, 2, -1, "OculusDirectory")
    internal.highlight(5, 2, -1, "OculusSectionTitle")

    for line, target in pairs(window.state.line_targets) do
      if target.kind == "project" then
        internal.highlight(line, 2, -1, "Identifier")
      elseif target.kind == "directory_empty" then
        internal.highlight(line, 2, -1, "Comment")
      end
    end

    if separator_line then
      internal.highlight(separator_line, 2, -1, "WinSeparator")
    end

    if commands_line then
      internal.highlight(commands_line, 2, -1, "OculusNormal")
    end

    local selected_line = nil

    if window.state.selected_project then
      for line, target in pairs(window.state.line_targets) do
        if
          target.kind == "project"
          and target.project.repository
            == window.state.selected_project.repository
        then
          selected_line = line
          break
        end
      end
    end

    if not selected_line then
      for _, line in ipairs(project_lines) do
        if window.state.line_targets[line] then
          selected_line = line
          break
        end
      end
    end

    if selected_line and internal.is_valid_win(window.state.win) then
      local target = window.state.line_targets[selected_line]

      if target and target.kind == "project" then
        window.state.selected_project = target.project
        window.state.selected_username = nil
        window.state.selected_directory = nil
        internal.queue_project_preview(target.project)
      else
        window.state.selected_project = nil
        window.state.selected_username = nil
        window.state.selected_directory = dir_name
        internal.queue_directory_preview(dir_name)
      end

      vim.api.nvim_win_set_cursor(window.state.win, { selected_line, 2 })
    end

    internal.update_contributor_selection()
    internal.render_sidebar()
  end

  local function toggle_project_directory(name)
    if not name then
      return
    end

    M.render_directory(name)
  end

  local function prompt_create_directory()
    local function on_confirm(input)
      if input and vim.trim(input) ~= "" then
        local ok, err = create_project_directory(vim.trim(input))

        if not ok and err then
          vim.notify("Oculus: " .. tostring(err), vim.log.levels.WARN)
        end
      end
    end

    if vim.ui and vim.ui.input then
      vim.ui.input({ prompt = "New project directory name: " }, on_confirm)
    else
      local input = vim.fn.input("New project directory name: ")
      on_confirm(input)
    end
  end

  local function prompt_move_project_to_directory(project)
    if window.state.opts.tracking_file then
      return require("oculus.tracking_ui").handle(window.state, "destination", internal.target_on_cursor())
    end

    project = project or window.state.selected_project

    if not project then
      local target = internal.target_on_cursor()

      if type(target) == "table" and target.kind == "project" then
        project = target.project
      end
    end

    if not project then
      vim.notify("Oculus: No project selected to move", vim.log.levels.WARN)
      return
    end

    local prompt_text = ("Move '%s' to directory (leave empty or '/' for root): "):format(internal.project_title(project))
    local default_val = project.directory or ""

    local function on_confirm(input)
      if input ~= nil then
        move_project_to_directory(project, input)
      end
    end

    if vim.ui and vim.ui.input then
      vim.ui.input({ prompt = prompt_text, default = default_val }, on_confirm)
    else
      local input = vim.fn.input(prompt_text, default_val)
      on_confirm(input)
    end
  end

  return {
    create_project_directory = create_project_directory,
    remove_project_directory = remove_project_directory,
    move_project_to_directory = move_project_to_directory,
    move_to_parent_directory = move_to_parent_directory,
    toggle_project_directory = toggle_project_directory,
    render_directory = M.render_directory,
    prompt_create_directory = prompt_create_directory,
    prompt_move_project_to_directory = prompt_move_project_to_directory,
  }
end

return M
