-- My work: review requests, your pull requests, and the issues and pull
-- requests assigned to you or mentioning you, each category listed like an
-- activity feed and paged the same way.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local browser = require("oculus.browser")
local navigation = require("oculus.navigation")
local M = {}

function M.setup(window, work_view, internal)
  work_view.categories = {
    {
      key = "review_requested",
      label = "Review requests",
      description = "Open pull requests waiting for your review",
      github_url = "https://github.com/pulls/review-requested",
      codeberg_url = "https://codeberg.org/pulls?type=review_requested",
    },
    {
      key = "authored",
      label = "Your pull requests",
      description = "Open pull requests you opened",
      github_url = "https://github.com/pulls",
      codeberg_url = "https://codeberg.org/pulls?type=created_by",
    },
    {
      key = "assigned",
      label = "Assigned to you",
      description = "Open issues and pull requests assigned to you",
      github_url = "https://github.com/issues/assigned",
      codeberg_url = "https://codeberg.org/issues?type=assigned",
    },
    {
      key = "mentioned",
      label = "Mentions",
      description = "Open issues and pull requests that mention you",
      github_url = "https://github.com/issues/mentioned",
      codeberg_url = "https://codeberg.org/issues?type=mentioned",
    },
  }

  -- GitHub always shows, with a sign-in hint when there is no token; Codeberg
  -- shows once it has a token or a tracked project or user.
  function work_view.providers()
    local auth = require("oculus.auth")
    local providers = { "github" }
    local uses_codeberg = auth.codeberg_token(window.state.opts) ~= nil

    for _, list in ipairs({
      window.state.opts.projects or {},
      window.state.contributors or window.state.opts.contributors or {},
    }) do
      for _, entry in ipairs(list) do
        uses_codeberg = uses_codeberg
          or (type(entry) == "table" and entry.provider == "codeberg")
      end
    end

    if uses_codeberg then
      providers[#providers + 1] = "codeberg"
    end

    return providers
  end

  function work_view.header(work, suffix)
    local viewer = work.viewer and ("@" .. work.viewer.login .. " · ") or ""

    return {
      "",
      "  MY WORK",
      ("  %s · %s%s%s"):format(
        work.label,
        viewer,
        internal.provider_name(work),
        suffix or ""
      ),
    }
  end

  function work_view.web_url(entry)
    return entry.provider == "codeberg"
        and entry.category.codeberg_url
      or entry.category.github_url
  end

  function work_view.count_text(entry)
    if entry.error then
      return "!"
    elseif entry.loading or not entry.loaded then
      return "…"
    elseif entry.total then
      return tostring(entry.total)
    end

    return tostring(#entry.events) .. (entry.complete and "" or "+")
  end

  function work_view.entries()
    local entries = {}

    for _, forge in ipairs(window.state.work_lists and window.state.work_lists.forges or {}) do
      for _, entry in ipairs(forge.entries) do
        entries[#entries + 1] = entry
      end
    end

    return entries
  end

  function work_view.preview_items(entry, width)
    local forge = entry.forge

    local items = {
      [2] = { entry.category.label:upper(), "Title" },
      [4] = { entry.category.description, "Identifier" },
      [5] = {
        forge.viewer
            and ("@%s on %s"):format(forge.viewer.login, internal.provider_name(entry))
          or internal.provider_name(entry),
        "Comment",
      },
    }

    if entry.error then
      items[7] = { entry.error, "DiagnosticError" }
      return items
    elseif entry.loading or not entry.loaded then
      items[7] = { "Loading…", "Comment" }
      return items
    end

    local count = work_view.count_text(entry)

    items[7] = {
      count == "0" and "Nothing open"
        or (count .. " open"),
      "Comment",
    }

    local line = 9
    local limit = math.max(0, vim.api.nvim_win_get_height(window.state.win) - line - 1)

    for index, event in ipairs(entry.events) do
      if index > limit then
        break
      end

      local issue = event.payload and event.payload.issue or {}

      items[line] = {
        internal.trim_to_width(
          ("%s#%s %s"):format(
            event.repo and event.repo.name or "",
            tostring(issue.number or "?"),
            tostring(issue.title or "")
          ),
          width
        ),
        "OculusActivityPreview",
      }

      line = line + 1
    end

    return items
  end

  function work_view.queue_preview(entry)
    if window.state.view ~= "work" or not entry then
      return
    end

    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local preview_width = math.max(15, window_width - left_width - 5)
    window.state.preview_key = "work:" .. entry.key
    internal.render_preview_panel(work_view.preview_items(entry, preview_width))
  end

  function work_view.selected_index(entries)
    for index, entry in ipairs(entries) do
      if entry.key == window.state.selected_work then
        return index
      end
    end

    return entries[1] and 1 or nil
  end

  function work_view.render()
    local list = window.state.work_lists

    if not list or not internal.is_valid_win(window.state.win) then
      return
    end

    internal.stop_activity_page_loading()
    internal.close_activity_footer()
    window.state.view = "work"
    window.state.activity_work = nil
    window.state.line_targets = {}
    window.state.preview_key = nil
    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local window_height = vim.api.nvim_win_get_height(window.state.win)
    local sidebar_visible = internal.is_sidebar_visible()

    local lines = {
      "",
      "  MY WORK",
      "  Open issues and pull requests that involve you",
      "",
    }

    local headings = {}
    local comment_lines = {}
    local error_lines = {}
    local rows = {}

    for _, forge in ipairs(list.forges) do
      if #rows > 0 then
        rows[#rows + 1] = { kind = "blank" }
      end

      rows[#rows + 1] = {
        kind = "heading",
        text = internal.provider_name(forge):upper()
          .. (forge.viewer and (" · @" .. forge.viewer.login) or ""),
      }

      for _, text in ipairs(internal.wrapped_preview_text(forge.message, left_width - 3, 3)) do
        rows[#rows + 1] = {
          kind = forge.signed_in and "error" or "comment",
          text = text,
        }
      end

      for _, entry in ipairs(forge.entries) do
        rows[#rows + 1] = { kind = "entry", entry = entry }
      end
    end

    local entries = work_view.entries()
    local selected_index = work_view.selected_index(entries)
    local selected = selected_index and entries[selected_index] or nil
    window.state.selected_work = selected and selected.key or nil
    local selected_row = 1

    for index, row in ipairs(rows) do
      if row.entry and row.entry == selected then
        selected_row = index
        break
      end
    end

    local capacity = math.max(
      3,
      window_height - #lines - (sidebar_visible and 0 or 2)
    )

    local offset = math.min(
      math.max(1, window.state.work_offset or 1),
      math.max(1, #rows - capacity + 1)
    )

    if selected_row < offset then
      offset = selected_row
    elseif selected_row >= offset + capacity then
      offset = selected_row - capacity + 1
    end

    -- Keep a forge's heading (and sign-in message) in view above its first
    -- category while the selection still fits.
    while offset > 1
      and rows[offset - 1].kind ~= "blank"
      and rows[offset - 1].kind ~= "entry"
      and selected_row < offset + capacity - 1
    do
      offset = offset - 1
    end

    window.state.work_offset = offset

    for index = offset, math.min(#rows, offset + capacity - 1) do
      local row = rows[index]

      if row.kind == "blank" then
        lines[#lines + 1] = ""
      elseif row.kind == "heading" then
        lines[#lines + 1] = "  " .. row.text
        headings[#headings + 1] = #lines
      elseif row.kind == "comment" or row.kind == "error" then
        lines[#lines + 1] = "  " .. internal.trim_to_width(row.text, left_width - 3)

        if row.kind == "error" then
          error_lines[#error_lines + 1] = #lines
        else
          comment_lines[#comment_lines + 1] = #lines
        end
      else
        local count = work_view.count_text(row.entry)
        local label_width = math.max(4, left_width - 3 - #count - 2)

        lines[#lines + 1] = internal.pad_cell(
          "  " .. internal.pad_cell(internal.trim_to_width(row.entry.category.label, label_width), label_width)
            .. " " .. count,
          left_width
        )

        window.state.line_targets[#lines] = { kind = "work", entry = row.entry }
      end
    end

    local separator_line = nil

    if not sidebar_visible then
      while #lines < window_height - 2 do
        lines[#lines + 1] = ""
      end

      lines[#lines + 1] = "  " .. string.rep("─", math.max(1, left_width - 2))
      separator_line = #lines
      lines[#lines + 1] = internal.pad_cell("", left_width)
    else
      while #lines < window_height do
        lines[#lines + 1] = ""
      end
    end

    internal.set_lines(lines)
    window.state.list_footer_line = nil
    window.state.list_footer_text = nil
    vim.wo[window.state.win].cursorline = false
    internal.highlight(2, 2, -1, "Title")
    internal.highlight(3, 2, -1, "Comment")

    if separator_line then
      internal.highlight(separator_line, 2, -1, "WinSeparator")
    end

    for _, line in ipairs(headings) do
      internal.highlight(line, 2, -1, "OculusSectionTitle")
    end

    for _, line in ipairs(comment_lines) do
      internal.highlight(line, 2, -1, "Comment")
    end

    for _, line in ipairs(error_lines) do
      internal.highlight(line, 2, -1, "DiagnosticError")
    end

    local selected_line

    for line, target in pairs(window.state.line_targets) do
      internal.highlight(line, 2, -1, "Identifier")

      if target.entry == selected then
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
      work_view.queue_preview(selected)
    else
      internal.render_preview_panel({ [2] = { "MY WORK", "Title" } })
    end

    internal.update_contributor_selection()
    internal.render_sidebar()
  end

  function work_view.select_adjacent(direction)
    local entries = work_view.entries()
    local index = work_view.selected_index(entries)

    if not index then
      return
    end

    index = ((index - 1 + direction) % #entries) + 1
    window.state.selected_work = entries[index].key
    work_view.render()
  end

  -- Rerender the list after a request finishes, unless the user has moved on.
  function work_view.refresh(list)
    if window.state.work_lists == list
      and window.state.view == "work"
      and internal.is_valid_win(window.state.win)
    then
      work_view.render()
    end
  end

  function work_view.load(force)
    local auth = require("oculus.auth")
    window.state.request_id = window.state.request_id + 1
    local list = { forges = {} }
    window.state.work_lists = list

    local request_opts = vim.tbl_extend(
      "force",
      window.state.opts,
      { force = force or false }
    )

    for _, provider in ipairs(work_view.providers()) do
      local forge = {
        provider = provider,
        entries = {},
        signed_in = auth.token(provider, window.state.opts) ~= nil,
        viewer = auth.cached_viewer(provider, window.state.opts),
      }

      list.forges[#list.forges + 1] = forge

      if not forge.signed_in then
        forge.message = "Not signed in: " .. auth.sign_in_hint(provider)
      else
        auth.viewer(provider, request_opts, function(viewer, err)
          forge.viewer = viewer or forge.viewer
          forge.message = not viewer and err and tostring(err) or nil
          work_view.refresh(list)
        end)

        local client = provider == "codeberg" and codeberg or github

        for _, category in ipairs(work_view.categories) do
          local entry = {
            key = provider .. ":" .. category.key,
            provider = provider,
            category = category,
            forge = forge,
            loading = true,
            events = {},
          }

          forge.entries[#forge.entries + 1] = entry

          client.work_items(category.key, request_opts, function(
            events,
            err,
            _,
            complete,
            total
          )
            entry.loading = false
            entry.loaded = events ~= nil
            entry.error = err and tostring(err) or nil
            entry.events = events or {}
            entry.complete = complete == true
            entry.total = total
            work_view.refresh(list)
          end)
        end
      end
    end

    work_view.render()
  end

  function work_view.open()
    if not internal.is_valid_win(window.state.win) then
      return
    end

    window.state.work_return = window.state.view == "directory"
        and window.state.current_directory
      or nil

    work_view.load(false)
  end

  -- One work category as an activity feed, paged like the milestone feed.
  function work_view.load_items(entry, force, page)
    local previous_page = window.state.activity_page or 1

    local work = {
      key = entry.key,
      provider = entry.provider,
      category = entry.category,
      label = entry.category.label,
      viewer = entry.forge and entry.forge.viewer or entry.viewer,
    }

    local preserve_activity_page = page ~= nil
      and window.state.view == "activity"
      and window.state.activity_work
      and window.state.activity_work.key == work.key
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
      window.state.activity_work = work
      window.state.activity_error = nil
      internal.start_activity_page_loading()
    else
      internal.render_loading({ kind = "work", work = work })
    end

    local client = work.provider == "codeberg" and codeberg or github

    local request_opts = vim.tbl_extend(
      "force",
      window.state.opts,
      { force = force or false, per_page = 50 }
    )

    local feed = window.state.work_items_feed

    if force or not feed or feed.key ~= work.key then
      feed = {
        key = work.key,
        events = {},
        seen = {},
        next_page = 1,
        complete = false,
        cached = true,
      }

      window.state.work_items_feed = feed
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

      client.work_items(work.category.key, request_opts, function(
        events,
        err,
        cached,
        complete
      )
        if request_id ~= window.state.request_id
          or window.state.view ~= "activity"
          or not window.state.activity_work
          or window.state.activity_work.key ~= work.key
          or not internal.is_valid_win(window.state.win)
        then
          return
        end

        if err then
          internal.render_error(err)
          return
        end

        local source = events or {}

        -- Items span repositories, so issue numbers alone are not unique.
        for _, event in ipairs(source) do
          local key = tostring(event.id)

          if not feed.seen[key] then
            feed.seen[key] = true
            feed.events[#feed.events + 1] = event
          end
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
      end)
    end

    ensure_items_page()
  end
end

return M
