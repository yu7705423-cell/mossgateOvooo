# 试点二：提示词拼装用网页版的代码（JavaScriptCore）

接着 `docs/jscore-pilot.md`（回复解析）。目标：一对一聊天的请求不再由 `Prompt/ChatPrompt.swift` 逐段翻译着拼，
而是直接执行网页版 `engine.js` 的 `buildChatSystem` / `buildHistory`，连同它用到的全部区块（`context/*`，52 块）、
能力说明（`capabilities.js`）、条目排版（`layout.js`）、模板（`templates.js`、`tplparts.js`）。网页版加一块、改一句，
下一次编译自动带进来，原生不再落后。

**默认关，行为不变。** 开关在「设置 - 问题反馈 - 试验 - 提示词按网页版拼装」（存在原生自己的 native_meta，不进备份）。
开着时只换一对一聊天的回复（`ChatEngine.reply`）；拼装失败、本轮要把原图交给聊天模型时退回原生。通话、主动消息、群聊、线下照旧原生。

网页版提交：`500728ebd1`（`claude/mini-phone-architecture-tqzvig`，本地打包时）；CI 每次取那条分支的最新提交。

## 文件

| 文件 | 作用 |
|---|---|
| `scripts/sync-weblogic.mjs <网页版目录> prompt` | 打 `Resources/weblogic/prompt.bundle.js`（不进仓库，编译时现取现打） |
| `Resources/weblogic/prompt-host.js` | 手写：JSContext 缺的几样全局、存储替身、宿主接口 `weblogic.prompt.*`、`buildChat` |
| `Resources/weblogic/shims.js` | 模块表（两个试点共用），这次加了循环依赖时的 `live` 绑定 |
| `scripts/check-weblogic.mjs prompt` | Node 的 `vm`（与 JSContext 同条件）里拿 `Tests/Fixtures/data.json` 拼一次，核对、计时 |
| `Sources/Eira/Prompt/WebPrompt.swift` | 读原生库、灌表、调 `buildChat`、结果换成 `ChatPrompt.Built`；开关；`compare` 对照 |
| `Tests/Unit/WebPromptTests.swift` | 两份备份两边对照、去掉一轮、改了一条再拼、耗时；开关开着时发一条仍只打一次接口 |
| `Tests/Fixtures/webprompt-rich.json` | 网页版备份格式的手写数据：39 条消息、引用、转账、表情、译文、撤回、群聊、四类记忆、世界书 |

CI（build.yml、testflight.yml）：回复解析与提示词拼装各打各的，哪一个打不出来只记警告、删掉那一个包，不拦编译。

## 打包：黑名单，不是白名单

回复解析用的是白名单（22 个模块）。拼装不行：44 个区块里 21 个直接读库，几乎每一块都要读别的模块，白名单要逐个维护。
这里反过来：从入口（`engine.js`、`presets.js`、`db/schema.js`）走到的模块**全部原样打进来**，只有 `stub` 里的是存根：

- `vendor/preact-htm.mjs`、`src/lib.js`、图标、二维码：界面
- `ai/providers/index.js`、`ai/queue.js`、`ai/sse.js`：网络。请求、排队、记账留在原生 `AIService`（原生规约第 10、15 条）

结果（本地网页版 `500728ebd1`）：**259 个模块、6 个存根，3.6 MB（gzip 1.2 MB）**；CI 上网页版 `e7f20f3aa6` 是 271 个模块、3.9 MB。动态 import 一律不展开（包里有就给，没有就是被拒的 Promise）。
`engine.js` 里没导出、拼装要调的两个小函数（`scanTextOf`、`budgets`）由打包脚本的 `expose` 多挂一个 getter，代码本身不动、不抄。

打包时遇到的两件事：

1. **循环依赖。** 原来的转换把 `import { x } from` 写成加载时取一次值。拼装的闭包里循环依赖很多（db/index.js ↔ 各业务模块），
   对方还没执行到 `const x = …` 时一读就是 ReferenceError。现在写成 `let x = __wl.live(mod, 'x', v => { x = v; })`：
   对方执行完时补上。两个包都用这一套，回复解析的样本照旧全过。
2. **JSContext 没有的全局**：`console`（网页版每个区块的 catch 里都调 `console.error`，没有它整次拼装会抛出去）、
   `TextEncoder`（zip.js 顶层建一个）、`structuredClone`（kv 的默认值）、定时器（给了，从不触发，只记次数）。时间可以钉住：`Date.now()` 与 `new Date()` 读宿主给的「此刻」。

## 存储替身

替换的是最底下的 `db/idb.js`（IndexedDB），不是 `db/index.js`：网页版的 `db/index.js`、`collection.js`（内存镜像、二级索引、
`messagesOf` 的排序缓存、元模式那一位的 `characters.get`、预设的 `settings.within`）全是原样的。

- **读**：每拼一次之前，Swift 从 `Store/Database.swift` 读各数据域的原文（一行一条的 JSON，本来就是网页版的格式），
  拼成 JSON 数组交进去（`weblogic.prompt.table(name, json)`），kv 交 `settings`、`persona`、`layout`。
  JS 那边把每张表整表换进内存镜像（先删后放，版本号只增不减：`collection.load()` 会把桶的版本清零，条数相同、内容变了的会话会读到旧的排序缓存，
  `testSeesChangesBetweenBuilds` 与 check-weblogic 都测着这一条）。迁移不跑（`schemaVersion` 回网页版当前的 DATA_VERSION）。
- **消息**：这段会话最近 5000 条（`WebPrompt.chatRows`），同一角色的别的会话各最近 300 条（`otherChatRows`）。其余数据域整表交。
- **写**：一律不落盘，记进结果的 `writes`。在两份备份上只有一处：`avatar.markSeen` 写 `chats.seenAvatar`（「对方换了头像」只说一次）。
  这一处不回写的后果：开着试点时，换了头像那句每一轮都会出现。正式切换之前要把它接回原生（宿主函数，或原生自己在发送成功之后记）。
- **读过哪些数据域**（`touched`）：25 个（books、characters、chats、closet、collection、diaries、focuses、impressions、lorebooks、memories、
  messages、moments、personas、phoneChats、phones、scenes、smsThreads、songs、spaceItems、stickers、ties、todos、trips、userSched、wishes）。
  数据里开了更多功能时会更多，所以现在不按它裁。

## buildChat 做的事

照 `engine.js` 的 `streamReply` 拼上下文那一段依次调网页版的函数：取消息（去掉失败的、`excludeTurn` 那一轮）→ `presets.settingsFor`
→ `lorebook.activate` → `memory.recentOf` 与同步的 `memory.recall` → `presets.within(chat, buildChatSystem + buildHistory)`。
不在这里的（都是要调接口或等待的，和网页版没配这些接口时一样）：识图等待、`imagesFor`（原图由原生挂在 `AIMessage.images`，本轮有图就退回原生）、
向量检索（`queryVec` 为 null）、重排、天气与热点、排日程、身体状态、每日穿搭、关系底色。

## 结果

CI 编译 [42248105566](https://github.com/yu7705423-cell/mossgateOvooo/actions/runs/42248105566)（iPhone 17 Pro 模拟器，iOS 26.5，网页版 `e7f20f3aa6`），全部 729 项测试通过。

| | 数 |
|---|---|
| 包 | 271 个模块、6 个存根，3.9 MB（gzip 约 1.3 MB） |
| 建 JSContext 并执行三份脚本 | 116 ms（一次，之后常驻） |
| data.json 一次拼装 | Node 里约 2 ms（含灌表） |
| rich 加 2000 条消息、300 条记忆，每次（20 次平均） | **网页版 23.0 ms**：读库 6.7、灌表 5.0、换表 4.5、拼装 6.1；原生 ChatPrompt 85.4 ms |
| 灌表 | 2353 行、605 KB |

模拟器的 JavaScriptCore 有 JIT，真机没有；拼装那 6 ms 在真机上会慢几倍，读库与灌表（JSON.parse）受影响较小。预算 50 ms 在模拟器上没有超出。

两份备份上都没有构建失败的区块，没有调到存根，没有排定时器；拼装途中想写的只有 `put chats <会话>`（头像已看过）。

### 网页版与原生的差别（`WebPromptTests.testSameAsNative`）

- data.json：13 段对 13 段，聊天记录 4 条对 4 条、逐字相同，召回相同。**只有一段不同：`[可用的功能]`**（网页版列的能力比原生多：心愿、旅行、授予标识、外卖、改密码、骰子、备注、回应等）。
- rich：聊天记录 18 条对 18 条、逐字相同（引用、转账、表情、译文、撤回、时间戳、末尾的此刻与最近记下的），召回相同。
  不同的两段：`[可用的功能]`，以及网页版多出的 `[群聊「三人行」的最近消息]`（私聊与群聊互通，原生没有这一块）。

也就是说原生已经搬过来的部分与网页版一字不差，差的正好是原生还没做的功能。

## 什么挡着默认打开

1. **灌表的开销随整个库变大。** 现在每拼一次把除消息以外的全部数据域整表交一遍。小库几毫秒，大库（几千条记忆、论坛、联机群消息）
   会到几十上百毫秒，真机无 JIT 再慢几倍。要改成：JSContext 里的表常驻，原生写库时记脏（Database.put/delete 处加一个变更序号），
   每次只交变了的行。
2. **写不回去。** `avatar.markSeen` 之外，开了更多功能的数据上还会有别的写（论坛的 markCarried、召回的 markRecalled 在网页版是发送成功之后调，
   原生这边已经各有对应）。要在宿主那边把 `writes` 按数据域分：要落盘的写回原生库（「数据不许丢」），其余丢掉，并各加一条测试。
3. **原图、向量、重排、网络那几步** 还在原生。原图那一档现在直接退回原生；向量检索与重排原生本来也没有。
4. **真机速度。** 模拟器的 JavaScriptCore 有 JIT，真机 app 里没有。要从 TestFlight 包里「问题反馈 - 试验 - 测量一次拼装耗时」量一次。
5. **包体**：多 3.9 MB 脚本（压缩后约 1.3 MB），冷启动第一次拼装多一次建 JSContext 与执行脚本。可以在打包时去掉注释（大约省一半），或者按需懒加载。
6. **差异要有人过一遍。** 网页版拼的是网页版的行为，原生不认的标记（心愿、旅行……）模型会写出来，原生的回复解析与落库要先认得它们
   （回复解析那一个试点已经能解析，落库那一层 `materialize` 还没接）。在那之前切过去，模型会写出原生不会处理的标记。

## 切换的步骤

1. 先接写回（第 2 条）与常驻表、增量灌表（第 1 条），用 StressTests 的规模量。
2. 回复落库认网页版全部的结果种类（回复解析试点的下一步）。
3. TestFlight 上开着试点用一段时间，诊断里看 `webprompt-used` 的耗时与 `failed`。
4. 默认打开，原生 ChatPrompt 留作退路；再把通话、主动消息、群聊、线下逐个换过去（`engine.js` 里分别是 `buildCallSystem`、
   `streamReply` 的主动那一档、`buildGroupSystem` / `buildGroupHistory`、`buildSceneSystem` / `buildSceneHistory`，同一个宿主接口多几个入口）。

## 同一条路还能走的

打包、存储替身、宿主接口都是通用的，换个入口就是另一份包：

- **游戏规则**（UNO、斗地主之类的出牌判定、计分）：纯函数为主，几乎不读库，白名单就够，最容易。
- **记账**（`ledger.js`，34 KB）：读 `books`、`entries`，计算余额、预算、统计，同样用存储替身；写入多，要先把「写回原生」做好。
- **美化生成**（`skin-gen.js`）：输入输出都是字符串，白名单即可；原生那边接 `CssSkin.compile`。
- **记忆提取、总结的提示词**（`tasks/*`）：和本试点同一套拼装，网络留在原生。
