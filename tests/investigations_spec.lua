vim.opt.runtimepath:prepend(vim.fn.getcwd())
local bridge = require("oculus.investigations")
local directory = vim.fn.tempname()
vim.fn.mkdir(directory, "p")
local source = directory .. "/consumer.rs"
local bytes = "fn inspect() {\n    match kind {}\n}\n"
vim.fn.writefile(vim.split(bytes, "\n", { plain = true }), source, "b")
local digest = "sha256:" .. vim.fn.sha256(bytes)
local calls = {}
local original_system, original_notify = vim.system, vim.notify
vim.notify = function() end

vim.system = function(argv, options, callback)
  local call = { argv = argv, options = options, callback = callback }
  calls[#calls + 1] = call
  return { kill = function(_, signal) call.killed = signal end }
end

local function respond(call, value)
  local completed = false
  call.callback({ code = 0, stdout = vim.json.encode(value), stderr = "" })
  vim.schedule(function() completed = true end)
  assert(vim.wait(1000, function() return completed end))
end

local location = { path = source, line = 2, column = 5, digest = digest, artifact = digest }

local finding = { id = "gap", title = "A capability emerged", status = "inferred", explanation = "A variant reaches a rejecting fallback.",
  consumer_location = location, evidence_path = { { relation = "consumes", description = "Consumer match", source = location } },
  limitations = { "Syntax only." } }

local view = {
  schema_version = 1, kind = "selected_change", investigation_id = "sha256:investigation", created_unix_nanos = "1",
  intent = "Find opportunities", status = "completed",
  observation = { repository = "/producer", base = "actual-base", head = "actual-head", consumer_repository = directory, consumer_revision = "actual-consumer" },
  reports = { { report_id = "sha256:report", rule_version = "enum-rule/1", opportunities = { finding },
    deltas = { { kind = "added", path = "producer::Kind::New" } } } },
  limitations = { "Committed bytes only." }, experiments = { { opportunity_id = "gap", report_id = "sha256:report", kind = "plexus_wit_fixture", label = "Run supported fixture" } },
  evidence = {},
}

local config = { command = { "/a path/plexus" }, store = directory .. "/store" }
local nexus_config = { command = { "/a path/nexus" }, state_dir = directory .. "/nexus" }
local submission = { schema_version = 1, repository = "/producer; $(touch nope)", head = "HEAD", base = "HEAD^", consumer_repository = directory, intent = "Find opportunities" }
local state = bridge.open(config, nexus_config, nil, submission)
assert(calls[1].argv[2] == "investigate" and vim.deep_equal(vim.json.decode(calls[1].argv[3]), submission))
assert(calls[1].options.timeout == 300000 and #calls[1].argv == 4)
respond(calls[1], view)
assert(not state.error, state.error)
assert(not state.busy and state.mode == "investigation")
local rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("actual-base → actual-head", 1, true) and rendered:find("n: Run supported fixture", 1, true))
assert(rendered:find("uncommitted edits are excluded", 1, true))
local target
for _, item in pairs(state.targets) do target = item; break end
assert(target and target.experiment)
local count = #calls
state.navigate(target)
assert(#calls == count and vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(state.source_win)) == source)
assert(vim.api.nvim_win_get_cursor(state.source_win)[1] == 2)
assert(state.closed and vim.api.nvim_win_get_config(0).relative == "", "following a location hands over the screen")

-- Following a source location closes the float, so each navigation below opens
-- the stored investigation again rather than reusing a dismissed view.
local function reopen(stored, pick)
  local opened = bridge.open(config, nexus_config, stored.investigation_id)
  respond(calls[#calls], stored)
  assert(not opened.error, opened.error)
  assert(vim.api.nvim_win_get_config(opened.win).relative == "editor", "the catalog is a float")
  for _, item in pairs(opened.targets) do
    if not pick or pick(item) then return opened, item end
  end
  error("reopened investigation has no matching finding")
end

vim.fn.writefile({ "changed source" }, source)
state, target = reopen(view, function(item) return item.experiment end)
state.navigate(target)
assert(calls[#calls].argv[2] == "investigation-source" and calls[#calls].argv[3] == digest)
respond(calls[#calls], { schema_version = 1, content = bytes })
assert(not state.error, state.error)
local archived_buf = vim.api.nvim_win_get_buf(state.source_win)
assert(vim.b[archived_buf].oculus_archived_source == digest and vim.bo[archived_buf].readonly)
assert(not vim.bo[archived_buf].modifiable)
state, target = reopen(view, function(item) return item.experiment end)
state.navigate(target)
respond(calls[#calls], { schema_version = 1, content = "corrupt" })
assert(state.error:find("digest mismatch", 1, true))
state.catalog()
respond(calls[#calls], { schema_version = 1, investigations = { view } })
assert(state.mode == "catalog")
state.navigate(view)
assert(calls[#calls].argv[2] == "investigation" and calls[#calls].argv[3] == view.investigation_id)
respond(calls[#calls], view)
state.queue(target)
assert(calls[#calls].argv[2] == "submit-investigation")
assert(calls[#calls].argv[3] == view.investigation_id and calls[#calls].argv[4] == finding.id)
local nexus = require("oculus.nexus").state

local job = { id = "job-1", state = "queued", resource_id = "plexus-native", hypothesis_id = view.investigation_id,
  binding_id = finding.id, plan_id = view.investigation_id, artifact_store = config.store, kind = "discovery_validation" }

respond(calls[#calls], { schema_version = 1, job = job })
respond(calls[#calls], { schema_version = 1, jobs = { job } })
nexus.refresh("resources")
respond(calls[#calls], { schema_version = 1, resources = { { id = "native", backend = "plexus-native", available = true, policy = { wall_timeout_ms = 30000 } } } })
assert(not nexus.error, nexus.error)
job.state, job.result_investigation_id = "succeeded", view.investigation_id
nexus.open_result(job)
assert(nexus.closed and state.closed)
state = bridge.state
assert(calls[#calls].argv[2] == "investigation")
local completed = vim.deepcopy(view)
completed.evidence = { { opportunity_id = "gap", validation_id = "sha256:validation", status = "accepted", diagnostic = "This fixture passed." } }
respond(calls[#calls], completed)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Evidence: accepted", 1, true) and rendered:find("relationship remains inferred", 1, true))
local compiler = vim.deepcopy(view)
compiler.reports[1].opportunities[1].validation = { kind = "rust_function_signature" }
compiler.reports[1].opportunities[1].substitution = { previous_path = "provider::legacy", replacement_path = "provider::replacement" }
compiler.experiments[1] = { opportunity_id = "gap", kind = "rust_function_signature", label = "Check replacement signature" }

compiler.reasoning = {
  schema_version = 1,
  claims = {
    { id = "claim-observed", opportunity_id = "gap", kind = "public_declaration", status = "observed", rule_version = "signature/1",
      statement = "A public replacement declaration was added.", obligations = {}, support = {} },
    { id = "claim-gap", kind = "candidate_substitution", status = "inferred", rule_version = "signature/1",
      statement = "The replacement has a matching declared signature.", obligations = { "gap/signature", "gap/behavior" },
      support = { { kind = "source", artifact = digest, source = location } } },
    { id = "claim-other", kind = "candidate_substitution", status = "inferred", statement = "Unrelated finding must remain elsewhere.",
      obligations = { "other/signature" }, support = {} },
  },
  relations = {},
  obligations = {
    { id = "gap/signature", opportunity_id = "gap", kind = "signature", label = "Replacement signature", status = "supported_for_signature", evidence = { "sha256:compiler" } },
    { id = "gap/behavior", opportunity_id = "gap", kind = "behavior", label = "Behavioral compatibility", status = "unresolved", evidence = {} },
    { id = "other/signature", opportunity_id = "other", kind = "signature", label = "Other signature", status = "unresolved", evidence = {} },
  },
}

compiler.evidence = { { opportunity_id = "gap", validation_id = "sha256:compiler", status = "supported_for_signature", diagnostic = "Both function pointer assignments compiled.",
  scope = "Offline function pointer assertions with default features disabled; no consumer compilation.",
  cases = { { label = "after_replacement", expected = "accepted", actual = "accepted", status = "matched" } } } }

state.refresh()
assert(calls[#calls].options.timeout == 120000, "catalog reads keep their ordinary timeout")
respond(calls[#calls], compiler)
assert(not state.error, state.error)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Candidate substitution: provider::legacy → provider::replacement", 1, true))
assert(rendered:find("Claim: inferred", 1, true) and rendered:find("Rule: signature/1", 1, true))
assert(rendered:find("Claim: observed · A public replacement declaration was added.", 1, true))
assert(rendered:find("Support: source", 1, true) and rendered:find("sha256:compiler", 1, true))
assert(rendered:find("Replacement signature · supported_for_signature", 1, true))
assert(rendered:find("Resolves with: compiler verification of matching callable signature", 1, true))
assert(rendered:find("Behavioral compatibility · unresolved", 1, true))
assert(rendered:find("Resolves with: passing behavioral test cases across consumer call sites", 1, true))
assert(rendered:find("h: promote to hypothesis · s: select · d: defer · x: dismiss", 1, true))
assert(rendered:find("behavior remains unverified and relationship remains inferred", 1, true))
assert(rendered:find("Scope: Offline function pointer assertions with default features disabled; no consumer compilation.", 1, true))
assert(rendered:find("Case: after_replacement · matched", 1, true))
assert(rendered:find("Expected: accepted · actual: accepted", 1, true))
assert(not rendered:find("Unrelated finding", 1, true) and not rendered:find("Other signature", 1, true))
local support_target

for row, item in pairs(state.targets) do
  if vim.api.nvim_buf_get_lines(state.buf, row - 1, row, false)[1]:find("        " .. source, 1, true) then support_target = item end
end

assert(support_target and support_target.source.artifact == digest and support_target.experiment.kind == "rust_function_signature")
local conflicting = vim.deepcopy(compiler)
conflicting.reasoning.obligations[1].status = "conflicting_evidence"
conflicting.reasoning.obligations[1].evidence = { "sha256:rejected-compiler", "sha256:compiler" }

table.insert(conflicting.evidence, 1, { opportunity_id = "gap", validation_id = "sha256:rejected-compiler", status = "contradicted_by_signature",
  diagnostic = "The replacement declaration did not compile in this attempt.", scope = "Archived compiler inputs for the rejected attempt.",
  cases = { { label = "after_replacement", expected = "accepted", actual = "rejected", status = "mismatched" } } })

table.insert(conflicting.evidence, { opportunity_id = "other", validation_id = "sha256:unrelated", status = "inconclusive", diagnostic = "Evidence for a different finding." })
state.refresh()
respond(calls[#calls], conflicting)
assert(not state.error, state.error)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Evidence attempts: 2", 1, true))
assert(rendered:find("Evidence: supported_for_signature · sha256:compiler", 1, true))
assert(rendered:find("Evidence: contradicted_by_signature · sha256:rejected-compiler", 1, true))
assert(rendered:find("Case: after_replacement · matched", 1, true) and rendered:find("Case: after_replacement · mismatched", 1, true))
assert(rendered:find("Expected: accepted · actual: accepted", 1, true) and rendered:find("Expected: accepted · actual: rejected", 1, true))
assert(rendered:find("Scope: Archived compiler inputs for the rejected attempt.", 1, true))
assert(rendered:find("Scope: Offline function pointer assertions with default features disabled; no consumer compilation.", 1, true))
assert(rendered:find("Replacement signature · conflicting_evidence", 1, true))
assert(rendered:find("Behavioral compatibility · unresolved", 1, true) and rendered:find("Claim: inferred", 1, true))
assert(not rendered:find("Evidence for a different finding", 1, true))
local no_experiment = vim.deepcopy(view)
no_experiment.experiments = {}
state.refresh()
respond(calls[#calls], no_experiment)
for _, item in pairs(state.targets) do target = item; break end
count = #calls
state.queue(target)
assert(#calls == count, "unsupported findings must not become Nexus jobs")
state.refresh()
local pending = calls[#calls]
state.cancel()
assert(pending.killed == 15 and not state.busy)
respond(pending, view)
assert(#state.view.experiments == 0, "late cancelled callback ignored")
state.close()
local old_input, old_select = vim.ui.input, vim.ui.select
local answers = { "/producer", "v2", "v1", "crates/provider/Cargo.toml", directory, "consumer-tag", "crates/consumer/Cargo.toml", "What changed?" }
local prompts = {}

vim.ui.input = function(options, callback)
  prompts[#prompts + 1] = options.prompt
  callback(table.remove(answers, 1))
end

bridge.prompt({ plexus = config, nexus = nexus_config, projects = {} })
assert(#answers == 0 and #prompts == 8)
local request = vim.json.decode(calls[#calls].argv[3])
assert(request.base == "v1" and request.head == "v2" and request.consumer_revision == "consumer-tag")
assert(request.producer_manifest == "crates/provider/Cargo.toml" and request.consumer_manifest == "crates/consumer/Cargo.toml")
respond(calls[#calls], view)
bridge.state.close()
answers = { "/native-producer", "v3", "v2", "include/math.hpp", "c++", directory, "zig-tag", "src/adapter.zig", "Find the missing C ABI wrapper" }
prompts = {}
local prompt_options = {}

vim.ui.input = function(options, callback)
  prompts[#prompts + 1], prompt_options[#prompt_options + 1] = options.prompt, options
  callback(table.remove(answers, 1))
end

bridge.prompt({ plexus = config, nexus = nexus_config, projects = {} }, { analysis = "c_zig" })
assert(#answers == 0 and #prompts == 9)
assert(prompt_options[5].default == "c", "C is the default standalone header language")
request = vim.json.decode(calls[#calls].argv[3])

assert(vim.deep_equal(request, {
  schema_version = 1, analysis = "c_zig", repository = "/native-producer", base = "v2", head = "v3",
  producer_header = "include/math.hpp", header_language = "c++", consumer_repository = directory,
  consumer_revision = "zig-tag", consumer_source = "src/adapter.zig", intent = "Find the missing C ABI wrapper",
}), "C/C++ to Zig requests must not contain Rust Cargo inputs")

local zig_bytes = "extern fn add(a: c_int, b: c_int) c_int;\n"
local zig_digest = "sha256:" .. vim.fn.sha256(zig_bytes)
local zig_location = { path = directory .. "/src/adapter.zig", line = 1, column = 1, digest = zig_digest, artifact = zig_digest }
local c_zig_view = vim.deepcopy(view)
c_zig_view.observation = request
c_zig_view.intent = request.intent
c_zig_view.experiments = {}
c_zig_view.reports[1].rule_version = "c-zig/1"
c_zig_view.reports[1].deltas = {}

c_zig_view.reports[1].opportunities = { {
  id = "wrapper", kind = "missing_c_abi_wrapper", title = "A C ABI wrapper could connect C++ to Zig", status = "inferred",
  explanation = "The C++ declaration matches the Zig requirement's shape but needs C linkage.",
  consumer_location = zig_location, evidence_path = { { relation = "requires", description = "Explicit Zig extern requirement", source = zig_location } },
  validation = vim.NIL, limitations = { "Declarations do not demonstrate implementation or runtime behavior." },
} }

c_zig_view.reasoning = {
  schema_version = 1, relations = {},
  claims = { { id = "wrapper-claim", opportunity_id = "wrapper", status = "inferred", rule_version = "c-zig/1",
    statement = "A wrapper is required before direct C ABI composition.", obligations = { "wrapper/implementation" },
    support = { { kind = "consumer_source", artifact = zig_digest, source = zig_location } } } },
  obligations = { { id = "wrapper/implementation", opportunity_id = "wrapper", label = "Wrapper implementation", status = "unresolved", evidence = {} } },
}

respond(calls[#calls], c_zig_view)
state = bridge.state
assert(not state.error, state.error)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Analysis: C/C++ ABI → Zig", 1, true))
assert(rendered:find("Header: include/math.hpp · language c++", 1, true))
assert(rendered:find("Zig source: src/adapter.zig", 1, true))
assert(rendered:find("A C ABI wrapper could connect C++ to Zig", 1, true))
assert(rendered:find("Wrapper implementation · unresolved", 1, true))
assert(rendered:find("Native preparation requires explicit sources and behavioral cases", 1, true))
for _, item in pairs(state.targets) do target = item; break end
assert(target and not target.experiment)
count = #calls
state.queue(target)
assert(#calls == count, "C/C++ declarations without an experiment must not be queued")
state.navigate(target)
assert(calls[#calls].argv[2] == "investigation-source" and calls[#calls].argv[3] == zig_digest)
respond(calls[#calls], { schema_version = 1, content = zig_bytes })
archived_buf = vim.api.nvim_win_get_buf(state.source_win)
assert(vim.b[archived_buf].oculus_archived_source == zig_digest and vim.bo[archived_buf].readonly)
assert(vim.bo[archived_buf].filetype == "zig")
state = reopen(c_zig_view)
state.catalog()
respond(calls[#calls], { schema_version = 1, investigations = { c_zig_view } })
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("Analysis: C/C++ ABI → Zig", 1, true))
state.close()
answers = { "/producer", "HEAD", "HEAD^", "include/api.h", "python" }
count = #calls
bridge.prompt({ plexus = config, nexus = nexus_config, projects = {} }, { analysis = "c_zig" })
assert(#answers == 0 and #calls == count, "unsupported header languages must stop before submission")
bridge.prompt({ plexus = config, nexus = nexus_config, projects = {} }, { analysis = "unknown" })
assert(#calls == count, "unknown analysis must not silently submit a Rust request")
local oculus = require("oculus")
local old_investigate = oculus.investigate
local command_calls, command_context = 0, nil

oculus.investigate = function(context)
  command_calls, command_context = command_calls + 1, context
end

dofile("plugin/oculus.lua")
local completions = vim.fn.getcompletion("OculusInvestigate ", "cmdline")
assert(vim.tbl_contains(completions, "rust") and vim.tbl_contains(completions, "c-zig"))
vim.cmd("OculusInvestigate c-zig")
assert(command_calls == 1 and command_context.analysis == "c_zig")
vim.cmd("OculusInvestigate")
assert(command_calls == 2 and command_context == nil, "the default command must preserve Rust analysis")
vim.cmd("OculusInvestigate rust")
assert(command_calls == 3 and command_context == nil)
vim.cmd("OculusInvestigate invalid")
assert(command_calls == 3)
oculus.investigate = old_investigate
local old_find = require("oculus.local_activity").find_repository
require("oculus.local_activity").find_repository = function(_, _, callback) callback(directory) end
local prompted_context
local old_prompt = bridge.prompt
bridge.prompt = function(_, context) prompted_context = context end
local sha = string.rep("a", 40)
bridge.from_activity({}, { oculus_local = { forge = "github" }, repo = { name = "owner/project" }, payload = { head = sha } }, "https://github.com/owner/project/commit/" .. sha)
assert(prompted_context.repository == directory and prompted_context.head == sha and prompted_context.base == sha .. "^")
prompted_context = nil
bridge.from_activity({}, { repo = { name = "owner/project" }, payload = { head = sha } })
assert(not prompted_context, "remote activity must not silently claim local provenance")
bridge.prompt = old_prompt
require("oculus.local_activity").find_repository = old_find
local custom_config = vim.tbl_extend("force", config, { capture_timeout_ms = 450000, timeout_ms = 8000 })
state = bridge.open(custom_config, nexus_config, nil, submission)
assert(calls[#calls].options.timeout == 450000, "capture retains its independently configurable timeout")
respond(calls[#calls], compiler)
state.close()
local native_view = vim.deepcopy(c_zig_view)
local native_id = native_view.reports[1].opportunities[1].id

native_view.evidence = { { kind = "c_zig_composition", opportunity_id = native_id, validation_id = "sha256:native", status = "supported_for_cases",
  scope = "Selected native cases", link_status = "succeeded", cases = {
    { name = "nonzero-is-expected", verdict = "passed", expected_exit = 6, actual_exit = 6, expected_stdout = "", stdout = digest, stderr = digest },
  }, steps = { { phase = "behavior", name = "nonzero-is-expected", success = false, exit_code = 6, stderr = digest } },
  unresolved = { "general_behavioral_equivalence" } } }

state = bridge.open(config, nexus_config, native_view.investigation_id)
respond(calls[#calls], native_view)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("nonzero-is-expected · passed", 1, true))
assert(rendered:find("Expected exit: 6 · actual: 6", 1, true))
assert(not rendered:find("nonzero-is-expected · failed", 1, true), "Nonzero expected exit is a passing case")
assert(rendered:find("general_behavioral_equivalence", 1, true))
state.close()

-- Test O7 Opportunity Steering: promote, select, defer, dismiss, clear
local steering_view = vim.deepcopy(compiler)
state = bridge.open(config, nexus_config, steering_view.investigation_id)
respond(calls[#calls], steering_view)
assert(not state.error, state.error)

local opp_target
for _, t in pairs(state.targets) do
  if t.opportunity and t.opportunity.id == "gap" then
    opp_target = t
    break
  end
end
assert(opp_target, "Expected target for opportunity gap")

-- Verify keybindings are mapped on the buffer
for _, k in ipairs({ "h", "s", "d", "x", "u" }) do
  local map = vim.fn.maparg(k, "n", false, true)
  assert(type(map.callback) == "function", "Missing mapping for " .. k)
end

-- 1. Promote to hypothesis
state.promote(opp_target, "promising substitution path")
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("[PROMOTED]", 1, true), "Opportunity title must show [PROMOTED] badge")
assert(rendered:find("Decision: promoted · by", 1, true), "Expected decision line in opportunity")
assert(rendered:find("promising substitution path", 1, true))
assert(rendered:find("Evidence: promoted · developer:", 1, true), "Decision must be recorded as attributed evidence")
assert(rendered:find("Rationale: promising substitution path", 1, true))
-- Claim and opportunity status must remain "inferred"
assert(steering_view.reports[1].opportunities[1].status == "inferred", "Opportunity claim status must never be edited")
assert(rendered:find("relationship remains inferred", 1, true))

-- 2. Select opportunity
state.select_opportunity(opp_target, "focus for upcoming release")
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("[SELECTED]", 1, true))
assert(rendered:find("Decision: selected · by", 1, true))
assert(rendered:find("focus for upcoming release", 1, true))
assert(rendered:find("Evidence: selected · developer:", 1, true))
assert(not rendered:find("[PROMOTED]", 1, true))

-- 3. Defer opportunity
state.defer(opp_target, "awaiting upstream stabilization")
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("[DEFERRED]", 1, true))
assert(rendered:find("Decision: deferred · by", 1, true))
assert(rendered:find("awaiting upstream stabilization", 1, true))
assert(rendered:find("Evidence: deferred · developer:", 1, true))

-- 4. Dismiss opportunity
state.dismiss(opp_target, "rejected by architectural design")
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("[DISMISSED]", 1, true))
assert(rendered:find("Decision: dismissed · by", 1, true))
assert(rendered:find("rejected by architectural design", 1, true))
assert(rendered:find("Evidence: dismissed · developer:", 1, true))

-- 5. Clear decision
state.clear_decision(opp_target)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(not rendered:find("[DISMISSED]", 1, true))
assert(not rendered:find("Decision:", 1, true))
assert(not rendered:find("Evidence: dismissed", 1, true))

-- 6. Interactive prompt via key mapping
local mock_prompts, mock_responses = {}, { "interactive note via prompt" }
vim.ui.input = function(opts, cb)
  mock_prompts[#mock_prompts + 1] = opts.prompt
  cb(table.remove(mock_responses, 1))
end
for row, t in pairs(state.targets) do
  if t.opportunity and t.opportunity.id == "gap" then
    vim.api.nvim_win_set_cursor(state.win, { row, 0 })
    break
  end
end
vim.fn.maparg("h", "n", false, true).callback()
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(#mock_prompts == 1 and mock_prompts[1]:find("Promote to hypothesis", 1, true))
assert(rendered:find("[PROMOTED]", 1, true))
assert(rendered:find("interactive note via prompt", 1, true))

-- 7. Decisions persist across reload
state.close()
state = bridge.open(config, nexus_config, steering_view.investigation_id)
respond(calls[#calls], steering_view)
rendered = table.concat(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false), "\n")
assert(rendered:find("[PROMOTED]", 1, true), "Persisted decision must be restored on reopen")
assert(rendered:find("interactive note via prompt", 1, true))
state.close()

vim.ui.input, vim.ui.select, vim.system, vim.notify = old_input, old_select, original_system, original_notify
vim.fn.delete(directory, "rf")
print("Rust and C/C++ to Zig prompts, durable catalog, archived navigation, Nexus submission/evidence, opportunity steering and cancellation passed")
