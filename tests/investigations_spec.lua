vim.opt.runtimepath:prepend(vim.fn.getcwd())
-- A realistic editor size puts the list and detail panes side by side.
vim.o.columns, vim.o.lines = 200, 50
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

local function text_of(buf)
  return table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), "\n")
end

-- Rendered text with its wrapping undone, for phrases that span lines.
local function flat(buf)
  return (text_of(buf):gsub("%s+", " "))
end

-- Put the list cursor on the first row whose target matches; the detail pane
-- then shows what that row selects.
local function select(state, predicate)
  for row = 1, vim.api.nvim_buf_line_count(state.buf) do
    local target = state.targets[row]

    if target and predicate(target) then
      vim.api.nvim_set_current_win(state.win)
      vim.api.nvim_win_set_cursor(state.win, { row, 0 })
      state.show_detail()
      return target, row
    end
  end

  error("no list row matches")
end

local function finding(id)
  return function(target) return target.kind == "finding" and target.finding.id == id end
end

local function any_finding(target)
  return target.kind == "finding"
end

local function overview(target)
  return target.kind == "overview"
end

local location = { path = source, line = 2, column = 5, digest = digest, artifact = digest }

local gap = { id = "gap", kind = "missing_match_arm", effect = "unhandled", title = "A capability emerged", status = "inferred",
  explanation = "A variant reaches a rejecting fallback.", consumer_location = location,
  evidence_path = { { relation = "consumes", description = "Consumer match", source = location } }, limitations = { "Syntax only." } }

local view = {
  schema_version = 1, kind = "selected_change", investigation_id = "sha256:investigation", created_unix_nanos = "1",
  intent = "Find opportunities", status = "completed",
  observation = { repository = "/producer", base = "actual-base", head = "actual-head", consumer_repository = directory, consumer_revision = "actual-consumer" },
  reports = { { report_id = "sha256:report", rule_version = "enum-rule/1", opportunities = { gap },
    deltas = { { kind = "added", path = "producer::Kind::New" } } } },
  limitations = { "Committed bytes only." }, experiments = { { opportunity_id = "gap", report_id = "sha256:report", kind = "plexus_wit_fixture", label = "Run supported fixture" } },
  preparations = {}, evidence = {},
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
local listed = text_of(state.buf)
assert(listed:find("actual-base → actual-head", 1, true))
assert(listed:find("1 finding: 1 not yet handled", 1, true))
assert(listed:find("NOT YET HANDLED", 1, true) and listed:find("! A capability emerged", 1, true))
assert(listed:find("API CHANGES · 1 added", 1, true) and listed:find("SCOPE · 1 limitation", 1, true))
-- The view opens on its first finding, with the step that can test it.
local target = state.targets[vim.api.nvim_win_get_cursor(state.win)[1]]
assert(target and target.kind == "finding" and target.experiment)
local detail = flat(state.detail_buf)
assert(detail:find("! NOT YET HANDLED · inferred", 1, true))
local consumer_project = vim.fn.fnamemodify(directory, ":t")
assert(detail:find("1. Consumer match consumes · " .. consumer_project .. "/consumer.rs:2", 1, true), detail)
assert(detail:find("n Run supported fixture", 1, true))
assert(detail:find("EVIDENCE · no runs yet", 1, true))
select(state, overview)
detail = flat(state.detail_buf)
assert(detail:find("uncommitted edits are excluded", 1, true))
assert(detail:find("Plexus found 1 relationship between producer's change and", 1, true))
assert(detail:find("n 1 finding can queue an experiment through Nexus", 1, true))
select(state, function(item) return item.kind == "deltas" end)
assert(flat(state.detail_buf):find("ADDED · 1 producer::Kind::New", 1, true))
select(state, function(item) return item.kind == "scope" end)
assert(flat(state.detail_buf):find("Committed bytes only.", 1, true))
target = select(state, any_finding)
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
  assert(vim.api.nvim_win_get_config(opened.frame_win).relative == "editor", "the catalog is a float")

  for _, item in pairs(opened.targets) do
    if item.kind == "finding" and (not pick or pick(item)) then return opened, item end
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
local other = vim.deepcopy(view)
other.investigation_id, other.intent = "sha256:other", "Another question"
respond(calls[#calls], { schema_version = 1, investigations = { view, other } })
assert(state.mode == "catalog")
listed = text_of(state.buf)
assert(listed:find("producer → " .. consumer_project, 1, true) and listed:find("Find opportunities", 1, true))
-- Findings are derived per investigation. The one already shown is summarized
-- at once; the other loads behind the list.
local preview = calls[#calls]
assert(preview.argv[2] == "investigation" and preview.argv[3] == other.investigation_id)
assert(flat(state.detail_buf):find("FINDINGS · 1 finding ! 1 not yet handled", 1, true))
respond(preview, other)
local _, summaries = text_of(state.buf):gsub("1 finding: 1 not yet handled", "")
assert(summaries == 2, "catalog rows summarize their findings")
state.navigate(view)
assert(calls[#calls].argv[2] == "investigation" and calls[#calls].argv[3] == view.investigation_id)
respond(calls[#calls], view)
state.queue(target)
assert(calls[#calls].argv[2] == "submit-investigation")
assert(calls[#calls].argv[3] == view.investigation_id and calls[#calls].argv[4] == gap.id)
local nexus = require("oculus.nexus").state

local job = { id = "job-1", state = "queued", resource_id = "plexus-native", hypothesis_id = view.investigation_id,
  binding_id = gap.id, plan_id = view.investigation_id, artifact_store = config.store, kind = "discovery_validation" }

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

completed.evidence = { { opportunity_id = "gap", validation_id = "sha256:validation", kind = "plexus_wit_fixture", status = "accepted",
  outcome = "contradicted", diagnostic = "This fixture passed." } }

respond(calls[#calls], completed)
select(state, finding("gap"))
detail = flat(state.detail_buf)
assert(detail:find("accepted · normalizer fixture · sha256:validation", 1, true) and detail:find("This fixture passed.", 1, true))
assert(detail:find("the finding itself stays inferred", 1, true))
assert(text_of(state.buf):find("1 run: 1 contradicted", 1, true))
local compiler = vim.deepcopy(view)
compiler.reports[1].opportunities[1].kind = "candidate_substitution"
compiler.reports[1].opportunities[1].effect = "substitutes"
compiler.reports[1].opportunities[1].validation = { kind = "rust_function_signature" }
compiler.reports[1].opportunities[1].substitution = { previous_path = "provider::legacy", replacement_path = "provider::replacement" }
compiler.experiments[1] = { opportunity_id = "gap", kind = "rust_function_signature", label = "Check replacement signature" }
compiler.preparations = { { opportunity_id = "gap", kind = "rust_call_site_adaptation", label = "Adapt the consumer's calls", blockers = {} } }

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
    { id = "gap/signature", opportunity_id = "gap", kind = "signature", label = "Replacement signature", status = "supported_for_signature",
      outcome = "supported", resolution = "Compiler verification of the callable signature", evidence = { "sha256:compiler" } },
    { id = "gap/behavior", opportunity_id = "gap", kind = "behavior", label = "Behavioral compatibility", status = "unresolved",
      outcome = "unresolved", resolution = "Passing behavioral test cases across consumer call sites", evidence = {} },
    { id = "other/signature", opportunity_id = "other", kind = "signature", label = "Other signature", status = "unresolved",
      outcome = "unresolved", evidence = {} },
  },
}

compiler.evidence = { { opportunity_id = "gap", validation_id = "sha256:compiler", kind = "rust_function_signature", status = "supported_for_signature",
  outcome = "supported", diagnostic = "Both function pointer assignments compiled.",
  scope = "Offline function pointer assertions with default features disabled; no consumer compilation.",
  cases = { { label = "after_replacement", expected = "accepted", actual = "accepted", status = "matched" } } } }

state.refresh()
assert(calls[#calls].options.timeout == 120000, "catalog reads keep their ordinary timeout")
respond(calls[#calls], compiler)
assert(not state.error, state.error)
listed = text_of(state.buf)
assert(listed:find("SUBSTITUTION PATHS · 1", 1, true) and listed:find("✓○", 1, true), "the list shows each obligation's outcome")
select(state, finding("gap"))
detail = flat(state.detail_buf)
assert(detail:find("provider::replacement", 1, true) and detail:find("may substitute for", 1, true))
assert(detail:find("provider::legacy", 1, true))
assert(detail:find("observed A public replacement declaration was added.", 1, true))
assert(detail:find("inferred by rule signature/1", 1, true))
assert(detail:find("supported Replacement signature supported for signature · 1 run", 1, true))
assert(detail:find("open Behavioral compatibility needs passing behavioral test cases across consumer call sites", 1, true))
assert(detail:find("h promote s select d defer x dismiss", 1, true))
assert(detail:find("the finding itself stays inferred", 1, true))
assert(detail:find("Scope: Offline function pointer assertions with default features disabled; no consumer compilation.", 1, true))
assert(detail:find("Case: after_replacement · matched", 1, true))
assert(detail:find("expected accepted · actual accepted", 1, true))
assert(detail:find("n Check replacement signature", 1, true) and detail:find("p Adapt the consumer's calls", 1, true))
assert(not detail:find("Unrelated finding", 1, true) and not detail:find("Other signature", 1, true))
local support_target

for _, item in pairs(state.detail_targets) do
  if item.kind == "source" and item.source.artifact == digest and item.source.line == 2 then support_target = item end
end

assert(support_target and support_target.finding.experiment.kind == "rust_function_signature")
local footer = text_of(state.footer_buf)
assert(footer:find("n queue", 1, true) and footer:find("p prepare", 1, true) and footer:find("q close", 1, true))
local conflicting = vim.deepcopy(compiler)
conflicting.reasoning.obligations[1].status = "conflicting_evidence"
conflicting.reasoning.obligations[1].outcome = "conflicting"
conflicting.reasoning.obligations[1].evidence = { "sha256:rejected-compiler", "sha256:compiler" }

table.insert(conflicting.evidence, 1, { opportunity_id = "gap", validation_id = "sha256:rejected-compiler", kind = "rust_function_signature",
  status = "contradicted_by_signature", outcome = "contradicted", diagnostic = "The replacement declaration did not compile in this attempt.",
  scope = "Archived compiler inputs for the rejected attempt.",
  cases = { { label = "after_replacement", expected = "accepted", actual = "rejected", status = "mismatched" } } })

table.insert(conflicting.evidence, { opportunity_id = "other", validation_id = "sha256:unrelated", status = "inconclusive", diagnostic = "Evidence for a different finding." })
state.refresh()
respond(calls[#calls], conflicting)
assert(not state.error, state.error)
assert(state.targets[vim.api.nvim_win_get_cursor(state.win)[1]].finding.id == "gap", "a reload keeps the finding in view")
detail = flat(state.detail_buf)
assert(detail:find("EVIDENCE · 2 runs", 1, true))
assert(detail:find("supported_for_signature · compiler signature check · sha256:compiler", 1, true))
assert(detail:find("contradicted_by_signature · compiler signature check · sha256:rejected-compiler", 1, true))
assert(detail:find("Case: after_replacement · matched", 1, true) and detail:find("Case: after_replacement · mismatched", 1, true))
assert(detail:find("expected accepted · actual accepted", 1, true) and detail:find("expected accepted · actual rejected", 1, true))
assert(detail:find("Scope: Archived compiler inputs for the rejected attempt.", 1, true))
assert(detail:find("Scope: Offline function pointer assertions with default features disabled; no consumer compilation.", 1, true))
assert(detail:find("conflicting Replacement signature", 1, true))
assert(detail:find("open Behavioral compatibility", 1, true) and detail:find("inferred by rule", 1, true))
assert(not detail:find("Evidence for a different finding", 1, true))
assert(text_of(state.buf):find("≠○", 1, true), "the list shows the conflict beside the open obligation")
local no_experiment = vim.deepcopy(view)
no_experiment.experiments = {}
state.refresh()
respond(calls[#calls], no_experiment)
target = select(state, any_finding)
assert(not text_of(state.footer_buf):find("n queue", 1, true), "the footer offers only what applies")
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

-- Findings group by what they mean for the consumer, in reading order, and
-- findings about the same requirement point at each other.
local function opportunity(id, effect, title)
  return { id = id, kind = "kind-" .. id, effect = effect, status = "inferred", title = title, explanation = title .. ", by rule.",
    consumer_location = location, evidence_path = {}, limitations = { "Shared limit.", "Only " .. id .. "." } }
end

local function relation(id, to)
  return { id = id .. "/relation", kind = "k", claim_id = id .. "/claim", requirement_id = id .. "/requirement",
    from = { project = "producer", revision = "r", path = id }, to = { project = "consumer", revision = "r", path = to } }
end

local structured = vim.deepcopy(view)
structured.investigation_id = "sha256:structured"
structured.experiments = {}

structured.reports[1].opportunities = { opportunity("broken", "breaks", "decode is no longer declared"),
  opportunity("enabled", "enables", "ready now matches"), opportunity("swap", "substitutes", "ready may replace decode"),
  opportunity("same", "unchanged", "version still matches") }

structured.preparations = {
  { opportunity_id = "swap", kind = "c_zig_composition", label = "Prepare a native composition", blockers = {} },
  { opportunity_id = "enabled", kind = "c_zig_composition", label = "Prepare a native composition", blockers = { "pointer wrappers need a reviewed adapter" } },
}

structured.reasoning = { schema_version = 1, claims = {}, obligations = {},
  relations = { relation("broken", "decode"), relation("enabled", "ready"), relation("swap", "decode"), relation("same", "version") } }

for _, item in ipairs(structured.reports[1].opportunities) do
  table.insert(structured.reasoning.claims, { id = item.id .. "/claim", opportunity_id = item.id, kind = item.kind, status = "inferred",
    rule_version = "rule/1", statement = item.explanation, support = {}, obligations = {} })
end

state = bridge.open(config, nexus_config, structured.investigation_id)
respond(calls[#calls], structured)
assert(not state.error, state.error)
listed = text_of(state.buf)
local order = {}

for _, heading in ipairs({ "NEWLY POSSIBLE", "SUBSTITUTION PATHS", "BROKEN BY THIS CHANGE", "UNCHANGED" }) do
  order[#order + 1] = assert(listed:find(heading, 1, true), heading)
end

assert(order[1] < order[2] and order[2] < order[3] and order[3] < order[4], "possibilities come before costs and context")
assert(listed:find("4 findings: 1 newly possible · 1 substitution path · 1 broken · 1 unchanged", 1, true))
assert(state.targets[vim.api.nvim_win_get_cursor(state.win)[1]].finding.id == "enabled", "the view opens on its first group")
-- A limit every finding shares describes the analysis, so it is listed once.
select(state, function(item) return item.kind == "scope" end)
assert(flat(state.detail_buf):find("Shared limit.", 1, true))
select(state, finding("broken"))
detail = flat(state.detail_buf)
assert(detail:find("LIMITS • Only broken.", 1, true) and not detail:find("Shared limit.", 1, true))
assert(detail:find("no matching declaration", 1, true), "a relation without a capability says the provider declares nothing")
assert(detail:find("RELATED · same requirement ⇄ ready may replace decode", 1, true))
assert(detail:find("no executable step for this finding yet", 1, true))

for row, item in pairs(state.detail_targets) do
  if item.kind == "related" then
    vim.api.nvim_set_current_win(state.detail_win)
    vim.api.nvim_win_set_cursor(state.detail_win, { row, 0 })
    break
  end
end

state.navigate()
assert(vim.api.nvim_get_current_win() == state.win, "a related finding opens in the list")
assert(state.targets[vim.api.nvim_win_get_cursor(state.win)[1]].finding.id == "swap")
state.jump(1)
assert(state.targets[vim.api.nvim_win_get_cursor(state.win)[1]].finding.id == "broken", "]] moves to the next finding")
state.jump(-1)
state.jump(-1)
assert(state.targets[vim.api.nvim_win_get_cursor(state.win)[1]].finding.id == "enabled", "[[ moves back")
-- A blocked preparation is shown with its reason and never offered.
detail = flat(state.detail_buf)
assert(detail:find("unavailable: pointer wrappers need a reviewed adapter", 1, true))
assert(not text_of(state.footer_buf):find("p prepare", 1, true))
local asked = false
local old_prompt_input = vim.ui.input
vim.ui.input = function() asked = true end
state.compose()
assert(not asked and state.message:find("pointer wrappers need a reviewed adapter", 1, true))
select(state, finding("swap"))
assert(text_of(state.footer_buf):find("p prepare", 1, true))
state.compose()
assert(asked, "an available preparation asks for its inputs")
vim.ui.input = old_prompt_input
-- J shows the raw records behind the finding, and returns.
state.toggle_raw()
detail = text_of(state.detail_buf)
assert(detail:find("RAW RECORDS", 1, true) and detail:find('"id": "swap"', 1, true), detail)
state.toggle_raw()
assert(not text_of(state.detail_buf):find("RAW RECORDS", 1, true))
-- Tab moves between the panes.
vim.fn.maparg("<Tab>", "n", false, true).callback()
assert(vim.api.nvim_get_current_win() == state.detail_win)
vim.fn.maparg("<Tab>", "n", false, true).callback()
assert(vim.api.nvim_get_current_win() == state.win)
local side = vim.api.nvim_win_get_config(state.detail_win)
assert(side.row == vim.api.nvim_win_get_config(state.win).row, "a wide editor shows the panes side by side")
-- A narrow editor stacks the detail under the list, and the footer keeps q.
vim.o.columns = 90
vim.api.nvim_exec_autocmds("VimResized", {})
local stacked = vim.api.nvim_win_get_config(state.detail_win)
assert(stacked.row > vim.api.nvim_win_get_config(state.win).row, "a narrow editor stacks the panes")
assert(text_of(state.footer_buf):find("q close", 1, true))
vim.o.columns = 200
vim.api.nvim_exec_autocmds("VimResized", {})
state.close()
-- An unsupported capture shows its reasons instead of findings, and the catalog
-- does not try to derive findings it does not have.
local unsupported = vim.deepcopy(view)
unsupported.investigation_id, unsupported.status, unsupported.reports = "sha256:unsupported", "unsupported", {}
unsupported.limitations = { "Committed bytes only.", "Capture failed: no lockfile." }
unsupported.experiments = {}
state = bridge.open(config, nexus_config, unsupported.investigation_id)
respond(calls[#calls], unsupported)
listed = flat(state.buf)
assert(listed:find("ANALYSIS UNAVAILABLE", 1, true) and listed:find("Capture failed: no lockfile.", 1, true))
state.catalog()
count = #calls
respond(calls[#calls], { schema_version = 1, investigations = { unsupported } })
assert(#calls == count, "unsupported captures have no findings to load")
assert(flat(state.detail_buf):find("WHY IT STOPPED • Committed bytes only. • Capture failed: no lockfile.", 1, true))
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
prompts = {}
local prompt_options = {}

vim.ui.input = function(options, callback)
  prompts[#prompts + 1], prompt_options[#prompt_options + 1] = options.prompt, options
  callback(table.remove(answers, 1))
end

-- An empty answer is a real one: a self-contained header needs no directories,
-- and the field is omitted rather than sent as an empty JSON object.
answers = { "/native-producer", "v3", "v2", "include/math.hpp", "c", "  ", directory, "zig-tag", "src/adapter.zig", "Find it" }
bridge.prompt({ plexus = config, nexus = nexus_config, projects = {} }, { analysis = "c_zig" })
assert(#answers == 0)
assert(vim.json.decode(calls[#calls].argv[3]).producer_include_dirs == nil)
bridge.state.close()
answers = { "/native-producer", "v3", "v2", "include/math.hpp", "c++", "include, vendor/include", directory, "zig-tag", "src/adapter.zig", "Find the missing C ABI wrapper" }
prompts = {}
bridge.prompt({ plexus = config, nexus = nexus_config, projects = {} }, { analysis = "c_zig" })
assert(#answers == 0 and #prompts == 10)
assert(prompt_options[#prompt_options - 5].default == "c", "C is the default header language")
request = vim.json.decode(calls[#calls].argv[3])

assert(vim.deep_equal(request, {
  schema_version = 1, analysis = "c_zig", repository = "/native-producer", base = "v2", head = "v3",
  producer_header = "include/math.hpp", header_language = "c++", consumer_repository = directory,
  producer_include_dirs = { "include", "vendor/include" },
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
  id = "wrapper", kind = "requires_c_abi_wrapper", effect = "needs_adapter", title = "A C ABI wrapper could connect C++ to Zig", status = "inferred",
  explanation = "The C++ declaration matches the Zig requirement's shape but needs C linkage.",
  consumer_location = zig_location, evidence_path = { { relation = "requires", description = "Explicit Zig extern requirement", source = zig_location } },
  validation = vim.NIL, limitations = { "Declarations do not demonstrate implementation or runtime behavior." },
} }

c_zig_view.preparations = { { opportunity_id = "wrapper", kind = "c_zig_composition",
  label = "Prepare a native composition from selected implementation sources and behavioral cases", blockers = {} } }

c_zig_view.reasoning = {
  schema_version = 1, relations = {},
  claims = { { id = "wrapper-claim", opportunity_id = "wrapper", status = "inferred", rule_version = "c-zig/1",
    statement = "A wrapper is required before direct C ABI composition.", obligations = { "wrapper/implementation" },
    support = { { kind = "consumer_source", artifact = zig_digest, source = zig_location } } } },
  obligations = { { id = "wrapper/implementation", opportunity_id = "wrapper", label = "Wrapper implementation", status = "unresolved",
    outcome = "unresolved", resolution = "A reviewed C ABI wrapper built against the implementation", evidence = {} } },
}

respond(calls[#calls], c_zig_view)
state = bridge.state
assert(not state.error, state.error)
listed = text_of(state.buf)
assert(listed:find("C/C++ ABI → Zig", 1, true) and listed:find("ONE ADAPTER AWAY", 1, true))
assert(listed:find("◇ A C ABI wrapper could connect C++ to Zig", 1, true))
select(state, overview)
detail = flat(state.detail_buf)
assert(detail:find("Header include/math.hpp · c++", 1, true) and detail:find("Includes include, vendor/include", 1, true))
assert(detail:find("Zig source src/adapter.zig", 1, true))
target = select(state, any_finding)
detail = flat(state.detail_buf)
assert(detail:find("open Wrapper implementation needs a reviewed C ABI wrapper built against the implementation", 1, true))
assert(detail:find("p Prepare a native composition from selected implementation sources and behavioral cases", 1, true))
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
assert(text_of(state.buf):find("C/C++ → Zig", 1, true))
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
  outcome = "supported", scope = "Selected native cases", link_status = "succeeded", cases = {
    { name = "nonzero-is-expected", verdict = "passed", expected_exit = 6, actual_exit = 6, expected_stdout = "", stdout = digest, stderr = digest },
  }, steps = { { phase = "behavior", name = "nonzero-is-expected", success = false, exit_code = 6, stderr = digest } },
  unresolved = { "general_behavioral_equivalence" } } }

state = bridge.open(config, nexus_config, native_view.investigation_id)
respond(calls[#calls], native_view)
select(state, any_finding)
detail = flat(state.detail_buf)
assert(detail:find("supported_for_cases · native composition", 1, true) and detail:find("Native link: succeeded", 1, true))
assert(detail:find("Case: nonzero-is-expected · passed", 1, true))
assert(detail:find("expected exit 6 · actual 6", 1, true))
assert(not detail:find("nonzero-is-expected · failed", 1, true), "Nonzero expected exit is a passing case")
assert(detail:find("Unresolved: general behavioral equivalence", 1, true))
local artifact_target

for _, item in pairs(state.detail_targets) do
  if item.kind == "source" and item.source.path == "stdout" then artifact_target = item end
end

assert(artifact_target and artifact_target.source.artifact == digest, "run output opens as an archived artifact")
state.close()
-- Test O7 Opportunity Steering: promote, select, defer, dismiss, clear
local steering_view = vim.deepcopy(compiler)
state = bridge.open(config, nexus_config, steering_view.investigation_id)
respond(calls[#calls], steering_view)
assert(not state.error, state.error)
local opp_target = select(state, finding("gap"))

-- Verify keybindings are mapped on the buffer
for _, k in ipairs({ "h", "s", "d", "x", "u" }) do
  local map = vim.fn.maparg(k, "n", false, true)
  assert(type(map.callback) == "function", "Missing mapping for " .. k)
end

-- A decision is the developer's own attributed record beside the claim, which
-- stays inferred.
local function steered(label, note)
  listed = text_of(state.buf)
  detail = flat(state.detail_buf)
  assert(listed:find(label, 1, true), "the list marks the finding " .. label)
  assert(detail:find("DECISION " .. label .. " · developer decision by", 1, true), detail)
  assert(detail:find(note, 1, true))
  assert(detail:find("SUBSTITUTION PATH · inferred", 1, true))
  assert(state.view.reports[1].opportunities[1].status == "inferred", "Opportunity claim status must never be edited")
end

-- 1. Promote to hypothesis
state.promote(opp_target, "promising substitution path")
steered("promoted", "promising substitution path")
assert(steering_view.reports[1].opportunities[1].status == "inferred", "Opportunity claim status must never be edited")
-- 2. Select opportunity
state.select_opportunity(opp_target, "focus for upcoming release")
steered("selected", "focus for upcoming release")
assert(not text_of(state.buf):find("promoted", 1, true))
-- 3. Defer opportunity
state.defer(opp_target, "awaiting upstream stabilization")
steered("deferred", "awaiting upstream stabilization")
-- 4. Dismiss opportunity
state.dismiss(opp_target, "rejected by architectural design")
steered("dismissed", "rejected by architectural design")
-- 5. Clear decision
state.clear_decision(opp_target)
assert(not text_of(state.buf):find("dismissed", 1, true))
assert(flat(state.detail_buf):find("DECISION None recorded", 1, true))
-- 6. Interactive prompt via key mapping
local mock_prompts, mock_responses = {}, { "interactive note via prompt" }

vim.ui.input = function(opts, cb)
  mock_prompts[#mock_prompts + 1] = opts.prompt
  cb(table.remove(mock_responses, 1))
end

select(state, finding("gap"))
vim.fn.maparg("h", "n", false, true).callback()
assert(#mock_prompts == 1 and mock_prompts[1]:find("Promote to hypothesis", 1, true))
steered("promoted", "interactive note via prompt")
-- 7. Decisions persist across reload
state.close()
state = bridge.open(config, nexus_config, steering_view.investigation_id)
respond(calls[#calls], steering_view)
select(state, finding("gap"))
steered("promoted", "interactive note via prompt")
state.close()
vim.ui.input, vim.ui.select, vim.system, vim.notify = old_input, old_select, original_system, original_notify
vim.fn.delete(directory, "rf")
print("Rust and C/C++ to Zig prompts, grouped findings with their evidence, durable catalog, archived navigation, Nexus submission/evidence, opportunity steering and cancellation passed")
