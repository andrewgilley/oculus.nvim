-- Preparing the content of an inspection before any window opens: reading each
-- side of a change out of the repository (or, without a clone, fetching just
-- the changed files), turning a commit or pull request into the pairs of file
-- versions the tabs are built from, and the commit details the overview shows.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local git = require("oculus.inspect.git")
local patch = require("oculus.inspect.patch")
local M = {}
local changed_file_read_concurrency = 8
local default_remote_context = 20

function M.setup(inspect)
  local function blob_lines(output)
    local lines = vim.split(output or "", "\n", { plain = true })

    if #lines > 1 and lines[#lines] == "" then
      table.remove(lines)
    end

    for index, line in ipairs(lines) do
      lines[index] = line:gsub("\r$", "")
    end

    return #lines > 0 and lines or { "" }
  end

  local function read_revision_file(repository, revision, file, missing, callback)
    if missing then
      callback({ "" })
      return
    end

    git.run_raw({
      "git",
      "-C",
      repository,
      "show",
      revision .. ":" .. file,
    }, function(output, err)
      if err then
        callback(nil, "could not read inspected file: " .. err)
        return
      end

      callback(blob_lines(output))
    end)
  end

  local function excerpt_commentstring(file)
    if type(file) ~= "string" or file == "" then
      return nil
    end

    local ok, filetype = pcall(vim.filetype.match, { filename = file })

    if not ok or type(filetype) ~= "string" or filetype == "" then
      return nil
    end

    local option_ok, commentstring = pcall(
      vim.filetype.get_option,
      filetype,
      "commentstring"
    )

    return option_ok and commentstring or nil
  end

  local function read_revision_diff(
    repository,
    info,
    pair,
    commit_index,
    callback
  )
    git.run({
      "git",
      "-C",
      repository,
      "diff",
      "--name-status",
      "-M",
      pair.parent,
      pair.commit,
      "--",
    }, function(changes, diff_err)
      if diff_err then
        callback(nil, "could not read commit changes: " .. diff_err)
        return
      end

      local changed_files = patch.parse_changed_files(changes)
      local reads = {}
      local tasks = {}

      for file_index, changed_file in ipairs(changed_files) do
        local parent_file = changed_file.old_path
        local change_file = changed_file.new_path

        local read = {
          changed_file = changed_file,
          parent_file = parent_file,
          change_file = change_file,
          parent_lines = changed_file.status == "A" and { "" } or nil,
          change_lines = changed_file.status == "D" and { "" } or nil,
        }

        reads[file_index] = read

        local diff_command = {
          "git",
          "-C",
          repository,
          "diff",
          "--no-color",
          "--no-ext-diff",
          "--unified=0",
          "-M",
          pair.parent,
          pair.commit,
          "--",
          parent_file,
        }

        if change_file ~= parent_file then
          diff_command[#diff_command + 1] = change_file
        end

        tasks[#tasks + 1] = function(done)
          git.run(diff_command, function(patch_content, patch_err)
            if patch_err then
              done(nil, "could not read file hunks: " .. patch_err)
              return
            end

            read.patch = patch_content
            done(true)
          end)
        end

        if changed_file.status ~= "A" then
          tasks[#tasks + 1] = function(done)
            read_revision_file(
              repository,
              pair.parent,
              parent_file,
              false,
              function(parent_lines, parent_err)
                if parent_err then
                  done(nil, parent_err)
                  return
                end

                read.parent_lines = parent_lines
                done(true)
              end
            )
          end
        end

        if changed_file.status ~= "D" then
          tasks[#tasks + 1] = function(done)
            read_revision_file(
              repository,
              pair.commit,
              change_file,
              false,
              function(change_lines, change_err)
                if change_err then
                  done(nil, change_err)
                  return
                end

                read.change_lines = change_lines
                done(true)
              end
            )
          end
        end
      end

      git.map_concurrently(
        tasks,
        changed_file_read_concurrency,
        function(task, _, done)
          task(done)
        end,
        function(_, read_err)
          if read_err then
            callback(nil, read_err)
            return
          end

          local inspections = {}

          for file_index, read in ipairs(reads) do
            local changed_file = read.changed_file

            local inspection = {
              kind = info.kind,
              parent = pair.parent,
              commit = pair.commit,
              parent_role = info.kind == "pull_request"
                  and "old"
                or "parent",
              repository = repository,
              parent_file = read.parent_file,
              change_file = read.change_file,
              parent_lines = read.parent_lines,
              change_lines = read.change_lines,
              patch = read.patch,
              changes = changed_files,
              commit_index = commit_index,
              file_index = file_index,
              file_count = #changed_files,
              status = changed_file.status,
              remote = info.remote,
            }

            if info.remote then
              local excerpt = patch.excerpt(
                read.parent_lines,
                read.change_lines,
                patch.parse_hunks(read.patch),
                info.remote_context,
                {
                  commentstring = excerpt_commentstring(
                    read.change_file or read.parent_file
                  ),
                }
              )

              if excerpt then
                inspection.parent_lines = excerpt.parent_lines
                inspection.change_lines = excerpt.change_lines
                inspection.hunks = excerpt.hunks

                inspection.excerpt = {
                  parent = excerpt.parent_ranges,
                  change = excerpt.change_ranges,
                  parent_count = excerpt.parent_count,
                  change_count = excerpt.change_count,
                  hidden = excerpt.hidden,
                }
              end
            end

            inspections[file_index] = inspection
          end

          callback(inspections)
        end
      )
    end)
  end

  local function prepare_revision(
    repository,
    info,
    pair,
    commit_index,
    callback
  )
    read_revision_diff(
      repository,
      info,
      pair,
      commit_index,
      callback
    )
  end

  local function load_commit_overview(repository, info, commit, callback)
    if info.kind ~= "commit" then
      callback()
      return
    end

    -- git show diffs a merge against its parents even with --no-patch, and
    -- rename detection there reads blobs a remote cache does not hold; git
    -- log reads only the commit.
    git.run_raw({
      "git",
      "-C",
      repository,
      "log",
      "-1",
      "--format=%H%x00%P%x00%an%x00%ae%x00%aI%x00%s%x00%b",
      commit,
    }, function(output)
      info.commit_details = patch.parse_commit_overview(output)
      callback()
    end)
  end

  local function remote_context(opts)
    local context = tonumber(opts.inspect_remote_context)

    if not context or context < 0 then
      return default_remote_context
    end

    return context == math.huge and context or math.floor(context)
  end

  local function expand_commit_sha(info, opts, callback)
    if info.kind ~= "commit"
      or type(info.sha) ~= "string"
      or #info.sha >= 40
    then
      callback(true)
      return
    end

    local provider = info.forge == "codeberg" and codeberg or github

    provider.commit_sha(
      info.owner .. "/" .. info.repo,
      info.sha,
      opts,
      function(sha, err)
        if not sha then
          callback(nil, "could not resolve commit " .. info.sha .. ": "
            .. tostring(err))

          return
        end

        info.sha = sha
        callback(true)
      end
    )
  end

  local function fetch_revision_pairs(
    repository,
    fetch_source,
    remote,
    info,
    opts,
    callback
  )
    if not remote then
      git.fetch_pair(repository, fetch_source, info, function(commits, commit_err)
        if commit_err then
          callback(nil, nil, commit_err)
          return
        end

        git.revision_pairs(repository, info, commits, function(pairs, pairs_err)
          callback(commits, pairs, pairs_err)
        end)
      end)

      return
    end

    expand_commit_sha(info, opts, function(_, expand_err)
      if expand_err then
        callback(nil, nil, expand_err)
        return
      end

      git.fetch_remote_revisions(repository, info, function(commits, pairs, err)
        if err then
          callback(nil, nil, err)
          return
        end

        git.prefetch_remote_blobs(repository, pairs, function(_, prefetch_err)
          callback(commits, pairs, prefetch_err)
        end)
      end)
    end)
  end

  local function prepare(info, opts, callback)
    git.ensure_repository(info, opts, function(
      repository,
      repository_err,
      fetch_source,
      remote
    )
      if repository_err then
        callback(nil, repository_err)
        return
      end

      if not repository then
        callback(nil, "inspect requires a standard local repository")
        return
      end

      if remote then
        info.remote = true
        info.remote_context = remote_context(opts)
      end

      fetch_revision_pairs(
        repository,
        fetch_source,
        remote,
        info,
        opts,
        function(commits, pairs, pairs_err)
          if pairs_err then
            callback(nil, pairs_err)
            return
          end

          if remote then
            local tree_commits = {}

            for _, pair in ipairs(pairs) do
              tree_commits[#tree_commits + 1] = pair.parent
              tree_commits[#tree_commits + 1] = pair.commit
            end

            -- Lay out the directory structure in the background so oil.nvim
            -- can browse it; the files themselves stay empty.
            git.materialize_remote_tree(repository, tree_commits)
          end

          load_commit_overview(repository, info, commits.commit, function()
            local inspections = {}
            local index = 1

            local function prepare_next()
              local pair = pairs[index]

              if not pair then
                if #inspections == 0 then
                  callback(
                    nil,
                    "the inspected revisions do not change any files"
                  )

                  return
                end

                callback(inspections)
                return
              end

              prepare_revision(
                repository,
                info,
                pair,
                index,
                function(commit_inspections, err)
                  if err then
                    callback(nil, err)
                    return
                  end

                  for _, inspection in ipairs(commit_inspections) do
                    inspections[#inspections + 1] = inspection
                  end

                  index = index + 1
                  prepare_next()
                end
              )
            end

            prepare_next()
          end)
        end
      )
    end)
  end

  local function apply_pull_request(info, details)
    local resolved = vim.deepcopy(info)

    for _, key in ipairs({
      "title",
      "body",
      "author",
      "state",
      "draft",
      "merged",
      "html_url",
      "created_at",
      "base_sha",
      "base_ref",
      "head_sha",
      "head_ref",
      "fetch_ref",
      "commit_count",
      "commits",
      "mergeable",
      "mergeable_state",
      "requested_reviewers",
    }) do
      resolved[key] = details[key]
    end

    return resolved
  end

  return {
    blob_lines = blob_lines,
    read_revision_file = read_revision_file,
    read_revision_diff = read_revision_diff,
    prepare_revision = prepare_revision,
    load_commit_overview = load_commit_overview,
    remote_context = remote_context,
    expand_commit_sha = expand_commit_sha,
    fetch_revision_pairs = fetch_revision_pairs,
    prepare = prepare,
    apply_pull_request = apply_pull_request,
  }
end

return M
