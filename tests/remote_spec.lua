local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.cmd("filetype plugin on")
local inspect = require("oculus.inspect")
local git = require("oculus.inspect.git")
local agent = require("oculus.agent")
local github = require("oculus.github")

local function numbered(count, prefix)
  local lines = {}

  for index = 1, count do
    lines[index] = ("%s %d"):format(prefix or "line", index)
  end

  return lines
end

do
  local parent = numbered(100)
  local change = numbered(100)
  change[50] = "changed 50"

  local excerpt = inspect._excerpt(parent, change, {
    { old_start = 50, old_count = 1, new_start = 50, new_count = 1 },
  }, 3, { commentstring = "-- %s" })

  assert(vim.deep_equal(excerpt.change_lines, {
    "-- ⋯ 46 unchanged lines ⋯",
    "line 47",
    "line 48",
    "line 49",
    "changed 50",
    "line 51",
    "line 52",
    "line 53",
    "-- ⋯ 47 unchanged lines ⋯",
  }))

  assert(excerpt.parent_lines[5] == "line 50")
  assert(#excerpt.parent_lines == #excerpt.change_lines)
  assert(excerpt.hidden == 93)

  assert(vim.deep_equal(excerpt.hunks, {
    {
      old_start = 5,
      old_count = 1,
      new_start = 5,
      new_count = 1,
      source_old_start = 50,
      source_new_start = 50,
    },
  }))

  assert(inspect._excerpt_line(excerpt.change_ranges, 50) == 5)
  assert(inspect._excerpt_line(excerpt.change_ranges, 47) == 2)
  assert(inspect._excerpt_line(excerpt.change_ranges, 10) == 1)
  assert(inspect._excerpt_line(excerpt.change_ranges, 90) == 9)
  assert(inspect._sidebar_chunk_row(excerpt.hunks[1], true) == "  └─ 50-50")
end

do
  local parent = numbered(30)
  local change = numbered(30)
  table.insert(change, 16, "inserted")
  -- The gap between the two hunks is not larger than both context bands, so
  -- nothing between them is hidden.
  change[5] = "changed 5"

  local excerpt = inspect._excerpt(parent, change, {
    { old_start = 5, old_count = 1, new_start = 5, new_count = 1 },
    { old_start = 15, old_count = 0, new_start = 16, new_count = 1 },
  }, 5, { commentstring = "/*%s*/" })

  assert(excerpt.change_lines[1] == "/* ⋯ 4 unchanged lines ⋯ */"
    or excerpt.change_lines[1] == "line 1")

  for index = 5, 20 do
    assert(vim.tbl_contains(excerpt.parent_lines, "line " .. index))
  end

  assert(excerpt.change_lines[excerpt.hunks[2].new_start] == "inserted")
  assert(excerpt.hunks[2].old_count == 0)
  assert(excerpt.parent_lines[excerpt.hunks[2].old_start] == "line 15")
end

do
  local added = inspect._excerpt({ "" }, { "one", "two" }, {
    { old_start = 0, old_count = 0, new_start = 1, new_count = 2 },
  }, 3)

  assert(vim.deep_equal(added.change_lines, { "one", "two" }))
  assert(vim.deep_equal(added.parent_lines, { "" }))
  assert(added.hunks[1].old_start == 0 and added.hunks[1].new_start == 1)

  local deleted = inspect._excerpt({ "one", "two" }, { "" }, {
    { old_start = 1, old_count = 2, new_start = 0, new_count = 0 },
  }, 3)

  assert(vim.deep_equal(deleted.parent_lines, { "one", "two" }))
  assert(vim.deep_equal(deleted.change_lines, { "" }))
  assert(inspect._excerpt(numbered(3), numbered(3), {}, 3) == nil)

  local whole = inspect._excerpt(numbered(100), numbered(100), {
    { old_start = 50, old_count = 1, new_start = 50, new_count = 1 },
  }, math.huge)

  assert(#whole.change_lines == 100 and whole.hidden == 0)
end

do
  assert(agent.needs_patch_locations({
    kind = "issue",
    overview = { kind = "issue" },
    {},
  }))

  assert(not agent.needs_patch_locations({
    kind = "issue",
    overview = { kind = "issue", remote = true },
    {},
  }))

  local overview_text = table.concat(inspect._sidebar_overview_lines({
    kind = "commit",
    remote = true,
    remote_context = 12,
  }, 60), "\n")

  assert(overview_text:find("Remote, ±12 lines around changes", 1, true))
end

local function git_command(...)
  local result = vim.system({
    "git",
    "-c",
    "user.name=Oculus Test",
    "-c",
    "user.email=oculus@example.invalid",
    "-c",
    "init.defaultBranch=main",
    ...,
  }, { text = true }):wait()

  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or "")
end

local function wait_for(label, predicate)
  assert(vim.wait(60000, predicate, 20), label)
end

local workspace = vim.fn.tempname()
local source = vim.fs.joinpath(workspace, "upstream")
local cache = vim.fs.joinpath(workspace, "cache")
assert(vim.fn.mkdir(source, "p") == 1)
git_command("-C", source, "init", "--quiet")
git_command("-C", source, "config", "uploadpack.allowFilter", "true")
git_command("-C", source, "config", "uploadpack.allowAnySHA1InWant", "true")

local function write(path, lines)
  local file = vim.fs.joinpath(source, path)
  vim.fn.mkdir(vim.fs.dirname(file), "p")
  assert(vim.fn.writefile(lines, file) == 0)
end

local big = numbered(120, "local value =")
write("lua/big.lua", big)
write("gone.txt", numbered(5, "gone"))
write("moved_old.txt", numbered(40, "moved"))
git_command("-C", source, "add", "--all")
git_command("-C", source, "commit", "--quiet", "-m", "base")
local base_sha = git_command("-C", source, "rev-parse", "HEAD")
big[10] = "local value = 'ten'"
big[100] = "local value = 'hundred'"
write("lua/big.lua", big)
write("added.lua", { "return {", "  added = true,", "}" })
assert(vim.fn.delete(vim.fs.joinpath(source, "gone.txt")) == 0)
git_command("-C", source, "mv", "moved_old.txt", "moved_new.txt")
local moved = numbered(40, "moved")
moved[20] = "moved twenty"
write("moved_new.txt", moved)
git_command("-C", source, "add", "--all")
git_command("-C", source, "commit", "--quiet", "-m", "feature")
local feature_sha = git_command("-C", source, "rev-parse", "HEAD")
big[60] = "local value = 'sixty'"
write("lua/big.lua", big)
git_command("-C", source, "commit", "--quiet", "--all", "-m", "follow up")
local follow_sha = git_command("-C", source, "rev-parse", "HEAD")
local follow_big_blob = git_command("-C", source, "rev-parse", follow_sha .. ":lua/big.lua")
local remote_url = "file://" .. source

local opts = {
  inspect_repositories = {},
  inspect_search_paths = {},
  inspect_remote_cache = cache,
  inspect_remote_context = 3,
}

local function commit_info(sha)
  return {
    kind = "commit",
    forge = "github",
    owner = "Oculus",
    repo = "Upstream",
    sha = sha,
    remote_url = remote_url,
  }
end

local original_cwd = vim.fn.getcwd()
vim.api.nvim_set_current_dir(workspace)
local original_commit_sha = github.commit_sha
local expanded

github.commit_sha = function(repo, sha, _, callback)
  assert(repo == "Oculus/Upstream")
  expanded = sha

  vim.schedule(function()
    callback(feature_sha:sub(1, #sha) == sha and feature_sha or nil)
  end)
end

local commit = commit_info(feature_sha:sub(1, 10))
local inspections, prepare_err

inspect._prepare(commit, opts, function(result, err)
  inspections = result
  prepare_err = err or false
end)

wait_for("remote commit preparation did not finish", function()
  return prepare_err ~= nil
end)

github.commit_sha = original_commit_sha
assert(not prepare_err, prepare_err)
assert(expanded == feature_sha:sub(1, 10))
assert(commit.sha == feature_sha)
assert(commit.remote and commit.remote_context == 3)
assert(commit.commit_details and commit.commit_details.subject == "feature")
local cache_repository = inspect._remote_repository_path(commit, opts)
assert(cache_repository == vim.fs.joinpath(cache, "github", "oculus", "upstream"))
assert(git_command("-C", cache_repository, "rev-parse", "--is-shallow-repository") == "true")
local by_file = {}

for _, inspection in ipairs(inspections) do
  assert(inspection.remote)
  assert(inspection.repository == cache_repository)
  by_file[inspection.change_file] = inspection
end

assert(#inspections == 4, vim.inspect(vim.tbl_keys(by_file)))
assert(by_file["moved_new.txt"].status == "R")
assert(by_file["moved_new.txt"].parent_file == "moved_old.txt")
assert(by_file["gone.txt"].status == "D")

assert(vim.deep_equal(by_file["added.lua"].change_lines, {
  "return {",
  "  added = true,",
  "}",
}))

local big_inspection = by_file["lua/big.lua"]
assert(big_inspection.excerpt)
assert(#big_inspection.hunks == 2)
assert(big_inspection.hunks[1].source_new_start == 10)
assert(big_inspection.hunks[2].source_new_start == 100)

assert(big_inspection.change_lines[big_inspection.hunks[1].new_start]
  == "local value = 'ten'")

assert(big_inspection.change_lines[big_inspection.hunks[2].new_start]
  == "local value = 'hundred'")

assert(big_inspection.parent_lines[big_inspection.hunks[2].old_start]
  == "local value = 100")

assert(big_inspection.change_lines[1] == "-- ⋯ 6 unchanged lines ⋯")
assert(#big_inspection.change_lines == 17)
assert(big_inspection.patch:find("@@ -10 +10 @@", 1, true))
local lazy_output, lazy_err

git.run({
  "git",
  "-C",
  cache_repository,
  "cat-file",
  "-p",
  follow_big_blob,
}, function(output, err)
  lazy_output = output
  lazy_err = err or false
end)

wait_for("missing remote object read did not finish", function()
  return lazy_err ~= nil
end)

assert(lazy_output == nil and lazy_err, "missing objects must not be lazily fetched")
local found_local = false
local found_local_done = false
vim.api.nvim_set_current_dir(cache_repository)

inspect._find_local_repository(commit_info(feature_sha), {
  inspect_repositories = {},
  inspect_search_paths = { cache },
  inspect_remote_cache = cache,
}, function(path)
  found_local = path
  found_local_done = true
end)

wait_for("remote cache candidate search did not finish", function()
  return found_local_done
end)

vim.api.nvim_set_current_dir(workspace)
assert(found_local == nil, "remote cache repositories must not count as clones")

local pull_request = {
  kind = "pull_request",
  forge = "github",
  owner = "oculus",
  repo = "upstream",
  number = 7,
  base_sha = base_sha,
  head_sha = follow_sha,
  commit_count = 2,
  commits = {
    { sha = feature_sha },
    { sha = follow_sha },
  },
  remote_url = remote_url,
}

local results = {}

for index = 1, 2 do
  inspect._prepare(vim.deepcopy(pull_request), vim.tbl_extend("force", opts, {
    inspect_remote_context = index == 1 and 3 or math.huge,
  }), function(result, err)
    results[index] = { inspections = result, err = err }
  end)
end

wait_for("concurrent remote pull request preparation did not finish", function()
  return results[1] ~= nil and results[2] ~= nil
end)

for index, result in ipairs(results) do
  assert(not result.err, result.err)
  local by_commit = {}

  for _, inspection in ipairs(result.inspections) do
    by_commit[inspection.commit_index] = (by_commit[inspection.commit_index] or 0) + 1

    if inspection.commit == follow_sha then
      assert(inspection.change_file == "lua/big.lua")
      assert(inspection.hunks[1].source_new_start == 60)

      if index == 2 then
        assert(#inspection.change_lines == 120)
        assert(inspection.excerpt.hidden == 0)
      else
        assert(#inspection.change_lines < 20)
      end
    end
  end

  assert(by_commit[1] == 4 and by_commit[2] == 1, vim.inspect(by_commit))
end

local missing_err

inspect._prepare(
  commit_info("0123456789abcdef0123456789abcdef01234567"),
  opts,
  function(_, err)
    missing_err = err or false
  end
)

wait_for("missing remote commit did not fail", function()
  return missing_err ~= nil
end)

assert(missing_err and missing_err:match("could not fetch commit"), missing_err)
local lifecycle_error
local lifecycle_done = false
local tabs_before = #vim.api.nvim_list_tabpages()

local ok, open_err = inspect.open(commit_info(feature_sha), opts, nil, {
  on_complete = function(message)
    lifecycle_error = message
    lifecycle_done = true
  end,
})

assert(ok, open_err)

wait_for("remote inspection tabs did not open", function()
  return lifecycle_done
end)

assert(not lifecycle_error, lifecycle_error)
assert(#vim.api.nvim_list_tabpages() == tabs_before + 8)
local marker_buffers = 0

for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
  local state_ok, state = pcall(vim.api.nvim_tabpage_get_var, tab, "oculus_inspect")

  if state_ok and state.file == "lua/big.lua" then
    local buf = vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_get_win(tab))
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    if lines[1] == "-- ⋯ 6 unchanged lines ⋯" then
      marker_buffers = marker_buffers + 1
    end

    assert(#lines < 30)
  end
end

assert(marker_buffers == 2, marker_buffers)
vim.api.nvim_set_current_dir(original_cwd)
assert(vim.fn.delete(workspace, "rf") == 0)
print("remote_spec: ok")
