local M = {}

local function scope(state)
  local kind = state.community_view == 'users' and 'users' or 'projects'
  state.tracking_paths = state.tracking_paths or {projects={}, users={}}
  return kind, state.tracking_paths[kind]
end

local function children(tree, kind, path)
  local nodes = tree[kind]

  for _, index in ipairs(path) do
    if not nodes[index] or not nodes[index].children then return nil end
    nodes = nodes[index].children
  end

  return nodes
end

local function label(node)
  return (node.name or node.repository or ('@' .. node.username)) .. (node.children and '/' or '')
end

-- Mirror the legacy directory preview: header, then direct children without
-- repeating the group's own name. The ../ row previews the parent group.
function M.preview_items(state, target, max_visible)
  local kind, path = scope(state)
  local tree = state.opts._tracking and state.opts._tracking.tree
  local group = vim.deepcopy(path)
  if target.kind == 'tracking_parent' then table.remove(group) else group[#group + 1] = target.tracking_index end
  local nodes = tree and children(tree, kind, group) or {}
  local items = {[2]={'GROUP', 'Title'}}
  if #nodes == 0 then items[4] = {'(empty group)', 'Comment'}; return items end
  local shown = #nodes <= max_visible and #nodes or math.max(1, max_visible - 1)

  for index = 1, shown do
    items[3 + index] = {label(nodes[index]), nodes[index].children and 'Directory' or 'Identifier'}
  end

  if shown < #nodes then items[4 + shown] = {('... and %d more'):format(#nodes - shown), 'Comment'} end
  return items
end

function M.render(state)
  local kind, path = scope(state)
  local tree = state.opts._tracking and state.opts._tracking.tree
  -- On an initial load error show the retained legacy membership read-only.
  tree = tree or {projects=state.opts.projects or {}, users=state.opts.contributors or {}}
  local nodes = tree and children(tree, kind, path)
  if not nodes then state.tracking_paths[kind] = {}; path = {}; nodes = tree and tree[kind] or {} end
  state.view = 'contributors'
  state.line_targets = {}
  local labels, current = {}, tree and tree[kind]

  for _, index in ipairs(path) do
    labels[#labels + 1] = current[index].name
    current = current[index].children
  end

  local lines = {'', '  ACTIVITY', '', '  ' .. kind:upper() .. (#labels > 0 and ' / ' .. table.concat(labels, ' / ') or '')}
  if state.opts._tracking and state.opts._tracking.error then lines[#lines + 1] = '  Tracking error: :OculusReloadTracking' end

  if #path > 0 then
    lines[#lines + 1] = '  ../'
    state.line_targets[#lines] = {kind='tracking_parent', name='..'}
  end

  for index, node in ipairs(nodes) do
    local target

    if node.children then target = {kind='tracking_group', name=node.name}
    elseif kind == 'projects' then target = {kind='project', project=vim.deepcopy(node)}
    else target = vim.deepcopy(node) end

    target.tracking_index = index
    lines[#lines + 1] = '  ' .. label(node)
    state.line_targets[#lines] = target
  end

  if #nodes == 0 then lines[#lines + 1] = '  Empty list. a add item · f add group' end
  return lines
end

local function change(state, edit, completing_move, preserve_failed_view)
  local target = state.win and vim.api.nvim_win_is_valid(state.win)
    and state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]]

  local index = target and target.tracking_index
  local ok, err = require('oculus.tracking').mutate(state.opts, edit)

  if ok then state.tracking_move = nil
  else vim.notify('Oculus: ' .. tostring(err), vim.log.levels.ERROR) end

  if not ok and preserve_failed_view then return ok, err end
  require('oculus.window').refresh_tracking()

  -- Adds append and removals promote in place: retain the current child slot,
  -- or its preceding sibling when removing the last child, not the ../ row.
  if not completing_move and index and state.win and vim.api.nvim_win_is_valid(state.win) then
    local kind, path = scope(state)
    local tree = state.opts._tracking and state.opts._tracking.tree
    local nodes = tree and children(tree, kind, path)
    index = math.min(index, nodes and #nodes or 0)

    for line, item in pairs(state.line_targets) do
      if item.tracking_index == index then
        vim.api.nvim_win_set_cursor(state.win, {line, 0})
        vim.api.nvim_exec_autocmds('CursorMoved', {buffer=state.buf})
        break
      end
    end
  end

  return ok, err
end

function M.rename(state, name)
  local kind, path = scope(state)
  path = vim.deepcopy(path)
  local target = state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]]
  local snapshot = state.opts._tracking and state.opts._tracking.tree
  local nodes = snapshot and children(snapshot, kind, path)
  local index = target and target.tracking_index
  local node = nodes and index and nodes[index]

  if not node then
    vim.notify('Oculus: select a group, project, or user to rename', vim.log.levels.WARN)
    return false
  end

  local function apply(value)
    if value == nil then return false end

    return change(state, function(tree)
      -- A delayed input callback must never rename a replacement at the same index.
      assert(state.opts._tracking.tree == snapshot, 'List changed; select the item and rename again')
      assert(type(value) == 'string', 'name must be a string')
      children(tree, kind, path)[index].name = vim.trim(value)
    end, false, true)
  end

  if name ~= nil then return apply(name) end
  vim.ui.input({prompt='Display name: ', default=node.name or node.repository or node.username}, apply)
end

function M.add(state, node, list)
  local kind, path = scope(state)
  if list and list ~= kind then path = state.tracking_paths[list]; kind = list end
  path = vim.deepcopy(path)

  return change(state, function(tree)
    table.insert(assert(children(tree, kind, path), 'Group no longer exists'), vim.deepcopy(node))
  end)
end

function M.move(state, destination, position)
  local moving = state.tracking_move
  if not moving then return nil, 'Select an item with m first' end
  local kind = scope(state)
  if moving.kind ~= kind then state.tracking_move = nil; return nil, 'Cannot move across lists' end
  local source_path = vim.deepcopy(moving.path)
  source_path[#source_path + 1] = moving.index

  if #destination >= #source_path then
    local descendant = true
    for i, index in ipairs(source_path) do if destination[i] ~= index then descendant = false end end

    if descendant then
      vim.notify('Oculus: cannot move a group into itself or its descendants', vim.log.levels.ERROR)
      return nil
    end
  end

  state.tracking_move = nil

  return change(state, function(tree)
    local source = assert(children(tree, kind, moving.path))
    local dest = assert(children(tree, kind, destination))
    local node = assert(table.remove(source, moving.index))
    table.insert(dest, math.min(position or (#dest + 1), #dest + 1), node)
  end, true)
end

function M.move_named(state, project, name)
  local kind, path = scope(state)
  local tree = state.opts._tracking and state.opts._tracking.tree
  if not tree then return nil, 'Tracking has not loaded; :OculusReloadTracking' end
  local sources, destinations = {}, {}

  local function visit(nodes, parent, label)
    for index, node in ipairs(nodes) do
      local next_path = vim.deepcopy(parent)
      next_path[#next_path + 1] = index

      if node.children then
        local full = label .. node.name .. '/'

        if name == full or (vim.deep_equal(parent, path) and name == node.name) then
          destinations[#destinations + 1] = next_path
        end

        visit(node.children, next_path, full)
      elseif project and node.repository then
        local repository = type(project) == 'table' and project.repository or project

        if repository == node.repository or repository == node.provider .. ':' .. node.repository then
          sources[#sources + 1] = {kind=kind,path=vim.deepcopy(parent),index=index}
        end
      end
    end
  end

  if project then kind = 'projects'; state.community_view = 'projects' end
  if name == '/' or name == '' or name == nil then destinations[1] = {} end
  visit(tree[kind], {}, '/')

  if not project then
    local target = state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]]
    if target and target.tracking_index then sources[1] = {kind=kind,path=vim.deepcopy(path),index=target.tracking_index} end
  end

  if #sources ~= 1 or #destinations ~= 1 then
    local err = 'Unknown or ambiguous source/group; use M to select a destination'
    vim.notify('Oculus: ' .. err, vim.log.levels.ERROR)
    return nil, err
  end

  state.tracking_move = sources[1]
  return M.move(state, destinations[1])
end

function M.handle(state, action, target)
  if not state.opts.tracking_file or state.view ~= 'contributors' then return false end
  local kind, path = scope(state)

  if action == 'cancel' and state.tracking_move then
    state.tracking_move = nil
    require('oculus.window').refresh_tracking()
    return true
  elseif action == 'move' then
    if target and target.tracking_index then
      if state.tracking_move then M.move(state, path, target.tracking_index)
      else state.tracking_move = {kind=kind,path=vim.deepcopy(path),index=target.tracking_index} end
    end

    return true
  elseif action == 'destination' then
    if not target or not target.tracking_index then return true end
    local tree = state.opts._tracking and state.opts._tracking.tree
    if not tree then return true end
    state.tracking_move = {kind=kind,path=vim.deepcopy(path),index=target.tracking_index}
    local source = vim.deepcopy(path)
    source[#source + 1] = target.tracking_index
    local items = {{label='/',path={}}}

    local function collect(nodes, parent, label)
      for index, node in ipairs(nodes) do
        if node.children then
          local next_path = vim.deepcopy(parent)
          next_path[#next_path + 1] = index

          if not vim.deep_equal(next_path, source) then
            local name = label .. node.name .. '/'
            items[#items + 1] = {label=name,path=next_path}
            collect(node.children, next_path, name)
          end
        end
      end
    end

    collect(tree[kind], {}, '/')

    vim.ui.select(items, {prompt='Move to group', format_item=function(item) return item.label end}, function(item)
      if item then M.move(state, item.path) else state.tracking_move = nil end
    end)

    return true
  elseif action == 'group' then
    vim.ui.input({prompt='Group name: '}, function(name)
      if name then M.add(state, {name=name, children={}}) end
    end)

    return true
  elseif action == 'remove' then
    if target and target.tracking_index then
      local index = target.tracking_index
      local tree = state.opts._tracking and state.opts._tracking.tree
      local nodes = tree and children(tree, kind, path)
      local node = nodes and nodes[index]

      if node and node.children and #node.children > 0 then
        local answer = vim.fn.confirm('Remove group "' .. node.name .. '"? Its children will be promoted to this list; descendants are preserved.', '&Cancel\n&Remove group', 1)
        if answer ~= 2 then return true end
      end

      change(state, function(tree)
        local nodes = children(tree, kind, path)
        local removed = table.remove(nodes, index)

        -- Removing a folder never deletes the tracked entries inside it.
        for offset, node in ipairs(removed.children or {}) do
          table.insert(nodes, index + offset - 1, node)
        end
      end)
    end

    return true
  end

  if action == 'left' or ((action == 'enter' or action == 'right') and target and target.kind == 'tracking_parent') then
    if state.tracking_move and #path > 0 then
      local parent = vim.deepcopy(path)
      table.remove(parent)
      if not M.move(state, parent) then return true end
    end

    table.remove(path)
  elseif (action == 'enter' or action == 'right') and target and target.kind == 'tracking_group' then
    if state.tracking_move then
      local destination = vim.deepcopy(path)
      destination[#destination + 1] = target.tracking_index
      M.move(state, destination)
      return true
    end

    path[#path + 1] = target.tracking_index
  else return false end

  require('oculus.window').refresh_tracking()
  return true
end

return M
