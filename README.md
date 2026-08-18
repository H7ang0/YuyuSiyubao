# 屿宇私域宝

Theos tweak scaffold for adding a "语音包" entry to Kuaishou private-message `+` panel.

## Build

```sh
make package
```

> Theos does not support spaces in the project path. If the current folder has spaces, build from a copied folder such as `/tmp/YuyuSiyubaoBuild`.

## Voice Pack Directory

At runtime the tweak scans:

```text
Documents/YuyuSiyubao/VoicePacks
```

Supported file extensions:

```text
m4a, aac, mp3, wav, amr
```

Tap `私信 -> + -> 语音包`, choose a file, and the tweak will call the native IM voice sending service:

```objc
- sendVoiceMessage:withReferenceMessage:duration:
```

In debug builds, choosing a voice file opens a second sheet with preview and four validation paths:

```text
试听                -> AVAudioPlayer local preview
原生录音链路        -> KSIMNTChatVoiceViewModel -handleStopActionWithFileURL:duration:error:
发送服务 Path      -> KSIMNTChatSendMessageComponent -sendVoiceMessage:... using NSString file path
发送服务 URL       -> KSIMNTChatSendMessageComponent -sendVoiceMessage:... using NSURL
发送服务 VoiceInfo -> KSIMVoiceInfo -initWithFilePath:duration:, then sendVoiceMessage:...
```

Tap `试听` first to confirm iOS can decode the imported file. For duration display testing, use `发送服务 VoiceInfo` first because the dumped headers show `KSIMVoiceInfo` owns `filePath`, `duration`, and `isLocal`.

Private-message voice duration is passed to native send APIs in rounded seconds. The tweak also logs and patches `KSIMNTChatVoiceUIState.durationText` / `KSIMNTChatVoiceContentView.durationLabel` when the display layer has a real duration but still renders zero.

## Comment Voice Pack

The tweak also hooks the comment voice recording panel:

```objc
KSCommentVoiceCommentPanelView
```

When the panel opens, it adds a `语音包` button to the left side of the panel close button. The comment voice pack uses the same directory as private messages:

```text
Documents/YuyuSiyubao/VoicePacks
```

Selecting a voice file supports:

```text
试听
发送到评论区
```

`发送到评论区` creates a `KSCommentVoiceInfo` with the selected file path and duration, then calls the native panel completion callback:

Duration is stored in milliseconds to match comment voice attachment metadata.

```objc
- voiceCommentRecorderDidFinishWithVoiceInfo:
```

If the panel method is unavailable, it falls back to the native delegate callback:

```objc
- voiceCommentPanel:didFinishRecordingWithAttachment:
```

## Hook Verification

This debug build prints runtime validation logs with the prefix:

```text
[屿宇私域宝]
```

Useful checks:

```sh
log stream --predicate 'eventMessage CONTAINS "[屿宇私域宝]"' --style compact
```

Expected validation flow:

```text
loaded bundle=com.smile.gifmaker
runtime validation begin
class KSIMNTChatMoreViewModel=YES
KSIMNTChatMoreViewModel has -genUIState type=...
KSIMNTChatMoreViewModel has -handleIMNT_KSIMNTChatMorePanelDidClickedIconIntent: type=...
KSIMNTChatSendMessageComponent has -sendVoiceMessage:withReferenceMessage:duration: type=...
KSIMVoiceInfo has -initWithFilePath:duration: type=...
KSIMNTChatVoiceContentView has -updateUIWithFrameEntity:uiState: type=...
genUIState hit state=KSIMNTChatMoreUIState originalItems=...
voice pack item injected newItems=...
more panel click intent=KSIMNTChatMorePanelDidClickedIconIntent item=KSIMChatMorePanelItem key=com.yuyu.siyubao.voicepack index=...
calling KSIMNTChatSendMessageComponent -sendVoiceMessage:withReferenceMessage:duration:
voice content update view=KSIMNTChatVoiceContentView frameEntity=... durationAfter=... textAfter=... label=...
```

If any class or selector is `missing`, the current app version does not match the dumped headers for that hook point.
