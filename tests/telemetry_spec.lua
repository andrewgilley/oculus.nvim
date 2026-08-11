local root = vim.fn.getcwd()
vim.opt.runtimepath:prepend(root)

local oculus = require("oculus")
local exported = {}
local reported_errors = {}
oculus.setup({
  persist_filters = false,
  persist_contributors = false,
  persist_projects = false,
  persist_inspect_overviews = false,
  telemetry = {
    enabled = true,
    service_name = "oculus-test",
    environment = "test",
    resource_attributes = {
      ["test.suite"] = "telemetry",
    },
    exporter = function(payload, span)
      exported[#exported + 1] = {
        payload = payload,
        span = span,
      }
    end,
    on_error = function(message)
      reported_errors[#reported_errors + 1] = message
    end,
  },
})

local telemetry = require("oculus.telemetry")
assert(telemetry.enabled())

local parent = telemetry.start("invoke_agent test", {
  ["gen_ai.operation.name"] = "invoke_agent",
  ["gen_ai.workflow.name"] = "oculus.test",
  ["oculus.test.count"] = 2,
  ["oculus.test.success"] = true,
})
assert(parent and #parent.trace_id == 32 and #parent.span_id == 16)
local parent_context = telemetry.finish(parent, {
  ["oculus.test.output.bytes"] = 14,
})
assert(vim.wait(1000, function()
  return #exported == 1
end))
assert(parent_context.trace_id == parent.trace_id)
local parent_payload = exported[1].payload
local resource_span = parent_payload.resourceSpans[1]
assert(resource_span.resource.attributes[1])
local exported_parent = resource_span.scopeSpans[1].spans[1]
assert(exported_parent.traceId == parent.trace_id)
assert(exported_parent.spanId == parent.span_id)
assert(exported_parent.status.code == 1)
assert(exported_parent.startTimeUnixNano:match("^%d+$"))
assert(exported_parent.endTimeUnixNano:match("^%d+$"))

local child_context = telemetry.record(
  "oculus.test.use_output",
  { ["oculus.test.selected"] = true },
  parent_context
)
assert(vim.wait(1000, function()
  return #exported == 2
end))
local exported_child = exported[2].payload.resourceSpans[1]
  .scopeSpans[1].spans[1]
assert(child_context.trace_id == parent_context.trace_id)
assert(exported_child.traceId == parent.trace_id)
assert(exported_child.parentSpanId == parent.span_id)
telemetry.finish(parent)
assert(#exported == 2, "a span must only be exported once")

local original_exepath = vim.fn.exepath
local original_system = vim.system
local captured_command
local captured_options
vim.fn.exepath = function(name)
  if name == "codex" then
    return "codex-test"
  end
  return original_exepath(name)
end
vim.system = function(command, options, callback)
  captured_command = command
  captured_options = options
  callback({
    code = 0,
    stdout = "private generated explanation",
    stderr = "model: gpt-5.6-sol",
  })
  return { test_process = true }
end

local completed
local process, explain_err = require("oculus.agent").explain({
  cwd = root,
  prompt = "private prompt and diff",
  model = "gpt-5.6-terra",
  workflow = "oculus.inspect.explanation",
  telemetry_attributes = {
    ["oculus.activity.kind"] = "issue",
    ["oculus.activity.changed_file_count"] = 3,
  },
}, function(text, err, metadata)
  completed = { text = text, err = err, metadata = metadata }
end)
assert(process and not explain_err)
assert(captured_command[1] == "codex-test")
assert(captured_options.stdin == "private prompt and diff")
assert(vim.wait(1000, function()
  return completed ~= nil and #exported == 3
end))
assert(completed.text == "private generated explanation")
assert(not completed.err)
assert(completed.metadata.model == "gpt-5.6-sol")
assert(completed.metadata.telemetry.trace_id)
local encoded = vim.json.encode(exported[3].payload)
assert(not encoded:find("private prompt", 1, true))
assert(not encoded:find("private generated", 1, true))
assert(encoded:find("oculus.inspect.explanation", 1, true))
assert(encoded:find("gpt-5.6-sol", 1, true))

vim.system = function(_, _, callback)
  callback({
    code = 7,
    stdout = "",
    stderr = "private provider failure detail",
  })
  return { test_process = true }
end
local failed
require("oculus.agent").explain({
  cwd = root,
  prompt = "another private prompt",
  model = "gpt-5.6-luna",
  workflow = "oculus.inspect.patch_locations",
  output_type = "json",
}, function(text, err, metadata)
  failed = { text = text, err = err, metadata = metadata }
end)
assert(vim.wait(1000, function()
  return failed ~= nil and #exported == 4
end))
assert(not failed.text)
assert(failed.err:find("private provider failure detail", 1, true))
local failed_span = exported[4].payload.resourceSpans[1]
  .scopeSpans[1].spans[1]
assert(failed_span.status.code == 2)
assert(failed_span.status.message == "codex_exit_error")
assert(not vim.json.encode(exported[4].payload):find(
  "private provider failure detail",
  1,
  true
))

local opinion = require("oculus.opinion")
local opinion_view = assert(opinion.consult({
  prompt = "private opinion context",
  model = "gpt-5.6-sol",
  workflow = "oculus.opinion.code_review",
}, {
  enter = false,
  provider = function()
    return {
      text = "private opinion output",
      model = "gpt-5.6-terra",
    }
  end,
}))
assert(vim.wait(1000, function()
  return not opinion_view.pending and #exported == 5
end))
local opinion_payload = vim.json.encode(exported[5].payload)
assert(opinion_payload:find("oculus.opinion.code_review", 1, true))
assert(opinion_payload:find("gpt-5.6-terra", 1, true))
assert(not opinion_payload:find("private opinion context", 1, true))
assert(not opinion_payload:find("private opinion output", 1, true))
opinion_view.close()

vim.fn.exepath = original_exepath
vim.system = original_system
assert(#reported_errors == 0)

oculus.config.telemetry.enabled = false
assert(not telemetry.enabled())
assert(telemetry.start("disabled") == nil)
