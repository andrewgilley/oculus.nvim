-- Integration with nvim-treesitter-context for inspected files: the context
-- window's own highlights, absolute line numbers in it, and the safeguards
-- that keep it from erroring on the buffers Oculus rewrites while a chunk is
-- focused. `setup` hands the module the inspect module it extends and the
-- inspection state it reads.
local M = {}
local internal

local function ensure_treesitter_safeguards()
  if
    vim.treesitter
    and type(vim.treesitter.get_range) == "function"
    and not vim.treesitter._oculus_safe_get_range
  then
    local orig_get_range = vim.treesitter.get_range

    vim.treesitter.get_range = function(node, source, metadata)
      if type(node) == "table" and type(node.range) ~= "function" then
        if
          (type(node[1]) == "userdata" or type(node[1]) == "table")
          and type(node[1].range) == "function"
        then
          return vim.treesitter.get_range(node[1], source, metadata)
        elseif type(node[1]) == "number" and #node >= 4 then
          if #node >= 6 then
            return node
          end

          if
            source
            and vim.treesitter._range
            and vim.treesitter._range.add_bytes
          then
            local ok, r = pcall(vim.treesitter._range.add_bytes, source, node)

            if ok and r then
              return r
            end
          end

          return node
        end

        return { 0, 0, 0, 0, 0, 0 }
      end

      if not node or type(node.range) ~= "function" then
        return { 0, 0, 0, 0, 0, 0 }
      end

      local ok, res = pcall(orig_get_range, node, source, metadata)

      if ok and res then
        return res
      end

      return { 0, 0, 0, 0, 0, 0 }
    end

    vim.treesitter._oculus_safe_get_range = true
  end

  if
    vim.treesitter
    and type(vim.treesitter.get_node_text) == "function"
    and not vim.treesitter._oculus_safe_get_node_text
  then
    local orig_get_node_text = vim.treesitter.get_node_text

    vim.treesitter.get_node_text = function(node, source, opts)
      if type(node) == "table" and type(node.start) ~= "function" then
        if
          (type(node[1]) == "userdata" or type(node[1]) == "table")
          and type(node[1].start) == "function"
        then
          return vim.treesitter.get_node_text(node[1], source, opts)
        end

        return ""
      end

      if not node or type(node.start) ~= "function" then
        return ""
      end

      local ok, res = pcall(orig_get_node_text, node, source, opts)

      if ok and type(res) == "string" then
        return res
      end

      return ""
    end

    vim.treesitter._oculus_safe_get_node_text = true
  end

  local ok_ctx, ctx = pcall(require, "treesitter-context.context")

  if
    ok_ctx
    and type(ctx) == "table"
    and type(ctx.get) == "function"
    and not ctx._oculus_safe_get
  then
    local orig_get = ctx.get

    ctx.get = function(winid)
      local ok, ranges, lines = pcall(orig_get, winid)

      if ok then
        return ranges, lines
      end

      return nil, nil
    end

    ctx._oculus_safe_get = true
  end
end

ensure_treesitter_safeguards()

function M._use_absolute_treesitter_context_numbers()
  local ok, render = pcall(require, "treesitter-context.render")

  if not ok
    or type(render) ~= "table"
    or type(render.open) ~= "function"
    or render._oculus_absolute_line_numbers
  then
    return
  end

  local original_open = render.open

  render.open = function(win, ...)
    if not vim.api.nvim_win_is_valid(win) then
      return original_open(win, ...)
    end

    local buf = vim.api.nvim_win_get_buf(win)

    if type(vim.b[buf].oculus_inspect) ~= "table"
      or not vim.wo[win].relativenumber
    then
      return original_open(win, ...)
    end

    local had_number = vim.wo[win].number

    vim.api.nvim_win_call(win, function()
      vim.cmd("noautocmd setlocal number norelativenumber")
    end)

    local result = { pcall(original_open, win, ...) }

    if vim.api.nvim_win_is_valid(win) then
      vim.api.nvim_win_call(win, function()
        vim.cmd(
          "noautocmd setlocal "
            .. (had_number and "number" or "nonumber")
            .. " relativenumber"
        )
      end)
    end

    if not result[1] then
      error(result[2], 0)
    end

    return unpack(result, 2)
  end

  render._oculus_absolute_line_numbers = true
end

local rendered_treesitter_contexts = {}

local function treesitter_context_lines_equal(a, b)
  if a == b then
    return true
  end

  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end

  if #a ~= #b then
    return false
  end

  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end

  return true
end

local function treesitter_context_ranges_equal(a, b)
  if a == b then
    return true
  end

  if type(a) ~= "table" or type(b) ~= "table" then
    return false
  end

  if #a ~= #b then
    return false
  end

  for i = 1, #a do
    local r1 = a[i]
    local r2 = b[i]

    if r1 ~= r2 then
      if type(r1) ~= "table" or type(r2) ~= "table" then
        return false
      end

      if
        r1[1] ~= r2[1]
        or r1[2] ~= r2[2]
        or r1[3] ~= r2[3]
        or r1[4] ~= r2[4]
      then
        return false
      end
    end
  end

  return true
end

local function has_valid_context_window(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return false
  end

  for _, context_win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(context_win) then
      local config = vim.api.nvim_win_get_config(context_win)

      if
        vim.w[context_win].treesitter_context
        and config.relative == "win"
        and config.win == win
      then
        local ctx_buf = vim.api.nvim_win_get_buf(context_win)

        if ctx_buf and vim.api.nvim_buf_is_valid(ctx_buf) then
          return true
        end
      end
    end
  end

  return false
end

local function ensure_context_window_leftcol(win)
  if not win or not vim.api.nvim_win_is_valid(win) then
    return
  end

  for _, context_win in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(context_win) then
      local config = vim.api.nvim_win_get_config(context_win)

      if
        vim.w[context_win].treesitter_context
        and config.relative == "win"
        and config.win == win
      then
        vim.api.nvim_win_call(context_win, function()
          local v = vim.fn.winsaveview()

          if v.leftcol ~= 0 then
            vim.fn.winrestview({ leftcol = 0 })
          end
        end)
      end
    end
  end
end

function M._refresh_inspection_treesitter_context_highlights()
  local ok, render = pcall(require, "treesitter-context.render")

  if not ok
    or type(render) ~= "table"
    or type(render.open) ~= "function"
    or render._oculus_refresh_inspection_highlights
  then
    return
  end

  local original_open = render.open

  render.open = function(win, ranges, lines, force_hl_update)
    local source_uses_treesitter = false
    local source_buf
    local content_same = false

    if vim.api.nvim_win_is_valid(win) then
      source_buf = vim.api.nvim_win_get_buf(win)

      if type(vim.b[source_buf].oculus_inspect) == "table" then
        local highlighters = vim.treesitter
            and vim.treesitter.highlighter
            and vim.treesitter.highlighter.active
          or nil

        if highlighters
          and not highlighters[source_buf]
          and vim.treesitter.start
        then
          pcall(vim.treesitter.start, source_buf)
        end

        source_uses_treesitter = highlighters and highlighters[source_buf]
          or false

        local changedtick = vim.api.nvim_buf_get_changedtick(source_buf)
        local prev = rendered_treesitter_contexts[win]
        local has_context_win = has_valid_context_window(win)

        content_same = has_context_win
          and prev ~= nil
          and prev.buf == source_buf
          and prev.changedtick == changedtick
          and treesitter_context_lines_equal(prev.lines, lines)
          and treesitter_context_ranges_equal(prev.ranges, ranges)

        if not content_same then
          rendered_treesitter_contexts[win] = {
            buf = source_buf,
            changedtick = changedtick,
            lines = vim.deepcopy(lines),
            ranges = vim.deepcopy(ranges),
            parsed = false,
          }

          if vim.b[source_buf].oculus_context_highlight_tick ~= changedtick then
            vim.b[source_buf].oculus_context_highlight_tick = changedtick

            local parser_ok, parser = pcall(
              vim.treesitter.get_parser,
              source_buf
            )

            if parser_ok and parser then
              pcall(parser.parse, parser, true, function()
                vim.schedule(function()
                  if
                    vim.api.nvim_win_is_valid(win)
                    and vim.api.nvim_win_get_buf(win) == source_buf
                  then
                    local current = rendered_treesitter_contexts[win]

                    if current and not current.parsed then
                      current.parsed = true
                      original_open(win, ranges, lines, true)
                    end
                  end
                end)
              end)
            end
          end

          force_hl_update = true
        else
          force_hl_update = false
        end
      end
    end

    local result = { pcall(original_open, win, ranges, lines, force_hl_update) }

    if
      not content_same
      and result[1]
      and source_buf
      and not source_uses_treesitter
      and vim.bo[source_buf].syntax ~= ""
    then
      for _, context_win in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(context_win)

        if
          vim.w[context_win].treesitter_context
          and config.relative == "win"
          and config.win == win
        then
          vim.api.nvim_buf_call(
            vim.api.nvim_win_get_buf(context_win),
            function()
              vim.cmd("syntax sync fromstart")
            end
          )

          break
        end
      end
    end

    if result[1] and vim.api.nvim_win_is_valid(win) then
      local display_options = {
        "tabstop",
        "shiftwidth",
        "softtabstop",
        "vartabstop",
        "varsofttabstop",
        "expandtab",
        "list",
        "listchars",
      }

      for _, context_win in ipairs(vim.api.nvim_list_wins()) do
        local config = vim.api.nvim_win_get_config(context_win)

        if
          vim.w[context_win].treesitter_context
          and config.relative == "win"
          and config.win == win
        then
          for _, option in ipairs(display_options) do
            local opt_ok, value = pcall(
              vim.api.nvim_get_option_value,
              option,
              { win = win }
            )

            if opt_ok then
              pcall(
                vim.api.nvim_set_option_value,
                option,
                value,
                { win = context_win }
              )
            end
          end

          vim.api.nvim_win_call(context_win, function()
            local v = vim.fn.winsaveview()

            if v.leftcol ~= 0 then
              vim.fn.winrestview({ leftcol = 0 })
            end
          end)

          break
        end
      end
    end

    if not result[1] then
      error(result[2], 0)
    end

    return unpack(result, 2)
  end

  render._oculus_refresh_inspection_highlights = true
end

local function set_inspection_context_highlights()
  -- Context is rendered in a separate floating window. Linking its surface to
  -- Normal prevents colorschemes with a panel-style TreesitterContext
  -- background from drawing an apparent divider above inspected code.
  vim.api.nvim_set_hl(0, "TreesitterContext", { link = "Normal" })
  -- nvim-treesitter-context applies this group as a high-priority line
  -- highlight to its final visible row. Keep it background-only: linking it
  -- to Normal supplies a foreground and masks that row's token highlights.
  vim.api.nvim_set_hl(0, "TreesitterContextBottom", { bg = "NONE" })

  vim.api.nvim_set_hl(0, "TreesitterContextLineNumber", {
    link = "Normal",
  })

  vim.api.nvim_set_hl(0, "TreesitterContextLineNumberBottom", {
    link = "TreesitterContextLineNumber",
  })

  vim.api.nvim_set_hl(0, "TreesitterContextSeparator", {
    link = "TreesitterContext",
  })
end

function M._enable_inspection_treesitter_context(opts)
  if opts and opts.inspect_treesitter_context == false then
    return false
  end

  ensure_treesitter_safeguards()
  local ok, context = pcall(require, "treesitter-context")

  if not ok or type(context) ~= "table" then
    return false
  end

  M._use_absolute_treesitter_context_numbers()
  M._refresh_inspection_treesitter_context_highlights()

  local multiwindow = not opts
    or opts.inspect_treesitter_context_multiwindow ~= false

  local mode = opts and opts.inspect_treesitter_context_mode or "topline"

  if mode ~= "cursor" and mode ~= "topline" then
    mode = "topline"
  end

  local enabled = type(context.enabled) == "function"
    and context.enabled()

  local configured_multiwindow = context.config
    and context.config.multiwindow == true

  local separator_disabled = context.config
    and context.config.separator == false

  local configured_mode = context.config and context.config.mode

  if not enabled
    or configured_multiwindow ~= multiwindow
    or not separator_disabled
    or configured_mode ~= mode
  then
    if type(context.setup) ~= "function" then
      return false
    end

    local setup_ok = pcall(context.setup, {
      enable = true,
      multiwindow = multiwindow,
      separator = false,
      mode = mode,
    })

    if not setup_ok then
      return false
    end
  end

  set_inspection_context_highlights()
  return true
end

-- User configs commonly restore an underlined TreesitterContextBottom from a
-- scheduled ColorScheme handler, which would redraw the divider whenever the
-- inspected code's colorscheme loads. Reapply after those handlers run.
vim.api.nvim_create_autocmd("ColorScheme", {
  group = vim.api.nvim_create_augroup(
    "OculusInspectTreesitterContext",
    { clear = true }
  ),
  callback = function()
    vim.schedule(function()
      vim.schedule(function()
        if #internal.sidebar_groups > 0 then
          set_inspection_context_highlights()
        end
      end)
    end)
  end,
})

function M.setup(inspect, deps)
  internal = deps
  M.ensure_safeguards = ensure_treesitter_safeguards
  M.ensure_leftcol = ensure_context_window_leftcol
  M.rendered = rendered_treesitter_contexts
  M.set_highlights = set_inspection_context_highlights

  inspect._use_absolute_treesitter_context_numbers =
    M._use_absolute_treesitter_context_numbers

  inspect._refresh_inspection_treesitter_context_highlights =
    M._refresh_inspection_treesitter_context_highlights

  inspect._enable_inspection_treesitter_context =
    M._enable_inspection_treesitter_context

  return M
end

return M
