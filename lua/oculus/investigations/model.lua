-- What a Plexus investigation means to the developer, arranged from the view
-- Plexus returns: findings grouped by their effect on the consumer, each joined
-- to its claims, obligations, runs and the actions Plexus accepts for it.
-- Plexus owns the meaning (effect, outcome, preparations); this only arranges it.
local M = {}

-- In the order a developer reads them: what became possible, what it takes,
-- then what the change cost, then context.
M.effects = {
  { id = "enables", single = "Newly possible", label = "Newly possible", icon = "+", hl = "OculusInvestigationPositive", verb = "now satisfies",
    one = "newly possible", many = "newly possible",
    about = "Nothing met this requirement before the change; a declaration meets it now." },
  { id = "substitutes", single = "Substitution path", label = "Substitution paths", icon = "⇄", hl = "OculusInvestigationInfo", verb = "may substitute for",
    one = "substitution path", many = "substitution paths",
    about = "Something the consumer relies on was removed or changed; a new capability has the shape to replace it." },
  { id = "needs_adapter", single = "One adapter away", label = "One adapter away", icon = "◇", hl = "OculusInvestigationHint", verb = "needs an adapter to satisfy",
    one = "needs an adapter", many = "need an adapter",
    about = "A capability matching the requirement exists, but only an explicit adapter can connect it." },
  { id = "unhandled", single = "Not yet handled", label = "Not yet handled", icon = "!", hl = "OculusInvestigationWarning", verb = "is not handled by",
    one = "not yet handled", many = "not yet handled",
    about = "The producer now exposes a capability that reaches a consumer path which rejects it." },
  { id = "breaks", single = "Broken by this change", label = "Broken by this change", icon = "✗", hl = "OculusInvestigationNegative", verb = "no longer satisfies",
    one = "broken", many = "broken",
    about = "The requirement was met before the change and is not met after it." },
  { id = "conflicts", single = "Incompatible", label = "Incompatible", icon = "≠", hl = "OculusInvestigationNegative", verb = "conflicts with",
    one = "incompatible", many = "incompatible",
    about = "The provider declares this, in a shape the requirement does not accept." },
  { id = "unmet", single = "Unmet", label = "Unmet", icon = "?", hl = "OculusInvestigationWarning", verb = "does not satisfy",
    one = "unmet", many = "unmet",
    about = "Neither revision declares anything that meets this requirement." },
  { id = "unchanged", single = "Unchanged", label = "Unchanged", icon = "=", hl = "OculusInvestigationMuted", verb = "still satisfies",
    one = "unchanged", many = "unchanged",
    about = "Met before and after the change; shown for context." },
  { id = "other", single = "Other finding", label = "Other findings", icon = "·", hl = "OculusInvestigationMuted", verb = "relates to",
    one = "other", many = "other",
    about = "Plexus did not classify this finding's effect." },
}

M.effect = {}
for _, effect in ipairs(M.effects) do M.effect[effect.id] = effect end

M.outcomes = {
  supported = { icon = "✓", label = "supported", hl = "OculusInvestigationPositive" },
  contradicted = { icon = "✗", label = "contradicted", hl = "OculusInvestigationNegative" },
  conflicting = { icon = "≠", label = "conflicting", hl = "OculusInvestigationNegative" },
  inconclusive = { icon = "?", label = "inconclusive", hl = "OculusInvestigationWarning" },
  unresolved = { icon = "○", label = "open", hl = "OculusInvestigationMuted" },
  unknown = { icon = "·", label = "unknown", hl = "OculusInvestigationMuted" },
}

M.decisions = {
  promoted = { label = "promoted", hl = "OculusInvestigationPositive" },
  selected = { label = "selected", hl = "OculusInvestigationInfo" },
  deferred = { label = "deferred", hl = "OculusInvestigationWarning" },
  dismissed = { label = "dismissed", hl = "OculusInvestigationMuted" },
}

M.analyses = {
  rust = { short = "Rust", label = "Rust API → consumer calls" },
  c_zig = { short = "C/C++ → Zig", label = "C/C++ ABI → Zig" },
}

local run_kinds = {
  rust_function_signature = "compiler signature check",
  plexus_wit_fixture = "normalizer fixture",
  rust_call_site_adaptation = "call-site adaptation",
  c_zig_composition = "native composition",
}

local support_kinds = {
  compiler_api = "compiler API",
  consumer_source = "consumer source",
  source_declaration = "source declaration",
  cargo_metadata = "Cargo metadata",
  experiment = "experiment",
}

local function present(value)
  return value ~= nil and value ~= vim.NIL
end

local function list(value)
  return type(value) == "table" and value or {}
end

function M.text(value)
  if not present(value) then return "—" end
  return (tostring(value):gsub("[%c]", " "))
end

function M.words(value)
  return (M.text(value):gsub("_", " "))
end

-- Commits read as short hashes; anything else (a tag, a test label) as given.
function M.short(revision)
  if not present(revision) then return "—" end
  local value = tostring(revision):gsub("^git:", "")
  if value:match("^%x+$") and #value >= 12 then return value:sub(1, 7) end
  return value
end

function M.digest(value)
  if not present(value) then return "—" end
  local hex = tostring(value):match("^sha256:(%x+)$")
  return hex and ("sha256:" .. hex:sub(1, 12) .. "…") or tostring(value)
end

function M.date(nanos)
  local seconds = type(nanos) == "string" and #nanos > 9 and tonumber(nanos:sub(1, -10))
  -- Earlier decisions stamped a monotonic clock; that is no date at all.
  return seconds and seconds >= 946684800 and os.date("%Y-%m-%d %H:%M", seconds) or nil
end

-- A repository path as the developer would type it.
function M.home(path)
  if type(path) ~= "string" or path == "" then return "—" end
  return vim.fn.fnamemodify(path, ":~")
end

function M.basename(path)
  if type(path) ~= "string" or path == "" then return "—" end
  return vim.fn.fnamemodify(path:gsub("/+$", ""), ":t")
end

function M.signature(signature)
  if type(signature) ~= "table" or type(signature.parameters) ~= "table" then return nil end
  local parameters = vim.tbl_map(M.text, signature.parameters)
  return "(" .. table.concat(parameters, ", ") .. ") → " .. M.text(signature.result)
end

-- A capability or requirement shape as a short signature, when it has one.
function M.shape(shape)
  if type(shape) ~= "table" then return nil end
  local signature = M.signature(type(shape.signature) == "table" and shape.signature or shape)
  if signature and present(shape.linkage) then signature = signature .. " · " .. M.text(shape.linkage) .. " linkage" end
  return signature
end

function M.run_kind(run)
  return run_kinds[run.kind] or (present(run.kind) and M.words(run.kind)) or "experiment"
end

function M.support_kind(kind)
  return support_kinds[kind] or M.words(kind)
end

local function unique(items)
  local seen, result = {}, {}

  for _, item in ipairs(items) do
    if type(item) == "string" and item ~= "" and not seen[item] then
      seen[item] = true
      result[#result + 1] = item
    end
  end

  return result
end

-- A path inside either repository reads relative to it, prefixed with the
-- project when producer and consumer are different repositories.
function M.relative(model, path)
  if type(path) ~= "string" then return "—" end
  local best

  for _, side in ipairs({ model.producer, model.consumer }) do
    local root = type(side.repository) == "string" and side.repository:gsub("/+$", "") or nil

    if root and root ~= "" and path:sub(1, #root + 1) == root .. "/" and (not best or #root > #best.root) then
      best = { root = root, project = side.project }
    end
  end

  if not best then return path end
  local relative = path:sub(#best.root + 2)
  return model.shared_repository and relative or (best.project .. "/" .. relative)
end

function M.location(model, location)
  if type(location) ~= "table" then return nil end
  return M.relative(model, location.path) .. ":" .. M.text(location.line)
end

local function outcome_of(value)
  return type(value) == "string" and M.outcomes[value] and value or "unknown"
end

-- Every finding joined to what Plexus said about it.
local function findings(view, decisions)
  local reasoning = type(view.reasoning) == "table" and view.reasoning or {}
  local claims_by_id, relations, capabilities, requirements, hypotheses = {}, {}, {}, {}, {}
  local obligations, claims, runs, experiments, preparations = {}, {}, {}, {}, {}
  for _, claim in ipairs(list(reasoning.claims)) do claims_by_id[claim.id] = claim end
  for _, capability in ipairs(list(reasoning.capabilities)) do capabilities[capability.id] = capability end
  for _, requirement in ipairs(list(reasoning.requirements)) do requirements[requirement.id] = requirement end
  for _, hypothesis in ipairs(list(reasoning.hypotheses)) do hypotheses[hypothesis.opportunity_id] = hypothesis end

  for _, obligation in ipairs(list(reasoning.obligations)) do
    local id = obligation.opportunity_id
    obligations[id] = obligations[id] or {}
    table.insert(obligations[id], obligation)
  end

  -- A claim without its own finding belongs to the finding whose obligations it names.
  for _, claim in ipairs(list(reasoning.claims)) do
    local owners = {}

    if type(claim.opportunity_id) == "string" then
      owners[claim.opportunity_id] = true
    else
      for id, items in pairs(obligations) do
        for _, obligation in ipairs(items) do
          if vim.tbl_contains(list(claim.obligations), obligation.id) then owners[id] = true end
        end
      end
    end

    for id in pairs(owners) do
      claims[id] = claims[id] or {}
      table.insert(claims[id], claim)
    end
  end

  for _, relation in ipairs(list(reasoning.relations)) do
    local claim = claims_by_id[relation.claim_id]
    if claim and type(claim.opportunity_id) == "string" then relations[claim.opportunity_id] = relation end
  end

  for _, run in ipairs(list(view.evidence)) do
    if run.kind ~= "developer_decision" and type(run.opportunity_id) == "string" then
      runs[run.opportunity_id] = runs[run.opportunity_id] or {}
      table.insert(runs[run.opportunity_id], run)
    end
  end

  for _, experiment in ipairs(list(view.experiments)) do experiments[experiment.opportunity_id] = experiment end

  for _, preparation in ipairs(list(view.preparations)) do
    preparations[preparation.opportunity_id] = preparations[preparation.opportunity_id] or preparation
  end

  local result = {}

  for _, report in ipairs(list(view.reports)) do
    assert(type(report.opportunities) == "table", "Missing report opportunities")

    for _, opportunity in ipairs(report.opportunities) do
      local id = opportunity.id
      local relation = relations[id]

      local finding = {
        id = id,
        index = #result + 1,
        opportunity = opportunity,
        report = report,
        effect = M.effect[opportunity.effect] or M.effect.other,
        relation = relation,
        capability = relation and capabilities[relation.capability_id],
        requirement = relation and requirements[relation.requirement_id],
        hypothesis = hypotheses[id],
        claims = claims[id] or {},
        obligations = {},
        runs = runs[id] or {},
        experiment = experiments[id],
        preparation = preparations[id],
        decision = decisions and decisions[id],
        progress = { total = 0 },
      }

      for _, obligation in ipairs(obligations[id] or {}) do
        local outcome = outcome_of(obligation.outcome)
        table.insert(finding.obligations, vim.tbl_extend("force", obligation, { outcome = outcome }))
        finding.progress[outcome] = (finding.progress[outcome] or 0) + 1
        finding.progress.total = finding.progress.total + 1
      end

      result[#result + 1] = finding
    end
  end

  return result
end

function M.build(view, decisions)
  assert(type(view) == "table" and type(view.observation) == "table", "Invalid investigation")
  local observation, provenance = view.observation, type(view.provenance) == "table" and view.provenance or {}
  local analysis = observation.analysis == "c_zig" and "c_zig" or "rust"

  local model = {
    view = view,
    id = view.investigation_id,
    status = view.status,
    intent = view.intent,
    created = M.date(view.created_unix_nanos),
    analysis = M.analyses[analysis],
    c_zig = analysis == "c_zig",
    shared_repository = observation.repository == observation.consumer_repository,
    producer = {
      project = present(provenance.producer_project) and provenance.producer_project or M.basename(observation.repository),
      repository = observation.repository,
      base = observation.base,
      head = observation.head,
      entry = observation.producer_header or observation.producer_manifest,
      language = observation.header_language,
      include_dirs = type(observation.producer_include_dirs) == "table" and observation.producer_include_dirs or {},
    },
    consumer = {
      project = present(provenance.consumer_project) and provenance.consumer_project or M.basename(observation.consumer_repository),
      repository = observation.consumer_repository,
      revision = observation.consumer_revision,
      entry = observation.consumer_source or observation.consumer_manifest,
    },
    provenance = provenance,
    reports = list(view.reports),
    deltas = {},
    delta_count = 0,
    counts = {},
    groups = {},
    runs = 0,
  }

  model.findings = findings(view, decisions)
  local global = vim.list_extend({}, list(view.limitations))
  for _, report in ipairs(model.reports) do vim.list_extend(global, list(report.limitations)) end
  -- A limit every finding shares describes the analysis, not one finding.
  local shared

  for _, finding in ipairs(model.findings) do
    local own = {}
    for _, limitation in ipairs(list(finding.opportunity.limitations)) do own[limitation] = true end

    if shared then
      for limitation in pairs(shared) do if not own[limitation] then shared[limitation] = nil end end
    else
      shared = own
    end
  end

  if #model.findings > 1 then
    for _, limitation in ipairs(list(model.findings[1].opportunity.limitations)) do
      if shared[limitation] then global[#global + 1] = limitation end
    end
  end

  model.limitations = unique(global)
  local known = {}
  for _, limitation in ipairs(model.limitations) do known[limitation] = true end

  for _, finding in ipairs(model.findings) do
    finding.limitations = vim.tbl_filter(function(limitation) return not known[limitation] end,
      unique(list(finding.opportunity.limitations)))

    model.counts[finding.effect.id] = (model.counts[finding.effect.id] or 0) + 1
    model.runs = model.runs + #finding.runs
  end

  for _, effect in ipairs(M.effects) do
    local members = vim.tbl_filter(function(finding) return finding.effect == effect end, model.findings)
    if #members > 0 then model.groups[#model.groups + 1] = { effect = effect, findings = members } end
  end

  -- Findings about the same consumer requirement answer to each other: a broken
  -- binding and the substitutions that could replace it.
  local by_requirement = {}

  for _, finding in ipairs(model.findings) do
    local to = finding.relation and finding.relation.to
    local key = type(to) == "table" and (M.text(to.project) .. "\0" .. M.text(to.path)) or nil
    finding.requirement_key = key

    if key then
      by_requirement[key] = by_requirement[key] or {}
      table.insert(by_requirement[key], finding)
    end
  end

  for _, finding in ipairs(model.findings) do
    finding.related = vim.tbl_filter(function(other) return other ~= finding end,
      finding.requirement_key and by_requirement[finding.requirement_key] or {})
  end

  for _, report in ipairs(model.reports) do
    for _, delta in ipairs(list(report.deltas)) do
      local kind = present(delta.kind) and delta.kind or "changed"
      model.deltas[kind] = model.deltas[kind] or {}
      table.insert(model.deltas[kind], M.text(delta.path))
      model.delta_count = model.delta_count + 1
    end
  end

  for _, kind in ipairs({ "added", "removed", "changed", "unsupported" }) do
    if model.deltas[kind] then table.sort(model.deltas[kind]) end
  end

  return model
end

-- "1 newly possible · 2 substitution paths · 1 broken"
function M.counts(counts)
  local parts = {}

  for _, effect in ipairs(M.effects) do
    local count = counts[effect.id]
    if count and count > 0 then parts[#parts + 1] = count .. " " .. (count == 1 and effect.one or effect.many) end
  end

  return parts
end

function M.plural(count, one, many)
  return count .. " " .. (count == 1 and one or (many or one .. "s"))
end

-- A catalog entry's identity, without deriving its findings.
function M.entry(item)
  local observation, provenance = item.observation or {}, type(item.provenance) == "table" and item.provenance or {}
  local analysis = M.analyses[observation.analysis == "c_zig" and "c_zig" or "rust"]

  return {
    item = item,
    id = item.investigation_id,
    producer = present(provenance.producer_project) and provenance.producer_project or M.basename(observation.repository),
    consumer = present(provenance.consumer_project) and provenance.consumer_project or M.basename(observation.consumer_repository),
    analysis = analysis,
    created = M.date(item.created_unix_nanos),
    status = item.status,
    intent = item.intent,
  }
end

return M
