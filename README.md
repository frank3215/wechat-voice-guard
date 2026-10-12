# WeChat Voice Guard · 微信语音输入防丢字

**在微信电脑版「语音输入」报「输入失败」、识别结果即将消失的那一刻，把文字截下来。**

macOS + [Hammerspoon](https://www.hammerspoon.org/)。适用于微信 4.1.8+ 的「按住 `fn` 说话」全局语音输入。

> Intercept the speech-to-text result that WeChat for Mac throws away when its voice input
> fails to insert (you weren't focused on a text field) — so you never lose the transcription.
> Implemented with a `CGEventTap` in Hammerspoon. macOS only.

---

## 问题

微信电脑版 4.1.8+ 的「语音输入」是一个**全局听写**：按住 `fn` 说话，识别结果上屏到当前焦点输入框
（[官方说明](https://www.ithome.com/0/930/754.htm)）。但如果你说话时没把光标放在输入框里，
它会提示「**输入失败**」，那段识别结果就随浮窗一起消失了——而长时间静音时它会**自动停止**，
根本来不及点回输入框。

## 已实测确认的机制

微信并不是「先检查焦点、失败就放弃」，而是**先把整段识别结果合成一个键盘事件发出去，之后才报错**。

`events.log` 实证（文字已打码）：

```
19:26:12  pid=2985(微信) keycode=0 flags=[] unicode='<整段识别结果，实测 636 字>' focused=?|
19:28:58  pid=2985(微信) keycode=0 flags=[] unicode='在某种意义上讲'            focused=?|
```

- `keycode=0` + 整段文字作为 unicode 串 = `CGEventKeyboardSetUnicodeString` 的标准用法
- `focused=?` = 当时**没有**任何焦点输入框（正是「输入失败」的场景）
- **事件照样发出** ⇒ 外部可以在它被丢弃之前截获，一个字都不会丢

这推翻了先前的假设（原以为它会走「写剪贴板 + 模拟 ⌘V」，实测 `flags=[]`，没有任何 ⌘V）。
它也解释了为什么失败时剪贴板里有时能捞到内容：微信会**顺带**写一次剪贴板，并很快还原。

## 它给你什么

每次语音输入，**不论上屏成功还是失败**：

- 全文写入 `~/Library/Logs/WeChatVoiceGuard/capture.log`（追加流水，永不丢）
- 最近 300 条存入同目录 `state.json`
- **最新一条自动放进剪贴板** ⇒ 失败时直接 `⌘V` 就能补上
- 系统通知提示已截获

## 安装

```bash
brew install --cask hammerspoon --appdir="$HOME/Applications"
git clone https://github.com/frank3215/wechat-voice-guard.git
cd wechat-voice-guard
./deploy.sh
```

`deploy.sh` 会把 `init.lua` 复制到 `~/.hammerspoon/init.lua` 并重启 Hammerspoon。

然后：**系统设置 → 隐私与安全性 → 辅助功能 → 勾选 Hammerspoon**。

> 实测**不需要**「输入监控」权限——有辅助功能权限，`CGEventTap` 就能收到键盘事件。
> 验证方式见下面的自检（`键盘事件>0` 即为生效）。

## 热键

| 热键 | 作用 |
|---|---|
| `⌥⌘C` | 复制上一条被捕获的文字 |
| `⌥⌘V` | 手动快照当前焦点输入框的文字 |
| `⌥⌘I` | 切换拦截模式：开 = 吞掉微信的注入事件（文字只进剪贴板，不上屏） |
| `⌥⌘R` | 立刻重扫并重挂 AX 监听 |
| `⌃⌥⌘D` | dump 微信 AX 元素树（诊断用） |
| `⌥⌘L` | 打开捕获日志 |

## 自检

```bash
grep -E "\[hb\]|\[tap\]|\[pb\]" ~/Library/Logs/WeChatVoiceGuard/capture.log
```

| 输出 | 含义 |
|---|---|
| `[tap] CGEventTap isEnabled=true` | 事件钩子已创建 |
| `[hb] 近60秒键盘事件=N`（N>0） | 钩子确实在收键盘事件（权限 OK） |
| `[hb] … 微信来源=N` | 微信注入过 N 次 |
| `[pb] 已在微信动作瞬间抢到 N 字` | 剪贴板兜底也抓到了 |

## 设计要点 · 踩过的坑（改代码前务必读）

1. **Hammerspoon 的定时器必须挂在全局强引用上。**
   `hs.timer.doEvery` 的定时器即使存进局部变量也没用——`init.lua` 这个 chunk 执行完后局部变量
   即不可达，定时器会被 Lua GC 回收并**静默停摆**。现象是启动几秒后日志再无任何输出。
   本仓库的做法是挂到 `_G.WXGUARD`。
2. **事件回调里任何字段取值都要容错。**
   曾经因为 `focusedInfo()` 返回 nil 时执行了 `ftitle:sub()` 抛错，导致整行诊断日志
   **连带后面的保存动作一起被吞掉**——一次 636 字的语音就这样丢了，而日志里连错误都没有。
   现在：捕获动作排在诊断日志之前，且全程 `pcall`。
3. **短文本的「静默丢字」比崩溃更阴。**
   流式前缀合并 / 去重如果只按字符串关系判断，会吃掉两种情况：
   ①隔了很久后重复说同一句话被去重；②短句恰好是上一条的前缀，被并进上一条且因更短而不留痕迹。
   本仓库用 `mergeWindow`（默认 5 秒）把合并/去重限制在同一会话内。
4. **配置和日志不要放 `~/Downloads`**（macOS 15 的 TCC 受保护目录），Hammerspoon 写入会被**静默拒绝**。
   本仓库把日志放在 `~/Library/Logs/`。
5. **微信上屏失败后会快速还原剪贴板**，所以剪贴板兜底必须够快：
   `changeCount` 轮询 0.1s ＋ 微信事件瞬间同步抢读 ＋ 事件后 0.05/0.12/0.3/0.6/1.2s 追读。

## 为什么不用其它方案（都有实测依据）

| 方案 | 结论 |
|---|---|
| **辅助功能 AX 读浮窗文字** | ❌ 微信 4.1.15 是自绘原生 UI，整棵 AX 树里 `AXText*` 元素数量 = **0**；语音浮窗只是一个 420×40 的 `AXWindow/AXSystemDialog`，读不到任何文本 |
| **读进程内存** | ❌ SIP 已启用 + 微信是 hardened runtime + 沙盒签名且**无 `get-task-allow`**，`lldb` 附加被系统拒绝（`Not allowed to attach to process`）。要绕过就得关 SIP 或用 `get-task-allow` 重签名，后者会改变 sandbox 的 application-identifier、丢掉微信的容器数据与登录态 |
| **MITM 截 ASR 流量** | ❌ 腾讯自有加密协议（MMTLS/自定义），且走 Chromium network service（`--utility-sub-type=network.mojom.NetworkService`），证书固定 |
| **剪贴板历史工具**（Clipy / Raycast） | ⚠️ 只在微信顺带写剪贴板时有效，且它很快还原，普通 1 秒级轮询会漏 |
| **`CGEventTap` 截合成事件** | ✅ **本方案**。实测微信在失败路径上照样把整段文字作为 unicode 事件发出 |

## 局限

- 只在**微信自身**的语音输入上验证过（4.1.15 / macOS 15.0.1）。微信升级后的事件形态可能变化，
  `events.log` 是唯一可靠的验证手段
- 「长时间静音自动停止」本身没有可调设置，这是外部兜底，不是改微信行为
- 只支持 macOS

## 文件

| 文件 | 说明 |
|---|---|
| `init.lua` | Hammerspoon 配置（唯一源码） |
| `deploy.sh` | 部署 + 重启 Hammerspoon + 打印状态 |
| `tools/mock_test.lua` | 用假 `hs` API 加载配置，抓语法/顶层错误（不需要 macOS 权限，可在 CI 跑） |
| `tools/run_mock.sh` | 上面那个的包装（把 `HOME` 指向临时目录，避免污染真实日志） |

运行时产物（不在仓库内）：

| 路径 | 说明 |
|---|---|
| `~/Library/Logs/WeChatVoiceGuard/capture.log` | 捕获流水 |
| `~/Library/Logs/WeChatVoiceGuard/events.log` | 微信注入的原始事件（keycode/flags/unicode/焦点） |
| `~/Library/Logs/WeChatVoiceGuard/state.json` | 最近 300 条历史 |
| `~/Library/Logs/WeChatVoiceGuard/ax-tree.txt` | AX 树快照（诊断） |

## License

MIT
