vim.opt.runtimepath:prepend(vim.fn.getcwd())
local inspect = require("oculus.inspect")
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local auth = require("oculus.auth")

-- Both forges paginate and normalize the general issue/PR discussion.
for _, provider in ipairs({ github, codeberg }) do
  local original_system = vim.system

  local original_token = provider == github and auth.github_token
    or auth.codeberg_token

  local token_key = provider == github and "github_token" or "codeberg_token"
  auth[token_key] = function() end
  local page_size = provider == github and 100 or 50
  local calls = 0
  local comments, error_message

  vim.system = function(command, _, callback)
    calls = calls + 1
    local url = command[#command]
    assert(url:find("/issues/7/comments?", 1, true), url)
    assert(url:find("page=" .. calls, 1, true), url)
    local items = {}
    local count = calls == 1 and page_size or 1

    for index = 1, count do
      items[index] = {
        user = index == 1 and vim.NIL or { login = "alice" },
        body = "Page " .. calls,
        created_at = "2026-10-05T12:00:00Z",
        html_url = "https://example.com/comment/" .. calls,
      }
    end

    callback({ code = 0, stdout = vim.json.encode(items) .. "\n200" })
  end

  provider.issue_comments("o/r", 7, {}, function(items, err)
    comments, error_message = items, err
  end)

  assert(vim.wait(1000, function() return comments ~= nil end))
  assert(not error_message, error_message)
  assert(calls == 2 and #comments == page_size + 1)
  assert(comments[1].author == nil)
  assert(comments[2].author == "alice")
  assert(comments[#comments].body == "Page 2")
  assert(comments[2].created_at == "2026-10-05T12:00:00Z")
  assert(comments[2].url == "https://example.com/comment/1")
  -- A later page failing must not masquerade as a complete discussion.
  calls = 0
  comments, error_message = nil, nil
  local paginated_system = vim.system

  vim.system = function(command, opts, callback)
    if calls == 1 then
      callback({ code = 0, stdout = '{"message":"No access"}\n403' })
      return
    end

    return paginated_system(command, opts, callback)
  end

  provider.issue_comments("o/r", 7, {}, function(items, err)
    comments, error_message = items, err
  end)

  assert(vim.wait(1000, function() return error_message ~= nil end))
  assert(comments == nil and error_message:find("No access", 1, true))
  vim.system = original_system
  auth[token_key] = original_token
end

-- Loading, empty and failed discussions stay visible in the overview.
do
  local overview = { kind = "issue", comments = { loading = true } }

  local function text()
    return table.concat(inspect._sidebar_overview_lines(overview, 38), "\n")
  end

  assert(text():find("  Comments\n  Loading…", 1, true))
  overview.comments = { items = {} }
  assert(text():find("  Comments\n  No comments yet.", 1, true))
  overview.comments = { error = "No access" }
  assert(text():find("  Could not load: No access", 1, true))
  overview.kind = "pull_request"

  overview.comments = {
    items = {
      { author = "alice", body = "First paragraph\n\nSecond paragraph", created_at = "2026-10-05T12:00:00Z" },
      { body = "Anonymous reply" },
      { author = "bob", body = "Long comment with enough words to wrap across several lines in a narrow overview window." },
    },
  }

  local rendered = text()
  assert(rendered:find("  @alice · ", 1, true))
  assert(rendered:find("    First paragraph\n\n    Second paragraph", 1, true))
  assert(rendered:find("  @unknown\n    Anonymous reply", 1, true))

  for _, line in ipairs(inspect._sidebar_overview_lines(overview, 38)) do
    assert(vim.fn.strdisplaywidth(line) <= 38, line)
  end
end

-- Background results repaint an open overview; closing it does not lose
-- comments, while discarding the inspection or reloading ignores old replies.
for _, kind in ipairs({ "issue", "pull_request" }) do
  local original_comments = github.issue_comments
  local callbacks = {}

  github.issue_comments = function(repo, number, _, callback)
    assert(repo == "o/r" and number == 7)
    callbacks[#callbacks + 1] = callback
  end

  local buf = vim.api.nvim_create_buf(false, true)

  local win = vim.api.nvim_open_win(buf, false, {
    relative = "editor", row = 1, col = 1, width = 60, height = 10,
    style = "minimal",
  })

  local group = { overview = { kind = kind }, overview_buf = buf, overview_win = win }
  local info = { kind = kind, owner = "o", repo = "r", number = 7 }
  inspect._overview_ui.load_comments(group, info, {})
  assert(group.overview.comments.loading)
  callbacks[1]({ { author = "alice", body = "Discussion loaded" } })
  local rendered = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
  assert(rendered:find("Discussion loaded", 1, true))
  local marks = vim.api.nvim_buf_get_extmarks(buf, vim.api.nvim_get_namespaces().oculus_inspect_sidebar, 0, -1, { details = true })
  local heading

  for _, mark in ipairs(marks) do
    local line = vim.api.nvim_buf_get_lines(buf, mark[2], mark[2] + 1, false)[1]
    if line == "  Comments" then heading = mark[4].hl_group end
  end

  assert(heading ~= nil, "Comments heading must be highlighted")
  inspect._overview_ui.close_footer(group)
  vim.api.nvim_win_close(win, true)
  group.overview_win = nil
  group.overview_buf = nil
  inspect._overview_ui.load_comments(group, info, {})
  callbacks[2]({ { body = "Loaded while closed" } })
  assert(group.overview.comments.items[1].body == "Loaded while closed")
  inspect._overview_ui.load_comments(group, info, {})
  inspect._overview_ui.load_comments(group, info, {})
  callbacks[3]({ { body = "Stale" } })
  assert(group.overview.comments.loading)
  callbacks[4](nil, "Network failed")
  assert(group.overview.comments.error == "Network failed")
  inspect._overview_ui.load_comments(group, info, {})
  group.discarded = true
  callbacks[5]({ { body = "Discarded" } })
  assert(group.overview.comments.items == nil)
  github.issue_comments = original_comments
end

-- Incoming comments shift the model list without changing the chosen model.
do
  local buf = vim.api.nvim_create_buf(false, true)

  local models = {
    { display_name = "First", id = "first" },
    { display_name = "Second", id = "second" },
  }

  local group = {
    overview = { kind = "issue", comments = { loading = true } },
    overview_buf = buf,
    overview_agent_mode = "models",
    overview_agent_request_kind = "explanation",
    overview_agent_models = models,
  }

  inspect._overview_ui.render(group)

  for line, model in pairs(group.overview_agent_model_lines) do
    if model == models[2] then group.overview_agent_selected_line = line end
  end

  local old_line = group.overview_agent_selected_line
  group.overview.comments = { items = { { body = "First line\nSecond line\nThird line" } } }
  inspect._overview_ui.render(group)
  assert(group.overview_agent_selected_line > old_line)
  assert(group.overview_agent_model_lines[group.overview_agent_selected_line] == models[2])
  vim.api.nvim_buf_delete(buf, { force = true })
end
