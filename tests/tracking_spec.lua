vim.opt.runtimepath:prepend(vim.fn.getcwd())
local oculus = require('oculus')
local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
local path = dir .. '/tracking.json'

local function write(value)
  vim.fn.writefile({vim.json.encode(value)}, path)
end

write({version=1, projects={{name='Tools',children={{repository='a/b',provider='github',custom={color='red'}}}}}, users={{username='alice',provider='github'}}})
oculus.setup({tracking_file=path,state_file=dir..'/state.json'})
assert(#oculus.config.projects == 1 and oculus.config.projects[1].repository == 'a/b', 'tracking membership overrides defaults')
assert(oculus.config.contributors[1].username == 'alice')
assert(oculus.config._tracking.tree.projects[1].children[1].custom.color == 'red')
local window = require('oculus.window')
assert(window.state.opts == oculus.config, 'tracking commands have setup config before window opens')
assert(oculus.create_project_directory('Before open'))
assert(vim.json.decode(table.concat(vim.fn.readfile(path),'\n')).projects[2].name == 'Before open')
local tracking = require('oculus.tracking')

for _, bad in ipairs({
  {version=2,projects={},users={}},
  {version=1,projects={},users={{username='a',provider='bogus'}}},
  {version=1,projects={{repository='bad',provider='github'}},users={}},
  {version=1,projects={},users={{username='a',provider='github'},{name='group',children={{username='A',provider='github'}}}}},
  {version=1,projects={{name='g',children={}},{name='G',children={}}},users={}},
  {version=1,projects='bad',users={}},
}) do
  write(bad)
  local ok = tracking.load(oculus.config)
  assert(not ok, 'invalid schema must be rejected')
  assert(oculus.config.projects[1].repository == 'a/b', 'failed load retains membership')
  assert(oculus.config._tracking.error, 'failed load blocks writes')
end

write({version=1,projects={},users={}})
assert(tracking.load(oculus.config))

assert(tracking.mutate(oculus.config, function(tree)
  table.insert(tree.users, {username='bob',provider='github',custom={tag='keep'}})
end))

local bytes = table.concat(vim.fn.readfile(path), '\n')
assert(bytes:find('\n  "'), 'human readable JSON')
assert(vim.json.decode(bytes).users[1].custom.tag == 'keep')
write({version=1,projects={},users={{username='external',provider='github'}}})
assert(not tracking.mutate(oculus.config, function(tree) tree.users={} end), 'external edits block writes')
assert(vim.json.decode(table.concat(vim.fn.readfile(path),'\n')).users[1].username == 'external')
assert(oculus.config.contributors[1].username == 'bob', 'failed write retains UI membership')
local storage = require('oculus.storage')
local legacy = {projects={{repository='legacy/repo'}},contributors={{username='legacy'}},project_directories={'Old'},project_order={'old'}}
vim.fn.writefile({vim.json.encode(legacy)}, dir..'/state.json')
local before = table.concat(vim.fn.readfile(path),'\n')
assert(storage.save(dir..'/state.json',oculus.config))
assert(table.concat(vim.fn.readfile(path),'\n') == before, 'filter save must not touch externally edited tracking')
assert(storage.load(dir..'/state.json').projects[1].repository == 'legacy/repo', 'filter save preserves legacy membership')
assert(not storage.save(path,oculus.config), 'state_file cannot overwrite tracking_file')
assert(tracking.load(oculus.config))
vim.fn.delete(path)
assert(not tracking.mutate(oculus.config, function(tree) tree.users={} end), 'deleted file is not recreated')
assert(vim.fn.filereadable(path) == 0)
assert(not tracking.load(oculus.config))
assert(oculus.config.contributors[1].username == 'external')
write({version=1,projects={},users={}})
assert(tracking.load(oculus.config))
assert(vim.uv.fs_chmod(path, 292)) -- 0444
assert(not tracking.mutate(oculus.config, function(tree) tree.users={{username='blocked',provider='github'}} end), 'unwritable file rejects edits')
assert(#vim.json.decode(table.concat(vim.fn.readfile(path),'\n')).users == 0)
assert(vim.uv.fs_chmod(path, 420))
assert(tracking.load(oculus.config))
local cycle={version=1,projects={},users={}}
cycle.projects[1]={name='Cycle',children=cycle.projects}
assert(not tracking.validate(cycle), 'cycles rejected')
local ok = pcall(function() tracking.load({tracking_file={}}) end)
assert(ok, 'invalid path type reports an error rather than throwing')

for _, repository in ipairs({'owner/..','owner/.','../repo','./repo'}) do
  assert(not tracking.validate({version=1,projects={{repository=repository,provider='github'}},users={}}), 'dot path components rejected')
end

for _, username in ipairs({'.','..'}) do
  assert(not tracking.validate({version=1,projects={},users={{username=username,provider='github'}}}), 'dot usernames rejected')
end

vim.fn.delete(dir, 'rf')
print('tracking_spec: passed')
