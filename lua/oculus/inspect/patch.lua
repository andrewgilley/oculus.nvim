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

  local comment = event.payload and event.payload.comment or nil

  if type(comment) ~= "table" then
    return nil
  end

  local body = type(comment.body) == "string"
      and vim.trim(comment.body)
    or ""

  local path = type(comment.path) == "string"
      and comment.path
    or nil

  local side = comment.side == "LEFT" and "parent" or "change"

  local line = side == "parent"
      and (
        tonumber(comment.original_start_line)
        or tonumber(comment.original_line)
      )
    or (
      tonumber(comment.start_line)
      or tonumber(comment.line)
      or tonumber(comment.original_line)
    )

  if body == "" or not path or path == "" or not line then
    return nil
  end

  return {
    body = body,
    path = path:gsub("\\", "/"),
    line = math.max(1, line),
    side = side,
    commit = side == "parent"
        and (comment.original_commit_id or comment.commit_id)
      or comment.commit_id,
  }
end

function M.activity_context(event)
  local comment = M.activity_comment(event)

  if comment then
    return comment
  end

  if type(event) == "table"
    and event.type == "PushEvent"
    and type(event.oculus_local) == "table"
  then
    return {
      local_commit = {
        forge = event.oculus_local.forge,
        pushed = event.oculus_local.pushed,
      },
    }
  end

  if type(event) ~= "table"
    or (
      event.type ~= "IssuesEvent"
      and event.type ~= "IssueCommentEvent"
    )
  then
    return nil
  end

  local payload = event.payload or {}
  local issue = payload.issue

  if type(issue) ~= "table" or issue.pull_request then
    return nil
  end

  local issue_body = type(issue.body) == "string" and issue.body or nil

  local comment_body = type(payload.comment) == "table"
      and type(payload.comment.body) == "string"
      and payload.comment.body
    or nil

  return {
    issue = {
      number = issue.number,
      title = issue.title,
      body = issue_body,
      comment = comment_body,
      html_url = issue.html_url,
      created_at = issue.created_at,
    },
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

function M.session_hunks(session)
  if not session then
    return {}
  end

  if session.hunks then
    return session.hunks
  end

  if session.patch and session.patch ~= "" then
    session.hunks = M.parse_hunks(session.patch)
  else
    session.hunks = {}
  end

  return session.hunks
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
  local hunks = M.session_hunks(session)

  for index, hunk in ipairs(hunks) do
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
  local hunks = M.session_hunks(session)

  if not session.focused_chunks then
    return M.revision_hunk_index_at_line(session, role, line)
  end

  for index, hunk in ipairs(hunks) do
    local focused_change = session.focused_chunks
      and role == "change"
      and index == session.active_chunk

    local start

    if focused_change then
      start = M.focused_hunk_start(hunk)
    elseif session.focused_chunks then
      start = M.hunk_start(hunk, "parent")
      local active = hunks[session.active_chunk]

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
  if not hunk then
    return vim.deepcopy(parent_lines or { "" }), 1
  end

  parent_lines = parent_lines or { "" }
  change_lines_value = change_lines_value or { "" }
  local parent_count = #parent_lines

  if parent_count == 1
    and parent_lines[1] == ""
    and hunk.old_start == 0
    and hunk.old_count == 0
  then
    parent_count = 0
  end

  local before_count = hunk.old_count == 0
      and hunk.old_start
    or hunk.old_start - 1

  before_count = math.min(math.max(0, before_count), parent_count)
  local result = {}

  local function append(source, first, last)
    for index = math.max(1, first), math.min(#source, last) do
      result[#result + 1] = source[index]
    end
  end

  append(parent_lines, 1, before_count)

  append(
    change_lines_value,
    hunk.new_start,
    hunk.new_start + hunk.new_count - 1
  )

  append(
    parent_lines,
    before_count + hunk.old_count + 1,
    parent_count
  )

  return #result > 0 and result or { "" }, math.max(1, before_count + 1)
end

function M.excerpt_marker(hidden, indent, commentstring)
  local text = ("⋯ %d unchanged lines ⋯"):format(hidden)
  local left, right

  if type(commentstring) == "string" then
    left, right = commentstring:match("^(.-)%%s(.-)$")
  end

  if left then
    left = vim.trim(left)
    right = vim.trim(right)

    text = (left ~= "" and (left .. " ") or "")
      .. text
      .. (right ~= "" and (" " .. right) or "")
  end

  return (indent or "") .. text
end

local function excerpt_line_count(lines, hunks, other_lines, other_key)
  local count = #lines

  if count ~= 1 or lines[1] ~= "" then
    return count
  end

  local own_key = other_key == "new_count" and "old_count" or "new_count"
  local own_total = 0
  local other_total = 0

  for _, hunk in ipairs(hunks) do
    own_total = own_total + (hunk[own_key] or 0)
    other_total = other_total + (hunk[other_key] or 0)
  end

  -- An empty side is loaded as a single blank line; it holds no source lines
  -- when the other side's unchanged lines are fully consumed by the hunks.
  if #other_lines - other_total == 0 and own_total == 0 then
    return 0
  end

  return count
end

-- Trims both sides of a file to the changed lines plus `context` unchanged
-- lines around each hunk. Hidden runs become one marker line on each side, so
-- both excerpts keep the same unchanged-line alignment as the full files.
function M.excerpt(parent_lines, change_lines, hunks, context, options)
  options = options or {}
  parent_lines = parent_lines or { "" }
  change_lines = change_lines or { "" }
  context = math.max(0, tonumber(context) or 0)

  if type(hunks) ~= "table" or #hunks == 0 then
    return nil
  end

  local parent_count = excerpt_line_count(
    parent_lines,
    hunks,
    change_lines,
    "new_count"
  )

  local change_count = excerpt_line_count(
    change_lines,
    hunks,
    parent_lines,
    "old_count"
  )

  local result = {
    parent_lines = {},
    change_lines = {},
    hunks = {},
    parent_ranges = {},
    change_ranges = {},
    hidden = 0,
    parent_count = parent_count,
    change_count = change_count,
  }

  local function track(ranges, source, excerpt, count)
    if count > 0 then
      ranges[#ranges + 1] = {
        source = source,
        excerpt = excerpt,
        count = count,
      }
    end
  end

  local function copy(target, ranges, source_lines, first, count)
    track(ranges, first, #target + 1, count)

    for index = first, first + count - 1 do
      target[#target + 1] = source_lines[index]
    end
  end

  local function keep(parent_first, change_first, count)
    copy(
      result.parent_lines,
      result.parent_ranges,
      parent_lines,
      parent_first,
      count
    )

    copy(
      result.change_lines,
      result.change_ranges,
      change_lines,
      change_first,
      count
    )
  end

  local function unchanged(parent_first, change_first, count, leading, trailing)
    if count <= 0 then
      return
    end

    local head = leading and 0 or context
    local tail = trailing and 0 or context
    local hidden = count - head - tail

    if hidden <= 1 then
      keep(parent_first, change_first, count)
      return
    end

    keep(parent_first, change_first, head)
    local indent = (parent_lines[parent_first + head] or ""):match("^%s*")

    local marker = M.excerpt_marker(
      hidden,
      indent,
      options.commentstring
    )

    result.parent_lines[#result.parent_lines + 1] = marker
    result.change_lines[#result.change_lines + 1] = marker
    result.hidden = result.hidden + hidden

    keep(
      parent_first + count - tail,
      change_first + count - tail,
      tail
    )
  end

  local parent_next = 1
  local change_next = 1

  for index, hunk in ipairs(hunks) do
    local old_count = hunk.old_count or 0
    local new_count = hunk.new_count or 0

    local parent_before = old_count == 0
        and hunk.old_start
      or hunk.old_start - 1

    local change_before = new_count == 0
        and hunk.new_start
      or hunk.new_start - 1

    local run = parent_before - parent_next + 1

    if run < 0 or run ~= change_before - change_next + 1 then
      return nil
    end

    unchanged(parent_next, change_next, run, index == 1, false)

    local remapped = {
      old_start = old_count == 0
          and #result.parent_lines
        or #result.parent_lines + 1,
      old_count = old_count,
      new_start = new_count == 0
          and #result.change_lines
        or #result.change_lines + 1,
      new_count = new_count,
      source_old_start = hunk.old_start,
      source_new_start = hunk.new_start,
    }

    copy(
      result.parent_lines,
      result.parent_ranges,
      parent_lines,
      hunk.old_start,
      old_count
    )

    copy(
      result.change_lines,
      result.change_ranges,
      change_lines,
      hunk.new_start,
      new_count
    )

    result.hunks[index] = remapped
    parent_next = parent_before + old_count + 1
    change_next = change_before + new_count + 1
  end

  local trailing = parent_count - parent_next + 1

  if trailing < 0 or trailing ~= change_count - change_next + 1 then
    return nil
  end

  unchanged(parent_next, change_next, trailing, false, true)

  if #result.parent_lines == 0 then
    result.parent_lines = { "" }
  end

  if #result.change_lines == 0 then
    result.change_lines = { "" }
  end

  return result
end

-- Maps a source file line onto an excerpt built by M.excerpt. Hidden lines
-- resolve to the marker line that stands in for them.
function M.excerpt_line(ranges, line)
  if type(ranges) ~= "table" or #ranges == 0 or not line then
    return line
  end

  for _, range in ipairs(ranges) do
    if line < range.source then
      return math.max(1, range.excerpt - 1)
    end

    if line < range.source + range.count then
      return range.excerpt + line - range.source
    end
  end

  local last = ranges[#ranges]
  return last.excerpt + last.count
end

-- The inverse of M.excerpt_line: maps an excerpt line back onto the source
-- file. A marker line stands for the hidden run it replaces, so it returns
-- that run's first and last source lines.
function M.source_line(ranges, line, count)
  if type(ranges) ~= "table" or #ranges == 0 or not line then
    return line, line
  end

  local next_source = 1

  for _, range in ipairs(ranges) do
    if line < range.excerpt then
      return next_source, range.source - 1
    end

    if line < range.excerpt + range.count then
      local source = range.source + line - range.excerpt
      return source, source
    end

    next_source = range.source + range.count
  end

  return next_source, math.max(next_source, count or next_source)
end

function M.parse_revision_pairs(output)
  local pairs = {}

  for line in (output or ""):gmatch("[^\r\n]+") do
    local fields = vim.split(line, "%s+", { trimempty = true })

    if fields[1] and fields[2] then
      pairs[#pairs + 1] = {
        commit = fields[1],
        parent = fields[2],
      }
    end
  end

  return pairs
end

return M
