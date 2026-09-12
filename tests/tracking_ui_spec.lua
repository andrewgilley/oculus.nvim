vim.opt.runtimepath:prepend(vim.fn.getcwd())
local oculus = require('oculus')
local window = require('oculus.window')
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local path = dir .. '/tracking.json'
local function write(tree) vim.fn.writefile({vim.json.encode(tree)}, path) end
write({version=1,projects={{name='Tools',children={{name='Nested',children={{repository='a/b',provider='github'}}}}}},users={{name='Friends',children={{username='alice',provider='github'}}}}})
oculus.setup({tracking_file=path,state_file=dir..'/state.json'})
window.open(oculus.config)

local function key(lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(window.state.buf,'n')) do
    if map.lhs == lhs then assert(map.callback, lhs); map.callback(); return end
  end

  error('missing mapping '..lhs)
end

local function select_label(label)
  for line, target in pairs(window.state.line_targets) do
    if target.name == label or target.username == label or (target.project and target.project.repository == label) then
      vim.api.nvim_win_set_cursor(window.state.win,{line,0}); return target
    end
  end

  error('missing target '..label..' '..vim.inspect(window.state.line_targets))
end

select_label('Tools'); key('<CR>')
select_label('Nested'); key('<Right>')
select_label('a/b'); key('<Left>')
select_label('Nested'); key('<Left>')
select_label('Tools'); key('u')
select_label('Friends'); key('<CR>'); select_label('alice')
local function disk() return vim.json.decode(table.concat(vim.fn.readfile(path),'\n')) end
local input = vim.ui.input
vim.ui.input = function(_, callback) callback('Colleagues') end
key('f')
vim.ui.input = input
assert(disk().users[1].children[2].name == 'Colleagues', 'group added in current user group')
select_label('Colleagues'); key('<CR>')
assert(window._add_contributor({username='bob',provider='github'}))
assert(disk().users[1].children[2].children[1].username == 'bob', 'UI user add persisted inside nested group')
select_label('bob'); key('r')
assert(#disk().users[1].children[2].children == 0, 'UI removal persisted')
key('<Left>'); select_label('Colleagues'); key('r')
assert(#disk().users[1].children == 1, 'UI group removal persisted')
key('p'); select_label('Tools'); key('<CR>'); select_label('Nested'); key('<CR>')
assert(window._add_project({repository='c/d',provider='github'}))
assert(disk().projects[1].children[1].children[2].repository == 'c/d')
select_label('a/b')
local before_down = vim.api.nvim_win_get_cursor(window.state.win)[1]
key('<Down>')
assert(vim.api.nvim_win_get_cursor(window.state.win)[1] ~= before_down, 'real down binding navigates tracking siblings')
assert(window.state.line_targets[vim.api.nvim_win_get_cursor(window.state.win)[1]].project.repository == 'c/d', 'down selects next leaf')
select_label('c/d'); key('m'); select_label('a/b'); key('m')
assert(disk().projects[1].children[1].children[1].repository == 'c/d', 'sibling reorder persisted')
select_label('c/d'); key('m'); key('<Left>')
assert(disk().projects[1].children[2].repository == 'c/d', 'move leaf to parent persisted')
select_label('c/d'); key('m'); select_label('Nested'); key('<Right>')
assert(disk().projects[1].children[1].children[2].repository == 'c/d', 'move leaf into group persisted')
select_label('Nested'); key('m'); key('<Left>')
assert(disk().projects[2].name == 'Nested', 'move group to parent persisted')
select_label('Nested'); key('m'); select_label('Tools'); key('m')
assert(disk().projects[1].name == 'Nested', 'group reorder persisted')
key('u'); select_label('alice'); key('m'); key('<Left>')
assert(disk().users[2].username == 'alice', 'users move to parent persisted')
select_label('alice'); key('m'); select_label('Friends'); key('<Right>')
assert(disk().users[1].children[1].username == 'alice', 'users move into group persisted')
local select = vim.ui.select

vim.ui.select = function(items, _, callback)
  for _, item in ipairs(items) do if item.label == '/' then callback(item); return end end
  error('root destination missing')
end

select_label('Friends'); key('<CR>'); select_label('alice'); key('M')
vim.ui.select = select
assert(disk().users[2].username == 'alice', 'M destination picker moves users')
-- Nonempty removal requires consent; cancellation preserves exact bytes/tree/UI.
key('p'); select_label('Nested')
local confirm = vim.fn.confirm
local before_remove = table.concat(vim.fn.readfile(path, 'b'), '\n')
local before_tree = vim.deepcopy(oculus.config._tracking.tree)
local before_cursor = vim.api.nvim_win_get_cursor(window.state.win)
local before_paths = vim.deepcopy(window.state.tracking_paths)
key('m')
local before_move = vim.deepcopy(window.state.tracking_move)
local confirmations = 0
vim.fn.confirm = function(message, choices, default)
  confirmations = confirmations + 1
  assert(message:match('promot'), 'confirmation explains child promotion')
  assert(choices == '&Cancel\n&Remove group' and default == 1, 'Cancel is first/default')
  return 1
end
key('r')
assert(confirmations == 1, 'nonempty removal must prompt')
assert(table.concat(vim.fn.readfile(path, 'b'), '\n') == before_remove, 'cancel preserves exact file bytes')
assert(vim.deep_equal(oculus.config._tracking.tree, before_tree), 'cancel preserves tree')
assert(vim.deep_equal(vim.api.nvim_win_get_cursor(window.state.win), before_cursor), 'cancel preserves cursor')
assert(vim.deep_equal(window.state.tracking_paths, before_paths), 'cancel preserves browsing paths')
assert(vim.deep_equal(window.state.tracking_move, before_move), 'cancel preserves pending move')
vim.fn.confirm = function() return 0 end
key('r')
assert(table.concat(vim.fn.readfile(path, 'b'), '\n') == before_remove, 'dismiss preserves file')
vim.fn.confirm = function() return 2 end
key('r')
vim.fn.confirm = confirm
assert(disk().projects[1].repository == 'a/b' and disk().projects[2].repository == 'c/d', 'group removal retains descendants in order')
write({version=1,projects={{repository='fresh/repo',provider='github'}},users={}})
vim.cmd('runtime plugin/oculus.lua')
vim.cmd('OculusReloadTracking')
key('p'); select_label('fresh/repo')
assert(#oculus.config.contributors == 0)
vim.fn.writefile({'invalid json'}, path)
local notify = vim.notify
vim.notify = function() end
assert(not oculus.reload_tracking())
select_label('fresh/repo'); key('r')
assert(oculus.config.projects[1].repository == 'fresh/repo')
assert(table.concat(vim.fn.readfile(path),'\n') == 'invalid json')
vim.notify = notify
-- Public move command uses nested group paths, not legacy flat folders.
write({version=1,projects={{repository='cmd/repo',provider='github'},{name='Outer',children={{name='Inner',children={}}}}},users={}})
assert(oculus.reload_tracking())
vim.cmd('OculusMoveToDirectory cmd/repo /Outer/Inner/')
assert(disk().projects[1].name == 'Outer' and disk().projects[1].children[1].children[1].repository == 'cmd/repo', 'public move command persists nested destination')
-- The actual provider/input dialog feeds the same transactional add path.
write({version=1,projects={},users={}})
assert(oculus.reload_tracking())
key('u'); key('a')

local function dialog_key(buf, lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(buf,'n')) do
    if map.lhs == lhs then map.callback(); return end
  end

  error('missing dialog key '..lhs)
end

dialog_key(window.state.add_dialog_buf, '<CR>')
vim.api.nvim_buf_set_lines(window.state.add_input_buf,0,-1,false,{'dialog-user'})
dialog_key(window.state.add_input_buf, '<CR>')
assert(disk().users[1].username == 'dialog-user', 'actual add dialog writes tracking file')
assert(window._add_contributor({username='https://codeberg.org/url-user'}))
assert(disk().users[2].username == 'url-user' and disk().users[2].provider == 'codeberg', 'UI URL normalization retained')
key('p')
assert(window._add_project({repository='git@github.com:url/repo.git'}))
assert(disk().projects[1].repository == 'url/repo' and disk().projects[1].provider == 'github')
select_label('url/repo')
vim.api.nvim_exec_autocmds('CursorMoved',{buffer=window.state.buf})
assert(window.state.preview_items[2][1] == 'PROJECT', 'tracking project preview retained')
assert(vim.api.nvim_buf_line_count(window.state.buf) >= vim.api.nvim_win_get_height(window.state.win) - 2, 'tracking list keeps padded interior layout')
select_label('url/repo'); key('m')
local ns = vim.api.nvim_get_namespaces().oculus_contributor_selection
local marked = false

for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(window.state.buf,ns,0,-1,{details=true})) do
  if mark[4].hl_group == 'OculusMoveTarget' then marked = true end
end

assert(marked, 'pending move is visibly highlighted')
key('u')
assert(not window.state.tracking_move, 'switching lists cancels pending moves')
select_label('url-user')
vim.api.nvim_exec_autocmds('CursorMoved',{buffer=window.state.buf})
assert(window.state.preview_items[2][1] == 'USER' and window.state.preview_items[4][1] == '@url-user', 'tracking user preview retained')
-- Structural edits cancel numeric move sources before another move can retarget them.
local function project(repository) return {repository=repository,provider='github'} end
local function current_target()
  return window.state.line_targets[vim.api.nvim_win_get_cursor(window.state.win)[1]]
end
local scenarios = {
  {name='selected source deletion', earlier=project('a/a'), source='a/a', remove='a/a', expected='b/b'},
  {name='earlier sibling deletion', earlier=project('a/a'), source='b/b', remove='a/a', expected='b/b'},
  {name='earlier empty group removal', earlier={name='Earlier',children={}}, source='b/b', remove='Earlier', expected='b/b'},
  {name='earlier group promotion', earlier={name='Earlier',children={project('x/x'),{name='Child',children={project('y/y')}}}}, source='b/b', remove='Earlier', expected='x/x'},
}
for _, scenario in ipairs(scenarios) do
  write({version=1,projects={{name='Outer',children={scenario.earlier,project('b/b'),project('c/c')}}},users={}})
  assert(oculus.reload_tracking())
  key('p'); select_label('Outer'); key('<CR>')
  select_label(scenario.source); key('m'); select_label(scenario.remove)
  vim.fn.confirm = function() return 2 end
  key('r')
  vim.fn.confirm = confirm
  assert(not window.state.tracking_move, scenario.name .. ': cancels pending move')
  assert(vim.deep_equal(window.state.tracking_paths.projects, {1}), scenario.name .. ': keeps group path')
  assert(current_target().project.repository == scenario.expected, scenario.name .. ': selects adjacent surviving child')
  if scenario.name == 'earlier group promotion' then
    assert(disk().projects[1].children[2].children[1].repository == 'y/y', 'promotion preserves nested descendants')
  end
  local after_remove = table.concat(vim.fn.readfile(path, 'b'), '\n')
  select_label('c/c'); key('m')
  assert(table.concat(vim.fn.readfile(path, 'b'), '\n') == after_remove, scenario.name .. ': next m selects, never moves stale source')
  assert(window.state.tracking_move, scenario.name .. ': new source selected')
  key('<Esc>')
end
-- Adding a group also cancels a pending source without jumping to ../.
select_label('b/b'); key('m')
vim.ui.input = function(_, callback) callback('Added') end
key('f')
vim.ui.input = input
assert(not window.state.tracking_move, 'successful group addition cancels pending move')
assert(current_target().project.repository == 'b/b', 'addition preserves logical cursor')
assert(vim.deep_equal(window.state.tracking_paths.projects, {1}), 'addition preserves group path')
select_label('b/b'); key('m')
local pending_before_failure = vim.deepcopy(window.state.tracking_move)
local bytes_before_failure = table.concat(vim.fn.readfile(path, 'b'), '\n')
vim.ui.input = function(_, callback) callback('Added') end
vim.notify = function() end
key('f') -- Duplicate group name: rejected, not a successful structural mutation.
vim.ui.input = input
vim.notify = notify
assert(vim.deep_equal(window.state.tracking_move, pending_before_failure), 'failed addition retains pending source')
assert(table.concat(vim.fn.readfile(path, 'b'), '\n') == bytes_before_failure, 'failed addition preserves file')
assert(current_target().project.repository == 'b/b', 'failed addition preserves cursor')
key('<Esc>')
window.close()
-- Failed initial load retains saved lists in the UI, not an empty screen.
oculus.setup({tracking_file=dir..'/missing.json',state_file=dir..'/state.json',projects={{repository='saved/repo',provider='github'}},contributors={}})
window.open(oculus.config)
select_label('saved/repo')
window.close()
vim.fn.delete(dir,'rf')
print('tracking_ui_spec: passed')
