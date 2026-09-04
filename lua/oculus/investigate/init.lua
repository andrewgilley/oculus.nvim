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
      id = tostring(issue.number or target or ""),
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
        id = tostring(issue.number or target or ""),
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
        id = tostring(pr.number or target or ""),
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

  vim.notify("Oculus: Running investigation...", vim.log.levels.INFO)

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
  end)
end

function M.investigate(target, opts, context, callback)
  opts = opts or {}
  context = context or {}
  local repo_root = context.cwd

  if not repo_root or repo_root == "" then
    if context.project and context.project.path then
      repo_root = context.project.path
    else
      repo_root = vim.fn.getcwd()
    end
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
            fetch_fn(repo, parsed.id, opts, function(details, err)
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
                elseif parsed.kind == "issue" then
                  resolved_target = nil
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
end

function M.close()
  window.close()
end

return M
