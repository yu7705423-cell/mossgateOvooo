# 美化生成器用网页版的代码（JavaScriptCore）

接着 `docs/jscore-pilot.md`（回复解析）与 `docs/jscore-prompt.md`（提示词拼装）。美化编辑器（网页版 4.836 起）那一堆旋钮的定义
（`GROUPS`）与「设置编成 CSS」（`emit`）在网页版 `src/system/skin-gen.js`（另引 `skin-paint.js`），纯函数、不碰库，
字符串进、CSS 出。原生直接跑这两个文件，不重抄：网页版加一组、改一项，下一次编译自动带进来。

## 文件

| 文件 | 作用 |
|---|---|
| `scripts/sync-weblogic.mjs <网页版目录> skin` | 打 `Resources/weblogic/skin.bundle.js`（白名单两个模块，不进仓库）；打之前用网页版原文件直接编 `Tests/Fixtures/skingen-cases.json` 的样本，写 `Tests/Fixtures/skingen-expected.json`（不进仓库） |
| `Resources/weblogic/skin-host.js` | 手写：`weblogic.skin.groups / state / emit`，结果一律是 JSON 字符串；补一个 `btoa`（JSContext 没有，毛玻璃质感要用） |
| `scripts/check-weblogic.mjs skin [--raw 目录]` | Node 的 `vm`（与 JSContext 同条件）里跑包，样本逐字对照网页版原文件编的；去过注释的包与原样的包逐字相同 |
| `Sources/Eira/Prompt/SkinGen.swift` | JSContext（自己一个，串行队列）：`groups`、`state`、`emit`（按设置缓存）；包不在时 `available` 为假 |
| `Sources/Eira/Prompt/SkinCompile.swift` | `Skins.effectiveCss`：网页版 skin.js 的 compile（令牌变量、头像框、生成器那一段、手写 CSS、late 时再写一遍并加 `:not(#skin-late)`） |
| `Tests/Unit/SkinGenTests.swift` | 与网页版逐字相同、先后与 late、包不在时退回、美化包 TXT/DOCX/JSON 来回、首页文件夹 |

CI（build.yml、testflight.yml）：与另外两个包一样，打不出来只记警告、删掉包与样本结果，不拦编译；编辑器退回原生的几项。

## 一条路

会话页、编辑器预览、主题小样、画成图片的部分都只读 `Skins.compiled(row)`，它交给 `CssSkin.compile` 的是 `Skins.effectiveCss(row)`：

    :root { 令牌与头像形状 }  →  头像框  →  生成器编出来的（带 !important）  →  手写 CSS
    手写 CSS 之后又动过令牌或生成器（late）：:root:root { 令牌 }，生成器那一段每条选择器前加 :not(#skin-late)

`CssSkinParser.isRoot` 认 `:not(#skin-late)` 这一层祖先（任何祖先都满足，多一个 id 的特异度），所以 late 时生成器在原生里同样压过手写的。
原生主题的格子（`native` 字段）照旧盖在最上面（ChatTheme.resolve）。网页版最后的 hoistImports 不做：原生不载入 @import，先后不影响结果。

包不在时生成器那一段是空的；`Skins.look` 照旧直接读生成器里原生认得的几项（气泡的边、底色、字色、圆角、内距、字号，头像的显示、大小、圆角），
编辑器页换成「尺寸与颜色」（`SkinEditView`），存着的设置原样留着、写回不丢。

## 美化 app 与会话菜单「主题」

- 美化 app（`SkinAppView`）是美化库：首页一排文件夹（`SkinPlaces.categories`：会话美化、应用美化、状态栏、心声卡片、线下、HTML 卡片、主屏组件），
  点开、点一张放大看、「编辑」带到起作用的那一页；导入与全部美化；每一份的详情（`SkinOneView`）：编辑器、主题格子、尺寸、自定义 CSS、
  复制 CSS、使用情况与挂到一段会话、生效范围与全部会话的默认、复制、导出（JSON、TXT、DOCX、复制为文字，作者署名）、删除。
- 会话菜单「主题」（`ThemeGalleryView(chatId:)`）只管这段会话挂哪一份；「修改」进的是同一个详情页，「导入与全部美化」进的是同一个美化库页。
  全部会话的默认只有 `ThemeGalleryView(chatId: nil)` 一页：美化 app 的「应用美化」与「设置 - 主题 - 聊天主题」都跳到它。
- 网页版的 shell（整个应用）一档：原生版里是「可以设为全部会话的默认」。消息列表、联系人等页面原生版不套美化（那些页面没有 ph- 钩子的原生对应），设置 app 从不套。
