# pantheon.nvim

Pantheon is a small Neovim browser for the recent public GitHub activity of
people whose work is worth following.

<img width="1902" height="1027" alt="pantheon" src="https://github.com/user-attachments/assets/c6de957e-f9ba-4c7f-870f-8fc46754b673" />

## Requirements

- Neovim 0.10+
- `curl`

## Setup

```lua
require("pantheon").setup({
  width = 0.91,
  height = 0.80,
  row = 1,
  results_limit = 20,
  contributor_list_limit = 20,
  push_detail_limit = 10,
  activity_types = nil,
  user_activity_types = {},
  persist_filters = true,
  browser_command = nil,
  contributors = {
    {
      name = "Mitchell Hashimoto",
      username = "mitchellh",
      description = "Creator of Ghostty, HashiCorp, Terraform, and Nomad",
    },
    {
      name = "Luke Wagner",
      username = "lukewagner",
      description = "WebAssembly and JavaScript engine engineer",
    },
    {
      name = "Alex Kladov",
      username = "matklad",
      description = "Rust Analyzer co-creator and TigerBeetle engineer",
    },
    {
      name = "Michael Paulson",
      username = "ThePrimeagen",
      description = "Vim, developer tooling, and performance programming",
    },
    {
      name = "Ryan Fleury",
      username = "ryanfleury",
      description = "Systems programming, debuggers, and data-oriented tools",
    },
    {
      name = "Bill Hall",
      username = "gingerBill",
      description = "Creator of the Odin programming language",
    },
    {
      name = "Jon Gjengset",
      username = "jonhoo",
      description = "Rust educator and distributed systems engineer",
    },
    {
      name = "Jarred Sumner",
      username = "Jarred-Sumner",
      description = "Creator of the Bun JavaScript runtime and toolkit",
    },
    {
      name = "Shadab Ahmed",
      username = "shadcn",
      description = "Creator of shadcn/ui and open-code interface tooling",
    },
    {
      name = "Andrej Karpathy",
      username = "karpathy",
      description = "AI researcher; creator of nanoGPT, llm.c, and micrograd",
    },
    {
      name = "Jake Fitzgerald",
      username = "earthtojake",
      description = "Creator of Text-to-CAD and source-controlled CAD tooling",
    },
    {
      name = "Folke Lemaitre",
      username = "folke",
      description = "Creator of lazy.nvim, LazyVim, and Neovim tooling",
    },
    {
      name = "Tim Culverhouse",
      username = "rockorager",
      description = "Creator of libvaxis and modern Zig terminal tooling",
    },
    {
      name = "Simon Willison",
      username = "simonw",
      description = "Creator of Datasette and practical LLM tooling",
    },
    {
      name = "Steven Arcangeli",
      username = "stevearc",
      description = "Creator of Neovim plugins and developer tooling",
    },
    {
      name = "Charlie Marsh",
      username = "charliermarsh",
      description = "Builder of Ruff, uv, ty, and fast Python tooling",
    },
    {
      name = "Andrew Gallant",
      username = "BurntSushi",
      description = "Creator of ripgrep, Rust regex, and jiff",
    },
    {
      name = "Carl Lerche",
      username = "carllerche",
      description = "Rust asynchronous systems engineer and creator of Tokio",
    },
    {
      name = "Georgi Gerganov",
      username = "ggerganov",
      description = "Creator of llama.cpp, whisper.cpp, and local AI tools",
    },
    {
      name = "David Tolnay",
      username = "dtolnay",
      description = "Maintainer of foundational Rust libraries and macros",
    },
    {
      name = "Justin Keyes",
      username = "justinmk",
      description = "Neovim maintainer and influential tooling creator",
    },
    {
      name = "Roberto Ierusalimschy",
      username = "roberto-ieru",
      description = "Principal designer and maintainer of the Lua language",
    },
    {
      name = "Peter Steinberger",
      username = "steipete",
      description = "Creator of OpenClaw and founder of PSPDFKit",
    },
    {
      name = "Russ Cox",
      username = "rsc",
      description = "Go engineer, writer, and open-source maintainer",
    },
    {
      name = "David Heinemeier Hansson",
      username = "dhh",
      description = "Creator of Ruby on Rails and co-owner of 37signals",
    },
    {
      name = "Alex Crichton",
      username = "alexcrichton",
      description = "WebAssembly, Wasmtime, wasm-bindgen, and Rust engineer",
    },
    {
      name = "Andrew Clark",
      username = "acdlite",
      description = "React core engineer and co-creator of Redux",
    },
    {
      name = "Benno Lossin",
      username = "BennoLossin",
      description = "Rust-for-Linux maintainer and Rust contributor",
    },
    {
      name = "Niko Matsakis",
      username = "nikomatsakis",
      description = "Rust language designer and compiler team leader",
    },
  },
})
```

Run `:PantheonOpen`, `:PantheonClose`, or `:PantheonToggle`.

Inside Pantheon:

- `i`, `k`, `j`, and `l` move up, down, left/back, and right/select.
- `<Left>` goes back and `<Right>` selects or opens the highlighted item.
- `f` opens the activity-type checklist for the selected contributor.
- `F` opens the global activity-type checklist.
- In a checklist, `<Space>`, `l`, or `<CR>` toggles a checkbox; `a` enables all and `n` disables all.
- `<CR>` selects a contributor or opens an activity item.
- `o` opens the selected profile or activity item in your browser.
- `r` bypasses the five-minute cache and refreshes activity.
- `b` returns to the contributor list.
- `q`, `<C-c>`, or `<Esc>` closes the window.

Pantheon uses GitHub's public events API. It works without authentication and
uses `GITHUB_TOKEN` automatically when that environment variable is present.
You may instead pass `token` to `setup`, though environment variables are safer
than storing credentials in your Neovim configuration.

GitHub public events are not real-time and can be delayed. Only public activity
is shown.

GitHub no longer includes commit metadata in push events. Pantheon enriches up
to `push_detail_limit` pushes with cached compare requests so push items show a
commit count and latest commit message. A `GITHUB_TOKEN` is recommended if you
preview many contributors because unauthenticated API limits are lower.

## Activity filters

Use GitHub event type names to choose which activity Pantheon reports. A global
allowlist applies to everyone, and a username-specific allowlist overrides it:

```lua
require("pantheon").setup({
  activity_types = {
    "PushEvent",
    "PullRequestEvent",
    "IssuesEvent",
    "ReleaseEvent",
  },
  user_activity_types = {
    mitchellh = { "PushEvent", "ReleaseEvent" },
    dtolnay = { "PushEvent", "PullRequestEvent" },
  },
})
```

Omit `activity_types` to show every event type. Set either allowlist to `{}` to
show no activity in that scope. Filters affect the initial preview and full
activity window.

Checkbox changes are saved to `stdpath("state")/pantheon.json` and restored on
the next `setup()` call. Set `persist_filters = false` to keep changes for the
current session only, or set `state_file` to use another location.

Common values are `PushEvent`, `PullRequestEvent`, `PullRequestReviewEvent`,
`PullRequestReviewCommentEvent`, `IssuesEvent`, `IssueCommentEvent`,
`CommitCommentEvent`, `CreateEvent`, `DeleteEvent`, `ForkEvent`, `WatchEvent`,
`ReleaseEvent`, `GollumEvent`, `MemberEvent`, and `PublicEvent`.

## Browser

On Windows, Pantheon opens links directly in a new normal Edge window. It does
not use a separate browser profile. On other systems it uses Neovim's standard
system-browser handler. To choose a browser explicitly, provide its executable
and arguments; Pantheon appends the URL:

```lua
require("pantheon").setup({
  browser_command = {
    "C:/Program Files (x86)/Microsoft/Edge/Application/msedge.exe",
    "--new-window",
  },
})
```
