# Pantheon issue scout

Pantheon can run an external AI command and display its recommended GitHub issues as a navigable list. If `codex` is available in Neovim's `PATH`, Pantheon automatically runs `codex --search exec` in ephemeral, read-only mode.

No configuration is required for Codex. To use another program, configure `issue_command` with an argv table. Pantheon sends the issue-scout prompt to the command on standard input. When any argument contains `{prompt}`, Pantheon substitutes the prompt into that argument instead and does not use standard input.

```lua
require("pantheon").setup({
  issue_command = { "your-ai-command", "--json" },
  issue_timeout = 180000,
  issue_results_limit = 12,
})
```

The command must write only the JSON array requested by Pantheon's bundled issue-scout skill to standard output. Diagnostic output should go to standard error.

Press `s` from Pantheon's startup user list or run `:PantheonIssues` to use the default career-signal ranking. Add free-form preferences after the command, for example:

```vim
:PantheonIssues Rust compiler performance, about 10 hours per week
```

Run `:PantheonIssues!` to bypass the in-memory results and execute the command again.

Inside the issue list, `i` and `k` move, `l`, `<Right>`, or `<CR>` opens details, `j` or `<Left>` returns to the list, `o` opens the issue in a browser, `r` reruns the search, and `q` closes the window.

The following optional settings are supported:

```lua
require("pantheon").setup({
  issue_command = { "your-ai-command" },
  issue_prompt = nil,
  issue_timeout = 180000,
  issue_results_limit = 12,
  issue_width = 0.90,
  issue_height = 0.82,
  issue_row = 1,
  issue_title = " Pantheon Issues ",
})
```

`issue_command` may also be a function receiving the fully constructed prompt and returning an argv table. Set it to `false` to disable automatic Codex detection. `issue_prompt` may be a replacement prompt string or a function receiving the command-line preferences and returning a prompt string.
