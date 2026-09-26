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

-- Users always show their handle; display names only label groups/projects.
local function label(node)
  if node.username then return '@' .. node.username end
  return node.name or node.repository
end

local function node_matches_workspace(node, active_ws)
  if not active_ws or not active_ws.projects or #active_ws.projects == 0 then
    return true
  end

  if node.children then
    for _, child in ipairs(node.children) do
      if node_matches_workspace(child, active_ws) then
        return true
      end
    end

    return false
  end

  return require("oculus.workspace").matches_workspace(node, active_ws)
end

-- Show all of a group's descendants without repeating the selected group's own
-- name.
function M.preview_items(state, target, max_visible)
  if target and target.kind == 'directory_empty' then
    return {{'',''}, {'GROUP','Title'}, {'',''}, {'(empty group)', 'Comment'}}
  end

  local kind, path = scope(state)
  local tree = state.opts._tracking and state.opts._tracking.tree
  local group = vim.deepcopy(path)
  group[#group + 1] = target.tracking_index
  local nodes = tree and children(tree, kind, group) or {}
  local items = {[2]={'GROUP', 'Title'}}
  if #nodes == 0 then items[4] = {'(empty group)', 'Comment'}; return items end
  local descendants = {}

  local function collect(children)
    for _, node in ipairs(children) do
      descendants[#descendants + 1] = {
        label(node),
        node.children and 'Directory' or 'Identifier',
      }

      if node.children then collect(node.children) end
    end
  end

  collect(nodes)
  local shown = #descendants <= max_visible and #descendants or math.max(1, max_visible - 1)

  for index = 1, shown do
    items[3 + index] = descendants[index]
  end

  if shown < #descendants then
    items[4 + shown] = {('... and %d more'):format(#descendants - shown), 'Comment'}
  end

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
  local active_ws = require("oculus.workspace").get_active(state.opts)
  local filter_active = active_ws and state.workspace_filter_enabled ~= false and kind == "projects"
  local header_title = kind:upper()

  if filter_active then
    header_title = "PROJECTS · " .. active_ws.name:upper()
  end

  local lines = { "", "  " .. header_title, "" }
  if state.opts._tracking and state.opts._tracking.error then lines[#lines + 1] = '  Tracking error: :OculusReloadTracking' end
  local visible_count = 0

  for index, node in ipairs(nodes) do
    if not filter_active or node_matches_workspace(node, active_ws) then
      visible_count = visible_count + 1
      local target

      if node.children then target = {kind='tracking_group', name=node.name}
      elseif kind == 'projects' then target = {kind='project', project=vim.deepcopy(node)}
      else target = vim.deepcopy(node) end

      target.tracking_index = index
      lines[#lines + 1] = '  ' .. label(node)
      state.line_targets[#lines] = target
    end
  end

  if #nodes == 0 and kind == 'projects' then
    lines[#lines + 1] = '  Empty list. a add item · f add group'

    if #path > 0 then
      local parent_path = vim.deepcopy(path)
      local group_idx = table.remove(parent_path)
      local parent_nodes = tree and children(tree, kind, parent_path)
      local current_group = parent_nodes and parent_nodes[group_idx]

      if current_group then
        state.line_targets[#lines] = {
          kind = 'directory_empty',
          name = current_group.name,
          tracking_index = group_idx,
          parent_path = parent_path,
        }
      end
    end
  elseif visible_count == 0 and filter_active then
    lines[#lines + 1] = "  (no projects in workspace '" .. active_ws.name .. "')"
  end

  return lines
end

local function change(state, edit, completing_move, preserve_failed_view, selected_after)
  local target = state.win and vim.api.nvim_win_is_valid(state.win)
    and state.line_targets[vim.api.nvim_win_get_cursor(state.win)[1]]

  local index = target and target.tracking_index
  local ok, err = require('oculus.tracking').mutate(state.opts, edit)

  if ok then
    state.tracking_move = nil
    state.tracking_selected = selected_after
  else vim.notify('Oculus: ' .. tostring(err), vim.log.levels.ERROR) end

  if not ok and preserve_failed_view then return ok, err end
  require('oculus.window').refresh_tracking()

  -- Adds append and removals promote in place: retain the current child slot,
  -- or its preceding sibling when removing the last child.
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

  if target and target.kind == 'directory_empty' then
    path = vim.deepcopy(target.parent_path or {})
  end

  local snapshot = state.opts._tracking and state.opts._tracking.tree
  local nodes = snapshot and children(snapshot, kind, path)
  local index = target and target.tracking_index
  local node = nodes and index and nodes[index]

  if not node then
    vim.notify('Oculus: select a group, project, or user to rename', vim.log.levels.WARN)
    return false
  end

  -- Users are listed by handle, so renaming a user edits the username itself.
  local field = node.username and 'username' or 'name'

  local function apply(value)
    if value == nil then return false end

    return change(state, function(tree)
      -- A delayed input callback must never rename a replacement at the same index.
      assert(state.opts._tracking.tree == snapshot, 'List changed; select the item and rename again')
      assert(type(value) == 'string', 'name must be a string')
      local text = vim.trim(value)
      if field == 'username' then text = (text:gsub('^@', '')) end
      children(tree, kind, path)[index][field] = text
    end, false, true)
  end

  if name ~= nil then return apply(name) end
  local prompt = field == 'username' and 'Username: ' or 'Display name: '
  vim.ui.input({prompt=prompt, default=node.username or node.name or node.repository}, apply)
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
  local kind, path = scope(state)
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

  local selected_after

  if #destination == #path + 1 then
    local visible = true

    for index, value in ipairs(path) do
      if destination[index] ~= value then visible = false; break end
    end

    if visible then
      selected_after = destination[#destination]

      if vim.deep_equal(moving.path, path) and moving.index < selected_after then
        selected_after = selected_after - 1
      end
    end
  end

  state.tracking_move = nil

  return change(state, function(tree)
    local source = assert(children(tree, kind, moving.path))
    local dest = assert(children(tree, kind, destination))
    local node = assert(table.remove(source, moving.index))
    table.insert(dest, math.min(position or (#dest + 1), #dest + 1), node)
  end, true, false, selected_after)
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

-- The footer confirmation question for removing `target`; nonempty groups
-- explain that their children are promoted rather than deleted.
function M.removal_question(state, target)
  if not target or not target.tracking_index then return nil end

  if target.kind == 'directory_empty' then
    return ('Remove group "%s"?'):format(target.name or '')
  end

  local kind, path = scope(state)
  local tree = state.opts._tracking and state.opts._tracking.tree
  local nodes = tree and children(tree, kind, path)
  local node = nodes and nodes[target.tracking_index] or target.project or target

  if node.children and #node.children > 0 then
    return ('Remove group "%s"? Its children will be promoted'):format(node.name)
  end

  return ('Remove %s"%s"?'):format(node.children and 'group ' or '', label(node))
end

function M.handle(state, action, target)
  if not state.opts.tracking_file or state.view ~= 'contributors' then return false end
  local kind, path = scope(state)

  if action == 'cancel' and state.tracking_move then
    state.tracking_move = nil
    require('oculus.window').refresh_tracking()
    return true
  elseif action == 'move' then
    if target and target.tracking_index and target.kind ~= 'directory_empty' then
      if state.tracking_move then M.move(state, path, target.tracking_index)
      else state.tracking_move = {kind=kind,path=vim.deepcopy(path),index=target.tracking_index} end
    end

    return true
  elseif action == 'destination' then
    if not target or not target.tracking_index or target.kind == 'directory_empty' then return true end
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
      if target.kind == 'directory_empty' then
        local parent_path = target.parent_path or {}
        local index = target.tracking_index
        state.tracking_paths[kind] = vim.deepcopy(parent_path)

        change(state, function(tree)
          local nodes = children(tree, kind, parent_path)
          table.remove(nodes, index)
        end)

        return true
      end

      local index = target.tracking_index

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

  if action == 'left' then
    if state.tracking_move and #path > 0 then
      local parent = vim.deepcopy(path)
      table.remove(parent)
      if not M.move(state, parent) then return true end
    else
      -- Place the cursor back on the group being left.
      state.tracking_selected = path[#path]
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
