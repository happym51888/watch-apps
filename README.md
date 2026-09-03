# 四款 Apple Watch 应用

调研 → 筛选 → 实现。四个应用都是完整源码，可直接在 Mac 或 CI 上构建。

- **调研报告与选型理由**：[`00-研究报告与选型.md`](00-研究报告与选型.md)
- **平台限制备忘**：[`01-watchos-platform-constraints.md`](01-watchos-platform-constraints.md)
- **验证状态与已知风险**：[`02-verification-status.md`](02-verification-status.md)

---

## 四个应用

| | 应用 | 做什么 | 需求证据 | 形态 |
|---|---|---|---|---|
| 1 | [**Kairos**](apps/Kairos/README.md) | 手表原生双因素验证码 | GitHub issue 78 👍 + 33 👍，2017 年至今未解决 | iPhone + Watch |
| 2 | [**Tactus**](apps/Tactus/README.md) | 触觉节拍器 | Soundbrenner 卖 70–130 美元硬件做同一件事 | 仅 Watch |
| 3 | [**Awqat**](apps/Awqat/README.md) | 礼拜时间 + 朝向 + 计数器 | 现有最佳应用的复杂功能变成空白方块 | 仅 Watch |
| 4 | [**Verba**](apps/Verba/README.md) | 一键录音 → 转文字 → 进自己的数据库 | 你自己提的需求 | iPhone + Watch |

每个应用的 README 里写了：为什么做、关键设计决策、构建步骤、审核风险、以及 v1 故意没做的东西。

### Verba 有两条硬限制值得单独看一眼

动手前先查了每个 API 在 watchOS 上到底有没有，查的是 Apple 自己的文档索引，不是猜的。两条结论直接否掉了最直觉的做法：

- **watchOS 上没有任何语音转文字 API。** `SFSpeechRecognizer` 和 26 新出的 `SpeechAnalyzer` 都只有 iOS / iPadOS / macOS / visionOS，没有 watchOS。所以"手表自己转文字"这个功能不是难做，是做不了——任何人都做不了。转写放在 iPhone 上，本地跑，免费，音频不出设备。
- **手表 App 不能在后台启动录音。** `audio` 后台模式只允许**继续**已经在前台开始的录音，从定时器里启动会直接报 `AVAudioSession` 561015905。所以"全天自动录下所有声音"也做不了。

能做而且已经做好的是：一键开始（表盘一下就能点到）→ 放下手腕、锁屏、切别的 App 都继续录 → 传到 iPhone → 本地转写 → 存进你自己的 Supabase。

---

## 当前状态：四个应用全部编译通过、测试全绿

GitHub Actions 的 `macos-15` runner 上，真实的 `xcodebuild` 和 `swift test`：

| 构建目标 | 结果 | | 测试 | 结果 |
|---|---|---|---|---|
| KairosWatch | BUILD SUCCEEDED | | Kairos | 9 tests, 0 failures |
| Kairos (iOS) | BUILD SUCCEEDED | | Tactus | 31 tests, 0 failures |
| TactusWatch | BUILD SUCCEEDED | | Awqat | 36 tests, 0 failures |
| AwqatWatch | BUILD SUCCEEDED | | Verba | 19 tests, 0 failures |
| VerbaWatch | BUILD SUCCEEDED | | | |
| Verba (iOS) | BUILD SUCCEEDED | | 合计 | **95 tests, 0 failures** |

六个目标全部 0 error。从第一次推上去到全绿一共八轮，中间修掉的都是**只有编译器才能发现的问题**：模块导入、Swift 6 数据竞争、协议隔离、类型检查超时、缺失的 `Hashable` conformance。清单见
[`02-verification-status.md`](02-verification-status.md)。

其中有两个值得单独说：

- **CI 曾经在骗人。** `continue-on-error: true` 是第一轮为了一次性看到所有错误加的，但它让任务在 `xcodebuild` 失败时依然报绿。第 5 轮 11 个任务全绿、实际两个构建是失败的，就是它造成的。现在两处都已删除，绿灯才有意义。
- **测试写错了，代码是对的。** Awqat 有两个儒略日断言失败，查下来是我写测试时把 Meeus 书里的 "1957 October 4.81 → JD 2436116.31" 当成了午夜值。用 Python 独立算过之后确认：实现返回的 2436115.5 才对。

## 核心逻辑另有一层验证（编译之外）

Swift 工具链在这台 Windows 机器上装好了，但无法编译——标准库需要 Windows SDK，而 MSVC 构建工具的安装需要管理员权限（已尝试，失败）。SwiftUI 与 WatchKit 在 Apple 平台之外则根本无法编译。

所以采取的办法是：**把可能算错的纯逻辑单独移植成 Python 跑起来，用外部公开数据对答案。**

挑出来验的都是**错了不会报错、只会静悄悄给出错结果**的那部分——崩溃能自己暴露，算错不会。

```sh
python apps/Kairos/validation/verify_totp.py        # PASS (47,954 assertions)
python apps/Tactus/validation/verify_haptic_plan.py # PASS (61,233 assertions)
python apps/Awqat/validation/verify_astronomy.py    # PASS
python apps/Verba/validation/verify_queue.py        # PASS (3,054,303 assertions)
python apps/Verba/validation/verify_transcript.py   # PASS (23,259 assertions)
python apps/Verba/validation/verify_upsert.py       # PASS (36 assertions)
```

| 应用 | 对照基准 | 结果 |
|---|---|---|
| Kairos | RFC 4226 附录 D、RFC 6238 附录 B、RFC 4648 §10 | 全部向量逐字节一致 |
| Tactus | 60,960 种配置的性质穷举 | 最紧间隔 0.3409s，未触碰 0.34s 下限 |
| Awqat | AlAdhan API 的 36 个已发布时刻 | 30 个完全一致，6 个差 60 秒内（分歧原因已查明并记录） |
| Verba | 400 轮随机事件流，含 6,927 次传输中途崩溃 | 每次删文件都确认了别处有副本，没有一条录音消失 |
| Verba | 3,000 段随机录音、338,799 个词的分段拼接 | 100% 完整还原，**0 个词丢失** |
| Verba | 数据库 upsert 的三种到达顺序 | 6 种排列全部收敛到同一行，已有文字不会被后到的写入抹成空 |

Verba 那三条是这次新加的，思路和前三个一样：录音机唯一不可原谅的 bug 是丢录音，所以队列写成纯状态机，然后拿随机事件流猛砸，**每一个事件之后**都检查"只存在于手表上的音频有没有被删"。分段拼接同理——固定切分会吃掉跨越切口的那个词，转出来的文字读着通顺、每分钟少一个词，是最难发现的一种错。

**这不能替代编译**，两者抓的是不同的东西。Python 验证器管"算得对不对"，编译器管"写得合不合法"——上面那 8 轮修的错，验证器一个都发现不了；而验证器抓到的 Asr 偏差 60 秒，编译器也永远不会报。两层都得有。

---

## 你没有 Mac，所以先跑 CI

[`.github/workflows/build.yml`](.github/workflows/build.yml) 已经写好。推上 GitHub 就会：

1. 在 Ubuntu 上跑六个 Python 验证器（快，先挡一道）
2. 在 `macos-15` 上跑 `swift test`
3. 用 XcodeGen 生成工程，`xcodebuild` 出完整 watchOS 构建
4. 把编译错误汇总到 Actions 的 Summary 页，并上传完整日志

前几轮里 Swift 相关的步骤设了 `continue-on-error`，因为这批代码从没见过编译器——**当时要的是完整错误清单，不是停在第一个错误上的任务**。这两处现在已经删掉了：留着它，构建失败也会报绿（第 5 轮就是这样骗过去的），绿灯就不再是证据。

公开仓库的 macOS runner 免费；私有仓库按 10 倍计费 macOS 分钟数，会很快吃掉免费额度，建议先用公开仓库。

真机才能回答的问题（CI 一个都答不了）：触觉够不够强、扩展运行时会话是否可靠、耗电多少、Core Location 冷启动多快。

---

## 目录

```
00-研究报告与选型.md              调研方法、否掉的方向、最终三选的理由
01-watchos-platform-constraints.md 平台硬限制（触觉速率、后台、表盘、传感器）
02-verification-status.md          验证做到了哪一步、还有什么风险
.github/workflows/build.yml        macOS CI

apps/Kairos/     TOTP 验证器     Sources/KairosCore + WatchApp + PhoneApp + Complication
apps/Tactus/     节拍器           Sources/TactusCore + WatchApp + Complication
apps/Awqat/      礼拜时间         Sources/AwqatCore + WatchApp + Complication + Shared
apps/Verba/      录音转文字       Sources/VerbaCore + WatchApp + PhoneApp + supabase/
```

每个应用内部结构一致：`Sources/<Name>Core/` 是不依赖任何 Apple 框架的纯逻辑（因此 `swift test` 在哪都能跑），`Tests/` 覆盖它，`validation/` 是可执行的外部对照，其余是平台层。

---

## 上架前必须知道的两件事

**Tactus 和 Awqat 是 watch-only。** App Store 没有独立的 watchOS 平台，Xcode Organizer 会拒绝上传。需要套一个 iOS 壳（容器 `Info.plist` 设 `ITSWatchOnlyContainer = true` 和 `LSApplicationLaunchProhibited = true`，手表端设 `WKWatchOnly = true` 且不能有 `WKCompanionAppBundleIdentifier`），并用 `iTMSTransporter` 上传。两个 plist 都已按此配置好。

代价是：**watch-only 应用在 App Store Analytics 里什么都看不到**——没有获取、留存、崩溃、归因数据，只有销售报表。Kairos 不受影响，因为它是带手表端的正常 iOS 应用。

**Tactus 有一个真实的审核风险**：它声明了 `mindfulness` 后台模式来维持节拍。Apple 的文档明确说会话类型应按应用**用途**选择，而不是按它能换到的运行时间。节拍器不是正念。README 里列了三个应对方案，其中"改用后台音频"是零风险路线，代码已经写好，切换只是改 plist 加一个开关。

**Kairos 和 Verba 不受这两条影响**，它们是带手表端的正常 iOS 应用，正常提交、正常拿数据。Verba 用的是 `audio` 后台模式——录音 App 做录音，没有需要辩解的地方。

另外 Verba 上架前要处理一件与代码无关的事：**录音的合法性在不同地区不一样**（美国部分州要求双方同意，欧盟另有规定）。这句话该写在 App Store 的描述里，不是藏在设置页某个角落。
