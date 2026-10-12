-- 用假 hs API 加载 init.lua，捕获语法错误与顶层运行时错误（不需要 macOS 权限）
-- 用法：lua tools/mock_test.lua

local calls = {}
local pbCount = 0
local function rec(name)
  return function(...) calls[#calls + 1] = name; return true end
end

hs = {
  keycodes = { map = { fn = 63, ctrl = 59, cmd = 55, alt = 58, shift = 56 } },
  timer = {
    secondsSinceEpoch = function() return 0 end,
    doEvery = function() return { stop = function() end } end,
    doAfter = function() return { stop = function() end } end,
  },
  application = {
    runningApplications = function() return {} end,
    applicationForPID = function() return nil end,
    get = function() return nil end,
    find = function() return nil end,
  },
  notify = { new = function() return { send = function() end } end },
  pasteboard = {
    setContents = function() pbCount = pbCount + 1; return true end,
    getContents = function() return "" end,
    changeCount = function() return pbCount end,
    watcher = {
      interval = function() return 0.15 end,
      new = function() return { start = function() end, stop = function() end } end,
    },
  },
  hotkey = { bind = function(...) calls[#calls + 1] = "hotkey.bind"; return true end },
  open = function() return true end,
  axuielement = {
    systemWideElement = function() return nil end,
    applicationElementForPID = function() return nil end,
    observer = {
      new = function() return {
        callback = function() return true end,
        addWatcher = function() return true end,
        start = function() return true end,
        stop = function() return true end,
      } end,
    },
  },
  eventtap = {
    new = function()
      return {
        start = rec("tap.start"),
        stop = rec("tap.stop"),
        isEnabled = function() return true end,
      }
    end,
    event = {
      types = { keyDown = 10, flagsChanged = 12, tapDisabledByTimeout = -2, tapDisabledByUserInput = -1 },
      properties = { eventSourceUnixProcessID = 1 },
      newEvent = function()
        local e = {}
        e.setType = function() return e end
        e.setKeyCode = function() return e end
        e.setFlags = function() return e end
        e.post = function() calls[#calls + 1] = "event.post"; return true end
        return e
      end,
      newKeyEvent = function()
        local e = {}
        e.setFlags = function() return e end
        e.post = function() calls[#calls + 1] = "keyevent.post"; return true end
        return e
      end,
    },
  },
}

-- 默认相对于仓库根目录；用 tools/run_mock.sh 跑最省事
local path = arg[1] or "init.lua"
local chunk, err = loadfile(path)
if not chunk then
  print("SYNTAX ERROR: " .. tostring(err))
  os.exit(1)
end

local ok, mod = pcall(chunk)
if not ok then
  print("LOAD-TIME ERROR: " .. tostring(mod))
  os.exit(1)
end

print("SYNTAX + LOAD OK")

-- 顶层返回值检查（v2 的导出面）
for _, k in ipairs({ "dump", "pollPasteboard", "refreshPIDs", "snapshot", "toggle",
                     "toggleAutoResume", "resumeNow", "state", "counters" }) do
  if mod[k] == nil then print("MISSING EXPORT: " .. k); os.exit(1) end
end
print("EXPORTS OK")

-- 冒烟：调用不依赖真实 AX/权限的函数
local ok2, err2 = pcall(mod.pollPasteboard)
print("pollPasteboard(): " .. (ok2 and "OK" or ("ERROR " .. tostring(err2))))
local ok3, err3 = pcall(mod.toggle)
print("toggle(): " .. (ok3 and "OK" or ("ERROR " .. tostring(err3))))
local ok4, err4 = pcall(mod.refreshPIDs)
print("refreshPIDs(): " .. (ok4 and "OK" or ("ERROR " .. tostring(err4))))

-- 自动续上：开关 + 手动触发一次（真实发键，mock 下只记调用）
local ok5, err5 = pcall(mod.toggleAutoResume)
print("toggleAutoResume(): " .. (ok5 and "OK" or ("ERROR " .. tostring(err5))))
local ok6, err6 = pcall(mod.resumeNow)
print("resumeNow(): " .. (ok6 and "OK" or ("ERROR " .. tostring(err6))))
print("resume.enabled = " .. tostring(mod.resumeState.enabled))

local c = mod.counters()
print(string.format("counters: key=%s wx=%s tapDisabled=%s", tostring(c.key), tostring(c.wx), tostring(c.tapDisabled)))

print("HOTKEYS BOUND: " .. tostring(#calls))
os.exit((ok2 and ok3 and ok4 and ok5 and ok6) and 0 or 1)
