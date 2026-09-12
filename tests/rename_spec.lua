vim.opt.runtimepath:prepend(vim.fn.getcwd())
local oculus = require('oculus')
local window = require('oculus.window')
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local path = dir .. '/tracking.json'
local function write(tree) vim.fn.writefile({vim.json.encode(tree)}, path) end
local function disk() return vim.json.decode(table.concat(vim.fn.readfile(path), '\n')) end

local function select_label(label)
  for line, target in pairs(window.state.line_targets) do
    if target.name == label or target.username == label or (target.project and (target.project.repository == label or target.project.name == label)) then
      vim.api.nvim_win_set_cursor(window.state.win, {line, 0})
      return line
    end
  end

  error('missing label: ' .. label)
end

local function key(lhs)
  for _, map in ipairs(vim.api.nvim_buf_get_keymap(window.state.buf, 'n')) do
    if map.lhs == lhs then map.callback(); return end
  end

  error('missing key: ' .. lhs)
end

write({version=1,projects={{name='Tools',children={{name='Nested',children={{repository='a/b',provider='codeberg',extra='keep'}}}}}},users={{name='Friends',children={{username='alice',provider='github'}}}}})
oculus.setup({tracking_file=path,state_file=dir .. '/state.json'})
window.open(oculus.config)
vim.cmd('runtime plugin/oculus.lua')
select_label('Tools')
vim.cmd('OculusRename Dev Tools')
assert(disk().projects[1].name == 'Dev Tools', 'command renames selected group with spaces')
select_label('Dev Tools')
assert(not vim.wo[window.state.win].cursorline)
key('<CR>'); select_label('Nested'); key('<CR>'); select_label('a/b')
vim.cmd('OculusRename Repository Display')
assert(vim.deep_equal(disk().projects[1].children[1].children[1], {repository='a/b',provider='codeberg',extra='keep',name='Repository Display'}), 'leaf identity and metadata preserved')
select_label('Repository Display')
local input, notify = vim.ui.input, vim.notify
vim.notify = function() end
local function bytes() return table.concat(vim.fn.readfile(path, 'b'), '\n') end

local function unchanged_input(value)
  local before, tree = bytes(), vim.deepcopy(oculus.config._tracking.tree)
  local cursor = vim.api.nvim_win_get_cursor(window.state.win)
  cursor[2] = 3
  vim.api.nvim_win_set_cursor(window.state.win, cursor)
  local paths = vim.deepcopy(window.state.tracking_paths)

  vim.ui.input = function(opts, callback)
    assert(opts.default == 'Repository Display')
    callback(value)
  end

  vim.cmd('OculusRename')
  assert(bytes() == before and vim.deep_equal(tree, oculus.config._tracking.tree), 'cancel/blank preserves file and tree')
  assert(vim.deep_equal(cursor, vim.api.nvim_win_get_cursor(window.state.win)), 'cancel/blank preserves exact cursor')
  assert(vim.deep_equal(paths, window.state.tracking_paths), 'cancel/blank preserves paths')
end

unchanged_input(nil)
unchanged_input('   ')
-- R opens the same prefilled text prompt from the list.
select_label('Repository Display')

vim.ui.input = function(opts, callback)
  assert(opts.default == 'Repository Display', 'R prompt is prefilled with the current name')
  callback('Via Key')
end

key('R')
assert(disk().projects[1].children[1].children[1].name == 'Via Key', 'R renames the selected item')
vim.ui.input = input
vim.notify = notify
window.close()
vim.fn.delete(dir, 'rf')
print('rename_spec: passed')
