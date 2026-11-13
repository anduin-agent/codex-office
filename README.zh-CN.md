# Codex Office

[English](README.md) · 简体中文

Codex Office 是一个 macOS 菜单栏 App，在双层 3D 办公室里展示本机 Codex 聊天。它直接读取这台 Mac 上的会话日志和客户端元数据，所有处理都在本机完成，无需启动额外服务、登录账户或配置 API 密钥。

从 [GitHub Releases](https://github.com/anduin-agent/codex-office/releases/latest) 下载并打开 DMG，把 Codex Office 拖入「应用程序」。Apple 芯片的 Mac 需要 macOS 12 或更新版本，Intel 芯片的 Mac 需要 macOS 13 或更新版本。运行时无需安装 Python、Apple Command Line Tools 或 `zstd`。

从源码构建需要 Apple Command Line Tools 和 macOS 26 或更新的 SDK。

```sh
make mac-office
open "build/Codex Office.app"
```

单击菜单栏图标展开办公室，再点图标或点面板外侧即可收起。收起时暂停 3D 渲染。单击工位查看状态，双击打开对应的 Codex 聊天。如果会话日志提供累计 token 数，工位详情会显示该数值。

菜单栏显示进行中的主聊天数，有待确认的聊天时优先显示「等你确认」和数量。在「办公室设置 → 菜单栏显示」中可选旁边显示今日 Token、Token 速度或套餐余量。菜单栏机器人的步频跟随最近 1 分钟的 token 速度，无用量时站定。办公室里的机器人坐在显示器后面，聊天运行时会交替敲键盘和眨眼。读到本机 Codex 桌面发出的待审批或待回答状态时，机器人会停手抬头，工位显示「等你确认」。两处动画都遵循 macOS 的「减少动态效果」。「用量」面板展示实时聊天用量、最近 30 天走势和本机可读日志的累计用量。

用数据摘要下方的「办公室」和「用量」标签切换视图。悬停柱子可查看日期、Token 数和 API 费用预估，点击可查看当天的会话用量排行。统计在本机从 Codex 会话日志计算，App 用内置的 Zstandard 解码器读取压缩归档。「用量」页展示本机最近记录的 Codex 额度快照中的有效窗口，5 小时额度在上，周额度在下。菜单栏的套餐余量显示最长的有效窗口。

周额度和 5 小时额度各自显示从周期开始至今本机记录的 Token。容量按同一时刻的本机 Token 和额度已用比例外推，表示按当前用法大致能用多少。数据不完整、已用比例低于 5% 或额度已经用尽时，仅显示已记录用量。5 小时额度在本机有有效记录时显示。

在「用量」页点「详细用量」可打开独立窗口，按日期、项目和模型筛选。点会话可查看所选范围内各模型的 Token 数。Swift 采集器直接读取本机 Codex 日志和会话元数据，无需启动 Python 或本地 Web 服务。个人总看板可以继续读取同一批 Codex 日志，并保留自己的历史数据库和其他数据来源。

用量排行按主对话、子 Agent 和可归属自动审批的 Token 合计排序。展开一组可以看各会话的自身用量，也可以一键收起全部分组。找不到明确父级的自动审批集中在「未归属的自动审批」。

顶部摘要显示今日 API 费用预估。「用量」页汇总本机可读日志的全部历史，柱状图和峰值日使用最近 30 天。选中日期后可查看当天的输入、输出 Token 和缓存命中率。Token 统计旁的小字是按标准 API 标价折算的名义费用，实际扣费以账单为准。

本机日志有周额度或 5 小时额度时，「用量」分别显示本周期和上次有记录周期的用量与估算容量。上周期 Token 截止到重置前，容量用重置前最后一条可用的同账户快照计算：截至快照的本机 Token ÷ 当时的已用比例（至少 5%，低于 100%）。两次估算各取 ±15% 的经验区间；重叠显示接近，分开才提示可能缩小或增加。数据不足或记录到的套餐不一致时不判断变化；模型、任务和其他设备的用量都可能影响估算。

费用以美元按 [OpenAI 官方标准 API 价格](https://developers.openai.com/api/docs/pricing)估算，并标明只能估价部分用量的情况。App 内置价格表，在浮窗打开时每天最多检查一次公开价目表，刷新失败时继续使用上次可用的价格。

Git 工作区会显示为项目。点面板内的设置按钮，或在右键菜单选「设置…」，即可编辑项目别名、统筹分区和聊天归属。新安装的统筹分区默认留空，配置后才自动识别该分区。设置保存在 `~/Library/Application Support/Codex Office/office.json`。手动协作关系和回执保存在 App 的 macOS 偏好中。

添加项目别名时，可从列表选择本机 Codex 已登记的项目目录，也可点「浏览…」选择其他文件夹，再填写 Office 中显示的名称。

「办公室设置」会列出本机 Codex 侧栏分区。默认显示全部，可以改为只显示勾选的分区，也可以单独勾选「未分区」。筛选用于办公室工位，菜单栏的聊天计数和用量仍汇总本机聊天。

在「办公室设置 → 界面语言」可选简体中文、English 或跟随系统，选择后立即切换。设置会自动保存。设置会显示当前版本，从 Git 工作区构建时还会显示短提交哈希。macOS 13 起可开启「登录时启动」，较早的系统可手动添加登录项。办公室顶部并排显示今日用量和 Token 速度。「用量」面板会同时显示额度重置时刻和精确到分钟的倒计时。

发布时用 `OFFICE_RELEASE_REPO=owner/repo` 指定公开的 GitHub 仓库，并以 `v1.2.3` 这样的版本标签发布正式 Release 和 DMG。用户点击「检查更新」时，App 会查询该仓库的最新正式版本，有新版时可打开发布页。开发构建默认显示发布渠道尚未配置。

自动统筹来自成功的本机 Codex 任务派发记录。确认另一个项目发生文件改动时，目标项目短暂亮起，聊天对应的小人留在原来的工位。

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
