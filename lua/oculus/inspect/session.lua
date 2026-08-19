local M = {}

function M.create_session(id, opts)
  return {
    id = id,
    opts = opts or {},
    active_chunk = 1,
    hunks = {},
    sections = {},
    windows = {},
    focused_chunks = false,
  }
end

return M
