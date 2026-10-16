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
    emptyEndResume = true,  -- 空转写结束（无文字）也续上：靠麦克风占用释放来判定
    minSessionSec  = 1.0,   -- 语音会话短于此秒数不算数（防别的应用一闪而过）
  },

  -- ── 桌面悬浮球（hs.canvas 原生绘制：不额外起进程、不轮询）────────────────
  ball = {
    enabled = true,   -- 默认显示；⌥⌘B 隐藏/显示，显隐与位置都存盘
    size    = 56,     -- 直径（点）
  },
}

local LOG_FILE   = CONFIG.outDir .. "/capture.log"
local EVENT_FILE = CONFIG.outDir .. "/events.log"
local TREE_FILE  = CONFIG.outDir .. "/ax-tree.txt"
local STATE_FILE = CONFIG.outDir .. "/state.json"

local state = { intercept = CONFIG.interceptMode, history = {}, lastText = "", lastCaptureAt = 0 }
-- 悬浮球模块在后面才定义；capture()/开关函数通过这两个前向钩子通知它重绘
local ballFlash, ballRedraw = nil, nil
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
  if ballFlash then pcall(ballFlash) end   -- 悬浮球闪一下，给个"截到了"的反馈
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
  if ballRedraw then pcall(ballRedraw) end
end

--------------------------------------------------------------------------------
-- 第二个触发器：麦克风占用释放（覆盖"空的结束"）
--
-- 微信语音输入期间，默认输入设备一直处于「被占用」状态
-- （CoreAudio kAudioDevicePropertyDeviceIsRunningSomewhere）。它释放 = 会话结束。
-- 这样即使这次一个字都没识别出来（微信不会发任何事件），我们也能知道该续上。
--
-- 每 0.5s 读一次是**纯本地 CoreAudio 状态查询**，不与其他进程做 IPC，
-- 不会像 v1 的 AX 轮询那样拖慢输入。
--------------------------------------------------------------------------------

local mic = { on = nil, startedAt = 0, hadText = false, timer = nil, dev = nil, devTick = 0 }

-- 设备对象必须缓存：首次解析默认输入设备实测要 400+ms，主线程阻塞就是输入卡顿
local function micDevice(refresh)
  if refresh or not mic.dev then
    mic.dev = (hs.audiodevice and hs.audiodevice.defaultInputDevice)
      and hs.audiodevice.defaultInputDevice() or nil
  end
  return mic.dev
end

local function micTick()
  mic.devTick = mic.devTick + 1
  local dev = micDevice(mic.devTick % 60 == 1)   -- 约每 30s 重解析一次，平时只读状态
  if not dev then return end
  local inUse = dev:inUse()
  if inUse == nil then
    micDevice(true)
    return
  end
  if mic.on == nil then mic.on = inUse; return end       -- 首次只记基线
  if inUse == mic.on then return end

  mic.on = inUse
  local now = hs.timer.secondsSinceEpoch()
  if inUse then
    mic.startedAt, mic.hadText = now, false
    log("[mic] 输入设备开始被占用（语音会话开始）")
  else
    local dur = now - (mic.startedAt or now)
    log(string.format("[mic] 输入设备释放（会话 %.1fs，本次%s文本）", dur, mic.hadText and "有" or "无"))
    if resume.enabled and CONFIG.autoResume.emptyEndResume
       and not mic.hadText and dur >= CONFIG.autoResume.minSessionSec then
      if mic.timer then mic.timer:stop() end
      mic.timer = hs.timer.doAfter(CONFIG.autoResume.delay, function()
        if mic.hadText then
          log("[mic] 期间产生了文本，改由文本路径续上，跳过空转续上")
          return
        end
        doResume("空转写结束（无文字）")
      end)
    end
  end
end

--------------------------------------------------------------------------------
-- 微信注入事件到达后的重活，全部在这里做（已离开事件回调）
--------------------------------------------------------------------------------

local function handleInjection(s, code, flags, pid)
  -- 本次转写结束：hold 模式在这里松手，随后再按下一轮
  releaseHeld("转写结束")
  mic.hadText = true      -- 告诉麦克风路径：这次有文字，别重复续上

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
  if ballRedraw then pcall(ballRedraw) end
end

--------------------------------------------------------------------------------
-- 桌面悬浮球：⌥⌘B 显隐 / 左键点它切「自动续上」/ ⌥+左键切「拦截模式」/ 拖动挪位置
-- 纯 hs.canvas 绘制：没有额外进程、没有轮询、只在状态变化时重绘
--------------------------------------------------------------------------------

local BALL_FILE = CONFIG.outDir .. "/ball.state"
local ball = {
  canvas = nil, w = CONFIG.ball.size, h = CONFIG.ball.size,
  x = nil, y = nil, visible = CONFIG.ball.enabled,
  flashUntil = 0, flashTimer = nil, drag = nil, moved = false,
}

local function saveBallState()
  local f = io.open(BALL_FILE, "w")
  if not f then return end
  f:write(string.format("%s,%s,%s", tostring(ball.x or ""), tostring(ball.y or ""),
                        ball.visible and "1" or "0"))
  f:close()
end

local function loadBallState()
  local f = io.open(BALL_FILE, "r")
  if not f then return end
  local s = f:read("*a") or ""
  f:close()
  local x, y, vis = s:match("^([^,]*),([^,]*),(%d)")
  if tonumber(x) and tonumber(y) then ball.x, ball.y = tonumber(x), tonumber(y) end
  if vis then ball.visible = (vis == "1") end
end

local function ballDraw()
  local c = ball.canvas
  if not c then return end
  local on = resume and resume.enabled
  local flash = hs.timer.secondsSinceEpoch() < ball.flashUntil

  local fill
  if flash then
    fill = { red = 0.18, green = 0.84, blue = 1.00, alpha = 0.95 }   -- 刚截到文字
  elseif on then
    fill = { red = 0.16, green = 0.72, blue = 0.42, alpha = 0.90 }   -- 自动续上：开
  else
    fill = { red = 0.42, green = 0.43, blue = 0.47, alpha = 0.70 }   -- 关
  end
  local ring = state.intercept
    and { red = 1.00, green = 0.55, blue = 0.10, alpha = 0.95 }        -- 拦截模式：开
    or  { white = 1.0, alpha = 0.35 }

  pcall(function()
    c:replaceElements({
      -- 注意：不要在这里开 trackMouse*。元素级 + canvas 级两套鼠标事件会让同一次点击
      -- 被投递两遍，表现为"点一下翻转两次"（实测踩过）。只走 canvas 级。
      { type = "circle", action = "fill", fillColor = fill,
        center = { x = "50%", y = "50%" }, radius = "44%" },
      { type = "circle", action = "stroke", strokeColor = ring, strokeWidth = 2,
        center = { x = "50%", y = "50%" }, radius = "44%" },
      { type = "text", text = "续", textAlignment = "center",
        textSize = math.max(12, math.floor(ball.w * 0.40)),
        textColor = { white = 1.0, alpha = 0.95 },
        frame = { x = 0, y = math.floor(ball.h * 0.30), w = ball.w, h = ball.h } },
    })
  end)
end

ballRedraw = ballDraw

ballFlash = function()
  ball.flashUntil = hs.timer.secondsSinceEpoch() + 0.45
  ballDraw()
  if ball.flashTimer then ball.flashTimer:stop() end
  ball.flashTimer = hs.timer.doAfter(0.45, function() ballDraw() end)
end

-- 前向声明：ballMouse 要用到，但菜单那一节在后面才定义
local showBallMenu

-- 拖拽实现：不依赖 canvas 的 mouseMove 事件（实测根本收不到，导致拖不动）。
-- 改成按下时起一个 60Hz 的循环，自己读鼠标绝对位置来移动窗口；
-- 并用 hs.eventtap.checkMouseButtons() 兜底检测"按键已松开但 mouseUp 丢了"的情况。
local function finishDrag(reason, allowClick)
  if ball.dragTimer then
    pcall(function() ball.dragTimer:stop() end)
    ball.dragTimer = nil
  end
  local d = ball.drag
  ball.drag = nil
  if not d then return end

  local now = hs.timer.secondsSinceEpoch()
  local since = ball.lastUp and (now - ball.lastUp) or 999
  ball.lastUp = now
  log(string.format("[ball] %s：moved=%s 位移=%.0fpx 耗时=%.1fs 距上次=%.2fs%s",
      reason, tostring(d.moved), d.dist or 0, now - d.t0, since,
      (allowClick and not d.moved and since >= 0.6) and " → 判为点击" or ""))

  if allowClick and not d.moved and since >= 0.6 then
    -- 点击：⌥+点击 = 切拦截模式；普通点击 = 切自动续上
    local mods = hs.eventtap.checkKeyboardModifiers() or {}
    if mods.alt then toggleIntercept() else toggleAutoResume() end
  else
    if ball.canvas then
      local f = ball.canvas:frame()
      if f then ball.x, ball.y = f.x, f.y end
    end
    saveBallState()
  end
  ballDraw()
end

local function startDrag(canvas)
  local p = hs.mouse.absolutePosition()
  local f = canvas:frame() or { x = 0, y = 0, w = ball.w, h = ball.h }
  ball.drag = {
    start = p, t0 = hs.timer.secondsSinceEpoch(), moved = false, dist = 0,
    offset = { x = p.x - f.x, y = p.y - f.y },   -- 抓取点偏移，拖动时手感自然
  }
  if ball.dragTimer then pcall(function() ball.dragTimer:stop() end) end
  ball.dragTimer = hs.timer.new(1 / 60, function()
    local d = ball.drag
    if not d then return end
    local cur = hs.mouse.absolutePosition()
    local dx, dy = cur.x - d.start.x, cur.y - d.start.y
    d.dist = math.abs(dx) + math.abs(dy)
    if d.dist > 3 then d.moved = true end
    pcall(function()
      canvas:frame({ x = cur.x - d.offset.x, y = cur.y - d.offset.y, w = ball.w, h = ball.h })
    end)

    -- 兜底一：按键全松开了（可能漏掉 mouseUp，比如拖太快甩出球外）
    local btns = hs.eventtap.checkMouseButtons() or {}
    local any = false
    for _, v in pairs(btns) do if v then any = true; break end end
    if not any then finishDrag("按键已松开（mouseUp 未送达）", false); return end
    -- 兜底二：拖太久（异常情况），别让它一直黏着鼠标
    if hs.timer.secondsSinceEpoch() - d.t0 > 30 then finishDrag("拖拽超时", false) end
  end)
  ball.dragTimer:start()
end

local function ballMouse(canvas, msg)
  if msg == "mouseDown" then
    -- canvas 不区分左右键，必须自己问：right 是 checkMouseButtons 提供的哈希键
    local btns = hs.eventtap.checkMouseButtons() or {}
    if btns.right then
      ball.rightClick = true
      ball.drag = nil
      if ball.dragTimer then pcall(function() ball.dragTimer:stop() end); ball.dragTimer = nil end
      return false
    end
    ball.rightClick = nil
    startDrag(canvas)
  elseif msg == "mouseUp" then
    if ball.rightClick then
      ball.rightClick = nil
      -- 不要在鼠标回调里做菜单跟踪，延后一拍
      hs.timer.doAfter(0, function() pcall(showBallMenu) end)
      return false
    end
    finishDrag("mouseUp", true)
  end
  return false
end

local function ballCreate()
  if ball.canvas then return end
  -- 注意：不要在这里 loadBallState()。那样读盘发生在"是否显示"的判断之后，
  -- 结果是"上次明明隐藏了、这次照样建出来并显示"（实测踩过）。
  -- 状态必须在 ballApply 判断之前就读好。
  local scr = hs.screen.mainScreen():frame()
  local x = ball.x or (scr.x + scr.w - ball.w - 24)
  local y = ball.y or (scr.y + math.floor(scr.h * 0.35))
  local c = hs.canvas.new({ x = x, y = y, w = ball.w, h = ball.h })
  c:level(hs.canvas.windowLevels.floating)
  pcall(function() c:behaviorAsLabels({ "canJoinAllSpaces", "stationary" }) end)
  c:clickActivating(false)        -- 点它不抢焦点（否则会把你的输入框弄失焦）
  -- 只接 down/up（拖动时再临时打开 move 跟踪），避免无谓的鼠标移动回调
  pcall(function() c:canvasMouseEvents(true, true, false, false) end)
  c:mouseCallback(ballMouse)
  ball.canvas = c
  ballDraw()
  c:show()
  log("[ball] 悬浮球已创建 " .. ball.w .. "px @ (" .. x .. "," .. y .. ") 显示=" .. tostring(ball.visible))
end

local function ballApply()
  if ball.visible then
    ballCreate()
    if ball.canvas then ball.canvas:show() end
  elseif ball.canvas then
    ball.canvas:hide()
  end
  ballDraw()
  saveBallState()
end

local function ballToggleVisible()
  ball.visible = not ball.visible
  ballApply()
  log("[ball] 显示 = " .. tostring(ball.visible))
  notify("Voice Guard", ball.visible and "悬浮球：显示" or "悬浮球：已隐藏（⌥⌘B 唤回）")
end

--------------------------------------------------------------------------------
-- 悬浮球右键菜单
--
-- 用原生 NSMenu 而不是自己在 canvas 上画菜单：hs.menubar.new(false) 建一个不在
-- 菜单栏里显示的对象，再用 popupMenu(point) 在指定坐标弹出——勾选态、分隔线、
-- 键盘导航都是系统给的。（canvas 的鼠标事件不区分左右键，所以右键靠
-- hs.eventtap.checkMouseButtons() 的 right 哈希键判断。）
--------------------------------------------------------------------------------

local ballMenu = nil

local function quitService()
  log("[menu] 从悬浮球菜单退出服务")
  notify("Voice Guard", "正在退出服务…")
  local pid = hs.processInfo and hs.processInfo.processID
  local app = hs.application.get("Hammerspoon") or (pid and hs.application.get(pid))
  if app then
    hs.timer.doAfter(0.3, function() app:kill() end)   -- 让通知先出去
  else
    hs.timer.doAfter(0.3, function() os.exit(0) end)   -- 兜底
  end
end

local function buildBallMenu()
  if not ballMenu then
    ballMenu = hs.menubar.new(false)     -- false = 不占用系统菜单栏
  end
  if not ballMenu then return nil end
  ballMenu:setMenu({
    { title = "自动续上", checked = (resume and resume.enabled) or false, fn = toggleAutoResume },
    { title = "拦截模式", checked = state.intercept, fn = toggleIntercept },
    { title = "-" },
    { title = "打开捕获日志", fn = function() hs.open(LOG_FILE) end },
    { title = "打开抢救箱", fn = function() hs.open(CONFIG.outDir .. "/clipboard-rescue") end },
    { title = "-" },
    { title = "隐藏悬浮球（⌥⌘B 唤回）", fn = ballToggleVisible },
    { title = "退出服务（停止 Hammerspoon）", fn = quitService },
  })
  return ballMenu
end

-- 注意：这里不能写 local，否则 ballMouse 里引用的是那个前向声明的空值
function showBallMenu()
  local m = buildBallMenu()
  if not m then
    log("[menu] 无法创建菜单对象")
    return
  end
  -- 菜单位置：鼠标当前所在的屏幕坐标
  local pt = hs.mouse.absolutePosition()
  local ok, err = pcall(function() m:popupMenu(pt) end)
  if not ok then
    -- 某些版本只接受 hs.geometry 点表，或者干脆无参
    ok = pcall(function() m:popupMenu(hs.geometry.point(pt.x, pt.y)) end)
    if not ok then
      log("[menu] popupMenu(point) 失败：" .. tostring(err) .. "，退回无参形式")
      pcall(function() m:popupMenu() end)
    end
  end
end

--------------------------------------------------------------------------------
-- 启动
--------------------------------------------------------------------------------

hs.hotkey.bind({ "alt", "cmd" }, "c", copyLast)
hs.hotkey.bind({ "alt", "cmd" }, "v", snapshotFocused)
hs.hotkey.bind({ "alt", "cmd" }, "i", toggleIntercept)
hs.hotkey.bind({ "alt", "cmd" }, "s", toggleAutoResume)                        -- 自动续上开关
hs.hotkey.bind({ "alt", "cmd" }, "t", function() doResume("手动测试", true) end) -- 手动试一次键位
hs.hotkey.bind({ "alt", "cmd" }, "b", ballToggleVisible)                       -- 悬浮球显隐
hs.hotkey.bind({ "alt", "cmd" }, "m", function() pcall(showBallMenu) end)      -- 保底：在鼠标处弹同一菜单
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

-- 右键菜单：先构建一次验证通路（不弹出），弹出只在右键时发生
do
  local okM, m = pcall(buildBallMenu)
  if okM and m then log("[menu] 右键菜单已就绪（自动续上 / 拦截模式 / 日志 / 抢救箱 / 隐藏球 / 退出服务）")
  else log("[menu] 构建失败：" .. tostring(m)) end
end

-- 悬浮球：必须先读盘再判断显隐，否则"上次隐藏了"会被无视
do
  pcall(loadBallState)
  local okBall, errBall = pcall(ballApply)
  if not okBall then log("[ball] 创建失败：" .. tostring(errBall)) end
  log("[ball] 显隐状态已恢复：显示=" .. tostring(ball.visible))
end

-- 麦克风设备预热：首次解析要 400+ms，放在启动阶段吃掉，别让它落在输入路径上
pcall(function() withPerf("micDevice:预热", micDevice, true) end)

local okTap, errTap = pcall(startEventTap)
if not okTap then log("[tap] 启动失败：" .. tostring(errTap)) end

lastPBChange = hs.pasteboard.changeCount()

-- 定时器必须挂全局强引用：只放局部变量里会被 GC 回收，定时器静默停摆
local timers = {}
timers.pid = hs.timer.doEvery(CONFIG.pidRefresh, function() withPerf("refreshWeChatPIDs", refreshWeChatPIDs) end)
timers.pb  = hs.timer.doEvery(CONFIG.pbPoll, function() withPerf("pollPasteboard", pollPasteboard, "pasteboard") end)
timers.mic = hs.timer.doEvery(0.5, function() withPerf("micTick", micTick) end)

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
  mic = mic,
  ball = ball,
  ballToggleVisible = ballToggleVisible,
  ballApply = ballApply,
  state = state,
  timers = timers,
  eventtap = eventtap,
  counters = function() return { key = keySeen, wx = wxKeySeen, tapDisabled = tapDisabledCount } end,
}
_G.WXGUARD = mod
return mod
