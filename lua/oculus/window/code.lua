-- A project's code: the contents of one directory on its default branch,
-- listed like the milestones, with directories opened in place and files
-- opened in a tab, from a local clone when there is one.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local git = require("oculus.inspect.git")
local colorscheme = require("oculus.inspect.colorscheme")
local M = {}
local remote_file_group = vim.api.nvim_create_augroup("OculusCodeFiles", { clear = true })

function M.setup(window, code_view, internal)
  -- The directory a tracked subdirectory starts at; the listing never goes
  -- above it.
  function code_view.root(project)
    return (tostring(project.path or ""):gsub("^/+", ""):gsub("/+$", ""))
  end

  local function format_size(size)
    size = tonumber(size)

    if not size then
      return nil
    end

    if size < 1024 then
      return ("%d B"):format(size)
    elseif size < 1024 * 1024 then
      return ("%.1f KB"):format(size / 1024)
    end

    return ("%.1f MB"):format(size / (1024 * 1024))
  end

  local type_names = {
    dir = "Directory",
    file = "File",
    symlink = "Symbolic link",
    submodule = "Submodule",
  }

  function code_view.preview_items(entry)
    if entry.kind == "parent" then
      return {
        [2] = { "DIRECTORY", "Title" },
        [4] = { "..", "Identifier" },
        [5] = { "Parent directory", "Comment" },
      }
    end

    local size = entry.type ~= "dir" and format_size(entry.size) or nil
    local details = {}

    if entry.path ~= entry.name then
      details[#details + 1] = entry.path
    end

    details[#details + 1] = size

    return {
      [2] = { (type_names[entry.type] or "Entry"):upper(), "Title" },
      [4] = { entry.name, "Identifier" },
      [5] = details[1] and { details[1], "Comment" } or nil,
      [6] = details[2] and { details[2], "Comment" } or nil,
    }
  end

  function code_view.entry_key(entry)
    return entry.kind == "parent" and ".." or entry.path
  end

  local entry_key = code_view.entry_key

  function code_view.queue_preview(entry)
    if window.state.view ~= "code" or not entry then
      return
    end

    local key = "code:" .. entry_key(entry)

    if window.state.preview_key == key then
      return
    end

    window.state.preview_key = key
    internal.render_preview_panel(code_view.preview_items(entry), { offset = 3 })
  end

  -- The rows of the current listing: the parent directory when below the
  -- project's root, then the entries.
  local function rows()
    local listing = window.state.project_code
    local result = {}

    if not listing then
      return result
    end

    if listing.path ~= code_view.root(listing.project) then
      result[1] = { kind = "parent", name = ".." }
    end

    for _, entry in ipairs(listing.entries or {}) do
      result[#result + 1] = entry
    end

    return result
  end

  function code_view.selected_index(entries)
    for index, entry in ipairs(entries) do
      if entry_key(entry) == window.state.selected_code_entry then
        return index
      end
    end

    return entries[1] and 1 or nil
  end

  function code_view.render()
    local listing = window.state.project_code

    if not listing or not internal.is_valid_win(window.state.win) then
      return
    end

    internal.stop_activity_page_loading()
    internal.close_activity_footer()
    window.state.view = "code"
    window.state.line_targets = {}
    window.state.preview_key = nil
    local project = listing.project
    local window_width = vim.api.nvim_win_get_width(window.state.win)
    local left_width = internal.preview_left_width(window_width)
    local window_height = vim.api.nvim_win_get_height(window.state.win)
    local sidebar_visible = internal.is_sidebar_visible()
    local tab_text, tab_ranges = internal.project_tab_line("code", window_width - 2)

    local lines = {
      "",
      internal.trim_to_width(("  %s · %s"):format(
        internal.project_title(project),
        listing.path == "" and internal.provider_name(project) or ("/" .. listing.path)
      ), window_width - 2),
      tab_text,
      listing.status and internal.trim_to_width("  " .. listing.status.text, left_width - 1) or "",
    }

    local comment_lines = {}
    local directory_lines = {}
    local error_line
    local entries = rows()

    if listing.loading and not listing.entries then
      lines[#lines + 1] = "  Loading files…"
      comment_lines[#comment_lines + 1] = #lines
    elseif listing.error then
      lines[#lines + 1] = "  Could not load files"
      error_line = #lines

      for _, line in ipairs(internal.wrapped_preview_text(listing.error, left_width - 4, 4)) do
        lines[#lines + 1] = "  " .. line
        comment_lines[#comment_lines + 1] = #lines
      end
    elseif #entries == 0 then
      lines[#lines + 1] = "  This directory is empty."
      comment_lines[#comment_lines + 1] = #lines
    else
      local selected_index = code_view.selected_index(entries)
      window.state.selected_code_entry = entry_key(entries[selected_index])

      -- Render only the rows that fit, like the milestones, so the preview
      -- panel and the footer stay anchored while the selection scrolls.
      local capacity = math.max(
        3,
        window_height - #lines - (sidebar_visible and 0 or 2)
      )

      local offset = math.min(
        math.max(1, window.state.code_offset or 1),
        math.max(1, #entries - capacity + 1)
      )

      if selected_index < offset then
        offset = selected_index
      elseif selected_index >= offset + capacity then
        offset = selected_index - capacity + 1
      end

      window.state.code_offset = offset

      for index = offset, math.min(#entries, offset + capacity - 1) do
        local entry = entries[index]
        local directory = entry.kind == "parent" or entry.type == "dir"
        local name = entry.name .. (entry.type == "dir" and "/" or "")

        lines[#lines + 1] = internal.pad_cell(
          "  " .. internal.trim_to_width(name, left_width - 3),
          left_width
        )

        window.state.line_targets[#lines] = {
          kind = "code_entry",
          entry = entry,
        }

        if directory then
          directory_lines[#lines] = true
        end
      end
    end

    local commands_line = internal.footer(lines, left_width)
    internal.set_lines(lines)
    internal.paint_footer(commands_line)
    vim.wo[window.state.win].cursorline = false
    internal.paint_project_header(lines[2], tab_ranges)

    if listing.status then
      internal.highlight(4, 2, -1, listing.status.group)
    end

    for _, line in ipairs(comment_lines) do
      internal.highlight(line, 2, -1, "Comment")
    end

    if error_line then
      internal.highlight(error_line, 2, -1, "DiagnosticError")
    end

    local selected_line

    for line, target in pairs(window.state.line_targets) do
      internal.highlight(line, 2, -1, directory_lines[line] and "OculusDirectory" or "Identifier")

      if entry_key(target.entry) == window.state.selected_code_entry then
        selected_line = line
      end
    end

    if selected_line then
      vim.api.nvim_win_set_cursor(window.state.win, { selected_line, 0 })
      code_view.queue_preview(window.state.line_targets[selected_line].entry)
    else
      internal.render_preview_panel({}, { offset = 3 })
    end

    internal.update_contributor_selection()
    internal.render_sidebar()
  end

  function code_view.select_adjacent(direction)
    local entries = rows()
    local index = code_view.selected_index(entries)

    if not index then
      return
    end

    index = ((index - 1 + direction) % #entries) + 1
    window.state.selected_code_entry = entry_key(entries[index])
    code_view.render()
  end

  -- Lists one directory of the project. select names the entry to select
  -- once it loads, such as the directory just left.
  function code_view.load(project, path, force, select)
    window.state.request_id = window.state.request_id + 1
    local request_id = window.state.request_id
    local previous = window.state.project_code
    local key = internal.project_issue_filter_key(project) .. ":" .. path
    local same = previous and previous.key == key

    if not same then
      window.state.selected_code_entry = select
      window.state.code_offset = 1
    end

    window.state.project_code = {
      key = key,
      project = project,
      path = path,
      loading = true,
      entries = same and previous.entries or nil,
    }

    code_view.render()
    local provider = project.provider == "codeberg" and codeberg or github

    if type(provider.repository_contents) ~= "function" then
      window.state.project_code.loading = false
      window.state.project_code.error = "this provider does not support browsing code"
      code_view.render()
      return
    end

    local request_opts = vim.tbl_extend(
      "force",
      window.state.opts,
      { force = force or false }
    )

    provider.repository_contents(project.repository, path, request_opts, function(entries, err)
      if request_id ~= window.state.request_id
        or window.state.view ~= "code"
        or not internal.is_valid_win(window.state.win)
      then
        return
      end

      window.state.project_code = {
        key = key,
        project = project,
        path = path,
        loading = false,
        error = err and tostring(err) or nil,
        entries = entries or {},
      }

      code_view.render()
    end)
  end

  -- Opens the directory under the cursor, or the parent directory. Returns
  -- false for files, which have nothing to open in place.
  function code_view.open(entry)
    local listing = window.state.project_code

    if not listing or not entry then
      return false
    end

    if entry.kind == "parent" then
      code_view.up()
      return true
    end

    if entry.type == "file" or entry.type == "symlink" then
      code_view.open_file(entry)
      return true
    end

    if entry.type ~= "dir" then
      return false
    end

    code_view.load(listing.project, entry.path, false)
    return true
  end

  local function set_status(listing, text, group)
    listing.status = text and { text = text, group = group or "Comment" } or nil

    if window.state.project_code == listing and window.state.view == "code" then
      code_view.render()
    end
  end

  -- Shows fetched text in a read-only buffer named after where it came from,
  -- reusing the buffer when the same file is opened again.
  local function remote_buffer(project, path, text)
    local name = ("oculus://%s/%s/%s"):format(
      project.provider == "codeberg" and "codeberg" or "github",
      project.repository,
      path
    )

    local buf = vim.fn.bufnr(name)

    if buf == -1 then
      buf = vim.api.nvim_create_buf(true, true)
      vim.api.nvim_buf_set_name(buf, name)
    end

    local lines = vim.split(text:gsub("\r\n", "\n"), "\n", { plain = true })

    if lines[#lines] == "" and #lines > 1 then
      lines[#lines] = nil
    end

    vim.bo[buf].buftype = "nofile"
    vim.bo[buf].bufhidden = "hide"
    vim.bo[buf].swapfile = false
    vim.bo[buf].readonly = false
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
    vim.bo[buf].modifiable = false
    vim.bo[buf].readonly = true
    vim.bo[buf].modified = false

    vim.b[buf].oculus_remote_file = {
      provider = project.provider == "codeberg" and "codeberg" or "github",
      repository = project.repository,
      path = path,
    }

    -- Coming back to the buffer, such as from another tab, restores its
    -- colorscheme too.
    vim.api.nvim_clear_autocmds({ group = remote_file_group, buffer = buf })

    vim.api.nvim_create_autocmd("BufEnter", {
      group = remote_file_group,
      buffer = buf,
      callback = function(args)
        colorscheme.apply(args.buf)
      end,
    })

    local filetype = vim.filetype.match({ buf = buf, filename = path, contents = lines })

    if filetype then
      vim.bo[buf].filetype = filetype
    end

    return buf
  end

  -- Opens a file in a new tab: the local clone's copy when a clone of the
  -- project is found and has the file, otherwise the forge's copy on the
  -- default branch, read-only.
  function code_view.open_file(entry)
    local listing = window.state.project_code
    local project = listing.project
    local owner, repo = project.repository:match("^([^/]+)/([^/]+)$")
    local forge = project.provider == "codeberg" and "codeberg" or "github"
    set_status(listing, ("Opening %s…"):format(entry.name))

    local info = {
      forge = forge,
      owner = owner,
      repo = repo,
      remote_url = ("https://%s/%s/%s.git"):format(
        forge == "codeberg" and "codeberg.org" or "github.com",
        owner,
        repo
      ),
    }

    local function current()
      return window.state.project_code == listing
        and window.state.view == "code"
        and internal.is_valid_win(window.state.win)
    end

    -- The file gets the colorscheme a per-filetype colorscheme plugin picks
    -- for it, which such plugins skip on the read-only remote buffers.
    local function open_in_tab(command)
      listing.status = nil
      window.close()
      command()
      colorscheme.apply(vim.api.nvim_get_current_buf())
    end

    git.find_local_repository(info, window.state.opts, function(root)
      if not current() then
        return
      end

      local file = root and vim.fs.joinpath(root, entry.path)
      local stat = file and vim.uv.fs_stat(file)

      if stat and stat.type == "file" then
        open_in_tab(function()
          vim.cmd("tabedit " .. vim.fn.fnameescape(file))
        end)

        return
      end

      local provider = forge == "codeberg" and codeberg or github

      if type(provider.repository_file) ~= "function" then
        set_status(listing, "This forge's files cannot be loaded", "DiagnosticWarn")
        return
      end

      provider.repository_file(project.repository, entry.path, window.state.opts, function(text, err)
        if not current() then
          return
        end

        if not text then
          set_status(listing, tostring(err or "the file could not be loaded"), "DiagnosticWarn")
          return
        end

        open_in_tab(function()
          vim.cmd("tab sbuffer " .. remote_buffer(project, entry.path, text))
        end)
      end)
    end)
  end

  -- Goes to the parent directory, selecting the directory just left.
  -- Returns false at the project's root.
  function code_view.up()
    local listing = window.state.project_code

    if not listing or listing.path == code_view.root(listing.project) then
      return false
    end

    local parent = listing.path:match("^(.*)/[^/]+$") or ""
    code_view.load(listing.project, parent, false, listing.path)
    return true
  end

  function code_view.browser_url()
    local listing = window.state.project_code
    local target = window.state.line_targets[vim.api.nvim_win_get_cursor(window.state.win)[1]]

    if type(target) == "table" and target.entry and target.entry.html_url then
      return target.entry.html_url
    end

    if listing then
      local host = listing.project.provider == "codeberg"
          and "https://codeberg.org/"
        or "https://github.com/"

      return host .. listing.project.repository
    end
  end
end

return M
