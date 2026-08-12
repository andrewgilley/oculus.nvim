local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
vim.api.nvim_set_hl(0, "Normal", {
  fg = 0xd0d0d0,
  bg = 0x101820,
})
vim.api.nvim_set_hl(0, "DiffDelete", {
  fg = 0xff8080,
  bg = 0x401820,
})
vim.api.nvim_set_hl(0, "DiffAdd", {
  fg = 0x80ff80,
  bg = 0x104020,
})
vim.api.nvim_set_hl(0, "CursorLine", {
  fg = 0xfefefe,
  bg = 0x202830,
  nocombine = true,
})
local oil_runtime = vim.env.OCULUS_INSPECT_TEST_OIL
if oil_runtime then
  vim.opt.runtimepath:append(oil_runtime)
end

local inspect = require("oculus.inspect")
local oculus = require("oculus")
do
  local completions = {}
  local active_count = 0
  local maximum_active = 0
  local mapped
  inspect._map_concurrently(
    { 10, 20, 30, 40 },
    2,
    function(value, index, done)
      active_count = active_count + 1
      maximum_active = math.max(maximum_active, active_count)
      completions[index] = function()
        active_count = active_count - 1
        done(value + 1)
      end
    end,
    function(results, err)
      assert(not err, err)
      mapped = results
    end
  )
  assert(active_count == 2)
  completions[2]()
  assert(active_count == 2)
  completions[1]()
  assert(active_count == 2)
  completions[4]()
  completions[3]()
  assert(maximum_active == 2)
  assert(vim.deep_equal(mapped, { 11, 21, 31, 41 }))
end
assert(oculus.config.inspect_sidebar_toggle == "<leader>oi")
assert(math.abs(
  oculus.config.inspect_sidebar_width - (28 / vim.o.columns)
) < 0.000001)
assert(inspect._inspect_sidebar_width(
  oculus.config.inspect_sidebar_width,
  vim.o.columns
) == 28)
do
  local original_win = vim.api.nvim_get_current_win()
  vim.cmd("botright vsplit")
  local aerial_win = vim.api.nvim_get_current_win()
  local aerial_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(aerial_win, aerial_buf)
  vim.bo[aerial_buf].filetype = "aerial"
  vim.wo[aerial_win].winfixwidth = true
  assert(inspect._is_foreign_sidebar_window(aerial_win))
  vim.bo[aerial_buf].filetype = "custom-sidebar"
  assert(inspect._is_foreign_sidebar_window(aerial_win))
  vim.wo[aerial_win].winfixwidth = false
  assert(not inspect._is_foreign_sidebar_window(aerial_win))
  vim.bo[aerial_buf].filetype = "aerial"
  vim.api.nvim_win_set_config(aerial_win, {
    relative = "editor",
    row = 0,
    col = 0,
    width = 10,
    height = 5,
  })
  assert(not inspect._is_foreign_sidebar_window(aerial_win))
  vim.api.nvim_win_close(aerial_win, true)
  vim.api.nvim_set_current_win(original_win)
  vim.api.nvim_buf_delete(aerial_buf, { force = true })
end
assert(oculus.config.inspect_overview_toggle == "<leader>op")
assert(oculus.config.inspect_old_version == "<C-s>")
assert(oculus.config.inspect_new_version == "<C-d>")
assert(oculus.config.inspect_next_chunk == "<C-Tab>")
assert(oculus.config.inspect_previous_chunk == "<S-Tab>")
assert(oculus.config.inspect_treesitter_context == true)
assert(oculus.config.inspect_treesitter_context_multiwindow == true)
do
  local module_name = "treesitter-context"
  local original_context = package.loaded[module_name]
  local setup_options
  local fake_context = {
    config = { multiwindow = false },
    enabled = function()
      return true
    end,
    setup = function(options)
      setup_options = vim.deepcopy(options)
    end,
  }
  package.loaded[module_name] = fake_context
  assert(inspect._enable_inspection_treesitter_context({}))
  assert(vim.deep_equal(setup_options, {
    enable = true,
    multiwindow = true,
  }))
  setup_options = nil
  fake_context.config.multiwindow = true
  assert(inspect._enable_inspection_treesitter_context({}))
  assert(setup_options == nil)
  assert(not inspect._enable_inspection_treesitter_context({
    inspect_treesitter_context = false,
  }))
  assert(setup_options == nil)
  package.loaded[module_name] = original_context
end
assert(oculus.config.inspect_next_file == nil)
assert(oculus.config.persist_inspect_overviews == true)
assert(inspect._progressed_chunk_role({ kind = "commit" }, "change")
  == "change")
assert(inspect._progressed_chunk_role({ kind = "commit" }, "parent")
  == "parent")
assert(inspect._progressed_chunk_role({ kind = "issue" }, "issue")
  == "issue")
assert(inspect._chunk_start_for_role(
  { old_start = 7, new_start = 12 },
  "parent",
  12
) == 7)
assert(inspect._chunk_start_for_role(
  { old_start = 7, new_start = 12 },
  "change",
  12
) == 12)
assert(inspect._chunk_start_for_role(
  { old_start = 7, new_start = 2, new_count = 3 },
  "change",
  8,
  { "before", "", "  ", "changed" }
) == 10)
assert(inspect._chunk_start_for_role(
  { old_start = 7, new_start = 2, new_count = 2 },
  "change",
  8,
  { "before", "", "  " }
) == 8)
assert(vim.deep_equal(
  inspect._inspection_endpoints({}, {
    parent = "parent",
    change = "change",
  }),
  { "parent", "change" }
))
assert(vim.deep_equal(
  inspect._inspection_endpoints({ kind = "issue" }, {
    issue = "issue",
  }),
  { "issue" }
))
do
  local origin = vim.api.nvim_get_current_tabpage()
  local endpoints = {}
  for index = 1, 4 do
    vim.cmd("tabnew")
    endpoints[index] = {
      tab = vim.api.nvim_get_current_tabpage(),
      win = vim.api.nvim_get_current_win(),
      buf = vim.api.nvim_get_current_buf(),
    }
  end
  local group = {
    { parent = endpoints[1], change = endpoints[2] },
    { parent = endpoints[3], change = endpoints[4] },
  }
  assert(inspect._preserved_version_tab({
    group = group,
    index = 1,
    role = "parent",
  }, endpoints[2].tab) == endpoints[3].tab)
  assert(inspect._preserved_version_tab({
    group = group,
    index = 1,
    role = "change",
  }, endpoints[3].tab) == endpoints[4].tab)
  assert(inspect._preserved_version_tab({
    group = group,
    index = 2,
    role = "parent",
  }, endpoints[2].tab) == endpoints[1].tab)
  assert(inspect._preserved_version_tab({
    group = group,
    index = 2,
    role = "change",
  }, endpoints[3].tab) == endpoints[2].tab)
  for index = #endpoints, 1, -1 do
    vim.api.nvim_set_current_tabpage(endpoints[index].tab)
    vim.cmd("tabclose")
  end
  vim.api.nvim_set_current_tabpage(origin)
end

for group, expected in pairs({
  OculusInspectRemoved = { fg = 0xfee2e2, bg = 0x991b1b },
  OculusInspectAdded = { fg = 0xdcfce7, bg = 0x166534 },
}) do
  local sign_highlight =
    vim.api.nvim_get_hl(0, { name = group, link = false })
  assert(sign_highlight.fg == expected.fg)
  assert(sign_highlight.bg == expected.bg)
  vim.api.nvim_set_hl(0, group, { fg = 1, bg = 2 })
end
vim.api.nvim_exec_autocmds("ColorScheme", {})
for group, expected in pairs({
  OculusInspectRemoved = { fg = 0xfee2e2, bg = 0x991b1b },
  OculusInspectAdded = { fg = 0xdcfce7, bg = 0x166534 },
}) do
  local sign_highlight =
    vim.api.nvim_get_hl(0, { name = group, link = false })
  assert(sign_highlight.fg == expected.fg)
  assert(sign_highlight.bg == expected.bg)
end
do
  local parent_buf = vim.api.nvim_create_buf(false, true)
  local change_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(change_buf, 0, -1, false, { "one", "two" })
  local addition = {
    old_start = 0,
    old_count = 0,
    new_start = 1,
    new_count = 2,
  }
  inspect._apply_change_signs(parent_buf, change_buf, { addition }, "A")
  local signs = vim.api.nvim_get_namespaces().oculus_inspect_changes
  assert(#vim.api.nvim_buf_get_extmarks(
    parent_buf,
    signs,
    0,
    -1,
    {}
  ) == 0)
  assert(#vim.api.nvim_buf_get_extmarks(
    change_buf,
    signs,
    0,
    -1,
    {}
  ) == 0)
  inspect._apply_change_signs(parent_buf, change_buf, { addition }, "M")
  assert(#vim.api.nvim_buf_get_extmarks(
    change_buf,
    signs,
    0,
    -1,
    {}
  ) == 2)
  vim.api.nvim_buf_delete(parent_buf, { force = true })
  vim.api.nvim_buf_delete(change_buf, { force = true })
end
assert(vim.api.nvim_get_hl(
  0,
  { name = "OculusInspectCursorLine", link = false }
).bg == 0x202830)
assert(vim.api.nvim_get_hl(
  0,
  { name = "OculusInspectCursorLine", link = false }
).fg == nil)
assert(vim.api.nvim_get_hl(
  0,
  { name = "OculusInspectCursorLine", link = false }
).nocombine ~= true)
local hidden_cursor_hl = vim.api.nvim_get_hl(
  0,
  { name = "OculusInspectHiddenCursor", link = false }
)
assert(hidden_cursor_hl.fg == 0x101820)
assert(hidden_cursor_hl.bg == 0x101820)
assert(hidden_cursor_hl.blend == 100)
assert(vim.api.nvim_get_hl(
  0,
  { name = "OculusOilChange", link = false }
).fg == 0xfbd38d)
assert(vim.api.nvim_get_hl(
  0,
  { name = "OculusOilChange", link = false }
).bg == 0x101820)
assert(vim.api.nvim_get_hl(
  0,
  { name = "OculusOilChange", link = false }
).bold ~= true)

local dimming_win = vim.api.nvim_get_current_win()
local original_winhighlight = vim.wo[dimming_win].winhighlight
vim.wo[dimming_win].winhighlight =
  "NormalNC:Comment,CursorLine:Visual"
assert(inspect._prevent_window_dimming(dimming_win))
assert(vim.wo[dimming_win].winhighlight
  == "CursorLine:Visual,NormalNC:Normal")
assert(inspect._preserve_cursorline_text_highlighting(dimming_win))
assert(vim.wo[dimming_win].winhighlight
  == "NormalNC:Normal,CursorLine:OculusInspectCursorLine")
vim.wo[dimming_win].winhighlight = original_winhighlight

local highlight_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(
  highlight_buf,
  0,
  -1,
  false,
  { "local highlighted = true" }
)
vim.bo[highlight_buf].filetype = "lua"
vim.bo[highlight_buf].syntax = "lua"
vim.b[highlight_buf].oculus_inspect = { role = "change" }
local fake_highlighter = {}
local invalidated = false
local parsed = false
local parser = {
  invalidate = function(_, reload)
    assert(reload == true)
    invalidated = true
  end,
  parse = function(_, range, callback)
    assert(range == true)
    parsed = true
    callback()
  end,
}
local original_highlighter =
  vim.treesitter.highlighter.active[highlight_buf]
local original_get_parser = vim.treesitter.get_parser
local original_stop = vim.treesitter.stop
local original_start = vim.treesitter.start
vim.treesitter.highlighter.active[highlight_buf] = fake_highlighter
vim.treesitter.get_parser = function(buf)
  assert(buf == highlight_buf)
  return parser
end
vim.treesitter.stop = function()
  error("refresh must preserve the active highlighter")
end
vim.treesitter.start = function()
  error("refresh must preserve the active highlighter")
end
assert(inspect._refresh_buffer_highlighting(highlight_buf))
assert(vim.bo[highlight_buf].syntax == "lua")
assert(invalidated)
assert(parsed)
assert(vim.treesitter.highlighter.active[highlight_buf]
  == fake_highlighter)
invalidated = false
parsed = false
assert(inspect._refresh_buffer_highlighting(highlight_buf))
assert(not invalidated)
assert(not parsed)
assert(inspect._refresh_buffer_highlighting(highlight_buf, true))
assert(invalidated)
assert(parsed)

assert((function()
  local late_highlight_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(
    late_highlight_buf,
    0,
    -1,
    false,
    { "local imported = require('oculus')" }
  )
  vim.bo[late_highlight_buf].filetype = "lua"
  vim.bo[late_highlight_buf].syntax = "lua"
  vim.b[late_highlight_buf].oculus_inspect = { role = "change" }
  local original_late_highlighter =
    vim.treesitter.highlighter.active[late_highlight_buf]
  vim.treesitter.highlighter.active[late_highlight_buf] = nil
  local late_highlighter = {}
  local late_start_count = 0
  local late_invalidated = false
  local late_parsed = false
  vim.treesitter.start = function(buf)
    assert(buf == late_highlight_buf)
    late_start_count = late_start_count + 1
    if late_start_count == 2 then
      vim.treesitter.highlighter.active[buf] = late_highlighter
    end
  end
  vim.treesitter.get_parser = function(buf)
    assert(buf == late_highlight_buf)
    return {
      invalidate = function(_, reload)
        assert(reload == true)
        late_invalidated = true
      end,
      parse = function(_, range, callback)
        assert(range == true)
        late_parsed = true
        callback()
      end,
    }
  end
  assert(not inspect._refresh_buffer_highlighting(late_highlight_buf))
  assert(late_start_count == 1)
  assert(
    vim.b[late_highlight_buf].oculus_inspect_highlighting_changedtick
      == nil
  )
  assert(inspect._refresh_buffer_highlighting(late_highlight_buf))
  assert(late_start_count == 2)
  assert(late_invalidated)
  assert(late_parsed)
  late_invalidated = false
  late_parsed = false
  assert(inspect._refresh_buffer_highlighting(late_highlight_buf))
  assert(not late_invalidated)
  assert(not late_parsed)
  local late_tick = vim.api.nvim_buf_get_changedtick(late_highlight_buf)
  assert(vim.wait(100, function()
    return vim.b[late_highlight_buf]
        .oculus_inspect_highlighting_changedtick == late_tick
  end))
  vim.api.nvim_buf_set_lines(
    late_highlight_buf,
    0,
    -1,
    false,
    { "local imported = require('oculus.inspect')" }
  )
  assert(inspect._refresh_buffer_highlighting(late_highlight_buf))
  assert(late_invalidated)
  assert(late_parsed)

  local fallback_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(
    fallback_buf,
    0,
    -1,
    false,
    { 'const std = @import("std");' }
  )
  vim.bo[fallback_buf].filetype = "zig"
  vim.bo[fallback_buf].syntax = ""
  vim.b[fallback_buf].oculus_inspect = { role = "parent" }
  local original_fallback_highlighter =
    vim.treesitter.highlighter.active[fallback_buf]
  vim.treesitter.highlighter.active[fallback_buf] = nil
  local fallback_start_count = 0
  vim.treesitter.start = function(buf)
    assert(buf == fallback_buf)
    fallback_start_count = fallback_start_count + 1
    error("no Zig parser")
  end
  assert(inspect._refresh_buffer_highlighting(fallback_buf))
  assert(fallback_start_count == 1)
  assert(vim.bo[fallback_buf].syntax == "zig")
  assert(vim.b[fallback_buf].current_syntax == "zig")
  local fallback_tick = vim.api.nvim_buf_get_changedtick(fallback_buf)
  assert(vim.b[fallback_buf].oculus_inspect_syntax_changedtick
    == fallback_tick)
  assert(inspect._refresh_buffer_highlighting(fallback_buf))
  assert(fallback_start_count == 1)
  vim.treesitter.highlighter.active[fallback_buf] =
    original_fallback_highlighter
  vim.api.nvim_buf_delete(fallback_buf, { force = true })

  local pair_parent = vim.api.nvim_create_buf(false, true)
  local pair_change = vim.api.nvim_create_buf(false, true)
  for _, buf in ipairs({ pair_parent, pair_change }) do
    vim.api.nvim_buf_set_lines(
      buf,
      0,
      -1,
      false,
      { "local imported = require('oculus')" }
    )
    vim.bo[buf].filetype = "lua"
    vim.bo[buf].syntax = ""
    vim.b[buf].oculus_inspect = { role = "change" }
  end
  local original_pair_parent_highlighter =
    vim.treesitter.highlighter.active[pair_parent]
  local original_pair_change_highlighter =
    vim.treesitter.highlighter.active[pair_change]
  vim.treesitter.highlighter.active[pair_parent] = {}
  vim.treesitter.highlighter.active[pair_change] = nil
  local pair_parent_stopped = false
  vim.treesitter.get_parser = function(buf)
    assert(buf == pair_parent)
    return {
      invalidate = function() end,
      parse = function(_, _, callback)
        callback()
      end,
    }
  end
  vim.treesitter.start = function(buf)
    assert(buf == pair_change)
    error("pair parser did not attach")
  end
  vim.treesitter.stop = function(buf)
    assert(buf == pair_parent)
    pair_parent_stopped = true
    vim.treesitter.highlighter.active[buf] = nil
  end
  assert(inspect._synchronize_inspection_highlighting(
    pair_parent,
    pair_change
  ) == "syntax")
  assert(pair_parent_stopped)
  for _, buf in ipairs({ pair_parent, pair_change }) do
    assert(vim.b[buf].oculus_inspect_highlight_engine == "syntax")
    assert(vim.bo[buf].syntax == "lua")
    assert(vim.b[buf].current_syntax == "lua")
  end
  vim.treesitter.highlighter.active[pair_parent] =
    original_pair_parent_highlighter
  vim.treesitter.highlighter.active[pair_change] =
    original_pair_change_highlighter
  vim.api.nvim_buf_delete(pair_parent, { force = true })
  vim.api.nvim_buf_delete(pair_change, { force = true })

  vim.treesitter.highlighter.active[late_highlight_buf] =
    original_late_highlighter
  vim.api.nvim_buf_delete(late_highlight_buf, { force = true })
  return true
end)())
vim.treesitter.highlighter.active[highlight_buf] = original_highlighter
vim.treesitter.get_parser = original_get_parser
vim.treesitter.stop = original_stop
vim.treesitter.start = original_start
vim.api.nvim_buf_delete(highlight_buf, { force = true })

local filetype_buf = vim.api.nvim_create_buf(false, true)
vim.api.nvim_buf_set_lines(
  filetype_buf,
  0,
  -1,
  false,
  { "print('inspected python')" }
)
vim.bo[filetype_buf].filetype = "lua"
vim.b[filetype_buf].oculus_inspect = {
  role = "parent",
  source_path = vim.fs.joinpath(root, "src", "inspection.py"),
}
local original_reliquary = package.loaded.reliquary
local reliquary_buf
local reliquary_filetype
local reliquary_apply_count = 0
local normal_before_filetype = vim.api.nvim_get_hl(0, {
  name = "Normal",
  link = false,
})
local filetype_colorscheme_bg = 0x2a3340
package.loaded.reliquary = {
  apply = function(buf)
    reliquary_apply_count = reliquary_apply_count + 1
    reliquary_buf = buf
    reliquary_filetype = vim.bo[buf].filetype
    vim.api.nvim_set_hl(0, "Normal", {
      fg = normal_before_filetype.fg,
      bg = filetype_colorscheme_bg,
    })
    return "st"
  end,
}
local filetype_current_buf = vim.api.nvim_get_current_buf()
assert(inspect._apply_inspection_filetype(filetype_buf) == "python")
assert(vim.bo[filetype_buf].filetype == "python")
assert(reliquary_buf == filetype_buf)
assert(reliquary_filetype == "python")
assert(vim.api.nvim_get_current_buf() == filetype_current_buf)
assert(reliquary_apply_count == 1)
local filetype_window_highlight_ns = assert(
  vim.api.nvim_get_namespaces().oculus_window_highlights
)
assert(vim.api.nvim_get_hl(filetype_window_highlight_ns, {
  name = "OculusNormal",
  link = false,
}).bg == filetype_colorscheme_bg)
assert(vim.api.nvim_get_hl(filetype_window_highlight_ns, {
  name = "OculusBorder",
  link = false,
}).bg == filetype_colorscheme_bg)
vim.api.nvim_set_hl(0, "Normal", normal_before_filetype)
require("oculus.window").refresh_window_highlights()
package.loaded.reliquary = original_reliquary
vim.api.nvim_buf_delete(filetype_buf, { force = true })

local viewport_buf = vim.api.nvim_get_current_buf()
local viewport_win = vim.api.nvim_get_current_win()
local viewport_lines = {}
for index = 1, 40 do
  viewport_lines[index] = "line " .. index
end
vim.api.nvim_buf_set_lines(
  viewport_buf,
  0,
  -1,
  false,
  viewport_lines
)
for _, expected in ipairs({
  { cursor = 5, topline = 1, column = 0 },
  {
    cursor = 15,
    topline = 5,
    column = #viewport_lines[15] - 1,
  },
}) do
  vim.api.nvim_win_call(viewport_win, function()
    vim.fn.winrestview({ topline = 1 })
  end)
  vim.api.nvim_win_set_cursor(viewport_win, { expected.cursor, 0 })
  inspect._normalize_inspection_view(viewport_win)
  local view = vim.api.nvim_win_call(viewport_win, vim.fn.winsaveview)
  local cursor = vim.api.nvim_win_get_cursor(viewport_win)
  assert(view.topline == expected.topline)
  assert(cursor[2] == expected.column)
end

local comment = inspect.activity_comment({
  type = "PullRequestReviewCommentEvent",
  payload = {
    comment = {
      body = "Please keep this branch explicit.",
      path = "lua/oculus/inspect.lua",
      start_line = 15,
      line = 17,
      side = "RIGHT",
      commit_id = "aaaaaaaa",
    },
  },
})
assert(comment)
assert(comment.body == "Please keep this branch explicit.")
assert(comment.path == "lua/oculus/inspect.lua")
assert(comment.line == 15)
assert(comment.side == "change")
assert(comment.commit == "aaaaaaaa")
local left_comment = inspect.activity_comment({
  type = "PullRequestReviewCommentEvent",
  payload = {
    comment = {
      body = "This was removed.",
      path = "lua/oculus/inspect.lua",
      original_line = 12,
      side = "LEFT",
      original_commit_id = "bbbbbbbb",
    },
  },
})
assert(left_comment)
assert(left_comment.line == 12)
assert(left_comment.side == "parent")
assert(left_comment.commit == "bbbbbbbb")
assert(inspect.activity_comment({
  type = "IssueCommentEvent",
  payload = {
    comment = {
      body = "Not attached to code.",
      path = "README.md",
      line = 1,
    },
  },
}) == nil)

local comment_view = assert(inspect._comment_float({
  tab = vim.api.nvim_get_current_tabpage(),
  win = viewport_win,
  buf = viewport_buf,
}, comment))
assert(vim.api.nvim_get_current_win() == viewport_win)
local comment_config = vim.api.nvim_win_get_config(comment_view.win)
assert(comment_config.relative == "win")
assert(comment_config.win == viewport_win)
assert(comment_config.anchor == "SW")
assert(comment_config.bufpos[1] == comment.line - 1)
assert(comment_config.col > 0)
assert(comment_config.focusable == false)
assert(vim.api.nvim_buf_get_lines(
  comment_view.buf,
  0,
  -1,
  false
)[1] == comment.body)
vim.api.nvim_win_close(comment_view.win, true)

vim.api.nvim_buf_set_lines(viewport_buf, 0, -1, false, { "" })
vim.api.nvim_win_set_cursor(viewport_win, { 1, 0 })
vim.bo[viewport_buf].modified = false

local shortened_sidebar_row = inspect._sidebar_row(
  "a-very-long-changed-file-name.lua",
  24
)
assert(shortened_sidebar_row.line:match("^• …"))
assert(shortened_sidebar_row.line:match(" P C $"))
assert(shortened_sidebar_row.parent_column
  < shortened_sidebar_row.change_column)
assert(vim.fn.strdisplaywidth(shortened_sidebar_row.line) == 24)
local versioned_sidebar_row = inspect._sidebar_row(
  "inspect.lua",
  24,
  2
)
assert(versioned_sidebar_row.line:match("^• inspect%.lua v%.2"))
assert(versioned_sidebar_row.line:match(" P C $"))
assert(versioned_sidebar_row.version_column)
assert(versioned_sidebar_row.version_end_column
  == versioned_sidebar_row.version_column + 3)
assert(vim.fn.strdisplaywidth(versioned_sidebar_row.line) == 24)
local versioned_sessions = inspect._assign_sidebar_versions({
  { file = "lua/oculus/inspect.lua", commit_index = 1 },
  { file = "lua/oculus/inspect.lua", commit_index = 2 },
  { file = "tests/inspect.lua", commit_index = 2 },
  { file = "lua/oculus/inspect.lua", commit_index = 3 },
})
assert(versioned_sessions[1].sidebar_version == 1)
assert(versioned_sessions[2].sidebar_version == 2)
assert(versioned_sessions[3].sidebar_version == nil)
assert(versioned_sessions[4].sidebar_version == 3)
assert(versioned_sessions[1].sidebar_version_count == 3)
assert(inspect._sidebar_chunk_row(
  { old_count = 1, new_start = 25, new_count = 4 },
  false
) == "  ├─ 25-28 (+3)")
assert(inspect._sidebar_chunk_row(
  { old_count = 2, new_start = 31, new_count = 0 },
  true
) == "  └─ 31-31 (-2)")
assert(inspect._sidebar_chunk_row(
  { old_count = 2, new_start = 40, new_count = 2 },
  true
) == "  └─ 40-41")
assert(inspect._sidebar_file(
  "a/very/long/path/to/a/changed/file.lua"
) == "file.lua")
assert(inspect._sidebar_file(
  "lua\\oculus\\inspect.lua"
) == "inspect.lua")
assert(inspect._sidebar_file("README.md") == "README.md")
vim.g.oculus_test_sorted_inspections = inspect._sort_inspections({
  { change_file = "tests/unit/inspect_spec.lua" },
  { change_file = "lua/oculus/window.lua" },
  { change_file = "README.md" },
  { parent_file = "lua/init.lua" },
  { change_file = "LICENSE" },
  { change_file = "tests/inspect_spec.lua" },
  { change_file = "lua/oculus/inspect.lua" },
})
assert(vim.deep_equal(
  vim.tbl_map(function(inspection)
    return inspection.change_file or inspection.parent_file
  end, vim.g.oculus_test_sorted_inspections),
  {
    "LICENSE",
    "README.md",
    "lua/init.lua",
    "tests/inspect_spec.lua",
    "lua/oculus/inspect.lua",
    "lua/oculus/window.lua",
    "tests/unit/inspect_spec.lua",
  }
))
vim.g.oculus_test_sorted_inspections = nil
assert(inspect._sidebar_target_role(
  1,
  "change",
  { pair_index = 2 }
) == "parent")
assert(inspect._sidebar_target_role(
  1,
  "change",
  { pair_index = 1 }
) == "change")
assert(inspect._sidebar_target_role(
  1,
  "parent",
  { pair_index = 2 },
  { kind = "commit", [2] = { last_role = "change" } },
  "parent"
) == "change")
assert(inspect._chunk_navigation_role(
  { kind = "commit" },
  {},
  "change",
  { last_role = "change" },
  true
) == "change")

assert(inspect._inspection_directory(
  root,
  "lua/oculus/inspect.lua"
) == vim.fs.joinpath(root, "lua", "oculus"))
assert(inspect._inspection_directory(
  root,
  "not-present/inspect.lua"
) == root)
assert(inspect._inspection_statusline_path({
  repository = root,
  source_path = vim.fs.joinpath(root, "lua", "oculus", "inspect.lua"),
  file = "lua/oculus/inspect.lua",
}) == vim.fs.basename(root) .. "/lua/oculus/inspect.lua")
assert(inspect._inspection_buffer_name({
  source_path = vim.fs.joinpath(root, "lua", "oculus", "inspect.lua"),
  commit = "0123456789abcdef",
  role = "change",
  pair_index = 2,
}) == vim.fs.joinpath(root, "lua", "oculus", "inspect.lua")
  .. "@oculus-change-0123456789ab-2")

local parsed = inspect._parse_commit_url(
  "https://github.com/neovim/neovim/commit/"
    .. "0123456789abcdef0123456789abcdef01234567#diff"
)
assert(parsed)
assert(parsed.owner == "neovim")
assert(parsed.repo == "neovim")
assert(parsed.sha == "0123456789abcdef0123456789abcdef01234567")
assert(parsed.remote_url == "https://github.com/neovim/neovim.git")

local codeberg_commit = inspect._parse_commit_url(
  "https://codeberg.org/ziglang/zig/commit/0123456"
)
assert(codeberg_commit)
assert(codeberg_commit.forge == "codeberg")
assert(codeberg_commit.owner == "ziglang")
assert(codeberg_commit.repo == "zig")
assert(codeberg_commit.sha == "0123456")
assert(codeberg_commit.remote_url == "https://codeberg.org/ziglang/zig.git")
assert(inspect._parse_commit_url("https://github.com/a/b/issues/1") == nil)
assert(inspect._parse_commit_url("https://github.com/a/b/commit/123") == nil)
assert(inspect._parse_commit_url(
  "https://github.com/a/b/commit/01234567890123456789012345678901234567890"
) == nil)
assert(inspect._parse_commit_url(
  "https://github.com/../b/commit/0123456"
) == nil)

local pull_request = inspect._parse_pull_request_url(
  "https://github.com/neovim/neovim/pull/123/files#diff-test"
)
assert(pull_request)
assert(pull_request.kind == "pull_request")
assert(pull_request.owner == "neovim")
assert(pull_request.repo == "neovim")
assert(pull_request.number == 123)
assert(inspect._parse_pull_request_url(
  "https://github.com/neovim/neovim/issues/123#issuecomment-456"
) == nil)
assert(inspect._parse_pull_request_url(
  "https://github.com/neovim/neovim/issues/not-a-number"
) == nil)
local issue = inspect._parse_issue_url(
  "https://github.com/neovim/neovim/issues/123#issuecomment-456"
)
assert(issue)
assert(issue.kind == "issue")
assert(issue.forge == "github")
assert(issue.owner == "neovim")
assert(issue.repo == "neovim")
assert(issue.number == 123)
local codeberg_issue = inspect._parse_issue_url(
  "https://codeberg.org/ziglang/zig/issues/42"
)
assert(codeberg_issue)
assert(codeberg_issue.kind == "issue")
assert(codeberg_issue.forge == "codeberg")
assert(codeberg_issue.number == 42)
local codeberg_pull_request = inspect._parse_pull_request_url(
  "https://codeberg.org/ziglang/zig/pulls/35754#issuecomment-1"
)
assert(codeberg_pull_request)
assert(codeberg_pull_request.forge == "codeberg")
assert(codeberg_pull_request.owner == "ziglang")
assert(codeberg_pull_request.repo == "zig")
assert(codeberg_pull_request.number == 35754)
assert(not codeberg_pull_request.via_issue)
assert(codeberg_pull_request.remote_url
  == "https://codeberg.org/ziglang/zig.git")

local resolved_pull_request = inspect._apply_pull_request(pull_request, {
  title = "Test pull request",
  body = "This pull request improves the Inspect workflow.",
  author = "reviewer",
  state = "open",
  draft = false,
  merged = false,
  html_url = "https://github.com/neovim/neovim/pull/123",
  created_at = "2026-07-30T12:00:00-04:00",
  base_sha = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
  base_ref = "main",
  head_sha = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
  head_ref = "feature",
  commit_count = 3,
})
assert(resolved_pull_request.base_ref == "main")
assert(resolved_pull_request.head_ref == "feature")
assert(resolved_pull_request.base_sha:match("^a+$"))
assert(resolved_pull_request.head_sha:match("^b+$"))
assert(resolved_pull_request.commit_count == 3)
assert(resolved_pull_request.author == "reviewer")
assert(resolved_pull_request.created_at == "2026-07-30T12:00:00-04:00")

local pull_request_overview = inspect._inspection_overview(
  resolved_pull_request,
  {}
)
local pull_request_overview_text = table.concat(
  inspect._sidebar_overview_lines(pull_request_overview, 28),
  "\n"
)
assert(not pull_request_overview_text:match("\n$"))
assert(pull_request_overview_text:find(
  "OVERVIEW",
  1,
  true
))
assert(pull_request_overview_text:match("^OVERVIEW\n"))
assert(pull_request_overview_text:gsub("%s+", " "):find(
  "Title Test pull request",
  1,
  true
))
assert(pull_request_overview_text:find("#123", 1, true))
assert(pull_request_overview_text:find(
  "\n  Title\n  Test pull request",
  1,
  true
))
assert(pull_request_overview_text:find("@reviewer", 1, true))
assert(pull_request_overview_text:find(
  "This pull request improves",
  1,
  true
))
assert(pull_request_overview_text:find("\n  Title\n", 1, true))
assert(pull_request_overview_text:find("\n  Description\n", 1, true))
assert(pull_request_overview_text:find("\n  Author\n", 1, true))
assert(pull_request_overview_text:find("\n  URL\n", 1, true))
assert(pull_request_overview_text:find("\n  PR number\n", 1, true))
assert(pull_request_overview_text:find("\n  Status\n", 1, true))
assert(pull_request_overview_text:find("\n  Date\n", 1, true))
local pull_request_overview_lines =
  inspect._sidebar_overview_lines(pull_request_overview, 28)
assert(pull_request_overview_lines[#pull_request_overview_lines - 1]
  == "  Date")
assert(pull_request_overview_lines[#pull_request_overview_lines]
  :match("^  %a+ %d%d?, %d%d%d%d$"))
assert(not pull_request_overview_text:find("Repository", 1, true))
assert(not pull_request_overview_text:find("Branches", 1, true))
assert(not pull_request_overview_text:find("Changes", 1, true))
assert(not pull_request_overview_text:find("Created", 1, true))
assert(not pull_request_overview_text:find("Updated", 1, true))
assert(not pull_request_overview_text:find("changed files", 1, true))

local parsed_commit_overview = inspect._parse_commit_overview(
  table.concat({
    "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb",
    "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa",
    "Ada Lovelace",
    "ada@example.com",
    "2026-07-30T12:00:00-04:00",
    "Keep Inspect context visible",
    "Show the relevant commit details in the sidebar.",
  }, "\0")
)
assert(parsed_commit_overview)
assert(parsed_commit_overview.author_name == "Ada Lovelace")
assert(parsed_commit_overview.subject == "Keep Inspect context visible")
local commit_overview = inspect._inspection_overview({
  kind = "commit",
  forge = "github",
  host = "github.com",
  owner = "neovim",
  repo = "neovim",
  sha = parsed_commit_overview.sha,
  commit_details = parsed_commit_overview,
}, {
  {
    change_file = "lua/inspect.lua",
    commit_index = 1,
    hunks = {
      { old_count = 2, new_count = 5 },
    },
  },
})
local commit_overview_text = table.concat(
  inspect._sidebar_overview_lines(commit_overview, 28),
  "\n"
)
assert(commit_overview_text:match("^OVERVIEW\n"))
assert(commit_overview_text:gsub("%s+", " "):find(
  "Title Keep Inspect context visible",
  1,
  true
))
assert(commit_overview_text:find(
  "\n  Title\n  Keep Inspect context",
  1,
  true
))
assert(commit_overview_text:find("Ada Lovelace", 1, true))
assert(commit_overview_text:find("\n  Title\n", 1, true))
assert(commit_overview_text:find("\n  Description\n", 1, true))
assert(commit_overview_text:find("\n  Author\n", 1, true))
assert(commit_overview_text:find("\n  URL\n", 1, true))
assert(commit_overview_text:find("\n  Date\n", 1, true))
local commit_overview_lines =
  inspect._sidebar_overview_lines(commit_overview, 28)
assert(commit_overview_lines[#commit_overview_lines - 1]
  == "  Date")
assert(commit_overview_lines[#commit_overview_lines]
  :match("^  %a+ %d%d?, %d%d%d%d$"))
assert(not commit_overview_text:find("Repository", 1, true))
assert(not commit_overview_text:find("\nCommit\n", 1, true))
assert(not commit_overview_text:find("Authored", 1, true))
assert(not commit_overview_text:find("Changes", 1, true))
local commit_agent_prompt = require("oculus.agent").prompt({
  overview = commit_overview,
  {
    change_file = "lua/inspect.lua",
    change_repository = root,
    status = "M",
    patch = table.concat({
      "@@ -1 +1 @@",
      "-old behavior",
      "+new behavior",
      "@@ -10 +10 @@",
      "-second old behavior",
      "+second new behavior",
    }, "\n"),
  },
})
assert(commit_agent_prompt:find("Repository: neovim/neovim", 1, true))
assert(commit_agent_prompt:find("File: lua/inspect.lua", 1, true))
assert(commit_agent_prompt:find("+new behavior", 1, true))
assert(commit_agent_prompt:find(
  "Discuss file changes naturally without citing numbered diff chunks.",
  1,
  true
))
assert(not commit_agent_prompt:find("Chunk reference:", 1, true))
assert(not commit_agent_prompt:find("#chunk-", 1, true))
assert(require("oculus.agent").model_from_stderr(table.concat({
  "OpenAI Codex",
  "model: gpt-test-agent",
  "provider: openai",
}, "\n")) == "gpt-test-agent")
local normalized_models = require("oculus.agent").normalize_models({
  {
    model = "gpt-5.6-terra",
    displayName = "Terra",
    isDefault = true,
  },
  { model = "gpt-5.6-luna", displayName = "Luna" },
  { model = "gpt-5.6-sol", displayName = "Sol" },
  { model = "gpt-5.6-hidden", displayName = "Hidden", hidden = true },
  { model = "gpt-5.4", displayName = "GPT 5.4" },
})
assert(#normalized_models == 3)
assert(normalized_models[1].id == "gpt-5.6-sol")
assert(normalized_models[2].id == "gpt-5.6-terra")
assert(normalized_models[2].is_default)
assert(normalized_models[3].id == "gpt-5.6-luna")
local normalized_explanation, normalized_locations =
  require("oculus.agent").normalize_result(vim.json.encode({
    explanation = "A structured explanation.",
    locations = {
      {
        path = vim.fs.basename(root) .. "/one.lua",
        line = 17,
        reason = "First",
      },
      { path = "two.lua", line = "24", reason = "Second" },
      { path = "three.lua", reason = "Third" },
      { path = "four.lua", reason = "Fourth" },
      { path = "five.lua", reason = "Fifth" },
      { path = "six.lua", reason = "Must be omitted" },
    },
  }), true, root)
assert(normalized_explanation == "A structured explanation.")
assert(#normalized_locations == 3)
assert(normalized_locations[1].path
  == vim.fs.basename(root) .. "/one.lua")
assert(normalized_locations[1].line == 17)
assert(normalized_locations[2].line == 24)
assert(normalized_locations[3].path
  == vim.fs.basename(root) .. "/three.lua")
local persisted_overview_file = vim.fn.tempname()
local persisted_overviews = {}
local persisted_overview_config = {
  state_file = persisted_overview_file,
  inspect_overviews = persisted_overviews,
}
local persisted_overview_group = {
  overview = {
    kind = "issue",
    forge = "github",
    owner = "example",
    repo = "repository",
    number = 42,
    url = "https://github.com/example/repository/issues/42",
  },
  state_file = persisted_overview_file,
  inspect_overviews = persisted_overviews,
  persist_inspect_overviews = true,
  persistence_config = persisted_overview_config,
  overview_agent_explanation = "A persisted explanation.",
  overview_agent_explanation_model = "gpt-5.6-sol",
  overview_agent_locations = {
    {
      path = "repository/lua/one.lua",
      line = 17,
      reason = "First persisted location.",
    },
    {
      path = "repository/lua/two.lua",
      line = 24,
      reason = "Second persisted location.",
    },
  },
  overview_agent_patch_model = "gpt-5.6-terra",
  overview_agent_selected_location_index = 2,
  overview_agent_selected_locations = { [2] = true },
  { repository = root },
}
assert(inspect._overview_ui.persist(persisted_overview_group))
local restarted_overview_state = assert(
  require("oculus.storage").load(persisted_overview_file)
)
local restarted_overview_group = {
  overview = vim.deepcopy(persisted_overview_group.overview),
  inspect_overviews = restarted_overview_state.inspect_overviews,
  { repository = root },
}
assert(inspect._overview_ui.restore_persisted(restarted_overview_group))
assert(restarted_overview_group.overview_agent_explanation
  == "A persisted explanation.")
assert(restarted_overview_group.overview_agent_explanation_model
  == "gpt-5.6-sol")
assert(#restarted_overview_group.overview_agent_locations == 2)
assert(restarted_overview_group.overview_agent_locations[2].path
  == "repository/lua/two.lua")
assert(restarted_overview_group.overview_agent_locations[2].line == 24)
assert(restarted_overview_group.overview_agent_patch_model
  == "gpt-5.6-terra")
assert(restarted_overview_group.overview_agent_selected_location_index == 2)
assert(restarted_overview_group.overview_agent_selected_locations[2])
assert(restarted_overview_group.overview_agent_mode == "patch_locations")
vim.fn.delete(persisted_overview_file)
do
  local main_config = require("oculus.window").window_config({})
  local commit_config = inspect._overview_window_config(
    main_config,
    { kind = "commit" }
  )
  assert(commit_config.width == main_config.width - 12)
  assert(commit_config.height == main_config.height - 3)
  assert(commit_config.col == main_config.col + 6)
  assert(commit_config.row == main_config.row + 2)
  assert(commit_config.footer == nil)
  assert(commit_config.footer_pos == nil)
  local pull_request_config = inspect._overview_window_config(
    main_config,
    { kind = "pull_request" }
  )
  assert(pull_request_config.width == main_config.width - 12)
  assert(pull_request_config.height == main_config.height - 3)
  assert(pull_request_config.col == main_config.col + 6)
  assert(pull_request_config.row == main_config.row + 2)
  assert(pull_request_config.footer == nil)
  assert(pull_request_config.footer_pos == nil)
end

local issue_context = inspect.activity_context({
  type = "IssueCommentEvent",
  payload = {
    issue = {
      number = 123,
      title = "Inspection loses focus",
      body = "The problem is in lua/oculus/inspect.lua:10.",
    },
    comment = {
      body = "Also check `open_issue`.",
    },
  },
})
assert(issue_context)
assert(issue_context.issue.number == 123)
assert(issue_context.issue.title == "Inspection loses focus")
assert(issue_context.issue.body:find("inspect.lua:10", 1, true))
assert(issue_context.issue.comment == "Also check `open_issue`.")

local revision_pairs = inspect._parse_revision_pairs(table.concat({
  "1111111 aaaaaaa",
  "2222222 1111111",
  "3333333 2222222 bbbbbbb",
}, "\n"))
assert(#revision_pairs == 3)
assert(revision_pairs[1].parent == "aaaaaaa")
assert(revision_pairs[1].commit == "1111111")
assert(revision_pairs[3].parent == "2222222")
assert(revision_pairs[3].commit == "3333333")

assert(inspect._github_repository(
  "https://github.com/neovim/neovim.git"
) == "neovim/neovim")
assert(inspect._github_repository(
  "git@github.com:Neovim/Neovim.git"
) == "neovim/neovim")
assert(inspect._github_repository(
  "ssh://git@github.com/neovim/neovim.git"
) == "neovim/neovim")
assert(inspect._github_repository("https://codeberg.org/a/b.git") == nil)
local forge, repository = inspect._forge_repository(
  "https://codeberg.org/ziglang/zig.git"
)
assert(forge == "codeberg")
assert(repository == "ziglang/zig")
forge, repository = inspect._forge_repository(
  "git@codeberg.org:ziglang/zig.git"
)
assert(forge == "codeberg")
assert(repository == "ziglang/zig")
forge, repository = inspect._forge_repository(
  "ssh://git@codeberg.org/ziglang/zig.git"
)
assert(forge == "codeberg")
assert(repository == "ziglang/zig")

local renamed_search_root = vim.fn.tempname()
local renamed_repository = vim.fs.joinpath(
  renamed_search_root,
  "mirrors",
  "editor-source"
)
assert(vim.fn.mkdir(renamed_repository, "p") == 1)
local init_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "init",
}, { text = true }):wait()
assert(init_result.code == 0, init_result.stderr)
local remote_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "remote",
  "add",
  "upstream",
  "https://github.com/neovim/neovim.git",
}, { text = true }):wait()
assert(remote_result.code == 0, remote_result.stderr)
local found_renamed_repository
local found_renamed_remote
inspect._find_local_repository({
  kind = "commit",
  forge = "github",
  owner = "neovim",
  repo = "neovim",
  sha = "0123456789abcdef0123456789abcdef01234567",
  remote_url = "https://github.com/neovim/neovim.git",
}, {
  inspect_repositories = {},
  inspect_search_paths = { renamed_search_root },
}, function(path, remote)
  found_renamed_repository = path
  found_renamed_remote = remote
end)
assert(vim.wait(10000, function()
  return found_renamed_repository ~= nil
end), "renamed local repository was not found")
assert(vim.fs.normalize(found_renamed_repository)
  == vim.fs.normalize(renamed_repository))
assert(found_renamed_remote == "upstream")

local commit_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "-c",
  "user.name=Oculus Test",
  "-c",
  "user.email=oculus@example.invalid",
  "commit",
  "--allow-empty",
  "-m",
  "local identity fixture",
}, { text = true }):wait()
assert(commit_result.code == 0, commit_result.stderr)
local fixture_sha_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "rev-parse",
  "HEAD",
}, { text = true }):wait()
assert(fixture_sha_result.code == 0, fixture_sha_result.stderr)
local fixture_sha = vim.trim(fixture_sha_result.stdout)
local alias_result = vim.system({
  "git",
  "-C",
  renamed_repository,
  "remote",
  "set-url",
  "upstream",
  "git@github-work:neovim/neovim.git",
}, { text = true }):wait()
assert(alias_result.code == 0, alias_result.stderr)
local found_alias_repository
local found_alias_fetch_source
inspect._find_local_repository({
  kind = "commit",
  forge = "github",
  owner = "neovim",
  repo = "neovim",
  sha = fixture_sha,
  remote_url = "https://github.com/neovim/neovim.git",
}, {
  inspect_repositories = {},
  inspect_search_paths = { renamed_search_root },
}, function(path, fetch_source)
  found_alias_repository = path
  found_alias_fetch_source = fetch_source
end)
assert(vim.wait(10000, function()
  return found_alias_repository ~= nil
end), "repository with a custom remote alias was not found")
assert(vim.fs.normalize(found_alias_repository)
  == vim.fs.normalize(renamed_repository))
assert(found_alias_fetch_source
  == "https://github.com/neovim/neovim.git")
assert(vim.fn.delete(renamed_search_root, "rf") == 0)

do
local github = require("oculus.github")
local original_issue = github.issue
github.issue = function(repo, number, _, callback)
  assert(repo == "andrewgilley/oculus.nvim")
  assert(number == 77)
  callback({
    number = number,
    title = "Issue inspect fixture",
    body = "The issue information should open without identifying files.",
    author = "issue-author",
    state = "open",
    html_url = "https://github.com/andrewgilley/oculus.nvim/issues/77",
    created_at = "2026-07-30T12:00:00-04:00",
  })
end
local issue_tabs_before = vim.api.nvim_list_tabpages()
local issue_origin_win = vim.api.nvim_get_current_win()
local issue_origin_number = vim.wo[issue_origin_win].number
local issue_origin_relativenumber = vim.wo[issue_origin_win].relativenumber
vim.wo[issue_origin_win].number = true
vim.wo[issue_origin_win].relativenumber = true
local issue_lifecycle_complete = false
local issue_lifecycle_error
local issue_ok, issue_err = inspect.open(
  "https://github.com/andrewgilley/oculus.nvim/issues/77",
  {
    browser_command = { "test-browser", "{url}" },
    inspect_repositories = {
      ["andrewgilley/oculus.nvim"] = root,
    },
  },
  {
    issue = {
      comment = "The activity comment belongs on the information page.",
    },
  },
  {
    on_progress = function() end,
    on_complete = function(message)
      issue_lifecycle_error = message
      issue_lifecycle_complete = true
    end,
  }
)
assert(issue_ok, issue_err)
assert(vim.wait(10000, function()
  return issue_lifecycle_complete
end), "issue information page was not opened")
assert(not issue_lifecycle_error, issue_lifecycle_error)
github.issue = original_issue
local issue_tabs_after = vim.api.nvim_list_tabpages()
assert(#issue_tabs_after == #issue_tabs_before + 1)
local issue_tab = issue_tabs_after[#issue_tabs_after]
assert(vim.api.nvim_get_current_tabpage() == issue_tab)
assert(#vim.api.nvim_tabpage_list_wins(issue_tab) == 3)
local issue_state = vim.api.nvim_tabpage_get_var(issue_tab, "oculus_inspect")
assert(issue_state.kind == "issue")
assert(issue_state.role == "issue")
assert(issue_state.issue_number == 77)
assert(issue_state.issue_title == "Issue inspect fixture")
local overview_win = vim.api.nvim_get_current_win()
local overview_buf = vim.api.nvim_get_current_buf()
local retained_window_highlight_ns = assert(
  vim.api.nvim_get_namespaces().oculus_window_highlights
)
assert(vim.api.nvim_get_hl_ns({ winid = overview_win })
  == retained_window_highlight_ns)
assert(vim.b[overview_buf].oculus_inspect_overview == true)
assert(vim.api.nvim_win_get_config(overview_win).relative == "editor")
local issue_overview = table.concat(
  vim.api.nvim_buf_get_lines(overview_buf, 0, -1, false),
  "\n"
)
local issue_overview_lines = vim.api.nvim_buf_get_lines(
  overview_buf,
  0,
  -1,
  false
)
assert(issue_overview_lines[#issue_overview_lines - 1]
  == "  Date")
assert(issue_overview_lines[#issue_overview_lines]
  :match("^  %a+ %d%d?, %d%d%d%d$"))
local overview_footer_buf
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(issue_tab)) do
  local candidate = vim.api.nvim_win_get_buf(win)
  if vim.b[candidate].oculus_inspect_overview_footer then
    overview_footer_buf = candidate
    assert(not vim.api.nvim_win_get_config(win).focusable)
    assert(vim.api.nvim_get_hl_ns({ winid = win })
      == retained_window_highlight_ns)
  end
end
assert(overview_footer_buf)
assert(vim.deep_equal(
  vim.api.nvim_buf_get_lines(overview_footer_buf, 0, -1, false),
  {
    "  " .. string.rep(
      "─",
      math.max(1, vim.api.nvim_win_get_width(overview_win) - 4)
    ),
    "  p path   e explain   b browser",
  }
))
assert(issue_overview:find("  Title\n", 1, true))
assert(issue_overview:gsub("%s+", " "):find(
  "Title Issue inspect fixture",
  1,
  true
))
assert(issue_overview:find(
  "  Title\n  Issue inspect fixture",
  1,
  true
))
assert(issue_overview:find("  Description\n", 1, true))
issue_overview = issue_overview:gsub("%s+", " ")
assert(issue_overview:find("The issue information should open", 1, true))
assert(issue_overview:find("without identifying files.", 1, true))
assert(issue_overview:find("Activity comment", 1, true))
assert(issue_overview:find("The activity comment belongs", 1, true))
assert(issue_overview:find("on the information page.", 1, true))
assert(issue_overview:find("@issue%-author"))
assert(issue_overview:find("Issue number", 1, true))
assert(issue_overview:find("#77", 1, true))
assert(issue_overview:find("Status", 1, true))
assert(issue_overview:find("Open", 1, true))
local browser = require("oculus.browser")
local original_browser_open = browser.open
local opened_overview_url
browser.open = function(url, config)
  opened_overview_url = url
  assert(vim.deep_equal(
    config.browser_command,
    { "test-browser", "{url}" }
  ))
  return true
end
local overview_browser_mapping = vim.fn.maparg("b", "n", false, true)
assert(overview_browser_mapping.desc
  == "Open Oculus inspection item in browser")
overview_browser_mapping.callback()
assert(opened_overview_url
  == "https://github.com/andrewgilley/oculus.nvim/issues/77")
browser.open = original_browser_open
local agent = require("oculus.agent")
local original_agent_models = agent.models
local original_agent_explain = agent.explain
local agent_request
local agent_callback
local agent_models_callback
agent.models = function(callback)
  agent_models_callback = callback
  return {}
end
local function finish_agent_models()
  agent_models_callback({
    {
      id = "gpt-5.6-test-agent",
      display_name = "GPT 5.6 Test Agent",
      is_default = false,
    },
    {
      id = "gpt-5.6-test-fast",
      display_name = "GPT 5.6 Test Fast",
      is_default = true,
    },
  })
end
agent.explain = function(request, callback)
  agent_request = request
  agent_callback = callback
  return {}
end
local function finish_agent_explanation()
  agent_callback(table.concat({
    "The issue appears intended to make inspections useful even when",
    "an activity item does not identify particular files.",
  }, "\n"), nil, { model = "gpt-5.6-test-agent" })
end
local function finish_patch_locations()
  agent_callback(vim.json.encode({
    locations = {
      {
        path = "lua/oculus/inspect.lua",
        line = 25,
        reason = "The fileless issue inspection workflow is implemented here.",
      },
      {
        path = "lua/oculus/agent.lua",
        line = 10,
        reason = "Agent context and output handling live here.",
      },
    },
  }), nil, { model = "gpt-5.6-test-agent" })
end
local agent_explanation_mapping = vim.fn.maparg(
  "e",
  "n",
  false,
  true
)
assert(agent_explanation_mapping.desc
  == "Choose Oculus explanation model")
local overview_config = vim.api.nvim_win_get_config(overview_win)
agent_explanation_mapping.callback()
local loading_models_text = table.concat(
  vim.api.nvim_buf_get_lines(overview_buf, 0, -1, false),
  "\n"
)
assert(loading_models_text:find("Agent explanation", 1, true))
assert(not loading_models_text:find(
  "Loading available Codex models",
  1,
  true
))
local model_loading_spinner = vim.api.nvim_buf_get_extmarks(
  overview_buf,
  inspect._overview_ui.agent_spinner_ns,
  0,
  -1,
  { details = true }
)
assert(#model_loading_spinner == 1)
assert(model_loading_spinner[1][4].virt_text[1][1]:match("^ ⠋$"))
assert(vim.o.guicursor == "a:OculusInspectHiddenCursor")
finish_agent_models()
assert(#vim.api.nvim_buf_get_extmarks(
  overview_buf,
  inspect._overview_ui.agent_spinner_ns,
  0,
  -1,
  {}
) == 0)
assert(vim.o.guicursor == "a:OculusInspectHiddenCursor")
local model_win = vim.api.nvim_get_current_win()
local model_buf = vim.api.nvim_get_current_buf()
local model_config = vim.api.nvim_win_get_config(model_win)
assert(model_win == overview_win)
assert(model_buf == overview_buf)
assert(model_config.width == overview_config.width)
assert(model_config.height == overview_config.height)
local model_text = table.concat(
  vim.api.nvim_buf_get_lines(model_buf, 0, -1, false),
  "\n"
)
assert(model_text:find("Agent explanation", 1, true))
assert(model_text:find("GPT 5.6 Test Agent", 1, true))
assert(model_text:find("gpt-5.6-test-fast", 1, true))
assert(not model_text:find("  default", 1, true))
assert(model_text:find("\n  Date\n", 1, true)
  < model_text:find("Agent explanation", 1, true))
local model_selection_mark
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
  model_buf,
  -1,
  0,
  -1,
  { details = true }
)) do
  if mark[4].hl_group == "OculusInspectAgentModelSelected" then
    model_selection_mark = mark
    break
  end
end
assert(model_selection_mark)
assert(vim.api.nvim_win_get_cursor(model_win)[1]
  == model_selection_mark[2] + 1)
local first_explanation_model_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(
  model_buf,
  0,
  -1,
  false
)) do
  if line:find("GPT 5.6 Test Agent", 1, true) then
    first_explanation_model_line = index
    break
  end
end
assert(model_selection_mark[2] + 1 == first_explanation_model_line)
local model_selection_hl = vim.api.nvim_get_hl(0, {
  name = "OculusInspectAgentModelSelected",
  link = false,
})
assert(model_selection_hl.fg)
assert(not model_selection_hl.bg)
local select_agent_model = vim.fn.maparg("<CR>", "n", false, true)
assert(select_agent_model.desc == "Select Oculus overview item")
select_agent_model.callback()
local generating_text = table.concat(
  vim.api.nvim_buf_get_lines(overview_buf, 0, -1, false),
  "\n"
)
assert(generating_text:find(
  "Agent explanation (gpt-5.6-test-agent)",
  1,
  true
))
assert(not generating_text:find("Generating explanation", 1, true))
local spinner_marks = vim.api.nvim_buf_get_extmarks(
  overview_buf,
  inspect._overview_ui.agent_spinner_ns,
  0,
  -1,
  { details = true }
)
assert(#spinner_marks == 1)
assert(spinner_marks[1][4].virt_text[1][1]:match("^ ⠋$"))
local close_generating_explanation = vim.fn.maparg("q", "n", false, true)
close_generating_explanation.callback()
assert(not vim.api.nvim_win_is_valid(overview_win))
finish_agent_explanation()
local reopen_generating_explanation = vim.fn.maparg(
  "<C-t>",
  "n",
  false,
  true
)
reopen_generating_explanation.callback()
overview_win = vim.api.nvim_get_current_win()
overview_buf = vim.api.nvim_get_current_buf()
assert(#vim.api.nvim_buf_get_extmarks(
  overview_buf,
  inspect._overview_ui.agent_spinner_ns,
  0,
  -1,
  {}
) == 0)
local explanation_win = vim.api.nvim_get_current_win()
local explanation_buf = vim.api.nvim_get_current_buf()
local explanation_config = vim.api.nvim_win_get_config(explanation_win)
assert(explanation_win == overview_win)
assert(explanation_buf == overview_buf)
assert(explanation_config.width == overview_config.width)
assert(explanation_config.height == overview_config.height)
assert(vim.deep_equal(explanation_config.row, overview_config.row))
assert(vim.deep_equal(explanation_config.col, overview_config.col))
local explanation_request = agent_request
assert(vim.fs.normalize(explanation_request.cwd) == vim.fs.normalize(root))
assert(explanation_request.model == "gpt-5.6-test-agent")
assert(explanation_request.workflow == "oculus.inspect.explanation")
assert(explanation_request.output_type == "text")
assert(explanation_request.telemetry_attributes["oculus.activity.kind"]
  == "issue")
assert(explanation_request.telemetry_attributes[
  "oculus.activity.changed_file_count"
] == 0)
assert(explanation_request.prompt:find(
  "Repository: andrewgilley/oculus.nvim",
  1,
  true
))
assert(explanation_request.prompt:find(
  "No associated file changes are available",
  1,
  true
))
assert(not explanation_request.prompt:find("at most three", 1, true))
assert(not explanation_request.prompt:find("Return only valid JSON", 1, true))
local explanation_text = table.concat(
  vim.api.nvim_buf_get_lines(explanation_buf, 0, -1, false),
  "\n"
)
assert(explanation_text:find(
  "Agent explanation (gpt-5.6-test-agent)\n",
  1,
  true
))
assert(explanation_text:gsub("%s+", " "):find(
  "The issue appears intended to make inspections useful even when an "
    .. "activity item does not identify particular files.",
  1,
  true
))
assert(not explanation_text:find("Agent suggestion", 1, true))
local explanation_footer_buf
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(issue_tab)) do
  local candidate = vim.api.nvim_win_get_buf(win)
  if vim.b[candidate].oculus_inspect_overview_footer then
    explanation_footer_buf = candidate
    break
  end
end
assert(explanation_footer_buf)
assert(vim.api.nvim_buf_get_lines(
  explanation_footer_buf,
  1,
  2,
  false
)[1]:find("p path", 1, true))
local patch_mapping = vim.fn.maparg("p", "n", false, true)
assert(patch_mapping.desc == "Choose Oculus patch-location model")
patch_mapping.callback()
local patch_loading_text = table.concat(
  vim.api.nvim_buf_get_lines(explanation_buf, 0, -1, false),
  "\n"
)
assert(patch_loading_text:find("Agent suggestion", 1, true))
finish_agent_models()
local patch_model_text = table.concat(
  vim.api.nvim_buf_get_lines(explanation_buf, 0, -1, false),
  "\n"
)
assert(patch_model_text:find("Agent explanation", 1, true))
assert(patch_model_text:find("Agent suggestion", 1, true))
vim.fn.maparg("<CR>", "n", false, true).callback()
local patch_request = agent_request
assert(patch_request.workflow == "oculus.inspect.patch_locations")
assert(patch_request.output_type == "json")
assert(patch_request.telemetry_attributes[
  "oculus.activity.has_file_changes"
] == false)
assert(patch_request.prompt:find("at most three", 1, true))
assert(patch_request.prompt:find("Return only valid JSON", 1, true))
assert(patch_request.prompt:find(
  '"line":123',
  1,
  true
))
assert(patch_request.prompt:find(
  "`" .. vim.fs.basename(root) .. "/` project%-folder prefix"
))
assert(not patch_request.prompt:find(
  "Explain the reason or motivation behind this repository activity.",
  1,
  true
))
finish_patch_locations()
agent.models = original_agent_models
agent.explain = original_agent_explain
explanation_text = table.concat(
  vim.api.nvim_buf_get_lines(explanation_buf, 0, -1, false),
  "\n"
)
local focused_path_footer = vim.api.nvim_buf_get_lines(
  explanation_footer_buf,
  1,
  2,
  false
)[1]
assert(focused_path_footer:find("<Space> toggle", 1, true))
assert(focused_path_footer:find("<CR> open paths", 1, true))
assert(focused_path_footer:sub(-#("<Space> toggle   <CR> open paths"))
  == "<Space> toggle   <CR> open paths")
assert(explanation_text:find(
  "Agent suggestion (gpt-5.6-test-agent)",
  1,
  true
))
assert(explanation_text:find(
  "1. " .. vim.fs.basename(root) .. "/lua/oculus/inspect.lua:25",
  1,
  true
))
assert(explanation_text:find(
  "2. " .. vim.fs.basename(root) .. "/lua/oculus/agent.lua:10",
  1,
  true
))
local location_heading_line
local first_location_line
local second_location_line
for index, line in ipairs(vim.api.nvim_buf_get_lines(
  explanation_buf,
  0,
  -1,
  false
)) do
  if line:find("Agent suggestion", 1, true) then
    location_heading_line = index
  elseif line:find("/lua/oculus/inspect.lua", 1, true) then
    first_location_line = index
  elseif line:find("/lua/oculus/agent.lua", 1, true) then
    second_location_line = index
  end
end
assert(location_heading_line and first_location_line and second_location_line)
assert(vim.api.nvim_buf_get_lines(
  explanation_buf,
  first_location_line,
  first_location_line + 1,
  false
)[1] ~= "")
assert(vim.api.nvim_buf_get_lines(
  explanation_buf,
  second_location_line - 2,
  second_location_line - 1,
  false
)[1] == "")
local heading_underlined
local selected_location_line
local selected_location_col
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
  explanation_buf,
  -1,
  0,
  -1,
  { details = true }
)) do
  if mark[2] + 1 == location_heading_line
    and mark[4].hl_group == "OculusInspectOverviewSection"
  then
    heading_underlined = true
  elseif mark[4].hl_group == "OculusInspectAgentModelSelected" then
    selected_location_line = mark[2] + 1
    selected_location_col = mark[3]
  end
end
assert(heading_underlined)
assert(vim.api.nvim_get_hl(0, {
  name = "OculusInspectOverviewSection",
  link = false,
}).underline == true)
assert(selected_location_line == first_location_line)
assert(selected_location_col == 2)
local unfocus_patch_locations = vim.fn.maparg(
  "<C-c>",
  "n",
  false,
  true
)
assert(unfocus_patch_locations.desc
  == "Unfocus Oculus patch locations")
unfocus_patch_locations.callback()
assert(vim.api.nvim_get_current_win() == explanation_win)
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
  explanation_buf,
  -1,
  0,
  -1,
  { details = true }
)) do
  assert(mark[4].hl_group ~= "OculusInspectAgentModelSelected")
end
local unfocused_footer = vim.api.nvim_buf_get_lines(
  explanation_footer_buf,
  1,
  2,
  false
)[1]
assert(unfocused_footer:find("p path", 1, true))
assert(not unfocused_footer:find("<Space> toggle", 1, true))
assert(not unfocused_footer:find("<CR> open paths", 1, true))
patch_mapping.callback()
assert(vim.api.nvim_get_current_win() == explanation_win)
local refocused_location_line
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
  explanation_buf,
  -1,
  0,
  -1,
  { details = true }
)) do
  if mark[4].hl_group == "OculusInspectAgentModelSelected" then
    refocused_location_line = mark[2] + 1
  end
end
assert(refocused_location_line == first_location_line)
patch_mapping.callback()
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
  explanation_buf,
  -1,
  0,
  -1,
  { details = true }
)) do
  assert(mark[4].hl_group ~= "OculusInspectAgentModelSelected")
end
assert(not vim.api.nvim_buf_get_lines(
  explanation_footer_buf,
  1,
  2,
  false
)[1]:find("<Space> toggle", 1, true))
patch_mapping.callback()
local toggled_location_line
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
  explanation_buf,
  -1,
  0,
  -1,
  { details = true }
)) do
  if mark[4].hl_group == "OculusInspectAgentModelSelected" then
    toggled_location_line = mark[2] + 1
  end
end
assert(toggled_location_line == first_location_line)
vim.fn.maparg("k", "n", false, true).callback()
local moved_location_line
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
  explanation_buf,
  -1,
  0,
  -1,
  { details = true }
)) do
  if mark[4].hl_group == "OculusInspectAgentModelSelected" then
    moved_location_line = mark[2] + 1
  end
end
assert(moved_location_line == second_location_line)
vim.fn.maparg("i", "n", false, true).callback()
assert(explanation_text:gsub("%s+", " "):find(
  "The fileless issue inspection workflow is implemented here.",
  1,
  true
))
assert(vim.api.nvim_win_is_valid(overview_win))

local issue_main_win
local issue_sidebar_win
for _, win in ipairs(vim.api.nvim_tabpage_list_wins(issue_tab)) do
  local buf = vim.api.nvim_win_get_buf(win)
  local state = vim.b[buf].oculus_inspect
  if type(state) == "table" and state.role == "issue" then
    issue_main_win = win
  elseif vim.b[buf].oculus_inspect_sidebar_mode == "files" then
    issue_sidebar_win = win
  end
end
assert(issue_main_win)
assert(not issue_sidebar_win)
local issue_buf = vim.api.nvim_win_get_buf(issue_main_win)
assert(vim.bo[issue_buf].buftype == "")
assert(vim.bo[issue_buf].modifiable)
assert(not vim.bo[issue_buf].readonly)
assert(vim.api.nvim_buf_get_name(issue_buf) == "")
assert(vim.deep_equal(
  vim.api.nvim_buf_get_lines(issue_buf, 0, -1, false),
  { "" }
))
assert(vim.fs.normalize(vim.fn.getcwd()) == vim.fs.normalize(root))
assert(vim.wo[issue_main_win].number)
assert(vim.wo[issue_main_win].relativenumber)
local close_issue_overview = vim.fn.maparg("q", "n", false, true)
assert(close_issue_overview.desc == "Close Oculus Inspect overview")
close_issue_overview.callback()
assert(not vim.api.nvim_win_is_valid(overview_win))
assert(not vim.api.nvim_buf_is_valid(overview_footer_buf))
assert(vim.api.nvim_get_current_win() == issue_main_win)
assert(#vim.api.nvim_tabpage_list_wins(issue_tab) == 1)
local issue_sidebar_toggle = vim.fn.maparg(
  (vim.g.mapleader or "\\") .. "oi",
  "n",
  false,
  true
)
assert(issue_sidebar_toggle.desc == "Toggle Oculus Inspect sidebar")
issue_sidebar_toggle.callback()
assert(#vim.api.nvim_tabpage_list_wins(issue_tab) == 2)
for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(issue_tab)) do
  local candidate_buf = vim.api.nvim_win_get_buf(candidate)
  if vim.b[candidate_buf].oculus_inspect_sidebar_mode == "files" then
    issue_sidebar_win = candidate
    break
  end
end
assert(issue_sidebar_win)
assert(vim.wo[issue_sidebar_win].statusline
  == inspect._inspection_sidebar_statusline_option)
local issue_sidebar_text = table.concat(
  vim.api.nvim_buf_get_lines(
    vim.api.nvim_win_get_buf(issue_sidebar_win),
    0,
    -1,
    false
  ),
  "\n"
)
assert(issue_sidebar_text:find("Issue #77", 1, true))
issue_sidebar_toggle.callback()
assert(not vim.api.nvim_win_is_valid(issue_sidebar_win))
assert(#vim.api.nvim_tabpage_list_wins(issue_tab) == 1)
local issue_source_highlight_ns = vim.api.nvim_create_namespace(
  "oculus_test_issue_source_window"
)
local issue_source_bg = 0x252a33
vim.api.nvim_set_hl(issue_source_highlight_ns, "Normal", {
  fg = 0xd8dee9,
  bg = issue_source_bg,
})
vim.api.nvim_win_set_hl_ns(issue_main_win, issue_source_highlight_ns)
local reopen_issue_overview = vim.fn.maparg("<C-t>", "n", false, true)
assert(reopen_issue_overview.desc == "Toggle Oculus Inspect overview")
reopen_issue_overview.callback()
local restored_overview_win = vim.api.nvim_get_current_win()
assert(vim.api.nvim_get_hl_ns({ winid = restored_overview_win })
  == retained_window_highlight_ns)
local restored_overview_normal = vim.api.nvim_get_hl(
  retained_window_highlight_ns,
  { name = "OculusNormal", link = false }
)
local restored_overview_border = vim.api.nvim_get_hl(
  retained_window_highlight_ns,
  { name = "OculusBorder", link = false }
)
assert(restored_overview_normal.bg == issue_source_bg)
assert(restored_overview_border.bg == issue_source_bg)
local restored_overview_text = table.concat(
  vim.api.nvim_buf_get_lines(0, 0, -1, false),
  "\n"
)
assert(restored_overview_text:find(
  "Agent explanation (gpt-5.6-test-agent)",
  1,
  true
))
assert(restored_overview_text:gsub("%s+", " "):find(
  "The issue appears intended to make inspections useful even when an "
    .. "activity item does not identify particular files.",
  1,
  true
))
assert(restored_overview_text:find(
  "Agent suggestion",
  1,
  true
))
assert(restored_overview_text:find(
  vim.fs.basename(root) .. "/lua/oculus/inspect.lua",
  1,
  true
))
local open_patch_location = vim.fn.maparg("<CR>", "n", false, true)
assert(open_patch_location.desc == "Select Oculus overview item")
local tabs_before_unselected_open = #vim.api.nvim_list_tabpages()
open_patch_location.callback()
assert(vim.api.nvim_win_is_valid(restored_overview_win))
assert(vim.api.nvim_get_current_win() == restored_overview_win)
assert(#vim.api.nvim_list_tabpages() == tabs_before_unselected_open)
local toggle_patch_location = vim.fn.maparg(
  "<Space>",
  "n",
  false,
  true
)
assert(toggle_patch_location.desc == "Toggle Oculus patch location")
toggle_patch_location.callback()
vim.fn.maparg("k", "n", false, true).callback()
toggle_patch_location.callback()
local selected_paths_text = table.concat(
  vim.api.nvim_buf_get_lines(0, 0, -1, false),
  "\n"
)
assert(selected_paths_text:find(
  "[x] 1. " .. vim.fs.basename(root) .. "/lua/oculus/inspect.lua:25",
  1,
  true
))
assert(selected_paths_text:find(
  "[x] 2. " .. vim.fs.basename(root) .. "/lua/oculus/agent.lua:10",
  1,
  true
))
local patch_tabs_before = {}
for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
  patch_tabs_before[tab] = true
end
open_patch_location.callback()
assert(not vim.api.nvim_win_is_valid(restored_overview_win))
local patch_tabs = {}
for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
  if not patch_tabs_before[tab] then
    patch_tabs[#patch_tabs + 1] = tab
  end
end
assert(#patch_tabs == 2)
local patch_code = {}
local patch_sidebars = {}
local shallow_patch_win
for _, tab in ipairs(patch_tabs) do
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if vim.b[buf].oculus_inspect_sidebar_mode == "files" then
      patch_sidebars[tab] = win
    else
      patch_code[tab] = win
      if vim.fs.basename(vim.api.nvim_buf_get_name(buf)) == "agent.lua" then
        shallow_patch_win = win
      end
    end
  end
  assert(patch_code[tab])
  assert(patch_sidebars[tab])
end
assert(shallow_patch_win)
assert(vim.api.nvim_win_get_cursor(shallow_patch_win)[1] == 10)
assert(vim.api.nvim_win_call(
  shallow_patch_win,
  vim.fn.winsaveview
).topline == 1)
local patch_tab = vim.api.nvim_get_current_tabpage()
local patch_win = patch_code[patch_tab]
assert(patch_win)
assert(vim.api.nvim_get_current_win() == patch_win)
local patch_buf = vim.api.nvim_win_get_buf(patch_win)
local motivation_mapping = vim.fn.maparg("<C-s>", "n", false, true)
assert(vim.tbl_isempty(motivation_mapping))
assert(vim.fs.normalize(vim.api.nvim_buf_get_name(patch_buf))
  == vim.fs.normalize(
  vim.fs.joinpath(root, "lua", "oculus", "inspect.lua")
))
assert(vim.bo[patch_buf].buftype == "")
assert(vim.bo[patch_buf].modifiable)
assert(not vim.bo[patch_buf].readonly)
assert(vim.b[patch_buf].oculus_inspect == nil)
assert(vim.wo[patch_win].number == vim.wo[issue_main_win].number)
assert(vim.wo[patch_win].relativenumber
  == vim.wo[issue_main_win].relativenumber)
assert(vim.wo[patch_win].cursorline)
assert(vim.wo[patch_win].cursorlineopt == "line")
assert(vim.wo[patch_win].signcolumn
  == vim.wo[issue_main_win].signcolumn)
assert(not vim.wo[patch_win].winhighlight:find(
  "CursorLine:",
  1,
  true
))
assert(vim.wo[patch_win].statusline == vim.o.statusline)
local patch_highlight_ns = vim.api.nvim_get_hl_ns({ winid = patch_win })
assert(patch_highlight_ns ~= retained_window_highlight_ns)
local selected_patch_cursor = vim.api.nvim_win_get_cursor(patch_win)
assert(selected_patch_cursor[1] == 25)
local selected_patch_line = vim.api.nvim_buf_get_lines(
  patch_buf,
  24,
  25,
  false
)[1] or ""
local selected_patch_nonblank = selected_patch_line:find("%S")
assert(selected_patch_cursor[2]
  == (selected_patch_nonblank and selected_patch_nonblank - 1 or 0))
assert(vim.api.nvim_win_call(
  patch_win,
  vim.fn.winsaveview
).topline == 15)
local selected_patch_view = vim.api.nvim_win_call(
  patch_win,
  vim.fn.winsaveview
)
local patch_sidebar_buf = vim.api.nvim_win_get_buf(
  patch_sidebars[patch_tab]
)
local patch_sidebar_lines = vim.api.nvim_buf_get_lines(
  patch_sidebar_buf,
  0,
  -1,
  false
)
local patch_sidebar_text = table.concat(patch_sidebar_lines, "\n")
assert(patch_sidebar_text:find("inspect.lua", 1, true))
assert(patch_sidebar_text:find("25%-25"))
assert(patch_sidebar_text:find("agent.lua", 1, true))
assert(patch_sidebar_text:find("10%-10"))
assert(vim.wo[patch_sidebars[patch_tab]].cursorline)
assert(vim.wo[patch_sidebars[patch_tab]].cursorlineopt == "line")
assert(not vim.wo[patch_sidebars[patch_tab]].winhighlight:find(
  "CursorLine:",
  1,
  true
))
assert(vim.api.nvim_get_hl_ns({
  winid = patch_sidebars[patch_tab],
}) == patch_highlight_ns)
local active_patch_sidebar_line
for line, text in ipairs(patch_sidebar_lines) do
  if text:find("25%-25") then
    active_patch_sidebar_line = line
    break
  end
end
assert(active_patch_sidebar_line)
assert(vim.api.nvim_win_get_cursor(patch_sidebars[patch_tab])[1]
  == active_patch_sidebar_line)
vim.wo[patch_win].cursorline = false
vim.wo[patch_sidebars[patch_tab]].cursorline = false
vim.wo[patch_win].winhighlight =
  vim.wo[patch_win].winhighlight
    .. ",CursorLine:OculusInspectCursorLine"
vim.wo[patch_sidebars[patch_tab]].winhighlight =
  vim.wo[patch_sidebars[patch_tab]].winhighlight
    .. ",CursorLine:OculusInspectCursorLine"
vim.api.nvim_win_set_hl_ns(
  patch_sidebars[patch_tab],
  retained_window_highlight_ns
)
vim.api.nvim_exec_autocmds("CursorMoved", { buffer = patch_buf })
assert(vim.wo[patch_win].cursorline)
assert(vim.wo[patch_sidebars[patch_tab]].cursorline)
assert(not vim.wo[patch_win].winhighlight:find(
  "CursorLine:",
  1,
  true
))
assert(not vim.wo[patch_sidebars[patch_tab]].winhighlight:find(
  "CursorLine:",
  1,
  true
))
assert(vim.api.nvim_get_hl_ns({
  winid = patch_sidebars[patch_tab],
}) == patch_highlight_ns)
assert(vim.wo[patch_sidebars[patch_tab]].statusline
  == inspect._inspection_sidebar_statusline_option)
local patch_source_highlight_ns = vim.api.nvim_create_namespace(
  "oculus_test_patch_source_window"
)
local patch_source_bg = 0x432d3d
vim.api.nvim_set_hl(patch_source_highlight_ns, "Normal", {
  fg = 0xead7d7,
  bg = patch_source_bg,
})
vim.api.nvim_win_set_hl_ns(patch_win, patch_source_highlight_ns)
local patch_overview_mapping = vim.fn.maparg(
  "<C-t>",
  "n",
  false,
  true
)
assert(patch_overview_mapping.desc == "Toggle Oculus Inspect overview")
patch_overview_mapping.callback()
local patch_overview_win = vim.api.nvim_get_current_win()
local patch_overview_buf = vim.api.nvim_get_current_buf()
assert(vim.b[patch_overview_buf].oculus_inspect_overview == true)
assert(vim.api.nvim_win_get_config(patch_overview_win).relative == "editor")
assert(patch_source_bg ~= issue_source_bg)
assert(vim.api.nvim_get_hl(retained_window_highlight_ns, {
  name = "OculusNormal",
  link = false,
}).bg == patch_source_bg)
vim.wait(20, function()
  return false
end)
local overview_override_ns = vim.api.nvim_create_namespace(
  "oculus_test_overview_filetype_override"
)
vim.api.nvim_set_hl(overview_override_ns, "Normal", {
  bg = 0x151515,
})
vim.api.nvim_win_set_hl_ns(patch_overview_win, overview_override_ns)
assert(vim.api.nvim_get_hl_ns({ winid = patch_overview_win })
  == overview_override_ns)
assert(vim.api.nvim_get_hl(0, {
  name = "OculusNormal",
  link = false,
}).bg == patch_source_bg)
assert(vim.api.nvim_get_hl(0, {
  name = "OculusBorder",
  link = false,
}).bg == patch_source_bg)
vim.api.nvim_exec_autocmds("WinEnter", {
  buffer = patch_overview_buf,
})
assert(vim.wait(1000, function()
  return vim.api.nvim_get_hl_ns({ winid = patch_overview_win })
    == retained_window_highlight_ns
end), "overview highlight namespace was not restored")
assert(vim.api.nvim_get_hl(retained_window_highlight_ns, {
  name = "OculusNormal",
  link = false,
}).bg == patch_source_bg)
for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
  patch_overview_buf,
  -1,
  0,
  -1,
  { details = true }
)) do
  assert(mark[4].hl_group ~= "OculusInspectAgentModelSelected")
end
local patch_overview_footer
for _, candidate_win in ipairs(vim.api.nvim_tabpage_list_wins(
  vim.api.nvim_get_current_tabpage()
)) do
  local candidate_buf = vim.api.nvim_win_get_buf(candidate_win)
  if vim.b[candidate_buf].oculus_inspect_overview_footer then
    patch_overview_footer = vim.api.nvim_buf_get_lines(
      candidate_buf,
      1,
      2,
      false
    )[1]
    break
  end
end
assert(patch_overview_footer)
assert(patch_overview_footer:find("p path", 1, true))
assert(not patch_overview_footer:find("<Space> toggle", 1, true))
assert(not patch_overview_footer:find("<CR> open paths", 1, true))
vim.fn.maparg("<C-t>", "n", false, true).callback()
assert(not vim.api.nvim_win_is_valid(patch_overview_win))
assert(vim.api.nvim_get_current_tabpage() == patch_tab)
assert(vim.api.nvim_get_current_win() == patch_win)
assert(vim.deep_equal(
  vim.api.nvim_win_get_cursor(patch_win),
  selected_patch_cursor
))
assert(vim.deep_equal(vim.api.nvim_win_call(
  patch_win,
  vim.fn.winsaveview
), selected_patch_view))
local next_patch = vim.fn.maparg("<C-Tab>", "n", false, true)
assert(next_patch.desc == "Next Oculus changed chunk")
next_patch.callback()
assert(vim.api.nvim_get_current_tabpage() ~= patch_tab)
local second_patch_tab = vim.api.nvim_get_current_tabpage()
assert(vim.api.nvim_get_current_win() == patch_code[second_patch_tab])
assert(vim.api.nvim_win_get_cursor(patch_code[second_patch_tab])[1] == 1)
vim.fn.maparg("<C-Tab>", "n", false, true).callback()
assert(vim.api.nvim_get_current_tabpage() == second_patch_tab)
assert(vim.api.nvim_win_get_cursor(patch_code[second_patch_tab])[1] == 10)
local previous_patch = vim.fn.maparg("<S-Tab>", "n", false, true)
assert(previous_patch.desc == "Previous Oculus changed chunk")
previous_patch.callback()
assert(vim.api.nvim_get_current_tabpage() == second_patch_tab)
assert(vim.api.nvim_win_get_cursor(patch_code[second_patch_tab])[1] == 1)
vim.fn.maparg("<S-Tab>", "n", false, true).callback()
assert(vim.api.nvim_get_current_tabpage() == patch_tab)
assert(vim.api.nvim_get_current_win() == patch_win)
assert(vim.api.nvim_win_get_cursor(patch_win)[1] == 25)
for index = #patch_tabs, 1, -1 do
  local tab = patch_tabs[index]
  if vim.api.nvim_tabpage_is_valid(tab) then
    vim.api.nvim_set_current_tabpage(tab)
    vim.cmd("tabclose")
  end
end
vim.api.nvim_set_current_tabpage(issue_tab)
vim.api.nvim_set_current_win(issue_main_win)
github.issue = function(repo, number, _, callback)
  assert(repo == "andrewgilley/oculus.nvim")
  assert(number == 78)
  callback({
    number = number,
    title = "Replacement issue inspect fixture",
    body = "This inspection should replace the previous workflow.",
    author = "issue-author",
    state = "open",
    html_url = "https://github.com/andrewgilley/oculus.nvim/issues/78",
    created_at = "2026-08-07T12:00:00-04:00",
  })
end
local replacement_complete = false
local replacement_error
local replacement_closed = false
local replacement_ok, replacement_open_err = inspect.open(
  "https://github.com/andrewgilley/oculus.nvim/issues/78",
  {
    inspect_repositories = {
      ["andrewgilley/oculus.nvim"] = root,
    },
  },
  nil,
  {
    on_progress = function() end,
    on_complete = function(message)
      replacement_error = message
      replacement_complete = true
    end,
    on_closed = function()
      replacement_closed = true
    end,
  }
)
assert(replacement_ok, replacement_open_err)
assert(vim.wait(10000, function()
  return replacement_complete
end), "replacement issue inspection was not opened")
github.issue = original_issue
assert(not replacement_error, replacement_error)
assert(not vim.api.nvim_tabpage_is_valid(issue_tab))
assert(not vim.api.nvim_buf_is_valid(issue_buf))
local replacement_tab = vim.api.nvim_get_current_tabpage()
assert(#vim.api.nvim_list_tabpages() == #issue_tabs_before + 1)
local replacement_state = vim.api.nvim_tabpage_get_var(
  replacement_tab,
  "oculus_inspect"
)
assert(replacement_state.issue_number == 78)
assert(vim.b[vim.api.nvim_get_current_buf()].oculus_inspect_overview == true)
vim.fn.maparg("q", "n", false, true).callback()
assert(not replacement_closed)
vim.cmd("tabclose")
assert(vim.wait(1000, function()
  return replacement_closed
end), "closing the issue inspection did not complete its lifecycle")
vim.api.nvim_set_current_win(issue_origin_win)
vim.wo[issue_origin_win].number = issue_origin_number
vim.wo[issue_origin_win].relativenumber = issue_origin_relativenumber
end

local parent, change = inspect._first_changed_paths("M\tlua/oculus/init.lua")
assert(parent == "lua/oculus/init.lua")
assert(change == "lua/oculus/init.lua")

parent, change = inspect._first_changed_paths(
  "R100\tlua/oculus/old.lua\tlua/oculus/new.lua"
)
assert(parent == "lua/oculus/old.lua")
assert(change == "lua/oculus/new.lua")

parent, change = inspect._first_changed_paths("")
assert(parent == nil)
assert(change == nil)

local changed_files = inspect._parse_changed_files(table.concat({
  "M\tlua/oculus/inspect.lua",
  "A\tlua/oculus/new.lua",
  "D\tlua/oculus/old.lua",
  "R100\tREADME.old.md\tREADME.md",
}, "\n"))
assert(#changed_files == 4)
assert(changed_files[1].status == "M")
assert(changed_files[2].new_path == "lua/oculus/new.lua")
assert(changed_files[4].old_path == "README.old.md")
assert(changed_files[4].new_path == "README.md")
local oil_session = { changes = changed_files }
assert(inspect._oil_entry_status(
  oil_session,
  "change",
  "lua/oculus/new.lua",
  false
) == "A")
assert(inspect._oil_entry_status(
  oil_session,
  "parent",
  "lua/oculus/old.lua",
  false
) == "D")
assert(inspect._oil_entry_status(
  oil_session,
  "change",
  "lua",
  true
) == "directory")
assert(inspect._oil_entry_status(
  oil_session,
  "parent",
  "lua/oculus/new.lua",
  false
) == nil)
assert(inspect._entered_oil_subdirectory(
  root,
  vim.fs.joinpath(root, "lua", "oculus")
))
assert(not inspect._entered_oil_subdirectory(
  vim.fs.joinpath(root, "lua"),
  root
))
vim.api.nvim_buf_set_lines(
  viewport_buf,
  0,
  -1,
  false,
  { "nested", "unchanged.lua", "new.lua", "old.lua" }
)
assert(inspect._first_changed_oil_file_line(
  viewport_buf,
  oil_session,
  "change",
  "lua/oculus",
  {
    get_entry_on_line = function(_, line)
      if line == 1 then
        return { name = "nested", type = "directory" }
      elseif line == 2 then
        return { name = "unchanged.lua", type = "file" }
      elseif line == 3 then
        return { name = "new.lua", type = "file" }
      end
      return { name = "old.lua", type = "file" }
    end,
  }
) == 3)

local hunks = inspect._parse_hunks(table.concat({
  "@@ -10,2 +10,3 @@ local function changed()",
  "@@ -24 +25,0 @@",
  "@@ -30,0 +31,4 @@",
}, "\n"))
assert(#hunks == 3)
assert(hunks[1].old_start == 10)
assert(hunks[1].old_count == 2)
assert(hunks[1].new_start == 10)
assert(hunks[1].new_count == 3)
assert(hunks[2].old_count == 1)
assert(hunks[2].new_count == 0)
assert(hunks[3].old_count == 0)
assert(hunks[3].new_count == 4)
local focused_lines, focused_start = inspect._focused_change_lines(
  { "one", "old first", "middle", "old second", "tail" },
  { "one", "new first a", "new first b", "middle", "new second", "tail" },
  {
    old_start = 4,
    old_count = 1,
    new_start = 5,
    new_count = 1,
  }
)
assert(vim.deep_equal(focused_lines, {
  "one",
  "old first",
  "middle",
  "new second",
  "tail",
}))
assert(focused_start == 4)
focused_lines, focused_start = inspect._focused_change_lines(
  { "one", "old a", "old b", "tail" },
  { "one", "new a", "new b", "new c", "tail" },
  {
    old_start = 2,
    old_count = 2,
    new_start = 2,
    new_count = 3,
  }
)
assert(vim.deep_equal(focused_lines, {
  "one",
  "new a",
  "new b",
  "new c",
  "tail",
}))
assert(focused_start == 2)
focused_lines, focused_start = inspect._focused_change_lines(
  { "one", "tail" },
  { "one", "inserted", "tail" },
  {
    old_start = 1,
    old_count = 0,
    new_start = 2,
    new_count = 1,
  }
)
assert(vim.deep_equal(focused_lines, {
  "one",
  "inserted",
  "tail",
}))
assert(focused_start == 2)
focused_lines, focused_start = inspect._focused_change_lines(
  { "one", "removed", "tail" },
  { "one", "tail" },
  {
    old_start = 2,
    old_count = 1,
    new_start = 2,
    new_count = 0,
  }
)
assert(vim.deep_equal(focused_lines, { "one", "tail" }))
assert(focused_start == 2)
focused_lines, focused_start = inspect._focused_change_lines(
  { "" },
  { "new one", "new two" },
  {
    old_start = 0,
    old_count = 0,
    new_start = 1,
    new_count = 2,
  }
)
assert(vim.deep_equal(focused_lines, { "new one", "new two" }))
assert(focused_start == 1)
local jump_lines = inspect._change_lines(hunks)
assert(vim.deep_equal(jump_lines, { 10, 25, 31 }))
assert(vim.deep_equal(
  inspect._change_lines(hunks, "parent"),
  { 10, 24, 30 }
))

local missing_root = vim.env.OCULUS_INSPECT_TEST_MISSING_ROOT
if missing_root then
  local original_select = vim.ui.select
  local prompted = false
  vim.ui.select = function(items, select_opts, on_choice)
    prompted = true
    assert(select_opts.prompt:match("Download it to"))
    on_choice(items[2])
  end
  local source_root = vim.fs.joinpath(missing_root, "source")
  local tabs_before_missing = #vim.api.nvim_list_tabpages()
  local missing_error
  local missing_progress = 0
  local ok, err = inspect.open(
    "https://github.com/oculus/missing/commit/"
      .. "0123456789abcdef0123456789abcdef01234567",
    {
      inspect_search_paths = { source_root },
      inspect_repositories = {},
    },
    nil,
    {
      on_progress = function()
        missing_progress = missing_progress + 1
      end,
      on_complete = function(message)
        missing_error = message
      end,
    }
  )
  assert(ok, err)
  assert(vim.wait(10000, function()
    return missing_error ~= nil
  end), "missing local repository did not stop inspection")
  vim.ui.select = original_select
  assert(prompted)
  assert(missing_progress > 0)
  assert(#vim.api.nvim_list_tabpages() == tabs_before_missing)
  assert(missing_error:match("download was declined"))
  assert(vim.uv.fs_stat(vim.fs.joinpath(source_root, "missing")) == nil)
  assert(vim.uv.fs_stat(vim.fs.joinpath(missing_root, "repositories")) == nil)
end

local download_root = vim.env.OCULUS_INSPECT_TEST_DOWNLOAD_ROOT
local download_source = vim.env.OCULUS_INSPECT_TEST_DOWNLOAD_SOURCE

local existing_repository = vim.fs.normalize(vim.fn.getcwd())
local existing_repository_result
local existing_repository_error
inspect._offer_repository_download({
  owner = "andrewgilley",
  repo = vim.fs.basename(existing_repository),
  remote_url = "https://github.com/andrewgilley/oculus.nvim.git",
}, {
  inspect_search_paths = { vim.fs.dirname(existing_repository) },
}, function(path, err)
  existing_repository_result = path
  existing_repository_error = err
end)
assert(existing_repository_result, existing_repository_error)
assert(vim.fs.normalize(existing_repository_result) == existing_repository)

if download_root and download_source then
  local original_select = vim.ui.select
  local prompted = false
  vim.ui.select = function(items, select_opts, on_choice)
    prompted = true
    assert(select_opts.prompt:match("Download it to"))
    on_choice(items[1])
  end
  local downloaded
  local download_err
  inspect._offer_repository_download({
    owner = "oculus",
    repo = "downloaded",
    remote_url = download_source,
  }, {
    inspect_search_paths = { download_root },
  }, function(path, err)
    downloaded = path
    download_err = err
  end)
  assert(vim.wait(30000, function()
    return downloaded ~= nil or download_err ~= nil
  end), "repository download prompt did not finish")
  vim.ui.select = original_select
  assert(prompted)
  assert(downloaded, download_err)
  assert(downloaded == vim.fs.joinpath(download_root, "downloaded"))
  assert(vim.uv.fs_stat(vim.fs.joinpath(downloaded, ".git")))
end

local integration_root = vim.env.OCULUS_INSPECT_TEST_ROOT
local integration_sha = vim.env.OCULUS_INSPECT_TEST_SHA
local integration_url = vim.env.OCULUS_INSPECT_TEST_URL
local expected_pair_count = tonumber(
  vim.env.OCULUS_INSPECT_TEST_PAIR_COUNT
)
local expected_commit_count = tonumber(
  vim.env.OCULUS_INSPECT_TEST_COMMIT_COUNT
)
if integration_root and (integration_sha or integration_url) then
  vim.keymap.set("n", "<C-i>", "10k", {
    silent = true,
    desc = "Configured Ctrl-I",
  })
  local integration_repository =
    vim.env.OCULUS_INSPECT_TEST_REPOSITORY or "oculus/test"
  local integration_source = vim.env.OCULUS_INSPECT_TEST_SOURCE
  local integration_search_root =
    vim.env.OCULUS_INSPECT_TEST_SEARCH_ROOT
  local expected_source_root =
    vim.env.OCULUS_INSPECT_TEST_EXPECT_SOURCE_ROOT
      or integration_source
  local expect_no_worktrees =
    vim.env.OCULUS_INSPECT_TEST_NO_WORKTREES == "1"
  local expect_no_external_state =
    vim.env.OCULUS_INSPECT_TEST_NO_EXTERNAL_STATE == "1"
  local verify_revision_content =
    vim.env.OCULUS_INSPECT_TEST_VERIFY_CONTENT == "1"
  local integration_cwd = vim.env.OCULUS_INSPECT_TEST_CWD
  local repositories = {}
  local integration_is_pull_request = integration_url
    and integration_url:match("/pulls?/%d+")
  if integration_source then
    repositories[integration_repository] = integration_source
  end
  if integration_cwd then
    vim.api.nvim_set_current_dir(integration_cwd)
  end
  local initial_tab = vim.api.nvim_get_current_tabpage()
  local initial_tab_count = #vim.api.nvim_list_tabpages()
  local initial_lazyredraw = vim.o.lazyredraw
  local activity_closed_after_tabs_ready = false
  local oculus_window = require("oculus.window")
  local original_window_close = oculus_window.close
  oculus_window.close = function(...)
    oculus_window.close = original_window_close
    local ready_tabs = vim.api.nvim_list_tabpages()
    assert(vim.api.nvim_get_current_tabpage() == initial_tab)
    assert(#ready_tabs > initial_tab_count)
    assert((#ready_tabs - initial_tab_count) % 2 == 0)
    assert(vim.o.lazyredraw)
    for index = initial_tab_count + 1, #ready_tabs do
      local state = vim.api.nvim_tabpage_get_var(
        ready_tabs[index],
        "oculus_inspect"
      )
      assert(state.loading == false)
      assert(#vim.api.nvim_tabpage_list_wins(ready_tabs[index]) == 2)
    end
    activity_closed_after_tabs_ready = true
    return original_window_close(...)
  end
  local loading_frames = 0
  local lifecycle_complete = false
  local lifecycle_error
  vim.wo.number = true
  vim.wo.relativenumber = true
  local ok, err = inspect.open(
    integration_url
      or (
        "https://github.com/" .. integration_repository
        .. "/commit/" .. integration_sha
    ),
    {
      inspect_repositories = repositories,
      inspect_search_paths = integration_search_root
          and { integration_search_root }
        or {},
      inspect_sidebar_width = 0.30,
      inspect_old_version = "gS",
      inspect_new_version = "gD",
    },
    nil,
    {
      on_progress = function()
        loading_frames = loading_frames + 1
      end,
      on_complete = function(message)
        lifecycle_error = message
        lifecycle_complete = true
      end,
    }
  )
  assert(ok, err)
  assert(#vim.api.nvim_list_tabpages() == initial_tab_count)
  assert(loading_frames > 0)

  local inspection_error
  local inspection_finished = vim.wait(180000, function()
    local current_tabs = vim.api.nvim_list_tabpages()
    if #current_tabs <= initial_tab_count
      or (#current_tabs - initial_tab_count) % 2 ~= 0
    then
      return false
    end
    for index = 2, #current_tabs do
      local state_ok, state = pcall(
        vim.api.nvim_tabpage_get_var,
        current_tabs[index],
        "oculus_inspect"
      )
      if state_ok and state.error then
        inspection_error = state.error
        return true
      end
      if not state_ok or state.loading ~= false or state.commit == nil then
        return false
      end
    end
    return lifecycle_complete
  end)
  assert(inspection_finished, "inspection tabs were not opened")
  assert(not lifecycle_error, lifecycle_error)
  assert(not inspection_error, inspection_error)
  assert(activity_closed_after_tabs_ready)
  assert(vim.o.lazyredraw == initial_lazyredraw)

  local tabs = vim.api.nvim_list_tabpages()
  local pair_count = (#tabs - 1) / 2
  assert(pair_count >= 1)
  if expected_pair_count then
    assert(pair_count == expected_pair_count)
  end
  local commit_indices = {}
  local next_file_indices = {}
  local buffers = {}
  local sidebar_buf
  local sidebar_width
  local function inspection_window(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if type(vim.b[buf].oculus_inspect) == "table" then
        return win
      end
    end
  end
  local function sidebar_window(tab)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.bo[buf].filetype == "oculus-inspect-files" then
        return win
      end
    end
  end
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  local initial_parent_win = assert(inspection_window(tabs[2]))
  assert(vim.api.nvim_get_current_win() == initial_parent_win)
  for pair_index = 1, pair_count do
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2]
    ) == 2)
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2 + 1]
    ) == 2)
    assert(sidebar_window(tabs[pair_index * 2]))
    assert(sidebar_window(tabs[pair_index * 2 + 1]))
  end
  local initial_sidebar_toggle
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(
    vim.api.nvim_win_get_buf(initial_parent_win),
    "n"
  )) do
    if mapping.desc == "Toggle Oculus Inspect sidebar"
    then
      initial_sidebar_toggle = mapping
      break
    end
  end
  assert(initial_sidebar_toggle)
  assert(initial_sidebar_toggle.lhs
    == (vim.g.mapleader or "\\") .. "oi")
  do
    vim.api.nvim_set_current_tabpage(tabs[2])
    vim.api.nvim_set_current_win(initial_parent_win)
    vim.cmd("botright vsplit")
    local foreign_win = vim.api.nvim_get_current_win()
    local foreign_buf = vim.api.nvim_create_buf(false, true)
    vim.api.nvim_win_set_buf(foreign_win, foreign_buf)
    vim.bo[foreign_buf].filetype = "aerial"
    vim.wo[foreign_win].winfixwidth = true
    assert(vim.wait(10000, function()
      for pair_index = 1, pair_count do
        if sidebar_window(tabs[pair_index * 2])
          or sidebar_window(tabs[pair_index * 2 + 1])
        then
          return false
        end
      end
      return true
    end), "Inspect sidebar remained open beside Aerial")
    vim.api.nvim_win_close(foreign_win, true)
    assert(vim.wait(10000, function()
      for pair_index = 1, pair_count do
        if not sidebar_window(tabs[pair_index * 2])
          or not sidebar_window(tabs[pair_index * 2 + 1])
        then
          return false
        end
      end
      return true
    end), "Inspect sidebar was not restored after closing Aerial")
    vim.api.nvim_buf_delete(foreign_buf, { force = true })
  end
  for pair_index = 1, pair_count do
    local old_tab = tabs[pair_index * 2]
    local new_tab = tabs[pair_index * 2 + 1]
    assert(#vim.api.nvim_tabpage_list_wins(old_tab) == 2)
    assert(#vim.api.nvim_tabpage_list_wins(new_tab) == 2)
    local old_main_win = assert(inspection_window(old_tab))
    local new_main_win = assert(inspection_window(new_tab))
    assert(vim.wo[old_main_win].number == true)
    assert(vim.wo[old_main_win].relativenumber == true)
    assert(vim.wo[new_main_win].number == true)
    assert(vim.wo[new_main_win].relativenumber == true)
    assert(vim.wo[old_main_win].cursorline)
    assert(vim.wo[new_main_win].cursorline)
    assert(vim.wo[old_main_win].cursorlineopt == "line")
    assert(vim.wo[new_main_win].cursorlineopt == "line")
    assert(not vim.wo[old_main_win].winhighlight:find(
      "CursorLine:OculusCursorLine",
      1,
      true
    ))
    assert(not vim.wo[new_main_win].winhighlight:find(
      "CursorLine:OculusCursorLine",
      1,
      true
    ))
    local old_sidebar_win = assert(sidebar_window(old_tab))
    local new_sidebar_win = assert(sidebar_window(new_tab))
    local old_sidebar_buf = vim.api.nvim_win_get_buf(old_sidebar_win)
    local new_sidebar_buf = vim.api.nvim_win_get_buf(new_sidebar_win)
    sidebar_buf = sidebar_buf or old_sidebar_buf
    sidebar_width = sidebar_width
      or vim.api.nvim_win_get_width(old_sidebar_win)
    assert(old_sidebar_buf == sidebar_buf)
    assert(new_sidebar_buf == sidebar_buf)
    assert(vim.api.nvim_win_get_width(old_sidebar_win) == sidebar_width)
    assert(vim.api.nvim_win_get_width(new_sidebar_win) == sidebar_width)
    assert(sidebar_width == inspect._inspect_sidebar_width(
      0.30,
      vim.o.columns
    ))
    assert(vim.wo[old_sidebar_win].cursorline)
    assert(vim.wo[new_sidebar_win].cursorline)
    assert(vim.wo[old_sidebar_win].cursorlineopt == "line")
    assert(vim.wo[new_sidebar_win].cursorlineopt == "line")
    assert(vim.wo[old_sidebar_win].statusline
      == inspect._inspection_sidebar_statusline_option)
    assert(vim.wo[new_sidebar_win].statusline
      == inspect._inspection_sidebar_statusline_option)
    assert(inspect._inspection_statusline(old_sidebar_win) == "")
    assert(inspect._inspection_statusline(new_sidebar_win) == "")
    assert(vim.wo[old_main_win].winhighlight:find(
      "NormalNC:Normal",
      1,
      true
    ))
    assert(vim.wo[new_main_win].winhighlight:find(
      "NormalNC:Normal",
      1,
      true
    ))
    assert(vim.wo[old_sidebar_win].winhighlight:find(
      "NormalNC:Normal",
      1,
      true
    ))
    assert(vim.wo[new_sidebar_win].winhighlight:find(
      "NormalNC:Normal",
      1,
      true
    ))
    assert(vim.api.nvim_win_get_position(old_sidebar_win)[2]
      > vim.api.nvim_win_get_position(old_main_win)[2])
    assert(vim.api.nvim_win_get_position(new_sidebar_win)[2]
      > vim.api.nvim_win_get_position(new_main_win)[2])
    local old_state = vim.api.nvim_tabpage_get_var(
      old_tab,
      "oculus_inspect"
    )
    local new_state = vim.api.nvim_tabpage_get_var(
      new_tab,
      "oculus_inspect"
    )
    assert(old_state.role == (integration_is_pull_request and "old" or "parent"))
    assert(new_state.role == "change")
    assert(old_state.pair_index == pair_index)
    assert(new_state.pair_index == pair_index)
    assert(old_state.commit_index == new_state.commit_index)
    assert(old_state.file_index == new_state.file_index)
    assert(old_state.file_count == new_state.file_count)
    assert(old_state.status == new_state.status)
    assert(old_state.file)
    assert(new_state.file)
    if expected_source_root then
      local expected_root = vim.fs.normalize(expected_source_root):lower()
      assert(vim.fs.normalize(old_state.repository):lower() == expected_root)
      assert(vim.fs.normalize(new_state.repository):lower() == expected_root)
      assert(vim.fs.normalize(old_state.source_path):lower():sub(
        1,
        #expected_root
      ) == expected_root)
      assert(vim.fs.normalize(new_state.source_path):lower():sub(
        1,
        #expected_root
      ) == expected_root)
    end
    commit_indices[old_state.commit_index] = true
    local expected_file_index =
      next_file_indices[old_state.commit_index] or 1
    assert(old_state.file_index == expected_file_index)
    assert(old_state.file_index <= old_state.file_count)
    next_file_indices[old_state.commit_index] = expected_file_index + 1
    local old_buf = vim.api.nvim_win_get_buf(old_main_win)
    local new_buf = vim.api.nvim_win_get_buf(new_main_win)
    assert(not buffers[old_buf])
    buffers[old_buf] = true
    assert(not buffers[new_buf])
    buffers[new_buf] = true
    local old_name = vim.api.nvim_buf_get_name(old_buf)
    local new_name = vim.api.nvim_buf_get_name(new_buf)
    assert(not old_name:lower():match("oculus%-inspect"))
    assert(not new_name:lower():match("oculus%-inspect"))
    assert(not old_name:match(" Old "))
    assert(not old_name:match(" New "))
    assert(not new_name:match(" Old "))
    assert(not new_name:match(" New "))
    assert(vim.b[old_buf].oculus_inspect_repository)
    assert(vim.b[new_buf].oculus_inspect_repository)
    if expected_source_root then
      local old_cwd = vim.fn.getcwd(
        -1,
        vim.api.nvim_tabpage_get_number(old_tab)
      )
      local new_cwd = vim.fn.getcwd(
        -1,
        vim.api.nvim_tabpage_get_number(new_tab)
      )
      assert(
        vim.fs.normalize(old_cwd):lower()
          == vim.fs.normalize(old_state.directory):lower(),
        ("old inspection cwd %s did not match %s")
          :format(old_cwd, old_state.directory)
      )
      assert(
        vim.fs.normalize(new_cwd):lower()
          == vim.fs.normalize(new_state.directory):lower(),
        ("new inspection cwd %s did not match %s")
          :format(new_cwd, new_state.directory)
      )
    end
  end
  if expected_commit_count then
    assert(vim.tbl_count(commit_indices) == expected_commit_count)
  end
  assert(sidebar_buf)
  local sidebar_lines = vim.api.nvim_buf_get_lines(
    sidebar_buf,
    0,
    -1,
    false
  )
  local file_lines = {}
  local chunk_lines = 0
  for line_number, line in ipairs(sidebar_lines) do
    local branch =
      line:match("^  ├─ %d+%-%d+ %([+-]?%d+%)$")
        or line:match("^  └─ %d+%-%d+ %([+-]?%d+%)$")
        or line:match("^  ├─ %d+%-%d+$")
        or line:match("^  └─ %d+%-%d+$")
    if branch then
      chunk_lines = chunk_lines + 1
    else
      file_lines[#file_lines + 1] = line_number
      assert(line:match("^• "))
      assert(line:match(" P C $"))
      assert(not line:match("^%d+%. "))
      assert(vim.fn.strdisplaywidth(line) == sidebar_width)
      local displayed_file = line
        :gsub("%s+P C%s*$", "")
        :gsub("^• ", "")
        :gsub("^…", "")
      local _, separators = displayed_file:gsub("/", "")
      assert(separators == 0)
    end
  end
  assert(#file_lines == pair_count)
  assert(chunk_lines >= pair_count)
  assert(#sidebar_lines == pair_count + chunk_lines)
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  local first_sidebar_win = assert(sidebar_window(tabs[2]))
  assert(vim.api.nvim_win_get_cursor(first_sidebar_win)[1]
    == file_lines[1] + 1)
  assert(vim.api.nvim_win_call(
    first_sidebar_win,
    vim.fn.winsaveview
  ).topline == 1)
  if expect_no_worktrees then
    assert(vim.uv.fs_stat(vim.fs.joinpath(
      integration_root,
      "worktrees"
    )) == nil)
  end
  if expect_no_external_state then
    assert(
      vim.uv.fs_stat(integration_root) == nil,
      "inspect created state outside the project repository"
    )
  end
  local parent_state = vim.api.nvim_tabpage_get_var(
    tabs[2],
    "oculus_inspect"
  )
  local change_state = vim.api.nvim_tabpage_get_var(
    tabs[3],
    "oculus_inspect"
  )
  assert(parent_state.role
    == (integration_is_pull_request and "old" or "parent"))
  assert(change_state.role == "change")
  if integration_sha and not integration_url then
    assert(change_state.commit == integration_sha)
  end

  local parent_win = assert(inspection_window(tabs[2]))
  local change_win = assert(inspection_window(tabs[3]))
  local parent_buf = vim.api.nvim_win_get_buf(parent_win)
  local change_buf = vim.api.nvim_win_get_buf(change_win)
  assert(vim.bo[parent_buf].modifiable)
  assert(not vim.bo[parent_buf].readonly)
  assert(vim.bo[change_buf].modifiable)
  assert(not vim.bo[change_buf].readonly)
  do
    local initial_lines = vim.api.nvim_buf_get_lines(
      change_buf,
      0,
      -1,
      false
    )
    vim.api.nvim_set_current_win(change_win)
    local undo_cursor = vim.api.nvim_win_get_cursor(change_win)
    local undo_view = vim.api.nvim_win_call(
      change_win,
      vim.fn.winsaveview
    )
    vim.cmd("silent undo")
    assert(vim.deep_equal(
      vim.api.nvim_buf_get_lines(change_buf, 0, -1, false),
      initial_lines
    ))
    vim.api.nvim_win_set_cursor(change_win, undo_cursor)
    vim.api.nvim_win_call(change_win, function()
      vim.fn.winrestview(undo_view)
    end)
  end
  vim.g.oculus_test_statusline_path = vim.fs.basename(
    vim.fs.normalize(change_state.repository)
  ) .. "/" .. change_state.file:gsub("\\", "/")
  assert(vim.b[change_buf].oculus_inspect_statusline_path
    == vim.g.oculus_test_statusline_path)
  assert(vim.wo[change_win].statusline
    == inspect._inspection_statusline_option)
  assert(inspect._inspection_statusline(change_win):find(
    vim.g.oculus_test_statusline_path,
    1,
    true
  ))
  assert(inspect._inspection_statusline(change_win):find(
    "%d+,%d+"
  ))
  vim.g.oculus_test_statusline_path = nil
  if verify_revision_content then
    assert(expected_source_root)
    local content_state = change_state.status == "A"
        and change_state
      or parent_state
    local content_buf = change_state.status == "A"
        and change_buf
      or parent_buf
    local result = vim.system({
      "git",
      "-C",
      expected_source_root,
      "show",
      content_state.commit .. ":" .. content_state.file,
    }, { text = true }):wait()
    assert(result.code == 0, result.stderr)
    assert(vim.deep_equal(
      vim.api.nvim_buf_get_lines(content_buf, 0, -1, false),
      inspect._blob_lines(result.stdout)
    ))
  end
  local namespaces = vim.api.nvim_get_namespaces()
  local signs = namespaces.oculus_inspect_changes
  assert(signs)
  local parent_marks = vim.api.nvim_buf_get_extmarks(
    parent_buf,
    signs,
    0,
    -1,
    { details = true }
  )
  assert(vim.wo[parent_win].signcolumn == "yes")
  local change_marks = vim.api.nvim_buf_get_extmarks(
    change_buf,
    signs,
    0,
    -1,
    {}
  )
  assert(vim.wo[change_win].signcolumn == "yes")
  if change_state.status == "A" then
    assert(#parent_marks == 0)
    assert(#change_marks == 0)
  else
    assert(#parent_marks > 0)
    local parent_sign = vim.trim(parent_marks[1][4].sign_text)
    assert(parent_sign == "-" or parent_sign == "+")
    assert(parent_marks[1][4].sign_hl_group
      == (parent_sign == "-"
          and "OculusInspectRemoved"
        or "OculusInspectAdded"))
    assert(#change_marks > 0)
    assert(vim.api.nvim_win_get_cursor(parent_win)[1] == math.min(
      parent_marks[1][2] + 1,
      vim.api.nvim_buf_line_count(parent_buf)
    ))
  end
  local jump_maps = vim.api.nvim_buf_get_keymap(change_buf, "n")
  local previous_mapped = false
  local next_mapped = false
  local toggle_mapped = false
  local next_file_mapping
  local sidebar_tab_mapped = false
  local sidebar_leader_toggle
  for _, mapping in ipairs(jump_maps) do
    if mapping.desc == "Previous Oculus change" then
      previous_mapped = mapping.lhs == "<C-Left>"
    elseif mapping.desc == "Previous Oculus changed chunk" then
      previous_mapped = mapping
    elseif mapping.desc == "Next Oculus change" then
      next_mapped = mapping.lhs == "<C-Right>"
    elseif mapping.desc == "Next Oculus changed chunk" then
      toggle_mapped = mapping
    elseif mapping.desc == "Open Oculus old file version" then
      jump_maps.old_version = mapping
    elseif mapping.desc == "Open Oculus new file version" then
      jump_maps.new_version = mapping
    elseif mapping.desc == "Next Oculus changed file" then
      next_file_mapping = mapping
    elseif mapping.desc == "Toggle Oculus Inspect sidebar" then
      if mapping.lhs == "<Tab>" then
        sidebar_tab_mapped = true
      else
        sidebar_leader_toggle = mapping
      end
    elseif mapping.desc == "Toggle Oculus Inspect overview" then
      if mapping.lhs == "<C-T>" then
        jump_maps.main_ctrl_t_overview = mapping
      else
        jump_maps.main_overview = mapping
      end
    end
  end
  assert(previous_mapped and previous_mapped.lhs == "<S-Tab>")
  assert(not next_mapped)
  assert(toggle_mapped and toggle_mapped.lhs == "<C-Tab>")
  local configured_ctrl_i = vim.api.nvim_buf_call(change_buf, function()
    return vim.fn.maparg("<C-i>", "n", false, true)
  end)
  assert(configured_ctrl_i.buffer == 0)
  assert(configured_ctrl_i.rhs == "10k")
  assert(jump_maps.old_version and jump_maps.old_version.lhs == "gS")
  assert(jump_maps.new_version and jump_maps.new_version.lhs == "gD")
  assert(not next_file_mapping)
  assert(not sidebar_tab_mapped)
  assert(sidebar_leader_toggle
    and sidebar_leader_toggle.lhs
      == (vim.g.mapleader or "\\") .. "oi")
  assert(jump_maps.main_overview
    and jump_maps.main_overview.lhs
      == (vim.g.mapleader or "\\") .. "op")
  assert(jump_maps.main_ctrl_t_overview
    and jump_maps.main_ctrl_t_overview.lhs == "<C-T>")
  do
    vim.api.nvim_set_current_tabpage(tabs[3])
    vim.api.nvim_set_current_win(change_win)
    local cursor = vim.api.nvim_win_get_cursor(change_win)
    local view = vim.api.nvim_win_call(change_win, vim.fn.winsaveview)
    local guicursor = vim.o.guicursor
    jump_maps.main_ctrl_t_overview.callback()
    local overview_win = vim.api.nvim_get_current_win()
    local overview_buf = vim.api.nvim_get_current_buf()
    assert(vim.b[overview_buf].oculus_inspect_overview == true)
    assert(vim.o.guicursor == "a:OculusInspectHiddenCursor")
    local overview_down = vim.fn.maparg("k", "n", false, true)
    local overview_up = vim.fn.maparg("i", "n", false, true)
    local overview_ctrl_i = vim.fn.maparg("<C-i>", "n", false, true)
    local overview_page_down = vim.fn.maparg("<C-k>", "n", false, true)
    assert(overview_down.desc == "Scroll Oculus Inspect overview down")
    assert(overview_up.desc == "Scroll Oculus Inspect overview up")
    assert(overview_ctrl_i.desc == "Configured Ctrl-I")
    assert(overview_ctrl_i.rhs == "10k")
    assert(overview_page_down.desc
      == "Scroll Oculus Inspect overview down 10 lines")
    vim.api.nvim_win_set_height(overview_win, 4)
    local overview_content_height = vim.api.nvim_win_get_height(overview_win)
    for _, candidate in ipairs(vim.api.nvim_tabpage_list_wins(tabs[3])) do
      local candidate_buf = vim.api.nvim_win_get_buf(candidate)
      if vim.b[candidate_buf].oculus_inspect_overview_footer then
        overview_content_height = overview_content_height
          - vim.api.nvim_win_get_height(candidate)
        break
      end
    end
    overview_content_height = math.max(1, overview_content_height)
    local overview_topline = vim.fn.winsaveview().topline
    overview_down.callback()
    assert(vim.fn.winsaveview().topline > overview_topline)
    overview_up.callback()
    assert(vim.fn.winsaveview().topline == overview_topline)
    overview_page_down.callback()
    local overview_max_topline = math.max(
      1,
      vim.api.nvim_buf_line_count(overview_buf)
        - overview_content_height
        + 2
    )
    assert(vim.fn.winsaveview().topline
      == math.min(overview_max_topline, overview_topline + 10))
    for _ = 1, 10 do
      overview_up.callback()
    end
    assert(vim.fn.winsaveview().topline == overview_topline)
    for _ = 1, vim.api.nvim_buf_line_count(overview_buf) + 4 do
      overview_down.callback()
    end
    assert(vim.fn.winsaveview().topline == math.max(
      1,
      vim.api.nvim_buf_line_count(overview_buf)
        - overview_content_height
        + 2
    ))
    overview_topline = vim.fn.winsaveview().topline
    overview_down.callback()
    assert(vim.fn.winsaveview().topline == overview_topline)
    local overscrolled_view = vim.fn.winsaveview()
    overscrolled_view.topline = vim.api.nvim_buf_line_count(overview_buf)
    vim.fn.winrestview(overscrolled_view)
    vim.api.nvim_exec_autocmds("WinScrolled", {
      pattern = tostring(overview_win),
    })
    assert(vim.fn.winsaveview().topline == overview_topline)
    vim.api.nvim_win_set_height(
      overview_win,
      require("oculus.window").window_config({}).height - 3
    )
    for _ = 1, vim.api.nvim_buf_line_count(overview_buf) do
      overview_down.callback()
    end
    local restored_overview_view = vim.fn.winsaveview()
    vim.api.nvim_set_current_win(change_win)
    assert(vim.o.guicursor == guicursor)
    vim.api.nvim_set_current_win(overview_win)
    assert(vim.o.guicursor == "a:OculusInspectHiddenCursor")
    local close_mapping = vim.fn.maparg("q", "n", false, true)
    local ctrl_t_close_mapping =
      vim.fn.maparg("<C-t>", "n", false, true)
    assert(close_mapping.desc == "Close Oculus Inspect overview")
    assert(ctrl_t_close_mapping.desc
      == "Close Oculus Inspect overview")
    vim.api.nvim_set_hl(0, "OculusInspectAdded", { fg = 1, bg = 2 })
    vim.api.nvim_set_hl(0, "OculusInspectRemoved", { fg = 1, bg = 2 })
    ctrl_t_close_mapping.callback()
    assert(not vim.api.nvim_win_is_valid(overview_win))
    assert(not vim.api.nvim_buf_is_valid(overview_buf))
    assert(vim.o.guicursor == guicursor)
    assert(vim.api.nvim_get_current_win() == change_win)
    assert(vim.wo[change_win].signcolumn == "yes")
    for name, expected in pairs({
      OculusInspectAdded = { fg = 0xdcfce7, bg = 0x166534 },
      OculusInspectRemoved = { fg = 0xfee2e2, bg = 0x991b1b },
    }) do
      local highlight = vim.api.nvim_get_hl(0, {
        name = name,
        link = false,
      })
      assert(highlight.fg == expected.fg)
      assert(highlight.bg == expected.bg)
    end
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      change_buf,
      signs,
      0,
      -1,
      { details = true }
    )) do
      assert(mark[4].sign_hl_group == "OculusInspectAdded"
        or mark[4].sign_hl_group == "OculusInspectRemoved")
    end
    assert(vim.deep_equal(
      vim.api.nvim_win_get_cursor(change_win),
      cursor
    ))
    assert(vim.deep_equal(
      vim.api.nvim_win_call(change_win, vim.fn.winsaveview),
      view
    ))
    jump_maps.main_ctrl_t_overview.callback()
    overview_win = vim.api.nvim_get_current_win()
    overview_buf = vim.api.nvim_get_current_buf()
    assert(vim.b[overview_buf].oculus_inspect_overview == true)
    assert(vim.deep_equal(
      vim.fn.winsaveview(),
      restored_overview_view
    ))
    vim.fn.maparg("<C-t>", "n", false, true).callback()
    assert(vim.api.nvim_get_current_win() == change_win)
  end
  local function assert_cursor_at_first_nonblank(win)
    local cursor = vim.api.nvim_win_get_cursor(win)
    local text = vim.api.nvim_buf_get_lines(
      vim.api.nvim_win_get_buf(win),
      cursor[1] - 1,
      cursor[1],
      false
    )[1] or ""
    local first_nonblank = text:find("%S")
    assert(cursor[2] == (first_nonblank and first_nonblank - 1 or 0))
  end
  vim.g.oculus_test_main_tab_pair =
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.pair_index
  vim.g.oculus_test_main_tab_chunk =
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_index
  toggle_mapped.callback()
  assert(vim.bo[change_buf].modifiable)
  assert(not vim.bo[change_buf].readonly)
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(vim.api.nvim_get_current_win() == change_win)
  assert_cursor_at_first_nonblank(change_win)
  do
    local active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
    assert(active.pair_index == vim.g.oculus_test_main_tab_pair)
    assert(active.chunk_index == vim.g.oculus_test_main_tab_chunk + 1)
    assert(active.role == "change")
    local active_sidebar_win = assert(sidebar_window(
      vim.api.nvim_get_current_tabpage()
    ))
    assert(vim.api.nvim_win_get_cursor(active_sidebar_win)[1]
      == file_lines[active.pair_index] + active.chunk_index)
  end
  previous_mapped = vim.fn.maparg("<S-Tab>", "n", false, true)
  assert(previous_mapped.desc == "Previous Oculus changed chunk")
  previous_mapped.callback()
  assert_cursor_at_first_nonblank(
    vim.api.nvim_get_current_win()
  )
  do
    local active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
    assert(active.pair_index == vim.g.oculus_test_main_tab_pair)
    assert(active.chunk_index == vim.g.oculus_test_main_tab_chunk)
    local active_sidebar_win = assert(sidebar_window(
      vim.api.nvim_get_current_tabpage()
    ))
    assert(vim.api.nvim_win_get_cursor(active_sidebar_win)[1]
      == file_lines[active.pair_index] + active.chunk_index)
  end
  toggle_mapped.callback()
  vim.g.oculus_test_main_tab_pair = nil
  vim.g.oculus_test_main_tab_chunk = nil
  vim.g.oculus_test_main_file_pair =
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.pair_index
  vim.g.oculus_test_main_file_chunks =
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_count
  while vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_index
    < vim.g.oculus_test_main_file_chunks
  do
    vim.fn.maparg("<C-Tab>", "n", false, true).callback()
  end
  vim.fn.maparg("<C-Tab>", "n", false, true).callback()
  do
    local active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
    assert(active.pair_index
      == (vim.g.oculus_test_main_file_pair % pair_count) + 1)
    assert(active.chunk_index == nil)
    local active_sidebar_win = assert(sidebar_window(
      vim.api.nvim_get_current_tabpage()
    ))
    assert(vim.api.nvim_win_get_cursor(active_sidebar_win)[1]
      == file_lines[active.pair_index])
  end
  vim.fn.maparg("<C-Tab>", "n", false, true).callback()
  do
    local active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
    assert(active.pair_index
      == (vim.g.oculus_test_main_file_pair % pair_count) + 1)
    assert(active.chunk_index == 1)
    local active_sidebar_win = assert(sidebar_window(
      vim.api.nvim_get_current_tabpage()
    ))
    assert(vim.api.nvim_win_get_cursor(active_sidebar_win)[1]
      == file_lines[active.pair_index] + 1)
  end
  vim.fn.maparg("<S-Tab>", "n", false, true).callback()
  do
    local active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
    assert(active.pair_index
      == (vim.g.oculus_test_main_file_pair % pair_count) + 1)
    assert(active.chunk_index == nil)
    local active_sidebar_win = assert(sidebar_window(
      vim.api.nvim_get_current_tabpage()
    ))
    assert(vim.api.nvim_win_get_cursor(active_sidebar_win)[1]
      == file_lines[active.pair_index])
  end
  vim.fn.maparg("<S-Tab>", "n", false, true).callback()
  do
    local active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
    assert(active.pair_index == vim.g.oculus_test_main_file_pair)
    assert(active.chunk_index == vim.g.oculus_test_main_file_chunks)
    local active_sidebar_win = assert(sidebar_window(
      vim.api.nvim_get_current_tabpage()
    ))
    assert(vim.api.nvim_win_get_cursor(active_sidebar_win)[1]
      == file_lines[active.pair_index] + active.chunk_index)
  end
  vim.g.oculus_test_main_file_pair = nil
  vim.g.oculus_test_main_file_chunks = nil

  local sidebar_tab_from_sidebar = false
  local sidebar_leader_toggle_from_sidebar
  local sidebar_open_mapping
  local sidebar_overview_mapping
  for _, mapping in ipairs(vim.api.nvim_buf_get_keymap(
    sidebar_buf,
    "n"
  )) do
    if mapping.desc == "Toggle Oculus Inspect sidebar" then
      if mapping.lhs == "<Tab>" then
        sidebar_tab_from_sidebar = true
      else
        sidebar_leader_toggle_from_sidebar = mapping
      end
    elseif mapping.desc == "Open Oculus Inspect sidebar item" then
      sidebar_open_mapping = mapping
    elseif mapping.desc == "Open Oculus old file version" then
      jump_maps.sidebar_old_version = mapping
    elseif mapping.desc == "Open Oculus new file version" then
      jump_maps.sidebar_new_version = mapping
    elseif mapping.desc == "Toggle Oculus Inspect overview" then
      if mapping.lhs == "<C-T>" then
        jump_maps.sidebar_ctrl_t_overview = mapping
      else
        sidebar_overview_mapping = mapping
      end
    elseif mapping.desc == "Next Oculus changed file" then
      next_file_mapping = mapping
    elseif mapping.desc == "Next Oculus changed chunk" then
      toggle_mapped = mapping
    elseif mapping.desc == "Previous Oculus changed chunk" then
      previous_mapped = mapping
    end
  end
  assert(not sidebar_tab_from_sidebar)
  assert(sidebar_leader_toggle_from_sidebar
    and sidebar_leader_toggle_from_sidebar.lhs
      == (vim.g.mapleader or "\\") .. "oi")
  assert(sidebar_open_mapping
    and sidebar_open_mapping.lhs == "<CR>")
  assert(jump_maps.sidebar_old_version
    and jump_maps.sidebar_old_version.lhs == "gS")
  assert(jump_maps.sidebar_new_version
    and jump_maps.sidebar_new_version.lhs == "gD")
  local sidebar_configured_ctrl_i = vim.api.nvim_buf_call(
    sidebar_buf,
    function()
      return vim.fn.maparg("<C-i>", "n", false, true)
    end
  )
  assert(sidebar_configured_ctrl_i.buffer == 0)
  assert(sidebar_configured_ctrl_i.rhs == "10k")
  assert(sidebar_overview_mapping
    and sidebar_overview_mapping.lhs
      == (vim.g.mapleader or "\\") .. "op")
  assert(jump_maps.sidebar_ctrl_t_overview
    and jump_maps.sidebar_ctrl_t_overview.lhs == "<C-T>")
  assert(not next_file_mapping)
  assert(toggle_mapped and toggle_mapped.lhs == "<C-Tab>")
  assert(previous_mapped and previous_mapped.lhs == "<S-Tab>")

  vim.api.nvim_set_current_tabpage(tabs[pair_count * 2 + 1])
  local overview_sidebar_win =
    assert(sidebar_window(tabs[pair_count * 2 + 1]))
  vim.api.nvim_set_current_win(overview_sidebar_win)
  vim.g.oculus_test_chunk =
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_index or 0
  vim.g.oculus_test_chunk_count =
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_count
  assert(vim.g.oculus_test_chunk_count > 0)
  for _ = vim.g.oculus_test_chunk + 1, vim.g.oculus_test_chunk_count do
    toggle_mapped.callback()
  end
  assert(
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.pair_index
      == pair_count
  )
  assert(
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_index
      == vim.g.oculus_test_chunk_count
  )
  toggle_mapped.callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(vim.api.nvim_get_current_win()
    == assert(sidebar_window(tabs[3])))
  assert(vim.api.nvim_win_get_cursor(
    assert(sidebar_window(tabs[3]))
  )[1] == file_lines[1])
  assert(vim.api.nvim_win_get_cursor(change_win)[1] == 1)
  assert(vim.api.nvim_win_call(
    change_win,
    vim.fn.winsaveview
  ).topline == 1)
  assert(vim.b[sidebar_buf].oculus_inspect_sidebar_active.pair_index == 1)
  assert(vim.b[sidebar_buf].oculus_inspect_sidebar_active.role == "change")
  previous_mapped.callback()
  assert(vim.api.nvim_get_current_tabpage()
    == tabs[pair_count * 2 + 1])
  assert(vim.api.nvim_get_current_win()
    == assert(sidebar_window(tabs[pair_count * 2 + 1])))
  assert(
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.pair_index
      == pair_count
  )
  assert(
    vim.b[sidebar_buf].oculus_inspect_sidebar_active.chunk_index
      == vim.g.oculus_test_chunk_count
  )
  toggle_mapped.callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  vim.g.oculus_test_chunk = nil
  vim.g.oculus_test_chunk_count = nil
  overview_sidebar_win = assert(sidebar_window(tabs[3]))
  vim.api.nvim_set_current_win(overview_sidebar_win)
  local overview_saved = {
    sidebar_win = overview_sidebar_win,
    sidebar_cursor = vim.api.nvim_win_get_cursor(overview_sidebar_win),
    sidebar_view = vim.fn.winsaveview(),
    main_cursor = vim.api.nvim_win_get_cursor(change_win),
    main_view = vim.api.nvim_win_call(change_win, vim.fn.winsaveview),
  }
  assert(vim.api.nvim_get_current_buf() == sidebar_buf)
  sidebar_overview_mapping.callback()
  overview_sidebar_win = vim.api.nvim_get_current_win()
  overview_saved.buf = vim.api.nvim_get_current_buf()
  overview_saved.config =
    vim.api.nvim_win_get_config(overview_sidebar_win)
  overview_saved.close_mapping =
    vim.fn.maparg("q", "n", false, true)
  assert(overview_saved.close_mapping.desc
    == "Close Oculus Inspect overview")
  assert(
    overview_sidebar_win ~= overview_saved.sidebar_win,
    vim.inspect({
      current_win = overview_sidebar_win,
      sidebar_win = overview_saved.sidebar_win,
      current_buf = overview_saved.buf,
      sidebar_buf = sidebar_buf,
    })
  )
  assert(overview_saved.buf ~= sidebar_buf)
  assert(vim.b[overview_saved.buf].oculus_inspect_overview == true)
  assert(vim.b[sidebar_buf].oculus_inspect_sidebar_mode == "files")
  assert(vim.api.nvim_win_get_width(overview_saved.sidebar_win)
    == sidebar_width)
  assert(overview_saved.config.relative == "editor")
  do
    local main_overview_config =
      require("oculus.window").window_config({})
    assert(overview_saved.config.width
      == main_overview_config.width - 12)
    assert(overview_saved.config.height
      == main_overview_config.height - 3)
    assert(overview_saved.config.row
      == main_overview_config.row + 2)
    assert(overview_saved.config.col
      == main_overview_config.col + 6)
  end
  assert(overview_saved.config.title == nil
    or overview_saved.config.title == "")
  local overview_text = table.concat(
    vim.api.nvim_buf_get_lines(overview_saved.buf, 0, -1, false),
    "\n"
  )
  assert(not overview_text:match("\n$"))
  assert(overview_text:match("^  Title\n"))
  assert(overview_text:find("\n  Description\n", 1, true))
  assert(overview_text:find("\n  Author\n", 1, true))
  assert(overview_text:find("\n  URL\n", 1, true))
  assert(not overview_text:find("Repository", 1, true))
  assert(not overview_text:find("\nCommit\n", 1, true))
  assert(not overview_text:find("Authored", 1, true))
  assert(not overview_text:find("Changes", 1, true))
  assert(not overview_text:find("changed files", 1, true))
  overview_saved.section_marks = vim.api.nvim_buf_get_extmarks(
    overview_saved.buf,
    vim.api.nvim_get_namespaces().oculus_inspect_sidebar,
    0,
    -1,
    { details = true }
  )
  assert(#overview_saved.section_marks >= 4)
  for _, mark in ipairs(overview_saved.section_marks) do
    assert(mark[3] == 2)
    assert(mark[4].hl_group
      == "OculusInspectOverviewSection")
  end
  assert(vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectOverviewSection", link = false }
  ).underline == true)
  local overview_line_count =
    vim.api.nvim_buf_line_count(overview_saved.buf)
  vim.api.nvim_win_set_cursor(
    overview_sidebar_win,
    {
      math.min(overview_line_count, 2),
      0,
    }
  )
  vim.api.nvim_exec_autocmds("CursorMoved", {
    buffer = overview_saved.buf,
  })
  vim.wait(50, function()
    return false
  end)
  assert(vim.deep_equal(
    vim.api.nvim_win_get_cursor(change_win),
    overview_saved.main_cursor
  ))
  assert(vim.deep_equal(
    vim.api.nvim_win_call(change_win, vim.fn.winsaveview),
    overview_saved.main_view
  ))
  overview_saved.close_mapping.callback()
  assert(not vim.api.nvim_win_is_valid(overview_sidebar_win))
  assert(not vim.api.nvim_buf_is_valid(overview_saved.buf))
  assert(vim.b[sidebar_buf].oculus_inspect_sidebar_mode == "files")
  assert(vim.api.nvim_get_current_win() == overview_saved.sidebar_win)
  assert(vim.api.nvim_win_get_width(overview_saved.sidebar_win)
    == sidebar_width)
  assert(vim.deep_equal(
    vim.api.nvim_win_get_cursor(overview_saved.sidebar_win),
    overview_saved.sidebar_cursor
  ))
  assert(vim.fn.winsaveview().topline
    == overview_saved.sidebar_view.topline)
  assert(vim.deep_equal(
    vim.api.nvim_win_get_cursor(change_win),
    overview_saved.main_cursor
  ))
  assert(vim.api.nvim_buf_get_lines(
    sidebar_buf,
    file_lines[1] - 1,
    file_lines[1],
    false
  )[1]:find("• ", 1, true))

  vim.api.nvim_set_current_win(assert(sidebar_window(tabs[3])))
  vim.g.oculus_test_toggled_sidebar_state = {
    cursor = vim.api.nvim_win_get_cursor(0),
    view = vim.fn.winsaveview(),
    lines = vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false),
    active = vim.deepcopy(
      vim.b[sidebar_buf].oculus_inspect_sidebar_active
    ),
  }
  sidebar_leader_toggle_from_sidebar.callback()
  assert(vim.api.nvim_get_current_win() == change_win)
  for pair_index = 1, pair_count do
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2]
    ) == 1)
    assert(#vim.api.nvim_tabpage_list_wins(
      tabs[pair_index * 2 + 1]
    ) == 1)
  end
  vim.fn.maparg("gS", "n", false, true).callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  assert(vim.api.nvim_get_current_win() == parent_win)
  assert(sidebar_window(tabs[2]) == nil)
  vim.fn.maparg("gD", "n", false, true).callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(vim.api.nvim_get_current_win() == change_win)
  assert(sidebar_window(tabs[3]) == nil)
  vim.g.oculus_test_toggle_entered_tabs = {}
  vim.g.oculus_test_toggle_tab_enter =
    vim.api.nvim_create_autocmd("TabEnter", {
      callback = function()
        local entered = vim.g.oculus_test_toggle_entered_tabs
        entered[#entered + 1] = vim.api.nvim_get_current_tabpage()
        vim.g.oculus_test_toggle_entered_tabs = entered
      end,
    })
  sidebar_leader_toggle.callback()
  vim.api.nvim_del_autocmd(vim.g.oculus_test_toggle_tab_enter)
  assert(vim.api.nvim_get_current_win() == change_win)
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(#vim.g.oculus_test_toggle_entered_tabs == 0)
  vim.g.oculus_test_restored_sidebar_win = assert(sidebar_window(tabs[3]))
  assert(vim.deep_equal(
    vim.api.nvim_win_get_cursor(vim.g.oculus_test_restored_sidebar_win),
    vim.g.oculus_test_toggled_sidebar_state.cursor
  ))
  assert(vim.api.nvim_win_call(
    vim.g.oculus_test_restored_sidebar_win,
    vim.fn.winsaveview
  ).topline == vim.g.oculus_test_toggled_sidebar_state.view.topline)
  assert(vim.deep_equal(
    vim.api.nvim_buf_get_lines(sidebar_buf, 0, -1, false),
    vim.g.oculus_test_toggled_sidebar_state.lines
  ))
  assert(vim.deep_equal(
    vim.b[sidebar_buf].oculus_inspect_sidebar_active,
    vim.g.oculus_test_toggled_sidebar_state.active
  ))
  for pair_index = 1, pair_count do
    for _, tab in ipairs({
      tabs[pair_index * 2],
      tabs[pair_index * 2 + 1],
    }) do
      if tab ~= tabs[3] then
        assert(sidebar_window(tab) == nil)
      end
    end
  end
  vim.fn.maparg("gS", "n", false, true).callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  assert(vim.api.nvim_get_current_win() == parent_win)
  assert(sidebar_window(tabs[2]) ~= nil)
  vim.fn.maparg("gD", "n", false, true).callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(vim.api.nvim_get_current_win() == change_win)
  assert(sidebar_window(tabs[3]) ~= nil)
  for pair_index = 1, pair_count do
    for _, tab in ipairs({
      tabs[pair_index * 2],
      tabs[pair_index * 2 + 1],
    }) do
      vim.api.nvim_set_current_tabpage(tab)
      assert(#vim.api.nvim_tabpage_list_wins(tab) == 2)
      assert(vim.api.nvim_win_get_buf(assert(sidebar_window(tab)))
        == sidebar_buf)
    end
  end
  vim.g.oculus_test_toggled_sidebar_state = nil
  vim.g.oculus_test_toggle_entered_tabs = nil
  vim.g.oculus_test_toggle_tab_enter = nil
  vim.g.oculus_test_restored_sidebar_win = nil

  vim.api.nvim_set_current_tabpage(tabs[2])
  vim.api.nvim_set_current_win(parent_win)
  local sidebar_active = vim.b[sidebar_buf]
    .oculus_inspect_sidebar_active
  assert(sidebar_active.pair_index == 1)
  assert(sidebar_active.role == "parent")
  assert(sidebar_active.chunk_count >= 1)
  local initial_sidebar_win = assert(sidebar_window(tabs[2]))
  assert(vim.api.nvim_get_current_win() == parent_win)
  assert(vim.api.nvim_win_get_cursor(initial_sidebar_win)[1]
    == file_lines[1])
  local sidebar_signs = vim.api.nvim_get_namespaces()
    .oculus_inspect_sidebar
  assert(sidebar_signs)
  assert(#vim.api.nvim_buf_get_extmarks(
    sidebar_buf,
    sidebar_signs,
    0,
    -1,
    {}
  ) == pair_count * 2)
  local file_line_lookup = {}
  for _, line in ipairs(file_lines) do
    file_line_lookup[line] = true
  end
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    sidebar_buf,
    sidebar_signs,
    0,
    -1,
    { details = true }
  )) do
    assert(file_line_lookup[mark[2] + 1])
    assert(mark[4].line_hl_group == nil)
    assert(mark[4].hl_group
      ~= "OculusInspectSidebarChunkActive")
    assert(mark[4].hl_group
      ~= "OculusInspectSidebarCurrent")
  end
  local normal_hl =
    vim.api.nvim_get_hl(0, { name = "Normal", link = false })
  local parent_hl = vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectSidebarParent", link = false }
  )
  local change_hl = vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectSidebarChange", link = false }
  )
  assert(parent_hl.fg
    == vim.api.nvim_get_hl(
      0,
      { name = "DiagnosticError", link = false }
    ).fg)
  assert(change_hl.fg == 0x00c853)
  assert(parent_hl.bg == normal_hl.bg)
  assert(change_hl.bg == normal_hl.bg)
  local parent_active_hl = vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectSidebarParentActive", link = false }
  )
  local change_active_hl = vim.api.nvim_get_hl(
    0,
    { name = "OculusInspectSidebarChangeActive", link = false }
  )
  assert(parent_active_hl.underline == true)
  assert(change_active_hl.underline == true)
  assert(change_active_hl.fg == 0x00c853)
  assert(parent_active_hl.bold ~= true)
  assert(change_active_hl.bold ~= true)
  assert(parent_hl.bold ~= true)
  assert(change_hl.bold ~= true)
  assert(parent_hl.underline ~= true)
  assert(change_hl.underline ~= true)
  local function sidebar_role_groups(line)
    local groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
      sidebar_buf,
      sidebar_signs,
      { line - 1, 0 },
      { line - 1, -1 },
      { details = true }
    )) do
      local group = mark[4].hl_group
      if group then
        groups[group] = true
      end
    end
    return groups
  end
  local visible_role_groups = sidebar_role_groups(file_lines[1])
  assert(visible_role_groups.OculusInspectSidebarParentActive)
  assert(visible_role_groups.OculusInspectSidebarChange)
  assert(not visible_role_groups.OculusInspectSidebarChangeActive)
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(parent_buf)):lower()
    == vim.fs.normalize(
      inspect._inspection_buffer_name(parent_state)
    ):lower())
  local initial_cursor = vim.api.nvim_win_get_cursor(change_win)
  local initial_line = vim.api.nvim_buf_get_lines(
    change_buf,
    initial_cursor[1] - 1,
    initial_cursor[1],
    false
  )[1] or ""
  if initial_cursor[1] >= 10 then
    assert(initial_cursor[2] == math.max(0, #initial_line - 1))
  end
  local initial_view = vim.api.nvim_win_call(
    change_win,
    vim.fn.winsaveview
  )
  if initial_cursor[1] >= 10 then
    assert(initial_view.topline == math.max(1, initial_cursor[1] - 10))
  end
  local initial_parent_cursor = vim.api.nvim_win_get_cursor(parent_win)
  local initial_parent_line = vim.api.nvim_buf_get_lines(
    parent_buf,
    initial_parent_cursor[1] - 1,
    initial_parent_cursor[1],
    false
  )[1] or ""
  if initial_parent_cursor[1] >= 10 then
    assert(initial_parent_cursor[2]
      == math.max(0, #initial_parent_line - 1))
  end
  local initial_parent_view = vim.api.nvim_win_call(
    parent_win,
    vim.fn.winsaveview
  )
  if initial_parent_cursor[1] >= 10 then
    assert(initial_parent_view.topline
      == math.max(1, initial_parent_cursor[1] - 10))
  end
  local sidebar_parent_win = assert(sidebar_window(tabs[2]))
  vim.api.nvim_set_current_win(sidebar_parent_win)
  vim.api.nvim_win_set_cursor(
    sidebar_parent_win,
    { file_lines[1], 0 }
  )
  vim.api.nvim_exec_autocmds("CursorMoved", {
    buffer = sidebar_buf,
  })
  assert(vim.wait(1000, function()
    return vim.api.nvim_get_current_tabpage() == tabs[2]
      and vim.api.nvim_get_current_win() == sidebar_parent_win
      and vim.api.nvim_win_get_cursor(parent_win)[1] == 1
      and vim.api.nvim_win_call(
        parent_win,
        vim.fn.winsaveview
      ).topline == 1
  end), "sidebar file did not open at the top in the main pane")
  local selected_chunk =
    sidebar_active.chunk_count > 1 and 2 or 1
  local selected_chunk_line = file_lines[1] + selected_chunk
  vim.api.nvim_win_set_cursor(
    sidebar_parent_win,
    { selected_chunk_line, 0 }
  )
  vim.api.nvim_exec_autocmds("CursorMoved", {
    buffer = sidebar_buf,
  })
  assert(vim.wait(1000, function()
    local active = vim.b[sidebar_buf]
      .oculus_inspect_sidebar_active
    return vim.api.nvim_get_current_tabpage() == tabs[2]
      and vim.api.nvim_get_current_win() == sidebar_parent_win
      and active.chunk_index == selected_chunk
  end), "sidebar chunk did not open in the main pane")
  local selected_parent_cursor = vim.api.nvim_win_get_cursor(parent_win)
  local selected_parent_line = selected_parent_cursor[1]
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.chunk_index == selected_chunk)
  local selected_view = vim.api.nvim_win_call(
    parent_win,
    vim.fn.winsaveview
  )
  if selected_parent_line >= 10 then
    assert(selected_view.topline
      == math.max(1, selected_parent_line - 10))
  end
  vim.api.nvim_exec_autocmds("WinScrolled", {
    pattern = tostring(parent_win),
  })
  assert(vim.api.nvim_get_current_win() == sidebar_parent_win)
  local parent_sidebar_view = vim.fn.winsaveview()
  jump_maps.sidebar_new_version.callback()
  local sidebar_change_win = assert(sidebar_window(tabs[3]))
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(vim.api.nvim_get_current_win() == sidebar_change_win)
  assert(vim.api.nvim_win_get_cursor(sidebar_change_win)[1]
    == selected_chunk_line)
  assert(vim.api.nvim_win_get_cursor(sidebar_change_win)[2]
    == math.max(0, (vim.api.nvim_buf_get_lines(
      sidebar_buf,
      selected_chunk_line - 1,
      selected_chunk_line,
      false
    )[1]:find("%S") or 1) - 1))
  do
    local cursor = vim.api.nvim_win_get_cursor(change_win)
    assert(cursor[1] == selected_parent_cursor[1])
    assert_cursor_at_first_nonblank(change_win)
  end
  assert(vim.fn.winsaveview().topline
    == parent_sidebar_view.topline)
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.pair_index == 1)
  assert(sidebar_active.role == "change")
  jump_maps.sidebar_old_version.callback()
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  assert(vim.api.nvim_get_current_win() == sidebar_parent_win)
  assert(vim.api.nvim_win_get_cursor(sidebar_parent_win)[1]
    == selected_chunk_line)
  do
    local cursor = vim.api.nvim_win_get_cursor(parent_win)
    assert(vim.deep_equal(cursor, selected_parent_cursor))
  end
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.role == "parent")
  sidebar_open_mapping.callback()
  assert(vim.api.nvim_get_current_win() == parent_win)
  assert(vim.api.nvim_win_get_cursor(parent_win)[1]
    == selected_parent_line)
  assert(vim.api.nvim_win_get_cursor(sidebar_parent_win)[1]
    == selected_chunk_line)
  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    sidebar_buf,
    sidebar_signs,
    0,
    -1,
    { details = true }
  )) do
    assert(mark[4].line_hl_group ~= "CursorLine")
  end
  assert(vim.wo[sidebar_parent_win].cursorline)
  vim.api.nvim_feedkeys(
    "gD",
    "x",
    false
  )
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  do
    local cursor = vim.api.nvim_win_get_cursor(change_win)
    assert(cursor[1] == selected_parent_cursor[1])
    assert_cursor_at_first_nonblank(change_win)
  end
  assert(vim.wait(1000, function()
    local active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
    return type(active) == "table" and active.role == "change"
  end))
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.pair_index == 1)
  assert(sidebar_active.role == "change")
  visible_role_groups = sidebar_role_groups(file_lines[1])
  assert(visible_role_groups.OculusInspectSidebarParent)
  assert(visible_role_groups.OculusInspectSidebarChangeActive)
  assert(not visible_role_groups.OculusInspectSidebarParentActive)
  vim.api.nvim_feedkeys(
    "gS",
    "x",
    false
  )
  assert(vim.api.nvim_get_current_tabpage() == tabs[2])
  do
    local cursor = vim.api.nvim_win_get_cursor(parent_win)
    assert(vim.deep_equal(cursor, selected_parent_cursor))
  end
  sidebar_active = vim.b[sidebar_buf].oculus_inspect_sidebar_active
  assert(sidebar_active.role == "parent")
  vim.api.nvim_feedkeys(
    "gD",
    "x",
    false
  )
  assert(vim.api.nvim_get_current_tabpage() == tabs[3])
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(change_buf)):lower()
    == vim.fs.normalize(
      inspect._inspection_buffer_name(change_state)
    ):lower())
  assert(vim.fs.normalize(vim.api.nvim_buf_get_name(parent_buf)):lower()
    == vim.fs.normalize(
      inspect._inspection_buffer_name(parent_state)
    ):lower())
  if pair_count > 1 then
    vim.api.nvim_set_current_tabpage(tabs[3])
    vim.api.nvim_set_current_win(assert(sidebar_window(tabs[3])))
    vim.api.nvim_win_set_cursor(0, { file_lines[2], 0 })
    local source_sidebar_view = vim.fn.winsaveview()
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = sidebar_buf,
    })
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_tabpage() == tabs[4]
    end), "sidebar cursor did not open the second changed file")
    assert(vim.api.nvim_get_current_win()
      == assert(sidebar_window(tabs[4])))
    vim.wait(50, function()
      return false
    end)
    local second_sidebar_win = assert(sidebar_window(tabs[4]))
    assert(vim.api.nvim_get_current_win() == second_sidebar_win)
    assert(
      vim.api.nvim_win_get_cursor(second_sidebar_win)[1]
        == file_lines[2],
      ("second sidebar cursor was %d instead of file row %d")
        :format(
          vim.api.nvim_win_get_cursor(second_sidebar_win)[1],
          file_lines[2]
        )
    )
    local second_sidebar_view = vim.fn.winsaveview()
    assert(second_sidebar_view.topline == source_sidebar_view.topline)
    if file_lines[2] > source_sidebar_view.topline then
      assert(second_sidebar_view.topline < file_lines[2])
    end
    local second_main_win = assert(inspection_window(tabs[4]))
    vim.api.nvim_exec_autocmds("WinScrolled", {
      pattern = tostring(second_main_win),
    })
    assert(vim.api.nvim_get_current_win() == second_sidebar_win)
    sidebar_active = vim.b[sidebar_buf]
      .oculus_inspect_sidebar_active
    assert(sidebar_active.pair_index == 2)
    assert(sidebar_active.role == "parent")
    local second_first_parent_line =
      vim.api.nvim_win_get_cursor(second_main_win)[1]
    sidebar_open_mapping.callback()
    assert(vim.api.nvim_get_current_win() == second_main_win)
    assert(vim.api.nvim_win_get_cursor(second_main_win)[1]
      == second_first_parent_line)
    assert(vim.api.nvim_win_get_cursor(second_sidebar_win)[1]
      == file_lines[2])
    vim.api.nvim_set_current_win(second_sidebar_win)
    vim.api.nvim_win_set_cursor(0, { file_lines[1], 0 })
    vim.api.nvim_exec_autocmds("CursorMoved", {
      buffer = sidebar_buf,
    })
    assert(vim.wait(1000, function()
      return vim.api.nvim_get_current_tabpage() == tabs[3]
    end), "sidebar cursor did not return to the first changed file")
    assert(vim.api.nvim_get_current_win()
      == assert(sidebar_window(tabs[3])))
    vim.cmd("wincmd h")
    assert(vim.api.nvim_get_current_win() == change_win)
  end
  local linked_line = math.min(
    2,
    vim.api.nvim_buf_line_count(parent_buf),
    vim.api.nvim_buf_line_count(change_buf)
  )
  vim.api.nvim_win_set_cursor(change_win, { linked_line, 0 })
  vim.api.nvim_win_call(change_win, function()
    vim.api.nvim_exec_autocmds("CursorMoved", { buffer = change_buf })
  end)
  assert(
    vim.api.nvim_win_get_cursor(parent_win)[1] == linked_line,
    ("paired cursor stayed at %d instead of %d (current win %d, change %d)")
      :format(
        vim.api.nvim_win_get_cursor(parent_win)[1],
        linked_line,
        vim.api.nvim_get_current_win(),
        change_win
      )
  )

  vim.api.nvim_win_call(change_win, function()
    vim.fn.winrestview({ topline = linked_line })
  end)
  vim.api.nvim_exec_autocmds("WinScrolled", {
    pattern = tostring(change_win),
  })
  local change_view = vim.api.nvim_win_call(change_win, vim.fn.winsaveview)
  local parent_view = vim.api.nvim_win_call(parent_win, vim.fn.winsaveview)
  assert(parent_view.topline == change_view.topline)

  if oil_runtime then
    local oil = require("oil")
    oil.setup({
      watch_for_changes = false,
      keymaps = {
        ["<CR>"] = false,
        ["q"] = { "actions.close", mode = "n" },
        ["l"] = {
          callback = function()
            oil.select({ tab = true, close = true })
          end,
          desc = "Open file in a tab",
        },
      },
    })
    vim.api.nvim_set_current_tabpage(tabs[3])
    vim.api.nvim_set_current_win(change_win)
    local tabs_before_oil = #vim.api.nvim_list_tabpages()
    oil.open()
    assert(vim.wait(10000, function()
      local oil_buf = vim.api.nvim_get_current_buf()
      if vim.bo[oil_buf].filetype ~= "oil" then
        return false
      end
      local oil_signs = vim.api.nvim_get_namespaces()
        .oculus_inspect_oil
      return oil_signs
        and #vim.api.nvim_buf_get_extmarks(
          oil_buf,
          oil_signs,
          0,
          -1,
          {}
        ) > 0
        and type(vim.b[oil_buf].oculus_inspect_oil_origin)
          == "table"
    end), "Oil entries were not decorated")
    local oil_buf = vim.api.nvim_get_current_buf()
    assert(vim.fs.normalize(oil.get_current_dir()):lower()
      == vim.fs.normalize(change_state.directory):lower())
    local oil_origin = vim.b[oil_buf].oculus_inspect_oil_origin
    assert(type(oil_origin) == "table")
    assert(oil_origin.source_buf == change_buf)
    assert(oil_origin.filename == vim.fs.basename(
      change_state.source_path
    ))
    local cursor_entry = oil.get_cursor_entry()
    assert(cursor_entry)
    assert(
      cursor_entry.name == oil_origin.filename,
      ("Oil cursor stayed on %s instead of %s")
        :format(cursor_entry.name, oil_origin.filename)
    )
    for pair_index = 1, pair_count do
      assert(not sidebar_window(tabs[pair_index * 2]))
      assert(not sidebar_window(tabs[pair_index * 2 + 1]))
    end
    local oil_signs = vim.api.nvim_get_namespaces().oculus_inspect_oil
    local oil_marks = vim.api.nvim_buf_get_extmarks(
      oil_buf,
      oil_signs,
      0,
      -1,
      { details = true }
    )
    assert(#oil_marks > 0)
    assert(vim.trim(oil_marks[1][4].sign_text) == "•")
    assert(oil_marks[1][4].sign_hl_group == "OculusOilChange")
    assert(oil_marks[1][4].virt_text == nil)
    assert(vim.wo[vim.api.nvim_get_current_win()].signcolumn == "yes")
    local oil_highlight = vim.api.nvim_get_hl(0, {
      name = oil_marks[1][4].sign_hl_group,
      link = false,
    })
    local normal_highlight = vim.api.nvim_get_hl(0, {
      name = "Normal",
      link = false,
    })
    assert(oil_highlight.bg == normal_highlight.bg)
    ;(function()
      oil.open(vim.fs.dirname(change_state.directory))
      assert(vim.wait(10000, function()
        local current = oil.get_current_dir()
        return current
          and vim.fs.normalize(current):lower()
            == vim.fs.normalize(
              vim.fs.dirname(change_state.directory)
            ):lower()
      end), "Oil did not open the parent inspection directory")
      oil.open(change_state.directory)
      assert(vim.wait(10000, function()
        local current = oil.get_current_dir()
        if not current
          or vim.fs.normalize(current):lower()
            ~= vim.fs.normalize(change_state.directory):lower()
        then
          return false
        end
        local current_buf = vim.api.nvim_get_current_buf()
        local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
        for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
          current_buf,
          oil_signs,
          0,
          -1,
          { details = true }
        )) do
          if vim.trim(mark[4].sign_text) == "•"
            and cursor_line == mark[2] + 1
          then
            local entry = oil.get_entry_on_line(current_buf, cursor_line)
            return entry and entry.type ~= "directory"
          end
        end
        return false
      end), "Oil did not select the first changed file after descending")
      oil_buf = vim.api.nvim_get_current_buf()
      cursor_entry = oil.get_cursor_entry()
      assert(cursor_entry and cursor_entry.type ~= "directory")
      for line = 1, vim.api.nvim_buf_line_count(oil_buf) do
        local entry = oil.get_entry_on_line(oil_buf, line)
        if entry and entry.name == oil_origin.filename then
          vim.api.nvim_win_set_cursor(0, { line, 0 })
          break
        end
      end
    end)()
    local oil_select_mapping =
      vim.fn.maparg("l", "n", false, true)
    assert(
      oil_select_mapping.desc
        == "Select Oculus Inspect Oil entry",
      "unexpected Oil select mapping: "
        .. vim.inspect(oil_select_mapping)
    )
    ;(function()
      local origin_tab = vim.api.nvim_get_current_tabpage()
      local entered_tabs = {}
      local tab_enter = vim.api.nvim_create_autocmd("TabEnter", {
        callback = function()
          entered_tabs[#entered_tabs + 1] =
            vim.api.nvim_get_current_tabpage()
        end,
      })
      local close_mapping = vim.fn.maparg("q", "n", false, true)
      assert(type(close_mapping.callback) == "function")
      close_mapping.callback()
      assert(vim.wait(10000, function()
        return vim.api.nvim_get_current_buf() == change_buf
          and sidebar_window(origin_tab) ~= nil
      end), "Oil did not restore its originating inspect page")
      vim.api.nvim_del_autocmd(tab_enter)
      assert(vim.api.nvim_get_current_tabpage() == origin_tab)
      for _, entered_tab in ipairs(entered_tabs) do
        assert(entered_tab == origin_tab, "Oil close cycled inspect pages")
      end
    end)()
    assert(vim.api.nvim_get_current_buf() == change_buf)
    assert(#vim.api.nvim_list_tabpages() == tabs_before_oil)
    assert(vim.bo[vim.api.nvim_get_current_buf()].filetype ~= "oil")
    assert(sidebar_window(tabs[3]))
    ;(function()
      for pair_index = 1, pair_count do
        for _, tab in ipairs({
          tabs[pair_index * 2],
          tabs[pair_index * 2 + 1],
        }) do
          vim.api.nvim_set_current_tabpage(tab)
          local shown_tab = vim.api.nvim_get_current_tabpage()
          if inspection_window(shown_tab) then
            assert(vim.wait(10000, function()
              return sidebar_window(shown_tab) ~= nil
            end), "Inspect sidebar was not restored when its page was shown")
          else
            assert(sidebar_window(shown_tab) == nil)
          end
        end
      end
    end)()
    vim.api.nvim_set_current_tabpage(tabs[3])
    vim.api.nvim_set_current_win(change_win)
  end
end
