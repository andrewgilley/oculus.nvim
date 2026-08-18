local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)
local opinion = require("oculus.opinion")
local context, context_err = opinion.context()
assert(context, context_err)
assert(context.project.root == vim.fs.normalize(root))
assert(context.project.name == vim.fs.basename(root))
assert(context.buffer.bufnr == vim.api.nvim_get_current_buf())

local shown, show_err = opinion.show("A useful opinion.", {
  enter = false,
  width = 50,
  height = 8,
})

assert(shown, show_err)
assert(vim.api.nvim_win_is_valid(shown.win))
assert(vim.bo[shown.buf].buftype == "nofile")
assert(vim.bo[shown.buf].filetype == "markdown")
assert(vim.bo[shown.buf].readonly)

assert(vim.api.nvim_buf_get_lines(shown.buf, 0, -1, false)[1]
  == "A useful opinion.")

shown.close()
assert(shown.closed)
local missing, missing_err = opinion.consult({}, {})
assert(missing == nil)
assert(missing_err == "no opinion provider is configured")

local bad_context, bad_context_err = opinion.consult({
  context = "not a table",
}, {
  provider = function() end,
})

assert(bad_context == nil)
assert(bad_context_err == "opinion request context must be a table")
local received
local respond
local cancelled = false

local view, consult_err = opinion.consult({
  action = "assess-change",
  context = {
    subject = "current inspection",
  },
}, {
  enter = false,
  width = 50,
  height = 8,
  provider = function(request, callback)
    received = request
    respond = callback

    return function()
      cancelled = true
    end
  end,
})

assert(view, consult_err)
assert(view.pending)
assert(received.action == "assess-change")
assert(received.context.subject == "current inspection")
assert(received.context.project.root == vim.fs.normalize(root))
assert(received.context.buffer.bufnr == vim.api.nvim_get_current_buf())
assert(type(respond) == "function")

respond({
  text = "# Opinion\n\nThe change is coherent.",
  filetype = "markdown",
})

assert(vim.wait(1000, function()
  return not view.pending
end), "opinion callback did not update the view")

assert(vim.deep_equal(
  vim.api.nvim_buf_get_lines(view.buf, 0, -1, false),
  { "# Opinion", "", "The change is coherent." }
))

view.close()
assert(not cancelled)

local pending = assert(opinion.consult({}, {
  enter = false,
  provider = function()
    return {
      cancel = function()
        cancelled = true
      end,
    }
  end,
}))

pending.close()
assert(cancelled)
cancelled = false

local externally_closed = assert(opinion.consult({}, {
  enter = false,
  provider = function()
    return function()
      cancelled = true
    end
  end,
}))

vim.api.nvim_win_close(externally_closed.win, true)

assert(vim.wait(1000, function()
  return externally_closed.closed and cancelled
end), "closing the window did not cancel its provider")

local immediate = assert(opinion.consult({}, {
  enter = false,
  provider = function(request)
    return "Immediate opinion about " .. request.context.project.name
  end,
}))

assert(vim.wait(1000, function()
  return not immediate.pending
end), "immediate opinion did not update the view")

assert(vim.api.nvim_buf_get_lines(immediate.buf, 0, 1, false)[1]
  == "Immediate opinion about " .. vim.fs.basename(root))

immediate.close()
vim.cmd("qa!")
