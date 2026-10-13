# Eiraowo

「小手机」的 iOS 原生版（SwiftUI）。和网页版并行，不取代网页版。

## 编译

推到 `dev` 或 `main` 自动编译：先在模拟器上跑自动测试，全部通过才出 ipa。
也可以在 GitHub 的 Actions 页面左边选「编译」，点「Run workflow」手动触发。
几分钟后在那次运行的页面底部下载 `Eiraowo-unsigned`，里面是未签名的 ipa。

## 目录

```
project.yml          XcodeGen 工程描述，CI 上现生成 .xcodeproj
Sources/Eira/        全部 Swift 源码
.github/workflows/   编译工作流
```

规矩见 `CLAUDE.md`。
