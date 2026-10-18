# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

旁白助手（VoAssist）：iOS 语音扩展，在扩展里调用苹果自带的声音，再做 Sonic 加速、中英双语、朗读修正、数字读法。使用和编译见 README.md；设计、处理流程、实测数据、踩过的坑、调试和发布命令在 docs/开发笔记.md，动手前先读相关章节，改完同步更新。

## 常用命令

```sh
swift test [--filter 类名[/方法名]]
swift run -c release render-samples ...   # 参数见 Sources/render-samples/main.swift 顶部
xcodegen generate                         # 改了 project.yml 或增删源文件后
```

## 必须遵守

- 不能阻塞主线程：`AVSpeechSynthesizer.write()` 的回调只投递到主队列。
- 只包装 `com.apple.*` 的声音（`VoiceEntry.isWrappable`），否则会递归调用自己。
- 语速模型：旁白 100% = 苹果最快；加倍只由 Sonic 做，只在 App 里设置。
- `Sources/CSonic` 是 NVDA 同一版本的原版 Sonic，不要改。
- 各处标识要一致（见 README“自己编译”）。
- 方案的 `id` 和默认方案的 UUID 不能变；新字段解码用 `decodeIfPresent`。
- `synthesizeSpeechRequest` 只等到第一块声音就返回：旁白的调用是排队执行的，等久了“取消”和下一句都得等。
- 交给苹果合成器只能经过 `SystemVoice.run`：iOS 27 以前的 `AnnouncementGuard` 靠它设的线程标记挡掉推给旁白的播报（否则旁白不读“按钮”和提示）。这是私有接口，App Store 版不能带。
- 新请求交给空闲的合成器（`SynthWorker` 的合成器组、`SystemVoice.isBusy`），不要改回一个合成器：被打断的合成器要忙约 0.3 秒。
- 改了扩展的朗读流程：在 iOS 26 真机上用 `-focusTest` 确认“按钮”和提示照读，用 `-interruptTest` 看打断后的出声时间（开发笔记“真机调试”）。
