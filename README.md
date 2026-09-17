## oculus.nvim

https://github.com/user-attachments/assets/18e4cd77-701a-467d-ae3f-c3a7d82b4f19

**See what's happening across the projects and people you follow, and review
their changes without leaving Neovim.**

Oculus is a dashboard for GitHub and Codeberg activity. Keep a
tracked list of repositories and users, browse their pushes, merged pull
requests, and issues, then inspect any pull request, issue, or commit. 

Oculus checks the change out in your local clone (or fetches just the changed
files when you don't have one) and opens it as real, editable buffers with
change markers, chunk navigation, and an AI-assisted overview.

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

- **One interface for multiple forges.** Track GitHub and Codeberg repositories and
  users side by side in a single floating window.

- **Nested groups.** Organize projects and users into folders, reorder them, and
  move them between groups with a few keystrokes.

- **Your work in one place.** See the pull requests waiting for your review,
  your own open pull requests, and the issues and pull requests assigned to you
  or mentioning you, across every repository, on GitHub and Codeberg.

- **Filterable activity feeds.** Per-project feeds of pushes, merged pull
  requests, and assigned issues, and per-user feeds of any public event type.
  Filters persist between sessions.

- **Inspect anything by ID.** Paste a URL, or type `pr 123`, `neovim/neovim#123`,
  or a commit SHA. Oculus finds the matching local clone, or fetches only the
  changed files into a small cache when there isn't one, and opens the change
  in a dedicated tab.

- **Real buffers, not diff views.** Changed files open as normal buffers. Switch
  between the old and new version, jump between changed chunks, and browse
  changed files in a sidebar or an [oil.nvim](https://github.com/stevearc/oil.nvim)
  view.

- **Pull request review context.** Review threads appear on the lines they
  discuss, can be loaded into the code as full comment threads, and the
  overview shows each reviewer's verdict, check results and merge state.

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
entry to open its activity feed, and press `i` on any item to inspect it.

Fresh installations start with empty lists. You can add entries from inside the
window with `a`, list them in `setup()`, or load them from a
[tracking file](#tracking-file).

> [!TIP]
> Set `GITHUB_TOKEN` in your environment. Unauthenticated GitHub requests are
> rate-limited. See [Authentication](#authentication).

## Usage

### The Oculus window

Oculus uses Vim's `hjkl` movement by default: `k` is up, `j` down, `h` left,
and `l` right, and `i`/`I` inspect. The arrow keys always work too. Press `?`
to show every command in a sidebar.

Bind each navigation command to the key you want with `navigation`. Commands
you leave out keep their default key. For example, to move with `ijkl` and
inspect with `h`/`H`:

```lua
require("oculus").setup({
  navigation = {
    up = "i",
    down = "k",
    left = "j",
    right = "l",
    inspect = "h",
    inspect_id = "H",
  },
})
```

The keys below are the defaults.

**Projects and Users lists**

| Key                   | Action                                                     |
| --------------------- | ---------------------------------------------------------- |
| `<CR>` / `l` / `<Right>` | Open the selected group or activity feed               |
| `h` / `<Left>`        | Go to the parent group                                     |
| `p` / `u` / `v`       | Show Projects / show Users / switch between them           |
| `w`                   | Open [my work](#my-work)                                   |
| `s`                   | Open [saved items](#saved-items)                           |
| `a`                   | Add a project or user (handle or GitHub/Codeberg URL)      |
| `f` / `K` / `D`       | Create a group in the current location                     |
| `r`                   | Remove the selected item or group                          |
| `R`                   | Rename (display name, or the username for users)           |
| `m`                   | Start a move. Then `m` on a sibling reorders, `<CR>` on a group moves into it, and `h` moves to the parent |
| `M`                   | Move to any group through a picker                         |
| `o`                   | Open the selected profile or repository in your browser    |
| `F`                   | Edit activity filters                                      |
| `I`                   | Inspect by ID                                              |
| `?`                   | Toggle the command sidebar                                 |
| `<Esc>`               | Cancel a pending move, go back, or close                   |
| `q` / `<C-c>`         | Close                                                      |

**Activity feeds**

| Key             | Action                                                         |
| --------------- | -------------------------------------------------------------- |
| `i`             | Inspect the change or issue under the cursor                   |
| `I`             | Inspect by ID (issue, PR, commit, or `project#id`)             |
| `<Tab>`         | Queue the item for inspection. Queued items open together      |
| `b`             | Open the item in your browser                                  |
| `u`             | Show the project's issues                                      |
| `f`             | Issue filters (in the issues view) or newer activity           |
| `m`             | Milestones (in the issues view)                                |
| `s`             | Save the item under the cursor, or remove it from saved items  |
| `p`             | Load older activity                                            |
| `r`             | Refresh                                                        |
| `F`             | Choose activity types                                          |
| `<Space>` / `a` / `n` / `d` | Toggle one filter / enable all / disable all / reset to defaults |
| `h` / `<Left>`  | Back to the list                                               |

**Local commits**

GitHub and Codeberg can take a while to report new pushes. When pushes are
shown and a local clone of the project is found (the same search that
inspection uses, but only clones with a remote pointing at the project count),
a project feed also lists recent commits from the clone's `HEAD` and its
remote-tracking branches that are newer than the forge's latest push. These
read `committed to owner/repo · local`, or `· local, not pushed` when no
remote-tracking branch contains the commit. When the forge reports the same
commit, its entry replaces the local one. Inspecting a local commit shows
`Source: Local clone, not yet listed by GitHub` (or `Local clone, not pushed`)
in the overview.

**Saved items**

Press `s` on any activity item (in a project or user feed, the issues view, a
milestone, or an expanded push or pull request) to save it. Saved items are
marked with `★`, and pressing `s` again removes them. Press `s` on the start
screen to open the saved feed: every saved item, newest save first, rendered
like any other feed, so `i` inspects, `b` opens the browser, `Tab` queues, and
`p`/`f` page. `s` there removes the item under the cursor.

Items are stored as snapshots in `state_file`, so they survive restarts and
stay available offline, but they don't refresh (an issue saved while open still
shows as open).

**My work**

Press `w` on the start screen, or run `:OculusWork`, to see what needs you. The
list shows the account you're signed in as on each forge and four categories,
each with a count of open items:

| Category           | GitHub search                         | Codeberg filter             |
| ------------------ | ------------------------------------- | --------------------------- |
| Review requests    | `is:open is:pr review-requested:@me`  | `type=pulls&review_requested` |
| Your pull requests | `is:open is:pr author:@me`            | `type=pulls&created`        |
| Assigned to you    | `is:open assignee:@me`                | `assigned`                  |
| Mentions           | `is:open mentions:@me`                | `mentioned`                 |

The preview lists the most recently updated items. Select a category to open
its items as an activity feed spanning every repository, where `i` inspects,
`b` opens the browser, `Tab` queues and `s` saves as usual. Press `b` on the
list to open the forge's own page for that category, `r` to refresh, and
`h`/`←` to go back. GitHub archived repositories are left out.

My work needs a token (see [Authentication](#authentication)). Codeberg is
listed once you set a Codeberg token or track a Codeberg project or user.

**Milestones**

Press `m` in a project's issues view to list its milestones. The list works
like the Projects and Users lists: open milestones come first (nearest due date
first), then closed ones, and the preview shows the due date, progress, and
description. Select a milestone to see its issues and pull requests as an
activity feed, where `i` inspects and `b` opens items as usual. Press `b` on
the list to open a milestone in your browser, `r` to refresh it, and `h`/`←` to
go back.

### Inspecting changes

Inspect a change from an activity feed with `i`, from anywhere with `I`, or with
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
4. Any clone below `inspect_discovery_roots` (your home directory by default),
   up to four levels deep, skipping hidden directories

A local clone always loads whole files. Only when no clone is found does Oculus
inspect the change remotely instead:

- It keeps a shallow, blob-free Git repository per project under
  `inspect_remote_cache` and fetches only the inspected commits plus the
  contents of the changed files. A typical commit costs a few hundred kilobytes.
- Each changed file is trimmed to its changed lines plus
  `inspect_remote_context` lines of surrounding code (20 by default). Hidden
  stretches are replaced by a single `⋯ 94 unchanged lines ⋯` marker, written
  as a comment in the file's language. The sidebar's chunk list keeps the real
  line numbers, while buffer line numbers count excerpt lines.
- The project's directory structure at the inspected commits is laid out in
  the cache as empty files, so oil.nvim can browse it. Selecting an inspected
  file in oil.nvim shows its inspection; selecting any other file closes oil.nvim.
- The overview shows `Source: Remote, ±20 lines around changes`. For issues,
  `p` (patch locations) and `w` (worktree) are unavailable because there is no
  checkout to search or branch from.
- Fetching uses your Git credentials, so private repositories work when `git
  fetch` does. Resolving an abbreviated commit SHA uses the forge API.

Set `inspect_remote_context = math.huge` to load whole files.

The change opens in a new tab. Every changed file is a normal buffer with
change markers, and you can switch it between the parent and the change:

| Key (option)                               | Default      | Action                              |
| ------------------------------------------ | ------------ | ----------------------------------- |
| `inspect_old_version`                      | `<C-s>`      | Show the file before the change     |
| `inspect_new_version`                      | `<C-d>`      | Show the file after the change      |
| `inspect_next_chunk`                       | `<C-Tab>`    | Jump to the next changed chunk      |
| `inspect_previous_chunk`                   | `<S-Tab>`    | Jump to the previous changed chunk  |
| `inspect_next_thread`                      | `]r`         | Jump to the next [review thread](#review-threads) |
| `inspect_previous_thread`                  | `[r`         | Jump to the previous review thread  |
| `inspect_thread`                           | `<leader>oc` | Open the review thread on this line |
| `inspect_chunk_threads`                    | `<C-r>`      | Show or hide the review threads on the chunk this file is showing (shadows redo in inspected buffers; set to `false` to keep it) |
| `inspect_sidebar_toggle`                   | `<leader>oi` | Toggle the changed-files sidebar    |
| `inspect_overview_toggle`                  | `<leader>op` | Toggle the [overview](#inspect-overview) (`<C-t>` also works) |

Changed chunks can be listed in a sidebar (the default) or counted inline with
virtual text. Toggle between these modes in the overview with `v` and `s`, or
set `inspect_chunk_view_mode = "virtual"` to start in virtual mode.

### Review threads

When you inspect a pull request, Oculus loads its reviews in the background:

- Each commented line gets a label at the end of the line with the author, the
  first line of the comment, and the number of replies. Resolved threads are
  dimmed.
- Resting the cursor on that line shows the whole thread in a float. Press
  `inspect_thread` to move into the float and scroll it. In the float, `b`
  opens the thread in your browser and `q` closes it.
- The sidebar shows how many open threads each file has (`◆2`), or `✓3` when
  all of a file's threads are resolved.
- The overview lists each reviewer's latest verdict, the checks on the head
  commit, whether the pull request can be merged, and how many threads are
  open, resolved and outdated.
- Pressing `r` on the [overview](#inspect-overview) loads the threads into the
  files: every comment is shown under the code line it was written on, with
  replies indented and a line down the number column tying the comments to
  that code line, in place of the end-of-line label and the float. Files
  whose threads sit in other chunks are shown whole while the threads are
  loaded, so each one lands on its own line; `r` again puts the threads away
  and brings back the chunk each file was showing.
- `inspect_chunk_threads` (`<C-r>`) does the same for one chunk without
  leaving the file, and without changing what the file is showing. It starts
  from whatever `r` last set and flips only the chunk you are on, so you can
  read one thread in place while the rest stay as labels, or hide the comments
  on a chunk while the rest of the inspection keeps them.

A pull request inspection shows each commit's changes separately, so a thread
appears on the version of the file it was written against. A comment on the
new code appears on the latest version of the file at or before the comment's
commit, and a comment on the old code appears before the file's first change.
While a single chunk is shown, a thread in a different chunk is labelled at the
start of that chunk, and jumping to it shows that chunk. Threads on commits
that were force-pushed away are counted in the overview but not shown.

On GitHub, whether a thread is resolved or outdated comes from the GraphQL API,
which needs a [token](#authentication). Without one, every thread appears
unresolved.

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
| `r`         | _(pull requests)_ Load the [review threads](#review-threads) into the files, or put them away |
| `b`         | Open in your browser                                              |
| `v` / `s`   | Switch between the inline-counter and sidebar chunk modes         |
| `c` / `q`   | Close the overview and return to the files                        |
| `e`         | Exit the inspection                                               |

Worktrees are created next to the repository as `<repo>-<branch>`.

### Commands

| Command                                  | Description                                            |
| ---------------------------------------- | ------------------------------------------------------ |
| `:OculusOpen [project\|@user]`           | Open the Oculus window, optionally on a project's activity feed (`owner/repo` or `github:owner/repo`) or a user's (`@login` or `@codeberg:login`; `@me` is the signed-in account) |
| `:OculusWork`                            | Open the Oculus window on [my work](#my-work)          |
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
  -- The key for each navigation command
  navigation = {
    up = "k",
    down = "j",
    left = "h",
    right = "l",
    inspect = "i", -- inspect the item under the cursor
    inspect_id = "I", -- inspect by ID
  },
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
  token = nil, -- falls back to $GITHUB_TOKEN, then `gh auth token`
  gh_token_fallback = true, -- set to false to never ask the gh CLI
  codeberg_token = nil, -- falls back to $CODEBERG_TOKEN

  -- How to open URLs: nil (vim.ui.open; Microsoft Edge on Windows), a list such as
  -- { "firefox", "--new-tab", "{url}" }, or function(url) -> command
  browser_command = nil,

  -- Inspect
  inspect_cache_ttl = 60,
  -- List of paths, or a map of { ["owner/repo"] = "/path/to/clone" }
  inspect_repositories = {},
  -- Directories that contain your clones
  inspect_search_paths = {},
  -- Directories scanned for a matching clone before inspecting remotely
  inspect_discovery_roots = { vim.uv.os_homedir() },
  -- Lines of surrounding code kept around each change when no local clone
  -- exists (math.huge keeps whole files)
  inspect_remote_context = 20,
  -- Where shallow, blob-free repositories for remote inspections are kept
  inspect_remote_cache = vim.fn.stdpath("cache") .. "/oculus/remote",
  inspect_sidebar_width = 28 / vim.o.columns,
  inspect_sidebar_toggle = "<leader>oi",
  inspect_overview_toggle = "<leader>op",
  inspect_old_version = "<C-s>",
  inspect_new_version = "<C-d>",
  inspect_next_chunk = "<C-Tab>",
  inspect_previous_chunk = "<S-Tab>",
  inspect_next_thread = "]r",
  inspect_previous_thread = "[r",
  inspect_thread = "<leader>oc",
  inspect_chunk_threads = "<C-r>",
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

Filters, search history, list edits, inspect overviews, and saved items are
stored in `state_file` and restored the next time `setup()` runs. Entries you pass in
`projects` and `contributors` are merged with the saved lists. Entries you
remove in the UI stay removed.

## Authentication

| Forge    | Option           | Environment variable |
| -------- | ---------------- | -------------------- |
| GitHub   | `token`          | `GITHUB_TOKEN`       |
| Codeberg | `codeberg_token` | `CODEBERG_TOKEN`     |

If neither is set for GitHub and the [GitHub CLI](https://cli.github.com) is
installed, Oculus uses the token from `gh auth token`, so signing in with
`gh auth login` is enough. Set `gh_token_fallback = false` to turn this off.

The command sidebar on the start screen (`?`) shows the account behind each
token at the bottom, one line per forge, for example `Codeberg: @octocat`.

Tokens are optional for browsing, but [my work](#my-work) and `@me` need one,
and unauthenticated GitHub requests are limited to 60
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

-- Open straight on a project's activity feed (untracked repositories work too)
local ok, err = oculus.open_project("github:neovim/neovim")

-- Same for a user's activity feed (untracked users work too)
local ok, err = oculus.open_user("github:folke")

-- Open on your review requests, pull requests, assignments and mentions
oculus.open_work()

-- The signed-in account: { provider, login, name?, html_url?, avatar_url? }
oculus.viewer("github", function(viewer, err)
  print(viewer and viewer.login or err)
end)

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

| Group                         | Default                   | Used for                      |
| ----------------------------- | ------------------------- | ----------------------------- |
| `OculusNormal`                | derived from your window  | Window background             |
| `OculusBorder`                | derived from your window  | Window border                 |
| `OculusDirectory`             | links to `Directory`      | Groups in the lists           |
| `OculusAccounts`              | links to `DiagnosticOk`   | Signed-in accounts            |
| `OculusActivityIcon`          | `#fbd38d`                 | Event icons                   |
| `OculusActivityPreview`       | `#9ae6b4`                 | Activity previews             |
| `OculusContributorSelected`   | `#ffffff`                 | The selected list entry       |
| `OculusMoveTarget`            | `#ff9e3b`                 | The item being moved          |
| `OculusInspectThread`         | links to `DiagnosticInfo` | Open review thread labels     |
| `OculusInspectThreadResolved` | links to `Comment`        | Resolved review thread labels |
| `OculusInspectThreadHeader`   | links to `Title`          | Comment authors in threads    |
| `OculusInspectThreadBody`     | links to `Comment`        | Comment text of threads loaded into the files |
| `OculusInspectThreadGutter`   | links to `LineNr`         | The line drawn beside that comment text |

## Contributing

Bug reports and pull requests are welcome.

Two modules hold the two halves of the plugin, each with the parts that stand
on their own beside them:

| Module                  | What it holds                                                      |
| ----------------------- | ------------------------------------------------------------------ |
| `oculus/window.lua`     | The Oculus window: the list, the sidebar, the footer, the keys      |
| `oculus/window/`        | `activity` (the feeds behind the lists), `preview` (the panel beside them), `directories` (project groups), `highlight` (the colours it takes from the code), and the `milestones`, `work` and `saved` views |
| `oculus/inspect.lua`    | An inspection: its tabs, buffers, sidebar and chunk navigation      |
| `oculus/inspect/`       | `prepare` and `git` (getting the change), `patch` (reading a diff), `target` (resolving what to inspect), `overview` (the summary and its agent flows), `review` and `review_ui` (pull request review threads), `oil`, `context` (treesitter-context) and `counters` |

A module beside one of the two takes what it needs from it through `setup()`,
so the names the rest of the file uses, and everything the tests reach for,
stay where they are.

The test suites are plain Lua scripts that run in headless Neovim with no test
framework:

```sh
nvim --headless -u NONE -l tests/opinion_spec.lua
nvim --headless -u NONE -l tests/telemetry_spec.lua
nvim --headless -u NONE -l tests/tracking_spec.lua
nvim --headless -u NONE --cmd 'set showtabline=0' -l tests/tracking_ui_spec.lua
nvim --headless -u NONE --cmd 'set showtabline=0' -l tests/window_spec.lua
nvim --headless -u NONE --cmd 'set showtabline=0' -l tests/remote_spec.lua
nvim --headless -u NONE --cmd 'set showtabline=0' -l tests/milestones_spec.lua
nvim --headless -u NONE --cmd 'set showtabline=0' -l tests/saved_spec.lua
nvim --headless -u NONE --cmd 'set showtabline=0' -l tests/work_spec.lua
nvim --headless -u NONE --cmd 'set showtabline=0' -l tests/review_spec.lua
```

The inspect suite needs a checkout of oil.nvim and some environment variables.
See [`.github/workflows/tests.yml`](.github/workflows/tests.yml) for the exact
setup.

## License

[MIT](LICENSE)
