-- A project's insights: its counts, the languages it is written in, how many
-- commits it has had each week, and who made the most of them.
local github = require("oculus.github")
local codeberg = require("oculus.codeberg")
local M = {}
local bars = { "▁", "▂", "▃", "▄", "▅", "▆", "▇", "█" }

-- 12345 reads as 12,345.
function M.number(value)
  local text = tostring(math.floor(tonumber(value) or 0))
  local sign, digits = text:match("^(-?)(%d+)$")

  if not digits then
    return text
  end

  return sign .. digits:reverse():gsub("(%d%d%d)", "%1,"):reverse():gsub("^,", "")
end

-- One block character per value, scaled to the largest.
function M.sparkline(values)
  local largest = 0

  for _, value in ipairs(values) do
    largest = math.max(largest, value)
  end

  local marks = {}

  for _, value in ipairs(values) do
    local level = largest > 0 and math.floor(value / largest * (#bars - 1) + 0.5) + 1 or 1
    marks[#marks + 1] = bars[level]
  end

  return table.concat(marks)
end

function M.setup(window, insights_view, internal)
  local function date(timestamp)
    return type(timestamp) == "string"
        and timestamp:match("^(%d%d%d%d%-%d%d%-%d%d)")
      or nil
  end

  -- The page's sections as { text, highlight } lines.
  local function sections(insights, width)
    local rows = {}

    local function add(text, group)
      rows[#rows + 1] = { text = text, group = group }
    end

    local function heading(text)
      if #rows > 0 then
        add("")
      end

      add("  " .. text, "OculusSectionTitle")
    end

    local info = insights.info

    if info then
      heading("OVERVIEW")
      local counts = {}

      local function count(value, singular, plural)
        if value then
          counts[#counts + 1] = ("%s %s"):format(M.number(value), value == 1 and singular or plural)
        end
      end

      count(info.stars, "star", "stars")
      count(info.forks, "fork", "forks")
      count(info.watchers, "watcher", "watchers")
      count(info.open_issues, "open issue", "open issues")
      count(info.open_pull_requests, "open pull request", "open pull requests")
      add("  " .. table.concat(counts, " · "), "Identifier")
      local facts = {}

      if info.archived then
        facts[#facts + 1] = "archived"
      end

      facts[#facts + 1] = info.language
      facts[#facts + 1] = info.license

      if info.default_branch then
        facts[#facts + 1] = "default branch " .. info.default_branch
      end

      if date(info.created_at) then
        facts[#facts + 1] = "created " .. date(info.created_at)
      end

      if date(info.pushed_at) then
        facts[#facts + 1] = "last push " .. date(info.pushed_at)
      end

      if #facts > 0 then
        add("  " .. table.concat(facts, " · "), "Comment")
      end
    end

    local languages = insights.languages or {}

    if #languages > 0 then
      heading("LANGUAGES")
      local total = 0

      for _, language in ipairs(languages) do
        total = total + language.bytes
      end

      local shown = {}
      local other = 0

      for index, language in ipairs(languages) do
        if index <= 6 then
          shown[#shown + 1] = language
        else
          other = other + language.bytes
        end
      end

      if other > 0 then
        shown[#shown + 1] = { name = "Other", bytes = other }
      end

      local name_width = 0

      for _, language in ipairs(shown) do
        name_width = math.max(name_width, vim.fn.strdisplaywidth(language.name))
      end

      local bar_width = math.max(10, math.min(30, width - name_width - 14))

      for _, language in ipairs(shown) do
        local share = total > 0 and language.bytes / total or 0
        local filled = math.floor(share * bar_width + 0.5)

        add(("  %s  %s%s  %5.1f%%"):format(
          internal.pad_cell(language.name, name_width),
          string.rep("█", filled),
          string.rep("░", bar_width - filled),
          share * 100
        ))
      end
    end

    if insights.weeks then
      heading("COMMITS PER WEEK, LAST YEAR")
      local weeks = vim.list_slice(insights.weeks, math.max(1, #insights.weeks - (width - 20) + 1))
      local total = 0
      local recent = 0

      for index, value in ipairs(insights.weeks) do
        total = total + value

        if index > #insights.weeks - 4 then
          recent = recent + value
        end
      end

      add("  " .. M.sparkline(weeks), "DiagnosticOk")

      add(("  %s commits in the last year · %s in the last 4 weeks"):format(
        M.number(total),
        M.number(recent)
      ), "Comment")
    elseif insights.weeks_pending then
      heading("COMMITS PER WEEK, LAST YEAR")
      add("  GitHub is still counting commits. Press r to try again.", "Comment")
    end

    local contributors = insights.contributors or {}

    if #contributors > 0 then
      heading("TOP CONTRIBUTORS")
      local login_width = 0
      local count_width = 0

      for _, contributor in ipairs(contributors) do
        login_width = math.max(login_width, vim.fn.strdisplaywidth(contributor.login) + 1)
        count_width = math.max(count_width, #M.number(contributor.contributions))
      end

      for _, contributor in ipairs(contributors) do
        local count = M.number(contributor.contributions)

        add(("  %s  %s%s commit%s"):format(
          internal.pad_cell("@" .. contributor.login, login_width),
          string.rep(" ", count_width - #count),
          count,
          contributor.contributions == 1 and "" or "s"
        ))
      end
    end

    return rows
  end

  function insights_view.render()
    local insights = window.state.project_insights

    if not insights or not internal.is_valid_win(window.state.win) then
      return
    end

    internal.stop_activity_page_loading()
    internal.close_activity_footer()
    window.state.view = "insights"
    window.state.line_targets = {}
    local project = insights.project
    local width = vim.api.nvim_win_get_width(window.state.win) - 2
    local tab_text, tab_ranges = internal.project_tab_line("insights", width)

    local lines = {
      "",
      ("  %s · %s"):format(internal.project_title(project), internal.provider_name(project)),
      tab_text,
      "",
    }

    local groups = {}

    if insights.loading and not insights.info then
      lines[#lines + 1] = "  Loading insights…"
      groups[#lines] = "Comment"
    elseif insights.error then
      lines[#lines + 1] = "  Could not load insights"
      groups[#lines] = "DiagnosticError"
      lines[#lines + 1] = "  " .. insights.error
      groups[#lines] = "Comment"
    else
      for _, row in ipairs(sections(insights, width)) do
        lines[#lines + 1] = internal.trim_to_width(row.text, width)
        groups[#lines] = row.group
      end
    end

    local commands_line = internal.footer(lines, width + 2)
    internal.set_lines(lines)
    internal.paint_footer(commands_line)
    vim.wo[window.state.win].cursorline = false
    internal.paint_project_header(lines[2], tab_ranges)

    for line, group in pairs(groups) do
      internal.highlight(line, 2, -1, group)
    end

    internal.render_sidebar()
  end

  -- Loads every part of the page at once; each part draws as it arrives, and
  -- a part that fails is left out rather than failing the page.
  function insights_view.load(project, force)
    window.state.request_id = window.state.request_id + 1
    local request_id = window.state.request_id
    local key = internal.project_issue_filter_key(project)
    local previous = window.state.project_insights
    local insights = previous and previous.key == key and not force and previous or nil

    insights = {
      key = key,
      project = project,
      loading = true,
      info = insights and insights.info,
      languages = insights and insights.languages,
      contributors = insights and insights.contributors,
      weeks = insights and insights.weeks,
    }

    window.state.project_insights = insights
    insights_view.render()
    local provider = project.provider == "codeberg" and codeberg or github
    local request_opts = vim.tbl_extend("force", window.state.opts, { force = force or false })
    local pending = 0

    local function current()
      return request_id == window.state.request_id
        and window.state.project_insights == insights
        and window.state.view == "insights"
        and internal.is_valid_win(window.state.win)
    end

    local function request(name, run, store)
      if type(provider[name]) ~= "function" then
        return
      end

      pending = pending + 1

      run(provider[name], function(...)
        pending = pending - 1

        if not current() then
          return
        end

        store(...)
        insights.loading = pending > 0
        insights_view.render()
      end)
    end

    request("repository_info", function(call, done)
      call(project.repository, request_opts, done)
    end, function(info, err)
      insights.info = info

      if not info then
        insights.error = err and tostring(err) or "the repository could not be loaded"
      end
    end)

    request("repository_languages", function(call, done)
      call(project.repository, request_opts, done)
    end, function(languages)
      insights.languages = languages
    end)

    request("repository_contributors", function(call, done)
      call(project.repository, vim.tbl_extend("force", request_opts, { per_page = 10 }), done)
    end, function(contributors)
      insights.contributors = contributors
    end)

    request("repository_commit_weeks", function(call, done)
      call(project.repository, request_opts, done)
    end, function(weeks, err)
      insights.weeks = weeks
      insights.weeks_pending = not weeks and tostring(err or ""):find("202", 1, true) ~= nil
    end)
  end

  function insights_view.browser_url()
    local insights = window.state.project_insights

    if not insights then
      return nil
    end

    local project = insights.project

    return project.provider == "codeberg"
        and ("https://codeberg.org/%s/activity"):format(project.repository)
      or ("https://github.com/%s/pulse"):format(project.repository)
  end
end

return M
