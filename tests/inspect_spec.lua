local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local oil_runtime = vim.env.PANTHEON_INSPECT_TEST_OIL
if oil_runtime then
  vim.opt.runtimepath:append(oil_runtime)
end

local inspect = require("pantheon.inspect")

local parsed = inspect._parse_commit_url(
  "https://github.com/neovim/neovim/commit/"
    .. "0123456789abcdef0123456789abcdef01234567#diff"
)
assert(parsed)
assert(parsed.owner == "neovim")
assert(parsed.repo == "neovim")
assert(parsed.sha == "0123456789abcdef0123456789abcdef01234567")
assert(parsed.remote_url == "https://github.com/neovim/neovim.git")

assert(inspect._parse_commit_url("https://codeberg.org/a/b/commit/0123456")
  == nil)
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

local resolved_pull_request = inspect._apply_pull_request(pull_request, {
  title = "Test pull request",
  base_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  base_ref = "main",
  head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  head_ref = "feature",
})
assert(resolved_pull_request.base_ref == "main")
assert(resolved_pull_request.head_ref == "feature")
assert(resolved_pull_request.base_sha:match("^a+$"))
assert(resolved_pull_request.head_sha:match("^b+$"))

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
local jump_lines = inspect._change_lines(hunks)
assert(vim.deep_equal(jump_lines, { 10, 25, 31 }))
assert(inspect._next_change_line(jump_lines, 10, 1) == 25)
assert(inspect._next_change_line(jump_lines, 31, 1) == 10)
assert(inspect._next_change_line(jump_lines, 25, -1) == 10)
assert(inspect._next_change_line(jump_lines, 10, -1) == 31)

local missing_root = vim.env.PANTHEON_INSPECT_TEST_MISSING_ROOT
if missing_root then
  local ok, err = inspect.open(
    "https://github.com/pantheon/missing/commit/"
      .. "0123456789abcdef0123456789abcdef01234567",
    {
      inspect_root = missing_root,
      inspect_search_paths = {},
      inspect_repositories = {},
      inspect_allow_remote_clone = false,
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
  local tabs = vim.api.nvim_list_tabpages()
  local state = vim.api.nvim_tabpage_get_var(tabs[3], "pantheon_inspect")
  assert(state.error:match("remote cloning is disabled"))
  assert(vim.uv.fs_stat(vim.fs.joinpath(
    missing_root,
    "repositories",
    "pantheon",
    "missing.git"
  )) == nil)
end

local integration_root = vim.env.PANTHEON_INSPECT_TEST_ROOT
local integration_sha = vim.env.PANTHEON_INSPECT_TEST_SHA
local integration_url = vim.env.PANTHEON_INSPECT_TEST_URL
if integration_root and (integration_sha or integration_url) then
  local integration_repository =
    vim.env.PANTHEON_INSPECT_TEST_REPOSITORY or "pantheon/test"
  local integration_source = vim.env.PANTHEON_INSPECT_TEST_SOURCE
  local integration_search_root =
    vim.env.PANTHEON_INSPECT_TEST_SEARCH_ROOT
  local integration_cwd = vim.env.PANTHEON_INSPECT_TEST_CWD
  local repositories = {}
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
      inspect_root = integration_root,
      inspect_repositories = repositories,
      inspect_search_paths = integration_search_root
          and { integration_search_root }
        or {},
    }
  )
  assert(ok, err)
  local loading_tabs = vim.api.nvim_list_tabpages()
  assert(#loading_tabs == 3)
  local loading_state = vim.api.nvim_tabpage_get_var(
    loading_tabs[3],
    "pantheon_inspect"
  )
  assert(loading_state.loading)

  assert(vim.wait(60000, function()
    local current_tabs = vim.api.nvim_list_tabpages()
    if #current_tabs ~= 3 then
      return false
    end
    local state_ok, state = pcall(
      vim.api.nvim_tabpage_get_var,
      current_tabs[3],
      "pantheon_inspect"
    )
    return state_ok and state.loading == false and state.commit ~= nil
  end), "inspection tabs were not opened")

  local tabs = vim.api.nvim_list_tabpages()
  local parent_state = vim.api.nvim_tabpage_get_var(
    tabs[2],
    "pantheon_inspect"
  )
  local change_state = vim.api.nvim_tabpage_get_var(
    tabs[3],
    "pantheon_inspect"
  )
  assert(parent_state.role == (integration_url and "base" or "parent"))
  assert(change_state.role == "change")
  if integration_sha and not integration_url then
    assert(change_state.commit == integration_sha)
  end

  local parent_win = vim.api.nvim_tabpage_list_wins(tabs[2])[1]
  local change_win = vim.api.nvim_tabpage_list_wins(tabs[3])[1]
  local parent_buf = vim.api.nvim_win_get_buf(parent_win)
  local change_buf = vim.api.nvim_win_get_buf(change_win)
  local namespaces = vim.api.nvim_get_namespaces()
  local signs = namespaces.pantheon_inspect_changes
  assert(signs)
  assert(#vim.api.nvim_buf_get_extmarks(
    parent_buf,
    signs,
    0,
    -1,
    {}
  ) > 0)
  local change_marks = vim.api.nvim_buf_get_extmarks(
    change_buf,
    signs,
    0,
    -1,
    {}
  )
  assert(#change_marks > 0)
  assert(vim.api.nvim_win_get_cursor(change_win)[1]
    == change_marks[1][2] + 1)
  assert(vim.api.nvim_win_get_cursor(parent_win)[1]
    == change_marks[1][2] + 1)

  local jump_maps = vim.api.nvim_buf_get_keymap(change_buf, "n")
  local previous_mapped = false
  local next_mapped = false
  for _, mapping in ipairs(jump_maps) do
    if mapping.desc == "Previous Pantheon change" then
      previous_mapped = mapping.lhs == "[c"
    elseif mapping.desc == "Next Pantheon change" then
      next_mapped = mapping.lhs == "]c"
    end
  end
  assert(previous_mapped)
  assert(next_mapped)

  vim.api.nvim_set_current_tabpage(tabs[3])
  local linked_line = math.min(
    2,
    vim.api.nvim_buf_line_count(parent_buf),
    vim.api.nvim_buf_line_count(change_buf)
  )
  vim.api.nvim_win_set_cursor(change_win, { linked_line, 0 })
  vim.api.nvim_exec_autocmds("CursorMoved", { buffer = change_buf })
  assert(vim.api.nvim_win_get_cursor(parent_win)[1] == linked_line)

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
    oil.open(change_state.worktree)
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
    assert(oil_highlight.bg == nil)
  end
end
