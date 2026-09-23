-- Lines, highlights and navigation targets for the investigation panes: the
-- findings list grouped by effect, the detail of whatever the list selects,
-- and the catalog. Pure functions of a model and a width; the controller owns
-- windows and keys.
local model = require("oculus.investigations.model")
local M = {}
local text, short, words, plural = model.text, model.short, model.words, model.plural
local MUTED, HEADING, TITLE = "OculusInvestigationMuted", "OculusInvestigationHeading", "OculusInvestigationTitle"
local KEY, LOCATION = "OculusInvestigationKey", "OculusInvestigationLocation"

local function list(value)
  return type(value) == "table" and value or {}
end

local function width_of(value)
  return vim.fn.strdisplaywidth(value)
end

-- The longest prefix of value no wider than width.
local function prefix(value, width)
  local count = vim.fn.strchars(value)
  local keep = math.min(count, width)
  local result = vim.fn.strcharpart(value, 0, keep)

  while keep > 0 and width_of(result) > width do
    keep = keep - 1
    result = vim.fn.strcharpart(value, 0, keep)
  end

  return result
end

local function fit(value, width)
  if width < 1 then return "" end
  if width_of(value) <= width then return value end
  return prefix(value, width - 1) .. "…"
end

local function wrap(value, width)
  width = math.max(12, width)
  local lines, current = {}, ""

  for word in tostring(value):gmatch("%S+") do
    local candidate = current == "" and word or (current .. " " .. word)

    if width_of(candidate) <= width then
      current = candidate
    else
      if current ~= "" then lines[#lines + 1] = current end
      current = word

      while width_of(current) > width do
        local piece = prefix(current, width)
        lines[#lines + 1] = piece
        current = vim.fn.strcharpart(current, vim.fn.strchars(piece))
      end
    end
  end

  if current ~= "" or #lines == 0 then lines[#lines + 1] = current end
  return lines
end

-- Digests and commits inside Plexus's text read short; the raw view keeps them whole.
local function shorten(value)
  value = text(value):gsub("sha256:(%x+)", function(hex) return "sha256:" .. hex:sub(1, 12) .. "…" end)
  return (value:gsub("git:(%x+)", function(hex) return "git:" .. short(hex) end))
end

local function sentence(value)
  value = text(value)
  return value:sub(1, 1):lower() .. value:sub(2)
end

local function page(width)
  local b = { lines = {}, marks = {}, targets = {}, width = width }

  -- One line from { text, highlight } segments.
  function b.add(segments, target)
    local line = ""

    for _, segment in ipairs(segments) do
      local piece = segment[1] or ""

      if segment[2] and piece ~= "" then
        b.marks[#b.marks + 1] = { #b.lines + 1, #line, #line + #piece, segment[2] }
      end

      line = line .. piece
    end

    b.lines[#b.lines + 1] = line
    if target then b.targets[#b.lines] = target end
    return #b.lines
  end

  function b.blank(target)
    b.lines[#b.lines + 1] = ""
    if target then b.targets[#b.lines] = target end
  end

  -- A heading opens a section, set apart from the one before it.
  function b.heading(title, note, target)
    if #b.lines > 0 and b.lines[#b.lines] ~= "" then b.blank() end
    local segments = { { " " .. title, HEADING } }
    if note then segments[#segments + 1] = { " · " .. note, MUTED } end
    return b.add(segments, target)
  end

  -- Text wrapped under a prefix; continuation lines hang at the prefix's width.
  function b.hang(lead, value, highlight, target)
    local indent = 0
    for _, segment in ipairs(lead) do indent = indent + width_of(segment[1]) end
    local lines = wrap(value, b.width - indent - 1)
    local first = vim.deepcopy(lead)
    first[#first + 1] = { lines[1], highlight }
    b.add(first, target)

    for index = 2, #lines do
      b.add({ { string.rep(" ", indent) }, { lines[index], highlight } }, target)
    end
  end

  function b.para(value, highlight, target, indent)
    b.hang({ { string.rep(" ", indent or 1) } }, value, highlight, target)
  end

  -- One line with a right-aligned tail; the last left segment gives way.
  function b.row(left, right, target)
    local right_width, left_width = 0, 0
    for _, segment in ipairs(right) do right_width = right_width + width_of(segment[1]) end
    for index = 1, #left - 1 do left_width = left_width + width_of(left[index][1]) end
    local gap = right_width > 0 and 2 or 0
    local last = left[#left]
    local fitted = fit(last[1], math.max(1, b.width - left_width - right_width - gap))
    local segments = vim.list_slice(left, 1, #left - 1)
    segments[#segments + 1] = { fitted, last[2] }

    if right_width > 0 then
      local used = left_width + width_of(fitted)
      segments[#segments + 1] = { string.rep(" ", math.max(gap, b.width - used - right_width)) }
      vim.list_extend(segments, right)
    end

    return b.add(segments, target)
  end

  return b
end

M.page = page
M.fit = fit

local function finding_target(finding)
  return { kind = "finding", finding = finding, opportunity = finding.opportunity, experiment = finding.experiment,
    source = finding.opportunity.consumer_location }
end

local function decision_of(finding)
  local decision = finding.decision
  return decision and model.decisions[decision.status or decision.decision]
end

-- One glyph per obligation, in Plexus's order; counts when there are many.
local function progress(finding)
  local segments = {}

  if #finding.obligations <= 8 then
    for _, obligation in ipairs(finding.obligations) do
      local outcome = model.outcomes[obligation.outcome]
      segments[#segments + 1] = { outcome.icon, outcome.hl }
    end

    return segments
  end

  for _, id in ipairs({ "supported", "contradicted", "conflicting", "inconclusive", "unresolved", "unknown" }) do
    local count = finding.progress[id]

    if count then
      local outcome = model.outcomes[id]
      segments[#segments + 1] = { (#segments > 0 and " " or "") .. outcome.icon .. count, outcome.hl }
    end
  end

  return segments
end

local function run_outcomes(m)
  local counts, order = {}, { "supported", "contradicted", "inconclusive" }

  for _, finding in ipairs(m.findings) do
    for _, run in ipairs(finding.runs) do
      local outcome = model.outcomes[run.outcome] and run.outcome or "unknown"
      counts[outcome] = (counts[outcome] or 0) + 1
    end
  end

  local parts = {}

  for _, id in ipairs(vim.list_extend(order, { "unknown" })) do
    if counts[id] then parts[#parts + 1] = counts[id] .. " " .. model.outcomes[id].label end
  end

  return parts
end

local function evidence_line(m)
  if m.runs == 0 then return "No experiment has run yet; every finding is an inference." end
  return plural(m.runs, "run") .. ": " .. table.concat(run_outcomes(m), " · ") .. "; findings stay inferred."
end

local function delta_summary(m)
  local parts = {}

  for _, kind in ipairs({ "added", "removed", "changed", "unsupported" }) do
    if m.deltas[kind] then parts[#parts + 1] = #m.deltas[kind] .. " " .. kind end
  end

  return table.concat(parts, " · ")
end

local function revisions(m)
  return short(m.producer.base) .. " → " .. short(m.producer.head)
end

-- The list pane: what the investigation is, then its findings grouped by effect.
function M.list(m, width)
  local b = page(width)
  local overview = { kind = "overview" }
  b.add({ { " " .. fit(m.producer.project .. " → " .. m.consumer.project, width - 1), TITLE } }, overview)
  local status = m.status == "completed" and "" or (" · " .. text(m.status))
  b.add({ { " " .. fit(m.analysis.label .. " · " .. revisions(m) .. status, width - 1), MUTED } }, overview)
  b.para("“" .. text(m.intent) .. "”", nil, overview)

  if #m.findings > 0 then
    b.para(plural(#m.findings, "finding") .. ": " .. table.concat(model.counts(m.counts), " · "), nil, overview)
    b.para(evidence_line(m), MUTED, overview)
  end

  for _, group in ipairs(m.groups) do
    b.heading(group.effect.label:upper(), tostring(#group.findings), { kind = "group", group = group })

    for _, finding in ipairs(group.findings) do
      local decision = decision_of(finding)
      local quiet = decision and (decision.label == "dismissed" or decision.label == "deferred")
      local right = {}
      if decision then right[#right + 1] = { decision.label .. "  ", decision.hl } end
      vim.list_extend(right, progress(finding))

      b.row({ { " " .. finding.effect.icon .. " ", finding.effect.hl }, { text(finding.opportunity.title), quiet and MUTED or nil } },
        right, finding_target(finding))
    end
  end

  if #m.findings == 0 then
    if m.status == "completed" then
      b.heading("NO FINDINGS", nil, overview)
      b.para("No opportunities matched the supported rules.", nil, overview)
    else
      b.heading("ANALYSIS UNAVAILABLE", nil, overview)
      b.para("Analysis unavailable for this scope; Plexus kept the record with its reasons:", nil, overview)
      for _, limitation in ipairs(m.limitations) do b.hang({ { " • ", MUTED } }, limitation, nil, overview) end
    end
  end

  if m.delta_count > 0 or (#m.findings > 0 and #m.limitations > 0) then b.blank() end

  if m.delta_count > 0 then
    b.add({ { " API CHANGES", HEADING }, { " · " .. delta_summary(m), MUTED } }, { kind = "deltas" })
  end

  if #m.findings > 0 and #m.limitations > 0 then
    b.add({ { " SCOPE", HEADING }, { " · " .. plural(#m.limitations, "limitation"), MUTED } }, { kind = "scope" })
  end

  return b
end

local function field(b, label, value, highlight, target)
  b.hang({ { " " .. label .. string.rep(" ", math.max(1, 11 - width_of(label))), MUTED } }, value, highlight, target)
end

local function source_target(finding, location)
  return type(location) == "table" and { kind = "source", source = location, finding = finding } or nil
end

-- Where the provider's side of a finding is declared, when it has one.
local function provider_location(finding)
  local capability = finding.opportunity.capability
  if type(capability) == "table" and type(capability.source) == "table" then return capability.source end
  local consumer = finding.opportunity.consumer_location or {}

  for _, step in ipairs(list(finding.opportunity.evidence_path)) do
    if type(step.source) == "table" and step.source.path ~= consumer.path then return step.source end
  end
end

local function relationship(b, m, finding)
  local o, relation = finding.opportunity, finding.relation or {}
  local from, to = type(relation.from) == "table" and relation.from or {}, type(relation.to) == "table" and relation.to or {}
  local substitution = type(o.substitution) == "table" and o.substitution or nil
  local capability = type(o.capability) == "table" and o.capability or {}
  local symbol = from.path or (substitution and substitution.replacement_path) or capability.path or capability.name
  local shape = model.shape(finding.capability and finding.capability.shape) or (substitution and model.signature(substitution.signature))
  -- Only a relation that names no capability says the provider declares nothing.
  local missing = finding.relation and (relation.capability_id == nil or relation.capability_id == vim.NIL)
  local provided = symbol and (text(symbol) .. (missing and " · no matching declaration" or (shape and (" " .. shape) or "")))
  local producer = { { " " }, { m.producer.project .. " @ " .. short(m.producer.head), TITLE } }
  b.heading("RELATIONSHIP")

  if provided then
    table.insert(producer, { " · " })
    b.hang(producer, provided)
  else
    b.add(producer)
  end

  local where = provider_location(finding)

  if where then
    b.add({ { "   " }, { model.location(m, where), LOCATION } }, source_target(finding, where))
  end

  b.add({ { "   " .. finding.effect.verb, finding.effect.hl } })
  local requirement = finding.requirement and model.shape(finding.requirement.shape)
  local used = o.consumer_location

  -- A requirement named by its file is already the location line below.
  local needed = type(to.path) == "string" and to.path:sub(1, 1) ~= "/" and to.path
    or (substitution and substitution.previous_path) or nil

  if needed and requirement then needed = needed .. " " .. requirement end
  local consumer = { { " " }, { m.consumer.project .. " @ " .. short(m.consumer.revision), TITLE } }

  if needed then
    table.insert(consumer, { " · " })
    b.hang(consumer, needed)
  else
    b.add(consumer)
  end

  if type(used) == "table" then
    b.add({ { "   " }, { model.location(m, used), LOCATION } }, source_target(finding, used))
  end
end

local function proof_path(b, m, finding)
  local steps = list(finding.opportunity.evidence_path)
  if #steps == 0 then return end
  b.heading("PROOF PATH", "the chain Plexus followed")

  for index, step in ipairs(steps) do
    local target = source_target(finding, step.source)
    b.hang({ { string.format(" %d. ", index), MUTED } }, text(step.description), nil, target)
    local segments = { { string.rep(" ", #tostring(index) + 3) .. words(step.relation), MUTED } }
    if target then segments[#segments + 1] = { " · " .. model.location(m, step.source), LOCATION } end
    b.add(segments, target)
  end
end

local LADDER = 16

local function rung(icon, highlight, label)
  return { { " " .. icon .. " ", highlight }, { label .. string.rep(" ", math.max(1, LADDER - 3 - width_of(label))), highlight } }
end

-- The finding's epistemic path: what was observed, what the rule inferred, and
-- how far each obligation has been demonstrated.
local function evidence_state(b, m, finding)
  local supported, total = finding.progress.supported or 0, finding.progress.total
  b.heading("EVIDENCE STATE", total > 0 and (supported .. " of " .. plural(total, "obligation") .. " supported") or nil)
  local indent = string.rep(" ", LADDER)

  if #finding.claims == 0 and total == 0 then
    b.para("Plexus recorded no claims or obligations for this finding.", MUTED)
    return
  end

  -- Located support is navigable; the rest is named by kind (J shows the artifacts).
  local function supports(claim)
    local kinds, order = {}, {}

    for _, support in ipairs(list(claim.support)) do
      if type(support.source) == "table" then
        b.add({ { indent .. model.support_kind(support.kind), MUTED }, { " · " .. model.location(m, support.source), LOCATION } },
          source_target(finding, support.source))
      else
        local kind = model.support_kind(support.kind)
        if not kinds[kind] then order[#order + 1] = kind end
        kinds[kind] = (kinds[kind] or 0) + 1
      end
    end

    local named = vim.tbl_map(function(kind) return kinds[kind] > 1 and (kind .. " ×" .. kinds[kind]) or kind end, order)
    if #named > 0 then b.hang({ { indent } }, "also from " .. table.concat(named, ", "), MUTED) end
  end

  for _, claim in ipairs(finding.claims) do
    if claim.status == "observed" then
      b.hang(rung("✓", "OculusInvestigationPositive", "observed"), shorten(claim.statement))
      supports(claim)
    end
  end

  for _, claim in ipairs(finding.claims) do
    if claim.status ~= "observed" then
      b.hang(rung("◐", "OculusInvestigationInfo", text(claim.status)), "by rule " .. text(claim.rule_version) .. "; see Why")
      supports(claim)
    end
  end

  for _, obligation in ipairs(finding.obligations) do
    local outcome = model.outcomes[obligation.outcome]
    local label = obligation.outcome == "unknown" and words(obligation.status) or outcome.label
    b.hang(rung(outcome.icon, outcome.hl, label), shorten(obligation.label))

    if obligation.outcome == "unresolved" then
      local resolution = obligation.resolution or obligation.resolving_evidence
      if resolution then b.hang({ { indent } }, "needs " .. sentence(resolution), MUTED) end
    else
      local runs = #list(obligation.evidence)
      b.hang({ { indent } }, words(obligation.status) .. (runs > 0 and (" · " .. plural(runs, "run")) or ""), MUTED)
    end
  end
end

local function next_step(b, finding)
  b.heading("NEXT STEP")
  local offered = false

  if finding.experiment then
    local target = { kind = "action", action = "queue", finding = finding }
    b.hang({ { " n  ", KEY } }, text(finding.experiment.label), nil, target)
    b.add({ { "    queue it through Nexus; its result returns here as evidence", MUTED } }, target)
    offered = true
  end

  local preparation = finding.preparation

  if preparation then
    local blockers = list(preparation.blockers)

    if #blockers == 0 then
      local target = { kind = "action", action = "compose", finding = finding }
      b.hang({ { " p  ", KEY } }, text(preparation.label), nil, target)
      b.add({ { "    review the prepared plan before anything runs", MUTED } }, target)
    else
      b.hang({ { " p  ", MUTED } }, text(preparation.label), MUTED)
      b.hang({ { "    unavailable: ", "OculusInvestigationWarning" } }, table.concat(blockers, "; "), MUTED)
    end

    offered = true
  end

  if not offered then
    local message = "Plexus has no executable step for this finding yet; its obligations stay open until evidence arrives."
    if #finding.related > 0 then message = message .. " The related findings below concern the same requirement." end
    b.para(message, MUTED)
  end
end

local function case_highlight(status)
  if status == "passed" or status == "matched" then return "OculusInvestigationPositive" end
  if status == "failed" or status == "mismatched" then return "OculusInvestigationNegative" end
  return MUTED
end

local function artifact(b, finding, label, value)
  if type(value) ~= "string" then return end

  local target = { kind = "source", finding = finding,
    source = { artifact = value, digest = value, path = label, line = 1, column = 1 } }

  b.add({ { "        " .. label .. " ", MUTED }, { model.digest(value), LOCATION } }, target)
end

local function run_detail(b, finding, run)
  local outcome = model.outcomes[run.outcome] or model.outcomes.unknown
  b.hang({ { " " .. outcome.icon .. " ", outcome.hl } }, text(run.status) .. " · " .. model.run_kind(run) .. " · " .. model.digest(run.validation_id))
  if type(run.diagnostic) == "string" and run.diagnostic ~= "" then b.para(run.diagnostic, nil, nil, 3) end
  if type(run.scope) == "string" and run.scope ~= "" then b.hang({ { "   Scope: ", MUTED } }, run.scope, MUTED) end

  if run.kind == "rust_call_site_adaptation" then
    b.para("Adaptation needed: " .. text(run.adaptation_needed) .. " · adapted build: " .. text(run.adapted_build), nil, nil, 3)
  elseif run.kind == "c_zig_composition" then
    b.para("Native link: " .. text(run.link_status), nil, nil, 3)
  end

  for _, case in ipairs(list(run.cases)) do
    local status = case.status or case.verdict
    local name = text(case.label or case.name)
    b.add({ { "   Case: " .. name .. " · ", MUTED }, { text(status), case_highlight(status) } })

    if run.kind == "rust_call_site_adaptation" then
      b.para("before the change: " .. text(case.baseline) .. " · adapted after: " .. text(type(case.adapted) == "table" and case.adapted.status or case.adapted), MUTED, nil, 7)

      if type(case.adapted) == "table" then
        artifact(b, finding, "stdout", case.adapted.stdout)
        artifact(b, finding, "stderr", case.adapted.stderr)
      end
    elseif run.kind == "c_zig_composition" then
      b.para("expected exit " .. text(case.expected_exit) .. " · actual " .. text(case.actual_exit) .. " · expected stdout " .. text(case.expected_stdout), MUTED, nil, 7)
      artifact(b, finding, "stdout", case.stdout)
      artifact(b, finding, "stderr", case.stderr)
    else
      b.para("expected " .. text(case.expected) .. " · actual " .. text(case.actual), MUTED, nil, 7)
    end
  end

  for _, step in ipairs(list(run.steps)) do
    local phase = text(step.phase)

    if phase ~= "behavior" and not phase:match("_case$") then
      b.add({ { "   " .. words(phase) .. ": " .. text(step.name) .. " · ", MUTED },
        { step.success and "succeeded" or "failed", step.success and "OculusInvestigationPositive" or "OculusInvestigationNegative" } })

      artifact(b, finding, "stderr", step.stderr)
    end
  end

  for _, unresolved in ipairs(list(run.unresolved)) do
    b.hang({ { "   Unresolved: ", MUTED } }, words(unresolved), MUTED)
  end
end

local function runs(b, finding)
  b.heading("EVIDENCE", #finding.runs == 0 and "no runs yet" or plural(#finding.runs, "run"))

  if #finding.runs == 0 then
    b.para("Nothing has been executed for this finding.", MUTED)
    return
  end

  for index, run in ipairs(finding.runs) do
    if index > 1 then b.blank() end
    run_detail(b, finding, run)
  end

  b.blank()
  b.para("Each run resolves only the obligation it names; the finding itself stays inferred.", MUTED)
end

local function related(b, finding)
  if #finding.related == 0 then return end
  b.heading("RELATED", "same requirement")

  for _, other in ipairs(finding.related) do
    b.row({ { " " .. other.effect.icon .. " ", other.effect.hl }, { text(other.opportunity.title) } }, {},
      { kind = "related", finding = other })
  end
end

local function decision(b, finding)
  b.heading("DECISION")
  local recorded, meta = finding.decision, decision_of(finding)

  if recorded and meta then
    local note = recorded.rationale or recorded.diagnostic
    local when = model.date(recorded.created_unix_nanos)
    local detail = "developer decision by " .. text(recorded.actor or "developer") .. (when and (" · " .. when) or "")
    b.hang({ { " " .. meta.label, meta.hl }, { " · " } }, detail, MUTED)
    if type(note) == "string" and note ~= "" then b.hang({ { "   “" } }, note .. "”") end
  else
    b.para("None recorded. Decisions are your own attributed evidence and never change Plexus's claims.", MUTED)
  end

  local keys = { { " h", KEY }, { " promote  ", MUTED }, { "s", KEY }, { " select  ", MUTED }, { "d", KEY }, { " defer  ", MUTED },
    { "x", KEY }, { " dismiss", MUTED } }

  if recorded then vim.list_extend(keys, { { "  u", KEY }, { " clear", MUTED } }) end
  b.add(keys)
end

function M.finding(m, finding, width)
  local b = page(width)
  local o, effect = finding.opportunity, finding.effect
  b.add({ { " " .. effect.icon .. " " .. effect.single:upper(), effect.hl }, { " · " .. text(o.status), MUTED } })
  b.hang({ { " " } }, text(o.title), TITLE)
  relationship(b, m, finding)
  b.heading("WHY")
  b.para(text(o.explanation))
  proof_path(b, m, finding)
  evidence_state(b, m, finding)
  next_step(b, finding)
  runs(b, finding)
  related(b, finding)
  decision(b, finding)

  if #finding.limitations > 0 then
    b.heading("LIMITS")
    for _, limitation in ipairs(finding.limitations) do b.hang({ { " • ", MUTED } }, limitation, MUTED) end
  end

  return b
end

local function answer(b, m)
  b.heading("ANSWER")

  if #m.findings == 0 then
    if m.status == "completed" then
      b.para("No relationship matched the supported rules for this change. That is a result about these rules, not evidence that nothing changed.")
    else
      b.para("Plexus could not analyse this change and kept the record with its reasons (see Scope).")
    end

    return
  end

  local counts = model.counts(m.counts)
  local last = table.remove(counts)
  local listed = #counts > 0 and (table.concat(counts, ", ") .. " and " .. last) or last

  b.para("Plexus found " .. plural(#m.findings, "relationship") .. " between " .. m.producer.project .. "'s change and "
    .. m.consumer.project .. ": " .. listed .. ".")

  if m.runs == 0 then
    b.para("Nothing has been exercised yet: each finding is an inference from source and compiler evidence, and each obligation is open.")
  else
    b.para(plural(m.runs, "run") .. " recorded: " .. table.concat(run_outcomes(m), ", ")
      .. ". Evidence resolves named obligations only; every finding stays inferred.")
  end
end

local function next_steps(b, m)
  local queue, prepare, blocked = {}, {}, 0

  for _, group in ipairs(m.groups) do
    for _, finding in ipairs(group.findings) do
      if finding.experiment then queue[#queue + 1] = finding end

      if finding.preparation then
        if #list(finding.preparation.blockers) == 0 then prepare[#prepare + 1] = finding else blocked = blocked + 1 end
      end
    end
  end

  b.heading("NEXT STEPS")

  local function offer(key, findings, action)
    b.hang({ { " " .. key .. "  ", KEY } }, plural(#findings, "finding") .. " can " .. action .. ":")

    for index, finding in ipairs(findings) do
      if index > 4 then
        b.add({ { "      … and " .. (#findings - 4) .. " more", MUTED } })
        break
      end

      b.row({ { "    " .. finding.effect.icon .. " ", finding.effect.hl }, { text(finding.opportunity.title) } }, {},
        { kind = "related", finding = finding })
    end
  end

  if #queue > 0 then offer("n", queue, "queue an experiment through Nexus") end
  if #prepare > 0 then offer("p", prepare, "be prepared as a reviewable plan") end
  if blocked > 0 then b.para(plural(blocked, "preparation") .. " blocked; each finding says why.", MUTED) end

  if #queue == 0 and #prepare == 0 then
    b.para("No executable step is available; findings stay inferred until evidence arrives from elsewhere.", MUTED)
  else
    b.para("Move to a finding and press its key.", MUTED)
  end
end

function M.overview(m, width)
  local b = page(width)
  local status_hl = m.status == "completed" and MUTED or "OculusInvestigationWarning"
  b.add({ { " CHANGE INVESTIGATION", HEADING }, { " · " .. text(m.status), status_hl } })
  b.hang({ { " " } }, "“" .. text(m.intent) .. "”", TITLE)
  answer(b, m)
  if #m.findings > 0 then next_steps(b, m) end
  b.heading("OBSERVED")
  field(b, "Producer", m.producer.project .. " · " .. model.home(m.producer.repository))
  field(b, "Revisions", revisions(m) .. " (" .. text(m.producer.base) .. " → " .. text(m.producer.head) .. ")")

  if m.c_zig then
    field(b, "Header", text(m.producer.entry) .. " · " .. text(m.producer.language))
    if #m.producer.include_dirs > 0 then field(b, "Includes", table.concat(m.producer.include_dirs, ", ")) end
    field(b, "Consumer", m.consumer.project .. " · " .. model.home(m.consumer.repository) .. " @ " .. short(m.consumer.revision))
    field(b, "Zig source", text(m.consumer.entry))
  else
    field(b, "Manifest", text(m.producer.entry))
    field(b, "Consumer", m.consumer.project .. " · " .. model.home(m.consumer.repository) .. " @ " .. short(m.consumer.revision))
    field(b, "Manifest", text(m.consumer.entry))
  end

  field(b, "Analysis", m.analysis.label)
  if m.created then field(b, "Captured", m.created) end
  b.para("Committed sources only; uncommitted edits are excluded.", MUTED)

  if m.delta_count > 0 or #m.limitations > 0 then
    b.heading("MORE")
    if m.delta_count > 0 then b.para("API CHANGES lists " .. plural(m.delta_count, "declaration") .. " that differ: " .. delta_summary(m) .. ".", MUTED) end
    if #m.limitations > 0 then b.para("SCOPE lists " .. plural(#m.limitations, "limitation") .. " on what this analysis can establish.", MUTED) end
  end

  if m.status ~= "completed" then
    b.heading("SCOPE", plural(#m.limitations, "reason"))
    for _, limitation in ipairs(m.limitations) do b.hang({ { " • ", MUTED } }, limitation) end
  end

  b.heading("PROVENANCE")
  field(b, "Investigation", text(m.id), MUTED)

  for _, report in ipairs(m.reports) do
    field(b, "Report", text(report.report_id) .. " · rule " .. text(report.rule_version), MUTED)
  end

  local provenance = m.provenance
  if type(provenance.toolchain) == "string" then field(b, "Toolchain", provenance.toolchain, MUTED) end
  if type(provenance.target) == "string" then field(b, "Target", provenance.target, MUTED) end
  return b
end

function M.group(group, width)
  local b = page(width)
  local effect = group.effect
  b.add({ { " " .. effect.icon .. " " .. effect.label:upper(), effect.hl }, { " · " .. #group.findings, MUTED } })
  b.para(effect.about)
  b.heading("FINDINGS")

  for _, finding in ipairs(group.findings) do
    b.row({ { " " .. effect.icon .. " ", effect.hl }, { text(finding.opportunity.title) } }, progress(finding),
      { kind = "related", finding = finding })
  end

  return b
end

function M.deltas(m, width)
  local b = page(width)
  b.add({ { " API CHANGES", HEADING }, { " · " .. plural(m.delta_count, "declaration"), MUTED } })

  b.para("Declarations that differ between " .. short(m.producer.base) .. " and " .. short(m.producer.head)
    .. ", as the captured compiler or header shows them. Only some become findings: those a rule relates to the consumer.", MUTED)

  for _, kind in ipairs({ "added", "removed", "changed", "unsupported" }) do
    local paths = m.deltas[kind]

    if paths then
      b.heading(kind:upper(), tostring(#paths))
      for _, path in ipairs(paths) do b.para(path) end
    end
  end

  return b
end

function M.scope(m, width)
  local b = page(width)
  b.add({ { " SCOPE", HEADING }, { " · what this analysis can and cannot establish", MUTED } })
  b.blank()
  for _, limitation in ipairs(m.limitations) do b.hang({ { " • ", MUTED } }, limitation) end
  return b
end

-- The detail pane for whatever the list selects.
function M.detail(m, target, width)
  if not target or target.kind == "overview" then return M.overview(m, width) end
  if target.kind == "finding" then return M.finding(m, target.finding, width) end
  if target.kind == "group" then return M.group(target.group, width) end
  if target.kind == "deltas" then return M.deltas(m, width) end
  if target.kind == "scope" then return M.scope(m, width) end
  return M.overview(m, width)
end

local function preview_counts(preview)
  if not preview then return nil end
  if preview.error then return "Could not load findings: " .. text(preview.error), "OculusInvestigationWarning" end
  if not preview.model then return "Loading findings…", MUTED end
  local m = preview.model
  if #m.findings == 0 then return m.status == "completed" and "No findings" or nil, MUTED end
  return plural(#m.findings, "finding") .. ": " .. table.concat(model.counts(m.counts), " · "), MUTED
end

function M.catalog(entries, previews, width)
  local b = page(width)
  b.add({ { " " .. plural(#entries, "investigation") .. " · newest first", MUTED } })

  for _, entry in ipairs(entries) do
    b.blank()
    local when = entry.analysis.short .. (entry.created and (" · " .. entry.created) or "")
    b.row({ { " " }, { entry.producer .. " → " .. entry.consumer, TITLE } }, { { when, MUTED } }, entry.item)
    local right = entry.status ~= "completed" and { { text(entry.status), "OculusInvestigationWarning" } } or {}
    b.row({ { "   " }, { text(entry.intent) } }, right, entry.item)
    local summary, highlight = preview_counts(previews[entry.id])

    if summary then
      b.row({ { "   " }, { summary, highlight } }, {}, entry.item)
    elseif entry.status ~= "completed" and type(entry.item.limitations) == "table" then
      b.row({ { "   " }, { text(entry.item.limitations[#entry.item.limitations]), MUTED } }, {}, entry.item)
    end
  end

  if #entries == 0 then
    b.blank()
    b.para("No investigations. Use :OculusInvestigate or g on local activity.")
  end

  return b
end

function M.catalog_detail(entry, preview, width)
  local b = page(width)
  b.add({ { " " .. entry.producer .. " → " .. entry.consumer, TITLE } })
  b.hang({ { " " } }, "“" .. text(entry.intent) .. "”")
  b.blank()
  local item, observation = entry.item, entry.item.observation or {}
  field(b, "Status", text(entry.status), entry.status == "completed" and nil or "OculusInvestigationWarning")
  field(b, "Analysis", entry.analysis.label)
  field(b, "Producer", entry.producer .. " · " .. model.home(observation.repository))
  field(b, "Revisions", short(observation.base) .. " → " .. short(observation.head))
  field(b, "Consumer", entry.consumer .. " · " .. model.home(observation.consumer_repository) .. " @ " .. short(observation.consumer_revision))
  if entry.created then field(b, "Captured", entry.created) end
  local m = preview and preview.model

  if m and #m.findings > 0 then
    b.heading("FINDINGS", plural(#m.findings, "finding"))

    for _, group in ipairs(m.groups) do
      local count = #group.findings
      b.add({ { " " .. group.effect.icon .. " ", group.effect.hl }, { count .. " " .. (count == 1 and group.effect.one or group.effect.many) } })
    end

    b.para(evidence_line(m), MUTED)
  elseif entry.status == "completed" then
    local summary, highlight = preview_counts(preview)
    b.heading("FINDINGS")
    b.para(summary or "Findings are derived when you open it.", highlight or MUTED)
  end

  local limitations = list(item.limitations)

  if entry.status ~= "completed" and #limitations > 0 then
    b.heading("WHY IT STOPPED")
    for _, limitation in ipairs(limitations) do b.hang({ { " • ", MUTED } }, limitation) end
  end

  b.blank()
  b.add({ { " ⏎", KEY }, { " opens this investigation", MUTED } })
  field(b, "ID", text(entry.id), MUTED)
  return b
end

return M
