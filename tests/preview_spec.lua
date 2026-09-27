vim.opt.runtimepath:prepend(vim.fn.getcwd())

local buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"", "", "", "", "", ""})
local win = vim.api.nvim_open_win(buf, false, {
  relative = "editor", row = 0, col = 0, width = 50, height = 6,
  style = "minimal",
})
local ns = vim.api.nvim_create_namespace("oculus_preview_spec")
local window = {state = {buf = buf, win = win, view = "contributors"}}
local preview = require("oculus.window.preview").setup(window, {
  preview_ns = ns,
  is_valid_buf = vim.api.nvim_buf_is_valid,
  is_valid_win = vim.api.nvim_win_is_valid,
  preview_left_width = function(width) return math.floor(width / 2) end,
  trim_to_width = function(text, width) return text:sub(1, width) end,
})

local set_extmark = vim.api.nvim_buf_set_extmark
local clear_namespace = vim.api.nvim_buf_clear_namespace
local writes, clears = 0, 0

vim.api.nvim_buf_set_extmark = function(buffer, namespace, ...)
  if namespace == ns then writes = writes + 1 end
  return set_extmark(buffer, namespace, ...)
end

vim.api.nvim_buf_clear_namespace = function(buffer, namespace, ...)
  if namespace == ns then clears = clears + 1 end
  return clear_namespace(buffer, namespace, ...)
end

local function render(items)
  writes, clears = 0, 0
  preview.render_preview_panel(items)
end

local function marks()
  return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, {details = true})
end

local function row(line)
  for _, mark in ipairs(marks()) do
    if mark[2] == line - 1 then return mark end
  end
  error("missing preview row " .. line)
end

local items = {
  [2] = {"USER", "Title"},
  [4] = {"@alice", "Identifier"},
  [5] = {"GitHub", "Comment"},
}
render(items)
assert(writes == 6 and clears == 1, "first render draws the complete preview")
local original_marks = marks()
render(vim.deepcopy(items))
assert(writes == 0 and clears == 0, "identical previews perform no mark writes")
assert(vim.deep_equal(original_marks, marks()), "unchanged preview marks are retained")

items[4] = {"@bob", "Identifier"}
render(items)
assert(writes == 1 and clears == 0, "changing users updates only the username row")
assert(row(4)[1] == original_marks[4][1], "changed rows reuse their mark IDs")
assert(row(4)[4].virt_text[2][1] == " @bob", "the changed username is displayed")
items[4][2] = "Comment"
render(items)
assert(writes == 1 and row(4)[4].virt_text[2][2] == "Comment", "highlight changes update the row")

items[5] = nil
render(items)
assert(writes == 1 and clears == 0, "shorter previews clear only removed text")
assert(row(5)[4].virt_text[1][1] == "│" and row(5)[4].virt_text[2][1] == " ", "removed rows retain their separator")
assert(#marks() == 6, "updates do not accumulate extra marks")

vim.api.nvim_win_set_width(win, 40)
render(items)
assert(writes == 6 and clears == 1, "resizing rebuilds preview placement")
assert(row(4)[4].virt_text_win_col == 20, "the preview follows the resized divider")
items[4][1] = string.rep("x", 40)
render(items)
assert(writes == 1, "long text updates only its row")
items[4][1] = string.rep("x", 50)
render(items)
assert(writes == 0, "changes beyond the displayed width do not rewrite marks")

vim.api.nvim_win_set_height(win, 7)
render(items)
assert(writes == 6 and clears == 1, "height changes invalidate the layout")
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"new", "", "", "", "", ""})
render(items)
assert(writes == 6 and clears == 1, "buffer rewrites rebuild displaced marks")
assert(row(4)[2] == 3, "marks return to their intended rows after a rewrite")
vim.api.nvim_buf_set_lines(buf, 3, -1, false, {})
render(items)
assert(writes == 3 and clears == 1 and #marks() == 3, "shrinking the buffer removes obsolete marks")

clear_namespace(buf, ns, 0, -1)
window.state.preview_render = nil
render(items)
assert(writes == 3, "a list redraw can explicitly invalidate the cache")

vim.api.nvim_win_close(win, true)
vim.api.nvim_buf_delete(buf, {force = true})
buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(buf, 0, -1, false, {"", "", "", "", "", ""})
win = vim.api.nvim_open_win(buf, false, {
  relative = "editor", row = 0, col = 0, width = 50, height = 6,
  style = "minimal",
})
window.state.buf, window.state.win = buf, win
render(items)
assert(writes == 6 and clears == 1 and #marks() == 6, "reopening in a new buffer rebuilds the preview")

vim.api.nvim_buf_set_extmark = set_extmark
vim.api.nvim_buf_clear_namespace = clear_namespace
vim.api.nvim_win_close(win, true)
vim.api.nvim_buf_delete(buf, {force = true})
print("preview_spec: passed")
