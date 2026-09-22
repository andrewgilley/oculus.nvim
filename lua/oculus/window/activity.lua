-- The activity feeds behind the lists: the events a feed is built from, how
-- duplicates of one push or pull request are merged, how a feed is paged, and
-- which of a project's events and issues its filters let through. Fetching is
-- left to the forge clients; drawing is left to window.lua.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local M = {}

function M.setup(window, internal)
  local load_project_activity
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

  local function project_event_allowed(event, project)
    local enabled = {}

    for _, category in ipairs(internal.project_activity_types_for(project) or {}) do
      enabled[category] = true
    end

    local payload = event.payload or {}
    local event_type = event.type or event.event_type

    if event_type == "PushEvent" then
      return enabled.push == true
    end

    if event_type == "PullRequestEvent" then
      local pull_request = payload.pull_request or {}

      local merged = pull_request.merged == true
        or pull_request.merged_at ~= nil
        or pull_request.merged_by ~= nil

      return enabled.merged_pull_request == true
        and (payload.action == "merged"
          or (payload.action == "closed" and merged))
    end

    if event_type == "IssuesEvent" then
      return enabled.assigned_issue == true
        and payload.action == "assigned"
    end

    return false
  end

  local function filter_project_events(events, project)
    local result = {}

    for _, event in ipairs(events or {}) do
      local event_repository = event.repo
          and (event.repo.name or event.repo.full_name)
        or event.repository
          and (event.repository.full_name or event.repository.name)
        or nil

      local repository_matches = type(event_repository) ~= "string"
        or event_repository == ""
        or event_repository:lower() == project.repository:lower()

      if repository_matches
        and project_event_allowed(event, project)
      then
        result[#result + 1] = event
      end
    end

    return deduplicate_activity(result)
  end

  window._filter_project_events = filter_project_events

  local function add_project_feed_event(feed, event)
    local payload = event.payload or {}

    if event.type == "PushEvent" then
      local shas = {}

      for _, commit in ipairs(payload.commits or {}) do
        if type(commit.sha) == "string" and commit.sha ~= "" then
          shas[#shas + 1] = commit.sha
        end
      end

      if #shas == 0 and type(payload.head) == "string" then
        shas[1] = payload.head
      end

      if #shas > 0 then
        for _, sha in ipairs(shas) do
          if feed.seen_commits[sha]
            and (event.oculus_local or not feed.local_commits[sha])
          then
            return false
          end
        end

        -- The forge has now reported a commit that was shown from the local
        -- clone, so its version replaces the local one.
        local replaced = {}

        for _, sha in ipairs(shas) do
          if not event.oculus_local and feed.local_commits[sha] then
            replaced[feed.local_commits[sha]] = true
            feed.local_commits[sha] = nil
          end

          feed.seen_commits[sha] = true
        end

        if next(replaced) then
          feed.events = vim.tbl_filter(function(candidate)
            return not replaced[candidate]
          end, feed.events)
        end

        if event.oculus_local then
          for _, sha in ipairs(shas) do
            feed.local_commits[sha] = event
          end
        end
      end
    elseif event.type == "PullRequestEvent" then
      local pull_request = payload.pull_request or {}
      local number = pull_request.number or payload.number

      local merged = payload.action == "merged"
        or (payload.action == "closed" and (
          pull_request.merged == true
          or pull_request.merged_at ~= nil
          or pull_request.merged_by ~= nil
        ))

      if number and merged then
        local key = tostring(number)

        if feed.seen_pull_requests[key] then
          return false
        end

        feed.seen_pull_requests[key] = true
      end
    end

    local event_key = event.id and tostring(event.id) or nil

    if event_key and feed.seen[event_key] then
      return false
    end

    feed.events[#feed.events + 1] = event

    if event_key then
      feed.seen[event_key] = true
    end

    return true
  end

  window._add_project_feed_event = add_project_feed_event

  load_project_activity = function(project, force, page)
    local previous_page = window.state.activity_page or 1

    local preserve_activity_page = page ~= nil
      and window.state.view == "activity"
      and window.state.activity_loaded
      and internal.is_valid_buf(window.state.buf)

    window.state.view = "activity"
    window.state.activity_scope = "project"
    window.state.activity_project = project
    window.state.activity_issue_page = false
    window.state.activity_milestone = nil
    window.state.activity_saved = false
    window.state.activity_work = nil
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
      internal.render_loading({ kind = "project", project = project })
    end

    local provider = project.provider == "codeberg" and codeberg or github

    local request_opts = vim.tbl_extend(
      "force",
      window.state.opts,
      { force = force or false }
    )

    request_opts.per_page = project.provider == "codeberg"
        and math.min(50, math.max(16, window.state.activity_page_size * 2))
      or 100

    request_opts.path = project.path
    local activity_types = vim.deepcopy(internal.project_activity_types_for(project) or {})
    table.sort(activity_types)

    local feed_key = table.concat({
      project.provider == "codeberg" and "codeberg" or "github",
      project.repository:lower(),
      project.path or "",
      table.concat(activity_types, ","),
    }, ":")

    local feed = window.state.project_activity_feed

    if force or not feed or feed.key ~= feed_key then
      feed = {
        key = feed_key,
        events = {},
        seen = {},
        seen_commits = {},
        seen_pull_requests = {},
        local_commits = {},
        local_loaded = not vim.tbl_contains(activity_types, "push"),
        next_page = 1,
        using_updates = (project.path ~= nil or project.provider == "codeberg")
          and type(provider.repository_updates) == "function",
        complete = #activity_types == 0,
        cached = true,
        notice = nil,
      }

      window.state.project_activity_feed = feed
    end

    local request_pending = false
    local local_activity = require("oculus.local_activity")

    local function remote_project_event_count()
      local remote = vim.tbl_filter(function(event)
        return not event.oculus_local
      end, feed.events)

      return #filter_project_events(remote, project)
    end

    local required_events = requested_page * window.state.activity_page_size
    local max_source_pages = 10
    request_opts.activity_types = activity_types

    local function use_repository_updates()
      if feed.using_updates
        or type(provider.repository_updates) ~= "function"
      then
        return false
      end

      local useful = false

      for _, category in ipairs(activity_types) do
        if category == "push" or category == "merged_pull_request" then
          useful = true
          break
        end
      end

      if not useful then
        return false
      end

      feed.using_updates = true
      feed.next_page = 1
      feed.complete = false
      return true
    end

    local function render_project_results()
      local_activity.prune(feed)
      local filtered = filter_project_events(feed.events, project)

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

      local results = activity_page(
        filtered,
        window.state.activity_page,
        window.state.activity_page_size
      )

      internal.render_activity(results, feed.cached, feed.notice)

      provider.enrich_pull_requests(results, request_opts, function(with_prs)
        if request_id ~= window.state.request_id
          or window.state.view ~= "activity"
          or window.state.activity_project ~= project
        then
          return
        end

        internal.render_activity(with_prs, feed.cached, feed.notice)

        provider.enrich_pushes(with_prs, request_opts, function(enriched)
          if request_id ~= window.state.request_id
            or window.state.view ~= "activity"
            or window.state.activity_project ~= project
          then
            return
          end

          internal.render_activity(enriched, feed.cached, feed.notice)
        end)
      end)
    end

    local function ensure_project_page()
      local_activity.prune(feed)
      local filtered = filter_project_events(feed.events, project)

      -- Local commits alone never satisfy a page: the forge's first page decides
      -- which of them are still missing from its feed.
      if feed.complete
        or (feed.remote_loaded and #filtered >= required_events)
      then
        render_project_results()
        return
      end

      if feed.next_page > max_source_pages then
        if use_repository_updates() then
          ensure_project_page()
        else
          feed.complete = true
          render_project_results()
        end

        return
      end

      local source_page = feed.next_page
      request_opts.page = source_page

      local request = feed.using_updates
          and provider.repository_updates
        or provider.repository_events

      request_pending = true

      request(project.repository, request_opts, function(
        events,
        err,
        cached,
        notice
      )
        request_pending = false

        if request_id ~= window.state.request_id
          or window.state.view ~= "activity"
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
        local allowed_before = remote_project_event_count()
        local added = 0

        for _, event in ipairs(source) do
          if add_project_feed_event(feed, event) then
            added = added + 1
          end
        end

        local allowed_added = remote_project_event_count()
          - allowed_before

        table.sort(feed.events, function(left, right)
          return tostring(left.created_at or "")
            > tostring(right.created_at or "")
        end)

        feed.next_page = source_page + 1
        feed.remote_loaded = true
        feed.cached = feed.cached and cached == true
        feed.notice = feed.notice or notice

        if #source == 0 or added == 0 or allowed_added == 0 then
          if not use_repository_updates() then
            feed.complete = true
          end
        end

        ensure_project_page()
      end)
    end

    if type(provider.repository_events) ~= "function" then
      internal.render_error("this provider does not support project activity")
      return
    end

    if not feed.local_loaded then
      feed.local_loaded = true

      local_activity.commits(project, window.state.opts, function(local_events)
        if window.state.project_activity_feed ~= feed or #local_events == 0 then
          return
        end

        for _, event in ipairs(local_events) do
          add_project_feed_event(feed, event)
        end

        table.sort(feed.events, function(left, right)
          return tostring(left.created_at or "")
            > tostring(right.created_at or "")
        end)

        -- A pending forge request renders once it returns; otherwise show the
        -- local commits now.
        if request_id == window.state.request_id
          and window.state.view == "activity"
          and window.state.activity_project == project
          and internal.is_valid_win(window.state.win)
          and not request_pending
        then
          ensure_project_page()
        end
      end)
    end

    ensure_project_page()
  end

  local function project_issue_allowed(event, project)
    local filters = internal.project_issue_filters_for(project)
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

  local function filter_project_issues(events, project)
    local filtered = {}

    for _, event in ipairs(events or {}) do
      if event.type == "IssuesEvent"
        and project_issue_allowed(event, project)
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

  load_project_issues = function(project, force, page)
    local previous_page = window.state.activity_page or 1

    local preserve_activity_page = page ~= nil
      and window.state.view == "activity"
      and window.state.activity_issue_page
      and window.state.activity_loaded
      and internal.is_valid_buf(window.state.buf)

    window.state.view = "activity"
    window.state.activity_scope = "project"
    window.state.activity_project = project
    window.state.activity_issue_page = true
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
      })
    end

    local provider = project.provider == "codeberg" and codeberg or github

    if type(provider.repository_issues) ~= "function" then
      internal.render_error("this provider does not support project issues")
      return
    end

    local filters = internal.project_issue_filters_for(project)

    local request_opts = vim.tbl_extend(
      "force",
      window.state.opts,
      { force = force or false }
    )

    request_opts.per_page = project.provider == "codeberg" and 50 or 100
    request_opts.issue_state = filters.state

    local feed_key = table.concat({
      internal.project_issue_filter_key(project),
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
      }

      window.state.project_issue_feed = feed
    end

    local required_events = requested_page * window.state.activity_page_size
    local max_source_pages = 10

    local function render_issue_results()
      local filtered = filter_project_issues(feed.events, project)

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
        nil,
        { issue_page = true }
      )
    end

    local function ensure_issue_page()
      local filtered = filter_project_issues(feed.events, project)

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

      provider.repository_issues(project.repository, request_opts, function(
        events,
        err,
        cached,
        complete
      )
        if request_id ~= window.state.request_id
          or window.state.view ~= "activity"
          or not window.state.activity_issue_page
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
    load_project_activity = load_project_activity,
    load_project_issues = load_project_issues,
  }
end

return M
