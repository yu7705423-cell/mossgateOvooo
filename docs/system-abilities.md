# 系统能力：系统来电、Eira 推送、桌面组件、系统闹钟

原生版照网页版 iPhone 外壳的做法（网页版 ARCHITECTURE 4.895、4.896、4.941、4.711、4.104e）补上的几样系统能力，
以及**只能由用户在苹果开发者网站、App Store Connect、网页版仓库里做的事**。

## 一、做了什么

| 能力 | 代码 | 开关 | 要签名版才有 |
|---|---|---|---|
| 系统来电界面（CallKit） | `App/SystemCall.swift`；`Prompt/Call.swift` 的 `CallEngine.ring`；`Views/CallView.swift` | 设置 - 消息通知 - 来电（`settings.callKit`，默认关） | 否（自签的包也能用） |
| Eira 推送（APNs 与 PushKit） | `App/EiraPush.swift`、`App/AppDelegate.swift`；`AI/BgPush.swift` 的 `channelOut`；通知扩展 `Sources/EiraNotify` | 设置 - 后台消息 - 通知通道 - 登记 | 是 |
| 桌面组件（WidgetKit） | `App/WidgetFeed.swift`；组件扩展 `Sources/EiraWidgets`；共用 `Sources/Shared` | 设置 - 主题 - iPhone 桌面组件（选角色） | 是（App Group） |
| 待办的系统闹钟（AlarmKit，iOS 26） | `App/SystemAlarm.swift`、`Prompt/TodoAlarm.swift` | 待办 - 系统提醒（对账页写明用的是哪一条路） | 否 |
| 通知上的头像（4.711） | `App/WidgetFeed.swift` 的 `FaceThumbs`、`Shared/NotifyFaces.swift` | 跟着通知 | 否 |

- **一次开口只扣一次钱照旧**：Eira 推送只改「结果怎样送到手机上」，消息仍由后台消息服务器那一次调用产生；交接规矩（`holdsProactive`）不变。
  选了 Eira 推送时，后台刷新不再问服务器、不再弹本地通知（服务器自己推送，不重复）。
- **来电推送**：服务器那边回复里有来电标记、通道的 `ring` 为真（应用里开着系统来电界面）、角色卡没关打电话（任务里带 `canCall`），
  发来电推送；手机上解开盒子报一通系统来电。苹果规定每条来电推送都必须马上报一通来电，解不开也报一通「来电」再马上收掉。
- **接起来之后**：打开那段会话，通话页直接接通（不响第二遍）。通话本身照旧在应用里按回合进行；停在锁屏或系统通话界面上时说话与听，原生版还没做（见「下一步」）。
- **登记记在本机**：推送地址、签名只对这一台手机这一只 app 有效，不进设置、不进备份；导入网页版备份不会带进别的设备的登记。
- **桌宠组件不做**：网页版还挂在测试版（4.942），原生版没有桌宠。

## 二、要你去点的（按顺序）

### 1. 苹果开发者网站（developer.apple.com → Certificates, Identifiers & Profiles → Identifiers）

1. 右上角下拉选 **App Groups**，看有没有 `group.cn.eiraphone.native`。没有就点「+」→ App Groups → Description 填 `Eiraowo`，Identifier 填 `group.cn.eiraphone.native` → Continue → Register。
2. 下拉换回 **App IDs**，点 `cn.eiraphone.native`：
   - 勾 **App Groups** → 点右边 Configure → 勾 `group.cn.eiraphone.native` → Continue；
   - 确认 **Push Notifications** 与 **HealthKit** 已勾（工作流的 `scripts/asc.py` 会自动勾，没勾上就手动勾；Push Notifications 不用另配证书，推送转发用的是 .p8 密钥）；
   - 右上角 Save，弹出「会让描述文件失效」点 Confirm（工作流每次现申请新的，不受影响）。
3. 点 `cn.eiraphone.native.notify`：勾 **App Groups** → Configure → 勾 `group.cn.eiraphone.native` → Save。
4. 点 `cn.eiraphone.native.widgets`：同上。
5. 不用新建密钥：推送转发用的 APNs 密钥（.p8）对同一个团队里所有 app 都有效。

没点第 2 到 4 步也能出包：`scripts/signplan.py` 会把描述文件里没有的 App Group、推送从 entitlements 去掉，不带两个扩展，
「传 TestFlight」日志里出现 `::warning::` 写明少了哪一样。点完之后重新传一次即可。

### 2. 推送转发（网页版仓库，维护者部署一次）

推送转发（网页版 `worker/apns.js`）用一个固定的 topic 请苹果推送。现在那一台（`https://eira-apns.yu864249.workers.dev`）的 topic 是网页版外壳的包标识；
原生版的推送地址交给它，苹果会回 `DeviceTokenNotForTopic`。

1. 浏览器打开 `https://eira-apns.yu864249.workers.dev/`，看返回的 `topic`。如果正好是 `cn.eiraphone.native`，跳到第 4 步，地址就用它。
2. 否则在网页版仓库的 `.github/workflows/deploy-apns.yml` 里给 `workflow_dispatch.inputs` 加一项 `topic`（描述「推送的 topic，默认取 IOS_BUNDLE_ID」，不必填），
   并把那一步的 `APNS_TOPIC: ${{ vars.IOS_BUNDLE_ID }}` 改成 `APNS_TOPIC: ${{ inputs.topic || vars.IOS_BUNDLE_ID }}`（这一改按网页版的规矩在网页版仓库里做）。
3. 网页版仓库 Actions →「部署推送转发」→ Run workflow：Worker 的名字填 `eira-apns-native`，topic 填 `cn.eiraphone.native`。
   跑完看日志里的 `/probe` 结果是「连得通，密钥可用」。
4. 把地址（例如 `https://eira-apns-native.yu864249.workers.dev`）告诉开发会话，写进 `Sources/Eira/App/EiraPush.swift` 的 `siteRelay`；
   不改代码也行：在应用的「设置 - 后台消息 - 通知通道」里填这个地址。

### 3. 你自己的后台消息服务器

Eira 推送这一种通知通道要 2026-10 之后（网页版 4.896 起）的 `worker/push.js`。之前部署的要重新粘贴一次代码（网页版「部署教程」同一份）。

### 4. 在手机上

1. 装上新传的 TestFlight 版，打开「设置 - 后台消息」，开启后台消息；
2. 同一页「通知通道」：确认推送转发地址，点「登记」，系统问通知权限时允许；
3. 点「经推送转发试一条」，锁屏上应出现「这是一条测试推送」；
4. 要来电：「设置 - 消息通知 - 来电」开「系统来电界面」，点「试一次系统来电」，3 秒内锁屏，看系统来电界面弹不弹得出来；开关改过之后回到后台消息页再点一次「重新登记」或等下一次退到后台，通道里的 `ring` 才交给服务器；
5. 桌面组件：主屏幕长按空白处 → 左上角「+」→ 搜 Eiraowo，加「角色此刻」与「健康」；在「设置 - 主题 - iPhone 桌面组件」里选角色；
6. 待办：iOS 26 上第一次排提醒时系统问闹钟权限，允许后用系统闹钟；拒绝或系统更早时用通知。

### 5. App Store Connect

TestFlight 不用另填什么。以后上架 App Store 时：

- 中国大陆的 App Store 不允许使用 CallKit 的 app 上架。上架时要么不在中国大陆区发布，要么把系统来电界面与来电推送去掉（TestFlight 不受此限）；
- 审核时 `UIBackgroundModes` 里的 `voip` 要说明用途：只用于角色打来的电话（PushKit 来电推送 + CallKit）。

## 三、编译与签名

- `project.yml` 多两个 target：`EiraNotify`（`cn.eiraphone.native.notify`）、`EiraWidgets`（`cn.eiraphone.native.widgets`），随应用打包；
  三者共用 `Sources/Shared`（App Group、推送的盒子、组件数据）。entitlements：应用 `aps-environment: production`、App Group；两个扩展 App Group。
- 「编译」工作流（`build.yml`）不签名，两个扩展照样编译、跑测试，不用改。
- 「传 TestFlight」（`testflight.yml`）：`asc.py prepare` 申请证书，给应用与两个扩展各建一份描述文件、勾上能力；`signplan.py` 对一遍描述文件，
  缺什么去什么；然后才生成工程，每个 target 用自己的描述文件（`EIRA_PROFILE_APP` / `NOTIFY` / `WIDGETS`），导出时按包标识对上。
- `asc.py` 收旧证书只认这个 App 自己的（包标识是 `cn.eiraphone.native` 或它的扩展，网页版 4.1037），不再去收网页版工作流（`Eira CI`）的；
  壳 App 试点用网页版脚本给这个包标识建过的那几份，算这里的旧东西一起收。`python3 scripts/asc.py status cn.eiraphone.native` 只读地列出证书、描述文件与能力。

## 四、下一步

- 屏幕使用时间（Family Controls，网页版 `ScreenTime*`）：要苹果批准 Family Controls（Distribution）才进得了描述文件，先不做；
- 录屏共享（ReplayKit 广播扩展，网页版 `ScreenShare`，一起玩用）：先不做；
- 停在锁屏、系统通话界面上通话（网页版 4.895 后半：接听后由系统语音识别来听、音频会话配成通话）：原生版的通话是按回合的页面，接起来要回到应用里说；
- 后台接收回复（网页版 4.894，后台 URLSession）：应用被系统挂起时正在等的那条回复会断，原生版还没接系统的后台传输；
- 通讯类通知（带角色头像的那种大头像通知，INSendMessageIntent 与 Communication Notifications 能力）：现在是通知右侧的小图。
