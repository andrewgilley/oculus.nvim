local patch = require("oculus.inspect.patch")
local git = require("oculus.inspect.git")
local M = {}

function M.parse(input, projects)
  if type(input) ~= "string" and type(input) ~= "number" then
    return nil
  end

  local raw = vim.trim(tostring(input))

  if raw == "" then
    return nil
  end

  if raw:match("^https?://") then
    local parsed_url = patch.parse_target_url(raw)

    if parsed_url then
      return {
        url = raw,
        info = parsed_url,
        kind = parsed_url.kind,
        id = parsed_url.number or parsed_url.sha,
        owner = parsed_url.owner,
        repo = parsed_url.repo,
        repository = parsed_url.owner .. "/" .. parsed_url.repo,
        forge = parsed_url.forge,
      }
    end

    return { url = raw }
  end

  local str = raw
  local owner, repo, forge

  if type(projects) == "table" then
    for _, p in ipairs(projects) do
      if type(p) == "table" and type(p.repository) == "string" then
        local p_name = type(p.name) == "string" and p.name:lower() or nil
        local p_repo = p.repository:lower()
        local p_owner, p_reponame = p.repository:match("^([^/]+)/([^/]+)$")

        local pattern_name = p_name
          and ("^(" .. vim.pesc(p_name) .. ")[%s#/:]*(.*)$")

        local pattern_repo = ("^(" .. vim.pesc(p_repo) .. ")[%s#/:]*(.*)$")
        local rest = nil

        if pattern_name and str:lower():match(pattern_name) then
          local _, m_rest = str:lower():match(pattern_name)
          rest = str:sub(#str - #m_rest + 1)
        elseif str:lower():match(pattern_repo) then
          local _, m_rest = str:lower():match(pattern_repo)
          rest = str:sub(#str - #m_rest + 1)
        end

        if rest and p_owner and p_reponame then
          owner = p_owner
          repo = p_reponame
          forge = p.provider or "github"
          str = vim.trim(rest)
          break
        end
      end
    end
  end

  if not owner then
    local o, r, rest = str:match("^([%w._-]+)/([%w._-]+)[%s#/:]+(.*)$")

    if not o then
      o, r, rest = str:match("^([%w._-]+)/([%w._-]+)@(.*)$")
    end

    if o and r then
      owner = o
      repo = r
      str = vim.trim(rest or "")
    end
  end

  local kind = nil
  local path_pr_id = str:match("^/?pulls?/(%d+)$")

  if path_pr_id then
    kind = "pull_request"
    str = path_pr_id
  end

  if not kind then
    local path_issue_id = str:match("^/?issues?/(%d+)$")

    if path_issue_id then
      kind = "issue"
      str = path_issue_id
    end
  end

  if not kind then
    local path_commit_id = str:match("^/?commit/(%x+)$")

    if path_commit_id then
      kind = "commit"
      str = path_commit_id
    end
  end

  if not kind then
    local k, rest = str:match("^(%a+)[%s#/:]+(.*)$")

    if k then
      local kl = k:lower()

      if
        kl == "pr"
        or kl == "pull"
        or kl == "pulls"
        or kl == "pull_request"
      then
        kind = "pull_request"
        str = vim.trim(rest)
      elseif kl == "issue" or kl == "issues" then
        kind = "issue"
        str = vim.trim(rest)
      elseif kl == "commit" or kl == "sha" then
        kind = "commit"
        str = vim.trim(rest)
      end
    end
  end

  str = str:gsub("^#+", "")
  str = vim.trim(str)
  local id = nil

  if str:match("^%d+$") then
    id = tonumber(str)
  elseif
    str:match("^%x+$")
    and #str >= 7
    and #str <= 40
    and (str:match("%a") or kind == "commit")
  then
    id = str:lower()
    kind = "commit"
  elseif str ~= "" then
    id = str
  end

  if not id then
    return nil
  end

  return {
    id = id,
    kind = kind,
    owner = owner,
    repo = repo,
    repository = owner and repo and (owner .. "/" .. repo) or nil,
    forge = forge,
  }
end

function M.resolve_repository(parsed, context, opts, callback)
  opts = opts or {}
  context = context or {}

  if parsed.owner and parsed.repo then
    local forge = parsed.forge

    if not forge and type(opts.projects) == "table" then
      local target_repo = (parsed.owner .. "/" .. parsed.repo):lower()

      for _, p in ipairs(opts.projects) do
        if
          type(p) == "table"
          and type(p.repository) == "string"
          and p.repository:lower() == target_repo
        then
          forge = p.provider
          break
        end
      end
    end

    callback({
      forge = forge or "github",
      owner = parsed.owner,
      repo = parsed.repo,
      repository = parsed.owner .. "/" .. parsed.repo,
    })

    return
  end

  if context.project and type(context.project) == "table" then
    local p = context.project

    if type(p.repository) == "string" and p.repository ~= "" then
      local owner, repo = p.repository:match("^([^/]+)/([^/]+)$")

      if owner and repo then
        callback({
          forge = p.provider or "github",
          owner = owner,
          repo = repo,
          repository = p.repository,
        })

        return
      end
    end
  end

  if type(context.repository) == "string" and context.repository ~= "" then
    local owner, repo = context.repository:match("^([^/]+)/([^/]+)$")

    if owner and repo then
      callback({
        forge = context.provider or "github",
        owner = owner,
        repo = repo,
        repository = context.repository,
      })

      return
    end
  end

  local search_cwd = context.cwd or vim.fn.getcwd()

  git.detect_repository(search_cwd, function(detected)
    if detected then
      callback(detected)
      return
    end

    local projects = opts.projects

    if type(projects) == "table" and #projects == 1 then
      local single = projects[1]

      if type(single.repository) == "string" then
        local owner, repo = single.repository:match("^([^/]+)/([^/]+)$")

        if owner and repo then
          callback({
            forge = single.provider or "github",
            owner = owner,
            repo = repo,
            repository = single.repository,
          })

          return
        end
      end
    end

    if type(projects) == "table" and #projects > 1 then
      local items = {}

      for _, p in ipairs(projects) do
        if type(p.repository) == "string" and p.repository ~= "" then
          items[#items + 1] = p
        end
      end

      if #items > 0 then
        vim.ui.select(items, {
          prompt = "Select repository for inspection: ",
          format_item = function(item)
            local name = item.name or item.repository
            return ("%s (%s)"):format(name, item.repository)
          end,
        }, function(choice)
          if not choice then
            callback(nil, "inspection cancelled: no repository selected")
            return
          end

          local owner, repo = choice.repository:match("^([^/]+)/([^/]+)$")

          if owner and repo then
            callback({
              forge = choice.provider or "github",
              owner = owner,
              repo = repo,
              repository = choice.repository,
            })
          else
            callback(nil, "invalid repository: " .. choice.repository)
          end
        end)

        return
      end
    end

    vim.ui.input({
      prompt = "Repository (owner/repo): ",
    }, function(input_repo)
      if not input_repo or vim.trim(input_repo) == "" then
        callback(nil, "inspection cancelled: no repository provided")
        return
      end

      local owner, repo = vim.trim(input_repo):match("^([^/]+)/([^/]+)$")

      if owner and repo then
        callback({
          forge = "github",
          owner = owner,
          repo = repo,
          repository = owner .. "/" .. repo,
        })
      else
        callback(nil, "invalid repository format: " .. input_repo)
      end
    end)
  end)
end

function M.resolve_target_url(parsed, repo_info, opts, callback)
  opts = opts or {}

  if parsed.url then
    callback(parsed.url, parsed.kind, parsed.info)
    return
  end

  local forge = repo_info.forge or "github"
  local host = forge == "codeberg" and "codeberg.org" or "github.com"
  local slug = repo_info.owner .. "/" .. repo_info.repo
  local pull_path = forge == "codeberg" and "pulls" or "pull"

  if parsed.kind == "commit" then
    local url = ("https://%s/%s/commit/%s"):format(host, slug, parsed.id)
    callback(url, "commit", { sha = parsed.id })
    return
  end

  if parsed.kind == "pull_request" then
    local url = ("https://%s/%s/%s/%s"):format(host, slug, pull_path, parsed.id)
    callback(url, "pull_request", { number = parsed.id })
    return
  end

  if parsed.kind == "issue" then
    local url = ("https://%s/%s/issues/%s"):format(host, slug, parsed.id)
    callback(url, "issue", { number = parsed.id })
    return
  end

  local provider = forge == "codeberg" and require("oculus.codeberg")
    or require("oculus.github")

  provider.pull_request(slug, parsed.id, opts, function(pr_details, pr_err)
    if pr_details and (pr_details.number or pr_details.html_url) then
      local url = pr_details.html_url
        or ("https://%s/%s/%s/%s"):format(host, slug, pull_path, parsed.id)

      callback(url, "pull_request", pr_details)
      return
    end

    provider.issue(slug, parsed.id, opts, function(issue_details, issue_err)
      if issue_details and (issue_details.number or issue_details.html_url) then
        local url = issue_details.html_url
          or ("https://%s/%s/issues/%s"):format(host, slug, parsed.id)

        callback(url, "issue", issue_details)
        return
      end

      callback(
        nil,
        nil,
        nil,
        ("could not find pull request or issue #%s in %s"):format(
          tostring(parsed.id),
          slug
        )
      )
    end)
  end)
end

function M.inspect_by_id(target_input, opts, context, callback, lifecycle)
  opts = opts or {}
  context = context or {}

  if not target_input or vim.trim(tostring(target_input)) == "" then
    local project = context.project
    local repo_hint = project and (project.name or project.repository)

    local prompt_text = repo_hint
        and ("Inspect in %s (PR #, issue #, commit, or target): "):format(repo_hint)
      or "Inspect (PR #, issue #, commit, or target): "

    vim.ui.input({ prompt = prompt_text }, function(user_input)
      if not user_input or vim.trim(user_input) == "" then
        return
      end

      M.inspect_by_id(user_input, opts, context, callback, lifecycle)
    end)

    return
  end

  local parsed = M.parse(target_input, opts.projects)

  if not parsed then
    local err = ("invalid inspection target '%s'"):format(tostring(target_input))
    vim.notify("Oculus: " .. err, vim.log.levels.WARN)

    if callback then
      callback(nil, nil, nil, err)
    end

    return false, err
  end

  if parsed.url then
    local inspect = require("oculus.inspect")
    return inspect.open(parsed.url, opts, context, lifecycle)
  end

  M.resolve_repository(parsed, context, opts, function(repo_info, repo_err)
    if not repo_info then
      if repo_err then
        vim.notify("Oculus: " .. repo_err, vim.log.levels.WARN)
      end

      if callback then
        callback(nil, nil, nil, repo_err)
      end

      return
    end

    M.resolve_target_url(parsed, repo_info, opts, function(url, kind, details, url_err)
      if not url then
        if url_err then
          vim.notify("Oculus: " .. url_err, vim.log.levels.WARN)
        end

        if callback then
          callback(nil, nil, nil, url_err)
        end

        return
      end

      local inspect = require("oculus.inspect")
      local ok, open_err = inspect.open(url, opts, context, lifecycle)

      if callback then
        callback(url, kind, details, open_err)
      end
    end)
  end)

  return true
end

return M
