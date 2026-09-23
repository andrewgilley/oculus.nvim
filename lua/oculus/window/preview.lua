-- The preview panel beside the lists: what one activity item, project, user or
-- group looks like when the cursor rests on it, and the requests that fill a
-- preview in the background.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local M = {}

function M.setup(window, internal)
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

        return item.text .. separator .. internal.trim_to_width(detail, detail_width)
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

    return internal.pad_cell(content, content_width)
      .. activity_timestamp_gap
      .. internal.left_pad_cell(timestamp, activity_timestamp_width)
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
    body = internal.trim_to_width(body, body_width)

    while vim.fn.strdisplaywidth(body) > body_width do
      body = vim.fn.strcharpart(
        body,
        0,
        math.max(0, vim.fn.strchars(body) - 1)
      )
    end

    local spinner_column = #body + 1

    return internal.pad_cell(body .. " " .. frame, content_width) .. tail,
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
      local text = internal.trim_to_width(
        quoted_detail_line(detail_item.text),
        content_width
      )

      lines[#lines + 1] = indent .. internal.pad_cell(text, content_width)
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

  window._project_pull_request_title = project_pull_request_title

  local function render_preview_panel(items)
    if
      (
        window.state.view ~= "contributors"
        and window.state.view ~= "directory"
        and window.state.view ~= "milestones"
        and window.state.view ~= "devlog"
        and window.state.view ~= "work"
      )
      or not internal.is_valid_buf(window.state.buf)
      or not internal.is_valid_win(window.state.win)
    then
      return
    end

    vim.api.nvim_buf_clear_namespace(window.state.buf, internal.preview_ns, 0, -1)
    window.state.preview_items = items
    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local right_width = math.max(16, window_width - left_width - 3)
    local line_count = vim.api.nvim_buf_line_count(window.state.buf)

    for line = 1, line_count do
      local item = items[line]
      local text = item and internal.trim_to_width(item[1], right_width - 1) or ""
      local group = item and item[2] or "NormalFloat"

      vim.api.nvim_buf_set_extmark(window.state.buf, internal.preview_ns, line - 1, 0, {
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
      [5] = { internal.provider_name(contributor), "Comment" },
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

      lines[#lines + 1] = internal.trim_to_width(line, width)
    end

    return lines
  end

  local function project_preview_items(project, width)
    local provider = project.provider == "codeberg" and "Codeberg" or "GitHub"

    local items = {
      [2] = { "PROJECT", "Title" },
      [4] = { internal.project_title(project), "Identifier" },
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

  local function directory_preview_items(dir_name, width)
    if not dir_name or dir_name == "" then
      return {}
    end

    local projects = internal.visible_projects()
    local child_projects = {}

    for _, p in ipairs(projects) do
      if p.directory and p.directory:lower() == dir_name:lower() then
        child_projects[#child_projects + 1] = p
      end
    end

    local items = {
      [2] = { "DIRECTORY", "Title" },
    }

    if #child_projects == 0 then
      items[4] = { "(no projects)", "Comment" }
    else
      local window_height = internal.is_valid_win(window.state.win) and vim.api.nvim_win_get_height(window.state.win) or 25
      local max_visible = math.max(1, window_height - 6)

      if #child_projects <= max_visible then
        for index, p in ipairs(child_projects) do
          items[3 + index] = { internal.project_title(p), "Identifier" }
        end
      else
        local show_count = math.max(1, max_visible - 1)

        for index = 1, show_count do
          items[3 + index] = { internal.project_title(child_projects[index]), "Identifier" }
        end

        local remaining = #child_projects - show_count
        items[3 + show_count + 1] = { ("... and %d more"):format(remaining), "Comment" }
      end
    end

    return items
  end

  local function queue_directory_preview(dir_name)
    if not dir_name or (window.state.view ~= "contributors" and window.state.view ~= "directory") then
      return
    end

    local key = "dir:" .. dir_name:lower()

    if window.state.preview_key == key then
      return
    end

    window.state.preview_key = key
    window.state.preview_project = nil
    window.state.preview_contributor = nil
    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local preview_width = math.max(15, window_width - left_width - 5)
    render_preview_panel(directory_preview_items(dir_name, preview_width))
  end

  local function activity_types_for(contributor)
    local overrides = window.state.opts.user_activity_types or {}
    local username = contributor.username
    local user_types = overrides[username] or overrides[username:lower()]

    if user_types ~= nil then
      return user_types
    end

    if contributor.activity_types ~= nil then
      return contributor.activity_types
    end

    return window.state.opts.activity_types
  end

  local function queue_preview(contributor)
    if
      not contributor
      or window.state.view ~= "contributors"
    then
      return
    end

    local key = internal.contributor_key(contributor)

    if window.state.preview_key == key then
      return
    end

    window.state.preview_key = key
    window.state.preview_contributor = contributor
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
      window.state.opts or {},
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
    if not project or (window.state.view ~= "contributors" and window.state.view ~= "directory") then
      return
    end

    local key = internal.project_key(project)

    if window.state.preview_key == key then
      return
    end

    window.state.preview_key = key
    window.state.preview_project = project
    local cache = window.state.opts.project_descriptions or {}
    window.state.opts.project_descriptions = cache

    if not project.description or project.description == "" then
      project.description = cache[key]
    end

    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local preview_width = math.max(15, window_width - left_width - 5)
    render_preview_panel(project_preview_items(project, preview_width))

    if not project.description or project.description == "" then
      fetch_project_description(project, function(desc)
        if
          desc
          and desc ~= ""
          and window.state.preview_key == key
          and internal.is_valid_win(window.state.win)
        then
          project.description = desc
          cache[key] = desc
          internal.persist_projects()
          render_preview_panel(project_preview_items(project, preview_width))
        end
      end)
    end
  end

  function window.load_project_descriptions(opts, callback)
    local config = opts or window.state.opts or {}
    local projects = config.projects or {}
    local pending = 0
    local updated_any = false

    for _, project in ipairs(projects) do
      if
        type(project) == "table"
        and type(project.repository) == "string"
        and project.repository ~= ""
        and (config.force or not project.description or project.description == "")
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
                  window.state.preview_project
                  and internal.project_key(window.state.preview_project) == internal.project_key(project)
                  and internal.is_valid_win(window.state.win)
                then
                  local window_width = vim.api.nvim_win_get_width(window.state.win)
                  local left_width = internal.preview_left_width(window_width)
                  local preview_width = math.max(15, window_width - left_width - 5)

                  render_preview_panel(
                    project_preview_items(project, preview_width)
                  )
                end
              end
            end

            if pending == 0 then
              if updated_any and config.persist_projects then
                internal.persist_projects()
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

  function window.refresh_project_descriptions(opts_or_target, callback)
    local target = nil
    local config = nil

    if type(opts_or_target) == "function" then
      callback = opts_or_target
    elseif type(opts_or_target) == "string" then
      target = opts_or_target
    elseif type(opts_or_target) == "table" then
      if opts_or_target.projects then
        config = opts_or_target
      else
        target = opts_or_target.target or opts_or_target.repository
        config = opts_or_target.config
      end
    end

    local oculus = require("oculus")

    config = config
      or (oculus.config and oculus.config.projects and #oculus.config.projects > 0 and oculus.config)
      or (window.state and window.state.opts and window.state.opts.projects and #window.state.opts.projects > 0 and window.state.opts)
      or oculus.config
      or {}

    local projects = config.projects or {}
    local target_str = (type(target) == "string" and vim.trim(target) ~= "") and vim.trim(target):lower() or nil
    local to_refresh = {}

    for _, project in ipairs(projects) do
      if
        type(project) == "table"
        and type(project.repository) == "string"
        and project.repository ~= ""
      then
        if
          not target_str
          or project.repository:lower() == target_str
          or (type(project.name) == "string" and project.name:lower() == target_str)
        then
          to_refresh[#to_refresh + 1] = project
        end
      end
    end

    if #to_refresh == 0 then
      if callback then
        callback(to_refresh, false)
      end

      return false, target_str and ("Project '" .. tostring(target) .. "' not found") or "No saved projects found"
    end

    local pending = 0
    local updated_any = false
    local req_opts = vim.tbl_deep_extend("force", vim.deepcopy(config), { force = true })

    local cache = (window.state and window.state.opts and window.state.opts.project_descriptions)
      or config.project_descriptions
      or {}

    config.project_descriptions = cache

    if window.state and window.state.opts then
      window.state.opts.project_descriptions = cache
    end

    for _, project in ipairs(to_refresh) do
      local provider = project.provider == "codeberg" and codeberg or github

      if provider and type(provider.repository_info) == "function" then
        pending = pending + 1

        provider.repository_info(project.repository, req_opts, function(info)
          pending = pending - 1

          if
            info
            and type(info.description) == "string"
            and info.description ~= ""
          then
            local key = internal.project_key(project)
            cache[key] = info.description

            if oculus.config and oculus.config.project_descriptions then
              oculus.config.project_descriptions[key] = info.description
            end

            if project.description ~= info.description then
              project.description = info.description
              updated_any = true
            end

            if window.state and window.state.opts and window.state.opts.projects then
              for _, p in ipairs(window.state.opts.projects) do
                if type(p) == "table" and internal.project_key(p) == key then
                  p.description = info.description
                end
              end
            end

            if oculus.config and oculus.config.projects then
              for _, p in ipairs(oculus.config.projects) do
                if type(p) == "table" and internal.project_key(p) == key then
                  p.description = info.description
                end
              end
            end

            if
              window.state
              and window.state.preview_project
              and internal.project_key(window.state.preview_project) == key
              and internal.is_valid_win(window.state.win)
            then
              window.state.preview_project.description = info.description
              local window_width = vim.api.nvim_win_get_width(window.state.win)
              local left_width = internal.preview_left_width(window_width)
              local preview_width = math.max(15, window_width - left_width - 5)

              render_preview_panel(
                project_preview_items(project, preview_width)
              )
            end
          end

          if pending == 0 then
            if config.state_file then
              pcall(require("oculus.storage").save, config.state_file, config)
            end

            if config.persist_projects then
              pcall(internal.persist_projects)
            end

            if callback then
              callback(to_refresh, updated_any)
            end
          end
        end)
      end
    end

    if pending == 0 and callback then
      callback(to_refresh, updated_any)
    end

    return true
  end

  return {
    activity_title_highlight_end = activity_title_highlight_end,
    activity_item_line = activity_item_line,
    activity_loading_line = activity_loading_line,
    preview_lines = preview_lines,
    without_preview = without_preview,
    project_push_author = project_push_author,
    project_pull_request_title = project_pull_request_title,
    render_preview_panel = render_preview_panel,
    preview_items = preview_items,
    wrapped_preview_text = wrapped_preview_text,
    project_preview_items = project_preview_items,
    directory_preview_items = directory_preview_items,
    queue_directory_preview = queue_directory_preview,
    activity_types_for = activity_types_for,
    queue_preview = queue_preview,
    fetch_project_description = fetch_project_description,
    queue_project_preview = queue_project_preview,
    load_project_descriptions = window.load_project_descriptions,
    refresh_project_descriptions = window.refresh_project_descriptions,
  }
end

return M
