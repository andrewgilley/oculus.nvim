local M = {}

function M.parse_commit_url(url)
  if type(url) ~= "string" then
    return nil
  end

  local owner, repo, sha, suffix = url:match(
    "^https?://github%.com/([^/]+)/([^/]+)/commit/([0-9a-fA-F]+)(.*)$"
  )

  local forge = "github"
  local host = "github.com"

  if not owner then
    owner, repo, sha, suffix = url:match(
      "^https?://codeberg%.org/([^/]+)/([^/]+)/commit/([0-9a-fA-F]+)(.*)$"
    )

    forge = "codeberg"
    host = "codeberg.org"
  end

  if not owner or not repo or not sha then
    return nil
  end

  repo = repo:gsub("%.git$", "")

  if
    not owner:match("^[%w][%w._-]*$")
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
    kind = "commit",
    forge = forge,
    host = host,
    owner = owner,
    repo = repo,
    sha = sha:lower(),
    remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
  }
end

function M.parse_pull_request_url(url)
  if type(url) ~= "string" then
    return nil
  end

  local owner, repo, number, suffix = url:match(
    "^https?://github%.com/([^/]+)/([^/]+)/pull/(%d+)(.*)$"
  )

  local forge = "github"
  local host = "github.com"

  if not owner then
    owner, repo, number, suffix = url:match(
      "^https?://codeberg%.org/([^/]+)/([^/]+)/pulls/(%d+)(.*)$"
    )

    forge = "codeberg"
    host = "codeberg.org"
  end

  if
    not owner
    or not repo
    or not number
    or not owner:match("^[%w][%w._-]*$")
    or not repo:match("^[%w._-]+$")
    or repo == "."
    or repo == ".."
    or (suffix ~= "" and not suffix:match("^[/?#]"))
  then
    return nil
  end

  repo = repo:gsub("%.git$", "")

  return {
    kind = "pull_request",
    forge = forge,
    host = host,
    owner = owner,
    repo = repo,
    number = tonumber(number),
    remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
  }
end

function M.parse_issue_url(url)
  if type(url) ~= "string" then
    return nil
  end

  local owner, repo, number, suffix = url:match(
    "^https?://github%.com/([^/]+)/([^/]+)/issues/(%d+)(.*)$"
  )

  local forge = "github"
  local host = "github.com"

  if not owner then
    owner, repo, number, suffix = url:match(
      "^https?://codeberg%.org/([^/]+)/([^/]+)/issues/(%d+)(.*)$"
    )

    forge = "codeberg"
    host = "codeberg.org"
  end

  if
    not owner
    or not repo
    or not number
    or not owner:match("^[%w][%w._-]*$")
    or not repo:match("^[%w._-]+$")
    or repo == "."
    or repo == ".."
    or (suffix ~= "" and not suffix:match("^[/?#]"))
  then
    return nil
  end

  repo = repo:gsub("%.git$", "")

  return {
    kind = "issue",
    forge = forge,
    host = host,
    owner = owner,
    repo = repo,
    number = tonumber(number),
    remote_url = ("https://%s/%s/%s.git"):format(host, owner, repo),
  }
end

function M.parse_target_url(url)
  return M.parse_commit_url(url)
    or M.parse_pull_request_url(url)
    or M.parse_issue_url(url)
end

function M.parse_commit_overview(output)
  if type(output) ~= "string" or output == "" then
    return nil
  end

  local fields = vim.split(output, "\0", { plain = true })

  if #fields < 7 then
    return nil
  end

  return {
    sha = vim.trim(fields[1] or ""),
    parents = vim.split(
      vim.trim(fields[2] or ""),
      "%s+",
      { trimempty = true }
    ),
    author_name = vim.trim(fields[3] or ""),
    author_email = vim.trim(fields[4] or ""),
    authored_at = vim.trim(fields[5] or ""),
    subject = vim.trim(fields[6] or ""),
    body = vim.trim(fields[7] or ""),
  }
end

function M.activity_comment(event)
  if type(event) ~= "table" then
    return nil
  end

  if
    event.type ~= "PullRequestReviewCommentEvent"
    and event.type ~= "CommitCommentEvent"
  then
    return nil
  end

  local comment = event.payload and event.payload.comment
  if not comment then
    return nil
  end

  return {
    body = comment.body,
    path = comment.path,
    line = comment.line or comment.position,
    side = comment.side,
    commit_id = comment.commit_id,
    html_url = comment.html_url,
    created_at = comment.created_at,
    author = comment.user and comment.user.login,
  }
end

function M.activity_context(event)
  if type(event) ~= "table" then
    return nil
  end

  local repo_name = event.repo and event.repo.name
  local comment = M.activity_comment(event)

  return {
    event = event,
    repository = repo_name,
    comment = comment,
    pull_request = event.payload and event.payload.pull_request,
    issue = event.payload and event.payload.issue,
  }
end

function M.first_changed_paths(output)
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

function M.parse_changed_files(output)
  local changes = {}

  for line in (output or ""):gmatch("[^\r\n]+") do
    local fields = vim.split(line, "\t", { plain = true })
    local status = (fields[1] or ""):sub(1, 1)

    if
      (status == "R" or status == "C")
      and fields[2]
      and fields[3]
    then
      changes[#changes + 1] = {
        status = status,
        old_path = fields[2],
        new_path = fields[3],
      }
    elseif status ~= "" and fields[2] then
      changes[#changes + 1] = {
        status = status,
        old_path = fields[2],
        new_path = fields[2],
      }
    end
  end

  return changes
end

function M.parse_hunks(patch)
  local hunks = {}

  for old_start, old_count, new_start, new_count in
    (patch or ""):gmatch(
      "@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@"
    )
  do
    hunks[#hunks + 1] = {
      old_start = tonumber(old_start),
      old_count = old_count == "" and 1 or tonumber(old_count),
      new_start = tonumber(new_start),
      new_count = new_count == "" and 1 or tonumber(new_count),
    }
  end

  return hunks
end

function M.hunk_start(hunk, role)
  return math.max(
    1,
    role == "parent" and hunk.old_start or hunk.new_start
  )
end

function M.focused_hunk_start(hunk)
  local before = hunk.old_count == 0
      and hunk.old_start
    or hunk.old_start - 1

  return math.max(1, before + 1)
end

function M.revision_hunk_index_at_line(session, role, line)
  for index, hunk in ipairs(session.hunks or {}) do
    local start = M.hunk_start(hunk, role)

    local count = role == "parent"
        and hunk.old_count
      or hunk.new_count

    if line >= start
      and line <= start + math.max(1, count) - 1
    then
      return index
    end
  end
end

function M.hunk_index_at_line(session, role, line)
  if not session.focused_chunks then
    return M.revision_hunk_index_at_line(session, role, line)
  end

  for index, hunk in ipairs(session.hunks or {}) do
    local focused_change = session.focused_chunks
      and role == "change"
      and index == session.active_chunk

    local start

    if focused_change then
      start = M.focused_hunk_start(hunk)
    elseif session.focused_chunks then
      start = M.hunk_start(hunk, "parent")
      local active = session.hunks[session.active_chunk]

      if role == "change"
        and active
        and hunk.old_start > active.old_start
      then
        start = start + active.new_count - active.old_count
      end
    else
      start = M.hunk_start(hunk, role)
    end

    local count

    if focused_change then
      count = hunk.new_count
    elseif role == "parent" or index ~= session.active_chunk then
      count = hunk.old_count
    else
      count = hunk.new_count
    end

    if line >= start
      and line <= start + math.max(1, count) - 1
    then
      return index
    end
  end
end

function M.change_lines(hunks, role)
  local lines = {}
  local seen = {}

  for _, hunk in ipairs(hunks or {}) do
    local line = M.hunk_start(hunk, role or "change")

    if not seen[line] then
      seen[line] = true
      lines[#lines + 1] = line
    end
  end

  return lines
end

function M.focused_change_lines(parent_lines, change_lines_value, hunk)
  local lines = {}

  local function append(source, first, last)
    for index = first, last do
      lines[#lines + 1] = source[index]
    end
  end

  local before_count = hunk.old_start - 1
  append(parent_lines, 1, math.min(#parent_lines, before_count))

  local hunk_start_index = hunk.new_start
  local hunk_end_index = hunk.new_start + hunk.new_count - 1
  append(change_lines_value, hunk_start_index, math.min(#change_lines_value, hunk_end_index))

  local after_start = hunk.old_start + hunk.old_count
  append(parent_lines, after_start, #parent_lines)

  return lines
end

function M.parse_revision_pairs(output)
  local pairs = {}

  for line in (output or ""):gmatch("[^\r\n]+") do
    local base, head = line:match("^(%x+)%s+(%x+)")
    if base and head then
      pairs[#pairs + 1] = { base = base, head = head }
    end
  end

  return pairs
end

return M
