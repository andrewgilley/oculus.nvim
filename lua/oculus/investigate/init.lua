local engine = require("oculus.investigate.engine")
local window = require("oculus.investigate.window")
local M = {}

function M.investigate(target, opts, context, callback)
  opts = opts or {}
  context = context or {}
  local repo_root = context.cwd

  if not repo_root or repo_root == "" then
    if context.project and context.project.repository then
      -- Could be local path if configured
      repo_root = vim.fn.getcwd()
    else
      repo_root = vim.fn.getcwd()
    end
  end

  local request = {
    repo_root = repo_root,
    target = target,
    opts = opts,
  }

  vim.notify("Oculus: Running investigation...", vim.log.levels.INFO)

  return engine.run(request, function(bundle, err)
    if not bundle then
      local msg = "Investigation failed: " .. tostring(err or "unknown error")
      vim.notify("Oculus: " .. msg, vim.log.levels.WARN)

      if callback then
        callback(nil, msg)
      end

      return
    end

    window.open(bundle, opts)

    if callback then
      callback(bundle, nil)
    end
  end)
end

function M.close()
  window.close()
end

return M
