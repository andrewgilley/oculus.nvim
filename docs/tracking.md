# Oculus tracking files

Use an external JSON file as the source of truth for the **Projects** and
**Users** lists. This is opt-in; without `tracking_file`, Oculus keeps its existing
configured/saved-list behavior. Fresh installations have no bundled projects or
users. Add entries manually in Oculus, supply them through setup options, or load
this JSON file. Previously saved entries and existing tracking files are preserved.

For an empty tracking file, start with:

```json
{"version": 1, "projects": [], "users": []}
```

```lua
require("oculus").setup({
  tracking_file = vim.fn.expand("~/.config/oculus/tracking.json"),
  -- Keep state_file separate: it stores filters, history, and legacy lists.
})
```

Create the file yourself before enabling the option. Oculus never initializes a
missing configured file or silently replaces a broken file with defaults.
Relative paths are resolved on load; absolute paths are recommended. A writable
regular file and writable parent directory are required for edits.

## Format

```json
{
  "version": 1,
  "projects": [
    {
      "name": "Editors",
      "children": [
        {"repository": "neovim/neovim", "provider": "github", "name": "Neovim"},
        {
          "name": "Plugins",
          "children": [
            {"repository": "folke/lazy.nvim", "provider": "github"}
          ]
        }
      ]
    }
  ],
  "users": [
    {
      "name": "Maintainers",
      "children": [
        {"username": "folke", "provider": "github"}
      ]
    }
  ]
}
```

- Both root lists and every `children` value must be JSON arrays (`[]`, not `{}`).
- Projects require `repository` (`owner/repo`) and `provider`.
- Users require `username` and `provider`.
- Providers are `github` or `codeberg`; optional `name` is a nonempty display name.
- Groups have `name` and `children`, not a provider or leaf identity. Empty groups
  are supported. Nesting is limited to 64 levels.
- Array order is the displayed sibling order, including mixed groups and leaves.
- A provider/identity pair may occur only once in its entire list, compared
  case-insensitively. Sibling group names must be distinct ignoring case. Names
  may repeat in different parents or in the other list.
- Invalid types, ambiguous duplicates, unsafe `.`/`..` identity components, and
  cycles in programmatic edits are rejected. Unknown JSON leaf metadata survives
  reloads, movement, and writeback. It is not automatically fetched into the file.
- Group names are UI labels, **not filesystem search paths**. Neither this option
  nor the old `project_directories` changes `inspect_search_paths`.

The file overrides membership, hierarchy, and ordering from defaults, setup
`projects`/`contributors`, and saved legacy lists. Empty file lists remain empty.
Legacy state membership is left intact so disabling the option does not destroy
it. Filters and search history continue to use `state_file`.

## UI

Bindings below apply in tracking list views, including nested groups. Existing
project/user activity views, leaf previews, provider picker, and input forms are
retained. The add dialog still accepts handles and supported GitHub/Codeberg URLs;
the JSON file itself requires the canonical identifiers above.

| Key | Action |
| --- | --- |
| `p` / `u` / `v` | Projects / Users / switch lists; each remembers its group path |
| Enter or right-navigation key / Right arrow | Open group or leaf activity |
| Left-navigation key / Left arrow | Go to parent group |
| `a` | Add a project/user to the current group through the provider/input dialog |
| `f`, `K`, `D` | Add a group to the current Projects **or** Users group |
| `r` | Remove leaf or empty group; nonempty groups require confirmation before **promoting their children in place**, preserving order and nested groups |
| `m`, navigate to a sibling, `m` | Move selected item/group to that sibling position |
| `m`, select a group, Enter/right | Move selected item/group into that group (append) |
| `m`, left | Move selected item/group to its parent group (append), then navigate there |
| `M` | Choose any destination group in the same list, including `/` (root) |
| Escape | Cancel a pending move; otherwise retain normal close behavior |

Moves cannot cross lists or put a group inside itself/its descendants. Invalid
moves and group promotion that would create duplicate sibling names are refused
without changing the tree or file. `r` is removal; `d` remains the existing filter
reset binding. Nonempty-group confirmation explains promotion and defaults to
**Cancel** (the first choice); cancelling or dismissing it leaves the file, tree,
browsing path, cursor, and pending move unchanged. Descendants are never deleted.
Switching lists or successfully adding/removing an item or group cancels a pending
move, so shifted numeric positions cannot silently select a different source.
Rejected edits do not cancel it. Adds/removals retain the current group and child
slot (the preceding sibling if the last child was removed).

`:OculusAddDirectory Name` adds a group at the currently browsed location.
`:OculusMoveToDirectory` opens the destination picker; a single destination
argument moves the selected item. Two arguments select a project by repository
(or `provider:owner/repo`) and destination, e.g.:

```vim
:OculusMoveToDirectory neovim/neovim /Editors/Plugins/
```

A destination can be an exact sibling group name, a full `/Group/Subgroup/` label,
or `/`. For names with spaces/slashes or ambiguous textual labels, use `M`.

## Reloads, errors, and concurrent editing

After editing JSON externally run `:OculusReloadTracking`, or:

```lua
local ok, err = require("oculus").reload_tracking()
```

A successful reload resets browsing paths and updates the open Oculus window.
Malformed/missing files leave the last successfully loaded membership intact;
on initial failure the retained legacy membership is shown read-only. Failed
loads/saves block further writes until a successful explicit reload. Error
messages explain how to recover. Oculus does not silently reload or merge an
external edit with an in-flight UI edit.

Each UI membership change validates a copy, writes human-readable JSON to a
unique sibling temporary file, flushes it, and atomically renames it over the
original. Permissions are preserved. Failed writes do not publish the edited
copy to the UI. Unrelated filter/history saves never write the tracking file.

Conflict detection is **optimistic**: exact file bytes are checked before editing
and again immediately before replacement. Ordinary external changes (including
deletion) are refused until reload. This is not an interprocess lock or atomic
compare-and-swap: an uncooperative writer in the tiny interval between the final
check and rename can still race. Avoid simultaneous saves from multiple editors
or Oculus instances. Symlink tracking files are readable but writeback is refused;
configure the target regular file directly to edit it through Oculus.

## Tests

From the repository root:

```sh
nvim --headless -u NONE -l tests/tracking_spec.lua
nvim --headless -u NONE --cmd 'set showtabline=0' -l tests/tracking_ui_spec.lua
```

The UI suite executes real buffer mapping callbacks, public commands, and the
provider/input dialog against temporary tracking/state files. `showtabline=0`
avoids a Neovim 0.12.5 headless tabline assertion also affecting the legacy suite.
