local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local review = require("oculus.inspect.review")
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local inspect = require("oculus.inspect")

local function wait_for(label, predicate)
  assert(vim.wait(5000, predicate, 10), label)
end

-- Answers curl requests by URL substring; records each command.
local function with_fake_curl(routes, run)
  local original_system = vim.system
  local commands = {}

  vim.system = function(command, _, on_exit)
    commands[#commands + 1] = command
    local url = command[#command]
    local body = "[]"

    for pattern, response in pairs(routes) do
      if url:find(pattern, 1, true) then
        body = vim.json.encode(response)
      end
    end

    on_exit({ code = 0, stdout = body .. "\n200", stderr = "" })
    return {}
  end

  local ok, err = pcall(run)
  vim.system = original_system
  assert(ok, err)
  return commands
end

-- A comment never replaces an approval, the author's own replies are not
-- verdicts, and a pending request replaces an earlier verdict.
do
  local verdicts = review.reviewer_verdicts({
    { author = "alice", state = "approved" },
    { author = "alice", state = "commented" },
    { author = "owner", state = "commented" },
    { author = "bob", state = "changes_requested" },
    { author = "carol", state = "commented" },
  }, { "bob", "dave" }, "owner")

  assert(vim.deep_equal(verdicts, {
    { author = "alice", state = "approved" },
    { author = "bob", state = "requested", previous = "changes_requested" },
    { author = "carol", state = "commented" },
    { author = "dave", state = "requested" },
  }), vim.inspect(verdicts))

  local items = review.overview_sections({
    review = {
      reviews = { { author = "bob", state = "commented" } },
      requested_reviewers = { "bob" },
    },
  })[1].items

  assert(items[1] == "○ @bob review requested · previously commented", items[1])
end

-- Overview sections summarize reviewers, checks, merge state and threads.
do
  local sections = review.overview_sections({
    author = "owner",
    state = "open",
    review = {
      reviews = { { author = "alice", state = "approved" } },
      checks = {
        { name = "lint", state = "failure" },
        { name = "test", state = "success" },
        { name = "build", state = "pending" },
      },
      mergeable_state = "dirty",
      threads = {
        { resolved = true },
        { resolved = false, outdated = true },
      },
      unplaced = 1,
    },
  })

  assert(vim.deep_equal(sections, {
    { label = "Reviews", items = { "✓ @alice approved" } },
    { label = "Checks", items = { "✗ 1 failing  ● 1 pending  ✓ 1 passed", "✗ lint" } },
    { label = "Merge", items = { "Has conflicts" } },
    {
      label = "Review threads",
      items = {
        "1 open, 1 resolved, 1 outdated",
        "1 on code no longer in the pull request",
      },
    },
  }), vim.inspect(sections))

  assert(review.overview_sections({ review = { loading = true } })[1].items[1] == "Loading…")
  assert(#review.overview_sections({}) == 0)
end

-- The change buffer shows one chunk with the others reverted.
do
  local session = {
    hunks = {
      { old_start = 2, old_count = 1, new_start = 2, new_count = 3 },
      { old_start = 6, old_count = 2, new_start = 8, new_count = 1 },
      { old_start = 10, old_count = 0, new_start = 12, new_count = 2 },
    },
    focused_chunks = true,
    active_chunk = 3,
  }

  -- Before the first chunk nothing moves; inside a reverted chunk the line is
  -- its start; after it, the reverted chunk's added lines are gone.
  assert(review.display_line(session, "change", 1) == 1)
  local line, chunk = review.display_line(session, "change", 3)
  assert(line == 2 and chunk == 1, tostring(line))
  assert(review.display_line(session, "change", 6) == 4)
  line, chunk = review.display_line(session, "change", 8)
  assert(line == 6 and chunk == 2, tostring(line))
  -- Inside the active chunk: shifted by both reverted chunks (+2, -1).
  line, chunk = review.display_line(session, "change", 13)
  assert(line == 12 and chunk == nil, tostring(line))
  assert(review.display_line(session, "parent", 7) == 7)
  session.focused_chunks = false
  assert(review.display_line(session, "change", 13) == 13)

  -- Remote excerpts translate revision lines first.
  local excerpt_session = {
    hunks = {},
    excerpt = { change = { { source = 40, excerpt = 3, count = 10 } } },
  }

  assert(review.display_line(excerpt_session, "change", 45) == 8)
end

-- Threads land on the latest version of their file at or before their commit.
do
  local sessions = {
    { change_file = "a.lua", parent_file = "a.lua", change_commit = "A1", status = "M" },
    { change_file = "b.lua", parent_file = "b.lua", change_commit = "B2", status = "M" },
    { change_file = "a.lua", parent_file = "a.lua", change_commit = "C3", status = "M" },
  }

  local threads = {
    { id = "1", path = "a.lua", side = "change", line = 1, commit = "b2" },
    { id = "2", path = "a.lua", side = "change", line = 1, commit = "c3" },
    { id = "3", path = "a.lua", side = "parent", line = 1, commit = "c3" },
    { id = "4", path = "a.lua", side = "change", line = 1, commit = "gone", outdated = true },
    { id = "5", path = "a.lua", side = "change", line = 1, commit = "head" },
    { id = "6", path = "b.lua", side = "change", line = 1, commit = "A1" },
  }

  local unplaced = review.place(
    sessions,
    threads,
    { { sha = "a1" }, { sha = "b2" }, { sha = "c3" } },
    "HEAD"
  )

  local function ids(session)
    local result = {}

    for _, thread in ipairs(session.review_threads) do
      result[#result + 1] = thread.id
    end

    return table.concat(result, ",")
  end

  assert(ids(sessions[1]) == "1,3", ids(sessions[1]))
  assert(ids(sessions[2]) == "", ids(sessions[2]))
  assert(ids(sessions[3]) == "2,5", ids(sessions[3]))
  assert(unplaced == 2, tostring(unplaced))
end

-- Labels and float text.
do
  local thread = {
    resolved = true,
    outdated = true,
    comments = {
      { author = "alice", body = "Rename this\nplease", created_at = "2026-09-15T09:17:55Z" },
      { author = "bob", body = "Done" },
    },
  }

  assert(review.mark_text({ thread }) == "✓ @alice: Rename this (+1 reply)")
  assert(review.mark_text({ thread, thread }, 2) == "◆ 2 review threads · chunk 2")
  assert(review.all_resolved({ thread }))
  local lines, headers, starts = review.float_lines({ thread, thread })
  assert(lines[1] == "@alice  2026-09-15  · resolved, outdated", lines[1])
  assert(lines[2] == "Rename this" and lines[3] == "please")
  assert(lines[5] == "@bob" and lines[6] == "Done")
  assert(vim.deep_equal(headers, { 0, 4, 7, 11 }), vim.inspect(headers))
  assert(vim.deep_equal(starts, { 1, 8 }), vim.inspect(starts))
  -- Inline text wraps each comment under the code line, replies indented.
  local inline = review.inline_lines({ thread }, 24)

  local inline_text = vim.tbl_map(function(virt_line)
    return virt_line[1][1]
  end, inline)

  assert(vim.deep_equal(inline_text, {
    "  ✓ @alice  2026-09-15  · resolved, outdated",
    "    Rename this",
    "    please",
    "    ↳ @bob",
    "      Done",
  }), vim.inspect(inline_text))

  assert(inline[1][1][2] == "OculusInspectThreadResolved")

  local wrapped = review.inline_lines({
    {
      comments = {
        {
          author = "alice",
          body = "one two three four five six seven eight nine ten",
        },
      },
    },
  }, 24)

  assert(wrapped[1][1][1] == "  ◆ @alice")
  assert(wrapped[1][1][2] == "OculusInspectThreadHeader")
  assert(wrapped[2][1][1] == "    one two three four", wrapped[2][1][1])
  assert(wrapped[2][1][2] == "OculusInspectThreadBody")
  assert(wrapped[3][1][1] == "    five six seven eight", wrapped[3][1][1])
  assert(wrapped[4][1][1] == "    nine ten", wrapped[4][1][1])
  assert(#wrapped == 4, vim.inspect(wrapped))
end

-- GitHub replies join their thread, resolution comes from GraphQL, and a
-- comment GitHub no longer maps to the head keeps its original line.
do
  local threads = github.review_threads({
    {
      id = 10,
      path = "a.lua",
      line = 4,
      side = "RIGHT",
      commit_id = "head",
      original_commit_id = "old",
      user = { login = "alice" },
      body = "First",
      html_url = "https://github.com/o/r/pull/1#discussion_r10",
    },
    {
      id = 11,
      in_reply_to_id = 10,
      path = "a.lua",
      user = { login = "bob" },
      body = "Reply",
    },
    {
      id = 12,
      path = "b.lua",
      line = vim.NIL,
      original_line = 7,
      side = "LEFT",
      commit_id = "head",
      original_commit_id = "old",
      user = { login = "carol" },
      body = "Outdated",
      in_reply_to_id = vim.NIL,
    },
  }, { ["10"] = { resolved = true, outdated = false } })

  assert(#threads == 2)
  assert(threads[1].line == 4 and threads[1].commit == "head")
  assert(threads[1].resolved == true and threads[1].outdated == false)
  assert(#threads[1].comments == 2 and threads[1].comments[2].author == "bob")
  assert(threads[2].side == "parent" and threads[2].line == 7)
  assert(threads[2].commit == "old" and threads[2].outdated == true)
end

-- Codeberg conversations are the comments on one line of one commit.
do
  local threads = codeberg.review_threads({
    { id = 3, path = "a.lua", position = 5, commit_id = "c", user = { login = "bob" }, body = "Reply", resolver = { login = "alice" } },
    { id = 2, path = "a.lua", position = 5, commit_id = "c", user = { login = "alice" }, body = "First", resolver = vim.NIL },
    { id = 4, path = "a.lua", position = 0, old_position = 9, commit_id = "c", user = { login = "carol" }, body = "Old side" },
  })

  assert(#threads == 2, vim.inspect(threads))
  assert(threads[1].comments[1].body == "First" and threads[1].comments[2].body == "Reply")
  assert(threads[1].resolved == true and threads[1].line == 5)
  assert(threads[2].side == "parent" and threads[2].line == 9)
end

-- The GitHub loader combines reviews, comments, checks and GraphQL resolution.
do
  local original_token = require("oculus.auth").github_token

  require("oculus.auth").github_token = function()
    return "token"
  end

  local result, err

  local commands = with_fake_curl({
    ["/pulls/7/reviews"] = {
      { user = { login = "alice" }, state = "APPROVED" },
      { user = { login = "bob" }, state = "PENDING" },
    },
    ["/pulls/7/comments"] = {
      { id = 1, path = "a.lua", line = 2, side = "RIGHT", commit_id = "h", user = { login = "alice" }, body = "Hi" },
    },
    ["/check-runs"] = {
      check_runs = {
        { name = "lint", status = "completed", conclusion = "failure" },
        { name = "test", status = "in_progress", conclusion = vim.NIL },
      },
    },
    ["/status"] = { statuses = { { context = "ci", state = "success" } } },
    ["/graphql"] = {
      data = {
        repository = {
          pullRequest = {
            reviewThreads = {
              pageInfo = { hasNextPage = false },
              nodes = {
                { isResolved = true, isOutdated = false, comments = { nodes = { { databaseId = 1 } } } },
              },
            },
          },
        },
      },
    },
  }, function()
    github.pull_request_review("o/r", 7, "h", {}, function(value, error_message)
      result, err = value, error_message
    end)

    wait_for("GitHub review loads", function()
      return result ~= nil or err ~= nil
    end)
  end)

  require("oculus.auth").github_token = original_token
  assert(not err, err)
  assert(vim.deep_equal(result.reviews, { { author = "alice", state = "approved" } }), vim.inspect(result.reviews))
  assert(#result.threads == 1 and result.threads[1].resolved == true)

  assert(vim.deep_equal(vim.tbl_map(function(check)
    return check.state
  end, result.checks), { "failure", "pending", "success" }), vim.inspect(result.checks))

  local posted

  for _, command in ipairs(commands) do
    if command[#command]:find("/graphql", 1, true) then
      posted = table.concat(command, " ")
    end
  end

  assert(posted and posted:find("-X POST", 1, true) and posted:find("--data-binary @", 1, true), posted)
end

-- The Codeberg loader fetches each review's comments and the head status.
do
  local result, err

  local commands = with_fake_curl({
    ["/pulls/7/reviews?"] = {
      { id = 1, user = { login = "alice" }, state = "REQUEST_CHANGES", comments_count = 1 },
      { id = 2, user = { login = "bob" }, state = "PENDING", comments_count = 3 },
      { id = 3, user = { login = "carol" }, state = "APPROVED", dismissed = true, comments_count = 0 },
    },
    ["/reviews/1/comments"] = {
      { id = 9, path = "a.lua", position = 3, commit_id = "h", user = { login = "alice" }, body = "Fix" },
    },
    ["/commits/h/status"] = {
      statuses = { { context = "ci", status = "failure", target_url = "/o/r/actions/runs/1" } },
    },
  }, function()
    codeberg.pull_request_review("o/r", 7, "h", {}, function(value, error_message)
      result, err = value, error_message
    end)

    wait_for("Codeberg review loads", function()
      return result ~= nil or err ~= nil
    end)
  end)

  assert(not err, err)

  assert(vim.deep_equal(result.reviews, {
    { author = "alice", state = "changes_requested" },
    { author = "carol", state = "dismissed" },
  }), vim.inspect(result.reviews))

  assert(#result.threads == 1 and result.threads[1].line == 3)
  assert(result.checks[1].url == "https://codeberg.org/o/r/actions/runs/1")

  for _, command in ipairs(commands) do
    assert(not command[#command]:find("/reviews/2/comments", 1, true), "pending reviews are skipped")
  end
end

-- An inspected pull request shows its threads in the buffers, the sidebar and
-- the overview, and ]r walks through them.
do
  local tabs_before = vim.api.nvim_list_tabpages()
  local original_review = github.pull_request_review
  local original_apply = inspect._review.apply
  local group

  inspect._review.apply = function(target_group, ...)
    group = target_group
    return original_apply(target_group, ...)
  end

  github.pull_request_review = function(repository, number, head_sha, _, callback)
    assert(repository == "o/r" and number == 7 and head_sha == "c1")

    vim.schedule(function()
      callback({
        reviews = { { author = "alice", state = "approved" } },
        checks = {},
        threads = {
          {
            id = "1",
            path = "dummy.lua",
            side = "change",
            line = 8,
            commit = "c1",
            comments = { { author = "alice", body = "Second chunk" } },
          },
          {
            id = "2",
            path = "dummy.lua",
            side = "parent",
            line = 4,
            commit = "c1",
            comments = { { author = "bob", body = "Old side" } },
          },
          {
            id = "3",
            path = "dummy.lua",
            side = "change",
            line = 5,
            commit = "c1",
            resolved = true,
            comments = { { author = "carol", body = "Unchanged" } },
          },
        },
      })
    end)
  end

  local opened, open_err

  inspect._open_tabs({
    {
      kind = "pull_request",
      parent = "p0",
      commit = "c1",
      parent_role = "old",
      repository = root,
      parent_file = "dummy.lua",
      change_file = "dummy.lua",
      parent_lines = { "a", "b", "c", "d", "e", "f", "g", "h" },
      change_lines = { "a", "B", "c", "d", "e", "f", "G", "G2", "h" },
      hunks = {
        { old_start = 2, old_count = 1, new_start = 2, new_count = 1 },
        { old_start = 7, old_count = 1, new_start = 7, new_count = 2 },
      },
      commit_index = 1,
      status = "M",
    },
  }, { lifecycle = {} }, nil, {
    kind = "pull_request",
    forge = "github",
    owner = "o",
    repo = "r",
    number = 7,
    head_sha = "c1",
    author = "owner",
    state = "open",
    commits = { { sha = "c1" } },
    requested_reviewers = { "dave" },
    mergeable = true,
  }, { number = false, relativenumber = false }, {}, function(result, err)
    opened, open_err = result, err
  end)

  assert(not open_err, tostring(open_err))
  assert(opened)

  wait_for("review threads load", function()
    return group ~= nil and group.overview.review.threads ~= nil
  end)

  inspect._review.apply = original_apply
  github.pull_request_review = original_review
  local session = group[1]
  local change, parent = session.change, session.parent

  local function marks(endpoint)
    local result = {}

    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      endpoint.buf,
      inspect._review.ns,
      0,
      -1,
      { details = true }
    )) do
      if mark[4].virt_text then
        result[mark[2] + 1] = mark[4].virt_text[1][1]
      end
    end

    return result
  end

  -- Chunk 1 is focused: the second chunk's thread sits at its start.
  local change_marks = marks(change)
  assert(change_marks[7] == "  ◆ @alice: Second chunk · chunk 2", vim.inspect(change_marks))
  assert(change_marks[5] == "  ✓ @carol: Unchanged", vim.inspect(change_marks))
  assert(marks(parent)[4] == "  ◆ @bob: Old side", vim.inspect(marks(parent)))
  assert(group.sidebar_rows[1].line:find("◆2", 1, true), group.sidebar_rows[1].line)
  local overview_lines = inspect._sidebar_overview_lines(group.overview, 60)
  local overview_text = table.concat(overview_lines, "\n")
  assert(overview_text:find("  Reviews\n  ✓ @alice approved\n  ○ @dave review requested", 1, true), overview_text)
  assert(overview_text:find("  Merge\n  No conflicts", 1, true), overview_text)
  assert(overview_text:find("  Review threads\n  2 open, 1 resolved", 1, true), overview_text)
  -- Resting on a commented line shows the thread without a border title.
  vim.api.nvim_set_current_tabpage(change.tab)
  vim.api.nvim_set_current_win(change.win)
  vim.api.nvim_win_set_cursor(change.win, { 5, 0 })
  inspect._review.on_cursor_moved(change)
  local float = assert(change.review_float, "thread float opens")
  local float_config = vim.api.nvim_win_get_config(float.win)
  assert(float_config.focusable == false and float_config.title == nil)
  assert(vim.api.nvim_buf_get_lines(float.buf, 1, 2, false)[1] == "Unchanged")
  vim.api.nvim_win_set_cursor(change.win, { 6, 0 })
  inspect._review.on_cursor_moved(change)
  assert(change.review_float == nil, "thread float closes off the line")
  -- Opening the thread moves into it with an interior footer.
  vim.api.nvim_win_set_cursor(change.win, { 5, 0 })
  float = assert(inspect._review.show_float(change, 5, true))
  assert(vim.api.nvim_get_current_win() == float.win)
  assert(vim.api.nvim_win_is_valid(float.footer_win))
  assert(vim.api.nvim_win_get_config(float.footer_win).relative == "win")
  vim.api.nvim_feedkeys("q", "x", false)
  assert(change.review_float == nil and vim.api.nvim_get_current_win() == change.win)
  -- ]r from line 2 visits the old side, the unchanged line, then renders the
  -- second chunk for its thread.
  vim.api.nvim_win_set_cursor(change.win, { 2, 0 })
  inspect._review.jump(group, session, "change", 1)
  assert(vim.api.nvim_get_current_win() == parent.win)
  assert(vim.api.nvim_win_get_cursor(parent.win)[1] == 4)
  inspect._review.jump(group, session, "parent", 1)
  assert(vim.api.nvim_get_current_win() == change.win)
  assert(vim.api.nvim_win_get_cursor(change.win)[1] == 5)
  inspect._review.jump(group, session, "change", 1)
  assert(session.active_chunk == 2)
  assert(vim.api.nvim_win_get_cursor(change.win)[1] == 8)
  assert(vim.api.nvim_buf_get_lines(change.buf, 7, 8, false)[1] == "G2")
  assert(marks(change)[8] == "  ◆ @alice: Second chunk", vim.inspect(marks(change)))
  assert(change.review_float and change.review_float.line == 8)
  -- [r goes back to the unchanged line's thread.
  inspect._review.jump(group, session, "change", -1)
  assert(vim.api.nvim_win_get_cursor(change.win)[1] == 5)

  -- The overview loads the threads into the files: the whole file comes back
  -- so each thread sits on its own line, with its comments below it.
  local function inline_marks(endpoint)
    local result = {}

    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      endpoint.buf,
      inspect._review.ns,
      0,
      -1,
      { details = true }
    )) do
      if mark[4].virt_lines then
        assert(mark[4].virt_lines_leftcol, "inline threads own the gutter")

        result[mark[2] + 1] = vim.tbl_map(function(virt_line)
          return virt_line[#virt_line][1]
        end, mark[4].virt_lines)
      end
    end

    return result
  end

  assert(session.active_chunk == 2 and session.focused_chunks)
  assert(inspect._review.thread_count(group) == 3)
  assert(inspect._review.toggle_inline(group))
  assert(group.review_inline)
  assert(session.focused_chunks == false)
  assert(session.review_inline_chunk == 2)
  local change_inline = inline_marks(change)

  assert(vim.deep_equal(
    change_inline[5],
    { "  ✓ @carol  · resolved", "    Unchanged" }
  ), vim.inspect(change_inline))

  assert(vim.deep_equal(change_inline[8], { "  ◆ @alice", "    Second chunk" }),
    vim.inspect(change_inline))

  assert(vim.deep_equal(
    inline_marks(parent)[4],
    { "  ◆ @bob", "    Old side" }
  ), vim.inspect(inline_marks(parent)))

  -- A line runs down the number column from the code line to the last comment.
  local gutter = {}

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    change.buf,
    inspect._review.ns,
    0,
    -1,
    { details = true }
  )) do
    if mark[4].virt_lines and mark[2] + 1 == 8 then
      gutter = vim.tbl_map(function(virt_line)
        return virt_line[1]
      end, mark[4].virt_lines)
    end
  end

  assert(#gutter == 2, vim.inspect(gutter))
  assert(gutter[1][1]:find("│", 1, true), vim.inspect(gutter))
  assert(gutter[1][2] == "OculusInspectThreadGutter", vim.inspect(gutter))
  assert(gutter[2][1]:find("└", 1, true), vim.inspect(gutter))

  assert(
    vim.fn.strdisplaywidth(gutter[1][1])
      == inspect._review.gutter_width(change.win),
    vim.inspect(gutter)
  )

  -- Resolved threads dim their line too.
  local resolved_gutter

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    change.buf,
    inspect._review.ns,
    0,
    -1,
    { details = true }
  )) do
    if mark[4].virt_lines and mark[2] + 1 == 5 then
      resolved_gutter = mark[4].virt_lines[1][1]
    end
  end

  assert(resolved_gutter[2] == "OculusInspectThreadResolved", vim.inspect(resolved_gutter))
  -- Inline threads replace the end-of-line labels and the hover float.
  assert(marks(change)[5] == nil and marks(change)[8] == nil, vim.inspect(marks(change)))
  vim.api.nvim_set_current_win(change.win)
  vim.api.nvim_win_set_cursor(change.win, { 5, 0 })
  inspect._review.on_cursor_moved(change)
  assert(change.review_float == nil, "no float over inline threads")
  -- ]r keeps the whole file and moves between the threads in place.
  inspect._review.jump(group, session, "change", 1)
  assert(session.focused_chunks == false)
  assert(vim.api.nvim_win_get_cursor(change.win)[1] == 8)
  assert(change.review_float == nil)
  -- Putting them away restores the chunk the file was showing.
  assert(inspect._review.toggle_inline(group))
  assert(not group.review_inline)
  assert(session.focused_chunks and session.active_chunk == 2)
  assert(session.review_inline_chunk == nil)
  assert(next(inline_marks(change)) == nil, vim.inspect(inline_marks(change)))
  assert(marks(change)[8] == "  ◆ @alice: Second chunk", vim.inspect(marks(change)))
  -- r on the overview page is what loads and unloads them.
  inspect._show_inspection_overview(group)
  local overview_buf = vim.api.nvim_win_get_buf(group.overview_win)
  assert(group.overview_footer_win == nil or not vim.api.nvim_win_is_valid(group.overview_footer_win))

  local function shortcuts_text()
    inspect._overview_ui.open_shortcuts(group)

    local lines = table.concat(
      vim.api.nvim_buf_get_lines(
        group.overview_shortcuts_buf,
        0,
        -1,
        false
      ),
      "\n"
    )

    inspect._overview_ui.close_shortcuts(group)
    return lines
  end

  assert(shortcuts_text():find("Show review threads", 1, true), shortcuts_text())
  assert(vim.api.nvim_get_current_buf() == overview_buf)
  local toggle_map = assert(vim.fn.maparg("r", "n", false, true).callback)
  toggle_map()
  assert(group.review_inline)
  assert(shortcuts_text():find("Hide review threads", 1, true), shortcuts_text())
  toggle_map()
  assert(not group.review_inline)
  assert(shortcuts_text():find("Show review threads", 1, true), shortcuts_text())
  inspect._close_overview_window(group)
  -- <C-r> in a file shows the threads on the chunk it is showing, on their own.
  vim.api.nvim_set_current_tabpage(change.tab)
  vim.api.nvim_set_current_win(change.win)
  local chunk_map = assert(vim.fn.maparg("<C-r>", "n", false, true).callback)
  assert(session.focused_chunks and session.active_chunk == 2)
  chunk_map()
  assert(not group.review_inline)
  assert(session.focused_chunks and session.active_chunk == 2)

  assert(vim.deep_equal(
    inline_marks(change)[8],
    { "  ◆ @alice", "    Second chunk" }
  ), vim.inspect(inline_marks(change)))

  assert(marks(change)[8] == nil, vim.inspect(marks(change)))
  chunk_map()
  assert(next(inline_marks(change)) == nil, vim.inspect(inline_marks(change)))
  assert(marks(change)[8] == "  ◆ @alice: Second chunk", vim.inspect(marks(change)))
  -- A chunk can differ from the workflow-wide setting, which resets it.
  assert(inspect._review.toggle_inline(group))
  assert(group.review_inline and session.focused_chunks == false)
  assert(next(inline_marks(change)) ~= nil)
  chunk_map()
  assert(group.review_inline)
  assert(next(inline_marks(change)) == nil, vim.inspect(inline_marks(change)))
  assert(marks(change)[8] == "  ◆ @alice: Second chunk", vim.inspect(marks(change)))
  assert(inspect._review.toggle_inline(group))
  assert(not group.review_inline and session.review_inline_views == nil)
  assert(session.focused_chunks and session.active_chunk == 2)
  assert(marks(change)[8] == "  ◆ @alice: Second chunk", vim.inspect(marks(change)))

  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    if not vim.tbl_contains(tabs_before, tab) and vim.api.nvim_tabpage_is_valid(tab) then
      vim.api.nvim_set_current_tabpage(tab)
      vim.cmd("tabclose!")
    end
  end
end

print("review_spec: ok")
