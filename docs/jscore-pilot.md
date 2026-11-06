# 试点：网页版逻辑在 JavaScriptCore 里跑

目标：界面照旧用 SwiftUI 写，业务逻辑直接执行网页版自己的 JS 文件，不再逐行翻译成 Swift。
脚本在编译前由网页版源码打好，随 app 打包，不联网下载（App Store 审核 2.5.2）。
第一个试点是回复解析：网页版 `src/system/ai/reply.js` 的 `splitReply`，与原生 `Prompt/ReplyParser.swift` 并排对照。
正式路径没有改，`ChatEngine` 仍用 `ReplyParser.split`。

网页版提交：`52b119c06f`（`claude/mini-phone-architecture-tqzvig`）。

## 文件

| 文件 | 作用 |
|---|---|
| `scripts/sync-weblogic.mjs <网页版目录>` | 手写的最小 ESM 打包，产出 `Resources/weblogic/reply.bundle.js`（不许手改） |
| `Resources/weblogic/shims.js` | 模块表、两个手写替身、宿主接口 `weblogic.parseReply`（手写，可改） |
| `scripts/check-weblogic.mjs` | 在 Node 的 `vm` 里按 JSContext 的条件（没有 window、document、console、定时器、fetch）跑一遍 |
| `Sources/Eira/Prompt/WebLogic.swift` | 一个 JSContext，串行队列，出错记诊断返回 nil；结果换成 `ReplyParser.Result`；`compareWithNative` 对照 |
| `Tests/Unit/WebLogicTests.swift` | 同一批样本两边对照；两边耗时 |
| `Tests/Fixtures/weblogic-cases.json` | 样本：ReplyParserTests 的每一条输入，外加十条互动标记。Node 检查与 Swift 测试共用 |

`project.yml` 不用改：`Resources` 整个目录按 resources 打包，子目录的文件平铺在包的根上，`WebLogic` 两种位置都找。

## reply.js 的依赖

reply.js 3231 行、182 KB，直接 import 77 个模块（含 4 处动态 import）。按网页版无打包器的写法一路展开，
传递闭包是 **267 个模块、2.9 MB**，几乎是整个 `src/system`，包括数据库、接口队列、通知、导航。
所以不能整包搬，只能在边界上切断。

`splitReply` 及其局部函数（`liftCards`、`liftCalls`、`liftFiles`、`liftTheater`、`voicePart`、`reactOf`、`autoSplit`……）
实际调到的外部函数：

| 模块 | 调到的 | 纯不纯 |
|---|---|---|
| `markfold.js` | `foldMarks` `foldMedia` `splitTrailRecall` `flattenQuoteLines` | 纯，零依赖 |
| `ai/think.js` | `stripThink` | 纯，零依赖 |
| `ai/translate.js` | `compiled` `splitInline` `transLine` | 函数纯；读 `settings.get().translateFormats` |
| `place.js` `gift.js` `takeout.js` `trip.js` | `parse` | 函数纯；模块顶上 import 了 db、accounts |
| `closet.js` `collect.js` | `parseOutfit` `parseAcquire` | 同上 |
| `reaction.js` | `isEmoji` `emojisIn` | 同上 |
| `htmlcard.js` `statusbar.js` `innercard.js` | `hasHtml` `htmlSegments` `lift` | 同上 |
| `pass.js` `gacha.js` | `kindByMark` `rarityByLabel` | 同上 |
| `day.js` `request.js` | 常量 `DONE` `DROP` `JOINT` `SPEND` `CARD` `DEPOSIT` | 同上 |
| `db/index.js` | `settings.get().autoSplitAt` | **不纯**，换成替身 |

要点：**这些函数本身都是纯字符串逻辑，但它们所在的模块每一个都在顶上 import 了 `db/index.js`**。
网页版按功能分文件，不按纯不纯分，所以纯函数和读库的函数住在同一个文件里。
好在这些模块顶层都只有声明，没有一进来就执行的语句，import 进来的东西只在函数里用，换成存根不影响加载。

## 打包的做法

- 真打进包的模块列在 `REAL`（22 个，含 `db/defaults.js` 供替身取默认设置）；
  它们 import 的其余模块一律是**存根**（68 个）：读出来的每一项都是一调就抛错的函数，错误里写明模块与名字。
- 替身两个（`shims.js`）：`db/index.js` 只给 `settings.get()`，返回网页版 `DEFAULT_SETTINGS` 叠上宿主这一次传进来的几项；
  `ai/templates.js` 给空的 `DEFAULT_TEMPLATES`（`defaults.js` 只 import 不读）。
- 动态 import 只放行 `DYNAMIC_OK` 里的三个（来电、一起听、一起看，都在 `materialize` 里，不在解析路径上），换成被拒的 Promise；
  其余写法（`import.meta`、解构导出、`export * as`、非字面量路径的 `import()`）一律报错退出，不猜着转。
- 存根被当成常量用，会把函数塞进结果：`parseReply` 序列化时遇到函数直接报错。
- 具名 import 写成 `let x = __wl.live(mod, "x", v => { x = v; })`：循环依赖里对方还没执行完时先是 undefined，对方执行完补上（提示词拼装那一包里循环依赖很多，见 docs/jscore-prompt.md）。仍不是完全的活绑定：`export let` 之后再赋值的看不到；网页版 `src/system` 里没有一处 `export let`。

## 结果（Node 的 vm，JSContext 的同等条件）

- 产物 **525 KB**（gzip 后 177 KB），其中 `db/defaults.js` 42 KB、`closet.js` 46 KB、`trip.js` 30 KB 都只为一两个函数。
- 79 条样本全部跑通，**解析路径上没有调到任何存根**。
- 2000 行 x 200 次：约 2.2 秒，每次 11 毫秒（Node 有 JIT）。
- 网页版与原生已经能看出的差别（Node 输出与 ReplyParserTests 的断言对比）：
  - `[截图：聊天]`：原生当成文字，网页版是一张截图（`shot`）。这是真差异。
  - `[批准]` `[暂停]` `[同行]` `[心愿：…]` `[梦境：…]` 等：网页版落成 `vote` `playback` `trip-go` `wish` `dreamshare`，
    原生按既定做法吞掉。测试里只记录，不算不一致。
  - 时间戳：原生记整个 `[时间：…]`，网页版只记里面的时间。对照只比有没有。

Swift 测试里两边真正不一致的记成「预期内的失败」（`XCTExpectFailure`），日志里能看到每一条，不挡出包；
`WEBLOGIC_STRICT=1` 时是真失败。脚本加载不了、解析抛错一律是真失败。

## 速度：要真机数

模拟器跑在 Mac 上，JavaScriptCore 多半开着 JIT；**真机上 app 里的 JSContext 没有 JIT**（没有动态代码签名权限），
解释执行，正则也走解释器而不是 YARR JIT。CI 日志里的数只是下限。
一次 2000 行的解析在 Node 里 11 毫秒，真机解释执行慢一个数量级是常见的，仍在可接受范围；
日常回复只有几行到几十行，更不成问题。要定论，需要在 TestFlight 包里从「诊断」量一次。
另有一笔一次性的开销：建 JSContext 并执行 530 KB 脚本（`WebLogic.loadSeconds`，测试里打印）。

## 往提示词拼装（engine.js、context/*）延伸：判断

- `engine.js` 与 `context/index.js` 的传递闭包同样是 **267 个模块、2.8 MB**，连 `vendor/preact-htm.mjs` 都被带进来。
  闭包里用到 `document` 的 38 个文件、`setTimeout` 35 个、`window` 26 个、`fetch` 25 个、`localStorage` 16 个
  （大多在函数里或带 `typeof` 守卫）；顶层有语句的 22 个模块，几乎都有守卫。
- 44 个上下文区块里 21 个直接 import `db/index.js`。区块是同步的 `build(ctx)`，直接读
  `characters.get`、`lorebooks.all`、`settings.get`、`memories.where`，少数还会写（`lorebooks.update`、`memories.update`、`characters.update`）。
  **本试点「在边界上切断、其余全是存根」的做法对拼装行不通**：几乎每一块都要读库。
- 有利的一点：网页版的数据层（`db/collection.js`）是同步的内存缓存，启动时一次 `load()`；
  原生库（`Store/Database.swift`）本来就是一行一条、原样存网页版的 JSON。
  所以可行的路是**在存储那一层换替身**：`db/idb.js` 换成从原生库灌进来的内存表，写回走一个宿主函数；
  再给时间、定时器、`console` 各补一个最小替身。其余 260 多个模块原样打进包。
- `engine.js` 本身是网络、队列、流式、重试那一层，按原生规约第 10、15 条，请求次数与记账必须留在原生的 AI 服务里，
  **不搬**。要搬的是 `context/*` 与 `templates.js`、`layout.js` 这类拼字符串的部分。

结论：
- **回复解析：可行（go）。** 下一步是让 `materialize` 那一层（原生自己落库）认网页版全部的结果种类，再考虑切换。
- **提示词拼装：有条件可行（conditional go），但不是本试点的直接延伸。** 要先做第二个试点：
  存储层替身 + `context/index.js` 的 `assemble`，拿一份导入的真实备份对照原生 `ChatPrompt` 的输出。
  主要风险是包体（约 3 MB 脚本）、冷启动时执行这些脚本的时间、真机无 JIT 的速度，以及写回原生库的一致性（「数据不许丢」）。
- **engine.js 整个搬：不做（no-go）。**
