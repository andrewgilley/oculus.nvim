# pantheon.nvim

<!-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 15 Describe multi-forge activity support -->
Pantheon is a small Neovim browser for viewing public GitHub and Codeberg activity of community members.
<!-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 15 -->

From the startup user list, press `/` to fuzzy-search contributor names and
handles. Results and the contributor preview update as you type. Use
`<Up>`/`<Down>` (or `<C-p>`/`<C-n>`) to preview another match, `<CR>` to open
it, and `<Esc>` to cancel the search.

On a GitHub or Codeberg commit or pull-request activity, press `h` to inspect
the change.
Pantheon reads each commit and its first parent from Git without changing the
local checkout. Every changed file opens an adjacent old/new tab pair. Pull
requests group those file pairs by commit, in commit order. Each tab records
the standard local repository and original relative source path; no separate
Pantheon worktree is created. Its tab-local directory is the inspected file's
immediate parent when that directory exists in the checkout, so opening Oil
starts beside the file instead of at the project root. The tabs
appear with animated loading indicators and are replaced in place when their
files are ready. Cursor positions and scroll views remain linked within each
pair, and `-`/`+` signs mark the old and new lines. The cursor starts at the
first changed hunk; use `<C-Left>` and `<C-Right>` to jump to the previous and
next hunks. Git objects are cached under Neovim's cache directory; set
`inspect_root` in `require("pantheon").setup()` to use a different location.

When an inspection tab is opened with
[oil.nvim](https://github.com/stevearc/oil.nvim), a single foreground-only
symbol marks each relevant entry: `+` added, `~` modified, `-` deleted, `→`
renamed, and `•` a directory containing changes.

Pantheon first checks the repositories associated with the current working
directories and loaded buffers. If a matching clone is available, its local
Git objects seed the inspection cache instead of downloading another copy.
It also searches the immediate repositories under
`~/Desktop/Dev/code/source` by default. When no matching local clone is found,
Pantheon asks whether it should clone the repository into that source
directory. Choosing not to download leaves the source directory and inspection
cache unchanged. Search roots and clones elsewhere can be configured
explicitly:

```lua
require("pantheon").setup({
  inspect_search_paths = {
    "C:/Users/andre/Desktop/Dev/code/source",
  },
  inspect_repositories = {
    ["neovim/neovim"] = "C:/code/neovim",
  },
})
```

Pantheon also provides a provider-neutral foundation for model-assisted
opinions. It does not make network requests or choose a model on its own.
Configure an asynchronous provider and call `consult` with an action-specific
request:

```lua
require("pantheon").setup({
  opinion = {
    provider = function(request, respond)
      -- Pass request to the model integration of your choice.
      -- Call respond(result) or respond(nil, error_message) when it finishes.
      my_model.ask(request, respond)
    end,
  },
})

require("pantheon").consult({
  action = "review",
  prompt = "Give a concise opinion about this change.",
})
```

The request is enriched with current project, buffer, and inspection metadata.
The provider's string (or `{ text = ..., filetype = ... }` result) is shown in
a read-only floating buffer. Returning a function or an object with `cancel`
lets Pantheon cancel pending work when the float is closed. Actions, prompts,
model adapters, commands, and inspection keybindings remain separate so they
can be integrated without changing the display lifecycle.

<img width="1902" height="1027" alt="pantheon" src="https://github.com/user-attachments/assets/c6de957e-f9ba-4c7f-870f-8fc46754b673" />
<img width="1917" height="1061" alt="pan" src="https://github.com/user-attachments/assets/d75e4a85-a02c-410d-ad4f-62fce8f361da" />
