-- A project's official devlog, or a tracked user's blog: its posts listed like
-- milestones, and a reader that shows one post and inspects the pull requests,
-- issues and commits the post refers to.
local devlog = require("oculus.devlog")
local navigation = require("oculus.navigation")
local M = {}

local reader_ns = vim.api.nvim_create_namespace("oculus_devlog_post")
local current_ns = vim.api.nvim_create_namespace("oculus_devlog_reference")

-- The reader's text column is capped so long lines stay readable in a wide
-- window; the rest of the window is left blank.
local max_text_width = 100
local margin = "  "
local header_lines = 4

local kind_names = {
  pull_request = "pull request",
  issue = "issue",
  commit = "commit",
}

local highlight_links = {
  OculusDevlogHeading = "Title",
  OculusDevlogStrong = "@markup.strong",
  OculusDevlogEmphasis = "@markup.italic",
  OculusDevlogCode = "@markup.raw",
  OculusDevlogLink = "Underlined",
  OculusDevlogReference = "Special",
  OculusDevlogReferenceCurrent = "Visual",
  OculusDevlogQuote = "Comment",
  OculusDevlogMuted = "Comment",
  OculusDevlogBullet = "Comment",
}

function M.setup(window, devlog_view, internal)
  local state = window.state

  -- A devlog belongs to a project; a blog, shown the same way, to a tracked
  -- user.
  local function is_user(source)
    return type(source) == "table" and type(source.username) == "string"
  end

  local function source_title(source)
    return is_user(source) and ("@" .. source.username) or internal.project_title(source)
  end

  local function noun(source)
    return is_user(source) and "blog" or "devlog"
  end

  local function define_highlights()
    for group, link in pairs(highlight_links) do
      vim.api.nvim_set_hl(0, group, { link = link, default = true })
    end
  end

  -- The list ------------------------------------------------------------------

  local function list_posts()
    local list = state.project_devlog
    return list and list.posts or {}
  end

  function devlog_view.selected_index(posts)
    for index, post in ipairs(posts or {}) do
      if post.id == state.selected_devlog_post then
        return index
      end
    end

    return posts and posts[1] and 1 or nil
  end

  function devlog_view.preview_items(post, width)
    local items = { [2] = { "POST", "Title" } }
    local row = 4

    for _, line in ipairs(internal.wrapped_preview_text(post.title, width, 3)) do
      items[row] = { line, "Identifier" }
      row = row + 1
    end

    local meta = {}

    if post.date then
      meta[#meta + 1] = post.date
    end

    if post.author then
      meta[#meta + 1] = post.author
    end

    if #meta > 0 then
      items[row] = { table.concat(meta, " · "), "Comment" }
      row = row + 1
    end

    if post.url then
      items[row] = { devlog.display_url(post.url), "Comment" }
    end

    return items
  end

  function devlog_view.queue_preview(post)
    if state.view ~= "devlog" or not post then
      return
    end

    local key = "devlog:" .. tostring(post.id)

    if state.preview_key == key then
      return
    end

    state.preview_key = key
    local window_width = vim.api.nvim_win_get_width(state.win)
    local left_width = internal.preview_left_width(window_width)
    local preview_width = math.max(15, window_width - left_width - 5)

    internal.render_preview_panel(devlog_view.preview_items(post, preview_width))
  end

  local function source_label(list)
    if list.feed and list.feed.title and list.feed.title ~= "" then
      return list.feed.title
    end

    return list.feed_url and devlog.display_url(list.feed_url) or nil
  end

  function devlog_view.render()
    local list = state.project_devlog

    if not list or not internal.is_valid_win(state.win) then
      return
    end

    define_highlights()
    internal.stop_activity_page_loading()
    internal.close_activity_footer()
    state.view = "devlog"
    state.line_targets = {}
    state.preview_key = nil
    local project = list.project
    local window_width = vim.api.nvim_win_get_width(state.win)
    local left_width = internal.preview_left_width(window_width)
    local window_height = vim.api.nvim_win_get_height(state.win)
    local sidebar_visible = internal.is_sidebar_visible()
    local subtitle = { source_title(project) }
    local source = source_label(list)

    if source then
      subtitle[#subtitle + 1] = source
    end

    local lines = {
      "",
      "  " .. noun(project):upper() .. (list.loading and list.posts and " · refreshing…" or ""),
      internal.trim_to_width("  " .. table.concat(subtitle, " · "), left_width - 1),
      "",
    }

    local comment_lines = {}
    local error_line
    local posts = list.posts or {}

    local function comment(text)
      lines[#lines + 1] = internal.trim_to_width("  " .. text, left_width - 1)
      comment_lines[#comment_lines + 1] = #lines
    end

    if list.loading and not list.posts then
      comment(list.feed_url and "Loading posts…" or "Finding the devlog…")
    elseif not list.feed_url then
      comment(is_user(project) and "No blog found for this user." or "No devlog found for this project.")

      if list.missing then
        comment(list.missing)
      end

      lines[#lines + 1] = ""
      comment(("e set the %s's feed URL"):format(noun(project)))
    elseif list.error and #posts == 0 then
      lines[#lines + 1] = "  Could not load the " .. noun(project)
      error_line = #lines
      comment(list.error)
      lines[#lines + 1] = ""
      comment(("r retry   e set the %s's feed URL"):format(noun(project)))
    elseif #posts == 0 then
      comment("The devlog has no posts.")
    else
      local selected_index = devlog_view.selected_index(posts)
      state.selected_devlog_post = posts[selected_index].id

      local capacity = math.max(
        3,
        window_height - #lines - (sidebar_visible and 0 or 2)
      )

      local offset = math.min(
        math.max(1, state.devlog_offset or 1),
        math.max(1, #posts - capacity + 1)
      )

      if selected_index < offset then
        offset = selected_index
      elseif selected_index >= offset + capacity then
        offset = selected_index - capacity + 1
      end

      state.devlog_offset = offset

      for index = offset, math.min(#posts, offset + capacity - 1) do
        local post = posts[index]
        local date = post.date or "          "

        lines[#lines + 1] = internal.pad_cell(
          internal.trim_to_width("  " .. date .. "  " .. post.title, left_width - 1),
          left_width
        )

        state.line_targets[#lines] = { kind = "devlog_post", post = post }
      end
    end

    while #lines < window_height do
      lines[#lines + 1] = ""
    end

    internal.set_lines(lines)
    state.list_footer_line = nil
    state.list_footer_text = nil
    vim.wo[state.win].cursorline = false
    internal.highlight(2, 2, -1, "Title")
    internal.highlight(3, 2, -1, "Comment")

    for _, line in ipairs(comment_lines) do
      internal.highlight(line, 2, -1, "Comment")
    end

    if error_line then
      internal.highlight(error_line, 2, -1, "DiagnosticError")
    end

    local selected_line

    for line, target in pairs(state.line_targets) do
      internal.highlight(line, 2, 12, "Comment")
      internal.highlight(line, 14, -1, "Identifier")

      if target.post.id == state.selected_devlog_post then
        selected_line = line
      end
    end

    if selected_line then
      vim.api.nvim_win_set_cursor(state.win, { selected_line, 0 })
      devlog_view.queue_preview(state.line_targets[selected_line].post)
    else
      internal.render_preview_panel({ [2] = { "POST", "Title" } })
    end

    internal.update_contributor_selection()
    internal.render_sidebar()
  end

  function devlog_view.select_adjacent(direction)
    local posts = list_posts()
    local index = devlog_view.selected_index(posts)

    if not index then
      return
    end

    index = ((index - 1 + direction) % #posts) + 1
    state.selected_devlog_post = posts[index].id
    devlog_view.render()
  end

  local function save_feed(project, entry)
    local key = devlog.project_key(project)
    state.opts.devlog_feeds = state.opts.devlog_feeds or {}
    state.opts.devlog_feeds[key] = entry

    if not state.opts.state_file then
      return
    end

    local ok, err = require("oculus.storage").save(state.opts.state_file, state.opts)

    if not ok then
      vim.notify("Oculus could not save the devlog feed: " .. tostring(err), vim.log.levels.ERROR)
    end
  end

  function devlog_view.load(project, force)
    state.request_id = state.request_id + 1
    local request_id = state.request_id
    local key = devlog.project_key(project)
    local previous = state.project_devlog

    if not previous or previous.key ~= key then
      state.selected_devlog_post = nil
      state.devlog_offset = 1
      previous = nil
    end

    state.project_devlog = {
      key = key,
      project = project,
      loading = true,
      feed_url = previous and previous.feed_url,
      feed = previous and previous.feed,
      posts = previous and previous.posts,
    }

    devlog_view.render()

    local opts = vim.tbl_extend("force", state.opts, { force = force or false })

    local function stale()
      return request_id ~= state.request_id
        or state.view ~= "devlog"
        or not internal.is_valid_win(state.win)
    end

    local function attempt(rediscover)
      opts.rediscover = rediscover

      devlog.resolve_feed(project, opts, function(url, source, missing)
        if stale() then
          return
        end

        local list = state.project_devlog

        if not url then
          list.loading = false
          list.feed_url = nil
          list.posts = nil
          list.missing = missing
          devlog_view.render()
          return
        end

        list.feed_url = url
        list.source = source

        -- Discovery takes several requests, so remember what it found.
        if source == "discovered" then
          local saved = (state.opts.devlog_feeds or {})[key]

          if not saved or saved.url ~= url then
            save_feed(project, { url = url, discovered = true })
          end
        end

        devlog.fetch_feed(url, opts, function(feed, err)
          if stale() then
            return
          end

          -- A remembered feed that stopped working is looked for afresh.
          if not feed and source == "discovered" and not rediscover then
            save_feed(project, nil)
            opts.force = true
            attempt(true)
            return
          end

          local function show()
            if stale() then
              return
            end

            list.loading = false
            list.error = err and tostring(err) or nil

            if feed then
              list.feed = feed
              list.posts = feed.posts
            end

            devlog_view.render()
          end

          -- Changelog pages name versions but not dates; the project's
          -- releases of those versions have them.
          if feed then
            devlog.date_releases(feed, project, opts, show)
          else
            show()
          end
        end)
      end)
    end

    attempt(false)
  end

  -- Open the devlog of `project`, returning to the current view on back.
  function devlog_view.open(project)
    if not project or (type(project.repository) ~= "string" and not is_user(project)) then
      return
    end

    devlog_view.close_post(false)

    -- Switching to another project's devlog keeps the way back out.
    if state.view == "devlog" then
      state.devlog_resume = nil
      devlog_view.load(project, false)
      return
    end

    local target = state.view ~= "activity"
        and internal.target_on_cursor()
      or nil

    state.devlog_return = {
      view = state.view,
      project = state.activity_project,
      contributor = state.contributor,
      events = state.events,
      cached = state.activity_cached,
      notice = state.activity_notice,
      page = state.activity_page,
      loaded_pages = state.activity_loaded_pages,
      source_events = state.activity_source_events,
      has_past = state.activity_has_past,
      issue_page = state.activity_issue_page,
      current_directory = state.current_directory,
      tracking_index = type(target) == "table" and target.tracking_index or nil,
      cursor = internal.is_valid_win(state.win)
          and vim.api.nvim_win_get_cursor(state.win)
        or nil,
    }

    state.devlog_resume = nil
    devlog_view.load(project, false)
  end

  -- Ask for the feed URL of the devlog being shown. An empty answer forgets
  -- the saved URL so the devlog is looked for again.
  function devlog_view.prompt_feed()
    local list = state.project_devlog

    if state.view ~= "devlog" or not list then
      return
    end

    local project = list.project

    vim.ui.input({
      prompt = ("%s feed URL for %s (empty to find it again): "):format(
        is_user(project) and "Blog" or "Devlog",
        source_title(project)
      ),
      default = list.feed_url or "",
    }, function(input)
      if input == nil then
        return
      end

      input = vim.trim(input)

      if input == "" then
        save_feed(project, nil)
      elseif not input:match("^https?://") then
        vim.notify("Oculus: a devlog feed URL starts with http:// or https://", vim.log.levels.WARN)
        return
      else
        save_feed(project, { url = input })
      end

      if state.view == "devlog" and state.project_devlog == list then
        devlog_view.load(project, true)
      end
    end)
  end

  function devlog_view.browser_url()
    local target = internal.target_on_cursor()

    if type(target) == "table" and target.kind == "devlog_post" then
      return target.post.url
    end

    local list = state.project_devlog
    return list and list.feed and list.feed.link or nil
  end

  -- The reader ----------------------------------------------------------------

  local function reader()
    local current = state.devlog_reader

    if current and internal.is_valid_win(current.win) then
      return current
    end

    return nil
  end

  function devlog_view.owns(win)
    local current = state.devlog_reader
    return current ~= nil
      and win ~= nil
      and (current.opening or win == current.win or win == current.footer_win)
  end

  local function text_width(current)
    local width = vim.api.nvim_win_get_width(current.win)
    return math.max(20, math.min(max_text_width, width - #margin * 2))
  end

  local function footer_config(current)
    local config = vim.api.nvim_win_get_config(current.win)

    return {
      relative = "editor",
      width = vim.api.nvim_win_get_width(current.win),
      height = 2,
      row = (tonumber(config.row) or 0) + vim.api.nvim_win_get_height(current.win) - 1,
      col = (tonumber(config.col) or 0) + 1,
      style = "minimal",
      focusable = false,
      zindex = (config.zindex or 55) + 1,
    }
  end

  -- The reference whose text is under the cursor.
  local function reference_at_cursor(current)
    if not current.doc then
      return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(current.win)
    local line = cursor[1] - current.body_start
    local col = cursor[2] - #margin

    for _, reference in ipairs(current.doc.references) do
      for _, segment in ipairs(reference.segments) do
        if segment.line == line and col >= segment.start and col < segment.finish then
          return reference
        end
      end
    end

    return nil
  end

  -- The reference under the cursor, else the one on the cursor's line nearest
  -- to it.
  local function reference_near_cursor(current)
    local exact = reference_at_cursor(current)

    if exact or not current.doc then
      return exact
    end

    local cursor = vim.api.nvim_win_get_cursor(current.win)
    local line = cursor[1] - current.body_start
    local col = cursor[2] - #margin
    local best
    local best_distance

    for _, reference in ipairs(current.doc.references) do
      for _, segment in ipairs(reference.segments) do
        if segment.line == line then
          local distance = col < segment.start and segment.start - col or col - segment.finish + 1

          if not best_distance or distance < best_distance then
            best = reference
            best_distance = distance
          end
        end
      end
    end

    return best
  end

  local function link_at_cursor(current)
    if not current.doc then
      return nil
    end

    local cursor = vim.api.nvim_win_get_cursor(current.win)
    local line = cursor[1] - current.body_start
    local col = cursor[2] - #margin

    for _, link in ipairs(current.doc.links) do
      if link.line == line and col >= link.start and col < link.finish then
        return link.url
      end
    end

    return nil
  end

  local function reference_count(current)
    local seen = {}
    local count = 0

    for _, reference in ipairs(current.doc and current.doc.references or {}) do
      if not seen[reference.label] then
        seen[reference.label] = true
        count = count + 1
      end
    end

    return count
  end

  local function render_footer(current)
    if not current or not internal.is_valid_win(current.win) then
      return
    end

    local nav = navigation.resolve(state.opts)
    local config = footer_config(current)
    local commands = ("  %s inspect   ⇥ next reference   b browser   r refresh   %s/q back"):format(
      nav.inspect,
      nav.left
    )

    local status
    local status_group = "Comment"

    if current.inspecting then
      status = ("%s inspecting %s"):format(current.inspecting.frame or "⠋", current.inspecting.label)
      status_group = "DiagnosticInfo"
    else
      local reference = reference_at_cursor(current)

      if reference then
        status = reference.label
        status_group = "OculusDevlogReference"
      elseif current.doc then
        local count = reference_count(current)
        status = count == 1 and "1 activity reference"
          or (count == 0 and "no activity references" or (count .. " activity references"))
      end
    end

    local line = commands

    if status then
      local gap = config.width - vim.api.nvim_strwidth(commands) - vim.api.nvim_strwidth(status) - 2

      if gap < 3 then
        line = "  " .. status
      else
        line = commands .. string.rep(" ", gap) .. status
      end
    end

    local buf = current.footer_buf

    if not internal.is_valid_buf(buf) then
      buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].bufhidden = "wipe"
      vim.bo[buf].buftype = "nofile"
      vim.bo[buf].swapfile = false
      vim.bo[buf].filetype = "oculus"
      current.footer_buf = buf
    end

    vim.bo[buf].modifiable = true

    vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
      "  " .. string.rep("─", math.max(1, config.width - 4)),
      line,
    })

    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, reader_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, reader_ns, "Comment", 0, 2, -1)

    if line:sub(1, #commands) == commands then
      vim.api.nvim_buf_add_highlight(buf, reader_ns, "OculusNormal", 1, 2, #commands)
    end

    if status then
      vim.api.nvim_buf_add_highlight(buf, reader_ns, status_group, 1, #line - #status, -1)
    end

    if internal.is_valid_win(current.footer_win) then
      vim.api.nvim_win_set_config(current.footer_win, config)
    else
      current.footer_win = vim.api.nvim_open_win(buf, false, config)
    end

    local win = current.footer_win
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = false
    vim.wo[win].winhighlight = "Normal:OculusNormal,NormalFloat:OculusNormal"
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    internal.use_window_highlights(win)
  end

  -- Mark the reference under the cursor and keep the cursor above the footer.
  local function follow_cursor(current)
    vim.api.nvim_buf_clear_namespace(current.buf, current_ns, 0, -1)
    local reference = reference_at_cursor(current)

    if reference then
      for _, segment in ipairs(reference.segments) do
        vim.api.nvim_buf_set_extmark(current.buf, current_ns, current.body_start + segment.line - 1, #margin + segment.start, {
          end_col = #margin + segment.finish,
          hl_group = "OculusDevlogReferenceCurrent",
          priority = 300,
        })
      end
    end

    vim.api.nvim_win_call(current.win, function()
      local visible = vim.api.nvim_win_get_height(current.win) - 2
      local row = vim.fn.winline()

      if row > visible then
        local view = vim.fn.winsaveview()
        view.topline = view.topline + row - visible
        vim.fn.winrestview(view)
      end
    end)

    render_footer(current)
  end

  local function draw(current, cursor)
    if not internal.is_valid_buf(current.buf) then
      return
    end

    local post = current.post
    local width = text_width(current)
    local meta = {}

    if post.date then
      meta[#meta + 1] = post.date
    end

    if post.author then
      meta[#meta + 1] = post.author
    end

    meta[#meta + 1] = source_title(current.project) .. " " .. noun(current.project)

    local lines = {
      "",
      margin .. post.title,
      margin .. table.concat(meta, " · "),
      "",
    }

    local notice
    local notice_group = "Comment"

    if current.loading then
      notice = "Loading the post…"
    elseif current.error then
      notice = ("Could not load the whole post (%s); showing the feed's summary."):format(current.error)
      notice_group = "DiagnosticWarn"
    end

    local notice_lines = {}

    if notice then
      for _, text in ipairs(internal.wrapped_preview_text(notice, width, 4)) do
        lines[#lines + 1] = margin .. text
        notice_lines[#notice_lines + 1] = #lines
      end

      lines[#lines + 1] = ""
    end

    current.body_start = #lines

    if current.html then
      current.doc = devlog.render(current.html, {
        width = width,
        base_url = current.base_url,
        -- "#123" means an issue of the post's project; a person has none.
        project = not is_user(current.project) and current.project or nil,
        projects = state.opts.projects,
        skip_title = post.title,
        author = post.author,
        whole = post.whole,
      })

      for _, line in ipairs(current.doc.lines) do
        lines[#lines + 1] = line == "" and "" or (margin .. line)
      end

      if #current.doc.lines == 0 and not current.loading then
        lines[#lines + 1] = margin .. "This post has no text."
        notice_lines[#notice_lines + 1] = #lines
      end
    end

    -- After the post, each pull request, issue and commit it mentions, once.
    -- An entry is a reference of its own: Tab stops on it and it inspects.
    local section_heading
    local section_labels = {}
    current.section_start = nil

    if current.doc and not current.loading then
      local unique = {}
      local seen = {}

      for _, reference in ipairs(current.doc.references) do
        if not seen[reference.label] then
          seen[reference.label] = true
          unique[#unique + 1] = reference
        end
      end

      lines[#lines + 1] = ""
      lines[#lines + 1] = ""
      lines[#lines + 1] = margin .. ("REFERENCED ACTIVITY (%d)"):format(#unique)
      section_heading = #lines
      lines[#lines + 1] = ""
      current.section_start = #lines + 1

      if #unique == 0 then
        lines[#lines + 1] = margin .. "The post mentions no pull requests, issues or commits."
        notice_lines[#notice_lines + 1] = #lines
      end

      for _, reference in ipairs(unique) do
        local parts = {}

        -- The words the post linked, when they say more than the address.
        for _, segment in ipairs(reference.segments) do
          local body_line = current.doc.lines[segment.line] or ""
          parts[#parts + 1] = body_line:sub(segment.start + 1, segment.finish)
        end

        local context = table.concat(parts, " ")

        -- A bare number, SHA or address only repeats the reference.
        if not reference.url
          or context:match("^https?://")
          or context:match("^#?%d+$")
          or context:match("^%x+$")
        then
          context = ""
        end

        local text = internal.trim_to_width(
          margin .. reference.label .. "  " .. (kind_names[reference.kind] or "issue or pull request")
            .. (context ~= "" and (" · " .. context) or ""),
          width + #margin
        )

        lines[#lines + 1] = text

        reference.segments[#reference.segments + 1] = {
          line = #lines - current.body_start,
          start = 0,
          finish = #text - #margin,
          listed = true,
        }

        section_labels[#section_labels + 1] = { #lines, #reference.label }
      end
    end

    -- Room for the last lines to scroll above the footer.
    lines[#lines + 1] = ""
    lines[#lines + 1] = ""

    local buf = current.buf
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.api.nvim_buf_clear_namespace(buf, reader_ns, 0, -1)
    vim.api.nvim_buf_add_highlight(buf, reader_ns, "Title", 1, #margin, -1)
    vim.api.nvim_buf_add_highlight(buf, reader_ns, "Comment", 2, #margin, -1)

    for _, line in ipairs(notice_lines) do
      vim.api.nvim_buf_add_highlight(buf, reader_ns, notice_group, line - 1, #margin, -1)
    end

    if section_heading then
      vim.api.nvim_buf_add_highlight(buf, reader_ns, "OculusSectionTitle", section_heading - 1, #margin, -1)
    end

    for _, entry in ipairs(section_labels) do
      vim.api.nvim_buf_add_highlight(buf, reader_ns, "Comment", entry[1] - 1, #margin, -1)
      vim.api.nvim_buf_add_highlight(buf, reader_ns, "OculusDevlogReference", entry[1] - 1, #margin, #margin + entry[2])
    end

    for _, item in ipairs(current.doc and current.doc.highlights or {}) do
      vim.api.nvim_buf_add_highlight(
        buf,
        reader_ns,
        item[4],
        current.body_start + item[1] - 1,
        #margin + item[2],
        #margin + item[3]
      )
    end

    -- "body" puts the cursor at the start of the post's text.
    if cursor == "body" then
      cursor = { current.body_start + 1, #margin }
    end

    if cursor then
      local line = math.max(1, math.min(cursor[1], vim.api.nvim_buf_line_count(buf)))
      pcall(vim.api.nvim_win_set_cursor, current.win, { line, cursor[2] or 0 })
    end

    follow_cursor(current)
  end

  local function fetch(current, force)
    current.loading = true
    current.error = nil
    draw(current)
    local opts = vim.tbl_extend("force", state.opts, { force = force or false })

    devlog.post_html(current.post, opts, function(html, base_url, err)
      if state.devlog_reader ~= current or not internal.is_valid_buf(current.buf) then
        return
      end

      current.loading = false
      current.html = html
      current.base_url = base_url
      current.error = err
      local cursor = current.restore_cursor
      current.restore_cursor = nil

      draw(current, cursor or "body")
    end)
  end

  local function close_windows(current)
    if internal.is_valid_win(current.footer_win) then
      vim.api.nvim_win_close(current.footer_win, true)
    end

    if internal.is_valid_win(current.win) then
      vim.api.nvim_win_close(current.win, true)
    end

    if internal.is_valid_buf(current.buf) then
      vim.api.nvim_buf_delete(current.buf, { force = true })
    end
  end

  -- Close the reader. With `remember`, reopening Oculus opens the post again
  -- where it was left, as happens after inspecting a reference.
  function devlog_view.close_post(remember)
    local current = state.devlog_reader

    if not current then
      return
    end

    state.devlog_reader = nil

    if remember and internal.is_valid_win(current.win) then
      state.devlog_resume = {
        post = current.post,
        cursor = vim.api.nvim_win_get_cursor(current.win),
      }
    elseif not remember then
      state.devlog_resume = nil
    end

    close_windows(current)

    if not remember and internal.is_valid_win(state.win) then
      vim.api.nvim_set_current_win(state.win)
    end
  end

  function devlog_view.inspect_reference()
    local current = reader()

    if not current or current.inspecting then
      return
    end

    local reference = reference_near_cursor(current)

    if not reference then
      vim.notify(
        "Oculus: no pull request, issue or commit here; ⇥ jumps to the next one",
        vim.log.levels.INFO
      )

      return
    end

    local lifecycle = {
      on_progress = function(frame)
        if state.devlog_reader ~= current then
          return
        end

        current.inspecting = { label = reference.label, frame = frame }
        render_footer(current)
        vim.cmd("redraw")
      end,
      on_complete = function(message)
        if state.devlog_reader == current then
          current.inspecting = nil
          render_footer(current)
        end

        if message then
          vim.notify("Oculus: " .. tostring(message), vim.log.levels.WARN)
        end
      end,
    }

    current.inspecting = { label = reference.label }
    render_footer(current)
    local inspect = require("oculus.inspect")
    local ok, err

    if reference.url then
      ok, err = inspect.open(reference.url, state.opts, nil, lifecycle)
    else
      ok, err = inspect.inspect_by_id(
        reference.target,
        state.opts,
        { project = reference.project or (not is_user(current.project) and current.project or nil) },
        nil,
        lifecycle
      )
    end

    if not ok and state.devlog_reader == current then
      current.inspecting = nil
      render_footer(current)
    end

    if not ok and err then
      vim.notify("Oculus: " .. tostring(err), vim.log.levels.WARN)
    end
  end

  -- Move to the next (direction 1) or previous (-1) reference in the post.
  function devlog_view.jump_reference(direction)
    local current = reader()

    if not current or not current.doc or #current.doc.references == 0 then
      return
    end

    local cursor = vim.api.nvim_win_get_cursor(current.win)
    local stops = {}

    for _, reference in ipairs(current.doc.references) do
      -- A link wrapped over several lines is one stop; its entry in the list
      -- after the post is another.
      for index, segment in ipairs(reference.segments) do
        if index == 1 or segment.listed then
          stops[#stops + 1] = {
            line = current.body_start + segment.line,
            col = #margin + segment.start,
            reference = reference,
            listed = segment.listed == true,
          }
        end
      end
    end

    table.sort(stops, function(left, right)
      if left.line ~= right.line then
        return left.line < right.line
      end

      return left.col < right.col
    end)

    local under = reference_at_cursor(current)
    local in_list = current.section_start ~= nil and cursor[1] >= current.section_start
    local target

    -- The stop the cursor is already on, wherever on it the cursor sits.
    local function current_stop(stop)
      return stop.reference == under and stop.listed == in_list
    end

    local function after(stop)
      return stop.line > cursor[1] or (stop.line == cursor[1] and stop.col > cursor[2])
    end

    if direction > 0 then
      for _, stop in ipairs(stops) do
        if after(stop) and not current_stop(stop) then
          target = stop
          break
        end
      end

      target = target or stops[1]
    else
      for index = #stops, 1, -1 do
        local stop = stops[index]

        if not after(stop) and not current_stop(stop)
          and not (stop.line == cursor[1] and stop.col == cursor[2])
        then
          target = stop
          break
        end
      end

      target = target or stops[#stops]
    end

    vim.api.nvim_win_set_cursor(current.win, { target.line, target.col })
    follow_cursor(current)
  end

  function devlog_view.open_in_browser()
    local current = reader()

    if not current then
      return
    end

    local reference = reference_at_cursor(current)
    local url = reference and (reference.web_url or reference.url)
      or link_at_cursor(current)
      or current.post.url

    if url then
      internal.open_url(url)
    end
  end

  local function map_reader_keys(current)
    local nav = navigation.resolve(state.opts)

    local function map(lhs, rhs, desc)
      vim.keymap.set("n", lhs, rhs, {
        buffer = current.buf,
        nowait = true,
        silent = true,
        desc = desc,
      })
    end

    local function back()
      devlog_view.close_post(false)
    end

    map("q", back, "Back to the posts")
    map("<Esc>", back, "Back to the posts")
    map(nav.left, back, "Back to the posts")
    map("<Left>", back, "Back to the posts")
    map("<C-c>", window.close, "Close Oculus")

    map(nav.down, function()
      vim.cmd.normal({ vim.v.count1 .. "j", bang = true })
    end, "Scroll the devlog post down")

    map(nav.up, function()
      vim.cmd.normal({ vim.v.count1 .. "k", bang = true })
    end, "Scroll the devlog post up")

    map("<Tab>", function()
      devlog_view.jump_reference(1)
    end, "Next pull request, issue or commit in the post")

    map("<S-Tab>", function()
      devlog_view.jump_reference(-1)
    end, "Previous pull request, issue or commit in the post")

    map(nav.inspect, devlog_view.inspect_reference, "Inspect the reference under the cursor")
    map("<CR>", devlog_view.inspect_reference, "Inspect the reference under the cursor")
    map("b", devlog_view.open_in_browser, "Open the link under the cursor, or the post, in a browser")

    map("r", function()
      current.restore_cursor = vim.api.nvim_win_get_cursor(current.win)
      fetch(current, true)
    end, "Reload the devlog post")
  end

  -- Open `post` in the reader, over the Oculus window.
  function devlog_view.open_post(post, cursor)
    local list = state.project_devlog

    if not post or not list or not internal.is_valid_win(state.win) then
      return
    end

    if state.devlog_reader then
      close_windows(state.devlog_reader)
      state.devlog_reader = nil
    end

    define_highlights()
    internal.close_activity_footer()
    state.selected_devlog_post = post.id
    state.devlog_resume = nil

    local current = {
      post = post,
      project = list.project,
      restore_cursor = cursor,
      body_start = header_lines,
    }

    local buf = vim.api.nvim_create_buf(false, true)
    vim.bo[buf].bufhidden = "wipe"
    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].swapfile = false
    vim.bo[buf].filetype = "oculus_devlog"
    vim.bo[buf].modifiable = false
    current.buf = buf

    local config = window.full_window_config(state.opts)
    config.zindex = 55
    -- Entering the window fires before its id is known, and must not read as
    -- leaving Oculus.
    state.devlog_reader = current
    current.opening = true
    current.win = vim.api.nvim_open_win(buf, true, config)
    current.opening = nil
    local win = current.win

    vim.wo[win].winhighlight = table.concat({
      "Normal:OculusNormal",
      "NormalFloat:OculusNormal",
      "FloatBorder:OculusBorder",
      "FloatTitle:OculusBorder",
    }, ",")

    internal.use_window_highlights(win)
    vim.wo[win].wrap = false
    vim.wo[win].cursorline = true
    vim.wo[win].number = false
    vim.wo[win].relativenumber = false
    vim.wo[win].signcolumn = "no"
    vim.wo[win].winfixbuf = true
    map_reader_keys(current)

    local group = vim.api.nvim_create_augroup("OculusDevlogReader", { clear = true })

    vim.api.nvim_create_autocmd("CursorMoved", {
      group = group,
      buffer = buf,
      callback = function()
        if state.devlog_reader == current and internal.is_valid_win(current.win) then
          follow_cursor(current)
        end
      end,
    })

    vim.api.nvim_create_autocmd("WinClosed", {
      group = group,
      pattern = tostring(win),
      once = true,
      callback = function()
        vim.schedule(function()
          if state.devlog_reader == current then
            state.devlog_reader = nil
          end

          close_windows(current)
        end)
      end,
    })

    fetch(current, false)
  end

  -- Reopen the post that was being read when Oculus closed.
  function devlog_view.resume_post()
    local resume = state.devlog_resume

    if not resume or state.view ~= "devlog" then
      return
    end

    devlog_view.open_post(resume.post, resume.cursor)
  end

  -- Fit the reader to a resized editor, keeping the cursor on its line.
  function devlog_view.resize_post()
    local current = reader()

    if not current then
      return
    end

    local config = window.full_window_config(state.opts)
    config.zindex = 55
    vim.api.nvim_win_set_config(current.win, config)
    draw(current, vim.api.nvim_win_get_cursor(current.win))
  end
end

return M
