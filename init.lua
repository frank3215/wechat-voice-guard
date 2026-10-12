--[[
  WeChat Voice Guard — 微信语音输入保险箱（v2 · 低延迟版）
  ===============================================================
  背景：微信电脑版 4.1.8+ 的「语音输入」= 按住 fn 的全局听写。若语音停止时焦点不在输入框，
        它提示「输入失败」，识别结果随之消失。

  实测机制（微信 4.1.15 / macOS 15.0.1）：
        微信是先把**整段**识别结果合成**一个**键盘事件（keycode=0，整段文字作为 unicode 串）
        发出去，然后才报错。所以「输入失败」时，文字已经出现在系统事件流里，可以截获。

  重要性能约束（v1 就栽在这里）：
        CGEventTap 是**过滤型**的，macOS 会等回调返回才把按键交给前台应用；
        而 Hammerspoon 的 Lua 全跑在主线程上，所以**回调里任何耗时操作都会变成用户的输入延迟**。
        v1 在回调路径上做了 AX 树扫描、5 秒一次的全应用枚举、文件写入，结果系统反复
        因为 kCGEventTapDisabledByTimeout(-2) 禁用钩子 —— 用户感受到的就是"打字一卡一卡、按键被吞"。

        因此本版本铁律：
          1. 事件回调只做纯 Lua 表查找 + 取字段（微秒级），绝不能有 AX / 剪贴板 / 文件 I/O；
          2. 重活一律 hs.timer.doAfter(0, ...) 延后到回调之外；
          3. 微信进程表由定时器维护，回调里只查表，绝不枚举应用；
          4. 自动 AX 扫描一律删除（对微信也没用：它的 AX 树里 Text 元素 = 0）。
]]

local CONFIG = {
  bundleID      = "com.tencent.xinWeChat",
  outDir        = os.getenv("HOME") .. "/Library/Logs/WeChatVoiceGuard",
  interceptMode = false,   -- 是否吞掉微信的注入事件（文字只进剪贴板，不上屏）
  minLength     = 1,       -- 短于此长度的文本不记录
  mergeWindow   = 5.0,     -- 同一会话判定窗口（秒），窗口内才做流式合并/去重
  autoClipboard = true,    -- 捕获后把文字放进剪贴板（失败时直接 ⌘V）
  notify        = true,
  pidRefresh    = 10.0,    -- 微信进程表刷新间隔（秒）——绝不在事件回调里做
  pbPoll        = 0.2,     -- 剪贴板 changeCount 轮询间隔（秒）
  hotWindow     = 8.0,     -- 语音会话结束后 N 秒内视为"热"，才采信剪贴板变化
  perfWarnMs    = 50,      -- 任何一步超过这个耗时就打 [perf] 日志
  followUpDelays = { 0.05, 0.12, 0.3, 0.6, 1.2 },  -- 微信事件后追读剪贴板的时点（秒）

  -- ── 可选功能：转写停止后自动"续上"语音输入 ──────────────────────────────
  -- 微信长时间静音会自动停止听写；开启后，每次转写结束（捕获到一次微信注入事件）
  -- 就自动补按一次快捷键，把听写重新接上。默认关闭，用 ⌥⌘S 开关（状态存盘）。
  autoResume = {
    enabled    = false,
    combo      = { mods = { "ctrl" }, key = "fn" },  -- 默认 control+fn
    strategy   = "flags",   -- "flags"（官方推荐的修饰键写法）| "key"（keyDown/keyUp）| "both"
    mode       = "tap",     -- "tap"：轻点一下 | "hold"：按住，直到下次转写结束才放
    delay      = 0.8,       -- 转写结束后等多久再续（秒）
    holdMs     = 80,        -- tap 模式按下多久（毫秒）
    maxHoldSec = 90,        -- hold 模式的安全释放超时（秒），防止 fn 被永久按住
    minGap     = 2.0,       -- 两次续上之间最小间隔（秒）
    maxChain   = 100,       -- 连续续上的硬上限（0 = 不限），防呆用
  },
}

local LOG_FILE   = CONFIG.outDir .. "/capture.log"
local EVENT_FILE = CONFIG.outDir .. "/events.log"
local TREE_FILE  = CONFIG.outDir .. "/ax-tree.txt"
local STATE_FILE = CONFIG.outDir .. "/state.json"

local state = { intercept = CONFIG.interceptMode, history = {}, lastText = "", lastCaptureAt = 0 }
local wxPidSet = {}          -- 只由定时器维护；事件回调里只读
local lastWxEventAt = 0
local voiceHotAt = 0
local lastPBChange = 0
local keySeen, wxKeySeen, tapDisabledCount = 0, 0, 0

--------------------------------------------------------------------------------
-- 基础设施
--------------------------------------------------------------------------------

local function appendLog(path, line)
  local f = io.open(path, "a")
  if not f then return end
  f:write(os.date("%Y-%m-%d %H:%M:%S") .. "\t" .. line .. "\n")
  f:close()
end

local function log(line) appendLog(LOG_FILE, line) end
local function logEvent(line) appendLog(EVENT_FILE, line) end

local function notify(title, text)
  if not CONFIG.notify then return end
  pcall(function() hs.notify.new({ title = title, informativeText = text }):send() end)
end

local function esc(s)
  return (tostring(s):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n")
                    :gsub("\r", ""):gsub("\t", "\\t"))
end

local function persist()
  local f = io.open(STATE_FILE, "w")
  if not f then return end
  local rows = {}
  for _, item in ipairs(state.history) do
    rows[#rows + 1] = string.format('{"ts":"%s","source":"%s","text":"%s"}',
      item.ts, esc(item.source), esc(item.text))
  end
  f:write('{"last":"' .. esc(state.lastText) .. '","count":' .. #state.history ..
          ',"history":[' .. table.concat(rows, ",") .. ']}')
  f:close()
end

-- 给任何"可能变慢"的步骤套一层计时，超阈值就打日志。
-- 用户能感知的输入延迟就是从这里找出来的，别再靠猜。
local slowCount = {}
local function withPerf(name, fn, ...)
  local t0 = hs.timer.secondsSinceEpoch()
  local ok, err = pcall(fn, ...)
  local ms = (hs.timer.secondsSinceEpoch() - t0) * 1000
  if ms >= CONFIG.perfWarnMs then
    slowCount[name] = (slowCount[name] or 0) + 1
    log(string.format("[perf] %s 耗时 %.0fms（累计 %d 次）", name, ms, slowCount[name]))
  end
  if not ok then log(string.format("[perf] %s 出错: %s", name, tostring(err))) end
end

--------------------------------------------------------------------------------
-- 微信进程表：只在定时器里刷新，事件回调里只查表
--------------------------------------------------------------------------------

local function refreshWeChatPIDs()
  local set = {}
  for _, a in ipairs(hs.application.runningApplications() or {}) do
    local bid = a:bundleID() or ""
    local nm  = a:name() or ""
    if bid == CONFIG.bundleID or bid:find("^com%.tencent%.xinWeChat")
       or nm:find("WeChat") or nm:find("微信") then
      set[a:pid()] = true
    end
  end
  wxPidSet = set
end

--------------------------------------------------------------------------------
-- 捕获
--------------------------------------------------------------------------------

local function capture(text, source)
  if type(text) ~= "string" then return end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if #text < CONFIG.minLength then return end

  local nowEp = hs.timer.secondsSinceEpoch()
  local sameSession = (nowEp - (state.lastCaptureAt or 0)) <= CONFIG.mergeWindow
  -- 同一会话内的重复才丢；隔了很久又说了一遍同一句话时，必须算新的一条
  if text == state.lastText and sameSession then return end

  local now = os.date("%Y-%m-%d %H:%M:%S")
  local head = state.history[1]
  local merged = false
  -- 只在同一会话内做前缀增长合并
  if sameSession and head and head.text ~= text then
    if text:sub(1, #head.text) == head.text or head.text:sub(1, #text) == text then
      if #text > #head.text then head.text = text end
      head.ts, head.source, merged = now, source, true
    end
  end
  if not merged then
    table.insert(state.history, 1, { ts = now, source = source, text = text })
    while #state.history > 300 do table.remove(state.history) end
  end

  state.lastText = text
  state.lastCaptureAt = nowEp
  -- 剪贴板来源的内容本来就在剪贴板上，别回写，免得和微信的流式更新抢剪贴板
  if CONFIG.autoClipboard and source:sub(1, 9) ~= "clipboard" then
    hs.pasteboard.setContents(text)
  end
  log(string.format("[%s]%s %s", source, merged and " (合并)" or "", text:gsub("\n", "\\n")))
  persist()
  notify("语音已截获 (" .. source .. ")", text:sub(1, 120))
end

-- 只读 changeCount，变了才碰剪贴板内容
local function pollPasteboard(source, force)
  local cc = hs.pasteboard.changeCount()
  if cc == lastPBChange then return nil end
  lastPBChange = cc
  local v = hs.pasteboard.getContents()
  if type(v) ~= "string" or #v < CONFIG.minLength then return nil end
  local now = hs.timer.secondsSinceEpoch()
  local hot = force or (now - voiceHotAt) <= CONFIG.hotWindow
                      or (now - lastWxEventAt) <= CONFIG.hotWindow
  if not hot then return nil end
  capture(v, source)
  lastPBChange = hs.pasteboard.changeCount()
  return v
end

--------------------------------------------------------------------------------
-- 可选功能：转写停止后自动"续上"（⌥⌘S 开关，默认关）
--
-- 实现要点：fn 是**修饰键**，光发 keyDown/keyUp 很多应用收不到；官方推荐做法是
-- 发 flagsChanged 事件（newEvent + setType + setKeyCode + setFlags + post）。
-- 所以 strategy 默认 "flags"，保留 "key"/"both" 供实测不通时切换。
--------------------------------------------------------------------------------

local FN_CODE = (hs.keycodes.map and hs.keycodes.map.fn) or 63
local RESUME_FLAG_FILE = CONFIG.outDir .. "/autoresume.state"

local resume = { enabled = false, chain = 0, lastAt = 0, held = false, holdTimer = nil }

local function resumeName()
  local c = CONFIG.autoResume.combo
  local mods = c.mods or {}
  if #mods == 0 then return c.key end
  return table.concat(mods, "+") .. "+" .. c.key
end

local function comboFlags()
  local t = {}
  for _, m in ipairs(CONFIG.autoResume.combo.mods or {}) do t[m] = true end
  t[CONFIG.autoResume.combo.key] = true
  return t
end

local function postFlagsChanged(flags)
  local e = hs.eventtap.event.newEvent()
  e:setType(hs.eventtap.event.types.flagsChanged)
  e:setKeyCode(FN_CODE)
  e:setFlags(flags)
  e:post()
end

local function postKeyEvent(down)
  local e = hs.eventtap.event.newKeyEvent({}, FN_CODE, down)
  e:setFlags(down and comboFlags() or {})
  e:post()
end

local function pressResumeKey()
  local st = CONFIG.autoResume.strategy
  if st == "flags" or st == "both" then postFlagsChanged(comboFlags()) end
  if st == "key"   or st == "both" then postKeyEvent(true) end
end

local function releaseResumeKey()
  local st = CONFIG.autoResume.strategy
  if st == "flags" or st == "both" then postFlagsChanged({}) end
  if st == "key"   or st == "both" then postKeyEvent(false) end
end

local function releaseHeld(why)
  if resume.holdTimer then resume.holdTimer:stop(); resume.holdTimer = nil end
  if resume.held then
    resume.held = false
    releaseResumeKey()
    log("[resume] 释放 " .. resumeName() .. (why and ("（" .. why .. "）") or ""))
  end
end

local function saveResumeFlag()
  local f = io.open(RESUME_FLAG_FILE, "w")
  if f then f:write(resume.enabled and "1" or "0"); f:close() end
end

-- manual = ⌥⌘T 手动测试：忽略开关、间隔与上限（用来先确认键位对不对）
local function doResume(why, manual)
  if not resume.enabled and not manual then return end
  if manual then releaseHeld("手动触发前先松开") end

  local now = hs.timer.secondsSinceEpoch()
  if not manual then
    if (now - resume.lastAt) < CONFIG.autoResume.minGap then
      log("[resume] 距上次续上不足 " .. CONFIG.autoResume.minGap .. "s，跳过")
      return
    end
    if CONFIG.autoResume.maxChain > 0 and resume.chain >= CONFIG.autoResume.maxChain then
      resume.enabled = false
      saveResumeFlag()
      log("[resume] 连续续上达上限 " .. CONFIG.autoResume.maxChain .. " 次，已自动关闭")
      notify("Voice Guard", "自动续上达上限，已关闭")
      return
    end
    resume.chain = resume.chain + 1
  end
  resume.lastAt = now

  if CONFIG.autoResume.mode == "hold" then
    pressResumeKey()
    resume.held = true
    resume.holdTimer = hs.timer.doAfter(CONFIG.autoResume.maxHoldSec, function()
      releaseHeld("按住超时安全释放")
    end)
    log(string.format("[resume] 按住 %s（%s；等下次转写结束再放）", resumeName(), why))
  else
    pressResumeKey()
    hs.timer.doAfter(CONFIG.autoResume.holdMs / 1000, releaseResumeKey)
    log(string.format("[resume] 轻点 %s（%s）", resumeName(), why))
  end
end

local function toggleAutoResume()
  resume.enabled = not resume.enabled
  if not resume.enabled then releaseHeld("关闭功能") end
  resume.chain = 0
  saveResumeFlag()
  log("[resume] 自动续上 = " .. tostring(resume.enabled) ..
      (resume.enabled and ("（" .. resumeName() .. "，模式 " .. CONFIG.autoResume.mode ..
                          "，策略 " .. CONFIG.autoResume.strategy .. "）") or ""))
  notify("Voice Guard", resume.enabled and ("自动续上：开（" .. resumeName() .. "）") or "自动续上：关")
end

--------------------------------------------------------------------------------
-- 微信注入事件到达后的重活，全部在这里做（已离开事件回调）
--------------------------------------------------------------------------------

local function handleInjection(s, code, flags, pid)
  -- 本次转写结束：hold 模式在这里松手，随后再按下一轮
  releaseHeld("转写结束")

  local flagStr = {}
  for k in pairs(flags or {}) do flagStr[#flagStr + 1] = k end
  table.sort(flagStr)
  logEvent(string.format("pid=%s keycode=%s flags=[%s] unicode=%s",
    tostring(pid), tostring(code), table.concat(flagStr, ","),
    (type(s) == "string" and s ~= "") and ("'" .. s:gsub("\n", "\\n") .. "'") or "<空>"))

  -- 顺手抢一次剪贴板（有的路径会先写剪贴板）
  local v = pollPasteboard("pasteboard:动作瞬间", true)
  if v then log("[pb] 已在微信动作瞬间抢到 " .. #v .. " 字") end
  for _, d in ipairs(CONFIG.followUpDelays) do
    hs.timer.doAfter(d, function() withPerf("pollPasteboard", pollPasteboard, "pasteboard:事后" .. d .. "s", true) end)
  end

  if type(s) == "string" and s ~= "" then
    capture(s, "eventtap")
  end

  -- 可选：续上听写
  if resume.enabled then
    hs.timer.doAfter(CONFIG.autoResume.delay, function() doResume("转写结束") end)
  end
end

--------------------------------------------------------------------------------
-- 事件回调：这里的一切都会直接变成用户的输入延迟，所以只做微秒级的事
--------------------------------------------------------------------------------

local eventtap
local TAP_TIMEOUT   = rawget(hs.eventtap.event.types, "tapDisabledByTimeout")
local TAP_USERINPUT = rawget(hs.eventtap.event.types, "tapDisabledByUserInput")
local PROP_SRC_PID  = hs.eventtap.event.properties.eventSourceUnixProcessID

local function startEventTap()
  if eventtap then pcall(function() eventtap:stop() end) end

  local types = { hs.eventtap.event.types.keyDown }
  if TAP_TIMEOUT then types[#types + 1] = TAP_TIMEOUT end
  if TAP_USERINPUT then types[#types + 1] = TAP_USERINPUT end

  eventtap = hs.eventtap.new(types, function(e)
    local etype = e:getType()

    if etype == TAP_TIMEOUT or etype == TAP_USERINPUT then
      tapDisabledCount = tapDisabledCount + 1
      log("[tap] 钩子被系统禁用(type=" .. tostring(etype) .. ") → 重新启用")
      -- 不要在回调里直接 start，延后一拍
      hs.timer.doAfter(0, function() pcall(function() eventtap:start() end) end)
      return false
    end

    keySeen = keySeen + 1
    local pid = e:getProperty(PROP_SRC_PID)
    if not pid or not wxPidSet[pid] then return false end   -- 纯表查找，微秒级

    -- 只有微信注入事件这一瞬才继续；字段同步取（便宜），重活延后
    wxKeySeen = wxKeySeen + 1
    local now = hs.timer.secondsSinceEpoch()
    lastWxEventAt = now
    local s     = e:getUnicodeString()
    local code  = e:getKeyCode()
    local flags = e:getFlags() or {}

    hs.timer.doAfter(0, function() withPerf("handleInjection", handleInjection, s, code, flags, pid) end)

    if type(s) == "string" and s ~= "" then
      return state.intercept     -- 拦截模式：同步吞掉（必须同步决定）
    end
    return false
  end)

  eventtap:start()
  local ok, running = pcall(function() return eventtap:isEnabled() end)
  log("[tap] 事件钩子启动 isEnabled=" .. tostring(ok and running) ..
      "（v2：回调内不做任何 AX/剪贴板/文件 I/O）")
end

--------------------------------------------------------------------------------
-- 手动诊断（只在按热键时运行；它会阻塞输入几秒，属正常）
--------------------------------------------------------------------------------

local function walk(root, depth, maxDepth, acc)
  if not root or depth > maxDepth then return acc end
  acc[#acc + 1] = { el = root, depth = depth }
  local ok, kids = pcall(function() return root:attributeValue("AXChildren") end)
  if ok and type(kids) == "table" then
    for _, c in ipairs(kids) do walk(c, depth + 1, maxDepth, acc) end
  end
  return acc
end

local function describe(el)
  local function g(k) local ok, v = pcall(function() return el:attributeValue(k) end); return ok and v or nil end
  local role = tostring(g("AXRole") or "?")
  local sub  = tostring(g("AXSubrole") or "")
  local ttl  = tostring(g("AXTitle") or "")
  local val  = tostring(g("AXValue") or "")
  return string.format("%s/%s | title=%s | value=%s", role, sub, ttl:sub(1, 60), val:gsub("\n", "\\n"):sub(1, 200))
end

local function dumpTree(reason)
  local f = io.open(TREE_FILE, "w")
  if not f then return end
  f:write("# WeChat AX tree @ " .. os.date("%Y-%m-%d %H:%M:%S") .. " reason=" .. tostring(reason or "manual") .. "\n")
  for pid in pairs(wxPidSet) do
    f:write("\n## pid=" .. pid .. "\n")
    local appEl = hs.axuielement.applicationElementForPID(pid)
    if not appEl then
      f:write("   <取不到 AX 元素：缺辅助功能权限，或进程已退出>\n")
    else
      for _, item in ipairs(walk(appEl, 0, 12, {})) do
        f:write(string.rep("  ", item.depth) .. describe(item.el) .. "\n")
      end
    end
  end
  f:close()
  log("[dump] 已写出 " .. TREE_FILE .. " (reason=" .. tostring(reason or "manual") .. ")")
  if (reason or "manual") == "manual" then notify("Voice Guard", "AX 树已写出") end
end

--------------------------------------------------------------------------------
-- 手动操作
--------------------------------------------------------------------------------

local function snapshotFocused()
  local ok, v = pcall(function()
    local sys = hs.axuielement.systemWideElement()
    local el = sys and sys:attributeValue("AXFocusedUIElement")
    return el and el:attributeValue("AXValue")
  end)
  if not ok or type(v) ~= "string" then notify("Voice Guard", "拿不到焦点元素") return end
  capture(v, "snapshot")
end

local function copyLast()
  if state.lastText == "" then notify("Voice Guard", "还没捕获到内容") return end
  hs.pasteboard.setContents(state.lastText)
  notify("Voice Guard", "已复制上一条捕获")
end

local function toggleIntercept()
  state.intercept = not state.intercept
  log("[mode] intercept=" .. tostring(state.intercept))
  notify("Voice Guard", state.intercept and "拦截模式：开（只进剪贴板不上屏）" or "拦截模式：关（正常上屏 + 备份）")
end

--------------------------------------------------------------------------------
-- 启动
--------------------------------------------------------------------------------

hs.hotkey.bind({ "alt", "cmd" }, "c", copyLast)
hs.hotkey.bind({ "alt", "cmd" }, "v", snapshotFocused)
hs.hotkey.bind({ "alt", "cmd" }, "i", toggleIntercept)
hs.hotkey.bind({ "alt", "cmd" }, "s", toggleAutoResume)                        -- 自动续上开关
hs.hotkey.bind({ "alt", "cmd" }, "t", function() doResume("手动测试", true) end) -- 手动试一次键位
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "d", function() dumpTree("manual") end)
hs.hotkey.bind({ "alt", "cmd" }, "l", function() hs.open(LOG_FILE) end)

log("=== WeChat Voice Guard v2 启动 ===")
refreshWeChatPIDs()
log("[pid] 微信进程 " .. (function() local n = 0; for _ in pairs(wxPidSet) do n = n + 1 end; return n end)() ..
    " 个（由定时器维护，事件回调只查表）")

-- 自动续上：回读开关状态；并先清一次可能残留的修饰键（上次 hold 中途被重载会卡住 fn）
do
  local f = io.open(RESUME_FLAG_FILE, "r")
  if f then
    local s = f:read("*a") or ""
    f:close()
    resume.enabled = s:find("1") ~= nil
  end
  pcall(releaseResumeKey)   -- 清残留
  log("[resume] 自动续上 = " .. tostring(resume.enabled) ..
      "（" .. resumeName() .. "，模式 " .. CONFIG.autoResume.mode ..
      "，策略 " .. CONFIG.autoResume.strategy ..
      "，延迟 " .. CONFIG.autoResume.delay .. "s；⌥⌘S 开关，⌥⌘T 手动试一次）")
end

local okTap, errTap = pcall(startEventTap)
if not okTap then log("[tap] 启动失败：" .. tostring(errTap)) end

lastPBChange = hs.pasteboard.changeCount()

-- 定时器必须挂全局强引用：只放局部变量里会被 GC 回收，定时器静默停摆
local timers = {}
timers.pid = hs.timer.doEvery(CONFIG.pidRefresh, function() withPerf("refreshWeChatPIDs", refreshWeChatPIDs) end)
timers.pb  = hs.timer.doEvery(CONFIG.pbPoll, function() withPerf("pollPasteboard", pollPasteboard, "pasteboard") end)

local lastKey, lastWx = 0, 0
timers.hb = hs.timer.doEvery(60, function()
  local d, w = keySeen - lastKey, wxKeySeen - lastWx
  lastKey, lastWx = keySeen, wxKeySeen
  log(string.format("[hb] 近60秒键盘事件=%d 微信来源=%d 钩子被禁用=%d", d, w, tapDisabledCount))
end)

log("[hint] 若 [perf] 行频繁出现或 [hb] 里'钩子被禁用'在涨，说明回调变慢了，务必先查回调路径")
notify("Voice Guard", "v2 已启动（低延迟）")

local mod = {
  dump = dumpTree,
  pollPasteboard = pollPasteboard,
  refreshPIDs = refreshWeChatPIDs,
  snapshot = snapshotFocused,
  toggle = toggleIntercept,
  toggleAutoResume = toggleAutoResume,
  resumeNow = function() doResume("手动测试", true) end,
  resumeState = resume,
  state = state,
  timers = timers,
  eventtap = eventtap,
  counters = function() return { key = keySeen, wx = wxKeySeen, tapDisabled = tapDisabledCount } end,
}
_G.WXGUARD = mod
return mod
