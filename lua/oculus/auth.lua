-- Credentials and the signed-in account for each forge. Tokens come from the
-- setup options, then the environment, then (for GitHub) the gh CLI; the
-- account behind a token is looked up once and cached per token.
local M = {}
local gh_token_result
local viewers = {}
local pending = {}

local function nonempty(value)
  return type(value) == "string" and vim.trim(value) ~= "" and vim.trim(value) or nil
end

local function read_gh_token()
  if vim.fn.executable("gh") ~= 1 then
    return nil
  end

  local output = {}

  local ok, job = pcall(vim.fn.jobstart, { "gh", "auth", "token", "--hostname", "github.com" }, {
    stdout_buffered = true,
    on_stdout = function(_, data)
      output = data
    end,
  })

  if not ok or job <= 0 then
    return nil
  end

  -- A locked keyring can make gh wait for input; never block the editor on it.
  local status = vim.fn.jobwait({ job }, 3000)[1]

  if status == -1 then
    pcall(vim.fn.jobstop, job)
  end

  return status == 0 and nonempty(table.concat(output, "\n")) or nil
end

-- The GitHub token and where it came from: "option", "env" or "gh".
function M.github_token(opts)
  opts = opts or {}
  local token = nonempty(opts.token)

  if token then
    return token, "option"
  end

  token = nonempty(vim.env.GITHUB_TOKEN)

  if token then
    return token, "env"
  end

  if opts.gh_token_fallback == false then
    return nil
  end

  if gh_token_result == nil then
    -- Jobs cannot start inside a libuv callback; ask again from the main loop.
    if vim.in_fast_event() then
      return nil
    end

    gh_token_result = read_gh_token() or false
  end

  return gh_token_result or nil, gh_token_result and "gh" or nil
end

function M.codeberg_token(opts)
  opts = opts or {}
  local token = nonempty(opts.codeberg_token)

  if token then
    return token, "option"
  end

  token = nonempty(vim.env.CODEBERG_TOKEN)
  return token, token and "env" or nil
end

function M.token(provider, opts)
  if provider == "codeberg" then
    return M.codeberg_token(opts)
  end

  return M.github_token(opts)
end

function M.sign_in_hint(provider)
  if provider == "codeberg" then
    return "set $CODEBERG_TOKEN or the codeberg_token option"
  end

  return "set $GITHUB_TOKEN or the token option, or run gh auth login"
end

local function viewer_key(provider, token)
  return provider .. ":" .. vim.fn.sha256(token)
end

-- The account signed in on `provider`, as { provider, login, name?, html_url?,
-- avatar_url? }. Successful lookups are cached for the session; failures are
-- not, so a fixed token works on the next call.
function M.viewer(provider, opts, callback)
  provider = provider == "codeberg" and "codeberg" or "github"
  opts = opts or {}
  local token = M.token(provider, opts)

  if not token then
    vim.schedule(function()
      callback(nil, ("Not signed in to %s: %s"):format(
        provider == "codeberg" and "Codeberg" or "GitHub",
        M.sign_in_hint(provider)
      ))
    end)

    return
  end

  local key = viewer_key(provider, token)

  if viewers[key] and not opts.force then
    local viewer = vim.deepcopy(viewers[key])

    vim.schedule(function()
      callback(viewer, nil, true)
    end)

    return
  end

  if pending[key] then
    table.insert(pending[key], callback)
    return
  end

  pending[key] = { callback }
  local client = require(provider == "codeberg" and "oculus.codeberg" or "oculus.github")

  client.viewer(opts, function(viewer, err)
    local waiters = pending[key] or {}
    pending[key] = nil

    if viewer then
      viewers[key] = vim.deepcopy(viewer)
    end

    for _, waiter in ipairs(waiters) do
      waiter(viewer and vim.deepcopy(viewer) or nil, err, false)
    end
  end)
end

-- The cached viewer for `provider`, without a request.
function M.cached_viewer(provider, opts)
  provider = provider == "codeberg" and "codeberg" or "github"
  local token = M.token(provider, opts)
  return token and vim.deepcopy(viewers[viewer_key(provider, token)]) or nil
end

function M.reset()
  gh_token_result = nil
  viewers = {}
  pending = {}
end

return M
