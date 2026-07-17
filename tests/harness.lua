-- Minimal test harness runnable with the standalone `lua` interpreter.
local M = { passed = 0, failed = 0, name = "" }

function M.describe(name) M.name = name end

local function fail(msg)
  M.failed = M.failed + 1
  print(string.format("  FAIL [%s] %s", M.name, msg or ""))
end
local function pass() M.passed = M.passed + 1 end

-- Deep-equality for plain tables/scalars.
local function deepeq(a, b)
  if type(a) ~= type(b) then return false end
  if type(a) ~= "table" then return a == b end
  for k, v in pairs(a) do if not deepeq(v, b[k]) then return false end end
  for k in pairs(b) do if a[k] == nil then return false end end
  return true
end

function M.eq(actual, expected, msg)
  if deepeq(actual, expected) then pass()
  else fail((msg or "") .. " (got " .. tostring(actual) .. ", want " .. tostring(expected) .. ")") end
end

function M.ok(cond, msg)
  if cond then pass() else fail(msg) end
end

function M.run()
  print(string.format("%d passed, %d failed", M.passed, M.failed))
  os.exit(M.failed == 0 and 0 or 1)
end

return M
