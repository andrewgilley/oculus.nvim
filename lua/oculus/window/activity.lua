-- The activity feeds behind the lists: the events a feed is built from, how
-- duplicates of one push or pull request are merged, how a feed is paged, and
-- which of a project's issues and pull requests its filters let through.
-- Fetching is left to the forge clients; drawing is left to window.lua.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local M = {}

function M.setup(window, internal)
  local load_project_issues

  local function activity_repository(event)
    local repository = event.repo
        and (event.repo.name or event.repo.full_name)
      or event.repository
        and (event.repository.full_name or event.repository.name)
      or ""

    return tostring(repository):lower()
  end

  local function activity_target_id(payload, target)
    local value = payload[target]

    if type(value) == "table" then
      return value.id or value.number
    end

    return nil
  end

  local function activity_dedupe_key(event)
    local payload = event.payload or {}
    local event_type = event.type or event.event_type or "ActivityEvent"
    local repository = activity_repository(event)

    if event_type == "PushEvent" then
      local before = payload.before
      local head = payload.head

      if type(head) == "string" and head ~= "" then
        return table.concat({ "push", repository, before or "", head }, ":")
      end

      local shas = {}

      for _, commit in ipairs(payload.commits or {}) do
        if type(commit.sha) == "string" and commit.sha ~= "" then
          shas[#shas + 1] = commit.sha
        end
      end

      if #shas > 0 then
        table.sort(shas)
        return table.concat({ "push", repository, table.concat(shas, ",") }, ":")
      end
    elseif event_type == "PullRequestEvent" then
      local pull_request = payload.pull_request or {}
      local number = pull_request.number or payload.number

      if number then
        local merged = payload.action == "merged"
          or (payload.action == "closed" and (
            pull_request.merged == true
            or pull_request.merged_at ~= nil
            or pull_request.merged_by ~= nil
          ))

        local action = merged and "merged" or payload.action or "updated"

        return table.concat({
          "pr",
          repository,
          number,
          action,
          merged and "" or event.created_at or "",
        }, ":")
      end
    elseif event_type == "IssuesEvent" then
      local number = activity_target_id(payload, "issue") or payload.number

      if number then
        return table.concat({
          "issue",
          repository,
          number,
          payload.action or "updated",
          event.created_at or "",
        }, ":")
      end
    end

    for _, target in ipairs({ "comment", "review", "release", "forkee" }) do
      local id = activity_target_id(payload, target)

      if id then
        return table.concat({ event_type, repository, target, id }, ":")
      end
    end

    if event_type == "CreateEvent" or event_type == "DeleteEvent" then
      local ref = payload.ref

      if ref then
        return table.concat({
          event_type,
          repository,
          payload.ref_type or "ref",
          ref,
          event.created_at or "",
        }, ":")
      end
    end

    if event.id ~= nil then
      return table.concat({ event_type, repository, event.id }, ":")
    end

    local url = event.url or event.group_url

    if type(url) == "string" and url ~= "" then
      return table.concat({
        event_type,
        repository,
        url,
        event.created_at or "",
      }, ":")
    end

    return table.concat({ event_type, repository, tostring(event) }, ":")
  end

  local function merge_missing_activity_values(current, duplicate)
    if type(current) ~= "table" or type(duplicate) ~= "table" then
      return
    end

    for key, value in pairs(duplicate) do
      local existing = current[key]

      if existing == nil or existing == "" then
        current[key] = vim.deepcopy(value)
      elseif type(existing) == "table" and type(value) == "table" then
        if vim.islist(existing) and #existing == 0 and #value > 0 then
          current[key] = vim.deepcopy(value)
        elseif not vim.islist(existing) and not vim.islist(value) then
          merge_missing_activity_values(existing, value)
        end
      end
    end
  end

  local function deduplicate_activity(events)
    local result = {}
    local seen = {}

    for _, event in ipairs(events or {}) do
      local key = activity_dedupe_key(event)
      local existing = seen[key]

      if existing then
        merge_missing_activity_values(existing, event)
      else
        result[#result + 1] = event
        seen[key] = event
      end
    end

    return result
  end

  window._activity_dedupe_key = activity_dedupe_key
  window._deduplicate_activity = deduplicate_activity

  local function activity_page(events, page, page_size)
    local result = {}
    local first = (page - 1) * page_size + 1
    local last = math.min(#events, first + page_size - 1)

    for index = first, last do
      result[#result + 1] = events[index]
    end

    return result
  end

  window._activity_page = activity_page

  local function project_issue_allowed(event, project, kind)
    local filters = internal.project_issue_filters_for(project, kind)
    local issue = event.payload and event.payload.issue or {}

    local state = issue.state
      or (event.payload and event.payload.action == "closed" and "closed")
      or "open"

    if filters.state ~= "all" and filters.state ~= state then
      return false
    end

    local assigned = issue.assignee ~= nil
      or (type(issue.assignees) == "table" and #issue.assignees > 0)

    if filters.assignment == "assigned" and not assigned then
      return false
    end

    if filters.assignment == "unassigned" and assigned then
      return false
    end

    return true
  end

  local function filter_project_issues(events, project, kind)
    local filtered = {}

    for _, event in ipairs(events or {}) do
      -- Discussions have no filters.
      if (kind == "discussions" and event.type == "DiscussionEvent")
        or (event.type == "IssuesEvent" and project_issue_allowed(event, project, kind))
      then
        filtered[#filtered + 1] = event
      end
    end

    return deduplicate_activity(filtered)
  end

  window._filter_project_issues = filter_project_issues

  local function add_project_issue(feed, event)
    local issue = event.payload and event.payload.issue or {}

    local key = issue.number and tostring(issue.number)
      or event.id and tostring(event.id)

    if key and feed.seen[key] then
      return false
    end

    feed.events[#feed.events + 1] = event

    if key then
      feed.seen[key] = true
    end

    return true
  end

  -- Loads the project's issues, or its pull requests or discussions when kind
  -- is "pulls" or "discussions". Without a kind, the list already shown keeps
  -- its kind.
  load_project_issues = function(project, force, page, kind)
    local previous_page = window.state.activity_page or 1

    kind = kind
      or window.state.view == "activity"
        and window.state.activity_issue_page
        and window.state.activity_issue_kind
      or "issues"

    local preserve_activity_page = page ~= nil
      and window.state.view == "activity"
      and window.state.activity_issue_page
      and window.state.activity_issue_kind == kind
      and window.state.activity_loaded
      and internal.is_valid_buf(window.state.buf)

    window.state.view = "activity"
    window.state.activity_scope = "project"
    window.state.activity_project = project
    window.state.activity_issue_page = true
    window.state.activity_issue_kind = kind
    window.state.activity_milestone = nil
    window.state.activity_saved = false
    window.state.activity_work = nil
    window.state.activity_commit_page = false
    window.state.contributor = nil

    if page == nil then
      window.state.activity_loaded_pages = 1
    end

    local requested_page = math.max(1, page or 1)
    window.state.activity_page = requested_page

    window.state.activity_page_size = math.max(
      1,
      math.floor(tonumber(window.state.opts.results_limit) or 8)
    )

    window.state.request_id = window.state.request_id + 1
    local request_id = window.state.request_id

    if preserve_activity_page then
      window.state.activity_error = nil
      internal.start_activity_page_loading()
    else
      internal.render_loading({
        kind = "project",
        project = project,
        issues = true,
        issue_kind = kind,
      })
    end

    local provider = project.provider == "codeberg" and codeberg or github

    local request = kind == "pulls" and provider.repository_pulls
      or kind == "discussions" and provider.repository_discussions
      or provider.repository_issues

    if type(request) ~= "function" then
      if kind == "discussions" then
        window.state.activity_page = 1
        window.state.activity_loaded_pages = 1
        window.state.activity_source_events = {}
        window.state.activity_has_past = false

        internal.render_activity(
          {},
          false,
          internal.provider_name(project) .. " projects have no discussions.",
          { issue_page = true }
        )

        return
      end

      internal.render_error(kind == "pulls"
          and "this provider does not support project pull requests"
        or "this provider does not support project issues")

      return
    end

    local filters = internal.project_issue_filters_for(project, kind)

    local request_opts = vim.tbl_extend(
      "force",
      window.state.opts,
      { force = force or false }
    )

    request_opts.per_page = project.provider == "codeberg" and 50 or 100
    request_opts.issue_state = filters.state

    local feed_key = table.concat({
      kind,
      internal.project_issue_filter_key(project, kind),
      filters.state,
      filters.assignment,
    }, ":")

    local feed = window.state.project_issue_feed

    if force or not feed or feed.key ~= feed_key then
      feed = {
        key = feed_key,
        events = {},
        seen = {},
        next_page = 1,
        complete = false,
        cached = true,
        notice = nil,
      }

      window.state.project_issue_feed = feed
    end

    local required_events = requested_page * window.state.activity_page_size
    local max_source_pages = 10

    local function render_issue_results()
      local filtered = filter_project_issues(feed.events, project, kind)

      local first_event =
        (requested_page - 1) * window.state.activity_page_size + 1

      if requested_page > 1 and #filtered < first_event then
        window.state.activity_page = math.max(1, previous_page)
      else
        window.state.activity_page = requested_page
      end

      window.state.activity_source_events = filtered

      window.state.activity_loaded_pages = math.max(
        window.state.activity_loaded_pages or 1,
        window.state.activity_page
      )

      local page_end = window.state.activity_page * window.state.activity_page_size
      window.state.activity_has_past = #filtered > page_end or not feed.complete

      internal.render_activity(
        activity_page(
          filtered,
          window.state.activity_page,
          window.state.activity_page_size
        ),
        feed.cached,
        feed.notice,
        { issue_page = true }
      )
    end

    local function ensure_issue_page()
      local filtered = filter_project_issues(feed.events, project, kind)

      if #filtered >= required_events or feed.complete then
        render_issue_results()
        return
      end

      if feed.next_page > max_source_pages then
        feed.complete = true
        render_issue_results()
        return
      end

      local source_page = feed.next_page
      request_opts.page = source_page

      request(project.repository, request_opts, function(
        events,
        err,
        cached,
        complete,
        notice
      )
        if request_id ~= window.state.request_id
          or window.state.view ~= "activity"
          or not window.state.activity_issue_page
          or window.state.activity_issue_kind ~= kind
          or window.state.activity_project ~= project
          or not internal.is_valid_win(window.state.win)
        then
          return
        end

        if err then
          internal.render_error(err)
          return
        end

        local source = events or {}

        for _, event in ipairs(source) do
          add_project_issue(feed, event)
        end

        table.sort(feed.events, function(left, right)
          return tostring(left.created_at or "")
            > tostring(right.created_at or "")
        end)

        feed.next_page = source_page + 1
        feed.cached = feed.cached and cached == true
        feed.notice = feed.notice or notice

        if complete == true or (complete == nil and #source == 0) then
          feed.complete = true
        end

        ensure_issue_page()
      end)
    end

    ensure_issue_page()
  end

  return {
    dedupe_key = activity_dedupe_key,
    deduplicate = deduplicate_activity,
    page = activity_page,
    add_project_issue = add_project_issue,
    load_project_issues = load_project_issues,
  }
end

return M
