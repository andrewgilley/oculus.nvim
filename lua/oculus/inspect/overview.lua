local M = {}

function M.inspection_overview(info)
  local overview = vim.deepcopy(info or {})

  local route = overview.kind == "issue"
      and ("issues/" .. tostring(overview.number))
    or overview.kind == "pull_request" and (
        overview.forge == "codeberg"
            and ("pulls/" .. tostring(overview.number))
          or ("pull/" .. tostring(overview.number))
      )
    or ("commit/" .. tostring(
      overview.commit_details
        and overview.commit_details.sha
        or overview.sha
        or ""
    ))

  overview.url = overview.html_url
    or ("https://%s/%s/%s/%s"):format(
      overview.host or (
        overview.forge == "codeberg"
            and "codeberg.org"
          or "github.com"
      ),
      overview.owner or "",
      overview.repo or "",
      route
    )

  return overview
end

function M.append_sidebar_text(lines, text, width, indent)
  indent = indent or ""
  local available = math.max(1, width - vim.fn.strdisplaywidth(indent))

  for _, paragraph in ipairs(vim.split(
    tostring(text or ""),
    "\n",
    { plain = true }
  )) do
    paragraph = vim.trim(paragraph)

    if paragraph == "" then
      lines[#lines + 1] = ""
    else
      local current = ""

      for word in paragraph:gmatch("%S+") do
        while vim.fn.strdisplaywidth(word) > available do
          if current ~= "" then
            lines[#lines + 1] = indent .. current
            current = ""
          end

          local take = math.max(1, available)
          local piece = vim.fn.strcharpart(word, 0, take)

          while vim.fn.strdisplaywidth(piece) > available and take > 1 do
            take = take - 1
            piece = vim.fn.strcharpart(word, 0, take)
          end

          lines[#lines + 1] = indent .. piece
          word = vim.fn.strcharpart(word, take)
        end

        local proposed = current == "" and word or (current .. " " .. word)

        if vim.fn.strdisplaywidth(proposed) <= available then
          current = proposed
        else
          lines[#lines + 1] = indent .. current
          current = word
        end
      end

      if current ~= "" then
        lines[#lines + 1] = indent .. current
      end
    end
  end
end

function M.overview_window_config(opts)
  local width = math.floor(vim.o.columns * 0.7)
  local height = math.floor(vim.o.lines * 0.7)
  local col = math.floor((vim.o.columns - width) / 2)
  local row = math.floor((vim.o.lines - height) / 2)

  return {
    relative = "editor",
    width = width,
    height = height,
    col = col,
    row = row,
    style = "minimal",
    border = opts and opts.border or "rounded",
    zindex = 50,
  }
end

return M
