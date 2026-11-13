# Codex Office

[English](README.md) · 简体中文

Codex Office 是一个 macOS 菜单栏 App，用来查看本机 Codex 聊天。打开 3D 办公室就能看出哪些聊天正在工作、哪些在等你确认。切到「用量」，可以查 Token 都用在了哪里。App 直接读取本机 Codex 日志和桌面端数据，无需额外启动服务或配置 API 密钥。

[下载 macOS 版](https://github.com/anduin-agent/codex-office/releases/latest)

打开 DMG，把 **Codex Office** 拖进「应用程序」并启动。点击菜单栏的小机器人即可打开面板。

- **Apple 芯片**需要 macOS 12 或更新版本，**Intel 芯片**需要 macOS 13 或更新版本。
- v0.1.0 使用临时签名，未经过 Apple 公证。首次打开时 macOS 可能拦截。
- 安装后无需另装 Python、Apple 命令行工具或 `zstd`。

### 首次打开被 macOS 拦截时

如果提示无法验证开发者，或 Apple 无法检查 App 是否包含恶意软件，先确认 DMG 来自本项目的 GitHub 发布页，并核对 SHA-256 与 `SHA256SUMS.txt` 一致。

1. 在「应用程序」中尝试打开 **Codex Office**，然后关闭提示。
2. 前往「系统设置 → 隐私与安全性」，向下滚动到「安全性」。macOS 12 请打开「系统偏好设置 → 安全性与隐私 → 通用」。
3. 在 Codex Office 旁点击「仍要打开」，然后在弹窗中确认。若系统要求验证身份，按提示操作。

[Apple 官方打开指引](https://support.apple.com/zh-cn/102445)

## 办公室

- **一眼看到谁在等你。** 聊天运行时，机器人会在工位敲键盘。Codex 桌面端有待审批或待回答的事项时，机器人会停手抬头，并显示「等你确认」。双击工位可打开对应聊天。
- **看清主聊天和子 Agent 的关系。** 办公室按归属展示子 Agent，可以在设置里多选要显示的 Codex 侧栏分区。
- **在菜单栏查看状态。** 默认显示进行中的主聊天数。有待确认事项时，优先显示等待数量。旁边可三选一显示今日 Token、Token 速度或套餐余量。小机器人的步频随最近一分钟的 Token 用量变化。
- **跟踪跨项目协作。** 设置统筹分区后，可查看从本机日志识别到的成功派发。也可以自己选择统筹聊天和执行聊天、手动记录派发及回执。手动记录只在本机保存关系，不会启动 Codex 任务。

## 用量

- **看今天，也能查历史。** 面板顶部显示今日 Token、当前速度和今日 API 费用预估。「用量」页有近 30 天走势、峰值日和本机可读日志的累计用量。悬停柱子可看日期、Token 和估算费用，点击可看当日排行、输入输出和缓存命中率。
- **看哪些聊天用量最多。** 排行按主聊天、子 Agent 和可归属自动审批的合计排序。展开可看各自用量，找不到父级的审批集中在「未归属的自动审批」。
- **进一步筛选。** 打开「详细用量」，可按日期、项目、模型筛选，再点进会话查看各模型的 Token 用量。
- **对比额度周期。** 本机有周额度或 5 小时额度记录时，可查看余量、重置时刻和倒计时。数据足够时，还会对比当前周期与上次有记录周期的估算容量。
- **查询实时账户额度。** 在办公室设置开启「实时账户额度」后，打开「用量」页或让菜单栏显示套餐余量时，Office 会通过已安装的 Codex 向 OpenAI 查询。用量页会显示来源和读取时间。查询失败时，能确认同一账户才显示本机额度记录。

API 费用按 [OpenAI 标准 API 价格](https://developers.openai.com/api/docs/pricing)折算为美元，是名义费用。App 内置价格表，面板打开时每天最多检查一次价格更新。仅能估价部分用量时，界面会标明。

周期容量用截至快照的本机 Token 除以当时的已用比例。估算要求快照的已用比例至少为 5%，且低于 100%。上周期的 Token 统计截止到重置前。两次估算各留 ±15% 的经验区间，重叠显示「接近上周期」，分开才提示可能增减。模型、任务和其他设备上的用量都会影响估算。

## 设置与数据

设置修改后立即生效。可选简体中文、English 或跟随系统，也可以设置项目别名及要显示的侧栏分区。macOS 13 起可在设置里开启「登录时启动」。点击「检查更新」，发现新版时可打开 GitHub 正式发布页。

Codex Office 在本机读取会话日志、压缩归档和 Codex 桌面数据库。设置保存在 `~/Library/Application Support/Codex Office/office.json`，手动协作记录和回执保存在 App 的 macOS 偏好中。

## 从源码构建

从源码构建需要 Apple Command Line Tools 和 macOS 26 或更新的 SDK。

```sh
make mac-office
open "build/Codex Office.app"
```

发布构建用 `OFFICE_RELEASE_REPO=owner/repo` 指定 GitHub 仓库，并使用 `v0.1.0` 这样的标签发布正式版本，即可启用「检查更新」。

采集器优先使用 `CODEX_HOME`，默认读取 `~/.codex`。也可以在启动时指定其他 Codex 目录。

```sh
open -na "build/Codex Office.app" --args -officeCodexHome "$HOME/path/to/codex-home"
```

如果已有旧版办公室设置 JSON，可在新版 App 第一次保存设置前执行一次导入。导入会复制项目别名、统筹分区和聊天归属。如果 Codex Office 已有设置文件，导入会保留现有设置。

```sh
"build/Codex Office.app/Contents/MacOS/CodexOffice" --import-settings "/path/to/previous-office-settings.json"
```

`make mac-office` 将 AppKit 外壳、WebKit 场景和 Swift 采集器构建到 `build/Codex Office.app`。升级时可通过 `OFFICE_BUNDLE_ID` 指定原来的 App 标识，保留应用偏好。`make test` 用开发机的 Python 3 生成测试数据，并验证 Swift 采集器的会话、用量、协作、待确认状态和设置迁移。`make test-ui` 在离屏 AppKit 面板中验证 WebKit 页面与设置读写桥接，使用临时数据，不显示窗口或抢占焦点。

## 许可证

Codex Office 采用 [PolyForm Noncommercial 1.0.0](LICENSE)。你可以按条款为非商业目的使用、修改并免费分享原版或修改版。分发源码或构建后的 App 时，请保留原作者署名和版权声明，并附上许可证全文或官方链接。商业使用或收费分发须另行取得版权持有人授权。

内置的 [Zstandard 解码器](mac-office/Collector/Zstd/LICENSE) 继续适用其 BSD 许可证。
