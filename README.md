# 旁白助手（VoAssist）

让 iOS 旁白（VoiceOver）用**系统自带的苹果声音**读得更顺心：语速加倍、中英双语、朗读修正、数字读法，方案可以分享给别人。不带任何第三方语音库。

> VoAssist is an iOS speech synthesis extension (`AVSpeechSynthesisProviderAudioUnit`) for VoiceOver users. Inside the extension it reads with Apple's own built-in voices and adds what VoiceOver lacks: a Sonic speed boost (the same version NVDA uses), Chinese/English reading with a second voice, user reading rules, number reading and shareable voice schemes. The documentation is in Chinese.

## 功能

- **语音方案**：在 App 里定义方案（主语音、副语音、语速加倍……）。系统的声音列表里只显示方案名，每个方案只出现在主语音那种语言的列表里（点开“旁白助手”分组）。
- **语速加倍**：旁白 100% 已是苹果声音本身的最快速度，方案的“语速加倍”在此之上再快 1–6 倍，不变调。用的是 NVDA“语速加倍”同一版本的 Sonic 算法。
- **原生停顿**：整句交给苹果声音按旁白发来的 SSML 读，停顿、句读和旁白直接用这个声音时一模一样。
- **中英双语**：中文方案里的英文交给副语音（如 Samantha），其他语言方案里的汉字交给中文副语音，同一句话里无缝衔接。副语音可以单独调相对语速；音量平衡默认打开，把副语音调到和主语音一样响。
- **数字读法**：默认交给系统声音；也可以选“数值”（1234 读一千两百三十四）或“数字”（逐位读一二三四）。
- **朗读修正规则**：自己写替换规则（普通文字或正则表达式），修正多音字、英文读法、数字和符号的读法。规则全局一份，每个方案决定用不用。
- **分享**：方案和规则可以导出成文字或 `.voassist` 文件发给别人，对方一键导入。

## 系统要求

- iOS 16 或更新（第三方声音扩展从 iOS 16 开始）。
- 只能用系统**内置**的苹果声音（婷婷、美嘉、善怡、Samantha 等）。语音扩展的沙盒拿不到下载的增强、高音质声音和 Siri 声音，App 的声音选择页也只列能用的声音。原因见[开发笔记](docs/开发笔记.md#实现要点踩过的坑)。

## 使用

1. 安装后先打开一次 App：它会建好默认方案“婷婷+Samantha”（婷婷读中文、Samantha 读英文），并测量手机上的语速曲线。
2. 打开 设置 → 辅助功能 → 旁白 → 语音，在方案对应的语言里点开“旁白助手”，选择方案。新建或改名的方案最多要约 30 秒才出现；一直不出现就重启一次手机。
3. 旁白自己的语速滑块和转子照常用，管的是苹果声音本身的快慢；加速、双语、规则、数字读法都在 App 的方案里设置，旁白读下一句就生效。

遇到问题时：在 App 主页的“日志”里打开“记录日志”（一小时后自动关闭），把问题重现一遍，再点“发送日志”，用微信、邮件等发给开发者。日志默认不记旁白读的文字，只记字数；排查读法问题时可以再打开“记录朗读内容”。日志只存在手机上，App 不联网，只有你自己点发送时才会离开手机。

编辑已有方案时，改动马上对旁白生效，方便直接用旁白试听；点“取消”或下滑关掉编辑页，方案恢复原样。名称和换成另一种语言的主语音要点“保存”才生效。方案编辑页里也可以直接试听。

### 方案设置

| 项 | 说明 | 默认 |
| --- | --- | --- |
| 名称 | 系统里显示的名字 | 主语音的名字 |
| 主语音 | 系统内置的苹果声音，先选语言再选声音（常用语言在上） | — |
| 副语音 | 中文主语音（普通话、台湾、粤语）配非中文声音读英文；其他主语音配中文声音读汉字；可以不用 | — |
| 语速加倍 | 1–6 倍（Sonic） | 1 倍 |
| 副语音相对语速 | 0.5–2 倍 | 1 倍 |
| 副语音音量平衡 | 自动测两个声音的响度，把副语音调到一样响（最多 ±12 dB） | 开 |
| 使用修正规则 | 用不用全局的朗读修正规则 | 开 |
| 数字读法 | 默认（交给系统声音）/ 数值 / 数字 | 默认 |

各项的具体规则（中英怎么分段、数字怎么转换、分享文件的格式）见[开发笔记](docs/开发笔记.md)。

## 自己编译

需要 Xcode 15 或更新、[XcodeGen](https://github.com/yonaskolb/XcodeGen)（`brew install xcodegen`）。

```sh
swift test                 # 核心代码的单元测试（Mac 上跑）
xcodegen generate          # 生成 VoAssist.xcodeproj
open VoAssist.xcodeproj    # 选自己的 iPhone 运行
```

第三方声音只有真机上的旁白能选用，模拟器只能跑 App 和扩展自检。

要装到自己的手机上，得换成自己的开发者团队和标识（下表各处一起改，必须保持一致；两个 Info.plist 由 XcodeGen 按 `project.yml` 生成，不用手改）：

| 项 | 本仓库的值 | 在哪里改 |
| --- | --- | --- |
| 开发者团队 | `H9V8GVBZSS` | `project.yml`（`DEVELOPMENT_TEAM`） |
| App | `com.zdyi.voassist` | `project.yml` |
| 扩展 | `com.zdyi.voassist.voice` | `project.yml` |
| App Group | `group.com.zdyi.voassist` | `project.yml`、`Sources/BoostCore/SharedSettings.swift`（`groupID`） |
| 方案的声音标识前缀 | `com.zdyi.voassist.s.` | `Sources/BoostCore/Scheme.swift`（`providerPrefix`） |
| 分享文件类型 | `com.zdyi.voassist.share`（`.voassist`） | `project.yml`、`App/AppModel.swift` |
| AudioComponent | `ausp` / `VoAs` / `Zdyi` | `project.yml`、`App/ExtensionProbe.swift`（`extensionComponent`） |

在 Mac 上试听处理效果、真机调试、发布 TestFlight 的命令都在[开发笔记](docs/开发笔记.md#命令)里。

## 目录

| 路径 | 内容 |
| --- | --- |
| `Sources/BoostCore/` | 平台无关的核心：SSML 改写（`ApplePlan.swift`）、Sonic 封装、静音裁剪、语速换算、中英分段、修正规则、数字读法（`Numbers.swift`）、语音方案与分享格式、响度测量、共享设置、系统声音驱动（`SystemVoice` / `BoostSynthesis`）、扩展的播放缓冲（`AudioRing`）与它的实时模拟（`PlaybackCheck`） |
| `Sources/CSonic/` | Sonic 原版 C 代码（NVDA 同一版本）和它的 Apache 2.0 许可证 |
| `Extension/` | 语音扩展本体（AU、合成线程） |
| `App/` | 宿主 App：方案管理、规则管理、分享与导入、试听 |
| `Sources/render-samples/` | Mac 命令行工具：用 Mac 的系统声音跑同一条处理链，输出 WAV |
| `Tests/BoostCoreTests/` | 单元测试 |
| `docs/开发笔记.md` | 设计、处理流程、实测数据、踩过的坑、调试命令 |
| `project.yml` | XcodeGen 工程定义 |

## 许可证

本项目以 [Apache License 2.0](LICENSE) 发布。

`Sources/CSonic` 是 Bill Cox 的 [Sonic](https://github.com/waywardgeek/sonic)（Apache 2.0），在 NVDA 使用的那次提交（b93885d）上原样收录，未作修改，许可证见该目录下的 `LICENSE`；App 的“关于 → 开源许可”里也能查看。

## 致谢

- [Sonic](https://github.com/waywardgeek/sonic)（Bill Cox）：语速加倍的算法。
- [NVDA](https://github.com/nvaccess/nvda)：“语速加倍”对 Sonic 的用法（同一版本、同样的调用方式）。
- NVDA 的 Dual Voice、WorldVoice 插件：中英分段的思路。

## 声明

Apple、iPhone、VoiceOver、Siri 是 Apple Inc. 的商标。本项目与 Apple 无关，也未经 Apple 认可。
