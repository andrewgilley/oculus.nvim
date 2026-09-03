if vim.g.loaded_oculus then
  return
end

vim.g.loaded_oculus = true

vim.api.nvim_create_user_command("OculusOpen", function()
  require("oculus").open()
end, { desc = "Open Oculus" })

vim.api.nvim_create_user_command("OculusClose", function()
  require("oculus").close()
end, { desc = "Close Oculus" })

vim.api.nvim_create_user_command("OculusToggle", function()
  require("oculus").toggle()
end, { desc = "Toggle Oculus" })

vim.api.nvim_create_user_command("OculusInspect", function(opts)
  local target = opts.args ~= "" and opts.args or nil
  require("oculus").inspect(target)
end, {
  nargs = "?",
  desc = "Inspect an issue, pull request, or commit",
  complete = function(arglead)
    local config = require("oculus").config or {}
    local projects = config.projects or {}
    local completions = { "pr ", "issue ", "commit " }

    for _, p in ipairs(projects) do
      if type(p.repository) == "string" and p.repository ~= "" then
        completions[#completions + 1] = p.repository .. "#"
      end

      if type(p.name) == "string" and p.name ~= "" then
        completions[#completions + 1] = p.name:lower() .. "#"
      end
    end

    local matches = {}

    for _, c in ipairs(completions) do
      if c:lower():sub(1, #arglead) == arglead:lower() then
        matches[#matches + 1] = c
      end
    end

    return matches
  end,
})
