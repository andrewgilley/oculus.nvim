vim.opt.runtimepath:prepend(vim.fn.getcwd())
local oculus = require("oculus")
local workspace = require("oculus.workspace")
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, "p")
local state_file = dir .. "/state.json"
-- 1. Default state
assert(#oculus.workspaces() == 0, "fresh oculus has no workspaces")
assert(oculus.get_workspace() == nil, "fresh oculus has no active workspace")

local sample_projects = {
  { repository = "bytecodealliance/wasmtime", provider = "github", name = "Wasmtime" },
  { repository = "bytecodealliance/wit-bindgen", provider = "github", name = "wit-bindgen" },
  { repository = "ratatui-org/ratatui", provider = "github", name = "ratatui" },
  { repository = "community/tool", provider = "codeberg", name = "tool" },
}

local unfiltered = oculus.filter_projects(sample_projects)
assert(#unfiltered == 4, "filter_projects returns all projects when no workspace is active")

-- 2. Normalization: list and map formats
local ws_list = {
  {
    name = "wasm",
    description = "WebAssembly tools and runtimes",
    projects = { "bytecodealliance/wasmtime", "bytecodealliance/wit-bindgen" },
  },
  {
    name = "tui",
    description = "Terminal user interfaces",
    projects = { "ratatui-org/ratatui" },
  },
}

oculus.setup({
  state_file = state_file,
  projects = sample_projects,
  workspaces = ws_list,
})

local all_ws = oculus.workspaces()
assert(#all_ws == 2, "2 workspaces loaded from list")
assert(all_ws[1].name == "wasm" and #all_ws[1].projects == 2)
assert(all_ws[2].name == "tui" and #all_ws[2].projects == 1)

-- Map format with shorthand projects
local ws_map = {
  wasm = {
    description = "WebAssembly tools",
    projects = { "bytecodealliance/wasmtime" },
  },
  forge = { "codeberg:community/tool" },
}

oculus.setup({
  state_file = state_file,
  projects = sample_projects,
  workspaces = ws_map,
})

all_ws = oculus.workspaces()
assert(#all_ws == 2, "2 workspaces loaded from map")
local ws_wasm = workspace.find(oculus.config, "wasm")
local ws_forge = workspace.find(oculus.config, "forge")
assert(ws_wasm and ws_wasm.description == "WebAssembly tools")
assert(ws_forge and ws_forge.projects[1] == "codeberg:community/tool")
-- 3. Switching active workspace
assert(oculus.get_workspace() == nil, "no active workspace yet")
local ok, active = oculus.set_workspace("wasm")
assert(ok, "set_workspace succeeded")
assert(active and active.name == "wasm", "active workspace is wasm")
assert(oculus.get_workspace().name == "wasm", "get_workspace returns active workspace")
-- Case-insensitivity
local ok_upper, active_upper = oculus.set_workspace("FORGE")
assert(ok_upper and active_upper.name == "forge", "case-insensitive set_workspace works")
-- Unknown workspace
local ok_bad, err_bad = oculus.set_workspace("nonexistent")
assert(not ok_bad, "setting non-existent workspace fails")
assert(err_bad:find("not found"), "error mentions not found")
assert(oculus.get_workspace().name == "forge", "active workspace untouched after failed set")
-- Clearing active workspace
assert(oculus.set_workspace("none"), "clearing via 'none' succeeds")
assert(oculus.get_workspace() == nil, "active workspace is nil after 'none'")
oculus.set_workspace("wasm")
assert(oculus.get_workspace() ~= nil)
assert(oculus.set_workspace("clear"), "clearing via 'clear' succeeds")
assert(oculus.get_workspace() == nil, "active workspace is nil after 'clear'")
oculus.set_workspace("wasm")
assert(oculus.set_workspace(nil), "clearing via nil succeeds")
assert(oculus.get_workspace() == nil, "active workspace is nil after nil")

-- 4. Project filtering
oculus.setup({
  state_file = state_file,
  projects = sample_projects,
  workspaces = ws_list,
})

-- Inactive: returns all projects
local filtered = oculus.filter_projects()
assert(#filtered == 4, "no active workspace returns all projects")
-- Activate wasm: should return only wasmtime and wit-bindgen
oculus.set_workspace("wasm")
filtered = oculus.filter_projects()
assert(#filtered == 2, "wasm workspace filters to 2 projects")
assert(filtered[1].repository == "bytecodealliance/wasmtime")
assert(filtered[2].repository == "bytecodealliance/wit-bindgen")
-- Activate tui: should return only ratatui
oculus.set_workspace("tui")
filtered = oculus.filter_projects()
assert(#filtered == 1, "tui workspace filters to 1 project")
assert(filtered[1].repository == "ratatui-org/ratatui")

-- Provider matching: e.g. "codeberg:community/tool"
local ws_codeberg = oculus.add_workspace("codeberg-test", {
  description = "Codeberg tools",
  projects = { "codeberg:community/tool" },
})

assert(ws_codeberg, "added codeberg-test workspace")
oculus.set_workspace("codeberg-test")
filtered = oculus.filter_projects()
assert(#filtered == 1 and filtered[1].repository == "community/tool")

-- 5. Dynamic add and remove
local added = oculus.add_workspace("dynamic", {
  description = "Dynamic workspace",
  projects = { "ratatui-org/ratatui" },
})

assert(added and added.name == "dynamic")
assert(workspace.find(oculus.config, "dynamic") ~= nil)
oculus.set_workspace("dynamic")
assert(oculus.get_workspace().name == "dynamic")
-- Removing active workspace resets active_workspace to nil
assert(oculus.remove_workspace("dynamic"), "remove_workspace succeeds")
assert(workspace.find(oculus.config, "dynamic") == nil, "workspace is removed")
assert(oculus.get_workspace() == nil, "active workspace was reset to nil")
-- 6. Persistence across setups
local persist_state = dir .. "/persist-test.json"

oculus.setup({
  state_file = persist_state,
  persist_projects = true,
  projects = sample_projects,
  workspaces = {
    {
      name = "persisted-ws",
      description = "Should persist",
      projects = { "bytecodealliance/wasmtime" },
    },
  },
  active_workspace = "persisted-ws",
})

-- Verify active and saved
assert(oculus.get_workspace().name == "persisted-ws")
local storage = require("oculus.storage")
assert(storage.save(persist_state, oculus.config))
-- Reset config completely and reload from state
oculus.config = vim.deepcopy(oculus.defaults or {})

oculus.setup({
  state_file = persist_state,
  persist_projects = true,
})

assert(#oculus.workspaces() == 1, "workspace restored from saved state")
assert(oculus.workspaces()[1].name == "persisted-ws")
assert(oculus.get_workspace() ~= nil and oculus.get_workspace().name == "persisted-ws", "active workspace restored from saved state")
-- 7. User command :OculusWorkspace and completion
require("oculus")
-- Load plugin commands
local plugin_path = vim.fn.getcwd() .. "/plugin/oculus.lua"
dofile(plugin_path)
-- Test completions
local commands = vim.api.nvim_get_commands({})
assert(commands.OculusWorkspace ~= nil, "OculusWorkspace command registered")
-- Retrieve completion function
local complete_fn = nil
-- Inspect command info
local cmd_info = vim.api.nvim_get_commands({})["OculusWorkspace"]
assert(cmd_info, "cmd_info found")
-- Run command without args (listing)
local notifications = {}
local orig_notify = vim.notify

vim.notify = function(msg, level)
  notifications[#notifications + 1] = { msg = msg, level = level }
end

vim.cmd("OculusWorkspace")
assert(#notifications > 0, "OculusWorkspace produced notification")
assert(notifications[#notifications].msg:find("persisted-ws", 1, true), "listing includes persisted-ws")
assert(notifications[#notifications].msg:find("(active)", 1, true), "listing marks active workspace")
-- Switch workspace via command
notifications = {}
vim.cmd("OculusWorkspace none")
assert(oculus.get_workspace() == nil, "OculusWorkspace none cleared active workspace")
notifications = {}
vim.cmd("OculusWorkspace persisted-ws")
assert(oculus.get_workspace().name == "persisted-ws", "OculusWorkspace persisted-ws activated workspace")
-- Switch to non-existent
notifications = {}
vim.cmd("OculusWorkspace bogus")
assert(#notifications > 0)
assert(notifications[#notifications].msg:find("not found"), "warns on non-existent workspace")
-- 8. Consumer scoping in investigations prompt
local investigations = require("oculus.investigations")
local orig_find_repo = require("oculus.local_activity").find_repository
local orig_ui_select = vim.ui.select
local passed_choices = nil
local passed_prompt = nil

require("oculus.local_activity").find_repository = function(project, cfg, cb)
  -- Return dummy path for all projects
  cb("/mock/" .. project.repository)
end

vim.ui.select = function(items, opts, cb)
  passed_choices = items
  passed_prompt = opts.prompt
  -- Cancel select
  cb(nil)
end

-- Active workspace is "persisted-ws" which only has "bytecodealliance/wasmtime"
oculus.config.projects = sample_projects
oculus.set_workspace("persisted-ws")
-- Call investigations.prompt
-- We can simulate prompt by asking for consumer directly or stepping through
local orig_ui_input = vim.ui.input

-- When prompt is invoked, it asks repository -> head -> base -> producer_manifest -> consumer
-- Let's stub ui.input to immediately call cb with default
vim.ui.input = function(opts, cb)
  cb(opts.default or "mock_value")
end

investigations.prompt(oculus.config, { repository = "/tmp/repo" })
assert(passed_choices ~= nil, "ui.select was called for consumer selection")
assert(passed_prompt:find("persisted%-ws"), "prompt title includes active workspace name")
-- Choice 1 should be wasmtime, Choice 2 should be "Choose another local repository…"
assert(#passed_choices == 2, "choices limited to active workspace projects + 'Choose another...'")
assert(passed_choices[1].label:find("wasmtime"), "first choice is wasmtime")
-- 9. UI rendering with active workspace in legacy mode
local window = require("oculus.window")

oculus.setup({
  state_file = dir .. "/legacy-ui-state.json",
  projects = sample_projects,
  workspaces = ws_list,
  active_workspace = "wasm",
})

oculus.open()
assert(window.state.win and vim.api.nvim_win_is_valid(window.state.win), "window is open")
local buf_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
local buf_text = table.concat(buf_lines, "\n")
assert(buf_text:find("PROJECTS · WASM", 1, true), "header includes active workspace name")
assert(buf_text:find("bytecodealliance/wasmtime", 1, true), "shows wasmtime")
assert(buf_text:find("bytecodealliance/wit-bindgen", 1, true), "shows wit-bindgen")
assert(not buf_text:find("ratatui-org/ratatui", 1, true), "filters out ratatui when wasm is active")
assert(not buf_text:find("W workspace", 1, true), "footer is removed from buffer")
window._toggle_shortcuts()
local shortcuts_text = table.concat(vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false), "\n")
assert(shortcuts_text:find("Select or switch project workspace", 1, true), "shortcuts displays W workspace command")
window._toggle_shortcuts()
-- Toggle filter off: should show all projects
assert(window.toggle_workspace_filter() == false, "toggle_workspace_filter returned false (off)")
buf_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
buf_text = table.concat(buf_lines, "\n")
assert(buf_text:find("PROJECTS", 1, true), "header reverts to PROJECTS when filter off")
assert(buf_text:find("ratatui-org/ratatui", 1, true), "shows ratatui when filter is toggled off")
-- Toggle filter back on
assert(window.toggle_workspace_filter() == true, "toggle_workspace_filter returned true (on)")
buf_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
buf_text = table.concat(buf_lines, "\n")
assert(buf_text:find("PROJECTS · WASM", 1, true), "header back to PROJECTS · WASM")
assert(not buf_text:find("ratatui-org/ratatui", 1, true), "ratatui hidden again")
oculus.close()
-- 10. UI rendering with active workspace in tracking mode
local tracking_path = dir .. "/ui-tracking.json"

vim.fn.writefile({
  vim.json.encode({
    version = 1,
    projects = {
      {
        name = "Wasm Group",
        children = {
          { repository = "bytecodealliance/wasmtime", provider = "github" },
        },
      },
      {
        name = "Terminal Group",
        children = {
          { repository = "ratatui-org/ratatui", provider = "github" },
        },
      },
    },
    users = {},
  }),
}, tracking_path)

oculus.setup({
  tracking_file = tracking_path,
  state_file = dir .. "/tracking-ui-state.json",
  workspaces = ws_list,
  active_workspace = "wasm",
})

oculus.open()
assert(window.state.win and vim.api.nvim_win_is_valid(window.state.win))
buf_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
buf_text = table.concat(buf_lines, "\n")
assert(buf_text:find("PROJECTS · WASM", 1, true), "tracking header has PROJECTS · WASM")
assert(buf_text:find("Wasm Group", 1, true), "group with matching wasm project is visible")
assert(not buf_text:find("Terminal Group", 1, true), "group with only non-wasm project is filtered out")
-- Toggle filter off in tracking mode
assert(window.toggle_workspace_filter() == false)
buf_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
buf_text = table.concat(buf_lines, "\n")
assert(buf_text:find("Terminal Group", 1, true), "Terminal Group shown when filter off")
oculus.close()
-- 11. Window keybinding W and prompt_select_workspace
oculus.open()
-- Verify 'W' mapping exists on buffer
local keymaps = vim.api.nvim_buf_get_keymap(window.state.buf, "n")
local found_w = false

for _, km in ipairs(keymaps) do
  if km.lhs == "W" then
    found_w = true
    break
  end
end

assert(found_w, "W keymap registered on buffer")

-- Test prompt_select_workspace flows:
-- a) Switch workspace via prompt
vim.ui.select = function(items, opts, cb)
  for _, item in ipairs(items) do
    if item.ws and item.ws.name == "tui" then
      cb(item)
      return
    end
  end

  cb(nil)
end

window.prompt_select_workspace()
assert(oculus.get_workspace().name == "tui", "switched to tui workspace via prompt")
buf_lines = vim.api.nvim_buf_get_lines(window.state.buf, 0, -1, false)
buf_text = table.concat(buf_lines, "\n")
assert(buf_text:find("PROJECTS · TUI", 1, true), "header updated to PROJECTS · TUI")

-- b) Toggle filter via prompt
vim.ui.select = function(items, opts, cb)
  for _, item in ipairs(items) do
    if item.kind == "toggle_filter" then
      cb(item)
      return
    end
  end

  cb(nil)
end

window.prompt_select_workspace()
assert(window.state.workspace_filter_enabled == false, "workspace filter toggled off via prompt")

-- c) Clear active workspace via prompt
vim.ui.select = function(items, opts, cb)
  for _, item in ipairs(items) do
    if item.kind == "clear" then
      cb(item)
      return
    end
  end

  cb(nil)
end

window.prompt_select_workspace()
assert(oculus.get_workspace() == nil, "active workspace cleared via prompt")

-- d) Create new workspace via prompt
vim.ui.select = function(items, opts, cb)
  for _, item in ipairs(items) do
    if item.kind == "new" then
      cb(item)
      return
    end
  end

  cb(nil)
end

vim.ui.input = function(opts, cb)
  cb("brand-new-ws")
end

window.prompt_select_workspace()
assert(oculus.get_workspace().name == "brand-new-ws", "new workspace created and activated via prompt")
oculus.close()
-- Clean up stubs
vim.notify = orig_notify
require("oculus.local_activity").find_repository = orig_find_repo
vim.ui.select = orig_ui_select
vim.ui.input = orig_ui_input
vim.fn.delete(dir, "rf")
