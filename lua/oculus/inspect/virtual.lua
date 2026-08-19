local M = {}

M.virtual_counter_ns = vim.api.nvim_create_namespace("oculus_inspect_virtual_counter")

function M.place_virtual_counter(buf, line, chunk_index, chunk_count)
  if
    not buf
    or not vim.api.nvim_buf_is_valid(buf)
    or not line
    or not chunk_index
    or not chunk_count
    or chunk_count == 0
  then
    return
  end

  local line_count = vim.api.nvim_buf_line_count(buf)
  if line_count == 0 then
    return
  end

  line = math.min(math.max(1, line), line_count)

  vim.api.nvim_buf_set_extmark(buf, M.virtual_counter_ns, line - 1, 0, {
    virt_text = {
      {
        ("\t[%d/%d]"):format(chunk_index, chunk_count),
        "OculusInspectVirtualCounter",
      },
    },
    virt_text_pos = "eol",
    hl_mode = "combine",
    priority = 50,
  })
end

function M.clear_virtual_counter(buf)
  if buf and vim.api.nvim_buf_is_valid(buf) then
    vim.api.nvim_buf_clear_namespace(buf, M.virtual_counter_ns, 0, -1)
  end
end

return M
