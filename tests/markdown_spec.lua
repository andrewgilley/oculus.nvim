vim.opt.runtimepath:prepend(vim.fn.getcwd())
local inspect = require("oculus.inspect")

local function syntax_names(buf, line, column)
  return vim.api.nvim_buf_call(buf, function()
    return vim.tbl_map(function(id)
      return vim.fn.synIDattr(id, "name")
    end, vim.fn.synstack(line, column))
  end)
end

for _, kind in ipairs({ "issue", "pull_request" }) do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].filetype = "oculus-inspect-overview"

  local group = {
    overview_buf = buf,
    overview_content_width = 60,
    overview = {
      kind = kind,
      title = "**A plain title**",
      author = "owner",
      body = table.concat({
        "# Heading",
        "**Bold text** and *italic text* with `inline code`.",
        "[Link text](https://example.com)",
        "- A list item",
        "  - A nested item",
        "",
        "Author",
        "",
        "```lua",
        "  local value = 1  +  2",
        "",
        "  print(value)",
        "```",
        "",
        "    indented  code",
      }, "\n"),
      comments = { items = { { body = "**Plain comment**" } } },
    },
  }

  local function render()
    inspect._overview_ui.render(group)
    return vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  end

  local lines = render()

  local function find(text)
    for index, line in ipairs(lines) do
      if line == text then return index end
    end

    error("Missing rendered line: " .. text)
  end

  assert(vim.tbl_contains(syntax_names(buf, find("  # Heading"), 6), "markdownH1"))
  local inline = find("  **Bold text** and *italic text* with `inline code`.")
  assert(vim.tbl_contains(syntax_names(buf, inline, 6), "markdownBold"))
  assert(vim.tbl_contains(syntax_names(buf, inline, 22), "markdownItalic"))
  assert(vim.tbl_contains(syntax_names(buf, inline, 40), "markdownCode"))
  assert(vim.tbl_contains(syntax_names(buf, find("  [Link text](https://example.com)"), 5), "markdownLinkText"))
  assert(vim.tbl_contains(syntax_names(buf, find("  - A list item"), 3), "markdownListMarker"))
  assert(find("    - A nested item"))
  assert(vim.tbl_contains(syntax_names(buf, find("    local value = 1  +  2"), 6), "markdownCodeBlock"))
  assert(find("    print(value)"))
  assert(find("      indented  code"))
  assert(#syntax_names(buf, find("  **A plain title**"), 6) == 0)
  assert(#syntax_names(buf, find("    **Plain comment**"), 8) == 0)
  assert(vim.bo[buf].filetype == "oculus-inspect-overview")
  assert(vim.bo[buf].modifiable == false)
  local description_author = find("  Author")

  for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(
    buf,
    vim.api.nvim_get_namespaces().oculus_inspect_sidebar,
    0,
    -1,
    { details = true }
  )) do
    assert(mark[2] ~= description_author - 1,
      "A word inside the description must not become an overview heading")
  end

  -- Reflowing the title relocates the syntax region on a background repaint.
  group.overview.title = string.rep("Long title ", 12)
  lines = render()
  assert(vim.tbl_contains(syntax_names(buf, find("  # Heading"), 6), "markdownH1"))

  -- An unclosed fence or emphasis must never color the metadata below it.
  for _, body in ipairs({ "```lua\nlocal value = 1", "**Unclosed emphasis" }) do
    group.overview.body = body
    lines = render()
    assert(#syntax_names(buf, find("  @owner"), 5) == 0)
    assert(#syntax_names(buf, find("    **Plain comment**"), 8) == 0)
  end

  -- Rendering a commit in the same buffer removes the description region.
  group.overview = {
    kind = "commit",
    commit_details = { subject = "Commit", body = "**Plain commit body**" },
  }

  lines = render()
  assert(#syntax_names(buf, find("  **Plain commit body**"), 6) == 0)
  vim.api.nvim_buf_delete(buf, { force = true })
end
