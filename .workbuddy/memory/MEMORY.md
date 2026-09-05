# Cassette 项目长期笔记

## 构建与验证（本机环境限制）

`xcode-select` 默认指向 Command Line Tools，**xcodebuild 不可用**：
SwiftPM 解析依赖时要 spawn 沙盒子进程，被环境拒绝（`sandbox-exec: sandbox_apply: Operation not permitted`），
`dangerouslyDisableSandbox` 也绕过不了。SwiftData 的宏插件同样加载不了
（`swift-plugin-server produced malformed response`）。

可用的替代验证手段：

1. **类型检查**：`export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer` 后
   用 `swiftc -typecheck -swift-version 6 -sdk $(xcrun --sdk macosx --show-sdk-path)`。
2. **语法检查**：`swiftc -parse`（不检查类型，适合 SwiftUI 文件）。
3. **纯逻辑验证**：把依赖少的工具文件 + SwiftSonic 源码复制到一个临时目录，
   用 `sed` 去掉 `import SwiftSonic`（变成同模块），编译成可执行程序直接跑断言。
   同模块编译时 `@retroactive Encodable` 要改成 `Encodable`。
4. **SwiftData 替身**：`@Model` / `#Predicate` 无法编译时，用普通 class + 空实现的
   `ModelContext`/`FetchDescriptor` 占位，重点验证其余逻辑。
5. 依赖源码在 `~/Library/Developer/Xcode/DerivedData/Cassette-*/SourcePackages/checkouts/swiftsonic`。
   注意：同模块编译时若同时存在 retroactive conformance，IRGen 会触发编译器崩溃（signal 6），
   此时只能 typecheck，不能 link。
7. **绕开 IRGen 崩溃跑运行时断言**（关键，2026-09-05 发现）：
   - 把 SwiftSonic 编译为 dylib：`swiftc -emit-module -emit-library -module-name SwiftSonic -o libSwiftSonic.dylib <SwiftSonic .swift> 列表`
   - 业务代码 `import SwiftSonic`，运行时引用：`swiftc -I <swiftmodule 目录> -L <dylib 目录> -lSwiftSonic`
   - 这样业务代码里 `@retroactive Encodable` 跨模块的 retroactivity 不会触发崩溃，
     链接也成功，可执行程序直接跑断言。
   - 经验证：`/tmp/lyrcheck/` 下有现成示例（main.swift 拿真实 .lrc 文件跑占位/JSON 解析）。

## 歌词功能

- 服务端是 Navidrome，歌词来自 `.lrc` 文件与内嵌标签。
- 取数链路为**乐观探测**：能力声明只用于诊断，绝不用于拦截请求。理由见 2026-09-05 日志。
- 三级来源：缓存 → `getLyricsBySongId` → legacy `getLyrics(artist:title:)`（经 `LyricsParser` 解析）。
- 缓存分档 TTL：synced 7 天 / unsynced 1 天 / 空结果 6 小时（负缓存）。
  unsynced 用短 TTL，便于服务器补了 `.lrc` 后能被发现。
- **占位假歌词必须拦截**：网易云下载器写 `[00:00.00]暂无歌词` 占位文件，
  服务器原样回传 → 之前会原样渲染。`LyricsParser.isPlaceholder` 检测后，
  `LyricsService.droppingPlaceholders` 在结构化入口 + legacyFallback 两处丢弃。
- **网易云 JSON yrc 混合格**：真歌词文件前几行是 `{"t":-1000,"c":[{"tx":"作词: "},{"tx":"0"}]}`，
  后面才是标准 LRC。`LyricsParser.parseNetEaseJSONLine` 解析 JSON；同时间戳下 LRC 行排 JSON 之前，
  保证标题置首。负 `t` 钳为 0。
- **LRC offset 符号翻转**：LRC `+500` → OpenSubsonic `offset = -500`（保证 `adjusted = elapsed - offset` 一致语义）。
