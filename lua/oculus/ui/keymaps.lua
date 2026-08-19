local M = {}

function M.map_key(buf, mode, lhs, rhs, desc, opts)
  opts = vim.tbl_extend("force", {
    buffer = buf,
    nowait = true,
    silent = true,
    desc = desc,
  }, opts or {})

  vim.keymap.set(mode, lhs, rhs, opts)
end

function M.map_normal(buf, lhs, rhs, desc, opts)
  M.map_key(buf, "n", lhs, rhs, desc, opts)
end

return M
