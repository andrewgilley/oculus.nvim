vim.opt.runtimepath:prepend(vim.fn.getcwd())
local github = require("oculus.github")
local storage = require("oculus.storage")
local window = require("oculus.window")
local original_repository_info = github.repository_info
local original_save = storage.save
local pending_description
local saves = 0

github.repository_info = function(_, _, callback)
  pending_description = callback
end

storage.save = function()
  saves = saves + 1
  return true
end

window.open({
  projects = {
    {repository = "example/project", provider = "github"},
  },
  contributors = {},
  project_descriptions = {},
  persist_projects = true,
  state_file = vim.fn.tempname() .. ".json",
})

assert(type(pending_description) == "function", "expected an asynchronous project preview request")
pending_description({description = "A project description"})
assert(saves == 1, "expected the preview callback to persist the description")
window.close()
github.repository_info = original_repository_info
storage.save = original_save
print("preview_persist_spec: passed")
