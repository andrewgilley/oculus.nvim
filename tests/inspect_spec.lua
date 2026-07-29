local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.api.nvim_set_hl(0, "Normal", {
  fg = 0xd0d0d0,
  bg = 0x101820,
})
local oil_runtime = vim.env.PANTHEON_INSPECT_TEST_OIL
if oil_runtime then
  vim.opt.runtimepath:append(oil_runtime)
end

local inspect = require("pantheon.inspect")

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
vim.b[highlight_buf].pantheon_inspect = { role = "change" }
assert(inspect._refresh_buffer_highlighting(highlight_buf))
assert(vim.bo[highlight_buf].syntax == "lua")
vim.api.nvim_buf_delete(highlight_buf, { force = true })

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
      path = "lua/pantheon/inspect.lua",
      start_line = 15,
      line = 17,
      side = "RIGHT",
      commit_id = "aaaaaaaa",
    },
  },
})
assert(comment)
assert(comment.body == "Please keep this branch explicit.")
assert(comment.path == "lua/pantheon/inspect.lua")
assert(comment.line == 15)
assert(comment.side == "change")
assert(comment.commit == "aaaaaaaa")
local left_comment = inspect.activity_comment({
  type = "PullRequestReviewCommentEvent",
  payload = {
    comment = {
      body = "This was removed.",
      path = "lua/pantheon/inspect.lua",
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
  { new_start = 25, new_count = 4 },
  false
) == "  ├─ 25-28")
assert(inspect._sidebar_chunk_row(
  { new_start = 31, new_count = 0 },
  true
) == "  └─ 31-31")
assert(inspect._sidebar_file(
  "a/very/long/path/to/a/changed/file.lua"
) == "changed/file.lua")
assert(inspect._sidebar_file(
  "lua\\pantheon\\inspect.lua"
) == "pantheon/inspect.lua")
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
  "lua/pantheon/inspect.lua"
) == vim.fs.joinpath(root, "lua", "pantheon"))
assert(inspect._inspection_directory(
  root,
  "not-present/inspect.lua"
) == root)

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
local pull_request_comment = inspect._parse_pull_request_url(
  "https://github.com/neovim/neovim/issues/123#issuecomment-456"
)
assert(pull_request_comment)
assert(pull_request_comment.via_issue)
assert(inspect._parse_pull_request_url(
  "https://github.com/neovim/neovim/issues/not-a-number"
) == nil)
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

local parent, change = inspect._first_changed_paths("M\tlua/pantheon/init.lua")
assert(parent == "lua/pantheon/init.lua")
assert(change == "lua/pantheon/init.lua")

parent, change = inspect._first_changed_paths(
  "R100\tlua/pantheon/old.lua\tlua/pantheon/new.lua"
)
assert(parent == "lua/pantheon/old.lua")
assert(change == "lua/pantheon/new.lua")

parent, change = inspect._first_changed_paths("")
assert(parent == nil)
assert(change == nil)

local changed_files = inspect._parse_changed_files(table.concat({
  "M\tlua/pantheon/inspect.lua",
  "A\tlua/pantheon/new.lua",
  "D\tlua/pantheon/old.lua",
  "R100\tREADME.old.md\tREADME.md",
}, "\n"))
assert(#changed_files == 4)
assert(changed_files[1].status == "M")
assert(changed_files[2].new_path == "lua/pantheon/new.lua")
assert(changed_files[4].old_path == "README.old.md")
assert(changed_files[4].new_path == "README.md")
local oil_session = { changes = changed_files }
assert(inspect._oil_entry_status(
  oil_session,
  "change",
  "lua/pantheon/new.lua",
  false
) == "A")
assert(inspect._oil_entry_status(
  oil_session,
  "parent",
  "lua/pantheon/old.lua",
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
  "lua/pantheon/new.lua",
  false
) == nil)

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

local missing_root = vim.env.PANTHEON_INSPECT_TEST_MISSING_ROOT
if missing_root then
  local original_select = vim.ui.select
  local prompted = false
  vim.ui.select = function(items, select_opts, on_choice)
    prompted = true
    assert(select_opts.prompt:match("Download it to"))
    on_choice(items[2])
  end
  local source_root = vim.fs.joinpath(missing_root, "source")
  local ok, err = inspect.open(
    "https://github.com/pantheon/missing/commit/"
      .. "0123456789abcdef0123456789abcdef01234567",
    {
      inspect_search_paths = { source_root },
      inspect_repositories = {},
    }
  )
  assert(ok, err)
  assert(vim.wait(10000, function()
    local tabs = vim.api.nvim_list_tabpages()
    if #tabs ~= 3 then
      return false
    end
    local state_ok, state = pcall(
      vim.api.nvim_tabpage_get_var,
      tabs[3],
      "pantheon_inspect"
    )
    return state_ok and state.error ~= nil
  end), "missing local repository did not stop inspection")
  vim.ui.select = original_select
  assert(prompted)
  local tabs = vim.api.nvim_list_tabpages()
  local state = vim.api.nvim_tabpage_get_var(tabs[3], "pantheon_inspect")
  assert(state.error:match("download was declined"))
  assert(vim.uv.fs_stat(vim.fs.joinpath(source_root, "missing")) == nil)
  assert(vim.uv.fs_stat(vim.fs.joinpath(missing_root, "repositories")) == nil)
end

local download_root = vim.env.PANTHEON_INSPECT_TEST_DOWNLOAD_ROOT
local download_source = vim.env.PANTHEON_INSPECT_TEST_DOWNLOAD_SOURCE

local existing_repository = vim.fs.normalize(vim.fn.getcwd())
local existing_repository_result
local existing_repository_error
inspect._offer_repository_download({
  owner = "andrewgilley",
  repo = vim.fs.basename(existing_repository),
  remote_url = "https://github.com/andrewgilley/pantheon.nvim.git",
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
    owner = "pantheon",
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

local integration_root = vim.env.PANTHEON_INSPECT_TEST_ROOT
local integration_sha = vim.env.PANTHEON_INSPECT_TEST_SHA
local integration_url = vim.env.PANTHEON_INSPECT_TEST_URL
local expected_pair_count = tonumber(
  vim.env.PANTHEON_INSPECT_TEST_PAIR_COUNT
)
local expected_commit_count = tonumber(
  vim.env.PANTHEON_INSPECT_TEST_COMMIT_COUNT
)
if integration_root and (integration_sha or integration_url) then
  local integration_repository =
    vim.env.PANTHEON_INSPECT_TEST_REPOSITORY or "pantheon/test"
  local integration_source = vim.env.PANTHEON_INSPECT_TEST_SOURCE
  local integration_search_root =
    vim.env.PANTHEON_INSPECT_TEST_SEARCH_ROOT
  local expected_source_root =
    vim.env.PANTHEON_INSPECT_TEST_EXPECT_SOURCE_ROOT
      or integration_source
  local expect_no_worktrees =
    vim.env.PANTHEON_INSPECT_TEST_NO_WORKTREES == "1"
  local expect_no_external_state =
    vim.env.PANTHEON_INSPECT_TEST_NO_EXTERNAL_STATE == "1"
  local verify_revision_content =
    vim.env.PANTHEON_INSPECT_TEST_VERIFY_CONTENT == "1"
  local integration_cwd = vim.env.PANTHEON_INSPECT_TEST_CWD
  local repositories = {}
  local integration_is_pull_request = integration_url
    and integration_url:match("/pulls?/%d+")
  if integration_source then
    repositories[integration_repository] = integration_source
  end
  if integration_cwd then
    vim.api.nvim_set_current_dir(integration_cwd)
  end
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
    }
  )
  assert(ok, err)
  local loading_tabs = vim.api.nvim_list_tabpages()
  assert(#loading_tabs == 3)
  assert(#vim.api.nvim_tabpage_list_wins(loading_tabs[2]) == 1)
  assert(#vim.api.nvim_tabpage_list_wins(loading_tabs[3]) == 1)
  local loading_state = vim.api.nvim_tabpage_get_var(
    loading_tabs[3],
    "pantheon_inspect"
  )
  assert(loading_state.loading)

  local inspection_error
  local inspection_finished = vim.wait(180000, function()
    local current_tabs = vim.api.nvim_list_tabpages()
    if #current_tabs < 3 or #current_tabs % 2 ~= 1 then
      return false
    end
    for index = 2, #current_tabs do
      local state_ok, state = pcall(
        vim.api.nvim_tabpage_get_var,
        current_tabs[index],
        "pantheon_inspect"
      )
      if state_ok and state.error then
        inspection_error = state.error
        return true
      end
      if not state_ok or state.loading ~= false or state.commit == nil then
        return false
      end
    end
    return true
  end)
  assert(inspection_finished, "inspection tabs were not opened")
  assert(not inspection_error, inspection_error)

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
      if type(vim.b[buf].pantheon_inspect) == "table" then
        return win
      end
    end
  end
  local function sidebar_window(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "pantheon-inspect-files" then
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
    if mapping.desc == "Toggle Pantheon Inspect sidebar"
      and mapping.lhs == "<C-I>"
    then
      initial_sidebar_toggle = mapping
      break
    end
  end
  assert(initial_sidebar_toggle)
  for pair_index = 1, pair_count do
    local old_tab = tabs[pair_index * 2]
    local new_tab = tabs[pair_index * 2 + 1]
    assert(#vim.api.nvim_tabpage_list_wins(old_tab) == 2)
    assert(#vim.api.nvim_tabpage_list_wins(new_tab) == 2)
    local old_main_win = assert(inspection_window(old_tab))
    local new_main_win = assert(inspection_window(new_tab))
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
    assert(sidebar_width == 28)
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
      "pantheon_inspect"
    )
    local new_state = vim.api.nvim_tabpage_get_var(
      new_tab,
      "pantheon_inspect"
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
    assert(not old_name:lower():match("pantheon%-inspect"))
    assert(not new_name:lower():match("pantheon%-inspect"))
    assert(not old_name:match(" Old "))
    assert(not old_name:match(" New "))
    assert(not new_name:match(" Old "))
    assert(not new_name:match(" New "))
    assert(vim.b[old_buf].pantheon_inspect_repository)
    assert(vim.b[new_buf].pantheon_inspect_repository)
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
      line:match("^  ├─ %d+%-%d+$")
        or line:match("^  └─ %d+%-%d+$")
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
  assert(vim.api.nvim_win_get_cursor(first_sidebar_win)[1] == 1)
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
    "pantheon_inspect"
  )
  local change_state = vim.api.nvim_tabpage_get_var(
    tabs[3],
    "pantheon_inspect"
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
  local signs = namespaces.pantheon_inspect_changes
  assert(signs)
  assert(#vim.api.nvim_buf_get_extmarks(
    parent_buf,
    signs,
    0,
    -1,
    {}
  ) == 0)
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
  local next_file_mapped = false
  local sidebar_toggle
  local sidebar_tab_toggle
  for _, mapping in ipairs(jump_maps) do
    if mapping.desc == "Previous Pantheon change" then
      previous_mapped = mapping.lhs == "<C-Left>"
    elseif mapping.desc == "Next Pantheon change" then
      next_mapped = mapping.lhs == "<C-Right>"
    elseif mapping.desc == "Toggle Pantheon file version" then
      toggle_mapped = mapping.lhs == "<Tab>"
    elseif mapping.desc == "Switch Pantheon file version" then
      switch_mapped = mapping.lhs == "<C-S>"
    elseif mapping.desc == "Next Pantheon changed file" then
      next_file_mapped = mapping.lhs == "<C-N>"
    elseif mapping.desc == "Toggle Pantheon Inspect sidebar" then
      if mapping.lhs == "<C-I>" then
        sidebar_toggle = mapping
      elseif mapping.lhs == "<Tab>" then
        sidebar_tab_toggle = mapping
      end
    end
  end
  assert(not previous_mapped)
  assert(not next_mapped)
  assert(not toggle_mapped)
  assert(switch_mapped)
  assert(not next_file_mapped)
  assert(sidebar_toggle and sidebar_toggle.lhs == "<C-I>")
  assert(sidebar_tab_toggle and sidebar_tab_toggle.lhs == "<Tab>")

  local sidebar_toggle_from_sidebar
  local sidebar_tab_toggle_from_sidebar
  local sidebar_open_mapping
  local sidebar_switch_mapping
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(
    sidebar_buf,
    "n"
  )) do
    if mapping.desc == "Toggle Pantheon Inspect sidebar" then
      if mapping.lhs == "<C-I>" then
        sidebar_toggle_from_sidebar = mapping
      elseif mapping.lhs == "<Tab>" then
        sidebar_tab_toggle_from_sidebar = mapping
      end
    elseif mapping.desc == "Open Pantheon Inspect sidebar item" then
      sidebar_open_mapping = mapping
    elseif mapping.desc == "Switch Pantheon file version" then
      sidebar_switch_mapping = mapping
    end
  end
  assert(
    sidebar_toggle_from_sidebar
      and sidebar_toggle_from_sidebar.lhs == "<C-I>"
  )
  assert(
    sidebar_tab_toggle_from_sidebar
      and sidebar_tab_toggle_from_sidebar.lhs == "<Tab>"
  )
  assert(sidebar_open_mapping
    and sidebar_open_mapping.lhs == "<CR>")
  assert(sidebar_switch_mapping
    and sidebar_switch_mapping.lhs == "<C-S>")
  vim.api.nvim_set_current_win(assert(sidebar_window(tabs[2])))
  sidebar_tab_toggle_from_sidebar.callback()
  assert(vim.api.nvim_get_current_win() == parent_win)
  for pair_index = 1, pair_count do
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2]
    ) == 1)
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2 + 1]
    ) == 1)
  end
  sidebar_toggle.callback()
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
    .pantheon_inspect_sidebar_active
  assert(sidebar_active.pair_index == 1)
  assert(sidebar_active.role == "parent")
  assert(sidebar_active.chunk_index == 1)
  assert(sidebar_active.chunk_count >= 1)
  local sidebar_signs = vim.api.nvim_get_namespaces()
    .pantheon_inspect_sidebar
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
      ~= "PantheonInspectSidebarChunkActive")
    assert(mark[4].hl_group
      ~= "PantheonInspectSidebarCurrent")
  end
  local normal_hl =
    vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local parent_hl = vim.api.nvim_get_hl(
    0,
    { name = "PantheonInspectSidebarParent", link = false }
  )
  local change_hl = vim.api.nvim_get_hl(
    0,
    { name = "PantheonInspectSidebarChange", link = false }
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
    { name = "PantheonInspectSidebarParentActive", link = false }
  )
  local change_active_hl = vim.api.nvim_get_hl(
    0,
    { name = "PantheonInspectSidebarChangeActive", link = false }
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
  assert(visible_role_groups.PantheonInspectSidebarParentActive)
  assert(visible_role_groups.PantheonInspectSidebarChange)
  assert(not visible_role_groups.PantheonInspectSidebarChangeActive)
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
      .pantheon_inspect_sidebar_active
    return vim.api.nvim_get_current_tabpage() == tabs[2]
      and vim.api.nvim_get_current_win() == sidebar_parent_win
      and active.chunk_index == selected_chunk
  end), "sidebar chunk did not open in the main pane")
  local selected_parent_line =
    vim.api.nvim_win_get_cursor(parent_win)[1]
  sidebar_active = vim.b[sidebar_buf].pantheon_inspect_sidebar_active
  assert(sidebar_active.chunk_index == selected_chunk)
  local selected_view = vim.api.nvim_win_call(
    parent_win,
    vim.fn.winsaveview
  )
  if selected_parent_line >= 10 then
    assert(selected_view.topline == selected_parent_line - 10)
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
  assert(vim.fn.winsaveview().topline
    == parent_sidebar_view.topline)
  sidebar_active = vim.b[sidebar_buf].pantheon_inspect_sidebar_active
  assert(sidebar_active.pair_index == 1)
  assert(sidebar_active.role == "change")
  sidebar_switch_mapping.callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  assert(vim.api.nvim_get_current_win() == sidebar_parent_win)
  assert(vim.api.nvim_win_get_cursor(sidebar_parent_win)[1]
    == selected_chunk_line)
  sidebar_active = vim.b[sidebar_buf].pantheon_inspect_sidebar_active
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
    vim.api.nvim_replace_termcodes("<C-s>", true, false, true),
    "x",
    false
  )
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  sidebar_active = vim.b[sidebar_buf].pantheon_inspect_sidebar_active
  assert(sidebar_active.pair_index == 1)
  assert(sidebar_active.role == "change")
  visible_role_groups = sidebar_role_groups(file_lines[1])
  assert(visible_role_groups.PantheonInspectSidebarParent)
  assert(visible_role_groups.PantheonInspectSidebarChangeActive)
  assert(not visible_role_groups.PantheonInspectSidebarParentActive)
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<C-s>", true, false, true),
    "x",
    false
  )
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  sidebar_active = vim.b[sidebar_buf].pantheon_inspect_sidebar_active
  assert(sidebar_active.role == "parent")
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<C-s>", true, false, true),
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
    assert(vim.api.nvim_win_get_cursor(second_sidebar_win)[1]
      == file_lines[2])
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
      .pantheon_inspect_sidebar_active
    assert(sidebar_active.pair_index == 2)
    assert(sidebar_active.role == "parent")
    local second_first_parent_line =
      vim.api.nvim_win_get_cursor(second_main_win)[1]
    sidebar_open_mapping.callback()
    assert(vim.api.nvim_get_current_win() == second_main_win)
    assert(vim.api.nvim_win_get_cursor(second_main_win)[1]
      == second_first_parent_line)
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
  vim.api.nvim_set_current_win(change_win)
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = change_buf })
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
    oil.setup({ watch_for_changes = false })
    vim.api.nvim_set_current_tabpage(tabs[3])
    oil.open()
    assert(vim.wait(10000, function()
      local oil_buf = vim.api.nvim_get_current_buf()
      if vim.bo[oil_buf].filetype ~= "oil" then
        return false
      end
      local oil_signs = vim.api.nvim_get_namespaces()
        .pantheon_inspect_oil
      return oil_signs
        and #vim.api.nvim_buf_get_extmarks(
          oil_buf,
          oil_signs,
          0,
          -1,
          {}
        ) > 0
    end), "Oil entries were not decorated")
    local oil_buf = vim.api.nvim_get_current_buf()
    assert(vim.fs.normalize(oil.get_current_dir()):lower()
      == vim.fs.normalize(change_state.directory):lower())
    local oil_signs = vim.api.nvim_get_namespaces().pantheon_inspect_oil
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
  end
end
