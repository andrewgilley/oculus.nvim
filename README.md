# oculus.nvim

**See what's happening across the projects and people you follow, and review
their changes without leaving Neovim.**

Oculus is a floating dashboard for GitHub and Codeberg activity. Keep a
tracked list of repositories and users, browse their pushes, merged pull
requests, and issues, then _inspect_ any pull request, issue, or commit. Oculus
checks the change out in your local clone and opens it as real, editable
buffers with change markers, chunk navigation, and an AI-assisted overview.

[![Tests](https://github.com/andrewgilley/oculus.nvim/actions/workflows/tests.yml/badge.svg)](https://github.com/andrewgilley/oculus.nvim/actions/workflows/tests.yml)

- [Features](#features)
- [Requirements](#requirements)
- [Installation](#installation)
- [Quick start](#quick-start)
- [Usage](#usage)
  - [The Oculus window](#the-oculus-window)
  - [Inspecting changes](#inspecting-changes)
  - [Inspect overview](#inspect-overview)
  - [Commands](#commands)
- [Options](#options)
- [Authentication](#authentication)
- [Tracking file](#tracking-file)
- [AI integration](#ai-integration)
- [Telemetry](#telemetry)
- [API](#api)
- [Highlights](#highlights)
- [FAQ](#faq)
- [Contributing](#contributing)

## Features

- **One dashboard for two forges.** Track GitHub and Codeberg repositories and
  users side by side in a single floating window.
- **Nested groups.** Organize projects and users into folders, reorder them, and
  move them between groups with a few keystrokes.
- **Filterable activity feeds.** Per-project feeds of pushes, merged pull
  requests, and assigned issues, and per-user feeds of any public event type.
  Filters persist between sessions.
- **Inspect anything by ID.** Paste a URL, or type `pr 123`, `neovim/neovim#123`,
  or a commit SHA. Oculus finds (or offers to clone) the matching local
  repository and opens the change in a dedicated tab.
- **Real buffers, not diff views.** Changed files open as normal buffers. Switch
  between the old and new version, jump between changed chunks, and browse
  changed files in a sidebar or an [oil.nvim](https://github.com/stevearc/oil.nvim)
  view.
- **AI-assisted overview.** Generate a description of a change, or ask for
  likely patch locations for an issue, then spin up a `git worktree` to start
  the fix.
- **Plain JSON source of truth.** You can keep your tracked lists in a
  hand-editable file that is written back atomically.
- **Optional OpenTelemetry tracing** over OTLP/HTTP.

## Requirements

- Neovim **0.10+** (CI runs against the latest stable release)
- `curl` for the GitHub and Codeberg APIs
- `git` for inspecting changes

Optional:

- [oil.nvim](https://github.com/stevearc/oil.nvim) shows change status on
  directory entries in inspected repositories and opens new worktrees.
- [nvim-treesitter-context](https://github.com/nvim-treesitter/nvim-treesitter-context)
  keeps context lines in sync across inspect windows.
- The [Codex CLI](https://github.com/openai/codex) (`codex`) and/or the
  Antigravity CLI (`agy`) power the [AI features](#ai-integration).

## Installation

Oculus supports all the usual plugin managers.

<details>
  <summary>lazy.nvim</summary>

```lua
{
  "andrewgilley/oculus.nvim",
  cmd = { "OculusOpen", "OculusToggle", "OculusInspect" },
  keys = {
    { "<leader>oo", "<cmd>OculusToggle<cr>", desc = "Oculus" },
  },
  ---@module 'oculus'
  opts = {},
}
```

</details>

<details>
  <summary>vim.pack (Neovim 0.12+)</summary>

```lua
vim.pack.add({ "https://github.com/andrewgilley/oculus.nvim" })
require("oculus").setup()
```

</details>

<details>
  <summary>Packer</summary>

```lua
use({
  "andrewgilley/oculus.nvim",
  config = function()
    require("oculus").setup()
  end,
})
```

</details>

<details>
  <summary>vim-plug</summary>

```vim
Plug 'andrewgilley/oculus.nvim'
```

Then, in your `init.lua`:

```lua
require("oculus").setup()
```

</details>

## Quick start

```lua
require("oculus").setup({
  projects = {
    { repository = "neovim/neovim", provider = "github", name = "Neovim" },
    { repository = "forgejo/forgejo", provider = "codeberg" },
  },
  contributors = {
    { username = "folke", provider = "github" },
  },
  -- Where your local clones live, so :OculusInspect can find them
  inspect_search_paths = { vim.fn.expand("~/src") },
})

vim.keymap.set("n", "<leader>oo", "<cmd>OculusToggle<cr>", { desc = "Oculus" })
```

Run `:OculusToggle` to open the window. The first screen lists your
**Projects**. Press `u` to switch to **Users** and `p` to switch back. Select an
entry to open its activity feed, and press `h` on any item to inspect it.

Fresh installations start with empty lists. You can add entries from inside the
window with `a`, list them in `setup()`, or load them from a
[tracking file](#tracking-file).

> [!TIP]
> Set `GITHUB_TOKEN` in your environment. Unauthenticated GitHub requests are
> heavily rate-limited. See [Authentication](#authentication).

## Usage

### The Oculus window

Oculus uses `ijkl` movement by default: `i` is up, `k` down, `j` left, and
`l` right. That frees `h` for **inspect**. If you prefer Vim's layout, set
`navigation = "hjkl"`, which moves inspect to `i`/`I`. The arrow keys work in
both layouts. Press `?` to show every command in a sidebar.

The keys below use the default `ijkl` layout.

**Projects and Users lists**

| Key                   | Action                                                     |
| --------------------- | ---------------------------------------------------------- |
| `<CR>` / `l` / `<Right>` | Open the selected group or activity feed               |
| `j` / `<Left>`        | Go to the parent group                                     |
| `p` / `u` / `v`       | Show Projects / show Users / switch between them           |
| `a`                   | Add a project or user (handle or GitHub/Codeberg URL)      |
| `f` / `K` / `D`       | Create a group in the current location                     |
| `r`                   | Remove the selected item or group                          |
| `R`                   | Rename (display name, or the username for users)           |
| `m`                   | Start a move. Then `m` on a sibling reorders, `<CR>` on a group moves into it, and `j` moves to the parent |
| `M`                   | Move to any group through a picker                         |
| `o`                   | Open the selected profile or repository in your browser    |
| `F`                   | Edit activity filters                                      |
| `H`                   | Inspect by ID                                              |
| `?` / `s`             | Toggle the command sidebar                                 |
| `<Esc>`               | Cancel a pending move, go back, or close                   |
| `q` / `<C-c>`         | Close                                                      |

**Activity feeds**

| Key             | Action                                                         |
| --------------- | -------------------------------------------------------------- |
| `h`             | Inspect the change or issue under the cursor                   |
| `H`             | Inspect by ID (issue, PR, commit, or `project#id`)             |
| `<Tab>`         | Queue the item for inspection. Queued items open together      |
| `b`             | Open the item in your browser                                  |
| `u`             | Show the project's issues                                      |
| `f`             | Issue filters (in the issues view) or newer activity           |
| `p`             | Load older activity                                            |
| `r`             | Refresh                                                        |
| `F`             | Choose activity types                                          |
| `<Space>` / `a` / `n` / `d` | Toggle one filter / enable all / disable all / reset to defaults |
| `j` / `<Left>`  | Back to the list                                               |

### Inspecting changes

Inspect a change from an activity feed with `h`, from anywhere with `H`, or with
`:OculusInspect`. All of these targets are accepted:

```vim
:OculusInspect https://github.com/neovim/neovim/pull/30000
:OculusInspect https://codeberg.org/forgejo/forgejo/issues/1234
:OculusInspect neovim/neovim#30000
:OculusInspect neovim pr 30000          " a tracked project's name or repository
:OculusInspect pr 30000                 " asks which tracked project if ambiguous
:OculusInspect issue 42
:OculusInspect commit 1a2b3c4d
:OculusInspect 1a2b3c4d                 " bare SHAs are recognized
```

Oculus searches for a local clone whose remote matches the target, in this
order:

1. `inspect_repositories`, either a list of paths or a map of `"owner/repo"` to
   a path
2. The current working directory
3. Each directory in `inspect_search_paths` and its immediate children

If no clone is found, Oculus offers to clone the repository into the first
`inspect_search_paths` entry.

The change opens in a new tab. Every changed file is a normal buffer with
change markers, and you can switch it between the parent and the change:

| Key (option)                               | Default      | Action                              |
| ------------------------------------------ | ------------ | ----------------------------------- |
| `inspect_old_version`                      | `<C-s>`      | Show the file before the change     |
| `inspect_new_version`                      | `<C-d>`      | Show the file after the change      |
| `inspect_next_chunk`                       | `<C-Tab>`    | Jump to the next changed chunk      |
| `inspect_previous_chunk`                   | `<S-Tab>`    | Jump to the previous changed chunk  |
| `inspect_sidebar_toggle`                   | `<leader>oi` | Toggle the changed-files sidebar    |
| `inspect_overview_toggle`                  | `<leader>op` | Toggle the [overview](#inspect-overview) (`<C-t>` also works) |

Changed chunks can be counted inline with virtual text (the default) or listed
in a sidebar. Toggle between these modes in the overview with `v` and `s`.

### Inspect overview

The overview is a floating summary of the item being inspected: the title,
metadata, and a description. Its footer shows these commands:

| Key         | Action                                                            |
| ----------- | ----------------------------------------------------------------- |
| `d`         | Describe the change with a model you pick                         |
| `p`         | _(issues)_ Ask a model for likely patch locations                 |
| `w`         | _(issues)_ Create a `git worktree` for the fix (default branch `fix-issue-<n>`) and open the selected locations |
| `<Space>`   | Toggle a suggested patch location                                 |
| `<CR>`      | Pick the highlighted model, or open patch locations               |
| `b`         | Open in your browser                                              |
| `v` / `s`   | Switch between the inline-counter and sidebar chunk modes         |
| `c` / `q`   | Close the overview and return to the files                        |
| `e`         | Exit the inspection                                               |

Worktrees are created next to the repository as `<repo>-<branch>`.

### Commands

| Command                                  | Description                                            |
| ---------------------------------------- | ------------------------------------------------------ |
| `:OculusOpen`                            | Open the Oculus window                                 |
| `:OculusClose`                           | Close it                                               |
| `:OculusToggle`                          | Toggle it                                              |
| `:OculusInspect [target]`                | Inspect an issue, PR, or commit (prompts if no target) |
| `:OculusRename [name]`                   | Rename the selected group or item                      |
| `:OculusAddDirectory [name]`             | Create a group at the current location                 |
| `:OculusMoveToDirectory [project] [dest]`| Move a project to a group (opens a picker with no arguments) |
| `:OculusReloadTracking`                  | Re-read the [tracking file](#tracking-file)            |

## Options

These are the defaults. You only need to pass the options you want to change.

```lua
require("oculus").setup({
  -- Window size, as a fraction of the editor (<= 1) or an absolute size
  width = 0.90,
  height = 0.80,
  row = 1,
  border = "rounded",
  -- "ijkl", "hjkl", or a table:
  -- { up = "i", down = "k", left = "j", right = "l", inspect = "h", inspect_id = "H" }
  navigation = "ijkl",
  -- Show the command sidebar when the window opens
  sidebar = false,
  sidebar_width = 26,

  -- Tracked lists. Entries: { repository = "owner/repo", provider = "github"|"codeberg", name? }
  projects = {},
  -- Entries: { username = "name", provider = "github"|"codeberg", name? }
  contributors = {},
  -- Use a JSON file as the source of truth for both lists (see "Tracking file")
  tracking_file = nil,

  -- Activity
  per_page = 30,
  results_limit = 8,
  contributor_list_limit = 20,
  push_detail_limit = 10,
  -- Event types shown for users. Empty means all
  user_activity_types = {},
  project_activity_types = { "push", "merged_pull_request", "assigned_issue" },
  project_issue_filters = {},
  -- Seconds to cache API responses
  cache_ttl = 300,
  request_timeout = 15,

  -- Persistence
  state_file = vim.fn.stdpath("state") .. "/oculus.json",
  persist_filters = true,
  persist_contributors = true,
  persist_projects = true,
  persist_inspect_overviews = true,

  -- Authentication (environment variables are used when these are nil)
  token = nil, -- falls back to $GITHUB_TOKEN
  codeberg_token = nil, -- falls back to $CODEBERG_TOKEN

  -- How to open URLs: nil (vim.ui.open; Microsoft Edge on Windows), a list such as
  -- { "firefox", "--new-tab", "{url}" }, or function(url) -> command
  browser_command = nil,

  -- Inspect
  inspect_cache_ttl = 60,
  -- List of paths, or a map of { ["owner/repo"] = "/path/to/clone" }
  inspect_repositories = {},
  -- Directories that contain your clones. The first one is the clone target
  inspect_search_paths = {},
  inspect_sidebar_width = 28 / vim.o.columns,
  inspect_sidebar_toggle = "<leader>oi",
  inspect_overview_toggle = "<leader>op",
  inspect_old_version = "<C-s>",
  inspect_new_version = "<C-d>",
  inspect_next_chunk = "<C-Tab>",
  inspect_previous_chunk = "<S-Tab>",
  -- Keep nvim-treesitter-context in sync across inspect windows
  inspect_treesitter_context = true,
  inspect_treesitter_context_multiwindow = true,
  inspect_treesitter_context_mode = "topline",

  -- See "AI integration"
  opinion = {
    provider = nil,
    width = 0.64,
    height = 0.70,
    border = "rounded",
    title = " Oculus opinion ",
    filetype = "markdown",
  },

  -- See "Telemetry"
  telemetry = {
    enabled = false,
    endpoint = nil,
    headers = {},
    service_name = "oculus.nvim",
    service_version = "0.1.0",
    environment = "dev",
    resource_attributes = {},
    timeout = 5,
    exporter = nil,
    on_error = nil,
  },
})
```

Filters, search history, list edits, and inspect overviews are saved to
`state_file` and restored the next time `setup()` runs. Entries you pass in
`projects` and `contributors` are merged with the saved lists. Entries you
remove in the UI stay removed.

## Authentication

| Forge    | Option           | Environment variable |
| -------- | ---------------- | -------------------- |
| GitHub   | `token`          | `GITHUB_TOKEN`       |
| Codeberg | `codeberg_token` | `CODEBERG_TOKEN`     |

Tokens are optional, but unauthenticated GitHub requests are limited to 60
per hour. A classic or fine-grained token with read access to public
repositories is enough.

## Tracking file

To keep your lists in a JSON file that you can edit by hand, sync between
machines, or generate, point `tracking_file` at it:

```lua
require("oculus").setup({
  tracking_file = vim.fn.expand("~/.config/oculus/tracking.json"),
})
```

```json
{
  "version": 1,
  "projects": [
    {
      "name": "Editors",
      "children": [
        { "repository": "neovim/neovim", "provider": "github", "name": "Neovim" }
      ]
    }
  ],
  "users": [{ "username": "folke", "provider": "github" }]
}
```

Oculus never creates or overwrites this file with defaults, so create it before
enabling the option. Edits made in the UI are validated, then written back
atomically. After editing the file outside Oculus, run `:OculusReloadTracking`.

See **[docs/tracking.md](docs/tracking.md)** for the full format, validation
rules, list-editing keys, and how Oculus handles concurrent edits.

## AI integration

Oculus uses AI in two places. Both are optional.

### Overview descriptions and patch locations

The inspect overview's `d` (describe) and `p` (patch locations) commands run a
local agent CLI in a read-only sandbox:

- **Codex.** If `codex` is on your `PATH`, its models are listed. The default
  model is read from `.codex/config.toml` in the project, or from
  `$CODEX_HOME/config.toml`.
- **Gemini.** If `GEMINI_API_KEY` or `GOOGLE_API_KEY` is set, Gemini models are
  listed too and run through the Antigravity CLI (`agy`).

If neither CLI is installed, these commands report that no agent is available.

### Opinions

`require("oculus").consult()` sends a prompt, along with the current buffer and
any active inspection, to a provider function you supply, then shows the answer
in a floating window. Oculus doesn't include a model client for this, so you
can wire it to any backend:

```lua
require("oculus").setup({
  opinion = {
    ---@param request { prompt: string, model?: string, context: table }
    ---@param respond fun(result: string|{ text?: string, lines?: string[], filetype?: string, model?: string }|nil, err?: string)
    provider = function(request, respond)
      local job = vim.system(
        { "llm", "-m", request.model or "default" },
        { stdin = request.prompt .. "\n\n" .. vim.json.encode(request.context) },
        function(out)
          respond(out.code == 0 and out.stdout or nil, out.stderr)
        end
      )
      -- Optionally return a cancel function (or a table with :cancel())
      return function() job:kill(15) end
    end,
  },
})

vim.keymap.set("n", "<leader>oa", function()
  require("oculus").consult({ prompt = "Is this change safe to merge?" })
end)
```

The provider can also return its result synchronously instead of calling
`respond`.

## Telemetry

Telemetry is off by default. When you enable it, Oculus records spans for
inspections and model calls and exports them as OTLP/HTTP JSON using `curl`:

```lua
telemetry = {
  enabled = true,
  endpoint = "http://localhost:4318/v1/traces",
  headers = { Authorization = "Bearer ..." },
}
```

`endpoint` and `headers` fall back to the standard
`OTEL_EXPORTER_OTLP_TRACES_ENDPOINT`, `OTEL_EXPORTER_OTLP_ENDPOINT`, and
`OTEL_EXPORTER_OTLP_HEADERS` variables. To handle payloads yourself, set
`exporter = function(payload, span) ... end`. Export errors are silent unless
you set `on_error`.

## API

```lua
local oculus = require("oculus")

oculus.setup(opts)
oculus.open()
oculus.close()
oculus.toggle()

-- Target syntax matches :OculusInspect
oculus.inspect("neovim/neovim#30000")

-- Tracking file
local ok, err = oculus.reload_tracking()

-- Groups
oculus.create_project_directory("Plugins")
oculus.remove_project_directory("Plugins")
oculus.move_project_to_directory("neovim/neovim", "Plugins")
oculus.open_project_directory("Plugins")

-- Opinions (see "AI integration")
oculus.consult({ prompt = "...", model = "...", context = {} })
oculus.show_opinion("Some **markdown**", { title = " Notes " })
```

## Highlights

| Group                       | Default                    | Used for                      |
| --------------------------- | -------------------------- | ----------------------------- |
| `OculusNormal`              | derived from your window   | Window background             |
| `OculusBorder`              | derived from your window   | Window border                 |
| `OculusDirectory`           | links to `Directory`       | Groups in the lists           |
| `OculusActivityIcon`        | `#fbd38d`                  | Event icons                   |
| `OculusActivityPreview`     | `#9ae6b4`                  | Activity previews             |
| `OculusContributorSelected` | `#ffffff`                  | The selected list entry       |
| `OculusMoveTarget`          | `#ff9e3b`                  | The item being moved          |

## FAQ

**Why doesn't `h` move left?**

Oculus defaults to `ijkl` movement so that `h` can inspect. Set
`navigation = "hjkl"` to use Vim's movement keys. Inspect then moves to `i` and
`I`.

**`:OculusInspect` says it can't find a repository.**

Oculus only uses clones whose remote points at the target repository, or clones
that already contain the target commits. Add the directory that holds your
clones to `inspect_search_paths`, or map the repository to its path in
`inspect_repositories`.

**I'm getting `API rate limit exceeded`.**

Set `GITHUB_TOKEN`. See [Authentication](#authentication).

**Where is my state stored?**

In `stdpath("state")/oculus.json`, or in `state_file` if you set it. If you use
a tracking file, it must be a different file from `state_file`.

## Contributing

Bug reports and pull requests are welcome. The test suites are plain Lua
scripts that run in headless Neovim with no test framework:

```sh
nvim --headless -u NONE -l tests/opinion_spec.lua
nvim --headless -u NONE -l tests/telemetry_spec.lua
nvim --headless -u NONE -l tests/tracking_spec.lua
nvim --headless -u NONE --cmd 'set showtabline=0' -l tests/tracking_ui_spec.lua
nvim --headless -u NONE -l tests/window_spec.lua
```

The inspect suite needs a checkout of oil.nvim and some environment variables.
See [`.github/workflows/tests.yml`](.github/workflows/tests.yml) for the exact
setup.
