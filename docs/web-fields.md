# 网页版数据字段参考

原生版导入的数据全部来自网页版，字段名、默认值以网页版为准。本文整理自网页版 `src/system/` 的代码（2026-10-13），
路径都相对于网页版的 `src/system/`。网页版改了字段，以那边的代码为准，再回来更新这里。

记录没有固定结构，几乎每个字段都可能缺，**读的时候按这里写的默认值补**。
网页版的默认值写法：`x !== false` 表示缺省为真，`x === true` 表示缺省为假。

## 0. 通用

- 每条记录都有 `id`、`createdAt`、`updatedAt`（毫秒时间戳），由 `db/collection.js` 的 `create` 补上；调用方可以覆盖 `createdAt`。
- `update` 是浅合并并更新 `updatedAt`；嵌套对象一律整个替换。
- id 写法：`前缀_时间36进制+随机6位`（`store.js`）。前缀：characters `char`、chats `chat`、messages `msg`、
  personas `me`、memories `mem`、lorebooks `lb`，世界书条目 `e`。
- kv 键：`settings`、`persona`、`layout`、`schemaVersion`。数据结构版本 `DATA_VERSION` = 12。
- 图片记录 `{id:'img_…', blob, w, h, bytes, createdAt, orig?}`；文件记录 `{id:'f_…', blob, name, type, bytes, createdAt}`。
- 开机时删除 `kind === 'typing'` 的消息（流式占位，不该留在库里）。

## 1. characters

公开字段与私有字段的完整名单在 `hubfields.js`（`PUBLIC`、`PUBLIC_IMAGES`、`PRIVATE`）。

| 字段 | 类型 | 说明 |
|---|---|---|
| name | String | 缺省 `新角色` |
| signature | String | 一句话签名，列表里只显示它 |
| persona / scenario / firstMessage / exampleDialogue / core | String | 人设正文，只在编辑页出现 |
| age, gender, birthday, appearance | String | 自由文本；gender 进提示词的性别锚点 |
| timezone | String | IANA 时区，空串跟用户 |
| region | String | 城市，天气用 |
| avatar, portrait, cover | 图片 id | |
| lorebookIds | [String] | 挂的世界书 |
| remark | String | 用户给角色的备注名 |
| relations | [{charId, label, circle}] | label 是「对方是我的什么」，两边各写一条；circle 是这一方自己的圈子分法，空串未分组（card.js，4.593）。指向已删除角色的读时滤掉 |
| nick | String | 网名 |
| altReason, altOpenedAt, altDisclosed | String 毫秒 Bool | 角色自己开的小号：理由、开设时间、是否已承认（4.305） |
| nowPlaying | {kind:'recent'/'often', at, songs:[{title, artist}]} | 在听的歌，近况页读 |
| loreEntries | {"书id:条目id": Bool} | 只对这个角色开关某一条世界书条目；没记跟着条目的 enabled |
| bonds | {根身份id 或 'root': {text, manual, at, sig}} | 关系底色 |
| states | {根身份id: {...}} | 现状块 |
| parentId | String? | 不为空表示是那个角色的小号 |
| isNpc, star, pinned | Bool | |
| group | String | 分组，空串不分组 |
| tags | [String] | |
| archived | 毫秒 | 大于 0 表示已归档 |
| proactive / proactiveMinutes / proactiveQuietFrom / proactiveQuietTo | Bool 60 0 8 | 主动发消息 |
| voiceIds | {语音接口id: String} | |
| nick | String | 网名（4.687、4.947），缺省空串；角色可以自己改（[改网名：…]，新功能 selfnick） |
| chatApiId | String | 这个角色回复用的那一套聊天接口（4.828），空串跟随主用；不公开 |
| featOpt | {新功能id: 'on' 'off'} | 这个角色自己对新功能的选择（4.882），没有这一项跟随全局 featureOpt |

能力开关（`ai/capabilities.js` 读）：
- 缺省为真：canCall canChangeLock canDice canListen canPact canPat canRecall canReact canRemark canSendGift
  canSendImage canSendLocation canSendSticker canSendVoice canTakeout canTransfer
- 缺省为假：canSilence canSendFile

另有大量自动任务的开关与「上次试过 / 上次出错」时间戳（diaryAuto、diaryAutoAt、diaryAutoError……），用到时再查 hubfields.js。

**图片 id 字段**：avatar cover portrait faceImage callImage avatarBase faceImages[] avatarPool[].imageId highlights[].imageId shelf[].cover

## 2. chats

**没有 type 字段。** `group === true` 或 `characterIds.length > 1` 是群聊（`group.js`）。
短信不在这里，在 `smsThreads`，消息仍在 messages 里，chatId 是那一段短信的 id。
一个（身份，角色）只有一段单聊（`apps/chat/helpers.js` 的 chatFor）。

| 字段 | 类型 | 说明 |
|---|---|---|
| characterIds | [String] | 成员 |
| group | Bool | |
| personaId | String | 这段会话属于哪个身份 |
| title | String | 群名 |
| lastMessageAt | 毫秒 | 几乎每次发送后更新 |
| unread | Int | |
| summary | String | 历史摘要 |
| pinned, muted | Bool | |
| avatar | 图片 id | 群头像 |
| presetId | String | 预设，空串是全局 |
| skinId | String | 美化 |
| look | {bg: 图片id, ...} | 聊天外观 |
| innerMode | 'off' 'inline' 'apart' | 心声 |
| narration, userNarration | Bool | 旁白 |
| translateTo | String | 空串不翻译 |
| paceMode | 'manual' 'now' 'paced' | 回复节奏 |
| faces | {charId 或 'me': 图片id} | 本会话里的头像 |
| memoryUpTo / memoryUpToAt / memoryTriedId / memoryTriedAt | | 记忆整理的进度 |

状态栏：`statusBar.{online,offline}` 为 `{on, carry, at, items, fold:false, folded:true, brief:'', css:''}`（4.399、4.802、4.857）；
最大高度在 `look.status.{online,offline}.mh`（40 到 1200，不填不限）。原生版只读写 online，css 原样留着。

群聊另有：admins、nicks、mutes、muteAll、groupProactive；
charLeave（Bool，缺省假，角色可以自行退群，4.733）、groupMode（'member' 'watch' 'voice'，缺省 member，4.1018）、
groupAmbient（{page: false, pageMin: 3, perOpen: 10}，本群页面打开时接着聊，4.1018）。上下文长度、记忆、模板**不按会话存**，都在 settings 里，
会话只能选一份预设（presetId）叠在 settings 上。

## 3. messages

按 chatId 查，按 createdAt 升序排。

| 字段 | 类型 | 说明 |
|---|---|---|
| chatId | String | |
| role | 'user' 'char' | 只有这两种。居中的系统提示也是二者之一 |
| authorId | 'me' 或角色 id | 群聊里是说话的成员 |
| kind | String | 缺省 text，见下 |
| content | String | **模型读到的那一份**。结构化消息存方括号标记，如 `[图片：…]` |
| status | 'done' 'error' | error 时另有 error、failedPresets |
| turnId | String | 同一轮生成的几条共用；重新生成换掉整轮 |
| raw, think, swipes, swipeIndex | | 只在一轮的第一条上 |
| quoteId, quoteText, quoteRole, quoteAuthorId | | 引用 |
| recalled | {at, by, seen?} | 撤回，不是删除 |
| reactions | [{e, by, at}] | 回应 |
| translation, inner, innerTrans | String | 翻译与心声 |
| readAt | 毫秒 | 已读 |
| fav, favAt | Bool, 毫秒 | 收藏（4.853）。取消时写 false 与 0，不另存一份 |
| forward | {title, from, count, items: [{who, mine, kind, text, at, imageId?, stickerId?, face?, trans?}]} | 转发的记录；stickerId、face 为 4.937 起，trans 为译文 |

主要 kind 与附加字段：

| kind | 附加字段 |
|---|---|
| text | — |
| image | imageId（生成中为空）、prompt、media、vision、imageDesc；imageVers（[图片 id]，各版按先后，4.861，缺省只有 imageId 那一张）；角色的文字改成的文字图 media 为 text、prompt 为空、原文在 textBefore（4.799） |
| voice | audioId（文件，可空）、seconds、voiceText、asr；由「改为语音」改过来的带 textBefore（4.881） |
| sticker | stickerId、stickerName |
| file | fileId、name、ext、size、text |
| clip | clipId（文件）、posterId（图片）、clipDur、prompt |
| transfer / request / gift / takeout | amount、note、currency 与各自的状态字段；群里的转账另有 to（角色 id 或 me）、toName（4.736） |
| redpacket | rp：{type luck/equal/only, total, count, shares[], claims[{who, amount, at}], to, note, currency}（4.736） |
| location | place、address |
| dice | faces、value |
| call | direction、outcome、seconds、callKind、callLog |
| narration | narration |
| silence | content 为 `[不回复]` |
| notice | 居中提示，靠 settledId、pat、wishId 等字段区分；领红包那一行带 rpOf，改网名那一行带 nickUndo {charId, prev}，退群那一行带 groupUndo {chatId, prev} |
| voiceover | 画外音（4.1018）：content `[画外音：…]`，voiceover 是那一句 |

其余 kind（listen watch read excerpt song xhs tool card forward moshare award acquire outfit groom closetshare
dresscode slip mallitem mallshot forumpost boxslip boxdraw boxreveal dreamcard quiz quizask game scene side）
见网页版 `apps/chat/pages/Conversation.js` 的渲染分派。

**图片 id**：imageId imageVers[] posterId mallSnap.imageId forward.items[].imageId share.images[]
**文件 id**：audioId clipId fileId callLog[].audio[]

## 4. personas 与 kv persona

personas 是「我」的身份树：parentId 为空是大号，否则是小号。当前身份是 settings.activePersonaId。

| 字段 | 说明 |
|---|---|
| name | 缺省 `新账号` |
| parentId | |
| avatar, cover, avatarBase | 图片 id |
| signature, description | |
| gender, age, birthday | birthday 可写 `3月14日` 或 `1999-03-14`，写进「对方是谁」，带年份时另写 Age（4.775） |
| nick, city | 网名（4.687）、所在城市（4.776），填了才写进「对方是谁」 |
| sections | {personality, likes, habits, triggers, life}。「基础资料」就是 description（selfprofile.js，4.347） |
| charNotes | [{id, charId, kind:'exp'/'imp', text, vis, visIds, at}] |

kv persona 是迁移 2 之前的单一身份，现在只作回落：`{name:'我', avatar, cover, signature, gender, description}`。

## 5. memories

| 字段 | 说明 |
|---|---|
| charId | 属于哪个角色。空串是老的「全局」记忆，**不注入** |
| personaId | 属于哪个身份，按根账号隔离 |
| scopeChat | 只在这段群聊里有效。没有 chatId 字段 |
| content | 第三人称陈述 |
| kind | event fact open。老记录没有，按 category 推：pending 是 open；emotion relation event 是 event；其余 fact |
| category | fact emotion pending pattern relation profile event |
| rank | S（压进关系底色，不逐条注入）A（长期，按话题召回）B（要关键词）C（只存档） |
| keywords | [String] |
| at | 发生时间，缺省 createdAt |
| status | open done dropped，只对 open。老数据 content 含「已完结」算 done |
| dueAt, doneAt, result | 待办类的到期日、完成时间、结果 |
| validTo | 事实失效的时间，0 表示仍然成立 |
| supersededBy, replaces | 被新记录取代 |
| slot | occupation location birthday school family contact |
| weight | 0 到 2 |
| pinned / taboo | 永远在上下文里；taboo 表示角色不许主动提 |
| source | auto manual import fate link mall |
| vec, vecModel, vecAt | 向量。备份里是 `{"__f32": base64}`，也可能是数组或 `{"0":…}` |
| useCount, lastUsedAt | 召回强度 |
| fateHidden | 被命运线藏起，不注入 |

可见性（`context/memory.js` 的 listFor）：charId 不为空且属于这个角色（含小号，除非 altShare === false）、
没有 fateHidden、scopeChat 符合、身份根账号相同。

## 6. lorebooks

书：name、description、global（对所有角色生效）、forImage forVoice forMemory forForum（用途，最多一个为真，都没有是 chat）、entries。

条目：

| 字段 | 缺省 | 说明 |
|---|---|---|
| comment | '' | 标题 |
| keys | [] | 任一命中即可，子串匹配 |
| secondaryKeys | [] | 不为空时还要再命中其中一个 |
| content | | 原样注入 |
| enabled | true | |
| constant | false | 常驻 |
| caseSensitive | false | |
| probability | 100 | 命中后再按概率 |
| priority | 100 | 大的在前 |
| order | 0 | 同优先级按它升序 |
| part | before | before / after：角色卡前或后 |
| depth | 0 | 0 在系统区；N 插在倒数第 N 条历史之前 |
| type | | 'card' 是网页卡片，不当世界书注入 |
| position | | 老字段：system 换成 before，其余换成 after，depth 0 |

排序：before 在前 → depth 大的在前 → priority 降序 → order 升序。
chat 用途的世界书预算是 contextBudget 的 40%（0 不限）。扫描最近 scanWindow 条消息。

## 7. settings 里与接口有关的部分

读设置是 `{...DEFAULT_SETTINGS, ...存的}`，只有 promptTemplates 多合并一层。嵌套对象不深合并。

`services.chat`：`{presets: [ChatPreset], activeId, fallbackId}`。activeId 是主用，fallbackId 是副用；
activeId 为 null 表示用户关了主用，没写取第一套。

ChatPreset：`{id:'svc…', name, provider:'anthropic'|'openai', baseUrl, apiKey, model, siteUrl, topupUrl,
effort, temperature:0.9, midSystem?, recentModels?}`。effort 只有 anthropic 用，temperature 只有 openai 发。
填了 apiKey 与 model 才算能用。

其余服务：image video voice embed rerank vision asr memory translate search endpoints netease books mcp qweather，
各自形状见网页版 `ai/services.js` 的 EMPTY_SERVICES。memory 与 translate 的 mode 为 'api' 且填全了才用，否则跟副用。

挑接口（`ai/engine.js` 的 presetFor）：
1. `taskRoutes[任务组]` 指定了且填全了，用它；
2. chat.reply chat.call scene.write 走主用，没有走副用；
3. memory.extract memory.bond memory.import link.tidy chat.summarize scene.summary work.summary 走记忆接口；
4. 其余走副用，没有走主用。

花钱的旋钮：retryMax 0（钳在 0 到 3）、chatFallback false、failoverMax 1（0 表示全试）、streamIdleSec 120、
streamMode 'stream'、promptCache true、taskMaxTokens 0。

请求格式（`ai/providers/`）：

| | Anthropic | OpenAI 兼容 |
|---|---|---|
| 地址 | `{baseUrl 或 https://api.anthropic.com}/v1/messages` | baseUrl 缺省 `https://api.openai.com/v1`，以 `/vN` 结尾补 `/chat/completions`，否则补 `/v1/chat/completions` |
| 头 | x-api-key、anthropic-version: 2023-06-01 | authorization: Bearer |
| 体 | max_tokens 必填（0 换成 32000）、system 字符串或带 cache_control 的数组、output_config.effort，不发 temperature | system 作为第一条消息、max_tokens 大于 0 才发、temperature |
| 流式 | content_block_delta 的 text_delta；stop_reason 为 refusal 报错；message_stop 结束 | choices[0].delta.content；[DONE] 或 finish_reason 结束 |

历史中段的 system 消息改成 `<context>\n…\n</context>` 包起来的 user，再把相邻同角色的并成一条（`midsystem.js`）。
Anthropic 一律这样，OpenAI 除非 midSystem 为 'system'。输出去掉 `<think>` `<thinking>` `<thought>` 段。

提示词预设：settings.presets `[{id, name, data}]`，会话的 presetId 选一份叠在 settings 上，叠的键见 `presets.js` 的 KEYS：
promptLayout promptCustom promptTemplates injectOrder msgMin msgMax smsMin smsMax narrationMin synopsisMin synopsisMax
historyMode historyLimit historyTurns scanWindow contextBudget promptLean。

## 8. 聊天界面的几项设置与记号

| 在哪儿 | 字段 | 说明 |
|---|---|---|
| settings | panelOrder, panelMore | 加号面板的先后与收进「更多」的几格（panel.js）。没设过取默认 |
| settings | msgMenuOrder | 长按消息那几格的先后（menuorder.js 的 MSG_ITEMS，三十个 id）。读时丢掉不认识的、补上缺的；恢复默认写 null |
| settings | convMenuOrder | 会话菜单分组的先后（menuorder.js 的 CONV_GROUPS，十一个 id）。读法同 msgMenuOrder；原生版没有的 scene、display 两组位置不动 |
| settings | callKit | 系统来电界面（4.895），默认 false。原生版 SystemCall 读同一个键 |
| settings | iosWidgetChar | iPhone 桌面组件「角色此刻」显示的角色 id（4.941），空为自动 |
| settings | bgPush.channel.kind | 通知通道：'' / bark / pushplus / eira。网页版的 eira 登记存在 `bgPush.channel.eira`；原生版的登记只记在本机（EiraPush，不进设置、不进备份），`channel.eira` 原样留着不读 |
| stickers | myUsedAt | 毫秒。自己从表情面板点出去的最近一次（4.935「最近常用」）；useCount 另算，角色发的也算 |


## 9. todos 与 notes（待办 app）

待办（`todo.js`、`alarm.js`、`when.js`，ARCHITECTURE 4.104d 到 4.104i、4.326）。id 前缀 `td`，没有查询字段（整域读出来筛）。

| 字段 | 缺省 | 说明 |
|---|---|---|
| text | | 要做的事，原话 |
| state | | pending（等确认）open（已计入）done drop（忽略，留着免得再问） |
| from | | 来源：local（对话中识别）char（角色提出）manual（手动）collect（收藏馆）fit（起居）。**每周重复的待办把开始日期也写在这一栏**（`'YYYY-MM-DD'`，我的日程那边建的会覆盖来源）；原生版只把形如日期的当开始日期 |
| chatId, charId, srcMsgId | '' | 从哪段对话、哪个角色、哪条消息来的 |
| dueAt | '' | 哪天做，`'YYYY-MM-DD'` |
| time | '' | 几点做 `HH:MM`，与提醒时刻无关 |
| remindAt | 0 | 提醒时刻（毫秒），也可能是空串 |
| whenText | | 提醒时刻输入框里的原话（「明天七点」） |
| alarmId, alarmAt | '', 0 | 排进系统的编号与排出去的时刻；两者对不上就是改过没重排。AlarmKit 的编号是按待办 id 散出来的 UUID（网页版外壳与原生版同一种散法），原生版退回本地通知时是 `todo-<id>` |
| rungAt | 0 | 应用开着时已经提醒过 |
| doneAt | 0 | 完成时刻 |
| repeat, weekdays | '', [] | `weekly` 加周几（1 到 7，周一为 1）为每周重复 |
| doneDates | [] | 每周重复的每一天各自完成，记日期；只留最近 400 个 |
| fitSched 等 | | 起居、收藏馆自己挂的记号，原样留着 |

设置：`todoDetect` true、`todoCues` / `todoSkips` null（用 todo.js 里的默认那份；空数组等于关掉本地识别）、`planCount` 8（注入几条「你记着的事」，0 为全给）。
能力 `todo`（角色卡 `canTodo !== false`，`capsOff` 可全局关）与区块 `plan` 都在新功能规矩定下之前就有（基线）。

备忘 `notes`：id 前缀 `nt`。`text`、`from`（manual / chat，长按消息存下来的是 chat）、`chatId`、`charId`、`createdAt`、`updatedAt`。按 updatedAt 倒序列出。

## 10. 新功能、角色截图、元模式与场外

| 在哪儿 | 字段 | 说明 |
|---|---|---|
| settings | featureOpt | {功能 id: 'on' / 'off'}，没有就是还没问过、不注入（newfeat.js） |
| characters | featOpt | {功能 id: 'on' / 'off'}，这个角色自己选的；没有跟随全局（4.882） |
| phones | photos[].kind / msgs / shotId / chatId | kind 'shot' 是角色截下的聊天记录（4.904）：msgs 是冻起来的消息副本（role 两边对调，角色自己的是 user），_name、_avatar 是当时的名字与头像 |
| shots | id、css | 截图与卡片那一刻的美化 CSS。id 是 SHA-256 的前 12 字节（十六进制），同样内容共用一份 |
| messages | kind 'charshot'、shot {msgs, shotId, note} | 角色发进聊天的截图，正文 `[聊天截图：说明]` |
| chats | meta, metaName, metaSystem, metaPresetId, metaBooks, metaCaps {sticker, image, voice}, metaVoiceId, metaApiId, metaTime, metaGap, metaSplit, metaMemory | 元模式（4.817、4.832）。chat_meta / char_meta 是最早那一个，之后的 chat_meta_xxx 对应 char_meta_xxx；元不在 characters 里。原生版不读 metaCaps.image / voice、metaVoiceId、metaMemory，原样留着 |
| settings | metaPlace | 'group'（默认，单独一组）或 'mix'（融入消息列表） |
| lorebooks | metaFor | 这一本是哪个元自己的那一本（存为世界书时建） |
| chats | ooc {on, trigger:'ooc', visible, style:'auto', customReview, customCheck, check, checkMode:'mark', rewriteMax:1, bookId} | 场外（4.819）。全部默认关 |
| messages | kind 'ooc' | 场外的问与答，不进记忆；visible 时以 [场外：…] / [场外回复：…] 进历史 |
| messages（这一轮第一条） | oocCheck 'tried' / 'ok' / 'issues' / 'failed', oocIssues [{card, reply, fix}], oocError, oocDismissed | 自动检查的结果。先写 tried 再发 |
| lorebooks | oocFor | 角色 id：这一本是那个角色的纠偏书（花园公开包不带） |
| chats | theater {mode:'inline', gen:'free', cardName:'', inject:'text', style:'', words:0, frame:'', bgm:true, bgmAuto:true} | 小剧场的会话设置（4.769、4.862）。separate 为打开时生成 |
| messages | kind 'theater'、theater {title, brief, html, inject, acts[], gen, card {name, values}, bgm} | 小剧场。content 是上下文里的写法（theater.promptOf）。html 为空是封面。原生版背景音乐只记歌名（bgmQuery），网页版的 bgm 原样留着 |
| messages | kind 'tool'、toolName、toolTitle、toolServerId、toolArgs {}、toolState ask/running/done/error/denied、toolResult、toolError、toolAt | 调用 MCP 工具（4.179）。content `[调用：名字 {参数}]`；历史里跟一条 `[工具结果：名字]` |
| settings.services | mcp.servers [{id, name, url, headers, authName, authValue, timeout:60, approve:'ask', toolsOff[], tools[], info, gen, version, checkedAt, error, viaRelay}] | MCP 服务器（4.179、4.973）。令牌与请求头同接口密钥一样处理。原生版不经转发站，viaRelay 原样留着 |
| characters | mcpServers [] | 这个角色能用哪几台服务器 |
| settings | mcpFollowUp false, mcpFollowMax 1, mcpResultChars 4000 | 工具结果回来后接着回复（默认关，登记为额外调用）、最多几轮、结果给角色读多少字 |
| messages | kind 'meet'、meet {place, state 'pending'/'here'/'page'/'declined', sceneId} | 角色提出见面（4.721）。不去时另落一条 kind 'notice'、meetNo、`[未答应见面]` |
| scenes | words 0 | 这一场的篇幅（4.690），0 用 settings.sceneWords |

## 11. impressions（角色眼中的你，4.346）

按 charId 查。一行一种，kind 分：

| kind | 字段 |
|---|---|
| imp | charId, personaId, text, voice, evidence:[{msgId, chatId, at, day, quote}], against（同上）, state 'kept'/'dropped', droppedAt, seenAt（null 为新）, mergedAt, mergedTo:{personaId, key, charId} |
| note | charId, personaId, text, evidence:[一条], usedAt（整理时用掉） |
| draft | charId, personaId, fresh:[{text, voice, evidence}], support / against:[{id, evidence}], noteIds, upTo。同一个角色 × 账号一份 |
| mark | charId, personaId, upTo（整理读到的最后一条消息的时间）, at |
| groups | charId 为空串，personaId, groups:[{ids, text}], basis（对照时的全部印象 id）, at |

强度按依据的不同日子数：settings.impressSeen 缺省 2、impressSure 缺省 5；整理最多读 settings.impressLines 缺省 400 条（0 为全部）。

## 12. 角色包 character.json（charpack.js，4.116）

zip 只存不压：`character.json` 加 `images/<id>.<ext>`、`files/<id>.<ext>`。
`{_format:'mini-phone-character', _version:2, _data, _history, exportedAt, character, alts, lorebooks, memories（向量 {__f32}）, chats, messages,
scenes, works, chapters, beats, trips, spaceItems, skins, days, meals, health, phones, phoneChats, moments, reviews, readnotes, todos, playlists,
songs, closet, wishes, ties, smsThreads, diaries, dreams, memsnaps, dramas, drafts, impressions, collection, mallPeople, mallItems, pets, cams,
camLogs, quizRuns, boxes, slips, slipLog}`。群聊与只在群里生效的记忆不带；印象只带 imp 与 note。

## 13. books 与 entries（记账，`ledger.js`，ARCHITECTURE 4.278、4.642、4.643、4.961）

原生版读写经 `Prompt/Ledger.swift`。**余额不入库**：一律由流水现算；聊天里的转账、外卖、情侣账户的存入与动用也不另存流水，
每次从消息现算（`chatEntries`，id 写成 `msg:<消息id>:<me|char|joint>`，src 为 message）。

books（id 前缀 `bk`，没有查询字段）：

| 字段 | 缺省 | 说明 |
|---|---|---|
| name | | 空着建时写「我的账本」（真实）或「未命名账本」 |
| kind | play | real（真实账本）/ play（虚拟账本）。两种功能完全一样，只是标签 |
| chatId | '' | 关联的对话（单聊）。关联了就有角色的钱包（owner char，名字是角色名） |
| currency | 建时的 settings.currency | 这本账的币种；没有记的按设置里那一种 |
| personaId | 建时的账号（isolate.tagNow） | 账号隔离用。关联了对话的按那段会话的账号算 |
| accounts | [] | `[{id:'ac…', name, owner:'me'/'char'/'joint', secret:false, pass:'', hint:'', unlocked:false, kind:''/'transit'}]`。私密账户锁着时不计入合计、任何时候不进提示词 |
| cards | [] | 亲属卡 `[{id:'cd…', from, to, limit, active:true, at}]`，同一个方向只留一张。用掉多少不入库，按时间顺序扫消息现算 |
| rules | [] | 固定入账 `[{id:'rl…', accountId, day 1 到 31, amount（带符号）, category, note, active:true, by:''/'ai', from（建立时刻，不补此前）}]` |
| inject | true（`!== false`） | 把余额告诉角色（区块 bill，`[你的钱]`） |
| strict | true（`!== false`） | 余额不足时不予支付（角色的转账、请客、外卖、存入先核对；角色的钱没生成时不拦） |
| settle | false | 排新一天日程时结算角色前一天的花销（src day，ref `角色id@日期#i项目id` / `#m餐次`） |
| charMoney | null | 按角色卡生成的那份说明 `{summary, balance, income:[{day, amount, note}], expenses, at}`（ai/tasks/money.js） |

entries（id 前缀 `en`，按 bookId 查）：`bookId, accountId, amount（正数进账、负数出账，按币种收位数）, category（大类 id）, sub（小类 id，可空）,
note, at（毫秒）, src（manual / seed 起始余额 / rule 固定入账 / day 日程结算 / move 账户间挪钱 / 其余如 chat 对话里提取）, pending（待确认，不计入）,
ref（rule 是 `规则id@YYYY-MM-DD`，move 两笔同一个 ref）, tripId（属于哪一次出行）`。seed、rule、day 的那几笔没有 sub、tripId。
src 为 move 的余额照算，收支与构成不算。

settings：`billBook`（当前看的那一本，'' 为第一本看得见的）、`ledgerCats`（`{tops:[{id:'u…', label, subs:[{id, label}]}], subs:{大类id:[{id, label}]}}`，
自定义分类所有账本共用；名字最多 8 个字）、`currency`（CNY）、`rates`（`{'CNY>JPY': 20.5}`，一对只存一个方向）。

personas：`isolate {moments, friends, wallet, album}`（4.960、4.961）：wallet 为真时只看这个账号下建的账本；friends 为真时卡包里列出的角色只限好友列表里的。
原生版只读，开关与新账号的默认值随账号之间隔离一起做。

## 14. 申请与卡包里的消息（`request.js`、`funcard.js`、`pass.js`、`ticket.js`、`member.js`、`idcard.js`，4.278、4.611、4.643、4.644）

卡就是消息：状态全部从这些消息现算，不另存一份。处理过的那一行提示（kind notice）带 `settledId`、`settledKind`，删掉就回到没处理。

| kind | 字段 | 说明 |
|---|---|---|
| request | requestKind joint/spend/card/deposit, amount, note, request pending/approved/rejected, currency | 申请。存入发出即 approved。content `[开设情侣账户]`、`[申请：用途 金额]`、`[亲属卡：额度 金额]`、`[存入情侣账户：金额]`，表态后加「（已通过）」「（已驳回）」。提示行 settledKind 'request' |
| funcard | card {name, desc, uses（0 不限）, expiresAt（0 长期，截到那天最后一刻）, color, confirm}, cardImageId | 娱乐卡。role 是送出的一方，持有的是另一方。content `[送卡：名｜说明｜N 次｜YYYY-MM-DD 前有效｜使用需对方同意]` |
| funcard-use | cardMsgId, cardName, useState pending/done/declined | 用一次。要确认的先 pending。提示行 settledKind 'funcard' |
| pass | pass {kind door/key/room, name, place, note, tripId?, tripTitle?} | 门禁卡、钥匙、房卡。房卡挂着出行，出行结束算退房 |
| pass-act | passMsgId, passName, act use/revoke/grant | 刷卡、收回、恢复。最后一次 revoke / grant 定收没收回 |
| ticket | ticket {kind movie/show/match/other, title, at（毫秒，0 为未写）, venue, seat, note} | 票。过了开场那天的最后一刻还没检票算过期 |
| ticket-act | ticketMsgId, ticketTitle, act check | 检票 |
| member | member {shop, note} | 会员卡，两人共用，同一家店只开一张 |
| member-act | memberMsgId, memberShop, points, note | 消费一次 |

证件：`characters.idCard`、`personas.idCard`：`{kind work/student/other, org, title, no, dept}`，四项都空的不算有。不进提示词。
能力 joint 是基线；funcard、pass、ticket、member 是新功能（featureOpt，app 'wallet'，第一次打开卡包时问）。
