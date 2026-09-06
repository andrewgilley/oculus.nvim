local engine = require("oculus.investigate.engine")
local window = require("oculus.investigate.window")
local M = {}

local function string_val(v)
  return type(v) == "string" and v ~= "" and v or nil
end

function M.extract_forge_artifact(target, context, opts)
  context = context or {}
  opts = opts or {}

  if type(context.forge_artifact) == "table" then
    return context.forge_artifact
  end

  local project = context.project or {}
  local provider = string_val(project.provider) or "github"
  -- 1. Check target_context (from inspect_targets on cursor)
  local tc = context.target_context

  if type(tc) == "table" and type(tc.issue) == "table" then
    local issue = tc.issue
    local comments = {}

    if string_val(issue.comment) then
      table.insert(comments, {
        author = "",
        body = issue.comment,
        created_at = nil,
      })
    end

    return {
      forge = provider,
      kind = "issue",
      id = tostring(issue.number or (type(target) == "string" and (target:match("/issues/(%d+)") or target:match("#(%d+)"))) or target or ""),
      title = string_val(issue.title),
      body = string_val(issue.body),
      author = string_val(issue.author),
      state = string_val(issue.state),
      url = string_val(issue.html_url) or string_val(target),
      labels = {},
      comments = comments,
    }
  end

  -- 2. Check context.event (activity events from window)
  local event = context.event

  if type(event) == "table" then
    local payload = event.payload or {}

    if event.type == "IssuesEvent" or event.type == "IssueCommentEvent" then
      local issue = payload.issue or {}
      local comments = {}

      if type(payload.comment) == "table" and string_val(payload.comment.body) then
        local c_author = payload.comment.user and string_val(payload.comment.user.login) or ""

        table.insert(comments, {
          author = c_author,
          body = payload.comment.body,
          created_at = string_val(payload.comment.created_at),
        })
      end

      local author = (issue.user and string_val(issue.user.login))
        or string_val(issue.author)
        or (event.actor and string_val(event.actor.login))

      return {
        forge = provider,
        kind = "issue",
        id = tostring(issue.number or (type(target) == "string" and (target:match("/issues/(%d+)") or target:match("#(%d+)"))) or target or ""),
        title = string_val(issue.title),
        body = string_val(issue.body),
        author = author,
        state = string_val(issue.state),
        url = string_val(issue.html_url) or string_val(issue.url) or string_val(target),
        labels = {},
        comments = comments,
      }
    elseif event.type == "PullRequestEvent" or event.type == "PullRequestReviewCommentEvent" then
      local pr = payload.pull_request or {}
      local comments = {}

      if type(payload.comment) == "table" and string_val(payload.comment.body) then
        local c_author = payload.comment.user and string_val(payload.comment.user.login) or ""

        table.insert(comments, {
          author = c_author,
          body = payload.comment.body,
          created_at = string_val(payload.comment.created_at),
        })
      end

      local author = (pr.user and string_val(pr.user.login))
        or string_val(pr.author)
        or (event.actor and string_val(event.actor.login))

      return {
        forge = provider,
        kind = "pull_request",
        id = tostring(pr.number or (type(target) == "string" and (target:match("/pulls?/(%d+)") or target:match("#(%d+)"))) or target or ""),
        title = string_val(pr.title),
        body = string_val(pr.body),
        author = author,
        state = string_val(pr.state),
        url = string_val(pr.html_url) or string_val(pr.url) or string_val(target),
        labels = {},
        comments = comments,
      }
    end
  end

  return nil
end

function M._execute_investigation(repo_root, target, target_kind, forge_artifact, opts, callback)
  local request = {
    repo_root = repo_root,
    target = target,
    target_kind = target_kind,
    forge_artifact = forge_artifact,
    opts = opts,
  }

  return engine.run(request, function(bundle, err)
    if not bundle then
      local msg = "Investigation failed: " .. tostring(err or "unknown error")
      vim.notify("Oculus: " .. msg, vim.log.levels.WARN)

      if callback then
        callback(nil, msg)
      end

      return
    end

    window.open(bundle, opts)

    if callback then
      callback(bundle, nil)
    end

    if window.state and window.state.win and vim.api.nvim_win_is_valid(window.state.win) then
      pcall(vim.api.nvim_set_current_win, window.state.win)
    end
  end)
end

function M.resolve_target_repository_info(target, context, opts)
  context = context or {}
  opts = opts or {}

  -- 1. Check if target is a URL
  if type(target) == "string" and target:match("^https?://") then
    local ok_patch, patch = pcall(require, "oculus.inspect.patch")

    if ok_patch and patch.parse_target_url then
      local parsed = patch.parse_target_url(target)

      if parsed and parsed.owner and parsed.repo then
        return {
          owner = parsed.owner,
          repo = parsed.repo,
          forge = parsed.forge or "github",
          repository = parsed.owner .. "/" .. parsed.repo,
          remote_url = parsed.remote_url,
        }
      end
    end

    local owner, repo = target:match("^https?://github%.com/([^/]+)/([^/]+)/?$")
    local forge = "github"

    if not owner then
      owner, repo = target:match("^https?://codeberg%.org/([^/]+)/([^/]+)/?$")
      forge = "codeberg"
    end

    if owner and repo then
      repo = repo:gsub("%.git$", "")
      local host = forge == "codeberg" and "codeberg.org" or "github.com"

      return {
        owner = owner,
        repo = repo,
        forge = forge,
        repository = owner .. "/" .. repo,
        remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
      }
    end
  end

  -- 2. Check context.project
  local project = context.project

  if type(project) == "table" and type(project.repository) == "string" and project.repository ~= "" then
    local owner, repo = project.repository:match("^([^/]+)/([^/]+)$")

    if owner and repo then
      local forge = project.provider or "github"
      local host = forge == "codeberg" and "codeberg.org" or "github.com"

      return {
        owner = owner,
        repo = repo,
        forge = forge,
        repository = project.repository,
        remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
        path = project.path,
      }
    end
  end

  -- 3. Check context.repository
  if type(context.repository) == "string" and context.repository ~= "" then
    local owner, repo = context.repository:match("^([^/]+)/([^/]+)$")

    if owner and repo then
      local forge = context.provider or (context.project and context.project.provider) or "github"
      local host = forge == "codeberg" and "codeberg.org" or "github.com"

      return {
        owner = owner,
        repo = repo,
        forge = forge,
        repository = context.repository,
        remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
      }
    end
  end

  -- 4. Check context.event
  if type(context.event) == "table" and type(context.event.repo) == "table" and type(context.event.repo.name) == "string" then
    local owner, repo = context.event.repo.name:match("^([^/]+)/([^/]+)$")

    if owner and repo then
      return {
        owner = owner,
        repo = repo,
        forge = "github",
        repository = context.event.repo.name,
        remote_url = ("https://github.com/%s/%s.git"):format(owner, repo),
      }
    end
  end

  -- 5. Check if target is a table representing a project
  if type(target) == "table" then
    local p = target.project or target

    if type(p) == "table" and type(p.repository) == "string" and p.repository ~= "" then
      local owner, repo = p.repository:match("^([^/]+)/([^/]+)$")

      if owner and repo then
        local forge = p.provider or "github"
        local host = forge == "codeberg" and "codeberg.org" or "github.com"

        return {
          owner = owner,
          repo = repo,
          forge = forge,
          repository = p.repository,
          remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
          path = p.path,
        }
      end
    end
  end

  return nil
end

function M.resolve_repository_root(info, opts, context, callback)
  opts = opts or {}
  context = context or {}

  -- 1. Explicit repo_root override in context (useful for tests and programmatic calls)
  if context.repo_root and context.repo_root ~= "" and vim.fn.isdirectory(context.repo_root) == 1 then
    callback(context.repo_root, nil)
    return
  end

  -- 2. If info has an explicit path that exists
  if info and info.path and info.path ~= "" and vim.fn.isdirectory(info.path) == 1 then
    callback(info.path, nil)
    return
  end

  -- 3. Check opts.projects for matching repository with configured path
  if info and info.repository and type(opts.projects) == "table" then
    local target_repo = info.repository:lower()

    for _, p in ipairs(opts.projects) do
      if type(p) == "table" and type(p.repository) == "string" and p.repository:lower() == target_repo then
        if p.path and p.path ~= "" and vim.fn.isdirectory(p.path) == 1 then
          callback(p.path, nil)
          return
        end
      end
    end
  end

  -- 4. Check opts.inspect_repositories
  if info and info.repository and type(opts.inspect_repositories) == "table" then
    local named = opts.inspect_repositories[info.repository]
    local p = type(named) == "table" and named.path or (type(named) == "string" and named or nil)

    if p and p ~= "" and vim.fn.isdirectory(p) == 1 then
      callback(p, nil)
      return
    end
  end

  -- 5. If no specific target repository info is known (e.g. local workspace investigation)
  if not info or not info.owner or not info.repo then
    local default_root = context.cwd or vim.fn.getcwd()
    callback(default_root, nil)
    return
  end

  -- 6. Check candidates via git.ensure_repository (which checks cwd and inspect_search_paths)
  local git = require("oculus.inspect.git")

  local search_opts = vim.tbl_extend("force", opts, {
    cwd = context.cwd,
  })

  git.ensure_repository(info, search_opts, function(repo_path, err)
    if repo_path and repo_path ~= "" then
      callback(repo_path, nil)
    else
      callback(nil, err or ("No local clone of " .. info.repository .. " was found"))
    end
  end)
end

function M.investigate(target, opts, context, callback)
  opts = opts or {}
  context = context or {}

  if context.launch_origin and not opts.launch_origin then
    opts = vim.tbl_extend("force", opts, { launch_origin = context.launch_origin })
  end

  if type(target) == "table" then
    target = nil
  end

  local info = M.resolve_target_repository_info(target, context, opts)

  M.resolve_repository_root(info, opts, context, function(repo_root, err)
    if not repo_root then
      local msg = "Investigation failed: " .. tostring(err or "Unable to resolve repository root")
      vim.notify("Oculus: " .. msg, vim.log.levels.WARN)

      if callback then
        callback(nil, msg)
      end

      return
    end

    -- Synchronous extraction from active window/event context
    local forge_artifact = M.extract_forge_artifact(target, context, opts)

    if forge_artifact then
      local target_kind = forge_artifact.kind
      return M._execute_investigation(repo_root, target, target_kind, forge_artifact, opts, callback)
    end

    -- If target is provided, parse target to detect forge issues or PRs
    if target and target ~= "" and type(target) == "string" then
      local ok_target_parser, target_parser = pcall(require, "oculus.inspect.target")

      if ok_target_parser and target_parser.parse then
        local projects = opts.projects or (context.project and { context.project })
        local parsed = target_parser.parse(target, projects)

        if parsed and (parsed.kind == "issue" or parsed.kind == "pull_request") then
          local repo = parsed.repository
            or (context.project and context.project.repository)
            or context.repository

          local forge_api = (parsed.forge == "codeberg" or (context.project and context.project.provider == "codeberg"))
              and require("oculus.codeberg")
            or require("oculus.github")

          if repo and parsed.id and forge_api then
            local fetch_fn = parsed.kind == "issue" and forge_api.issue or forge_api.pull_request

            if fetch_fn then
              fetch_fn(repo, parsed.id, opts, function(details, _)
                local fetched_art = nil
                local resolved_target = target

                if details then
                  fetched_art = {
                    forge = parsed.forge or "github",
                    kind = parsed.kind,
                    id = tostring(details.number or parsed.id),
                    title = string_val(details.title),
                    body = string_val(details.body),
                    author = string_val(details.author),
                    state = string_val(details.state),
                    url = string_val(details.html_url) or parsed.url or target,
                    labels = {},
                    comments = {},
                  }

                  if parsed.kind == "pull_request" and details.head_sha then
                    resolved_target = details.head_sha
                  end
                else
                  -- Fallback minimal artifact if network fetch fails
                  fetched_art = {
                    forge = parsed.forge or "github",
                    kind = parsed.kind,
                    id = tostring(parsed.id),
                    title = nil,
                    body = nil,
                    author = nil,
                    state = nil,
                    url = parsed.url or target,
                    labels = {},
                    comments = {},
                  }
                end

                M._execute_investigation(repo_root, resolved_target, parsed.kind, fetched_art, opts, callback)
              end)

              return
            end
          end
        end
      end
    end

    return M._execute_investigation(repo_root, target, nil, nil, opts, callback)
  end)
end

function M.close()
  window.close()
end

function M.is_open()
  return window.is_open()
end

function M.can_restore()
  return window.can_restore()
end

function M.restore()
  return window.restore()
end

return M
