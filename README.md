# pantheon.nvim


Pantheon is a small Neovim browser for viewing public GitHub and Codeberg activity of community members.

<img width="1917" height="1061" alt="pan" src="https://github.com/user-attachments/assets/d75e4a85-a02c-410d-ad4f-62fce8f361da" />

In a user's activity feed, press `p` to load the next page of eight past
activity items and move directly to the first item on that page. Press `r`
from a later page to move one page back toward recent activity.

<img width="1902" height="1027" alt="pantheon" src="https://github.com/user-attachments/assets/c6de957e-f9ba-4c7f-870f-8fc46754b673" />

From the startup user list, press `s` to fuzzy-search contributor names and
handles. Results and the contributor preview update as you type. Use
`<C-i>` to move up or `<C-k>` to move down (`<Up>`/`<Down>` and
`<C-p>`/`<C-n>` also work), `<CR>` to open a match, and `<Esc>` to cancel the
search. Main-list and search-result navigation use a short configurable delay
(`navigation_delay`, 80 ms by default) to keep held keys from skipping items.

## Inspect

Inspect turns GitHub and Codeberg commit and pull-request activity into a
local file-by-file review inside the current Neovim instance. Press `h` on a
supported activity item to open parent and changed revisions as tab pairs,
using an existing clone from the configured source directory when available;
linked cursors and scroll views, change signs, an Oil-aware directory view,
and a shared changed-files sidebar make it possible to move through every
file and hunk without altering the working checkout.

On a GitHub or Codeberg commit or pull-request activity, press `h` to inspect
the change.
Pantheon reads each commit and its first parent from Git without changing the
local checkout. Every changed file opens an adjacent parent/change tab pair.
The parent tab uses the parent file as its baseline, while the changed tab
applies only the currently selected hunk to that same baseline. Consequently,
switching versions changes only the block being inspected instead of replacing
the complete file; selecting another hunk rebuilds the focused preview around
that block. Pull requests group those file pairs by commit, in commit order.
Each tab records the standard local repository and original relative source
path; no separate Pantheon worktree is created. Its tab-local directory is the
inspected file's immediate parent when that directory exists in the checkout,
so opening Oil starts beside the file instead of at the project root. The tabs
appear with animated loading indicators and are replaced in place when their
files are ready. Cursor positions and scroll views remain linked within each
pair. Both versions retain one standard-width sign column, but only
changed-version tabs show markers: `+` marks added lines and `-` marks deletion
locations. The cursor starts at the
first changed hunk. When that cursor is on line 10 or later, the tab applies
`zt10<C-y>$` to normalize its view; lines 1–9 retain their existing view.
`<C-s>` switches between the parent and changed tabs for the current file from
either the main pane or the changed-files sidebar; sidebar focus, row, and
viewport are preserved.
Every Inspect tab includes the same right-hand changed-files sidebar.
File rows show `•`, the changed file's parent directory and filename, and the
trailing `P C`. Each file expands into a visible tree of
unnumbered hunks labeled with their changed-side start and end lines, such as
`├─ 25-31`, without semantic file or hunk highlighting. The cursor row uses
the active colorscheme’s native `CursorLine` background. The sidebar is 28
columns wide.
The trailing `P C` always remains visible: parent `P` is red, changed `C` is
green, and the symbol for the visible version is underlined. Inspect opens on the
parent version of the first file. Moving the cursor onto a file row opens that
file on the same side; moving onto a hunk child also jumps the main pane to
that hunk. Focus and the existing sidebar viewport remain in the sidebar in
both cases. Pressing `<CR>` on a hunk moves focus to that location in the main
pane; pressing it on a file moves focus to that file's first hunk. The sidebar
starts visible when Inspect is initialized. `<C-i>`
opens or closes it across all Inspect tabs. Pantheon also maps `<Tab>` to this
toggle because terminals
commonly send `<C-i>` as the Tab control code. Required
revisions are resolved or fetched through the project's own `.git` directory.
Inspect does not create a separate Pantheon repository, object cache, or
worktree, and it does not alter the working checkout.

Inspecting a GitHub review-comment or commit-comment activity item opens the
commented file and side at the referenced line. The full comment body appears
in a non-focusable Markdown float on the right of the main pane, anchored
above that line. Ordinary issue and pull-request conversation comments do not
create annotations because they are not attached to a file location.

When an inspection tab is opened with
[oil.nvim](https://github.com/stevearc/oil.nvim), a single foreground-only
symbol marks each relevant entry: `+` added, `~` modified, `-` deleted, `→`
renamed, and `•` a directory containing changes.

Pantheon first checks the repositories associated with the current working
directories and loaded buffers. If a matching clone is available, its local
Git objects are used directly. It also searches the immediate repositories
under `~/Desktop/Dev/code/source` by default. When no matching local clone is
found, Pantheon asks whether it should clone the repository into that source
directory. If the expected destination already contains a Git repository,
Pantheon uses it directly instead of offering another download. Choosing not
to download leaves the source directory unchanged. Search roots and clones
elsewhere can be configured explicitly:

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
