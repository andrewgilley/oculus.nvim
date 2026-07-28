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
local jump_lines = inspect._change_lines(hunks)
assert(vim.deep_equal(jump_lines, { 10, 25, 31 }))
assert(inspect._next_change_line(jump_lines, 10, 1) == 25)
assert(inspect._next_change_line(jump_lines, 31, 1) == 10)
assert(inspect._next_change_line(jump_lines, 25, -1) == 10)
assert(inspect._next_change_line(jump_lines, 10, -1) == 31)

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
  for pair_index = 1, pair_count do
    local old_tab = tabs[pair_index * 2]
    local new_tab = tabs[pair_index * 2 + 1]
    assert(#vim.api.nvim_tabpage_list_wins(old_tab) == 1)
    assert(#vim.api.nvim_tabpage_list_wins(new_tab) == 1)
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
    local old_buf = vim.api.nvim_win_get_buf(
      vim.api.nvim_tabpage_list_wins(old_tab)[1]
    )
    local new_buf = vim.api.nvim_win_get_buf(
      vim.api.nvim_tabpage_list_wins(new_tab)[1]
    )
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

  local parent_win = vim.api.nvim_tabpage_list_wins(tabs[2])[1]
  local change_win = vim.api.nvim_tabpage_list_wins(tabs[3])[1]
  local parent_buf = vim.api.nvim_win_get_buf(parent_win)
  local change_buf = vim.api.nvim_win_get_buf(change_win)
  if verify_revision_content then
    assert(expected_source_root)
    local content_state = change_state.status == "D"
        and parent_state
      or change_state
    local content_buf = change_state.status == "D"
        and parent_buf
      or change_buf
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
  local toggle_mapped = false
  local next_file_mapped = false
  for _, mapping in ipairs(jump_maps) do
    if mapping.desc == "Previous Pantheon change" then
      previous_mapped = mapping.lhs == "<C-Left>"
    elseif mapping.desc == "Next Pantheon change" then
      next_mapped = mapping.lhs == "<C-Right>"
    elseif mapping.desc == "Toggle Pantheon file version" then
      toggle_mapped = mapping.lhs == "<Tab>"
    elseif mapping.desc == "Next Pantheon changed file" then
      next_file_mapped = mapping.lhs == "<C-N>"
    end
  end
  assert(previous_mapped)
  assert(next_mapped)
  assert(toggle_mapped)
  assert(next_file_mapped)

  vim.api.nvim_set_current_tabpage(tabs[3])
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(change_buf)):lower()
    == vim.fs.normalize(change_state.source_path):lower())
  local initial_cursor = vim.api.nvim_win_get_cursor(change_win)
  local initial_line = vim.api.nvim_buf_get_lines(
    change_buf,
    initial_cursor[1] - 1,
    initial_cursor[1],
    false
  )[1] or ""
  assert(initial_cursor[2] == math.max(0, #initial_line - 1))
  local initial_view = vim.api.nvim_win_call(
    change_win,
    vim.fn.winsaveview
  )
  assert(initial_view.topline == math.max(1, initial_cursor[1] - 10))
  local initial_parent_cursor = vim.api.nvim_win_get_cursor(parent_win)
  local initial_parent_line = vim.api.nvim_buf_get_lines(
    parent_buf,
    initial_parent_cursor[1] - 1,
    initial_parent_cursor[1],
    false
  )[1] or ""
  assert(initial_parent_cursor[2]
    == math.max(0, #initial_parent_line - 1))
  local initial_parent_view = vim.api.nvim_win_call(
    parent_win,
    vim.fn.winsaveview
  )
  assert(initial_parent_view.topline
    == math.max(1, initial_parent_cursor[1] - 10))
  vim.api.nvim_feedkeys(
    vim.api.nvim_replace_termcodes("<Tab>", true, false, true),
    "x",
    false
  )
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(parent_buf)):lower()
    == vim.fs.normalize(parent_state.source_path):lower())
  assert(vim.api.nvim_buf_get_name(change_buf) == "")
  if pair_count > 1 then
    vim.api.nvim_feedkeys(
      vim.api.nvim_replace_termcodes("<C-n>", true, false, true),
      "x",
      false
    )
    assert(vim.api.nvim_get_current_tabpage() == tabs[4])
    vim.api.nvim_set_current_tabpage(tabs[3])
  end
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
