local M = {}

local labels = {
  CommitCommentEvent = "Commented on a commit",
  CreateEvent = "Created",
  DeleteEvent = "Deleted",
  ForkEvent = "Forked",
  GollumEvent = "Updated the wiki for",
  IssueCommentEvent = "Commented on an issue in",
  IssuesEvent = "Updated an issue in",
  MemberEvent = "Updated collaborators in",
  PublicEvent = "Made public",
  PullRequestEvent = "Updated a pull request in",
  PullRequestReviewEvent = "Reviewed a pull request in",
  PullRequestReviewCommentEvent = "Commented on a review in",
  PushEvent = "Pushed to",
  ReleaseEvent = "Published a release in",
  WatchEvent = "Starred",
}

local icons = {
  CreateEvent = "+",
  DeleteEvent = "-",
  ForkEvent = "⑂",
  IssueCommentEvent = "◆",
  IssuesEvent = "!",
  PullRequestEvent = "↗",
  PullRequestReviewEvent = "✓",
  PullRequestReviewCommentEvent = "◆",
  PushEvent = "↑",
  ReleaseEvent = "◇",
  WatchEvent = "★",
}

M.event_types = {
  "PushEvent",
  "PullRequestEvent",
  "PullRequestReviewEvent",
  "PullRequestReviewCommentEvent",
  "IssuesEvent",
  "IssueCommentEvent",
  "CommitCommentEvent",
  "CreateEvent",
  "DeleteEvent",
  "ForkEvent",
  "WatchEvent",
  "ReleaseEvent",
  "GollumEvent",
  "MemberEvent",
  "PublicEvent",
}

local type_names = {
  PushEvent = "Pushes",
  PullRequestEvent = "Pull requests",
  PullRequestReviewEvent = "Pull request reviews",
  PullRequestReviewCommentEvent = "Review comments",
  IssuesEvent = "Issues",
  IssueCommentEvent = "Issue comments",
  CommitCommentEvent = "Commit comments",
  CreateEvent = "Branches and tags created",
  DeleteEvent = "Branches and tags deleted",
  ForkEvent = "Forks",
  WatchEvent = "Stars",
  ReleaseEvent = "Releases",
  GollumEvent = "Wiki changes",
  MemberEvent = "Collaborator changes",
  PublicEvent = "Repositories made public",
}

function M.type_label(event_type)
  return type_names[event_type] or event_type:gsub("Event$", "")
end

local function value(root, ...)
  local current = root
  for _, key in ipairs({ ... }) do
    if type(current) ~= "table" then
      return nil
    end
    current = current[key]
  end
  return current
end

local function sentence(event)
  local payload = event.payload or {}
  local repo = value(event, "repo", "name") or "an unknown repository"
  local kind = event.type or "ActivityEvent"

  if kind == "PushEvent" then
    local count = payload.size or #(payload.commits or {})
    if count == 0 then
      return ("Pushed to %s"):format(repo)
    end
    local noun = count == 1 and "commit" or "commits"
    return ("Pushed %d %s to %s"):format(count, noun, repo)
  end

  if kind == "PullRequestEvent" then
    local number = value(payload, "pull_request", "number") or payload.number
    local action = payload.action or "Updated"
    if action == "closed" and value(payload, "pull_request", "merged") then
      action = "Merged"
    end
    return ("%s pull request%s in %s"):format(
      action,
      number and (" #" .. number) or "",
      repo
    )
  end

  if kind == "PullRequestReviewEvent" then
    local number = value(payload, "pull_request", "number")
    return ("Reviewed pull request%s in %s"):format(
      number and (" #" .. number) or "",
      repo
    )
  end

  if kind == "IssueCommentEvent" then
    local number = value(payload, "issue", "number")
    local title = value(payload, "issue", "title")
    return ("Commented on %s%s in %s%s"):format(
      value(payload, "issue", "pull_request") and "pull request" or "issue",
      number and (" #" .. number) or "",
      repo,
      title and (" · " .. title) or ""
    )
  end

  if kind == "IssuesEvent" then
    local number = value(payload, "issue", "number")
    local title = value(payload, "issue", "title")
    return ("%s issue%s in %s%s"):format(
      payload.action or "Updated",
      number and (" #" .. number) or "",
      repo,
      title and (" · " .. title) or ""
    )
  end

  if kind == "CreateEvent" or kind == "DeleteEvent" then
    local target = payload.ref_type or "item"
    local ref = payload.ref and (' "' .. payload.ref .. '"') or ""
    return ("%s %s%s in %s"):format(labels[kind], target, ref, repo)
  end

  if kind == "ReleaseEvent" then
    local tag = value(payload, "release", "tag_name")
    return ("%s%s in %s"):format(labels[kind], tag and (" " .. tag) or "", repo)
  end

  return ("%s %s"):format(labels[kind] or kind:gsub("Event$", ""), repo)
end

local function preview_text(text, limit)
  if type(text) ~= "string" then
    return nil
  end

  local preview = text:gsub("[%c%s]+", " "):gsub("^%s+", ""):gsub("%s+$", "")
  if preview == "" then
    return nil
  end
  return vim.fn.strcharpart(preview, 0, limit or 80)
end

local function quoted(text)
  return '"' .. text .. '"'
end

local function detail(event)
  if event.type == "PushEvent" then
    local commits = value(event, "payload", "commits") or {}
    local message = commits[#commits] and commits[#commits].message
    if not message then
      return nil
    end

    local first_line = message:match("[^\r\n]+")
    local pr_number = first_line
      and first_line:match("^Merge pull request #(%d+)")
    if pr_number then
      local body = message:gsub("^[^\r\n]+[\r\n]*", "")
      local title = body:match("[^\r\n]+")
      if title then
        return ("PR #%s · %s"):format(pr_number, quoted(title))
      end
    end

    return first_line
  end
  if event.type == "PullRequestEvent" then
    local title = preview_text(value(event, "payload", "pull_request", "title"))
    return title and quoted(title) or nil
  end
  if event.type == "PullRequestReviewEvent" then
    local title = preview_text(value(event, "payload", "pull_request", "title"))
    return title and quoted(title) or nil
  end
  if
    event.type == "IssueCommentEvent"
    or event.type == "PullRequestReviewCommentEvent"
    or event.type == "CommitCommentEvent"
  then
    return preview_text(value(event, "payload", "comment", "body"))
  end
  return nil
end

local function comment_url(comment, fallback)
  if type(comment) ~= "table" then
    return fallback
  end
  local url = comment.html_url or fallback
  local body = type(comment.body) == "string" and comment.body or nil
  if not body or body == "" then
    return url
  end

  local target = preview_text(body, 60)
  if not target or target == "" then
    return url
  end

  local fragment, base_url = url:match("#(.+)$"), url:gsub("#.*$", "")
  local anchor = fragment and (fragment .. ":~:text=") or ":~:text="
  local author = value(comment, "user", "login")
  local text_fragment = author
    and (vim.uri_encode(author) .. "," .. vim.uri_encode(target))
    or vim.uri_encode(target)
  return base_url .. "#" .. anchor .. text_fragment
end

local function event_url(event)
  local repo = value(event, "repo", "name")
  if not repo then
    return "https://github.com"
  end

  local base = "https://github.com/" .. repo
  local payload = event.payload or {}
  if event.type == "PullRequestEvent" then
    local number = value(payload, "pull_request", "number") or payload.number
    return number and (base .. "/pull/" .. number) or base
  elseif event.type == "IssueCommentEvent" then
    return comment_url(payload.comment, base)
  elseif event.type == "PullRequestReviewEvent" then
    return value(payload, "review", "html_url")
      or value(payload, "pull_request", "html_url")
      or base
  elseif event.type == "PullRequestReviewCommentEvent" then
    local fallback = value(payload, "pull_request", "html_url") or base
    return comment_url(payload.comment, fallback)
  elseif event.type == "CommitCommentEvent" then
    return comment_url(payload.comment, base)
  elseif event.type == "IssuesEvent" then
    local number = value(payload, "issue", "number")
    return number and (base .. "/issues/" .. number) or base
  elseif event.type == "ReleaseEvent" then
    local tag = value(payload, "release", "tag_name")
    return tag and (base .. "/releases/tag/" .. tag) or (base .. "/releases")
  elseif event.type == "PushEvent" and payload.head then
    return base .. "/commit/" .. payload.head
  end
  return base
end

function M.describe(event)
  return {
    icon = icons[event.type] or "●",
    text = sentence(event),
    detail = detail(event),
    url = event_url(event),
  }
end

function M.filter(events, activity_types)
  if activity_types == nil then
    return events
  end

  local allowed = {}
  for _, event_type in ipairs(activity_types) do
    allowed[event_type] = true
  end

  local filtered = {}
  for _, event in ipairs(events) do
    if allowed[event.type] then
      filtered[#filtered + 1] = event
    end
  end
  return filtered
end

return M
