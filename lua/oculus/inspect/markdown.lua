-- Markdown descriptions share the overview buffer with ordinary metadata.
-- Keep their structure while wrapping prose, and scope Neovim's bundled
-- Markdown syntax to their exact lines so unfinished markup cannot leak out.
local review = require("oculus.inspect.review")
local M = {}

function M.append(lines, text, width)
  local first = #lines + 1
  local fence, fence_length

  for _, line in ipairs(vim.split(text, "\n", { plain = true })) do
    line = line:gsub("\r$", "")
    local whitespace = line:match("^[ \t]*")
    local content = line:sub(#whitespace + 1)
    local delimiter = content:match("^(````*)") or content:match("^(~~~~*)")
    local in_code = fence ~= nil

    if delimiter then
      if not fence then
        fence = delimiter:sub(1, 1)
        fence_length = #delimiter
      elseif delimiter:sub(1, 1) == fence
        and #delimiter >= fence_length
        and vim.trim(content:sub(#delimiter + 1)) == ""
      then
        fence = nil
        fence_length = nil
      end
    end

    if in_code or delimiter or vim.fn.strdisplaywidth(whitespace) >= 4 then
      lines[#lines + 1] = line == "" and "" or ("  " .. line)
    else
      local indent = "  " .. whitespace

      for _, wrapped in ipairs(review.wrap(
        content,
        width - vim.fn.strdisplaywidth(indent)
      )) do
        lines[#lines + 1] = wrapped == "" and "" or (indent .. wrapped)
      end
    end
  end

  return { first = first, last = #lines }
end

function M.highlight(buf, range)
  vim.api.nvim_buf_call(buf, function()
    if vim.b[buf].oculus_overview_markdown_syntax then
      vim.cmd("silent! syntax clear OculusInspectOverviewMarkdown")
    end

    if not range then
      return
    end

    if not vim.b[buf].oculus_overview_markdown_syntax then
      local current_syntax = vim.b[buf].current_syntax
      vim.b[buf].current_syntax = nil
      vim.cmd("syntax include @OculusOverviewMarkdown syntax/markdown.vim")
      vim.b[buf].current_syntax = current_syntax
      vim.b[buf].oculus_overview_markdown_syntax = true
    end

    vim.cmd((
      "syntax region OculusInspectOverviewMarkdown "
        .. "start=/\\%%%dl^/ end=/\\%%%dl^/ "
        .. "keepend transparent contains=@OculusOverviewMarkdown"
    ):format(range.first, range.last + 1))

    vim.cmd("syntax sync fromstart")
  end)
end

return M
