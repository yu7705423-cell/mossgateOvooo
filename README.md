# Eiraowo

「小手机」的 iOS 原生版（SwiftUI）。和网页版并行，不取代网页版。

## 编译

GitHub 上打开 Actions，左边选「编译」，点「Run workflow」。
十几分钟后在那次运行的页面底部下载 `Eiraowo-unsigned`，里面是未签名的 ipa。

只手动触发：仓库私密，macOS 机器按 10 倍扣免费额度。

## 目录

```
project.yml          XcodeGen 工程描述，CI 上现生成 .xcodeproj
Sources/Eira/        全部 Swift 源码
.github/workflows/   编译工作流
```

规矩见 `CLAUDE.md`。
