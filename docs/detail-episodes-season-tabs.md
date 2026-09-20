# 详情页「季与集」改为 Season TAB + 横向剧集列表

## 现象

电视剧详情页的「季与集」区是**手风琴**：每一季一行，点一下在**那一行下方展开**一段纵向分集列表。

设备实测（模拟器 1260×2844，density 3.375）暴露两个问题：

1. **多季剧翻页成本高**：想看第 5 季要先把前四季的展开内容滚过去；
   而"现在看的是第几季"没有任何固定指示，展开状态叠在长列表里很容易看错。
2. **一进来是空的**：默认没有任何季被展开，用户必须先点一下才有内容。

另外分集封面用的是 **2:3 海报卡**（复用 `MediaCard`），而分集封面实际是 **16:9 剧照**，
被按海报比例裁切后画面主体（人物、场景）经常被切掉；
"上次看到哪""这集看完了"这两个分集最关心的状态也没有位置安放。

## 修复

### 1. 季改成横向 TAB（`DetailPage.SeasonTabs`）

`native/app/entry/src/main/ets/pages/DetailPage.ets`：

- 状态从 `expandedSeasonId: string`（展开哪一季）改为 `activeSeasonIndex: number`（选中哪一季）；
- 季标签用**横向 `List`** 而非 `Row()+ForEach`：季数多的剧（20+ 季）在 `Row` 里会被挤到每季只剩几个字，
  `List` 可以滑动；
- 选中态 = 品牌色文字 + 品牌色下划线；未选中用 `Color.Transparent` 占位，
  保证**所有标签高度一致、切换时不跳动**；
- 进入详情页**默认选中第一季并加载分集**，TAB 栏一进来就有内容。

### 2. 分集改成横滑列表（新增 `components/EpisodeCard.ets`）

- 封面 **16:9 剧照**（高度由宽度推出，不裁切主体）；
- 已看完 → 右上角 `checkmark_circle_fill`；未看完且有进度 → 封面底部品牌色进度条；
- 点击直接起播该集。

不复用 `MediaCard` 的原因：它的封面是 2:3 海报（电影/剧集/合集用），
上面两个状态也没有位置放。

### 3. 修掉切季的竞态

`loadSeasonEpisodes` 里加了请求序号（`episodesSeq`）：

```ts
const seq: number = ++this.episodesSeq;
const raw: string = await JellyfinNative.getSeasonEpisodes(this.itemId, this.seasons[index].id);
// 用户在等待期间又切了季 → 这次响应已过期，直接丢弃
if (seq !== this.episodesSeq) {
  return;
}
```

快速连点不同季标签时，先发的请求可能后到；没有这层会把**上一季的分集**盖到当前选中季下面
（内容与标签不符）。

### 4. 播放跟随选中的季

`startPlayback()` 原来固定取 `seasons[0]`，与界面上选中的季无关 ——
在第 3 季标签下按播放会跳回第 1 季。现在优先播**当前选中季的第一集**：

```ts
if (this.item.type === 'Series') {
  if (this.episodes.length > 0) {
    this.playItem(this.episodes[0].id);
    return;
  }
  // 分集尚未就绪时才回退到第一季
  ...
}
```

按钮文案同步修正：剧集（Series）的按钮不再写「播放本集」
（详情页没有"当前集"这个概念，实际会播选中季第一集），改为「播放」；单集（Episode）仍为「播放本集」。

### 5. 季名归一化

服务端未做中文化时季名是英文 `Season 1`，与界面其余中文不一致。
`seasonTabLabel()` 把 `Season N` 归一为 `第 N 季`、`Specials` 归一为 `特别篇`；
其余名称（服务器自定义过季名的场景）**原样显示，不擅自改写服务端数据**。

## 验证（模拟器实测）

设备：HarmonyOS 模拟器 `Pura70Pro`（HarmonyOS 6.1.1(24)），1260×2844 px，density 3.375。

| 用例 | 数据/操作 | 结果 |
| --- | --- | --- |
| 季名归一化 | 服务端返回 `Season 1` | 界面显示「第 1 季」 |
| 多季 TAB | `V世代`（服务端 2 季） | 出现「第 1 季」「第 2 季」两个标签，`dumpLayout` 读数 center=(122,1162) / (306,1162)，各 137×51 |
| TAB 切换 | 点「第 2 季」 | 分集由 `E1 戈多金大学`/`2023 · 7.0 分` 换成 `E4 血袋`/`2025 · 6.0 分`（列表随之刷新，无残留） |
| 横向滚动 | 在第 2 季剧照区左滑 | 出现后续 `E5 学生们不太对劲`、`E6 烹饪课`、`E7 地狱周` |
| 播放跟随选中季 | 选「第 2 季」后点播放 | 服务端 `/Sessions` 回报 `NowPlaying: 血袋`，`ParentIndexNumber: 2`、`IndexNumber: 4`（= 第 2 季首集），确非第 1 季 |
| 单季剧集 | `小谢尔顿` | 只有 1 个标签（**服务端 `/Shows/{id}/Seasons` 实际只返回 1 季**，非界面丢数据） |

「单季只显示 1 个标签」这条专门做了服务端直查：`/Shows/{id}/Seasons?userId=…`
返回 1 项（`第 1 季`, IndexNumber=1），确认是数据本身如此。

## 验证环境说明（重要）

验证所用 HAP 的 **ArkTS 侧与本分支一致**，但**原生 core 取自 `fix/detail-page-fd-abort` 分支**
（含 `FD_SET` fd≥1024 abort 的修复），原因：

- `main` 上该修复尚未合并，详情页存在"约 20 秒必崩"；
- 详情页验证需要在该页面停留、反复切季与滚动，20 秒窗口内做不完。

因此本次 UI 验证是在"详情页不崩"的前提下做的。本分支自身（基于 `main`）已单独编译通过
（`hvigorw assembleHap` → `BUILD SUCCESSFUL`），本次改动只涉及 ArkTS，不触碰 `native/core`。

## 排查记录

- 判断"分集列表是空的"时，先用**服务端直查**（`/Shows/{id}/Seasons`）区分
  "服务端只有 1 季" 与 "客户端丢了数据"——本例是小谢尔顿本身只有 1 季，不是 bug。
- 季标签数量/位置、分集是否切换，用 `uitest dumpLayout` 的文本+bounds 判定，
  比肉眼看截图可靠；横向滚动是否生效也用"滑动后出现了新集名"来确认。
