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
| relations | [{charId, label}] | |
| bonds | {根身份id 或 'root': {text, manual, at, sig}} | 关系底色 |
| states | {根身份id: {...}} | 现状块 |
| parentId | String? | 不为空表示是那个角色的小号 |
| isNpc, star, pinned | Bool | |
| group | String | 分组，空串不分组 |
| tags | [String] | |
| archived | 毫秒 | 大于 0 表示已归档 |
| proactive / proactiveMinutes / proactiveQuietFrom / proactiveQuietTo | Bool 60 0 8 | 主动发消息 |
| voiceIds | {语音接口id: String} | |

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

群聊另有：admins、nicks、mutes、muteAll、groupProactive。上下文长度、记忆、模板**不按会话存**，都在 settings 里，
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

主要 kind 与附加字段：

| kind | 附加字段 |
|---|---|
| text | — |
| image | imageId（生成中为空）、prompt、media、vision、imageDesc |
| voice | audioId（文件，可空）、seconds、voiceText、asr |
| sticker | stickerId、stickerName |
| file | fileId、name、ext、size、text |
| clip | clipId（文件）、posterId（图片）、clipDur、prompt |
| transfer / request / gift / takeout | amount、note、currency 与各自的状态字段 |
| location | place、address |
| dice | faces、value |
| call | direction、outcome、seconds、callKind、callLog |
| narration | narration |
| silence | content 为 `[不回复]` |
| notice | 居中提示，靠 settledId、pat、wishId 等字段区分 |

其余 kind（listen watch read excerpt song xhs tool card forward moshare award acquire outfit groom closetshare
dresscode slip mallitem mallshot forumpost boxslip boxdraw boxreveal dreamcard quiz quizask game scene side）
见网页版 `apps/chat/pages/Conversation.js` 的渲染分派。

**图片 id**：imageId posterId mallSnap.imageId forward.items[].imageId share.images[]
**文件 id**：audioId clipId fileId callLog[].audio[]

## 4. personas 与 kv persona

personas 是「我」的身份树：parentId 为空是大号，否则是小号。当前身份是 settings.activePersonaId。

| 字段 | 说明 |
|---|---|
| name | 缺省 `新账号` |
| parentId | |
| avatar, cover, avatarBase | 图片 id |
| signature, description | |
| gender, age, birthday | |
| sections | {personality, likes, habits, triggers, life} |
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
