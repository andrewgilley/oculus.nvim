-- The saved-item store. It owns the one live list so every state-file write
-- persists the latest saves, even when the caller holds an older config copy.
local M = {}
local items = {}
local loaded = false

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

function M.items()
  return items
end

function M.index(key)
  for index, entry in ipairs(items) do
    if entry.key == key then
      return index
    end
  end
end

function M.add(entry)
  local existing = M.index(entry.key)

  if existing then
    table.remove(items, existing)
  end

  table.insert(items, 1, entry)
  loaded = true
end

function M.remove(key)
  local index = M.index(key)

  if index then
    table.remove(items, index)
    loaded = true
    return true
  end

  return false
end

return M
