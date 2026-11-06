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
| `scripts/check-weblogic.mjs prompt [--raw 目录]` | Node 的 `vm`（与 JSContext 同条件）里拿三份备份拼、核对、计时；增量灌与整表灌结果相同；写回的字段；`--raw` 时对照去过注释与原样的两份包 |
| `scripts/jsstrip.mjs` | 打包时去注释与缩进（见「包体」） |
| `Sources/Eira/Prompt/WebPrompt.swift` | 调 `buildChat`、结果换成 `ChatPrompt.Built`；开关；`compare` 对照 |
| `Sources/Eira/Prompt/WebPromptFeed.swift` | 常驻表：第一次整表灌，之后按变更记录只交变了的行，消息按会话开窗 |
| `Sources/Eira/Prompt/WebPromptWrites.swift` | 拼装途中网页版的写，按字段写回原生库 |
| `Sources/Eira/Store/ChangeLog.swift` | 原生库的变更记录（`Database.changes`，put / delete / deleteAll / setKV 各记一笔，导入与清空时作废） |
| `Tests/Unit/WebPromptTests.swift` | 三份备份两边对照、去掉一轮、改了再拼、增量与整表相同、导入后整表重灌、写回、没写回时换回来、写回失败、耗时与内存；`ChangeLogTests`；开关开着时发一条仍只打一次接口、写回了头像已看过 |
| `Tests/Fixtures/webprompt-rich.json` | 网页版备份格式的手写数据：39 条消息、引用、转账、表情、译文、撤回、群聊、四类记忆、世界书 |
| `Tests/Fixtures/webprompt-avatar.json` | 我换了头像（`seenAvatar` 是旧的那张）、核心设定、会话与角色上的不认得的字段 |

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

## 存储替身与常驻表

替换的是最底下的 `db/idb.js`（IndexedDB），不是 `db/index.js`：网页版的 `db/index.js`、`collection.js`（内存镜像、二级索引、
`messagesOf` 的排序缓存、元模式那一位的 `characters.get`、预设的 `settings.within`）全是原样的。迁移不跑（`schemaVersion` 回网页版当前的 DATA_VERSION）。

**表常驻**（`WebPromptFeed`）。JSContext 第一次用时 `boot`（网页版的 `ready`，全是空表），之后网页版的内存镜像一直留着：

- **整表**：第一次、导入备份或清空全部数据之后（`ChangeLog` 作废）、换了一个库（测试里每个用例一份）、变更记录溢出（留 2 万笔）、
  上一次灌表或拼装途中脚本出错，都把除消息以外的全部数据域整表交一遍（`clearAll` + `replace`），kv 交 `settings`、`persona`、`layout`。
- **增量**：其余时候问 `Database.changes.since(上次)`，只交变了的行（`upsert` / `remove`），`deleteAll` 那种整批删的：消息拿掉那段会话，
  别的数据域整个重灌；kv 变了的那一个重新交（网页版的 `makeKV.load` 自己叠默认值，在 `buildChat` 开头等它读完）。
  变更记录在试点开关关着时（没人问过）只数序号、不留记录，不占内存。
- **消息开窗**：这段会话最近 5000 条（`WebPrompt.chatRows`），同一角色的别的会话各最近 300 条（`otherChatRows`），和从前每次现灌的一样：
  这一次用不到的会话从表里拿掉（`dropChat`），新来的消息超出条数时去掉最早的（`trimChat`），删了一条消息的会话整段重灌（窗口要往前补一条）。
- 版本号只增不减：换表用 `removeWhere` + `put`，不用 `collection.load()`（它把桶的版本清零，`messagesOf` 的排序缓存会认成没变）。

`testIncrementalSameAsFull`（改一条、加一条、删一条、整段删掉群聊、加记忆、改设置、改会话之后增量灌的结果与整表重灌逐字相同）
与 check-weblogic 都测着；`testImportRefeedsEverything` 测导入之后上一份的数据一行不留。

## 写回

拼装途中网页版的写，`prompt-host.js` 包在每个 collection 的 `update` / `put` / `create` / `remove` / `removeWhere` / `clear` 外面：
第一次碰一行之前记下它原来的样子，拼完和现在比，交回 `changes`：`patch`（改了的字段 `set`、去掉的 `unset`；原地改了看不出来的整行交、`whole`）、
`insert`、`delete`、`kv`（只交和原生库里那份不同的几项，没有的项和默认值比）、`mem`（`persist: false`，网页版本来不落盘）、
`other`（图片、文件这类原生另有一套的）、`clear`。

`WebPrompt.apply` 写回原生库：读原生库里**此刻**的那一行，只盖交来的几个字段，别的字段（原生自己的、不认得的、拼装期间原生刚写的）一个不动；
拼装期间已经删掉的行不复活。`mem`、`other`、`clear` 不写回。和网页版一样，拼装途中就写，不等请求成功（`engine.js` 在 `buildChatSystem` 里直接 `markSeen`）。
只有真正发请求的那条路（`replacing`）写回；测量、对照只拼不写。写过的行下一次一律照原生库重灌：写回了是同一份，没写回，表里改过的那份换回来。
写不进去的逐条摆到屏幕上（`Problems.report`，网页版第 20 条），这一轮照常发。

在三份备份上只有一处写：`avatar.markSeen` 的 `chats.seenAvatar`（加 `updatedAt`，同网页版的 `update`）。`testWritesGoBack`：换了头像的那一轮说一次
「[对方的头像]」，写回之后下一轮不再说，会话上不认得的字段与拼装之后原生刚改的字段都在；`WebPromptCostTests.testReplyAppliesWrites`：开着试点回复一轮，
仍只打一次接口，原生库里的 `seenAvatar` 写上了。

## buildChat 做的事

照 `engine.js` 的 `streamReply` 拼上下文那一段依次调网页版的函数：取消息（去掉失败的、`excludeTurn` 那一轮）→ `presets.settingsFor`
→ `lorebook.activate` → `memory.recentOf` 与同步的 `memory.recall` → `presets.within(chat, buildChatSystem + buildHistory)`。
不在这里的（都是要调接口或等待的，和网页版没配这些接口时一样）：识图等待、`imagesFor`（原图由原生挂在 `AIMessage.images`，本轮有图就退回原生）、
向量检索（`queryVec` 为 null）、重排、天气与热点、排日程、身体状态、每日穿搭、关系底色。

## 包体：去注释

`sync-weblogic` 默认把每个模块去掉注释与缩进（`scripts/jsstrip.mjs`，手写的词法扫描，无依赖）：字符串、模板字符串、正则原样照抄，
换行留着（不改自动分号插入），`/*!`、`@license`、`@preserve` 的注释留着。去之前后各做一次语法检查；再由 `check-weblogic --raw`
拿同一批样本（回复解析 89 条、提示词四份）对照去过的与原样的两份包，结果逐字相同才用去过的那一份，否则用原样的并报警告。
本机另用 acorn 解析了两份包，语法树（连字面量原文）完全相同。`--no-strip` 打原样的包。

| | 原样 | 去注释 | gzip |
|---|---|---|---|
| 提示词拼装（网页版 `9784477f43`，271 个模块） | 3.97 MB | **2.50 MB**（-37%） | 1.25 MB -> 0.71 MB（本地 `500728ebd1`） |
| 回复解析（22 个模块） | 542 KB | **306 KB**（-44%） | |

剩下的大半是提示词正文与界面字符串（模板字符串原样留着）。再往下要靠改名压缩，不做：出错时的调用栈与诊断就看不懂了。

## 结果

CI 编译 [42260966504](https://github.com/yu7705423-cell/mossgateOvooo/actions/runs/42260966504)（iPhone 模拟器，网页版 `9784477f43`），全部 781 项测试通过。

| | 数 |
|---|---|
| 建 JSContext 并执行三份脚本（去过注释） | 107 ms（从前 116 ms；一次，之后常驻） |
| 第一次拼装（含建 JSContext、整表灌 2353 行 605 KB） | 411 ms |
| rich 加 2000 条消息、300 条记忆，常驻、没有改动，每次（20 次平均） | **9.0 ms**：读库 0.1、灌表 0.1、拼装 8.0；每次交 1 行（上一轮写过的那一行） |
| 同上，每次多一条消息 | **9.4 ms**：读库 0.1、灌表 0.4、拼装 7.5；每次交 2 行 |
| 同上，每次整表重灌（从前的做法） | 23.0 ms：读库 6.3、灌表 10.1、拼装 5.5；每次交 2373 行 609 KB |
| 原生 ChatPrompt | 101.9 ms |
| 内存（phys_footprint） | 建 JSContext 并整表灌之后多 25 MB；再拼 60 次（其中 20 次整表重灌）之后共多 64 MB |

常驻之后每次的耗时几乎全在拼装本身。拼装那一段常驻时（8 ms）比整表重灌时（5.5 ms）慢一点，三组按顺序跑，整表那一组最后跑、JIT 最热，
多半是这个原因，没有单独量。内存那一行的 64 MB 里多半是整表重灌那 20 次留下的垃圾（JavaScriptCore 回收了也不一定还给系统），
只常驻、不整表重灌时涨多少还没单独量。

模拟器的 JavaScriptCore 有 JIT，真机没有；拼装那 8 ms 在真机上会慢几倍。读库、灌表常驻之后已经接近零，不再随库的大小变。

### 网页版与原生的差别（`WebPromptTests.testSameAsNative`，三份备份，共 8 处）

- data.json：13 段对 13 段，聊天记录 4 条对 4 条、逐字相同，召回相同。**只有一段不同：`[可用的功能]`**（网页版列的能力比原生多：心愿、旅行、授予标识、外卖、改密码、骰子、备注、回应等）。
- rich：聊天记录 18 条对 18 条、逐字相同（引用、转账、表情、译文、撤回、时间戳、末尾的此刻与最近记下的），召回相同。
  不同的两段：`[可用的功能]`，以及网页版多出的 `[群聊「三人行」的最近消息]`（私聊与群聊互通，原生没有这一块）。

- avatar（新加）：聊天记录 6 条对 6 条，设定区 12 段对 12 段。不同的：`[可用的功能]`，以及末尾第 5 条（对话末尾的易变区块）里网页版多一块
  `[对方的头像]`（我换了头像，原生没有这一块，也没有 `seenAvatar`）。核心设定、世界书、召回两边相同。

也就是说原生已经搬过来的部分与网页版一字不差，差的正好是原生还没做的功能。

## 什么挡着默认打开

已经解决的（本批）：灌表随库变大（常驻表、增量）、写不回去（写回原生库，按字段合并）、包体（去注释 -37%，冷启动 116 ms 到 107 ms）。

还挡着的：

1. **回复落库认不全网页版的结果种类。** 网页版拼的是网页版的行为，`[可用的功能]` 比原生多十来项（心愿、旅行、授予标识、外卖、改密码、骰子、备注、回应等），
   模型会写出原生的 `materialize` 不会处理的标记。回复解析那一个试点已经能解析，落库那一层没接。这是最大的一项。
2. **真机速度与内存。** 模拟器有 JIT。要从 TestFlight 包里「问题反馈 - 试验 - 测量一次拼装耗时」量：常驻之后每次多少、第一次多少、内存涨多少。
   第一次拼装 411 ms（模拟器）在真机上可能过一秒，可以在 app 启动后空闲时预热一次（建 JSContext 并整表灌，不发请求）。
3. **原图、向量、重排、网络那几步** 还在原生。原图那一档现在直接退回原生；向量检索与重排原生本来也没有。
4. **别的写。** 三份备份上只有 `seenAvatar` 一处；开了更多功能的数据上可能还有，写回的路已经通了，但每一处要有人看一遍网页版的意思，
   特别是 `delete`（现在照网页版删）。诊断里有 `webprompt-write-skipped`。

## 切换的步骤

1. 回复落库认网页版全部的结果种类（回复解析试点的下一步），或者在那之前用网页版的能力开关把原生不认的几项关掉。
2. TestFlight 上开着试点用一段时间，诊断里看 `webprompt-used`（`ms`、`full`、`writes`）与 `webprompt-failed`，真机量一次耗时与内存。
3. 默认打开，原生 ChatPrompt 留作退路（拼装失败自动退回）；再把通话、主动消息、群聊、线下逐个换过去（`engine.js` 里分别是 `buildCallSystem`、
   `streamReply` 的主动那一档、`buildGroupSystem` / `buildGroupHistory`、`buildSceneSystem` / `buildSceneHistory`，同一个宿主接口多几个入口）。

## 同一条路还能走的

打包、存储替身、宿主接口都是通用的，换个入口就是另一份包：

- **游戏规则**（UNO、斗地主之类的出牌判定、计分）：纯函数为主，几乎不读库，白名单就够，最容易。
- **记账**（`ledger.js`，34 KB）：读 `books`、`entries`，计算余额、预算、统计，同样用存储替身；写入多，要先把「写回原生」做好。
- **美化生成**（`skin-gen.js`）：输入输出都是字符串，白名单即可；原生那边接 `CssSkin.compile`。
- **记忆提取、总结的提示词**（`tasks/*`）：和本试点同一套拼装，网络留在原生。
