# pantheon.nvim

<!-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 15 Describe multi-forge activity support -->
Pantheon is a small Neovim browser for viewing public GitHub and Codeberg activity of community members.
<!-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 15 -->

On a GitHub commit or pull-request activity, press `h` to inspect the change.
Pantheon prepares detached worktrees for each commit and its first parent.
Every changed file opens an adjacent old/new tab pair. Pull requests group
those file pairs by commit, in commit order. The tabs appear with animated
loading indicators and are replaced in place when their files are ready.
Cursor positions and scroll views remain linked within each pair, and `-`/`+`
signs mark the old and new lines. The cursor starts at the first changed hunk;
use `<C-Left>` and `<C-Right>` to jump to the previous and next hunks.
Inspection repositories and worktrees are cached under Neovim's cache
directory; set `inspect_root` in `require("pantheon").setup()` to use a
different location.

When an inspection worktree is opened with
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

<img width="1902" height="1027" alt="pantheon" src="https://github.com/user-attachments/assets/c6de957e-f9ba-4c7f-870f-8fc46754b673" />
<img width="1917" height="1061" alt="pan" src="https://github.com/user-attachments/assets/d75e4a85-a02c-410d-ad4f-62fce8f361da" />
