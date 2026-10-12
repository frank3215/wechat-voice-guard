--[[
  WeChat Voice Guard — 微信语音输入保险箱
  ---------------------------------------------------------------
  背景：微信电脑版 4.1.8+ 的「语音输入」= 按住 fn 的全局听写，识别结果会跨应用上屏。
        实测行为：焦点在文本框 → 直接进去；不在文本框 → 提示「输入失败」。
        待验证假设：微信可能"先尝试写入、失败才报错"，那样 L1 在失败路径上也有信号。

  三层拦截：
    L1  CGEventTap  —— 微信合成的键盘事件。若"先试后报错"成立，失败时也能抓到。
    L2  AX Observer + 轮询 —— 主力：直接读微信浮窗 / 输入框 / 焦点元素的 AX 文本，
                        即使微信报「输入失败」，文字没上屏，也能救下来。
    L3  屏幕 OCR     —— 未实装；靠 ⌃⌥⌘D 的 dump 与 events.log 判断是否需要。

  日志：
    capture.log  只记捕获到的正文（每行：时间 来源 文本）
    events.log   记微信发的每一个键盘事件 + 当时的焦点元素（判定"先试后报错"的关键证据）
    ax-tree.txt  微信全家桶 AX 树快照
    state.json   最近 300 条历史

  热键：
    ⌥⌘V   手动快照当前焦点输入框文字
    ⌥⌘I   切换"拦截模式"：开 = 吞掉微信合成事件（文字只进剪贴板，不上屏）
    ⌥⌘C   复制上一条捕获
    ⌥⌘R   立刻重扫并重挂 AX 监听
    ⌃⌥⌘D  诊断 dump
    ⌥⌘L   打开捕获日志
--]]

local CONFIG = {
  bundleID      = "com.tencent.xinWeChat",
  -- 注意：macOS 15 下 ~/Downloads、~/Desktop、~/Documents 受 TCC 保护，
  -- Hammerspoon 直接往里写会被静默拒绝，所以日志放 ~/Library/Logs
  outDir        = os.getenv("HOME") .. "/Library/Logs/WeChatVoiceGuard",
  interceptMode = false,   -- 是否默认吞掉微信的上屏事件
  minLength     = 1,       -- 短于此长度的文本不记录（1 = 连单字也留，宁可吵也别丢）
  mergeWindow   = 5.0,     -- 同一会话判定窗口（秒）：只有这个窗口内才做流式合并/去重
  autoClipboard = true,    -- 每次捕获都刷进剪贴板
  notify        = true,
  pollInterval  = 0.8,     -- AX 轮询间隔（秒）
  pbPollInterval = 0.1,    -- 剪贴板轮询间隔（秒）：微信会很快还原剪贴板，必须抢得快
  followUpDelays = { 0.05, 0.12, 0.3, 0.6, 1.2 },  -- 微信事件后追读剪贴板的时点（秒）
  mainEveryN    = 6,       -- 主聊天窗口每 N 次轮询扫一次，降低 AX 开销
  maxDepthPanel = 12,
  maxDepthMain  = 8,
  axHotWindow   = 8.0,     -- 语音会话结束后 N 秒内视为"热"，采信剪贴板/焦点写入
  panelWarnGap  = 30,      -- 面板无文本告警的最小间隔（秒）
}

local LOG_FILE   = CONFIG.outDir .. "/capture.log"
local EVENT_FILE = CONFIG.outDir .. "/events.log"
local TREE_FILE  = CONFIG.outDir .. "/ax-tree.txt"
local STATE_FILE = CONFIG.outDir .. "/state.json"

local state = { intercept = CONFIG.interceptMode, history = {}, lastText = "" }
local lastWxEventAt = 0     -- 微信上一次发键盘事件的时间
local voiceHotAt    = 0     -- 语音面板最近一次出现的时间
local lastWarnAt    = 0

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

local pidCache, pidCacheAt = nil, 0
local function wechatPIDs(force)
  local now = hs.timer.secondsSinceEpoch()
  if pidCache and not force and (now - pidCacheAt) < 5 then return pidCache end
  local set = {}
  for _, a in ipairs(hs.application.runningApplications() or {}) do
    local bid = a:bundleID() or ""
    local nm  = a:name() or ""
    if bid == CONFIG.bundleID or bid:find("^com%.tencent%.xinWeChat")
       or nm:find("WeChat") or nm:find("微信") then
      set[a:pid()] = true
    end
  end
  pidCache, pidCacheAt = set, now
  return set
end

--------------------------------------------------------------------------------
-- 捕获（流式中间结果按"前缀增长"合并，不刷屏）
--------------------------------------------------------------------------------

local function capture(text, source)
  if type(text) ~= "string" then return end
  text = text:gsub("^%s+", ""):gsub("%s+$", "")
  if #text < CONFIG.minLength then return end

  local nowEp = hs.timer.secondsSinceEpoch()
  local sameSession = (nowEp - (state.lastCaptureAt or 0)) <= CONFIG.mergeWindow
  -- 同一会话内的重复才丢；隔了很久的一句同样的话（比如你接连两次说"在某种意义上讲"）
  -- 必须算新的一条，不能被去重吃掉
  if text == state.lastText and sameSession then return end

  local now = os.date("%Y-%m-%d %H:%M:%S")
  local head = state.history[1]
  local merged = false
  -- 只在同一会话（默认 5 秒内）做前缀增长合并；
  -- 否则"短的整句恰好是上一条的前缀"时会被并进上一条、且因更短而不留痕迹
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
  -- 剪贴板来源的内容本来就在剪贴板上，别回写：否则会和微信后续的流式更新抢剪贴板
  if CONFIG.autoClipboard and source:sub(1, 9) ~= "clipboard" then
    hs.pasteboard.setContents(text)
  end
  log(string.format("[%s]%s %s", source, merged and " (合并)" or "", text:gsub("\n", "\\n")))
  persist()
  notify("语音已截获 (" .. source .. ")", text:sub(1, 120))
end

--------------------------------------------------------------------------------
-- 剪贴板快照（核心救援手段）
-- 微信上屏 = 写剪贴板 + 模拟 ⌘V；粘贴失败后它会很快把剪贴板还原。
-- 所以必须在"微信动作的那一瞬"同步抢读，晚一步就只能读到被还原的旧内容。
--------------------------------------------------------------------------------

local lastPBChange = 0

local function pollPasteboard(source, force)
  local cc = hs.pasteboard.changeCount()
  if cc == lastPBChange then return nil end
  lastPBChange = cc
  local v = hs.pasteboard.getContents()
  if type(v) ~= "string" or #v < CONFIG.minLength then return nil end
  local now = hs.timer.secondsSinceEpoch()
  local hot = force or (now - voiceHotAt) <= CONFIG.axHotWindow
                      or (now - lastWxEventAt) <= CONFIG.axHotWindow
  if not hot then return nil end
  capture(v, source)
  lastPBChange = hs.pasteboard.changeCount()   -- capture() 可能回写过剪贴板
  return v
end

--------------------------------------------------------------------------------
-- AX 辅助
--------------------------------------------------------------------------------

local function str(v)
  if type(v) == "string" then return v end
  return nil
end

local function walk(root, depth, maxDepth, acc)
  if not root or depth > maxDepth then return acc end
  acc[#acc + 1] = { el = root, depth = depth }
  local ok, kids = pcall(function() return root:attributeValue("AXChildren") end)
  if ok and type(kids) == "table" then
    for _, c in ipairs(kids) do walk(c, depth + 1, maxDepth, acc) end
  end
  return acc
end

local function sizeOf(el)
  local s = el:attributeValue("AXSize")
  if type(s) ~= "table" then return nil, nil end
  return (s.w or s.width or s[1]), (s.h or s.height or s[2])
end

-- 当前焦点元素：返回 el, role, title
local function focusedInfo()
  local ok, el = pcall(function()
    local sys = hs.axuielement.systemWideElement()
    return sys and sys:attributeValue("AXFocusedUIElement")
  end)
  if not ok or not el then return nil end
  local ok2, role = pcall(function() return str(el:attributeValue("AXRole")) or "?" end)
  local ok3, title = pcall(function() return str(el:attributeValue("AXTitle")) or "" end)
  if not ok2 then return nil end
  return el, role, (ok3 and title) or ""
end

local function describe(el)
  local role = str(el:attributeValue("AXRole")) or "?"
  local sub  = str(el:attributeValue("AXSubrole")) or ""
  local ttl  = str(el:attributeValue("AXTitle")) or ""
  local val  = str(el:attributeValue("AXValue")) or ""
  local w, h = sizeOf(el)
  local dim  = (w and h) and string.format(" (%dx%d)", w, h) or ""
  return string.format("%s/%s%s | title=%s | value=%s", role, sub, dim,
    ttl:sub(1, 60), val:gsub("\n", "\\n"):sub(1, 200))
end

local MAIN_TITLES = { ["微信"] = true, ["WeChat"] = true, ["Weixin"] = true }
-- 主聊天窗口：标题匹配且尺寸较大（语音浮窗通常又小又没标题）
local function isMainWindow(w)
  local t = str(w:attributeValue("AXTitle")) or ""
  if not MAIN_TITLES[t] then return false end
  local wd, ht = sizeOf(w)
  if not wd or not ht then return true end
  return wd >= 700 and ht >= 400
end

local function isTextRole(role) return role:find("Text") ~= nil end

--------------------------------------------------------------------------------
-- L2-a: 轮询（不依赖微信是否发 AX 通知）
--------------------------------------------------------------------------------

-- 扫某个进程：wantMain=true 只扫主聊天窗口，false 只扫非主窗口（浮窗/面板）
local function scanProcess(pid, wantMain)
  local appEl = hs.axuielement.applicationElementForPID(pid)
  if not appEl then return 0, nil, nil end
  local wins = appEl:attributeValue("AXWindows")
  if type(wins) ~= "table" then return 0, nil, nil end
  local hits, panelWins, panelTexts = 0, 0, 0
  for _, w in ipairs(wins) do
    local main = isMainWindow(w)
    if main == wantMain then
      if not main then panelWins = panelWins + 1 end
      local acc = walk(w, 0, main and CONFIG.maxDepthMain or CONFIG.maxDepthPanel, {})
      for _, item in ipairs(acc) do
        local el = item.el
        local role = str(el:attributeValue("AXRole")) or ""
        if isTextRole(role) then
          -- 主窗口只取输入框，避免聊天记录刷屏
          if (not main) or role == "AXTextArea" or role == "AXTextField" then
            local v = str(el:attributeValue("AXValue"))
            if v and #v >= CONFIG.minLength then
              capture(v, main and "poll:inputbox" or "poll:panel")
              hits = hits + 1
              if not main then panelTexts = panelTexts + 1 end
            end
          end
        end
      end
    end
  end
  if not wantMain and panelWins > 0 then
    voiceHotAt = hs.timer.secondsSinceEpoch()   -- 语音面板在，会话是"热"的
  end
  return hits, panelTexts, panelWins
end

-- 焦点元素被写入（微信走 AX 直接设值这条路时，能在这里看到）
local function pollFocused()
  local el, role = focusedInfo()
  if not el then return end
  local v = str(el:attributeValue("AXValue"))
  if not v or #v < CONFIG.minLength then return end
  local now = hs.timer.secondsSinceEpoch()
  -- 只在"微信刚有动作"的窗口内采信，避免把用户手打内容记进历史
  if (now - voiceHotAt) <= CONFIG.axHotWindow or (now - lastWxEventAt) <= CONFIG.axHotWindow then
    capture(v, "poll:focused")
  end
end

local tick = 0
local function poll(_, force)
  tick = tick + 1
  local doMain = force or (tick % CONFIG.mainEveryN == 1)
  local anyPanel, anyPanelText = false, false
  for pid in pairs(wechatPIDs()) do
    local ok, _, pt, pw = pcall(scanProcess, pid, false)
    if ok and pw and pw > 0 then
      anyPanel = true
      if pt and pt > 0 then anyPanelText = true end
    end
    if doMain then pcall(scanProcess, pid, true) end
  end
  pcall(pollFocused)
  -- 有浮窗但读不到任何文本 → AX 可能不暴露浮窗文本，需要 L3 OCR
  local now = hs.timer.secondsSinceEpoch()
  if anyPanel and not anyPanelText and (now - lastWarnAt) > CONFIG.panelWarnGap then
    lastWarnAt = now
    log("[panel] 检测到微信非主窗口，但未读到文本元素 → AX 可能不暴露浮窗内容")
  end
end

--------------------------------------------------------------------------------
-- L2-b: AX 通知监听
--------------------------------------------------------------------------------

local observers = {}
local dumpTree          -- 前向声明：registerWatchers 的回调里要用到
local function registerWatchers(verbose)
  wechatPIDs(true)
  for _, o in pairs(observers) do pcall(function() o:stop() end) end
  observers = {}
  local added = 0

  for pid in pairs(wechatPIDs()) do
    local ok = pcall(function()
      local appEl = hs.axuielement.applicationElementForPID(pid)
      if not appEl then return end
      local obs = hs.axuielement.observer.new(pid)
      obs:callback(function(_, el, notification)
        if notification == "AXValueChanged" then
          local v = str(el:attributeValue("AXValue"))
          if v then capture(v, "ax:" .. (str(el:attributeValue("AXRole")) or "?")) end
        elseif notification == "AXWindowCreated" then
          voiceHotAt = hs.timer.secondsSinceEpoch()
          local okD, d = pcall(describe, el)
          log("[ax] 新窗口出现 " .. (okD and d or "?") .. " → 重挂监听 + 自动 dump")
          hs.timer.doAfter(0.5, function() poll(nil, true) end)
          hs.timer.doAfter(0.8, function() dumpTree("新窗口") end)
          hs.timer.doAfter(1.5, function() registerWatchers(false) end)
        end
      end)
      pcall(function() obs:addWatcher(appEl, "AXWindowCreated") end)

      local acc = walk(appEl, 0, CONFIG.maxDepthPanel, {})
      for _, item in ipairs(acc) do
        local el = item.el
        local role = str(el:attributeValue("AXRole")) or ""
        if isTextRole(role) or el:attributeValue("AXValue") ~= nil then
          if pcall(function() obs:addWatcher(el, "AXValueChanged") end) then added = added + 1 end
        end
      end
      pcall(function() obs:start() end)
      observers[#observers + 1] = obs
    end)
    if not ok then log("[ax] pid=" .. tostring(pid) .. " 挂监听失败（多半是缺辅助功能权限）") end
  end
  if verbose then log("[ax] 重挂监听，元素 " .. added .. " 个") end
  return added
end

--------------------------------------------------------------------------------
-- 诊断 dump
--------------------------------------------------------------------------------

function dumpTree(reason)
  local f = io.open(TREE_FILE, "w")
  if not f then return end
  f:write("# WeChat AX tree @ " .. os.date("%Y-%m-%d %H:%M:%S") ..
          "  reason=" .. tostring(reason or "manual") .. "\n")
  f:write("# AX permission(hs.accessibilityState)=" ..
          tostring(select(2, pcall(function() return hs.accessibilityState(false) end))) .. "\n")
  local pids = wechatPIDs(true)
  if next(pids) == nil then f:write("\n<微信没在运行>\n") end
  for pid in pairs(pids) do
    local appEl = hs.axuielement.applicationElementForPID(pid)
    f:write("\n## pid=" .. pid .. "\n")
    if not appEl then
      f:write("   <取不到 AX 元素：缺辅助功能权限，或进程已退出>\n")
    else
      local wins = appEl:attributeValue("AXWindows")
      f:write("   windows=" .. (type(wins) == "table" and #wins or 0) .. "\n")
      for _, item in ipairs(walk(appEl, 0, CONFIG.maxDepthPanel, {})) do
        f:write(string.rep("  ", item.depth) .. describe(item.el) .. "\n")
      end
    end
  end
  local focused = focusedInfo()
  if focused then f:write("\n# Focused: " .. describe(focused) .. "\n") end
  f:close()
  log("[dump] 已写出 " .. TREE_FILE .. " (reason=" .. tostring(reason or "manual") .. ")")
  if reason == "manual" then notify("Voice Guard", "AX 树已写出") end
end

--------------------------------------------------------------------------------
-- L1: CGEventTap
--------------------------------------------------------------------------------

local eventtap
local keySeen = 0          -- 任意来源的 keyDown 计数（用于判断输入监控是否授权）
local wxKeySeen = 0        -- 微信来源的 keyDown 计数
local function startEventTap()
  if eventtap then eventtap:stop() end
  eventtap = hs.eventtap.new({ hs.eventtap.event.types.keyDown }, function(e)
    keySeen = keySeen + 1
    local pid = e:getProperty(hs.eventtap.event.properties.eventSourceUnixProcessID)
    if not pid or not wechatPIDs()[pid] then return false end

    wxKeySeen = wxKeySeen + 1
    lastWxEventAt = hs.timer.secondsSinceEpoch()

    -- 最高优先级：微信动作的瞬间同步抢读剪贴板（它可能马上还原成旧内容）
    -- ⌘V 是异步投递的，"写剪贴板"可能发生在我们收到事件之后，所以事件后还要追读几次
    pcall(function()
      local v = pollPasteboard("pasteboard:动作瞬间", true)
      if v then log("[pb] 已在微信动作瞬间抢到 " .. #v .. " 字") end
      for _, d in ipairs(CONFIG.followUpDelays) do
        hs.timer.doAfter(d, function()
          local got = pollPasteboard("pasteboard:事后" .. d .. "s", true)
          if got then log("[pb] 事后 " .. d .. "s 抢到 " .. #got .. " 字") end
        end)
      end
    end)

    local s = e:getUnicodeString()
    local code = e:getKeyCode()
    local flags = e:getFlags() or {}

    -- 诊断日志必须最先写、且全程容错：
    -- 之前 focusedInfo() 返回 nil 时 ftitle:sub() 抛错，整行日志连带后面的捕获一起被吞掉，
    -- 表现就是"微信来源计数涨了但 events.log 不存在"。
    pcall(function()
      local names = {}
      for k in pairs(flags) do names[#names + 1] = k end
      table.sort(names)
      local frole, ftitle = "?", ""
      local _, r, t = focusedInfo()
      if r then frole, ftitle = r, (t or "") end
      local app = hs.application.applicationForPID(pid)
      logEvent(string.format("pid=%s(%s) keycode=%s flags=[%s] unicode=%s focused=%s|%s",
        tostring(pid), (app and app:name()) or "?",
        tostring(code), table.concat(names, ","),
        (type(s) == "string" and s ~= "") and ("'" .. s:gsub("\n", "\\n") .. "'") or "<空>",
        tostring(frole), tostring(ftitle):sub(1, 40)))
    end)

    -- 微信模拟 ⌘V 上屏：文字此刻在剪贴板里，先抄下来（失败时它就一直留在剪贴板）
    if flags.cmd and code == 9 then
      local cb = hs.pasteboard.getContents()
      if type(cb) == "string" then capture(cb, "clipboard:⌘V") end
    end

    if type(s) == "string" and s ~= "" then
      capture(s, "eventtap")
      return state.intercept          -- true = 吞掉，文字不进任何输入框
    end
    return false
  end)
  eventtap:start()
  local ok = pcall(function() return eventtap:isEnabled() end)
  log("[tap] CGEventTap isEnabled=" .. tostring(ok) ..
      "（false/报错 = 缺输入监控权限或被辅助功能挡下）intercept=" .. tostring(state.intercept))
end

--------------------------------------------------------------------------------
-- L1b: 剪贴板监听（微信若靠"写剪贴板 + 模拟 ⌘V"上屏，失败时文字仍留在这里）
--------------------------------------------------------------------------------

local pbWatcher
local function startPasteboardWatcher()
  pcall(function() hs.pasteboard.watcher.interval(CONFIG.pbPollInterval) end)
  pbWatcher = hs.pasteboard.watcher.new(function(v)
    -- 这里只当兜底：真正可靠的是 pollPasteboard 的 changeCount 轮询
    pcall(pollPasteboard, "pasteboard")
  end)
  pbWatcher:start()
  log("[pb] 剪贴板监听已启动（间隔 " .. CONFIG.pbPollInterval .. "s）")
end

--------------------------------------------------------------------------------
-- 手动操作
--------------------------------------------------------------------------------

local function snapshotFocused()
  local el = focusedInfo()
  if not el then notify("Voice Guard", "拿不到焦点元素") return end
  capture(str(el:attributeValue("AXValue")) or "", "snapshot")
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

hs.hotkey.bind({ "alt", "cmd" }, "v", snapshotFocused)
hs.hotkey.bind({ "alt", "cmd" }, "i", toggleIntercept)
hs.hotkey.bind({ "alt", "cmd" }, "c", copyLast)
hs.hotkey.bind({ "alt", "cmd" }, "r", function() registerWatchers(true); poll(nil, true) end)
hs.hotkey.bind({ "ctrl", "alt", "cmd" }, "d", function() dumpTree("manual") end)
hs.hotkey.bind({ "alt", "cmd" }, "l", function() hs.open(LOG_FILE) end)

log("=== WeChat Voice Guard 启动 ===")
local okPerm, axState = pcall(function() return hs.accessibilityState(false) end)
log("[perm] 辅助功能(Accessibility) = " ..
    (okPerm and tostring(axState) or "无法检测") .. "（false = 未授权，L2 会失效）")

local okTap, errTap = pcall(startEventTap)
if not okTap then log("[tap] 启动失败：" .. tostring(errTap)) end

local okPb, errPb = pcall(startPasteboardWatcher)
if not okPb then log("[pb] 启动失败：" .. tostring(errPb)) end

local okW, errW = pcall(registerWatchers, true)
if not okW then log("[ax] 启动失败：" .. tostring(errW)) end

-- 定时器必须存进表里持有引用：不持有时会被 Lua GC 回收，定时器静默停摆（已实测）
local timers = {}
lastPBChange = hs.pasteboard.changeCount()
timers.poll      = hs.timer.doEvery(CONFIG.pollInterval, poll)
timers.pbFast    = hs.timer.doEvery(CONFIG.pbPollInterval, function()
  pcall(pollPasteboard, "pasteboard")
end)
timers.reregister = hs.timer.doEvery(10, function() pcall(registerWatchers, false) end)
timers.dumpFirst = hs.timer.doAfter(3, function() pcall(dumpTree, "启动") end)
timers.dumpEvery = hs.timer.doEvery(120, function() pcall(dumpTree, "定时") end)

-- 自检心跳：能收到键盘事件 = 输入监控已授权
local lastKeySeen, lastWxSeen = 0, 0
timers.heartbeat = hs.timer.doEvery(60, function()
  local d = keySeen - lastKeySeen
  local w = wxKeySeen - lastWxSeen
  lastKeySeen, lastWxSeen = keySeen, wxKeySeen
  log(string.format("[hb] 近60秒键盘事件=%d（>0 说明输入监控已授权；=0 去勾选输入监控）微信来源=%d", d, w))
end)

log("[hint] 若 events.log 一直为空：去 系统设置→隐私与安全性→输入监控 勾选 Hammerspoon")
log("[hint] 若 ax-tree.txt 里全是 <取不到 AX 元素>：去 辅助功能 里勾选 Hammerspoon，然后 ⌥⌘R")
notify("Voice Guard", "已启动：⌥⌘V 快照 / ⌥⌘I 拦截 / ⌃⌥⌘D 诊断")

-- 关键：这些对象必须挂在全局强引用上。
-- 只放在局部变量里的话，init.lua 这个 chunk 执行完毕后就不可达了，
-- hs.timer 的定时器会被 Lua GC 回收并静默停摆（实测：启动 3 秒后所有定时器全哑）。
local mod = {
  dump = dumpTree,
  poll = function() return poll(nil, true) end,
  snapshot = snapshotFocused,
  toggle = toggleIntercept,
  refresh = function() return registerWatchers(true) end,
  state = state,
  timers = timers,
  eventtap = eventtap,
  pbWatcher = pbWatcher,
  getObservers = function() return observers end,
}
_G.WXGUARD = mod
return mod
