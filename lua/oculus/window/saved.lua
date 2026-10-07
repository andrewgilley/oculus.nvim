-- Saved activity items: the star on an item, global and source-specific lists,
-- and where each saved item came from. The entries themselves are persisted by
-- oculus.saved.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local M = {}

function M.setup(window, saved_view, internal)
  function saved_view.key(event)
    local key = internal.activity_dedupe_key(event)

    -- The last-resort dedupe key embeds a table address, which changes once a
    -- saved item is reloaded, so identify such items by their content instead.
    if key:find("table: 0x", 1, true) then
      local ok, encoded = pcall(vim.json.encode, event)
      key = ok and ("event:" .. vim.fn.sha256(encoded)) or key
    end

    return key
  end

  function saved_view.source(value)
    if type(value) ~= "table" then
      return nil
    end

    if value.kind == "project" or value.kind == "user" then
      return value
    end

    local provider = value.provider == "codeberg" and "codeberg" or "github"

    if type(value.repository) == "string" then
      return {
        kind = "project",
        provider = provider,
        repository = value.repository,
        name = value.name,
        path = value.path,
      }
    end

    if type(value.username) == "string" then
      return { kind = "user", provider = provider, username = value.username }
    end
  end

  -- The project or user an activity item came from: its recorded source on the
  -- saved page, otherwise the feed being viewed.
  function saved_view.source_for(event)
    local work = window.state.activity_work

    if work and type(event) == "table" and event.repo and event.repo.name then
      return {
        kind = "project",
        provider = work.provider,
        repository = event.repo.name,
      }
    end

    if window.state.activity_saved then
      local entry = window.state.saved_entries and window.state.saved_entries[event]

      if entry then
        return entry.source
      end

      if window.state.saved_expanded_source then
        return window.state.saved_expanded_source
      end

      return window.state.saved_scope
    end

    return saved_view.source(window.state.activity_project or window.state.contributor)
  end

  function saved_view.persist()
    local state_file = window.state.opts.state_file

    if type(state_file) ~= "string" or state_file == "" then
      return
    end

    local ok, err = require("oculus.storage").save(state_file, window.state.opts)

    if not ok then
      vim.notify(
        "Oculus could not save saved items: " .. tostring(err),
        vim.log.levels.ERROR
      )
    end
  end

  function saved_view.mark()
    if not internal.is_valid_buf(window.state.buf) then
      return
    end

    vim.api.nvim_buf_clear_namespace(window.state.buf, saved_view.ns, 0, -1)

    if window.state.view ~= "activity" then
      return
    end

    local store = require("oculus.saved")

    for line, title_line in pairs(window.state.activity_title_lines or {}) do
      local event = line == title_line
        and window.state.activity_events
        and window.state.activity_events[line]

      if type(event) == "table" then
        local entry = window.state.activity_saved
          and window.state.saved_entries
          and window.state.saved_entries[event]

        if entry or store.index(saved_view.key(event), saved_view.source_for(event), true) then
          pcall(vim.api.nvim_buf_set_extmark, window.state.buf, saved_view.ns, line - 1, 0, {
            virt_text = { { "★", "OculusSaved" } },
            virt_text_pos = "overlay",
            priority = 10001,
          })
        end
      end
    end
  end

  function saved_view.open(page, cursor, source)
    if not internal.is_valid_win(window.state.win) then
      return
    end

    if window.state.view == "directory" then
      window.state.directory_return = window.state.current_directory
    elseif window.state.view == "contributors" then
      window.state.directory_return = nil
    end

    internal.stop_activity_page_loading()
    window.state.request_id = window.state.request_id + 1
    window.state.view = "activity"
    window.state.activity_saved = true
    window.state.activity_work = nil
    window.state.activity_scope = "saved"
    source = saved_view.source(source)
    window.state.saved_scope = vim.deepcopy(source)
    window.state.activity_project = source and source.kind == "project" and source or nil
    window.state.contributor = source and source.kind == "user" and source or nil

    if source then
      window.state.community_view = source.kind == "project" and "projects" or "users"
      window.state.selected_project = window.state.activity_project
      window.state.selected_username = window.state.contributor and window.state.contributor.username
    end

    window.state.activity_issue_page = false
    window.state.activity_milestone = nil
    window.state.activity_commit_page = false
    window.state.activity_return = nil
    window.state.saved_expanded_source = nil
    local items = require("oculus.saved").items(source)

    local size = math.max(
      1,
      math.floor(tonumber(window.state.opts.results_limit) or 8)
    )

    local pages = math.max(1, math.ceil(#items / size))
    page = math.min(math.max(1, page or 1), pages)
    window.state.activity_page_size = size
    window.state.activity_page = page
    window.state.activity_loaded_pages = pages
    window.state.activity_has_past = page < pages
    window.state.saved_entries = {}
    local events = {}
    local all_events = {}

    for index, entry in ipairs(items) do
      all_events[#all_events + 1] = entry.event
      window.state.saved_entries[entry.event] = entry

      if index > (page - 1) * size and index <= page * size then
        events[#events + 1] = entry.event
      end
    end

    window.state.activity_source_events = all_events
    internal.render_activity(events, true, nil, { issue_page = false })

    if cursor and internal.is_valid_win(window.state.win) then
      local line_count = vim.api.nvim_buf_line_count(window.state.buf)

      pcall(vim.api.nvim_win_set_cursor, window.state.win, {
        math.min(cursor[1], line_count),
        0,
      })

      internal.update_activity_cursorline()
    end
  end

  function saved_view.open_scoped()
    local source

    if window.state.view == "contributors" or window.state.view == "directory" then
      local target = internal.target_on_cursor()
      source = saved_view.source(target and target.kind == "project" and target.project or target)
    elseif window.state.view == "activity" then
      if window.state.activity_saved then
        local cursor = vim.api.nvim_win_get_cursor(window.state.win)
        local event = window.state.activity_events and window.state.activity_events[cursor[1]]
        source = window.state.saved_scope or saved_view.source_for(event)
      else
        source = saved_view.source(window.state.activity_project or window.state.contributor)
      end
    elseif window.state.view == "milestones" then
      source = saved_view.source(window.state.project_milestones and window.state.project_milestones.project)
    elseif window.state.view == "boards" then
      source = saved_view.source(window.state.project_boards and window.state.project_boards.project)
    elseif window.state.view == "insights" then
      source = saved_view.source(window.state.project_insights and window.state.project_insights.project)
    end

    if not require("oculus.saved").scope_key(source) then
      vim.notify("Oculus: select a project or user to open its saved items", vim.log.levels.WARN)
      return
    end

    saved_view.open(nil, nil, source)
  end

  function saved_view.toggle()
    if window.state.view ~= "activity" or not internal.is_valid_win(window.state.win) then
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(window.state.win)
    local event = window.state.activity_events and window.state.activity_events[cursor[1]]

    if type(event) ~= "table" then
      vim.notify("Oculus: select an activity item to save", vim.log.levels.WARN)
      return
    end

    local store = require("oculus.saved")

    local entry = window.state.activity_saved
      and window.state.saved_entries
      and window.state.saved_entries[event]

    local key = entry and entry.key or saved_view.key(event)
    local source = entry and entry.source or saved_view.source_for(event)

    if not store.remove(key, source, true) then
      store.add({
        key = key,
        saved_at = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        source = vim.deepcopy(source),
        event = vim.deepcopy(event),
      })
    end

    saved_view.persist()

    if window.state.activity_saved and not window.state.activity_commit_page then
      saved_view.open(window.state.activity_page, cursor, window.state.saved_scope)
    else
      saved_view.mark()
    end
  end
end

return M
