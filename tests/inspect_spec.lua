local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.api.nvim_set_hl(0, "Normal", {
  fg = 0xd0d0d0,
  bg = 0x101820,
})
vim.api.nvim_set_hl(0, "DiffDelete", {
  fg = 0xff8080,
  bg = 0x401820,
})
vim.api.nvim_set_hl(0, "DiffAdd", {
  fg = 0x80ff80,
  bg = 0x104020,
})
local oil_runtime = vim.env.OCULUS_INSPECT_TEST_OIL
if oil_runtime then
  vim.opt.runtimepath:append(oil_runtime)
end

local inspect = require("oculus.inspect")
local oculus = require("oculus")
assert(oculus.config.inspect_sidebar_toggle == "<leader>oi")
assert(math.abs(
  oculus.config.inspect_sidebar_width - (28 / vim.o.columns)
) < 0.000001)
assert(inspect._inspect_sidebar_width(
  oculus.config.inspect_sidebar_width,
  vim.o.columns
) == 28)
assert(oculus.config.inspect_overview_toggle == "o")
assert(oculus.config.inspect_version_switch == "<C-s>")
assert(oculus.config.inspect_next_chunk == "<Tab>")
assert(oculus.config.inspect_previous_chunk == "<S-Tab>")
assert(oculus.config.inspect_next_file == nil)

for group, expected in pairs({
  OculusInspectRemoved = { fg = 0xfee2e2, bg = 0x991b1b },
  OculusInspectAdded = { fg = 0xdcfce7, bg = 0x166534 },
}) do
  local sign_highlight =
    vim.api.nvim_get_hl(0, { name = group, link = false })
  assert(sign_highlight.fg == expected.fg)
  assert(sign_highlight.bg == expected.bg)
  vim.api.nvim_set_hl(0, group, { fg = 1, bg = 2 })
end
vim.api.nvim_exec_autocmds("ColorScheme", {})
for group, expected in pairs({
  OculusInspectRemoved = { fg = 0xfee2e2, bg = 0x991b1b },
  OculusInspectAdded = { fg = 0xdcfce7, bg = 0x166534 },
}) do
  local sign_highlight =
    vim.api.nvim_get_hl(0, { name = group, link = false })
  assert(sign_highlight.fg == expected.fg)
  assert(sign_highlight.bg == expected.bg)
end

local dimming_win = vim.api.nvim_get_current_win()
local original_winhighlight = vim.wo[dimming_win].winhighlight
vim.wo[dimming_win].winhighlight =
  "NormalNC:Comment,CursorLine:Visual"
assert(inspect._prevent_window_dimming(dimming_win))
assert(vim.wo[dimming_win].winhighlight
  == "CursorLine:Visual,NormalNC:Normal")
vim.wo[dimming_win].winhighlight = original_winhighlight

local highlight_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(
  highlight_buf,
  0,
  -1,
  false,
  { "local highlighted = true" }
)
vim.bo[highlight_buf].filetype = "lua"
vim.bo[highlight_buf].syntax = "lua"
vim.b[highlight_buf].oculus_inspect = { role = "change" }
local fake_highlighter = {}
local invalidated = false
local parsed = false
local parser = {
  invalidate = function(_, reload)
    assert(reload == true)
    invalidated = true
  end,
  parse = function(_, range, callback)
    assert(range == true)
    parsed = true
    callback()
  end,
}
local original_highlighter =
  vim.treesitter.highlighter.active[highlight_buf]
local original_get_parser = vim.treesitter.get_parser
local original_stop = vim.treesitter.stop
local original_start = vim.treesitter.start
vim.treesitter.highlighter.active[highlight_buf] = fake_highlighter
vim.treesitter.get_parser = function(buf)
  assert(buf == highlight_buf)
  return parser
end
vim.treesitter.stop = function()
  error("refresh must preserve the active highlighter")
end
vim.treesitter.start = function()
  error("refresh must preserve the active highlighter")
end
assert(inspect._refresh_buffer_highlighting(highlight_buf))
assert(vim.bo[highlight_buf].syntax == "lua")
assert(invalidated)
assert(parsed)
assert(vim.treesitter.highlighter.active[highlight_buf]
  == fake_highlighter)
invalidated = false
parsed = false
assert(inspect._refresh_buffer_highlighting(highlight_buf))
assert(not invalidated)
assert(not parsed)
vim.treesitter.highlighter.active[highlight_buf] = original_highlighter
vim.treesitter.get_parser = original_get_parser
vim.treesitter.stop = original_stop
vim.treesitter.start = original_start
vim.api.nvim_buf_delete(highlight_buf, { force = true })

local filetype_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(
  filetype_buf,
  0,
  -1,
  false,
  { "print('inspected python')" }
)
vim.bo[filetype_buf].filetype = "lua"
vim.b[filetype_buf].oculus_inspect = {
  role = "parent",
  source_path = vim.fs.joinpath(root, "src", "inspection.py"),
}
local original_reliquary = package.loaded.reliquary
local reliquary_buf
local reliquary_filetype
package.loaded.reliquary = {
  apply = function(buf)
    reliquary_buf = buf
    reliquary_filetype = vim.bo[buf].filetype
    return "st"
  end,
}
local filetype_current_buf = vim.api.nvim_get_current_buf()
assert(inspect._apply_inspection_filetype(filetype_buf) == "python")
assert(vim.bo[filetype_buf].filetype == "python")
assert(reliquary_buf == filetype_buf)
assert(reliquary_filetype == "python")
assert(vim.api.nvim_get_current_buf() == filetype_current_buf)
package.loaded.reliquary = original_reliquary
vim.api.nvim_buf_delete(filetype_buf, { force = true })

local viewport_buf = vim.api.nvim_get_current_buf()
local viewport_win = vim.api.nvim_get_current_win()
local viewport_lines = {}
for index = 1, 40 do
  viewport_lines[index] = "line " .. index
end
vim.api.nvim_buf_set_lines(
  viewport_buf,
  0,
  -1,
  false,
  viewport_lines
)
for _, expected in ipairs({
  { cursor = 5, topline = 1, column = 0 },
  {
    cursor = 15,
    topline = 5,
    column = #viewport_lines[15] - 1,
  },
}) do
  vim.api.nvim_win_call(viewport_win, function()
    vim.fn.winrestview({ topline = 1 })
  end)
  vim.api.nvim_win_set_cursor(viewport_win, { expected.cursor, 0 })
  inspect._normalize_inspection_view(viewport_win)
  local view = vim.api.nvim_win_call(viewport_win, vim.fn.winsaveview)
  local cursor = vim.api.nvim_win_get_cursor(viewport_win)
  assert(view.topline == expected.topline)
  assert(cursor[2] == expected.column)
end

local comment = inspect.activity_comment({
  type = "PullRequestReviewCommentEvent",
  payload = {
    comment = {
      body = "Please keep this branch explicit.",
      path = "lua/oculus/inspect.lua",
      start_line = 15,
      line = 17,
      side = "RIGHT",
      commit_id = "aaaaaaaa",
    },
  },
})
assert(comment)
assert(comment.body == "Please keep this branch explicit.")
assert(comment.path == "lua/oculus/inspect.lua")
assert(comment.line == 15)
assert(comment.side == "change")
assert(comment.commit == "aaaaaaaa")
local left_comment = inspect.activity_comment({
  type = "PullRequestReviewCommentEvent",
  payload = {
    comment = {
      body = "This was removed.",
      path = "lua/oculus/inspect.lua",
      original_line = 12,
      side = "LEFT",
      original_commit_id = "bbbbbbbb",
    },
  },
})
assert(left_comment)
assert(left_comment.line == 12)
assert(left_comment.side == "parent")
assert(left_comment.commit == "bbbbbbbb")
assert(inspect.activity_comment({
  type = "IssueCommentEvent",
  payload = {
    comment = {
      body = "Not attached to code.",
      path = "README.md",
      line = 1,
    },
  },
}) == nil)

local comment_view = assert(inspect._comment_float({
  tab = vim.api.nvim_get_current_tabpage(),
  win = viewport_win,
  buf = viewport_buf,
}, comment))
assert(vim.api.nvim_get_current_win() == viewport_win)
local comment_config = vim.api.nvim_win_get_config(comment_view.win)
assert(comment_config.relative == "win")
assert(comment_config.win == viewport_win)
assert(comment_config.anchor == "SW")
assert(comment_config.bufpos[1] == comment.line - 1)
assert(comment_config.col > 0)
assert(comment_config.focusable == false)
assert(vim.api.nvim_buf_get_lines(
  comment_view.buf,
  0,
  -1,
  false
)[1] == comment.body)
vim.api.nvim_win_close(comment_view.win, true)

vim.api.nvim_buf_set_lines(viewport_buf, 0, -1, false, { "" })
vim.api.nvim_win_set_cursor(viewport_win, { 1, 0 })
vim.bo[viewport_buf].modified = false

local shortened_sidebar_row = inspect._sidebar_row(
  "a-very-long-changed-file-name.lua",
  24
)
assert(shortened_sidebar_row.line:match("^• …"))
assert(shortened_sidebar_row.line:match(" P C $"))
assert(shortened_sidebar_row.parent_column
  < shortened_sidebar_row.change_column)
assert(vim.fn.strdisplaywidth(shortened_sidebar_row.line) == 24)
assert(inspect._sidebar_chunk_row(
  { old_count = 1, new_start = 25, new_count = 4 },
  false
) == "  ├─ 25-28 (+3)")
assert(inspect._sidebar_chunk_row(
  { old_count = 2, new_start = 31, new_count = 0 },
  true
) == "  └─ 31-31 (-2)")
assert(inspect._sidebar_chunk_row(
  { old_count = 2, new_start = 40, new_count = 2 },
  true
) == "  └─ 40-41 (0)")
assert(inspect._sidebar_file(
  "a/very/long/path/to/a/changed/file.lua"
) == "changed/file.lua")
assert(inspect._sidebar_file(
  "lua\\oculus\\inspect.lua"
) == "oculus/inspect.lua")
assert(inspect._sidebar_file("README.md") == "README.md")
assert(inspect._sidebar_target_role(
  1,
  "change",
  { pair_index = 2 }
) == "parent")
assert(inspect._sidebar_target_role(
  1,
  "change",
  { pair_index = 1 }
) == "change")

assert(inspect._inspection_directory(
  root,
  "lua/oculus/inspect.lua"
) == vim.fs.joinpath(root, "lua", "oculus"))
assert(inspect._inspection_directory(
  root,
  "not-present/inspect.lua"
) == root)
assert(inspect._inspection_statusline_path({
  repository = root,
  source_path = vim.fs.joinpath(root, "lua", "oculus", "inspect.lua"),
  file = "lua/oculus/inspect.lua",
}) == vim.fs.basename(root) .. "/lua/oculus/inspect.lua")

local parsed = inspect._parse_commit_url(
  "https://github.com/neovim/neovim/commit/"
    .. "0123456789abcdef0123456789abcdef01234567#diff"
)
assert(parsed)
assert(parsed.owner == "neovim")
assert(parsed.repo == "neovim")
assert(parsed.sha == "0123456789abcdef0123456789abcdef01234567")
assert(parsed.remote_url == "https://github.com/neovim/neovim.git")

local codeberg_commit = inspect._parse_commit_url(
  "https://codeberg.org/ziglang/zig/commit/0123456"
)
assert(codeberg_commit)
assert(codeberg_commit.forge == "codeberg")
assert(codeberg_commit.owner == "ziglang")
assert(codeberg_commit.repo == "zig")
assert(codeberg_commit.sha == "0123456")
assert(codeberg_commit.remote_url == "https://codeberg.org/ziglang/zig.git")
assert(inspect._parse_commit_url("https://github.com/a/b/issues/1") == nil)
assert(inspect._parse_commit_url("https://github.com/a/b/commit/123") == nil)
assert(inspect._parse_commit_url(
  "https://github.com/a/b/commit/01234567890123456789012345678901234567890"
) == nil)
assert(inspect._parse_commit_url(
  "https://github.com/../b/commit/0123456"
) == nil)

local pull_request = inspect._parse_pull_request_url(
  "https://github.com/neovim/neovim/pull/123/files#diff-test"
)
assert(pull_request)
assert(pull_request.kind == "pull_request")
assert(pull_request.owner == "neovim")
assert(pull_request.repo == "neovim")
assert(pull_request.number == 123)
assert(inspect._parse_pull_request_url(
  "https://github.com/neovim/neovim/issues/123#issuecomment-456"
) == nil)
assert(inspect._parse_pull_request_url(
  "https://github.com/neovim/neovim/issues/not-a-number"
) == nil)
local issue = inspect._parse_issue_url(
  "https://github.com/neovim/neovim/issues/123#issuecomment-456"
)
assert(issue)
assert(issue.kind == "issue")
assert(issue.forge == "github")
assert(issue.owner == "neovim")
assert(issue.repo == "neovim")
assert(issue.number == 123)
local codeberg_issue = inspect._parse_issue_url(
  "https://codeberg.org/ziglang/zig/issues/42"
)
assert(codeberg_issue)
assert(codeberg_issue.kind == "issue")
assert(codeberg_issue.forge == "codeberg")
assert(codeberg_issue.number == 42)
local codeberg_pull_request = inspect._parse_pull_request_url(
  "https://codeberg.org/ziglang/zig/pulls/35754#issuecomment-1"
)
assert(codeberg_pull_request)
assert(codeberg_pull_request.forge == "codeberg")
assert(codeberg_pull_request.owner == "ziglang")
assert(codeberg_pull_request.repo == "zig")
assert(codeberg_pull_request.number == 35754)
assert(not codeberg_pull_request.via_issue)
assert(codeberg_pull_request.remote_url
  == "https://codeberg.org/ziglang/zig.git")

local resolved_pull_request = inspect._apply_pull_request(pull_request, {
  title = "Test pull request",
  body = "This pull request improves the Inspect workflow.",
  author = "reviewer",
  state = "open",
  draft = false,
  merged = false,
  html_url = "https://github.com/neovim/neovim/pull/123",
  base_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  base_ref = "main",
  head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  head_ref = "feature",
  commit_count = 3,
})
assert(resolved_pull_request.base_ref == "main")
assert(resolved_pull_request.head_ref == "feature")
assert(resolved_pull_request.base_sha:match("^a+$"))
assert(resolved_pull_request.head_sha:match("^b+$"))
assert(resolved_pull_request.commit_count == 3)
assert(resolved_pull_request.author == "reviewer")

local pull_request_overview = inspect._inspection_overview(
  resolved_pull_request,
  {}
)
local pull_request_overview_text = table.concat(
  inspect._sidebar_overview_lines(pull_request_overview, 28),
  "\n"
)
assert(pull_request_overview_text:find(
  "OVERVIEW",
  1,
  true
))
assert(pull_request_overview_text:match("^OVERVIEW\n"))
assert(pull_request_overview_text:find("Test pull request", 1, true))
assert(pull_request_overview_text:find("#123", 1, true))
assert(pull_request_overview_text:find("@reviewer", 1, true))
assert(pull_request_overview_text:find(
  "This pull request improves",
  1,
  true
))
assert(pull_request_overview_text:find("\n  Title\n", 1, true))
assert(pull_request_overview_text:find("\n  Description\n", 1, true))
assert(pull_request_overview_text:find("\n  Author\n", 1, true))
assert(pull_request_overview_text:find("\n  URL\n", 1, true))
assert(pull_request_overview_text:find("\n  PR number\n", 1, true))
assert(pull_request_overview_text:find("\n  Status\n", 1, true))
assert(not pull_request_overview_text:find("Repository", 1, true))
assert(not pull_request_overview_text:find("Branches", 1, true))
assert(not pull_request_overview_text:find("Changes", 1, true))
assert(not pull_request_overview_text:find("Created", 1, true))
assert(not pull_request_overview_text:find("Updated", 1, true))
assert(not pull_request_overview_text:find("changed files", 1, true))

local parsed_commit_overview = inspect._parse_commit_overview(
  table.concat({
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "Ada Lovelace",
    "ada@example.com",
    "2026-07-30T12:00:00-04:00",
    "Keep Inspect context visible",
    "Show the relevant commit details in the sidebar.",
  }, "\0")
)
assert(parsed_commit_overview)
assert(parsed_commit_overview.author_name == "Ada Lovelace")
assert(parsed_commit_overview.subject == "Keep Inspect context visible")
local commit_overview = inspect._inspection_overview({
  kind = "commit",
  forge = "github",
  host = "github.com",
  owner = "neovim",
  repo = "neovim",
  sha = parsed_commit_overview.sha,
  commit_details = parsed_commit_overview,
}, {
  {
    change_file = "lua/inspect.lua",
    commit_index = 1,
    hunks = {
      { old_count = 2, new_count = 5 },
    },
  },
})
local commit_overview_text = table.concat(
  inspect._sidebar_overview_lines(commit_overview, 28),
  "\n"
)
assert(commit_overview_text:match("^OVERVIEW\n"))
assert(commit_overview_text:find(
  "Keep Inspect context",
  1,
  true
))
assert(commit_overview_text:find("Ada Lovelace", 1, true))
assert(commit_overview_text:find("\n  Title\n", 1, true))
assert(commit_overview_text:find("\n  Description\n", 1, true))
assert(commit_overview_text:find("\n  Author\n", 1, true))
assert(commit_overview_text:find("\n  URL\n", 1, true))
assert(not commit_overview_text:find("Repository", 1, true))
assert(not commit_overview_text:find("\nCommit\n", 1, true))
assert(not commit_overview_text:find("Authored", 1, true))
assert(not commit_overview_text:find("Changes", 1, true))
do
  local main_config = require("oculus.window").window_config({})
  local compact_config = inspect._overview_window_config(
    main_config,
    { kind = "commit" }
  )
  assert(compact_config.width
    == math.max(20, math.floor(main_config.width * 0.8)))
  assert(compact_config.height
    == math.max(8, math.floor(main_config.height * 0.8)))
  assert(compact_config.col > main_config.col)
  assert(compact_config.row > main_config.row)
  local pull_request_config = inspect._overview_window_config(
    main_config,
    { kind = "pull_request" }
  )
  assert(pull_request_config.width == main_config.width)
  assert(pull_request_config.height == main_config.height)
  assert(pull_request_config.col == main_config.col)
  assert(pull_request_config.row == main_config.row)
end

local issue_context = inspect.activity_context({
  type = "IssueCommentEvent",
  payload = {
    issue = {
      number = 123,
      title = "Inspection loses focus",
      body = "The problem is in lua/oculus/inspect.lua:10.",
    },
    comment = {
      body = "Also check `open_issue`.",
    },
  },
})
assert(issue_context)
assert(issue_context.issue.number == 123)
assert(issue_context.issue.title == "Inspection loses focus")
assert(issue_context.issue.body:find("inspect.lua:10", 1, true))
assert(issue_context.issue.comment == "Also check `open_issue`.")

local revision_pairs = inspect._parse_revision_pairs(table.concat({
  "1111111 aaaaaaa",
  "2222222 1111111",
  "3333333 2222222 bbbbbbb",
}, "\n"))
assert(#revision_pairs == 3)
assert(revision_pairs[1].parent == "aaaaaaa")
assert(revision_pairs[1].commit == "1111111")
assert(revision_pairs[3].parent == "2222222")
assert(revision_pairs[3].commit == "3333333")

assert(inspect._github_repository(
  "https://github.com/neovim/neovim.git"
) == "neovim/neovim")
assert(inspect._github_repository(
  "git@github.com:Neovim/Neovim.git"
) == "neovim/neovim")
assert(inspect._github_repository(
  "ssh://git@github.com/neovim/neovim.git"
) == "neovim/neovim")
assert(inspect._github_repository("https://codeberg.org/a/b.git") == nil)
local forge, repository = inspect._forge_repository(
  "https://codeberg.org/ziglang/zig.git"
)
assert(forge == "codeberg")
assert(repository == "ziglang/zig")
forge, repository = inspect._forge_repository(
  "git@codeberg.org:ziglang/zig.git"
)
assert(forge == "codeberg")
assert(repository == "ziglang/zig")
forge, repository = inspect._forge_repository(
  "ssh://git@codeberg.org/ziglang/zig.git"
)
assert(forge == "codeberg")
assert(repository == "ziglang/zig")

local renamed_search_root = vim.fn.tempname()
local renamed_repository = vim.fs.joinpath(
  renamed_search_root,
  "mirrors",
  "editor-source"
)
assert(vim.fn.mkdir(renamed_repository, "p") == 1)
local init_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "init",
}, { text = true }):wait()
assert(init_result.code == 0, init_result.stderr)
local remote_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "remote",
  "add",
  "upstream",
  "https://github.com/neovim/neovim.git",
}, { text = true }):wait()
assert(remote_result.code == 0, remote_result.stderr)
local found_renamed_repository
local found_renamed_remote
inspect._find_local_repository({
  kind = "commit",
  forge = "github",
  owner = "neovim",
  repo = "neovim",
  sha = "0123456789abcdef0123456789abcdef01234567",
  remote_url = "https://github.com/neovim/neovim.git",
}, {
  inspect_repositories = {},
  inspect_search_paths = { renamed_search_root },
}, function(path, remote)
  found_renamed_repository = path
  found_renamed_remote = remote
end)
assert(vim.wait(10000, function()
  return found_renamed_repository ~= nil
end), "renamed local repository was not found")
assert(vim.fs.normalize(found_renamed_repository)
  == vim.fs.normalize(renamed_repository))
assert(found_renamed_remote == "upstream")

local commit_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "-c",
  "user.name=Oculus Test",
  "-c",
  "user.email=oculus@example.invalid",
  "commit",
  "--allow-empty",
  "-m",
  "local identity fixture",
}, { text = true }):wait()
assert(commit_result.code == 0, commit_result.stderr)
local fixture_sha_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "rev-parse",
  "HEAD",
}, { text = true }):wait()
assert(fixture_sha_result.code == 0, fixture_sha_result.stderr)
local fixture_sha = vim.trim(fixture_sha_result.stdout)
local alias_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "remote",
  "set-url",
  "upstream",
  "git@github-work:neovim/neovim.git",
}, { text = true }):wait()
assert(alias_result.code == 0, alias_result.stderr)
local found_alias_repository
local found_alias_fetch_source
inspect._find_local_repository({
  kind = "commit",
  forge = "github",
  owner = "neovim",
  repo = "neovim",
  sha = fixture_sha,
  remote_url = "https://github.com/neovim/neovim.git",
}, {
  inspect_repositories = {},
  inspect_search_paths = { renamed_search_root },
}, function(path, fetch_source)
  found_alias_repository = path
  found_alias_fetch_source = fetch_source
end)
assert(vim.wait(10000, function()
  return found_alias_repository ~= nil
end), "repository with a custom remote alias was not found")
assert(vim.fs.normalize(found_alias_repository)
  == vim.fs.normalize(renamed_repository))
assert(found_alias_fetch_source
  == "https://github.com/neovim/neovim.git")
assert(vim.fn.delete(renamed_search_root, "rf") == 0)

local issue_lines = inspect._issue_page_lines({
  forge = "github",
  host = "github.com",
  owner = "andrewgilley",
  repo = "oculus.nvim",
  number = 77,
}, {
  number = 77,
  title = "Issue inspect fixture",
  body = "Issue body\nwith a second line.",
  comment = "Activity comment fixture.",
  html_url = "https://github.com/andrewgilley/oculus.nvim/issues/77",
})
local issue_text = table.concat(issue_lines, "\n")
assert(issue_text:find("# Issue inspect fixture", 1, true))
assert(issue_text:find("Repository: `andrewgilley/oculus.nvim`", 1, true))
assert(issue_text:find("## Description", 1, true))
assert(issue_text:find("Issue body\nwith a second line.", 1, true))
assert(issue_text:find("## Activity comment", 1, true))
assert(issue_text:find("Activity comment fixture.", 1, true))
local empty_issue_text = table.concat(inspect._issue_page_lines({
  forge = "codeberg",
  host = "codeberg.org",
  owner = "example",
  repo = "project",
  number = 8,
}, { number = 8 }), "\n")
assert(empty_issue_text:find("# Issue #8", 1, true))
assert(empty_issue_text:find("_No description was provided._", 1, true))

local github = require("oculus.github")
local original_issue = github.issue
github.issue = function(repo, number, _, callback)
  assert(repo == "andrewgilley/oculus.nvim")
  assert(number == 77)
  callback({
    number = number,
    title = "Issue inspect fixture",
    body = "The issue information should open without identifying files.",
    html_url = "https://github.com/andrewgilley/oculus.nvim/issues/77",
  })
end
local issue_tabs_before = vim.api.nvim_list_tabpages()
local issue_origin_win = vim.api.nvim_get_current_win()
local issue_origin_number = vim.wo[issue_origin_win].number
local issue_origin_relativenumber = vim.wo[issue_origin_win].relativenumber
vim.wo[issue_origin_win].number = true
vim.wo[issue_origin_win].relativenumber = true
local issue_lifecycle_complete = false
local issue_lifecycle_error
local issue_ok, issue_err = inspect.open(
  "https://github.com/andrewgilley/oculus.nvim/issues/77",
  {},
  {
    issue = {
      comment = "The activity comment belongs on the information page.",
    },
  },
  {
    on_progress = function() end,
    on_complete = function(message)
      issue_lifecycle_error = message
      issue_lifecycle_complete = true
    end,
  }
)
assert(issue_ok, issue_err)
assert(vim.wait(10000, function()
  return issue_lifecycle_complete
end), "issue information page was not opened")
assert(not issue_lifecycle_error, issue_lifecycle_error)
github.issue = original_issue
local issue_tabs_after = vim.api.nvim_list_tabpages()
assert(#issue_tabs_after == #issue_tabs_before + 1)
local issue_tab = issue_tabs_after[#issue_tabs_after]
assert(vim.api.nvim_get_current_tabpage() == issue_tab)
assert(#vim.api.nvim_tabpage_list_wins(issue_tab) == 1)
local issue_state = vim.api.nvim_tabpage_get_var(issue_tab, "oculus_inspect")
assert(issue_state.kind == "issue")
assert(issue_state.role == "issue")
assert(issue_state.issue_number == 77)
assert(issue_state.issue_title == "Issue inspect fixture")
local issue_buf = vim.api.nvim_get_current_buf()
assert(vim.bo[issue_buf].buftype == "nofile")
assert(vim.bo[issue_buf].filetype == "markdown")
assert(vim.bo[issue_buf].readonly)
assert(not vim.bo[issue_buf].modifiable)
assert(vim.wo.wrap)
assert(vim.wo.linebreak)
assert(vim.wo.signcolumn == "no")
assert(vim.wo.number)
assert(vim.wo.relativenumber)
local issue_page = table.concat(
  vim.api.nvim_buf_get_lines(issue_buf, 0, -1, false),
  "\n"
)
assert(issue_page:find("# Issue inspect fixture", 1, true))
assert(issue_page:find(
  "The issue information should open without identifying files.",
  1,
  true
))
assert(issue_page:find("## Activity comment", 1, true))
assert(issue_page:find(
  "The activity comment belongs on the information page.",
  1,
  true
))
vim.cmd("tabclose")
vim.api.nvim_set_current_win(issue_origin_win)
vim.wo[issue_origin_win].number = issue_origin_number
vim.wo[issue_origin_win].relativenumber = issue_origin_relativenumber

local parent, change = inspect._first_changed_paths("M\tlua/oculus/init.lua")
assert(parent == "lua/oculus/init.lua")
assert(change == "lua/oculus/init.lua")

parent, change = inspect._first_changed_paths(
  "R100\tlua/oculus/old.lua\tlua/oculus/new.lua"
)
assert(parent == "lua/oculus/old.lua")
assert(change == "lua/oculus/new.lua")

parent, change = inspect._first_changed_paths("")
assert(parent == nil)
assert(change == nil)

local changed_files = inspect._parse_changed_files(table.concat({
  "M\tlua/oculus/inspect.lua",
  "A\tlua/oculus/new.lua",
  "D\tlua/oculus/old.lua",
  "R100\tREADME.old.md\tREADME.md",
}, "\n"))
assert(#changed_files == 4)
assert(changed_files[1].status == "M")
assert(changed_files[2].new_path == "lua/oculus/new.lua")
assert(changed_files[4].old_path == "README.old.md")
assert(changed_files[4].new_path == "README.md")
local oil_session = { changes = changed_files }
assert(inspect._oil_entry_status(
  oil_session,
  "change",
  "lua/oculus/new.lua",
  false
) == "A")
assert(inspect._oil_entry_status(
  oil_session,
  "parent",
  "lua/oculus/old.lua",
  false
) == "D")
assert(inspect._oil_entry_status(
  oil_session,
  "change",
  "lua",
  true
) == "directory")
assert(inspect._oil_entry_status(
  oil_session,
  "parent",
  "lua/oculus/new.lua",
  false
) == nil)
assert(inspect._entered_oil_subdirectory(
  root,
  vim.fs.joinpath(root, "lua", "oculus")
))
assert(not inspect._entered_oil_subdirectory(
  vim.fs.joinpath(root, "lua"),
  root
))
vim.api.nvim_buf_set_lines(
  viewport_buf,
  0,
  -1,
  false,
  { "nested", "unchanged.lua", "new.lua", "old.lua" }
)
assert(inspect._first_changed_oil_file_line(
  viewport_buf,
  oil_session,
  "change",
  "lua/oculus",
  {
    get_entry_on_line = function(_, line)
      if line == 1 then
        return { name = "nested", type = "directory" }
      elseif line == 2 then
        return { name = "unchanged.lua", type = "file" }
      elseif line == 3 then
        return { name = "new.lua", type = "file" }
      end
      return { name = "old.lua", type = "file" }
    end,
  }
) == 3)

local hunks = inspect._parse_hunks(table.concat({
  "@@ -10,2 +10,3 @@ local function changed()",
  "@@ -24 +25,0 @@",
  "@@ -30,0 +31,4 @@",
}, "\n"))
assert(#hunks == 3)
assert(hunks[1].old_start == 10)
assert(hunks[1].old_count == 2)
assert(hunks[1].new_start == 10)
assert(hunks[1].new_count == 3)
assert(hunks[2].old_count == 1)
assert(hunks[2].new_count == 0)
assert(hunks[3].old_count == 0)
assert(hunks[3].new_count == 4)
local focused_lines, focused_start = inspect._focused_change_lines(
  { "one", "old first", "middle", "old second", "tail" },
  { "one", "new first a", "new first b", "middle", "new second", "tail" },
  {
    old_start = 4,
    old_count = 1,
    new_start = 5,
    new_count = 1,
  }
)
assert(vim.deep_equal(focused_lines, {
  "one",
  "old first",
  "middle",
  "new second",
  "tail",
}))
assert(focused_start == 4)
focused_lines, focused_start = inspect._focused_change_lines(
  { "one", "old a", "old b", "tail" },
  { "one", "new a", "new b", "new c", "tail" },
  {
    old_start = 2,
    old_count = 2,
    new_start = 2,
    new_count = 3,
  }
)
assert(vim.deep_equal(focused_lines, {
  "one",
  "new a",
  "new b",
  "new c",
  "tail",
}))
assert(focused_start == 2)
focused_lines, focused_start = inspect._focused_change_lines(
  { "one", "tail" },
  { "one", "inserted", "tail" },
  {
    old_start = 1,
    old_count = 0,
    new_start = 2,
    new_count = 1,
  }
)
assert(vim.deep_equal(focused_lines, {
  "one",
  "inserted",
  "tail",
}))
assert(focused_start == 2)
focused_lines, focused_start = inspect._focused_change_lines(
  { "one", "removed", "tail" },
  { "one", "tail" },
  {
    old_start = 2,
    old_count = 1,
    new_start = 2,
    new_count = 0,
  }
)
assert(vim.deep_equal(focused_lines, { "one", "tail" }))
assert(focused_start == 2)
focused_lines, focused_start = inspect._focused_change_lines(
  { "" },
  { "new one", "new two" },
  {
    old_start = 0,
    old_count = 0,
    new_start = 1,
    new_count = 2,
  }
)
assert(vim.deep_equal(focused_lines, { "new one", "new two" }))
assert(focused_start == 1)
local jump_lines = inspect._change_lines(hunks)
assert(vim.deep_equal(jump_lines, { 10, 25, 31 }))
assert(vim.deep_equal(
  inspect._change_lines(hunks, "parent"),
  { 10, 24, 30 }
))

local missing_root = vim.env.OCULUS_INSPECT_TEST_MISSING_ROOT
if missing_root then
  local original_select = vim.ui.select
  local prompted = false
  vim.ui.select = function(items, select_opts, on_choice)
    prompted = true
    assert(select_opts.prompt:match("Download it to"))
    on_choice(items[2])
  end
  local source_root = vim.fs.joinpath(missing_root, "source")
  local tabs_before_missing = #vim.api.nvim_list_tabpages()
  local missing_error
  local missing_progress = 0
  local ok, err = inspect.open(
    "https://github.com/oculus/missing/commit/"
      .. "0123456789abcdef0123456789abcdef01234567",
    {
      inspect_search_paths = { source_root },
      inspect_repositories = {},
    },
    nil,
    {
      on_progress = function()
        missing_progress = missing_progress + 1
      end,
      on_complete = function(message)
        missing_error = message
      end,
    }
  )
  assert(ok, err)
  assert(vim.wait(10000, function()
    return missing_error ~= nil
  end), "missing local repository did not stop inspection")
  vim.ui.select = original_select
  assert(prompted)
  assert(missing_progress > 0)
  assert(#vim.api.nvim_list_tabpages() == tabs_before_missing)
  assert(missing_error:match("download was declined"))
  assert(vim.uv.fs_stat(vim.fs.joinpath(source_root, "missing")) == nil)
  assert(vim.uv.fs_stat(vim.fs.joinpath(missing_root, "repositories")) == nil)
end

local download_root = vim.env.OCULUS_INSPECT_TEST_DOWNLOAD_ROOT
local download_source = vim.env.OCULUS_INSPECT_TEST_DOWNLOAD_SOURCE

local existing_repository = vim.fs.normalize(vim.fn.getcwd())
local existing_repository_result
local existing_repository_error
inspect._offer_repository_download({
  owner = "andrewgilley",
  repo = vim.fs.basename(existing_repository),
  remote_url = "https://github.com/andrewgilley/oculus.nvim.git",
}, {
  inspect_search_paths = { vim.fs.dirname(existing_repository) },
}, function(path, err)
  existing_repository_result = path
  existing_repository_error = err
end)
assert(existing_repository_result, existing_repository_error)
assert(vim.fs.normalize(existing_repository_result) == existing_repository)

if download_root and download_source then
  local original_select = vim.ui.select
  local prompted = false
  vim.ui.select = function(items, select_opts, on_choice)
    prompted = true
    assert(select_opts.prompt:match("Download it to"))
    on_choice(items[1])
  end
  local downloaded
  local download_err
  inspect._offer_repository_download({
    owner = "oculus",
    repo = "downloaded",
    remote_url = download_source,
  }, {
    inspect_search_paths = { download_root },
  }, function(path, err)
    downloaded = path
    download_err = err
  end)
  assert(vim.wait(30000, function()
    return downloaded ~= nil or download_err ~= nil
  end), "repository download prompt did not finish")
  vim.ui.select = original_select
  assert(prompted)
  assert(downloaded, download_err)
  assert(downloaded == vim.fs.joinpath(download_root, "downloaded"))
  assert(vim.uv.fs_stat(vim.fs.joinpath(downloaded, ".git")))
end

local integration_root = vim.env.OCULUS_INSPECT_TEST_ROOT
local integration_sha = vim.env.OCULUS_INSPECT_TEST_SHA
local integration_url = vim.env.OCULUS_INSPECT_TEST_URL
local expected_pair_count = tonumber(
  vim.env.OCULUS_INSPECT_TEST_PAIR_COUNT
)
local expected_commit_count = tonumber(
  vim.env.OCULUS_INSPECT_TEST_COMMIT_COUNT
)
if integration_root and (integration_sha or integration_url) then
  local integration_repository =
    vim.env.OCULUS_INSPECT_TEST_REPOSITORY or "oculus/test"
  local integration_source = vim.env.OCULUS_INSPECT_TEST_SOURCE
  local integration_search_root =
    vim.env.OCULUS_INSPECT_TEST_SEARCH_ROOT
  local expected_source_root =
    vim.env.OCULUS_INSPECT_TEST_EXPECT_SOURCE_ROOT
      or integration_source
  local expect_no_worktrees =
    vim.env.OCULUS_INSPECT_TEST_NO_WORKTREES == "1"
  local expect_no_external_state =
    vim.env.OCULUS_INSPECT_TEST_NO_EXTERNAL_STATE == "1"
  local verify_revision_content =
    vim.env.OCULUS_INSPECT_TEST_VERIFY_CONTENT == "1"
  local integration_cwd = vim.env.OCULUS_INSPECT_TEST_CWD
  local repositories = {}
  local integration_is_pull_request = integration_url
    and integration_url:match("/pulls?/%d+")
  if integration_source then
    repositories[integration_repository] = integration_source
  end
  if integration_cwd then
    vim.api.nvim_set_current_dir(integration_cwd)
  end
  local initial_tab = vim.api.nvim_get_current_tabpage()
  local initial_tab_count = #vim.api.nvim_list_tabpages()
  local initial_lazyredraw = vim.o.lazyredraw
  local activity_closed_after_tabs_ready = false
  local oculus_window = require("oculus.window")
  local original_window_close = oculus_window.close
  oculus_window.close = function(...)
    oculus_window.close = original_window_close
    local ready_tabs = vim.api.nvim_list_tabpages()
    assert(vim.api.nvim_get_current_tabpage() == initial_tab)
    assert(#ready_tabs > initial_tab_count)
    assert((#ready_tabs - initial_tab_count) % 2 == 0)
    assert(vim.o.lazyredraw)
    for index = initial_tab_count + 1, #ready_tabs do
      local state = vim.api.nvim_tabpage_get_var(
        ready_tabs[index],
        "oculus_inspect"
      )
      assert(state.loading == false)
      assert(#vim.api.nvim_tabpage_list_wins(ready_tabs[index]) == 2)
    end
    activity_closed_after_tabs_ready = true
    return original_window_close(...)
  end
  local loading_frames = 0
  local lifecycle_complete = false
  local lifecycle_error
  vim.wo.number = true
  vim.wo.relativenumber = true
  local ok, err = inspect.open(
    integration_url
      or (
        "https://github.com/" .. integration_repository
        .. "/commit/" .. integration_sha
    ),
    {
      inspect_repositories = repositories,
      inspect_search_paths = integration_search_root
          and { integration_search_root }
        or {},
      inspect_sidebar_width = 0.30,
      inspect_overview_toggle = "gO",
      inspect_version_switch = "gS",
    },
    nil,
    {
      on_progress = function()
        loading_frames = loading_frames + 1
      end,
      on_complete = function(message)
        lifecycle_error = message
        lifecycle_complete = true
      end,
    }
  )
  assert(ok, err)
  assert(#vim.api.nvim_list_tabpages() == initial_tab_count)
  assert(loading_frames > 0)

  local inspection_error
  local inspection_finished = vim.wait(180000, function()
    local current_tabs = vim.api.nvim_list_tabpages()
    if #current_tabs <= initial_tab_count
      or (#current_tabs - initial_tab_count) % 2 ~= 0
    then
      return false
    end
    for index = 2, #current_tabs do
      local state_ok, state = pcall(
        vim.api.nvim_tabpage_get_var,
        current_tabs[index],
        "oculus_inspect"
      )
      if state_ok and state.error then
        inspection_error = state.error
        return true
      end
      if not state_ok or state.loading ~= false or state.commit == nil then
        return false
      end
    end
    return lifecycle_complete
  end)
  assert(inspection_finished, "inspection tabs were not opened")
  assert(not lifecycle_error, lifecycle_error)
  assert(not inspection_error, inspection_error)
  assert(activity_closed_after_tabs_ready)
  assert(vim.o.lazyredraw == initial_lazyredraw)

  local tabs = vim.api.nvim_list_tabpages()
  local pair_count = (#tabs - 1) / 2
  assert(pair_count >= 1)
  if expected_pair_count then
    assert(pair_count == expected_pair_count)
  end
  local commit_indices = {}
  local next_file_indices = {}
  local buffers = {}
  local sidebar_buf
  local sidebar_width
  local function inspection_window(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if type(vim.b[buf].oculus_inspect) == "table" then
        return win
      end
    end
  end
  local function sidebar_window(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "oculus-inspect-files" then
        return win
      end
    end
  end
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  local initial_parent_win = assert(inspection_window(tabs[2]))
  assert(vim.api.nvim_get_current_win() == initial_parent_win)
  for pair_index = 1, pair_count do
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2]
    ) == 2)
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2 + 1]
    ) == 2)
    assert(sidebar_window(tabs[pair_index * 2]))
    assert(sidebar_window(tabs[pair_index * 2 + 1]))
  end
  local initial_sidebar_toggle
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(
    vim.api.nvim_win_get_buf(initial_parent_win),
    "n"
  )) do
    if mapping.desc == "Toggle Oculus Inspect sidebar"
    then
      initial_sidebar_toggle = mapping
      break
    end
  end
  assert(initial_sidebar_toggle)
  assert(initial_sidebar_toggle.lhs
    == (vim.g.mapleader or "\\") .. "oi")
  for pair_index = 1, pair_count do
    local old_tab = tabs[pair_index * 2]
    local new_tab = tabs[pair_index * 2 + 1]
    assert(#vim.api.nvim_tabpage_list_wins(old_tab) == 2)
    assert(#vim.api.nvim_tabpage_list_wins(new_tab) == 2)
    local old_main_win = assert(inspection_window(old_tab))
    local new_main_win = assert(inspection_window(new_tab))
    assert(vim.wo[old_main_win].number == true)
    assert(vim.wo[old_main_win].relativenumber == true)
    assert(vim.wo[new_main_win].number == true)
    assert(vim.wo[new_main_win].relativenumber == true)
    assert(vim.wo[old_main_win].cursorline)
    assert(vim.wo[new_main_win].cursorline)
    assert(vim.wo[old_main_win].cursorlineopt == "line")
    assert(vim.wo[new_main_win].cursorlineopt == "line")
    assert(not vim.wo[old_main_win].winhighlight:find(
      "CursorLine:OculusCursorLine",
      1,
      true
    ))
    assert(not vim.wo[new_main_win].winhighlight:find(
      "CursorLine:OculusCursorLine",
      1,
      true
    ))
    local old_sidebar_win = assert(sidebar_window(old_tab))
    local new_sidebar_win = assert(sidebar_window(new_tab))
    local old_sidebar_buf = vim.api.nvim_win_get_buf(old_sidebar_win)
    local new_sidebar_buf = vim.api.nvim_win_get_buf(new_sidebar_win)
    sidebar_buf = sidebar_buf or old_sidebar_buf
    sidebar_width = sidebar_width
      or vim.api.nvim_win_get_width(old_sidebar_win)
    assert(old_sidebar_buf == sidebar_buf)
    assert(new_sidebar_buf == sidebar_buf)
    assert(vim.api.nvim_win_get_width(old_sidebar_win) == sidebar_width)
    assert(vim.api.nvim_win_get_width(new_sidebar_win) == sidebar_width)
    assert(sidebar_width == inspect._inspect_sidebar_width(
      0.30,
      vim.o.columns
    ))
    assert(vim.wo[old_sidebar_win].cursorline)
    assert(vim.wo[new_sidebar_win].cursorline)
    assert(vim.wo[old_sidebar_win].cursorlineopt == "line")
    assert(vim.wo[new_sidebar_win].cursorlineopt == "line")
    assert(vim.wo[old_main_win].winhighlight:find(
      "NormalNC:Normal",
      1,
      true
    ))
    assert(vim.wo[new_main_win].winhighlight:find(
      "NormalNC:Normal",
      1,
      true
    ))
    assert(vim.wo[old_sidebar_win].winhighlight:find(
      "NormalNC:Normal",
      1,
      true
    ))
    assert(vim.wo[new_sidebar_win].winhighlight:find(
      "NormalNC:Normal",
      1,
      true
    ))
    assert(vim.api.nvim_win_get_position(old_sidebar_win)[2]
      > vim.api.nvim_win_get_position(old_main_win)[2])
    assert(vim.api.nvim_win_get_position(new_sidebar_win)[2]
      > vim.api.nvim_win_get_position(new_main_win)[2])
    local old_state = vim.api.nvim_tabpage_get_var(
      old_tab,
      "oculus_inspect"
    )
    local new_state = vim.api.nvim_tabpage_get_var(
      new_tab,
      "oculus_inspect"
    )
    assert(old_state.role == (integration_is_pull_request and "old" or "parent"))
    assert(new_state.role == "change")
    assert(old_state.pair_index == pair_index)
    assert(new_state.pair_index == pair_index)
    assert(old_state.commit_index == new_state.commit_index)
    assert(old_state.file_index == new_state.file_index)
    assert(old_state.file_count == new_state.file_count)
    assert(old_state.status == new_state.status)
    assert(old_state.file)
    assert(new_state.file)
    if expected_source_root then
      local expected_root = vim.fs.normalize(expected_source_root):lower()
      assert(vim.fs.normalize(old_state.repository):lower() == expected_root)
      assert(vim.fs.normalize(new_state.repository):lower() == expected_root)
      assert(vim.fs.normalize(old_state.source_path):lower():sub(
        1,
        #expected_root
      ) == expected_root)
      assert(vim.fs.normalize(new_state.source_path):lower():sub(
        1,
        #expected_root
      ) == expected_root)
    end
    commit_indices[old_state.commit_index] = true
    local expected_file_index =
      next_file_indices[old_state.commit_index] or 1
    assert(old_state.file_index == expected_file_index)
    assert(old_state.file_index <= old_state.file_count)
    next_file_indices[old_state.commit_index] = expected_file_index + 1
    local old_buf = vim.api.nvim_win_get_buf(old_main_win)
    local new_buf = vim.api.nvim_win_get_buf(new_main_win)
    assert(not buffers[old_buf])
    buffers[old_buf] = true
    assert(not buffers[new_buf])
    buffers[new_buf] = true
    local old_name = vim.api.nvim_buf_get_name(old_buf)
    local new_name = vim.api.nvim_buf_get_name(new_buf)
    assert(not old_name:lower():match("oculus%-inspect"))
    assert(not new_name:lower():match("oculus%-inspect"))
    assert(not old_name:match(" Old "))
    assert(not old_name:match(" New "))
    assert(not new_name:match(" Old "))
    assert(not new_name:match(" New "))
    assert(vim.b[old_buf].oculus_inspect_repository)
    assert(vim.b[new_buf].oculus_inspect_repository)
    if expected_source_root then
      local old_cwd = vim.fn.getcwd(
        -1,
        vim.api.nvim_tabpage_get_number(old_tab)
      )
      local new_cwd = vim.fn.getcwd(
        -1,
        vim.api.nvim_tabpage_get_number(new_tab)
      )
      assert(
        vim.fs.normalize(old_cwd):lower()
          == vim.fs.normalize(old_state.directory):lower(),
        ("old inspection cwd %s did not match %s")
          :format(old_cwd, old_state.directory)
      )
      assert(
        vim.fs.normalize(new_cwd):lower()
          == vim.fs.normalize(new_state.directory):lower(),
        ("new inspection cwd %s did not match %s")
          :format(new_cwd, new_state.directory)
      )
    end
  end
  if expected_commit_count then
    assert(vim.tbl_count(commit_indices) == expected_commit_count)
  end
  assert(sidebar_buf)
  local sidebar_lines = vim.api.nvim_buf_get_lines(
    sidebar_buf,
    0,
    -1,
    false
  )
  local file_lines = {}
  local chunk_lines = 0
  for line_number, line in ipairs(sidebar_lines) do
    local branch =
      line:match("^  ├─ %d+%-%d+ %([+-]?%d+%)$")
        or line:match("^  └─ %d+%-%d+ %([+-]?%d+%)$")
    if branch then
      chunk_lines = chunk_lines + 1
    else
      file_lines[#file_lines + 1] = line_number
      assert(line:match("^• "))
      assert(line:match(" P C $"))
      assert(not line:match("^%d+%. "))
      assert(vim.fn.strdisplaywidth(line) == sidebar_width)
      local displayed_file = line
        :gsub("%s+P C%s*$", "")
        :gsub("^• ", "")
        :gsub("^…", "")
      local _, separators = displayed_file:gsub("/", "")
      assert(separators <= 1)
    end
  end
  assert(#file_lines == pair_count)
  assert(chunk_lines >= pair_count)
  assert(#sidebar_lines == pair_count + chunk_lines)
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  local first_sidebar_win = assert(sidebar_window(tabs[2]))
  assert(vim.api.nvim_win_get_cursor(first_sidebar_win)[1]
    == file_lines[1] + 1)
  assert(vim.api.nvim_win_call(
    first_sidebar_win,
    vim.fn.winsaveview
  ).topline == 1)
  if expect_no_worktrees then
    assert(vim.uv.fs_stat(vim.fs.joinpath(
      integration_root,
      "worktrees"
    )) == nil)
  end
  if expect_no_external_state then
    assert(
      vim.uv.fs_stat(integration_root) == nil,
      "inspect created state outside the project repository"
    )
  end
  local parent_state = vim.api.nvim_tabpage_get_var(
    tabs[2],
    "oculus_inspect"
  )
  local change_state = vim.api.nvim_tabpage_get_var(
    tabs[3],
    "oculus_inspect"
  )
  assert(parent_state.role
    == (integration_is_pull_request and "old" or "parent"))
  assert(change_state.role == "change")
  if integration_sha and not integration_url then
    assert(change_state.commit == integration_sha)
  end

  local parent_win = assert(inspection_window(tabs[2]))
  local change_win = assert(inspection_window(tabs[3]))
  local parent_buf = vim.api.nvim_win_get_buf(parent_win)
  local change_buf = vim.api.nvim_win_get_buf(change_win)
  vim.g.oculus_test_statusline_path = vim.fs.basename(
    vim.fs.normalize(change_state.repository)
  ) .. "/" .. change_state.file:gsub("\\", "/")
  assert(vim.b[change_buf].oculus_inspect_statusline_path
    == vim.g.oculus_test_statusline_path)
  assert(vim.wo[change_win].statusline
    == " " .. vim.g.oculus_test_statusline_path:gsub("%%", "%%%%"))
  vim.g.oculus_test_statusline_path = nil
  if verify_revision_content then
    assert(expected_source_root)
    local content_state = change_state.status == "A"
        and change_state
      or parent_state
    local content_buf = change_state.status == "A"
        and change_buf
      or parent_buf
    local result = vim.system({
      "git",
      "-C",
      expected_source_root,
      "show",
      content_state.commit .. ":" .. content_state.file,
    }, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    assert(vim.deep_equal(
      vim.api.nvim_buf_get_lines(content_buf, 0, -1, false),
      inspect._blob_lines(result.stdout)
    ))
  end
  local namespaces = vim.api.nvim_get_namespaces()
  local signs = namespaces.oculus_inspect_changes
  assert(signs)
  local parent_marks = vim.api.nvim_buf_get_extmarks(
    parent_buf,
    signs,
    0,
    -1,
    { details = true }
  )
  assert(#parent_marks > 0)
  local parent_sign = vim.trim(parent_marks[1][4].sign_text)
  assert(parent_sign == "-" or parent_sign == "+")
  assert(parent_marks[1][4].sign_hl_group
    == (parent_sign == "-"
        and "OculusInspectRemoved"
      or "OculusInspectAdded"))
  assert(vim.wo[parent_win].signcolumn == "yes")
  local change_marks = vim.api.nvim_buf_get_extmarks(
    change_buf,
    signs,
    0,
    -1,
    {}
  )
  assert(#change_marks > 0)
  assert(vim.wo[change_win].signcolumn == "yes")
  assert(vim.api.nvim_win_get_cursor(change_win)[1]
    == change_marks[1][2] + 1)
  assert(vim.api.nvim_win_get_cursor(parent_win)[1]
    == change_marks[1][2] + 1)

  local jump_maps = vim.api.nvim_buf_get_keymap(change_buf, "n")
  local previous_mapped = false
  local next_mapped = false
  local toggle_mapped = false
  local switch_mapped = false
  local next_file_mapping
  local main_ctrl_i_mapped = false
  local sidebar_ctrl_i_mapped = false
  local sidebar_tab_mapped = false
  local sidebar_leader_toggle
  for _, mapping in ipairs(jump_maps) do
    if mapping.lhs == "<C-I>" then
      main_ctrl_i_mapped = true
    end
    if mapping.desc == "Previous Oculus change" then
      previous_mapped = mapping.lhs == "<C-Left>"
    elseif mapping.desc == "Previous Oculus changed chunk" then
      previous_mapped = mapping
    elseif mapping.desc == "Next Oculus change" then
      next_mapped = mapping.lhs == "<C-Right>"
    elseif mapping.desc == "Toggle Oculus file version" then
      toggle_mapped = mapping.lhs == "<Tab>"
    elseif mapping.desc == "Next Oculus changed chunk" then
      toggle_mapped = mapping
    elseif mapping.desc == "Switch Oculus file version" then
      switch_mapped = mapping.lhs == "gS"
    elseif mapping.desc == "Next Oculus changed file" then
      next_file_mapping = mapping
    elseif mapping.desc == "Toggle Oculus Inspect sidebar" then
      if mapping.lhs == "<C-I>" then
        sidebar_ctrl_i_mapped = true
      elseif mapping.lhs == "<Tab>" then
        sidebar_tab_mapped = true
      else
        sidebar_leader_toggle = mapping
      end
    end
  end
  assert(previous_mapped and previous_mapped.lhs == "<S-Tab>")
  assert(not next_mapped)
  assert(toggle_mapped and toggle_mapped.lhs == "<Tab>")
  assert(switch_mapped)
  assert(not next_file_mapping)
  assert(not main_ctrl_i_mapped)
  assert(not sidebar_ctrl_i_mapped)
  assert(not sidebar_tab_mapped)
  assert(sidebar_leader_toggle
    and sidebar_leader_toggle.lhs
      == (vim.g.mapleader or "\\") .. "oi")
  assert(vim.fn.maparg("o", "n", false, true).buffer ~= 1)
  toggle_mapped.callback()
  assert(vim.api.nvim_get_current_win() == change_win)
  do
    local active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
    local active_sidebar_win = assert(sidebar_window(
      vim.api.nvim_get_current_tabpage()
    ))
    assert(vim.api.nvim_win_get_cursor(active_sidebar_win)[1]
      == file_lines[active.pair_index] + active.chunk_index)
  end

  local sidebar_ctrl_i_from_sidebar = false
  local sidebar_tab_from_sidebar = false
  local sidebar_leader_toggle_from_sidebar
  local sidebar_open_mapping
  local sidebar_switch_mapping
  local sidebar_overview_mapping
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(
    sidebar_buf,
    "n"
  )) do
    if mapping.desc == "Toggle Oculus Inspect sidebar" then
      if mapping.lhs == "<C-I>" then
        sidebar_ctrl_i_from_sidebar = true
      elseif mapping.lhs == "<Tab>" then
        sidebar_tab_from_sidebar = true
      else
        sidebar_leader_toggle_from_sidebar = mapping
      end
    elseif mapping.desc == "Open Oculus Inspect sidebar item" then
      sidebar_open_mapping = mapping
    elseif mapping.desc == "Switch Oculus file version" then
      sidebar_switch_mapping = mapping
    elseif mapping.desc == "Toggle Oculus Inspect overview" then
      sidebar_overview_mapping = mapping
    elseif mapping.desc == "Next Oculus changed file" then
      next_file_mapping = mapping
    elseif mapping.desc == "Next Oculus changed chunk" then
      toggle_mapped = mapping
    elseif mapping.desc == "Previous Oculus changed chunk" then
      previous_mapped = mapping
    end
  end
  assert(not sidebar_ctrl_i_from_sidebar)
  assert(not sidebar_tab_from_sidebar)
  assert(sidebar_leader_toggle_from_sidebar
    and sidebar_leader_toggle_from_sidebar.lhs
      == (vim.g.mapleader or "\\") .. "oi")
  assert(sidebar_open_mapping
    and sidebar_open_mapping.lhs == "<CR>")
  assert(sidebar_switch_mapping
    and sidebar_switch_mapping.lhs == "gS")
  assert(sidebar_overview_mapping
    and sidebar_overview_mapping.lhs == "gO")
  assert(not next_file_mapping)
  assert(toggle_mapped and toggle_mapped.lhs == "<Tab>")
  assert(previous_mapped and previous_mapped.lhs == "<S-Tab>")

  vim.api.nvim_set_current_tabpage(tabs[pair_count * 2 + 1])
  local overview_sidebar_win =
    assert(sidebar_window(tabs[pair_count * 2 + 1]))
  vim.api.nvim_set_current_win(overview_sidebar_win)
  vim.g.oculus_test_chunk =
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_index or 0
  vim.g.oculus_test_chunk_count =
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_count
  assert(vim.g.oculus_test_chunk_count > 0)
  for _ = vim.g.oculus_test_chunk + 1, vim.g.oculus_test_chunk_count do
    toggle_mapped.callback()
  end
  assert(
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.pair_index
      == pair_count
  )
  assert(
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_index
      == vim.g.oculus_test_chunk_count
  )
  toggle_mapped.callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(vim.api.nvim_get_current_win()
    == assert(sidebar_window(tabs[3])))
  assert(vim.api.nvim_win_get_cursor(
    assert(sidebar_window(tabs[3]))
  )[1] == file_lines[1])
  assert(vim.api.nvim_win_get_cursor(change_win)[1] == 1)
  assert(vim.api.nvim_win_call(
    change_win,
    vim.fn.winsaveview
  ).topline == 1)
  assert(vim.b[sidebar_buf].oculus_inspect_sidebar_active.pair_index == 1)
  previous_mapped.callback()
  assert(vim.api.nvim_get_current_tabpage()
    == tabs[pair_count * 2 + 1])
  assert(vim.api.nvim_get_current_win()
    == assert(sidebar_window(tabs[pair_count * 2 + 1])))
  assert(
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.pair_index
      == pair_count
  )
  assert(
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_index
      == vim.g.oculus_test_chunk_count
  )
  toggle_mapped.callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  vim.g.oculus_test_chunk = nil
  vim.g.oculus_test_chunk_count = nil
  overview_sidebar_win = assert(sidebar_window(tabs[3]))
  vim.api.nvim_set_current_win(overview_sidebar_win)
  local overview_saved = {
    sidebar_win = overview_sidebar_win,
    sidebar_cursor = vim.api.nvim_win_get_cursor(overview_sidebar_win),
    sidebar_view = vim.fn.winsaveview(),
    main_cursor = vim.api.nvim_win_get_cursor(change_win),
    main_view = vim.api.nvim_win_call(change_win, vim.fn.winsaveview),
  }
  assert(vim.api.nvim_get_current_buf() == sidebar_buf)
  sidebar_overview_mapping.callback()
  overview_sidebar_win = vim.api.nvim_get_current_win()
  overview_saved.buf = vim.api.nvim_get_current_buf()
  overview_saved.config =
    vim.api.nvim_win_get_config(overview_sidebar_win)
  overview_saved.close_mapping =
    vim.fn.maparg("q", "n", false, true)
  assert(overview_saved.close_mapping.desc
    == "Close Oculus Inspect overview")
  assert(
    overview_sidebar_win ~= overview_saved.sidebar_win,
    vim.inspect({
      current_win = overview_sidebar_win,
      sidebar_win = overview_saved.sidebar_win,
      current_buf = overview_saved.buf,
      sidebar_buf = sidebar_buf,
    })
  )
  assert(overview_saved.buf ~= sidebar_buf)
  assert(vim.b[overview_saved.buf].oculus_inspect_overview == true)
  assert(vim.b[sidebar_buf].oculus_inspect_sidebar_mode == "files")
  assert(vim.api.nvim_win_get_width(overview_saved.sidebar_win)
    == sidebar_width)
  assert(overview_saved.config.relative == "editor")
  do
    local main_overview_config =
      require("oculus.window").window_config({})
    local expected_overview_width = integration_is_pull_request
        and main_overview_config.width
      or math.max(20, math.floor(main_overview_config.width * 0.8))
    local expected_overview_height = integration_is_pull_request
        and main_overview_config.height
      or math.max(8, math.floor(main_overview_config.height * 0.8))
    assert(overview_saved.config.width
      == expected_overview_width)
    assert(overview_saved.config.height
      == expected_overview_height)
    assert(overview_saved.config.row
      == main_overview_config.row
        + math.floor(
          (main_overview_config.height - expected_overview_height) / 2
        ))
    assert(overview_saved.config.col
      == main_overview_config.col
        + math.floor(
          (main_overview_config.width - expected_overview_width) / 2
        ))
  end
  assert(overview_saved.config.title == nil
    or overview_saved.config.title == "")
  local overview_text = table.concat(
    vim.api.nvim_buf_get_lines(overview_saved.buf, 0, -1, false),
    "\n"
  )
  assert(overview_text:match("^  Title\n"))
  assert(overview_text:find("\n  Description\n", 1, true))
  assert(overview_text:find("\n  Author\n", 1, true))
  assert(overview_text:find("\n  URL\n", 1, true))
  assert(not overview_text:find("Repository", 1, true))
  assert(not overview_text:find("\nCommit\n", 1, true))
  assert(not overview_text:find("Authored", 1, true))
  assert(not overview_text:find("Changes", 1, true))
  assert(not overview_text:find("changed files", 1, true))
  overview_saved.section_marks = vim.api.nvim_buf_get_extmarks(
    overview_saved.buf,
    vim.api.nvim_get_namespaces().oculus_inspect_sidebar,
    0,
    -1,
    { details = true }
  )
  assert(#overview_saved.section_marks >= 4)
  for _, mark in ipairs(overview_saved.section_marks) do
    assert(mark[3] == 2)
    assert(mark[4].hl_group
      == "OculusInspectOverviewSection")
  end
  assert(vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectOverviewSection", link = false }
  ).underline == true)
  local overview_line_count =
    vim.api.nvim_buf_line_count(overview_saved.buf)
  vim.api.nvim_win_set_cursor(
    overview_sidebar_win,
    {
      math.min(overview_line_count, 2),
      0,
    }
  )
  vim.api.nvim_exec_autocmds("CursorMoved", {
    buffer = overview_saved.buf,
  })
  vim.wait(50, function()
    return false
  end)
  assert(vim.deep_equal(
    vim.api.nvim_win_get_cursor(change_win),
    overview_saved.main_cursor
  ))
  assert(vim.deep_equal(
    vim.api.nvim_win_call(change_win, vim.fn.winsaveview),
    overview_saved.main_view
  ))
  overview_saved.close_mapping.callback()
  assert(not vim.api.nvim_win_is_valid(overview_sidebar_win))
  assert(not vim.api.nvim_buf_is_valid(overview_saved.buf))
  assert(vim.b[sidebar_buf].oculus_inspect_sidebar_mode == "files")
  assert(vim.api.nvim_get_current_win() == overview_saved.sidebar_win)
  assert(vim.api.nvim_win_get_width(overview_saved.sidebar_win)
    == sidebar_width)
  assert(vim.deep_equal(
    vim.api.nvim_win_get_cursor(overview_saved.sidebar_win),
    overview_saved.sidebar_cursor
  ))
  assert(vim.fn.winsaveview().topline
    == overview_saved.sidebar_view.topline)
  assert(vim.deep_equal(
    vim.api.nvim_win_get_cursor(change_win),
    overview_saved.main_cursor
  ))
  assert(vim.api.nvim_buf_get_lines(
    sidebar_buf,
    file_lines[1] - 1,
    file_lines[1],
    false
  )[1]:find("• ", 1, true))

  vim.api.nvim_set_current_win(assert(sidebar_window(tabs[2])))
  sidebar_leader_toggle_from_sidebar.callback()
  assert(vim.api.nvim_get_current_win() == parent_win)
  for pair_index = 1, pair_count do
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2]
    ) == 1)
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2 + 1]
    ) == 1)
  end
  sidebar_leader_toggle.callback()
  assert(vim.api.nvim_get_current_win() == parent_win)
  for pair_index = 1, pair_count do
    for _, tab in ipairs({
      tabs[pair_index * 2],
      tabs[pair_index * 2 + 1],
    }) do
      assert(#vim.api.nvim_tabpage_list_wins(tab) == 2)
      assert(vim.api.nvim_win_get_buf(assert(sidebar_window(tab)))
        == sidebar_buf)
    end
  end

  vim.api.nvim_set_current_tabpage(tabs[2])
  local sidebar_active = vim.b[sidebar_buf]
    .oculus_inspect_sidebar_active
  assert(sidebar_active.pair_index == 1)
  assert(sidebar_active.role == "parent")
  assert(sidebar_active.chunk_count >= 1)
  local initial_sidebar_win = assert(sidebar_window(tabs[2]))
  assert(vim.api.nvim_get_current_win() == parent_win)
  assert(vim.api.nvim_win_get_cursor(initial_sidebar_win)[1]
    == file_lines[1])
  local sidebar_signs = vim.api.nvim_get_namespaces()
    .oculus_inspect_sidebar
  assert(sidebar_signs)
  assert(#vim.api.nvim_buf_get_extmarks(
    sidebar_buf,
    sidebar_signs,
    0,
    -1,
    {}
  ) == pair_count * 2)
  local file_line_lookup = {}
  for _, line in ipairs(file_lines) do
    file_line_lookup[line] = true
  end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    sidebar_buf,
    sidebar_signs,
    0,
    -1,
    { details = true }
  )) do
    assert(file_line_lookup[mark[2] + 1])
    assert(mark[4].line_hl_group == nil)
    assert(mark[4].hl_group
      ~= "OculusInspectSidebarChunkActive")
    assert(mark[4].hl_group
      ~= "OculusInspectSidebarCurrent")
  end
  local normal_hl =
    vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local parent_hl = vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectSidebarParent", link = false }
  )
  local change_hl = vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectSidebarChange", link = false }
  )
  assert(parent_hl.fg
    == vim.api.nvim_get_hl(
      0,
      { name = "DiagnosticError", link = false }
    ).fg)
  assert(change_hl.fg == 0x00c853)
  assert(parent_hl.bg == normal_hl.bg)
  assert(change_hl.bg == normal_hl.bg)
  local parent_active_hl = vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectSidebarParentActive", link = false }
  )
  local change_active_hl = vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectSidebarChangeActive", link = false }
  )
  assert(parent_active_hl.underline == true)
  assert(change_active_hl.underline == true)
  assert(change_active_hl.fg == 0x00c853)
  assert(parent_active_hl.bold ~= true)
  assert(change_active_hl.bold ~= true)
  assert(parent_hl.bold ~= true)
  assert(change_hl.bold ~= true)
  assert(parent_hl.underline ~= true)
  assert(change_hl.underline ~= true)
  local function sidebar_role_groups(line)
    local groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      sidebar_buf,
      sidebar_signs,
      { line - 1, 0 },
      { line - 1, -1 },
      { details = true }
    )) do
      local group = mark[4].hl_group
      if group then
        groups[group] = true
      end
    end
    return groups
  end
  local visible_role_groups = sidebar_role_groups(file_lines[1])
  assert(visible_role_groups.OculusInspectSidebarParentActive)
  assert(visible_role_groups.OculusInspectSidebarChange)
  assert(not visible_role_groups.OculusInspectSidebarChangeActive)
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(parent_buf)):lower()
    == vim.fs.normalize(parent_state.source_path):lower())
  local initial_cursor = vim.api.nvim_win_get_cursor(change_win)
  local initial_line = vim.api.nvim_buf_get_lines(
    change_buf,
    initial_cursor[1] - 1,
    initial_cursor[1],
    false
  )[1] or ""
  if initial_cursor[1] >= 10 then
    assert(initial_cursor[2] == math.max(0, #initial_line - 1))
  end
  local initial_view = vim.api.nvim_win_call(
    change_win,
    vim.fn.winsaveview
  )
  if initial_cursor[1] >= 10 then
    assert(initial_view.topline == math.max(1, initial_cursor[1] - 10))
  end
  local initial_parent_cursor = vim.api.nvim_win_get_cursor(parent_win)
  local initial_parent_line = vim.api.nvim_buf_get_lines(
    parent_buf,
    initial_parent_cursor[1] - 1,
    initial_parent_cursor[1],
    false
  )[1] or ""
  if initial_parent_cursor[1] >= 10 then
    assert(initial_parent_cursor[2]
      == math.max(0, #initial_parent_line - 1))
  end
  local initial_parent_view = vim.api.nvim_win_call(
    parent_win,
    vim.fn.winsaveview
  )
  if initial_parent_cursor[1] >= 10 then
    assert(initial_parent_view.topline
      == math.max(1, initial_parent_cursor[1] - 10))
  end
  local sidebar_parent_win = assert(sidebar_window(tabs[2]))
  vim.api.nvim_set_current_win(sidebar_parent_win)
  vim.api.nvim_win_set_cursor(
    sidebar_parent_win,
    { file_lines[1], 0 }
  )
  vim.api.nvim_exec_autocmds("CursorMoved", {
    buffer = sidebar_buf,
  })
  assert(vim.wait(1000, function()
    return vim.api.nvim_get_current_tabpage() == tabs[2]
      and vim.api.nvim_get_current_win() == sidebar_parent_win
      and vim.api.nvim_win_get_cursor(parent_win)[1] == 1
      and vim.api.nvim_win_call(
        parent_win,
        vim.fn.winsaveview
      ).topline == 1
  end), "sidebar file did not open at the top in the main pane")
  local selected_chunk =
    sidebar_active.chunk_count > 1 and 2 or 1
  local selected_chunk_line = file_lines[1] + selected_chunk
  vim.api.nvim_win_set_cursor(
    sidebar_parent_win,
    { selected_chunk_line, 0 }
  )
  vim.api.nvim_exec_autocmds("CursorMoved", {
    buffer = sidebar_buf,
  })
  assert(vim.wait(1000, function()
    local active = vim.b[sidebar_buf]
      .oculus_inspect_sidebar_active
    return vim.api.nvim_get_current_tabpage() == tabs[2]
      and vim.api.nvim_get_current_win() == sidebar_parent_win
      and active.chunk_index == selected_chunk
  end), "sidebar chunk did not open in the main pane")
  local selected_parent_line =
    vim.api.nvim_win_get_cursor(parent_win)[1]
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.chunk_index == selected_chunk)
  local selected_view = vim.api.nvim_win_call(
    parent_win,
    vim.fn.winsaveview
  )
  if selected_parent_line >= 10 then
    assert(selected_view.topline
      == math.max(1, selected_parent_line - 10))
  end
  vim.api.nvim_exec_autocmds("WinScrolled", {
    pattern = tostring(parent_win),
  })
  assert(vim.api.nvim_get_current_win() == sidebar_parent_win)
  local parent_sidebar_view = vim.fn.winsaveview()
  sidebar_switch_mapping.callback()
  local sidebar_change_win = assert(sidebar_window(tabs[3]))
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(vim.api.nvim_get_current_win() == sidebar_change_win)
  assert(vim.api.nvim_win_get_cursor(sidebar_change_win)[1]
    == selected_chunk_line)
  assert(vim.api.nvim_win_get_cursor(sidebar_change_win)[2]
    == (
      vim.api.nvim_buf_get_lines(
        sidebar_buf,
        selected_chunk_line - 1,
        selected_chunk_line,
        false
      )[1]:find("%S") - 1
    ))
  assert(vim.fn.winsaveview().topline
    == parent_sidebar_view.topline)
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.pair_index == 1)
  assert(sidebar_active.role == "change")
  sidebar_switch_mapping.callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  assert(vim.api.nvim_get_current_win() == sidebar_parent_win)
  assert(vim.api.nvim_win_get_cursor(sidebar_parent_win)[1]
    == selected_chunk_line)
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.role == "parent")
  sidebar_open_mapping.callback()
  assert(vim.api.nvim_get_current_win() == parent_win)
  assert(vim.api.nvim_win_get_cursor(parent_win)[1]
    == selected_parent_line)
  assert(vim.api.nvim_win_get_cursor(sidebar_parent_win)[1]
    == selected_chunk_line)
  local anchored_selection = false
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    sidebar_buf,
    sidebar_signs,
    { selected_chunk_line - 1, 0 },
    { selected_chunk_line - 1, -1 },
    { details = true }
  )) do
    if mark[4].line_hl_group == "CursorLine" then
      anchored_selection = true
      break
    end
  end
  assert(anchored_selection)
  vim.api.nvim_feedkeys(
    "gS",
    "x",
    false
  )
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  do
    local cursor = vim.api.nvim_win_get_cursor(change_win)
    local cursor_text = vim.api.nvim_buf_get_lines(
      change_buf,
      cursor[1] - 1,
      cursor[1],
      false
    )[1]
    assert(cursor[2] == ((cursor_text:find("%S") or 1) - 1))
  end
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.pair_index == 1)
  assert(sidebar_active.role == "change")
  visible_role_groups = sidebar_role_groups(file_lines[1])
  assert(visible_role_groups.OculusInspectSidebarParent)
  assert(visible_role_groups.OculusInspectSidebarChangeActive)
  assert(not visible_role_groups.OculusInspectSidebarParentActive)
  vim.api.nvim_feedkeys(
    "gS",
    "x",
    false
  )
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.role == "parent")
  vim.api.nvim_feedkeys(
    "gS",
    "x",
    false
  )
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(change_buf)):lower()
    == vim.fs.normalize(change_state.source_path):lower())
  assert(vim.api.nvim_buf_get_name(parent_buf) == "")
  if pair_count > 1 then
    vim.api.nvim_set_current_tabpage(tabs[3])
    vim.api.nvim_set_current_win(assert(sidebar_window(tabs[3])))
    vim.api.nvim_win_set_cursor(0, { file_lines[2], 0 })
    local source_sidebar_view = vim.fn.winsaveview()
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = sidebar_buf,
    })
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_tabpage() == tabs[4]
    end), "sidebar cursor did not open the second changed file")
    assert(vim.api.nvim_get_current_win()
      == assert(sidebar_window(tabs[4])))
    vim.wait(50, function()
      return false
    end)
    local second_sidebar_win = assert(sidebar_window(tabs[4]))
    assert(vim.api.nvim_get_current_win() == second_sidebar_win)
    assert(
      vim.api.nvim_win_get_cursor(second_sidebar_win)[1]
        == file_lines[2],
      ("second sidebar cursor was %d instead of file row %d")
        :format(
          vim.api.nvim_win_get_cursor(second_sidebar_win)[1],
          file_lines[2]
        )
    )
    local second_sidebar_view = vim.fn.winsaveview()
    assert(second_sidebar_view.topline == source_sidebar_view.topline)
    if file_lines[2] > source_sidebar_view.topline then
      assert(second_sidebar_view.topline < file_lines[2])
    end
    local second_main_win = assert(inspection_window(tabs[4]))
    vim.api.nvim_exec_autocmds("WinScrolled", {
      pattern = tostring(second_main_win),
    })
    assert(vim.api.nvim_get_current_win() == second_sidebar_win)
    sidebar_active = vim.b[sidebar_buf]
      .oculus_inspect_sidebar_active
    assert(sidebar_active.pair_index == 2)
    assert(sidebar_active.role == "parent")
    local second_first_parent_line =
      vim.api.nvim_win_get_cursor(second_main_win)[1]
    sidebar_open_mapping.callback()
    assert(vim.api.nvim_get_current_win() == second_main_win)
    assert(vim.api.nvim_win_get_cursor(second_main_win)[1]
      == second_first_parent_line)
    assert(vim.api.nvim_win_get_cursor(second_sidebar_win)[1]
      == file_lines[2])
    vim.api.nvim_set_current_win(second_sidebar_win)
    vim.api.nvim_win_set_cursor(0, { file_lines[1], 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = sidebar_buf,
    })
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_tabpage() == tabs[2]
    end), "sidebar cursor did not return to the first changed file")
    assert(vim.api.nvim_get_current_win()
      == assert(sidebar_window(tabs[2])))
    vim.cmd("wincmd h")
    assert(vim.api.nvim_get_current_win() == parent_win)
  end
  local linked_line = math.min(
    2,
    vim.api.nvim_buf_line_count(parent_buf),
    vim.api.nvim_buf_line_count(change_buf)
  )
  vim.api.nvim_win_set_cursor(change_win, { linked_line, 0 })
  vim.api.nvim_win_call(change_win, function()
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = change_buf })
  end)
  assert(
    vim.api.nvim_win_get_cursor(parent_win)[1] == linked_line,
    ("paired cursor stayed at %d instead of %d (current win %d, change %d)")
      :format(
        vim.api.nvim_win_get_cursor(parent_win)[1],
        linked_line,
        vim.api.nvim_get_current_win(),
        change_win
      )
  )

  vim.api.nvim_win_call(change_win, function()
    vim.fn.winrestview({ topline = linked_line })
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", {
    pattern = tostring(change_win),
  })
  local change_view = vim.api.nvim_win_call(change_win, vim.fn.winsaveview)
  local parent_view = vim.api.nvim_win_call(parent_win, vim.fn.winsaveview)
  assert(parent_view.topline == change_view.topline)

  if oil_runtime then
    local oil = require("oil")
    oil.setup({
      watch_for_changes = false,
      keymaps = {
        ["<CR>"] = false,
        ["l"] = {
          callback = function()
            oil.select({ tab = true, close = true })
          end,
          desc = "Open file in a tab",
        },
      },
    })
    vim.api.nvim_set_current_tabpage(tabs[3])
    vim.api.nvim_set_current_win(change_win)
    local tabs_before_oil = #vim.api.nvim_list_tabpages()
    oil.open()
    assert(vim.wait(10000, function()
      local oil_buf = vim.api.nvim_get_current_buf()
      if vim.bo[oil_buf].filetype ~= "oil" then
        return false
      end
      local oil_signs = vim.api.nvim_get_namespaces()
        .oculus_inspect_oil
      return oil_signs
        and #vim.api.nvim_buf_get_extmarks(
          oil_buf,
          oil_signs,
          0,
          -1,
          {}
        ) > 0
        and type(vim.b[oil_buf].oculus_inspect_oil_origin)
          == "table"
    end), "Oil entries were not decorated")
    local oil_buf = vim.api.nvim_get_current_buf()
    assert(vim.fs.normalize(oil.get_current_dir()):lower()
      == vim.fs.normalize(change_state.directory):lower())
    local oil_origin = vim.b[oil_buf].oculus_inspect_oil_origin
    assert(type(oil_origin) == "table")
    assert(oil_origin.source_buf == change_buf)
    assert(oil_origin.filename == vim.fs.basename(
      change_state.source_path
    ))
    local cursor_entry = oil.get_cursor_entry()
    assert(cursor_entry)
    assert(
      cursor_entry.name == oil_origin.filename,
      ("Oil cursor stayed on %s instead of %s")
        :format(cursor_entry.name, oil_origin.filename)
    )
    for pair_index = 1, pair_count do
      assert(not sidebar_window(tabs[pair_index * 2]))
      assert(not sidebar_window(tabs[pair_index * 2 + 1]))
    end
    local oil_signs = vim.api.nvim_get_namespaces().oculus_inspect_oil
    local oil_marks = vim.api.nvim_buf_get_extmarks(
      oil_buf,
      oil_signs,
      0,
      -1,
      { details = true }
    )
    assert(#oil_marks > 0)
    assert(oil_marks[1][4].sign_text)
    assert(oil_marks[1][4].virt_text == nil)
    assert(vim.wo[vim.api.nvim_get_current_win()].signcolumn == "yes")
    local oil_highlight = vim.api.nvim_get_hl(0, {
      name = oil_marks[1][4].sign_hl_group,
      link = false,
    })
    local normal_highlight = vim.api.nvim_get_hl(0, {
      name = "Normal",
      link = false,
    })
    assert(oil_highlight.bg == normal_highlight.bg)
    ;(function()
      oil.open(vim.fs.dirname(change_state.directory))
      assert(vim.wait(10000, function()
        local current = oil.get_current_dir()
        return current
          and vim.fs.normalize(current):lower()
            == vim.fs.normalize(
              vim.fs.dirname(change_state.directory)
            ):lower()
      end), "Oil did not open the parent inspection directory")
      oil.open(change_state.directory)
      assert(vim.wait(10000, function()
        local current = oil.get_current_dir()
        if not current
          or vim.fs.normalize(current):lower()
            ~= vim.fs.normalize(change_state.directory):lower()
        then
          return false
        end
        local current_buf = vim.api.nvim_get_current_buf()
        local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
          current_buf,
          oil_signs,
          0,
          -1,
          { details = true }
        )) do
          if mark[4].sign_text ~= "•" then
            return cursor_line == mark[2] + 1
          end
        end
        return false
      end), "Oil did not select the first changed file after descending")
      oil_buf = vim.api.nvim_get_current_buf()
      cursor_entry = oil.get_cursor_entry()
      assert(cursor_entry and cursor_entry.type ~= "directory")
      for line = 1, vim.api.nvim_buf_line_count(oil_buf) do
        local entry = oil.get_entry_on_line(oil_buf, line)
        if entry and entry.name == oil_origin.filename then
          vim.api.nvim_win_set_cursor(0, { line, 0 })
          break
        end
      end
    end)()
    local oil_select_mapping =
      vim.fn.maparg("l", "n", false, true)
    assert(
      oil_select_mapping.desc
        == "Select Oculus Inspect Oil entry",
      "unexpected Oil select mapping: "
        .. vim.inspect(oil_select_mapping)
    )
    oil_select_mapping.callback()
    assert(vim.api.nvim_get_current_buf() == change_buf)
    assert(#vim.api.nvim_list_tabpages() == tabs_before_oil)
    assert(vim.bo[vim.api.nvim_get_current_buf()].filetype ~= "oil")
    assert(vim.wait(10000, function()
      for pair_index = 1, pair_count do
        if not sidebar_window(tabs[pair_index * 2])
          or not sidebar_window(tabs[pair_index * 2 + 1])
        then
          return false
        end
      end
      return true
    end), "Inspect sidebar was not restored after closing Oil")
  end
end
