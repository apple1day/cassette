# 小熊音乐 / Cassette：签名到期提示

音乐仓库为 `apple1day/cassette`，本次基于 `v1.3_player_ui` 的
`02dfab2681a169dbcd1e36e45c203f79befcda6a`。参考 `apple1day/nice`
`6aa144714e5dd5a7bcd19af77562e0bf2fc5e8a3`，不是将视频工程复制到音乐工程。

## 安装和查看

在 **cassette 仓库根目录**执行（首次切换新分支）：

```bash
git fetch origin &&
git switch --track origin/codex/cassette-signing-expiry &&
open Cassette.xcodeproj
```

本地已存在该分支时改用 `git switch codex/cassette-signing-expiry`，再
`git pull --ff-only`。未提交修改请先自行保存；不要使用强制切换或清理命令。

保持原来的 Team 和 Bundle Identifier，选择原 iPhone，按 Command+R **覆盖安装**。
不要先卸载 App，以免删除离线歌曲。本次没有修改工程签名配置或媒体数据。
此工程使用 Xcode 文件夹自动同步，不需要 `ios/repair-project.sh`。

进入「我的」：顶部常驻签名卡显示剩余天/小时和到期日期，点击进入详情。
详情包含具体时间、时区、通知开关和重新检查按钮。
歌曲页和离线页只在剩余 48 小时内显示提示，24 小时内为红色。
不足一天显示小时和分钟，不显示误导性的“0 天”。

Debug 构建：`我的 → 签名有效期 → 查看提醒样式（演示）` 可立即查看五种状态。
演示数据不修改真实签名日期，也不安排通知。Release 不包含演示入口。

## 实现边界

- 读取已安装 App 的 `embedded.mobileprovision` CMS eContent 中的 `ExpirationDate`。
  不按安装日期加七天，不猜测免费/付费账号，不上传描述文件。
- 描述文件不存在、格式未知、Bundle ID 不匹配或模拟器环境均显示“无法确定”。
  不据此阻止播放，也不宣称“永久有效”。解析限制为 4 MiB、24 层和 20,000 节点。
- 仅为描述文件到期提示，不验证证书链、撤销状态或系统能否启动；不能自动续签。
- 用户主动开启后才申请通知权限，按绝对 UTC 时间安排到期前 48/24 小时通知。
  错过的提醒不补发，专注模式/系统通知设置可能影响展示。
- 通知标识使用 `cassette.signing-expiry.*`。关闭、解析失败或重新签名后只清理该功能的
  旧提醒，不清理其他通知。异步调度串行化，避免关闭之后旧任务恢复通知。
- 启动时后台读取一次小文件；前台激活检查通知权限，手动检查才重新读取文件。
  时钟只更新小型卡片，不扫描歌曲目录，不订阅播放进度，不改播放队列和下载数据库。
- 音乐工程默认 MainActor 隔离，纯解析/调度数据类型显式 `nonisolated`；
  SwiftUI 和通知适配器只用于 iOS，macOS 入口不变。需要项目现用的 Xcode 26+。

## 验证

```bash
bash scripts/check-signing.sh
```

该脚本将实际 App 的两个核心源文件及 XCTest 复制到临时 SwiftPM 包，运行 25 项测试。
随后按 Cassette 的 MainActor / approachable-concurrency 设置进行严格并发类型检查。
使用合成 CMS 数据，不依赖真实证书、网络服务或用户歌曲。

已在 Linux Swift 6.2.1 执行核心测试及并发检查。完整 iOS SDK 编译和真机通知展示不是
这些测试能够证明的；新增 GitHub Actions 执行核心测试与不签名 iOS Debug 编译。

真机验收：查看真实到期时间；开启/拒绝通知权限；在系统设置变更权限后返回；快速开关；
覆盖安装新签名后检查日期；飞行模式播放离线歌曲；查看全部演示状态和大字体/暗色布局。

参考：Apple TN3125（描述文件结构）与 UserNotifications 本地通知文档。
