-- The saved-item store. It owns the one live list so every state-file write
-- persists the latest saves, even when the caller holds an older config copy.
local M = {}
local items = {}
local loaded = false

-- Forge and source identity distinguish independent project/user collections.
function M.scope_key(source)
  if type(source) ~= "table" then
    return nil
  end

  local identifier = source.kind == "project" and source.repository
    or source.kind == "user" and source.username

  if type(identifier) ~= "string" or identifier == "" then
    return nil
  end

  return vim.json.encode({
    source.kind,
    source.provider == "codeberg" and "codeberg" or "github",
    identifier:lower(),
    source.kind == "project" and (source.path or "") or "",
  })
end

function M.load(list)
  items = {}

  for _, entry in ipairs(type(list) == "table" and list or {}) do
    if type(entry) == "table"
      and type(entry.key) == "string"
      and type(entry.event) == "table"
    then
      items[#items + 1] = vim.deepcopy(entry)
    end
  end

  loaded = true
end

function M.loaded()
  return loaded
end

function M.items(source)
  if source == nil then
    return items
  end

  local scope = M.scope_key(source)
  local result = {}

  for _, entry in ipairs(items) do
    if scope and M.scope_key(entry.source) == scope then
      result[#result + 1] = entry
    end
  end

  return result
end

function M.index(key, source, exact)
  local scope = M.scope_key(source)

  for index, entry in ipairs(items) do
    if entry.key == key
      and ((source == nil and not exact) or M.scope_key(entry.source) == scope)
    then
      return index
    end
  end
end

function M.add(entry)
  local existing = M.index(entry.key, entry.source, true)

  if existing then
    table.remove(items, existing)
  end

  table.insert(items, 1, entry)
  loaded = true
end

function M.remove(key, source, exact)
  local index = M.index(key, source, exact)

  if index then
    table.remove(items, index)
    loaded = true
    return true
  end

  return false
end

return M
