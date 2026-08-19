local M = {}

function M.inspect_sidebar_width(proportion, columns)
  columns = math.max(1, tonumber(columns) or vim.o.columns)

  if type(proportion) ~= "number"
    or proportion <= 0
    or proportion >= 1
  then
    proportion = 28 / columns
  end

  local width = math.floor(columns * proportion)

  return math.min(
    math.max(20, width),
    math.max(1, columns - 20)
  )
end

function M.sidebar_chunk_row(hunk, last)
  local branch = last and "└─" or "├─"
  local first = hunk.new_start
  local last_line = first + math.max(0, (hunk.new_count or 0) - 1)
  local delta = (hunk.new_count or 0) - (hunk.old_count or 0)
  local delta_text = delta > 0 and ("+" .. delta) or tostring(delta)
  local suffix = delta ~= 0 and (" (" .. delta_text .. ")") or ""

  return ("  %s %d-%d%s"):format(
    branch,
    first,
    last_line,
    suffix
  )
end

return M
