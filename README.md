# pantheon.nvim

<!-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 15 Describe multi-forge activity support -->
Pantheon is a small Neovim browser for viewing public GitHub and Codeberg activity of community members.

In a user's activity feed, press `b` to load the next page of eight past
activity items and move directly to the first item on that page. Press `r`
from a later page to move one page back toward recent activity.
<!-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 15 -->

From the startup user list, press `/` to fuzzy-search contributor names and
handles. Results and the contributor preview update as you type. Use
`<C-i>` to move up or `<C-k>` to move down (`<Up>`/`<Down>` and
`<C-p>`/`<C-n>` also work), `<CR>` to open a match, and `<Esc>` to cancel the
search. Main-list and search-result navigation use a short configurable delay
(`navigation_delay`, 80 ms by default) to keep held keys from skipping items.

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
pair. Both versions retain one standard-width sign column, but only
changed-version tabs show markers: `+` marks added lines and `-` marks deletion
locations. The cursor starts at the
first changed hunk. When that cursor is on line 10 or later, the tab applies
`zt10<C-y>$` to normalize its view; lines 1–9 retain their existing view. Use
`<C-Left>` and `<C-Right>` to jump to the previous and next hunks; the same
line-10-aware view normalization is reapplied after every jump. `<C-s>`
switches between the parent and changed tabs for the current file.
Every Inspect tab includes the same right-hand changed-files sidebar.
The first inspected file starts at the top, and long paths show only their
parent directory and filename. Each unnumbered file row includes its
change-hunk count and expands into a visible tree of unnumbered hunks, labeled
with their parent and changed starting lines. The active row shows the
cursor's current hunk as `(current/total)` without highlighting file or hunk
rows.
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
