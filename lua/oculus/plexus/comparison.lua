local M = {}

local function text(value)
  return tostring(value):gsub("[%c]", " ")
end

local function artifact(value)
  return type(value) == "string" and #value == 71 and value:match("^sha256:%x+$")
end

local function values(value, nullable)
  if nullable and value == vim.NIL then return "unavailable" end
  assert(type(value) == "table" and vim.islist(value), "Invalid case values")

  for _, number in ipairs(value) do
    assert(type(number) == "number" and number == math.floor(number)
      and number >= -2147483648 and number <= 2147483647, "Invalid case integer")
  end

  return vim.json.encode(value)
end

function M.lines(report, left, right)
  assert(type(report) == "table" and report.schema_version == 1
    and report.kind == "runtime_comparison", "Invalid comparison schema")
  assert(artifact(report.comparison_id), "Missing comparison artifact ID")
  assert(report.left_run == left and report.right_run == right, "Comparison run IDs differ from request")
  assert(({ agreement_for_cases = true, divergence = true, inconclusive = true })[report.status], "Invalid comparison status")
  assert(type(report.cases) == "table" and vim.islist(report.cases), "Missing comparison cases")
  assert(type(report.limitations) == "table" and vim.islist(report.limitations), "Missing comparison limitations")
  local conclusions = { supported_for_cases = true, contradicted_by_case = true, inconclusive = true, unsupported = true }
  local lines = {
    "  PLEXUS · RUNTIME COMPARISON", "",
    "  Status: " .. report.status,
    "  Comparison: " .. report.comparison_id,
    "  Agreement concerns these cases only; both runtimes may agree on a wrong result.", "",
  }

  for _, side in ipairs({ "left", "right" }) do
    local runtime = report[side .. "_runtime"]
    assert(type(runtime) == "table" and type(runtime.backend) == "string"
      and type(runtime.version) == "string", "Missing runtime identity")
    assert(conclusions[report[side .. "_conclusion"]], "Invalid individual conclusion")
    lines[#lines + 1] = "  " .. side:upper() .. ": " .. text(runtime.backend) .. " " .. text(runtime.version)
    lines[#lines + 1] = "    Run: " .. text(report[side .. "_run"])
    lines[#lines + 1] = "    Individual conclusion: " .. report[side .. "_conclusion"]
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  CASES"

  for _, case in ipairs(report.cases) do
    assert(type(case) == "table" and type(case.name) == "string", "Invalid comparison case")
    assert(({ agreement = true, divergence = true, inconclusive = true })[case.status], "Invalid case status")
    lines[#lines + 1] = "  " .. text(case.name) .. " · " .. case.status
    lines[#lines + 1] = "    Expected: " .. values(case.expected, false)
    lines[#lines + 1] = "    Left: " .. values(case.left_values, true)
    lines[#lines + 1] = "    Right: " .. values(case.right_values, true)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  LIMITATIONS"

  for _, limitation in ipairs(report.limitations) do
    assert(type(limitation) == "string", "Invalid comparison limitation")
    lines[#lines + 1] = "  " .. text(limitation)
  end

  lines[#lines + 1] = ""
  lines[#lines + 1] = "  J: full comparison JSON · q: return to investigation"
  return lines
end

M.is_artifact = artifact
return M
