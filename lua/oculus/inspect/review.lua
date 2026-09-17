-- Pull request review state for inspections: reviewer verdicts, checks, and
-- inline review threads, including where each thread lands in the inspected
-- files. The forge clients normalize their responses into these shapes:
--
-- review  { author, state, submitted_at }, state is one of "approved",
--         "changes_requested", "commented", "dismissed" or "requested"
-- check   { name, state, url }, state is one of "success", "failure",
--         "pending" or "skipped"
-- thread  { id, path, side ("parent"|"change"), line, commit, outdated,
--         resolved, url, comments = { { author, body, created_at, url } } }
local patch = require("oculus.inspect.patch")
local M = {}

local function comparable_path(path)
  return type(path) == "string"
      and path:gsub("\\", "/"):gsub("^%./", ""):gsub("/+$", "")
    or nil
end

-- The latest verdict per reviewer, in the order reviewers first appeared. A
-- comment never replaces an approval or a change request. A pending review
-- request replaces everything before it, keeping the earlier verdict as
-- previous.
function M.reviewer_verdicts(reviews, requested, pull_request_author)
  local verdicts = {}
  local previous = {}
  local order = {}

  local function set(author, state)
    if not verdicts[author] then
      order[#order + 1] = author
    end

    if state == "requested" then
      if verdicts[author] and verdicts[author] ~= "requested" then
        previous[author] = verdicts[author]
      end
    else
      previous[author] = nil
    end

    verdicts[author] = state
  end

  for _, review in ipairs(reviews or {}) do
    local author = review.author
    local state = review.state
    local current = author and verdicts[author]

    if author
      and state
      and not (state == "commented" and author == pull_request_author)
      and (
        state ~= "commented"
        or not current
        or current == "requested"
      )
    then
      set(author, state)
    end
  end

  for _, reviewer in ipairs(requested or {}) do
    set(reviewer, "requested")
  end

  local result = {}

  for _, author in ipairs(order) do
    result[#result + 1] = {
      author = author,
      state = verdicts[author],
      previous = previous[author],
    }
  end

  return result
end

function M.check_counts(checks)
  local counts = { success = 0, failure = 0, pending = 0, skipped = 0 }
  local failing = {}

  for _, check in ipairs(checks or {}) do
    local state = counts[check.state] and check.state or "skipped"
    counts[state] = counts[state] + 1

    if state == "failure" then
      failing[#failing + 1] = check.name
    end
  end

  return counts, failing
end

local verdict_text = {
  approved = "✓ @%s approved",
  changes_requested = "✗ @%s requested changes",
  commented = "◆ @%s commented",
  dismissed = "– @%s review dismissed",
  requested = "○ @%s review requested",
}

local previous_verdict_text = {
  approved = "previously approved",
  changes_requested = "previously requested changes",
  commented = "previously commented",
  dismissed = "review previously dismissed",
}

local merge_state_text = {
  dirty = "Has conflicts",
  behind = "Behind the base branch",
  blocked = "Blocked by required reviews or checks",
  unstable = "Mergeable, but some checks are failing",
  clean = "Ready to merge",
  has_hooks = "Ready to merge",
}

-- The review sections of the inspect overview, as { label, items } pairs.
function M.overview_sections(overview)
  local review = overview.review

  if type(review) ~= "table" then
    return {}
  end

  if review.loading then
    return { { label = "Reviews", items = { "Loading…" } } }
  end

  if review.error then
    return {
      { label = "Reviews", items = { "Could not load: " .. review.error } },
    }
  end

  local sections = {}
  local reviewer_items = {}

  for _, verdict in ipairs(M.reviewer_verdicts(
    review.reviews,
    review.requested_reviewers,
    overview.author
  )) do
    local text = verdict_text[verdict.state]:format(verdict.author)

    if verdict.previous then
      text = text .. " · " .. previous_verdict_text[verdict.previous]
    end

    reviewer_items[#reviewer_items + 1] = text
  end

  sections[#sections + 1] = {
    label = "Reviews",
    items = #reviewer_items > 0 and reviewer_items or { "No reviews yet." },
  }

  if #(review.checks or {}) > 0 then
    local counts, failing = M.check_counts(review.checks)
    local summary = {}

    for _, entry in ipairs({
      { "failure", "✗ %d failing" },
      { "pending", "● %d pending" },
      { "success", "✓ %d passed" },
      { "skipped", "– %d skipped" },
    }) do
      if counts[entry[1]] > 0 then
        summary[#summary + 1] = entry[2]:format(counts[entry[1]])
      end
    end

    local items = { table.concat(summary, "  ") }

    for index, name in ipairs(failing) do
      if index > 5 then
        items[#items + 1] = ("  and %d more"):format(#failing - 5)
        break
      end

      items[#items + 1] = "✗ " .. tostring(name)
    end

    sections[#sections + 1] = { label = "Checks", items = items }
  end

  if overview.state == "open" and not overview.merged and not overview.draft then
    local text = merge_state_text[review.mergeable_state]

    if not text then
      text = review.mergeable == true and "No conflicts"
        or review.mergeable == false and "Has conflicts"
        or "Not computed yet"
    end

    sections[#sections + 1] = { label = "Merge", items = { text } }
  end

  local threads = review.threads or {}

  if #threads > 0 then
    local open, resolved, outdated = 0, 0, 0

    for _, thread in ipairs(threads) do
      if thread.resolved then
        resolved = resolved + 1
      else
        open = open + 1
      end

      if thread.outdated then
        outdated = outdated + 1
      end
    end

    local parts = { ("%d open"):format(open) }

    if resolved > 0 then
      parts[#parts + 1] = ("%d resolved"):format(resolved)
    end

    if outdated > 0 then
      parts[#parts + 1] = ("%d outdated"):format(outdated)
    end

    local items = { table.concat(parts, ", ") }

    if (review.unplaced or 0) > 0 then
      items[#items + 1] = ("%d on code no longer in the pull request"):format(
        review.unplaced
      )
    end

    sections[#sections + 1] = { label = "Review threads", items = items }
  end

  return sections
end

-- Commit shas ranked oldest first. The pull request's commit list is used when
-- it covers every inspected commit; otherwise the inspection's own order is.
local function commit_ranks(sessions, commits)
  local ranks = {}

  for index, commit in ipairs(commits or {}) do
    local sha = type(commit) == "table" and commit.sha or commit

    if type(sha) == "string" then
      ranks[sha:lower()] = index
    end
  end

  local complete = next(ranks) ~= nil

  for _, session in ipairs(sessions) do
    if session.change_commit
      and not ranks[session.change_commit:lower()]
    then
      complete = false
    end
  end

  if complete then
    return ranks
  end

  ranks = {}

  for _, session in ipairs(sessions) do
    if session.change_commit and session.commit_index then
      ranks[session.change_commit:lower()] = session.commit_index
    end
  end

  return ranks
end

-- Assigns each thread to the inspected file version it was written against.
-- A new-side comment belongs to the latest version of its file at or before
-- its commit, and an old-side comment to the file before its first change.
-- Placed threads are listed in session.review_threads; the rest are counted.
function M.place(sessions, threads, commits, head_sha)
  local ranks = commit_ranks(sessions, commits)
  local unplaced = 0

  for _, session in ipairs(sessions) do
    session.review_threads = {}
  end

  for _, thread in ipairs(threads or {}) do
    local path = comparable_path(thread.path)
    local commit = type(thread.commit) == "string" and thread.commit:lower() or nil
    local thread_rank = commit and ranks[commit]

    if not thread_rank
      and (
        (commit and head_sha and commit == head_sha:lower())
        or thread.outdated == false
      )
    then
      thread_rank = math.huge
    end

    local chosen, chosen_rank

    for _, session in ipairs(thread_rank and sessions or {}) do
      local rank = session.change_commit
        and ranks[session.change_commit:lower()]

      local matches = thread.side == "parent"
          and session.status ~= "A"
          and (
            comparable_path(session.parent_file) == path
            or comparable_path(session.change_file) == path
          )
        or thread.side ~= "parent"
          and session.status ~= "D"
          and comparable_path(session.change_file) == path

      if matches and rank and rank <= thread_rank then
        local better = not chosen
          or (thread.side == "parent" and rank < chosen_rank)
          or (thread.side ~= "parent" and rank > chosen_rank)

        if better then
          chosen = session
          chosen_rank = rank
        end
      end
    end

    if chosen then
      local list = chosen.review_threads
      list[#list + 1] = thread
    else
      unplaced = unplaced + 1
    end
  end

  return unplaced
end

-- The buffer line showing a revision line of an inspected file. The change
-- buffer shows one chunk at a time with every other chunk reverted, so a line
-- inside another chunk is shown at the start of that chunk; its index is
-- returned as the second value.
function M.display_line(session, role, line)
  line = math.max(1, tonumber(line) or 1)
  local ranges = session.excerpt and session.excerpt[role]

  if ranges then
    line = patch.excerpt_line(ranges, line)
  end

  if role == "parent" or not session.focused_chunks or not session.active_chunk then
    return line
  end

  local shift = 0

  for index, hunk in ipairs(patch.session_hunks(session)) do
    local new_count = hunk.new_count or 0

    if new_count > 0
      and line >= hunk.new_start
      and line < hunk.new_start + new_count
    then
      if index == session.active_chunk then
        return line - shift
      end

      return math.max(1, hunk.new_start - shift), index
    end

    local before = new_count > 0
        and hunk.new_start + new_count - 1 < line
      or new_count == 0 and hunk.new_start < line

    if not before then
      break
    end

    if index ~= session.active_chunk then
      shift = shift + new_count - (hunk.old_count or 0)
    end
  end

  return math.max(1, line - shift)
end

local function first_line(text)
  local line = vim.trim(tostring(text or "")):match("^[^\r\n]*") or ""
  return line
end

local function truncate(text, width)
  if vim.fn.strdisplaywidth(text) <= width then
    return text
  end

  return vim.fn.strcharpart(text, 0, math.max(0, width - 1)) .. "…"
end

-- The end-of-line label for the threads on one buffer line.
function M.mark_text(threads, chunk_index)
  local text

  if #threads == 1 then
    local thread = threads[1]
    local comment = thread.comments[1] or {}
    local replies = #thread.comments - 1

    text = ("%s @%s: %s"):format(
      thread.resolved and "✓" or "◆",
      comment.author or "unknown",
      truncate(first_line(comment.body), 60)
    )

    if replies > 0 then
      text = text .. (" (+%d %s)"):format(
        replies,
        replies == 1 and "reply" or "replies"
      )
    end
  else
    text = ("◆ %d review threads"):format(#threads)
  end

  if chunk_index then
    text = text .. (" · chunk %d"):format(chunk_index)
  end

  return text
end

-- Whether every thread on a line is resolved, which dims its label.
function M.all_resolved(threads)
  for _, thread in ipairs(threads) do
    if not thread.resolved then
      return false
    end
  end

  return #threads > 0
end

-- The lines of the thread float, the 0-based header lines to highlight, and
-- the 1-based line each thread starts on.
function M.float_lines(threads)
  local lines = {}
  local headers = {}
  local starts = {}

  for thread_index, thread in ipairs(threads) do
    if thread_index > 1 then
      lines[#lines + 1] = ""
    end

    starts[thread_index] = #lines + 1
    local status = {}

    if thread.resolved then
      status[#status + 1] = "resolved"
    end

    if thread.outdated then
      status[#status + 1] = "outdated"
    end

    for comment_index, comment in ipairs(thread.comments or {}) do
      if comment_index > 1 then
        lines[#lines + 1] = ""
      end

      local header = "@" .. tostring(comment.author or "unknown")

      local date = type(comment.created_at) == "string"
        and comment.created_at:match("^%d%d%d%d%-%d%d%-%d%d")

      if date then
        header = header .. "  " .. date
      end

      if comment_index == 1 and #status > 0 then
        header = header .. "  · " .. table.concat(status, ", ")
      end

      headers[#headers + 1] = #lines
      lines[#lines + 1] = header

      for _, body_line in ipairs(vim.split(
        vim.trim(tostring(comment.body or "")),
        "\n",
        { plain = true }
      )) do
        lines[#lines + 1] = (body_line:gsub("\r$", ""))
      end
    end
  end

  return lines, headers, starts
end

return M
