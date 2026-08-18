# Project instructions

- After making Lua edits, run the Neovim `:LuaParagraphFormat` command on the edited
  Lua buffers when available, then review the diff.

- Once you have completed the task the user asked for, commit the intended changes
  with a concise, descriptive commit message and push them to the configured remote.

- After pushing commits for code changes, run the Lazy plugin manager update action
  from the CLI (`nvim --headless "+Lazy! update" +qa`).
