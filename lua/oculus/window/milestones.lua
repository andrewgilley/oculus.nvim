-- A project's milestones, and the issues and pull requests in one of them,
-- listed like an activity feed and paged the same way.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local browser = require("oculus.browser")
local navigation = require("oculus.navigation")
local M = {}

function M.setup(window, milestone_view, internal)
  function milestone_view.date(timestamp)
    return type(timestamp) == "string"
        and timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)")
      or nil
  end

  function milestone_view.sort(milestones)
    table.sort(milestones, function(left, right)
      if left.state ~= right.state then
        return left.state == "open"
      end

      -- Open milestones lead with the nearest due date; closed ones with the
      -- most recently finished.
      local left_date = left.state == "open"
          and (left.due_on or "")
        or (left.closed_at or left.due_on or "")

      local right_date = right.state == "open"
          and (right.due_on or "")
        or (right.closed_at or right.due_on or "")

      if left_date ~= right_date then
        if left.state == "open" and (left_date == "" or right_date == "") then
          return right_date == ""
        end

        if left.state == "open" then
          return left_date < right_date
        end

        return left_date > right_date
      end

      return tostring(left.title):lower() < tostring(right.title):lower()
    end)

    return milestones
  end

  function milestone_view.preview_items(milestone, width)
    local open_count = milestone.open_issues or 0
    local closed_count = milestone.closed_issues or 0
    local total = open_count + closed_count

    local percent = total > 0
        and math.floor(closed_count * 100 / total + 0.5)
      or 0

    local status

    if milestone.state == "closed" then
      local closed = milestone_view.date(milestone.closed_at)
      status = closed and ("Closed " .. closed) or "Closed"
    else
      local due = milestone_view.date(milestone.due_on)
      status = due and ("Open · due " .. due) or "Open · no due date"
    end

    local items = {
      [2] = { "MILESTONE", "Title" },
      [4] = { milestone.title, "Identifier" },
      [5] = { status, "Comment" },
      [6] = {
        ("%d open · %d closed · %d%% complete"):format(
          open_count,
          closed_count,
          percent
        ),
        "Comment",
      },
    }

    for index, line in ipairs(internal.wrapped_preview_text(
      milestone.description,
      width,
      6
    )) do
      items[7 + index] = { line, "Comment" }
    end

    return items
  end

  function milestone_view.queue_preview(milestone)
    if window.state.view ~= "milestones" or not milestone then
      return
    end

    local key = "milestone:" .. tostring(milestone.id)

    if window.state.preview_key == key then
      return
    end

    window.state.preview_key = key
    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local preview_width = math.max(15, window_width - left_width - 5)
    internal.render_preview_panel(milestone_view.preview_items(milestone, preview_width))
  end

  function milestone_view.selected_index(milestones)
    for index, milestone in ipairs(milestones or {}) do
      if milestone.id == window.state.selected_milestone then
        return index
      end
    end

    return milestones and milestones[1] and 1 or nil
  end

  function milestone_view.render()
    local list = window.state.project_milestones

    if not list or not internal.is_valid_win(window.state.win) then
      return
    end

    internal.stop_activity_page_loading()
    internal.close_activity_footer()
    window.state.view = "milestones"
    window.state.activity_milestone = nil
    window.state.line_targets = {}
    window.state.preview_key = nil
    local project = list.project
    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local window_height = vim.api.nvim_win_get_height(window.state.win)
    local sidebar_visible = internal.is_sidebar_visible()

    local lines = {
      "",
      "  MILESTONES",
      ("  %s · %s"):format(internal.project_title(project), internal.provider_name(project)),
      "",
    }

    local headings = {}
    local comment_lines = {}
    local error_line
    local milestones = list.milestones or {}

    if list.loading then
      lines[#lines + 1] = "  Loading milestones…"
      comment_lines[#comment_lines + 1] = #lines
    elseif list.error then
      lines[#lines + 1] = "  Could not load milestones"
      error_line = #lines
      lines[#lines + 1] = "  " .. list.error
      comment_lines[#comment_lines + 1] = #lines
    elseif #milestones == 0 then
      lines[#lines + 1] = "  No milestones."
      comment_lines[#comment_lines + 1] = #lines
    else
      local rows = {}
      local counts = { open = 0, closed = 0 }

      for _, milestone in ipairs(milestones) do
        counts[milestone.state] = counts[milestone.state] + 1
      end

      for _, section in ipairs({
        { state = "open", heading = "OPEN" },
        { state = "closed", heading = "CLOSED" },
      }) do
        if counts[section.state] > 0 then
          if #rows > 0 then
            rows[#rows + 1] = { kind = "blank" }
          end

          rows[#rows + 1] = {
            kind = "heading",
            text = ("%s (%d)"):format(section.heading, counts[section.state]),
          }

          for _, milestone in ipairs(milestones) do
            if milestone.state == section.state then
              rows[#rows + 1] = { kind = "milestone", milestone = milestone }
            end
          end
        end
      end

      local selected_index = milestone_view.selected_index(milestones)
      local selected = milestones[selected_index]
      window.state.selected_milestone = selected.id
      local selected_row = 1

      for index, row in ipairs(rows) do
        if row.milestone == selected then
          selected_row = index
          break
        end
      end

      -- Render only the rows that fit, like the user list, so the preview
      -- panel and the footer stay anchored while the selection scrolls.
      local capacity = math.max(
        3,
        window_height - #lines - (sidebar_visible and 0 or 2)
      )

      local offset = math.min(
        math.max(1, window.state.milestone_offset or 1),
        math.max(1, #rows - capacity + 1)
      )

      if selected_row < offset then
        offset = selected_row
      elseif selected_row >= offset + capacity then
        offset = selected_row - capacity + 1
      end

      if offset > 1
        and offset == selected_row
        and rows[offset - 1].kind == "heading"
      then
        offset = offset - 1
      end

      window.state.milestone_offset = offset

      for index = offset, math.min(#rows, offset + capacity - 1) do
        local row = rows[index]

        if row.kind == "blank" then
          lines[#lines + 1] = ""
        elseif row.kind == "heading" then
          lines[#lines + 1] = "  " .. row.text
          headings[#headings + 1] = #lines
        else
          lines[#lines + 1] = internal.pad_cell(
            "  " .. internal.trim_to_width(row.milestone.title, left_width - 3),
            left_width
          )

          window.state.line_targets[#lines] = {
            kind = "milestone",
            milestone = row.milestone,
          }
        end
      end
    end

    while #lines < window_height do
      lines[#lines + 1] = ""
    end

    internal.set_lines(lines)
    vim.wo[window.state.win].cursorline = false
    internal.highlight(2, 2, -1, "Title")
    internal.highlight(3, 2, -1, "Comment")

    for _, line in ipairs(headings) do
      internal.highlight(line, 2, -1, "OculusSectionTitle")
    end

    for _, line in ipairs(comment_lines) do
      internal.highlight(line, 2, -1, "Comment")
    end

    if error_line then
      internal.highlight(error_line, 2, -1, "DiagnosticError")
    end

    local selected_line

    for line, target in pairs(window.state.line_targets) do
      internal.highlight(line, 2, -1, "Identifier")

      if target.milestone.id == window.state.selected_milestone then
        selected_line = line
      end
    end

    if separator_line then
      internal.highlight(separator_line, 2, -1, "WinSeparator")
    end

    if commands_line then
      internal.highlight(commands_line, 2, -1, "OculusNormal")
    end

    if selected_line then
      vim.api.nvim_win_set_cursor(window.state.win, { selected_line, 0 })
      milestone_view.queue_preview(window.state.line_targets[selected_line].milestone)
    else
      internal.render_preview_panel({ [2] = { "MILESTONE", "Title" } })
    end

    internal.update_contributor_selection()
    internal.render_sidebar()
  end

  function milestone_view.select_adjacent(direction)
    local list = window.state.project_milestones
    local milestones = list and list.milestones or {}
    local index = milestone_view.selected_index(milestones)

    if not index then
      return
    end

    index = ((index - 1 + direction) % #milestones) + 1
    window.state.selected_milestone = milestones[index].id
    milestone_view.render()
  end

  function milestone_view.load(project, force)
    window.state.request_id = window.state.request_id + 1
    local request_id = window.state.request_id
    local key = internal.project_issue_filter_key(project)
    local previous = window.state.project_milestones

    if not previous or previous.key ~= key then
      window.state.selected_milestone = nil
      window.state.milestone_offset = 1
    end

    window.state.project_milestones = {
      key = key,
      project = project,
      loading = true,
      milestones = previous and previous.key == key
          and previous.milestones
        or nil,
    }

    milestone_view.render()
    local provider = project.provider == "codeberg" and codeberg or github

    if type(provider.repository_milestones) ~= "function" then
      window.state.project_milestones.loading = false

      window.state.project_milestones.error =
        "this provider does not support milestones"

      milestone_view.render()
      return
    end

    local request_opts = vim.tbl_extend(
      "force",
      window.state.opts,
      { force = force or false }
    )

    provider.repository_milestones(project.repository, request_opts, function(
      milestones,
      err
    )
      if request_id ~= window.state.request_id
        or window.state.view ~= "milestones"
        or not internal.is_valid_win(window.state.win)
      then
        return
      end

      window.state.project_milestones = {
        key = key,
        project = project,
        loading = false,
        error = err and tostring(err) or nil,
        milestones = milestones and milestone_view.sort(milestones) or {},
      }

      milestone_view.render()
    end)
  end

  function milestone_view.load_items(project, milestone, force, page)
    local previous_page = window.state.activity_page or 1

    local preserve_activity_page = page ~= nil
      and window.state.view == "activity"
      and window.state.activity_milestone == milestone
      and window.state.activity_loaded
      and internal.is_valid_buf(window.state.buf)

    if page == nil then
      window.state.activity_loaded_pages = 1
    end

    local requested_page = math.max(1, page or 1)
    window.state.activity_page = requested_page

    window.state.activity_page_size = math.max(
      1,
      math.floor(tonumber(window.state.opts.results_limit) or 8)
    )

    window.state.request_id = window.state.request_id + 1
    local request_id = window.state.request_id

    if preserve_activity_page then
      window.state.activity_error = nil
      internal.start_activity_page_loading()
    else
      internal.render_loading({
        kind = "project",
        project = project,
        milestone = milestone,
      })
    end

    local provider = project.provider == "codeberg" and codeberg or github

    local request_opts = vim.tbl_extend(
      "force",
      window.state.opts,
      { force = force or false }
    )

    request_opts.per_page = project.provider == "codeberg" and 50 or 100

    local feed_key = table.concat({
      internal.project_issue_filter_key(project),
      tostring(milestone.id),
    }, ":")

    local feed = window.state.milestone_items_feed

    if force or not feed or feed.key ~= feed_key then
      feed = {
        key = feed_key,
        events = {},
        seen = {},
        next_page = 1,
        complete = false,
        cached = true,
      }

      window.state.milestone_items_feed = feed
    end

    local required_events = requested_page * window.state.activity_page_size
    local max_source_pages = 10

    local function render_items()
      local items = internal.deduplicate_activity(feed.events)

      local first_event =
        (requested_page - 1) * window.state.activity_page_size + 1

      if requested_page > 1 and #items < first_event then
        window.state.activity_page = math.max(1, previous_page)
      else
        window.state.activity_page = requested_page
      end

      window.state.activity_source_events = items

      window.state.activity_loaded_pages = math.max(
        window.state.activity_loaded_pages or 1,
        window.state.activity_page
      )

      local page_end = window.state.activity_page * window.state.activity_page_size
      window.state.activity_has_past = #items > page_end or not feed.complete

      internal.render_activity(
        internal.activity_page(
          items,
          window.state.activity_page,
          window.state.activity_page_size
        ),
        feed.cached,
        nil,
        { issue_page = false }
      )
    end

    local function ensure_items_page()
      if #feed.events >= required_events or feed.complete then
        render_items()
        return
      end

      if feed.next_page > max_source_pages then
        feed.complete = true
        render_items()
        return
      end

      local source_page = feed.next_page
      request_opts.page = source_page

      provider.milestone_issues(
        project.repository,
        milestone.id,
        request_opts,
        function(events, err, cached, complete)
          if request_id ~= window.state.request_id
            or window.state.view ~= "activity"
            or window.state.activity_milestone ~= milestone
            or not internal.is_valid_win(window.state.win)
          then
            return
          end

          if err then
            internal.render_error(err)
            return
          end

          local source = events or {}

          for _, event in ipairs(source) do
            internal.add_project_issue(feed, event)
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

          ensure_items_page()
        end
      )
    end

    ensure_items_page()
  end
end

return M
