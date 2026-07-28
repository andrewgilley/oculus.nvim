# pantheon.nvim

<!-- AGENT_CHANGE_BEGIN codeberg-andrew-kelley-20260727 15 Describe multi-forge activity support -->
Pantheon is a small Neovim browser for viewing public GitHub and Codeberg activity of community members.
<!-- AGENT_CHANGE_END codeberg-andrew-kelley-20260727 15 -->

On a GitHub commit activity, press `h` to inspect the change. Pantheon
prepares detached worktrees for the commit and its first parent, then opens
both in new tabs in the current Neovim instance. The first changed file is
opened in each tab when one is available. Inspection repositories and
worktrees are cached under Neovim's cache directory; set `inspect_root` in
`require("pantheon").setup()` to use a different location.

Pantheon first checks the repositories associated with the current working
directories and loaded buffers. If a matching clone is available, its local
Git objects seed the inspection cache instead of downloading another copy.
It also searches the immediate repositories under
`~/Desktop/Dev/code/source` by default. Search roots and clones elsewhere can
be configured explicitly:

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
