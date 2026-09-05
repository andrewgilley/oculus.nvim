local M = {}

function M.build_projection(bundle)
  local lines = {}
  local meta = bundle.metadata or {}
  lines[#lines + 1] = "# OCULUS INVESTIGATION FACT PROJECTION (Layers 1-24 Deterministic Ground Truth)"
  lines[#lines + 1] = string.format("Repository: %s", meta.repository_root or "Unknown")
  lines[#lines + 1] = string.format("Target: %s (Kind: %s)", meta.target or "HEAD", meta.target_kind or "commit")
  lines[#lines + 1] = string.format("Analyzed At: %s", meta.analyzed_at or "")
  lines[#lines + 1] = ""
  -- Invariants
  local invariants = bundle.invariants or {}

  if #invariants > 0 then
    lines[#lines + 1] = "## VERIFIED GROUND-TRUTH INVARIANTS"

    for _, inv in ipairs(invariants) do
      local icon = inv.passed and "[PASSED]" or "[FAILED]"
      lines[#lines + 1] = string.format("- %s %s: %s", icon, inv.invariant_name, inv.details)
    end

    lines[#lines + 1] = ""
  end

  -- Forge Artifact
  local forge_art = bundle.forge_artifact

  if forge_art and forge_art.id then
    lines[#lines + 1] = "## FORGE CONTEXT"

    lines[#lines + 1] = string.format("- %s #%s by @%s: \"%s\" (State: %s)",
      (forge_art.kind or "item"):upper(), forge_art.id, forge_art.author or "unknown",
      forge_art.title or "Untitled", forge_art.state or "open")

    if forge_art.body and forge_art.body ~= "" then
      lines[#lines + 1] = string.format("  Body: %s", forge_art.body:sub(1, 300):gsub("\n", " "))
    end

    lines[#lines + 1] = ""
  end

  -- Traceability
  local trace = bundle.traceability_links or {}

  if #trace > 0 then
    lines[#lines + 1] = "## TRACEABILITY CANDIDATES"

    for _, l in ipairs(trace) do
      local e = l.target_entity or {}

      lines[#lines + 1] = string.format("- [%d%%] %s (%s:%d): %s",
        math.floor(l.confidence * 100), e.qualified_name or e.name or "",
        e.file_path or "", e.start_line or 1, l.match_reason or "")
    end

    lines[#lines + 1] = ""
  end

  -- Modified Entities
  local entities = bundle.entities or {}

  if #entities > 0 then
    lines[#lines + 1] = string.format("## MODIFIED AST SYMBOLS (%d)", #entities)

    for _, e in ipairs(entities) do
      lines[#lines + 1] = string.format("- [%s] %s (%s:%d-%d)",
        (e.kind or "entity"):upper(), e.qualified_name or e.name,
        e.file_path, e.start_line, e.end_line)
    end

    lines[#lines + 1] = ""
  end

  -- Impact Callers & Tests
  local impact = bundle.impact

  if impact then
    local callers = impact.direct_callers or {}
    local tests = impact.affected_tests or {}
    lines[#lines + 1] = string.format("## CALL GRAPH & TEST COVERAGE BLAST RADIUS")
    lines[#lines + 1] = string.format("- Direct Callers: %d", #callers)

    for _, c in ipairs(callers) do
      lines[#lines + 1] = string.format("  * %s (%s:%d)", c.name, c.file_path, c.start_line)
    end

    lines[#lines + 1] = string.format("- Associated Tests: %d", #tests)

    for _, t in ipairs(tests) do
      lines[#lines + 1] = string.format("  * %s (%s:%d)", t.name, t.file_path, t.start_line)
    end

    lines[#lines + 1] = ""
  end

  -- Dynamics
  local dynamics = bundle.dynamics

  if dynamics then
    local crossings = dynamics.boundary_crossings or {}

    if #crossings > 0 then
      lines[#lines + 1] = "## ARCHITECTURAL BOUNDARY CROSSINGS"

      for _, bc in ipairs(crossings) do
        lines[#lines + 1] = string.format("- [%s RISK] %s -> %s (%s)",
          (bc.risk_level or "low"):upper(), bc.source_subsystem, bc.target_subsystem, bc.details)
      end

      lines[#lines + 1] = ""
    end

    local instabilities = dynamics.subsystem_instabilities or {}

    if #instabilities > 0 then
      lines[#lines + 1] = "## SUBSYSTEM INSTABILITIES"

      for _, inst in ipairs(instabilities) do
        lines[#lines + 1] = string.format("- [%s] %s (Instability: %.2f, Maintainer: @%s)",
          inst.risk_category, inst.subsystem, inst.instability_score, inst.primary_maintainer or "none")
      end

      lines[#lines + 1] = ""
    end
  end

  return table.concat(lines, "\n")
end

function M.synthesize(bundle, opts, callback)
  opts = opts or {}

  if type(callback) ~= "function" then
    callback = function() end
  end

  -- If engine already synthesized derived investigation, use it as solid ground truth
  if bundle and bundle.derived and #bundle.derived.hypotheses > 0 then
    callback(bundle.derived, nil)
    return
  end

  -- Construct baseline derived investigation directly if missing
  local entities = (bundle and bundle.entities) or {}
  local impact = bundle and bundle.impact
  local callers = (impact and impact.direct_callers) or {}
  local tests = (impact and impact.affected_tests) or {}
  local dynamics = bundle and bundle.dynamics
  local crossings = (dynamics and dynamics.boundary_crossings) or {}
  local hypotheses = {}
  local actions = {}

  if #entities > 0 then
    local primary = entities[1]
    local is_isolated = #callers == 0

    hypotheses[#hypotheses + 1] = {
      id = "hyp_blast_radius",
      title = is_isolated and "Localized Blast Radius: Symbol is Structurally Isolated" or "Expanded Blast Radius: Modifies Actively Invoked Symbol",
      rationale = string.format("Syntactic call graph analysis determined %d direct callers for `%s`.", #callers, primary.name),
      confidence = 0.95,
      claims = {
        {
          claim_id = "claim_callers",
          claim_type = is_isolated and "no_external_callers" or "isolated_symbol",
          subject = primary.name,
          assertion = is_isolated and string.format("`%s` has no external callers", primary.name)
            or string.format("`%s` is called by %d external symbols", primary.name, #callers),
        },
      },
      verifications = {
        {
          claim_id = "claim_callers",
          claim_type = is_isolated and "no_external_callers" or "isolated_symbol",
          assertion = is_isolated and string.format("`%s` has no external callers", primary.name)
            or string.format("`%s` is called by %d external symbols", primary.name, #callers),
          status = is_isolated and "CONFIRMED" or "REFUTED",
          confidence = 1.0,
          deterministic_evidence = {
            string.format("AST call graph search across indexed files yielded %d callers", #callers),
          },
          details = is_isolated and "Verified: zero callers found." or string.format("Verified: %d direct caller(s) detected.", #callers),
        },
      },
      suggested_actions = {
        {
          action_type = "test_generation",
          label = "Generate Invariant Test Scaffold",
          description = string.format("Generate regression unit test scaffold for `%s`", primary.name),
          target = primary.name,
          command_hint = ":OculusInvestigateTestScaffold",
        },
      },
    }
  end

  if #crossings > 0 then
    local bc = crossings[1]

    hypotheses[#hypotheses + 1] = {
      id = "hyp_boundary_leakage",
      title = "Architectural Leakage: Cross-Subsystem Coupling Detected",
      rationale = string.format("Boundary crossing detected between `%s` and `%s`.", bc.source_subsystem, bc.target_subsystem),
      confidence = 0.90,
      claims = {
        {
          claim_id = "claim_boundary",
          claim_type = "subsystem_confined",
          subject = bc.source_subsystem,
          assertion = string.format("Changes confined to `%s` without leaking into `%s`", bc.source_subsystem, bc.target_subsystem),
        },
      },
      verifications = {
        {
          claim_id = "claim_boundary",
          claim_type = "subsystem_confined",
          assertion = string.format("Changes confined to `%s` without leaking into `%s`", bc.source_subsystem, bc.target_subsystem),
          status = "REFUTED",
          confidence = 1.0,
          deterministic_evidence = {
            string.format("Crossing detected: %s -> %s (%s)", bc.source_subsystem, bc.target_subsystem, bc.details),
          },
          details = "Refuted: cross-subsystem invocation detected by boundary analyzer.",
        },
      },
      suggested_actions = {
        {
          action_type = "decouple_refactor",
          label = "Plan Subsystem Decoupling Refactor",
          description = string.format("Decouple `%s` from `%s`", bc.source_subsystem, bc.target_subsystem),
          target = string.format("%s ➔ %s", bc.source_subsystem, bc.target_subsystem),
          command_hint = ":OculusInvestigateRefactorPlan",
        },
      },
    }
  end

  local derived = {
    hypotheses = hypotheses,
    unanswered_questions = {
      "Do downstream callers handle updated return invariants?",
      "Are integration test suites running in CI for cross-subsystem changes?",
    },
    candidate_patches = {
      "Add automated invariant tests for modified entities",
    },
    adversarial_verdict = #crossings > 0 and "PARTIALLY_VERIFIED" or "ALL_CLAIMS_VERIFIED",
  }

  callback(derived, nil)
end

function M.generate_test_scaffold(entity, callers)
  entity = entity or {}
  callers = callers or {}
  local file_path = entity.file_path or "unknown.lua"
  local name = entity.name or "target_function"
  local ext = vim.fn.fnamemodify(file_path, ":e")
  local lines = {}

  if ext == "lua" then
    local mod = file_path:gsub("^lua/", ""):gsub("%.lua$", ""):gsub("/", ".")
    lines[#lines + 1] = string.format("-- Invariant regression test scaffold for `%s`", name)
    lines[#lines + 1] = string.format("-- Source: %s:%d", file_path, entity.start_line or 1)

    if #callers > 0 then
      lines[#lines + 1] = string.format("-- Direct callers: %d detected", #callers)

      for _, c in ipairs(callers) do
        lines[#lines + 1] = string.format("--   • %s (%s:%d)", c.name, c.file_path, c.start_line)
      end
    end

    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("local target = require(\"%s\")", mod)
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("describe(\"%s\", function()", name)
    lines[#lines + 1] = string.format("  it(\"preserves caller contract when invoked\", function()")
    lines[#lines + 1] = string.format("    assert(target.%s ~= nil, \"expected %s to be exported\")", name, name)
    lines[#lines + 1] = "    -- TODO: Add specific invariant assertions"
    lines[#lines + 1] = "  end)"
    lines[#lines + 1] = "end)"
  elseif ext == "rs" then
    lines[#lines + 1] = string.format("// Invariant regression test scaffold for `%s`", name)
    lines[#lines + 1] = string.format("// Source: %s:%d", file_path, entity.start_line or 1)
    lines[#lines + 1] = ""
    lines[#lines + 1] = "#[cfg(test)]"
    lines[#lines + 1] = "mod tests {"
    lines[#lines + 1] = "    use super::*;"
    lines[#lines + 1] = ""
    lines[#lines + 1] = string.format("    #[test]")
    lines[#lines + 1] = string.format("    fn test_%s_invariants() {", name:lower())
    lines[#lines + 1] = "        // Assert invariant behavior and return values"
    lines[#lines + 1] = "    }"
    lines[#lines + 1] = "}"
  else
    lines[#lines + 1] = string.format("/* Invariant test scaffold for %s */", name)
    lines[#lines + 1] = string.format("/* Source: %s:%d */", file_path, entity.start_line or 1)
  end

  return table.concat(lines, "\n")
end

function M.generate_refactor_plan(crossing)
  crossing = crossing or {}
  local src = crossing.source_subsystem or "source"
  local dst = crossing.target_subsystem or "target"
  local risk = (crossing.risk_level or "medium"):upper()

  local lines = {
    string.format("# Subsystem Decoupling Refactor Plan: %s ➔ %s", src, dst),
    string.format("Risk Level: [%s RISK]", risk),
    "",
    "## 1. Problem Statement",
    string.format("Direct structural dependency detected from `%s` into `%s`.", src, dst),
    string.format("Details: %s", crossing.details or "Direct call detected across subsystem boundary"),
    "",
    "## 2. Decoupling Recommendations",
    "• Strategy A (Dependency Inversion):",
    string.format("  Define an abstract interface/trait in `%s` and have `%s` implement it at runtime.", src, dst),
    "• Strategy B (Event-driven Notification):",
    string.format("  Publish an internal domain event from `%s`; subscribe to it in `%s` without direct linkage.", src, dst),
    "• Strategy C (Facade/Bridge):",
    string.format("  Introduce a dedicated boundary adapter isolating `%s` from implementation details.", dst),
    "",
    "## 3. Verification & Test Gate",
    "• Run `:OculusInvestigate` to confirm boundary crossing is resolved (0 crossings).",
    "• Verify all caller integration tests pass cleanly.",
  }

  return table.concat(lines, "\n")
end

return M
