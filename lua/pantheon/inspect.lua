local M = {}

local active = false

local function git_error(result, fallback)
  local message = vim.trim(result.stderr or "")
  if message == "" then
    message = fallback
  end
  return message
end

local function run(command, callback)
  vim.system(command, { text = true }, function(result)
    vim.schedule(function()
      if result.code ~= 0 then
        callback(nil, git_error(result, "git command failed"))
        return
      end
      callback(vim.trim(result.stdout or ""))
    end)
  end)
end

local function parse_commit_url(url)
  if type(url) ~= "string" then
    return nil
  end

  local owner, repo, sha, suffix = url:match(
    "^https?://github%.com/([^/]+)/([^/]+)/commit/([0-9a-fA-F]+)(.*)$"
  )
  if not owner or not repo or not sha then
    return nil
  end

  repo = repo:gsub("%.git$", "")
  if
    not owner:match("^[%w][%w-]*$")
    or not repo:match("^[%w._-]+$")
    or repo == "."
    or repo == ".."
    or #sha < 7
    or #sha > 40
    or (suffix ~= "" and not suffix:match("^[/?#]"))
  then
    return nil
  end

  return {
    owner = owner,
    repo = repo,
    sha = sha:lower(),
    remote_url = ("https://github.com/%s/%s.git"):format(owner, repo),
  }
end

local function first_changed_paths(output)
  local line = output and output:match("[^\r\n]+")
  if not line then
    return nil, nil
  end

  local fields = vim.split(line, "\t", { plain = true })
  local status = fields[1] or ""
  if (status:sub(1, 1) == "R" or status:sub(1, 1) == "C")
    and fields[2]
    and fields[3]
  then
    return fields[2], fields[3]
  end
  return fields[2], fields[2]
end

local function directory(path)
  local stat = vim.uv.fs_stat(path)
  return stat and stat.type == "directory"
end

local function ensure_mirror(info, root, callback)
  local mirror = vim.fs.joinpath(
    root,
    "repositories",
    info.owner,
    info.repo .. ".git"
  )
  if directory(mirror) then
    callback(mirror)
    return
  end
  if vim.uv.fs_stat(mirror) then
    callback(nil, "the inspection repository cache is not a directory")
    return
  end

  vim.fn.mkdir(vim.fs.dirname(mirror), "p")
  run({
    "git",
    "clone",
    "--filter=blob:none",
    "--bare",
    info.remote_url,
    mirror,
  }, function(_, err)
    if err then
      callback(nil, "could not clone " .. info.owner .. "/" .. info.repo
        .. ": " .. err)
      return
    end
    callback(mirror)
  end)
end

local function fetch_commit(mirror, info, callback)
  run({
    "git",
    "--git-dir",
    mirror,
    "fetch",
    "--filter=blob:none",
    "origin",
    info.sha,
  }, function(_, err)
    if err then
      callback(nil, "could not fetch commit " .. info.sha .. ": " .. err)
      return
    end

    run({
      "git",
      "--git-dir",
      mirror,
      "rev-parse",
      info.sha .. "^{commit}",
    }, function(commit, resolve_err)
      if resolve_err then
        callback(nil, "could not resolve commit: " .. resolve_err)
        return
      end
      run({
        "git",
        "--git-dir",
        mirror,
        "rev-parse",
        commit .. "^",
      }, function(parent, parent_err)
        if parent_err then
          callback(nil, "this commit does not have an inspectable parent")
          return
        end
        callback({ commit = commit, parent = parent })
      end)
    end)
  end)
end

local function ensure_worktree(mirror, path, commit, callback)
  if directory(path) then
    run({ "git", "-C", path, "rev-parse", "HEAD" }, function(head, err)
      if err or head ~= commit then
        callback(nil, "the cached worktree at " .. path
          .. " is not at the expected commit")
        return
      end
      callback(path)
    end)
    return
  end
  if vim.uv.fs_stat(path) then
    callback(nil, "the worktree path is not a directory: " .. path)
    return
  end

  vim.fn.mkdir(vim.fs.dirname(path), "p")
  run({
    "git",
    "--git-dir",
    mirror,
    "worktree",
    "add",
    "--detach",
    path,
    commit,
  }, function(_, err)
    if err then
      callback(nil, "could not create worktree: " .. err)
      return
    end
    callback(path)
  end)
end

local function open_tab(path, file, role, commit)
  vim.cmd("tabnew")
  vim.cmd("tcd " .. vim.fn.fnameescape(path))
  if file then
    local target = vim.fs.joinpath(path, file)
    vim.cmd("edit " .. vim.fn.fnameescape(target))
  end
  vim.t.pantheon_inspect = {
    role = role,
    commit = commit,
    worktree = path,
  }
end

local function open_tabs(paths, done)
  local ok, err = pcall(function()
    require("pantheon.window").close()
    open_tab(
      paths.parent_worktree,
      paths.parent_file,
      "parent",
      paths.parent
    )
    open_tab(
      paths.change_worktree,
      paths.change_file,
      "change",
      paths.commit
    )
  end)
  if not ok then
    done(nil, "could not open inspection tabs: " .. tostring(err))
    return
  end
  done(paths)
end

local function prepare(info, opts, callback)
  local root = opts.inspect_root
    or vim.fs.joinpath(vim.fn.stdpath("cache"), "pantheon", "inspect")

  ensure_mirror(info, root, function(mirror, mirror_err)
    if mirror_err then
      callback(nil, mirror_err)
      return
    end
    fetch_commit(mirror, info, function(commits, commit_err)
      if commit_err then
        callback(nil, commit_err)
        return
      end

      run({
        "git",
        "--git-dir",
        mirror,
        "worktree",
        "prune",
      }, function(_, prune_err)
        if prune_err then
          callback(nil, "could not prune cached worktrees: " .. prune_err)
          return
        end

        local worktree_root = vim.fs.joinpath(
          root,
          "worktrees",
          info.owner,
          info.repo
        )
        local parent_path = vim.fs.joinpath(
          worktree_root,
          commits.parent
        )
        local change_path = vim.fs.joinpath(
          worktree_root,
          commits.commit
        )

        ensure_worktree(
          mirror,
          parent_path,
          commits.parent,
          function(_, parent_err)
            if parent_err then
              callback(nil, parent_err)
              return
            end
            ensure_worktree(
              mirror,
              change_path,
              commits.commit,
              function(_, change_err)
                if change_err then
                  callback(nil, change_err)
                  return
                end
                run({
                  "git",
                  "--git-dir",
                  mirror,
                  "diff",
                  "--name-status",
                  "-M",
                  commits.parent,
                  commits.commit,
                  "--",
                }, function(changes, diff_err)
                  if diff_err then
                    callback(nil, "could not read commit changes: " .. diff_err)
                    return
                  end
                  local parent_file, change_file =
                    first_changed_paths(changes)
                  callback({
                    parent = commits.parent,
                    commit = commits.commit,
                    parent_worktree = parent_path,
                    change_worktree = change_path,
                    parent_file = parent_file,
                    change_file = change_file,
                  })
                end)
              end
            )
          end
        )
      end)
    end)
  end)
end

function M.open(url, opts)
  opts = opts or {}
  local info = parse_commit_url(url)
  if not info then
    return nil, "inspect currently supports GitHub commit activity only"
  end
  if vim.fn.executable("git") ~= 1 then
    return nil, "inspect requires git"
  end
  if active then
    return nil, "an inspection is already being prepared"
  end

  active = true
  vim.notify(
    ("Pantheon: preparing %s/%s@%s for inspection"):format(
      info.owner,
      info.repo,
      info.sha:sub(1, 12)
    ),
    vim.log.levels.INFO
  )
  prepare(info, opts, function(paths, err)
    if err then
      active = false
      vim.notify("Pantheon: " .. err, vim.log.levels.ERROR)
      return
    end
    open_tabs(paths, function(_, open_err)
      active = false
      if open_err then
        vim.notify("Pantheon: " .. open_err, vim.log.levels.ERROR)
        return
      end
      vim.notify(
        "Pantheon: parent and change worktrees opened in new tabs",
        vim.log.levels.INFO
      )
    end)
  end)
  return true
end

M._parse_commit_url = parse_commit_url
M._first_changed_paths = first_changed_paths

return M
