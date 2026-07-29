# pantheon.nvim


Pantheon is a small Neovim browser for viewing public GitHub and Codeberg activity of community members.

In a user's activity feed, press `p` to load the next page of eight activity 
items and move directly to the first item on that page. Press `r`
from a later page to move one page back toward recent activity.


<img width="1917" height="1061" alt="pan" src="https://github.com/user-attachments/assets/d75e4a85-a02c-410d-ad4f-62fce8f361da" />


From the startup user list, press `s` or `/` to fuzzy-search contributor names and
handles. Results and the contributor preview update as you type. Use
`<C-i>` to move up or `<C-k>` to move down (`<Up>`/`<Down>` and
`<C-p>`/`<C-n>` also work), `<CR>` to open a match, and `<Esc>` to cancel the
search. Main-list and search-result navigation use a short configurable delay
(`navigation_delay`, 80 ms by default) to keep held keys from skipping items.


<img width="1902" height="1027" alt="pantheon" src="https://github.com/user-attachments/assets/c6de957e-f9ba-4c7f-870f-8fc46754b673" />


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

When an inspection tab is opened with
[oil.nvim](https://github.com/stevearc/oil.nvim), a single foreground-only
symbol marks each relevant entry: `+` added, `~` modified, `-` deleted, `→`
renamed, and `•` a directory containing changes.

