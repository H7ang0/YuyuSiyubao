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
genUIState hit state=KSIMNTChatMoreUIState originalItems=...
voice pack item injected newItems=...
more panel click intent=KSIMNTChatMorePanelDidClickedIconIntent item=KSIMChatMorePanelItem key=com.yuyu.siyubao.voicepack index=...
calling KSIMNTChatSendMessageComponent -sendVoiceMessage:withReferenceMessage:duration:
```

If any class or selector is `missing`, the current app version does not match the dumped headers for that hook point.
