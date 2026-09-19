vim.opt.runtimepath:prepend(vim.fn.getcwd())
local root = vim.fn.fnamemodify(vim.fn.getcwd(), ":h")
local manifest = assert(vim.env.PLEXUS_DISCOVERY_MANIFEST, "Set PLEXUS_DISCOVERY_MANIFEST to a prepared Rust discovery manifest")
local binary = vim.env.PLEXUS_BIN or root .. "/plexus/target/debug/plexus"
local store = assert(vim.env.PLEXUS_DISCOVERY_STORE, "Set PLEXUS_DISCOVERY_STORE to the store containing the API snapshots")
local source_win = vim.api.nvim_get_current_win()
local state = require("oculus.capabilities").open({ command = { binary }, store = store }, manifest)
assert(vim.wait(30000, function() return not state.busy end), "Discovery timed out")
assert(not state.error, state.error)
assert(state.report and #state.report.opportunities > 0, "Expected a source-derived opportunity")
local opportunity

for _, candidate in ipairs(state.report.opportunities) do
  if type(candidate.validation) == "table" and candidate.validation.kind == "plexus_wit_fixture" then
    opportunity = candidate
    break
  end
end

assert(opportunity, "Expected an opportunity with a generated validation fixture")
assert(vim.tbl_isempty(state.validations), "Viewing must not execute validation")
state.navigate(opportunity)
assert(not state.error, state.error)
assert(vim.api.nvim_get_current_win() == source_win)
assert(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(source_win)) == opportunity.consumer_location.path)
assert(vim.api.nvim_win_get_cursor(source_win)[1] == opportunity.consumer_location.line)
state.validate(opportunity)
assert(vim.wait(30000, function() return not state.busy end), "Validation timed out")
assert(not state.error, state.error)
local validation = assert(state.validations[opportunity.id])
assert(validation.status == "reproduced_gap", vim.inspect(validation))
assert(opportunity.status == "inferred", "Validation must preserve scoped inference status")
state.close()
assert(vim.api.nvim_win_is_valid(source_win))
print("Real Rust discovery, source navigation, and scoped fixture validation passed")
