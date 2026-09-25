vim.opt.runtimepath:prepend(vim.fn.getcwd())
local inspect = require("oculus.inspect")

local function git(directory, ...)
  local result = vim.system({
    "git",
    "-c",
    "user.name=Oculus Test",
    "-c",
    "user.email=oculus@example.invalid",
    "-c",
    "init.defaultBranch=main",
    "-C",
    directory,
    ...,
  }, { text = true }):wait()

  assert(result.code == 0, result.stderr)
  return vim.trim(result.stdout or "")
end

local function numbered(count)
  local lines = {}

  for index = 1, count do
    lines[index] = "line " .. index
  end

  return lines
end

-- Three chunks: two lines added after line 5, line 15 changed, line 25 removed.
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
git(directory, "init", "--quiet")
git(directory, "remote", "add", "origin", "https://github.com/oculus/versions.git")
local parent = numbered(30)
vim.fn.writefile(parent, directory .. "/file.txt")
git(directory, "add", "file.txt")
git(directory, "commit", "--quiet", "-m", "base")
local change = numbered(30)
table.remove(change, 25)
change[15] = "changed 15"
table.insert(change, 6, "added a")
table.insert(change, 7, "added b")
vim.fn.writefile(change, directory .. "/file.txt")
git(directory, "commit", "--quiet", "--all", "-m", "three chunks")
local sha = git(directory, "rev-parse", "HEAD")
local done, open_err

local ok, err = inspect.open({
  kind = "commit",
  forge = "github",
  owner = "oculus",
  repo = "versions",
  sha = sha,
  remote_url = "https://github.com/oculus/versions.git",
}, {
  inspect_repositories = { directory },
  inspect_search_paths = {},
}, nil, {
  on_complete = function(message)
    open_err = message
    done = true
  end,
})

assert(ok, err)
assert(vim.wait(30000, function() return done end, 20), "inspection did not open")
assert(not open_err, open_err)

local function press(lhs)
  local mapping = vim.fn.maparg(lhs, "n", false, true)
  assert(mapping and mapping.callback, "missing mapping " .. lhs)
  mapping.callback()
end

local function role()
  return vim.b[vim.api.nvim_get_current_buf()].oculus_inspect.role
end

local function shown()
  return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

-- The file with the given chunks in their new version.
local function composed(new)
  local lines = {}

  for index = 1, 30 do
    if index == 6 and new[1] then
      lines[#lines + 1] = "added a"
      lines[#lines + 1] = "added b"
    end

    if index == 15 and new[2] then
      lines[#lines + 1] = "changed 15"
    elseif not (index == 25 and new[3]) then
      lines[#lines + 1] = "line " .. index
    end
  end

  return lines
end

local function sidebar_buf()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.b[buf].oculus_inspect_sidebar_active then
      return buf
    end
  end
end

local function active_chunk()
  return vim.b[sidebar_buf()].oculus_inspect_sidebar_active.chunk_index
end

-- The colour of the dot at the end of each chunk row, in order.
local function dots()
  local buf = sidebar_buf()
  local result = {}

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(buf, -1, 0, -1, { details = true })) do
    local text = mark[4].virt_text

    if text and text[1] and text[1][1] == " ●" then
      result[#result + 1] = text[1][2] == "OculusInspectSidebarChange" and "new" or "old"
    end
  end

  return table.concat(result, " ")
end

-- Every chunk starts old, on the old tab.
assert(role() == "parent" and active_chunk() == 1)
assert(vim.deep_equal(shown(), parent))
assert(dots() == "old old old", dots())
-- Setting the first chunk to new keeps it new on the next chunk, which opens
-- old.
press("<C-d>")
assert(role() == "change" and active_chunk() == 1)
assert(vim.deep_equal(shown(), composed({ true })))
assert(dots() == "new old old", dots())
press("<C-Tab>")
assert(role() == "parent" and active_chunk() == 2)
assert(vim.deep_equal(shown(), composed({ true })))
-- Both tabs show the other chunks in their saved versions and differ only in
-- the chunk you are on.
press("<C-d>")
assert(role() == "change" and active_chunk() == 2)
assert(vim.deep_equal(shown(), composed({ true, true })))
assert(dots() == "new new old", dots())
press("<C-Tab>")
assert(role() == "parent" and active_chunk() == 3)
assert(vim.deep_equal(shown(), composed({ true, true })))
local cursor = vim.api.nvim_win_get_cursor(0)[1]
assert(shown()[cursor] == "line 25", shown()[cursor])
press("<C-d>")
assert(vim.deep_equal(shown(), composed({ true, true, true })))
assert(vim.deep_equal(shown(), change))
press("<C-s>")
assert(role() == "parent" and dots() == "new new old", dots())
-- Going back lands on each chunk in the version it was left in.
press("<S-Tab>")
assert(role() == "change" and active_chunk() == 2)
cursor = vim.api.nvim_win_get_cursor(0)[1]
assert(shown()[cursor] == "changed 15", shown()[cursor])
press("<S-Tab>")
assert(role() == "change" and active_chunk() == 1)
cursor = vim.api.nvim_win_get_cursor(0)[1]
assert(shown()[cursor] == "added a", shown()[cursor])
press("<C-s>")
assert(role() == "parent" and active_chunk() == 1)
assert(vim.deep_equal(shown(), composed({ false, true })))
assert(dots() == "old new old", dots())
vim.fn.delete(directory, "rf")
print("chunk version tests passed")
