-- The chunk counters drawn in the inspected files themselves, used instead of
-- the sidebar in virtual chunk mode: "[2/7]" at the end of the line each
-- chunk starts on, for the file version a window is showing.
local patch = require("oculus.inspect.patch")
local M = {}

function M.setup(inspect, internal)
  inspect._virtual_counter = {}

  function inspect._virtual_counter.place_virtual_counter(
    buf,
    line,
    chunk_index,
    chunk_count,
    file_index,
    file_count,
    max_line
  )
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

    line = internal.first_nonblank_line(buf, line, max_line)
    line = math.min(math.max(1, line), line_count)
    local text

    if file_index and file_count and file_count > 0 then
      text = ("\t[%d/%d] (%d/%d)"):format(
        chunk_index,
        chunk_count,
        file_index,
        file_count
      )
    else
      text = ("\t[%d/%d]"):format(chunk_index, chunk_count)
    end

    vim.api.nvim_buf_set_extmark(buf, inspect._virtual_counter_ns, line - 1, 0, {
      virt_text = {
        {
          text,
          "OculusInspectVirtualCounter",
        },
      },
      virt_text_pos = "eol",
      hl_mode = "combine",
      priority = 10,
    })
  end

  function inspect._virtual_counter.refresh_session_virtual_counters(group, session)
    if not group or not session then
      return
    end

    local file_chunks = #internal.inspection_chunks(group, session)

    if file_chunks == 0 then
      return
    end

    local file_count = #group
    local file_index

    for index, candidate in ipairs(group) do
      if candidate == session then
        file_index = index
        break
      end
    end

    file_index = file_index or 1
    file_count = math.max(1, file_count)
    local active = math.min(math.max(1, session.active_chunk or 1), file_chunks)
    local is_virtual = (group.chunk_view_mode or "sidebar") ~= "sidebar"

    if group.kind == "issue" then
      if internal.valid_endpoint(session.issue) then
        local buf = session.issue.buf
        vim.api.nvim_buf_clear_namespace(buf, inspect._virtual_counter_ns, 0, -1)

        if is_virtual then
          local sections = session.sections or {}
          local section = sections[active] or sections[1]

          if section and section.line then
            local line = internal.first_nonblank_line(buf, section.line, section.line)

            inspect._virtual_counter.place_virtual_counter(
              buf,
              line,
              active,
              file_chunks,
              file_index,
              file_count,
              section.line
            )
          end
        end
      end

      return
    end

    if internal.valid_endpoint(session.parent) then
      local buf = session.parent.buf
      vim.api.nvim_buf_clear_namespace(buf, inspect._virtual_counter_ns, 0, -1)

      if is_virtual then
        local hunks = session.hunks or {}
        local hunk = hunks[active] or hunks[1]

        if hunk then
          local start = patch.hunk_start(hunk, "parent")
          local max_line = internal.chunk_max_line_for_role(hunk, "parent", start)
          local line = internal.first_nonblank_line(buf, start, max_line)

          inspect._virtual_counter.place_virtual_counter(
            buf,
            line,
            active,
            file_chunks,
            file_index,
            file_count,
            max_line
          )
        end
      end
    end

    if internal.valid_endpoint(session.change) then
      local buf = session.change.buf
      vim.api.nvim_buf_clear_namespace(buf, inspect._virtual_counter_ns, 0, -1)

      if is_virtual then
        local hunks = session.hunks or {}
        local hunk = hunks[active] or hunks[1]

        if hunk then
          local start

          if session.focused_chunks then
            start = session.focused_start
              or internal.chunk_start_for_role(
                hunk,
                "change",
                patch.hunk_start(hunk, "change")
              )
          else
            start = internal.chunk_start_for_role(
              hunk,
              "change",
              patch.hunk_start(hunk, "change")
            )
          end

          local max_line = internal.chunk_max_line_for_role(hunk, "change", start)
          local line = internal.first_nonblank_line(buf, start, max_line)

          inspect._virtual_counter.place_virtual_counter(
            buf,
            line,
            active,
            file_chunks,
            file_index,
            file_count,
            max_line
          )
        end
      end
    end
  end

  function inspect._refresh_virtual_counters(group, session)
    if not group then
      return
    end

    if session then
      inspect._virtual_counter.refresh_session_virtual_counters(group, session)
    else
      for _, s in ipairs(group) do
        inspect._virtual_counter.refresh_session_virtual_counters(group, s)
      end
    end
  end

  function inspect._clear_virtual_counters(group)
    if not group then
      return
    end

    for _, session in ipairs(group) do
      for _, role in ipairs({ "issue", "parent", "change" }) do
        local endpoint = session[role]

        if internal.valid_endpoint(endpoint) then
          vim.api.nvim_buf_clear_namespace(
            endpoint.buf,
            inspect._virtual_counter_ns,
            0,
            -1
          )
        end
      end
    end
  end
end

return M
