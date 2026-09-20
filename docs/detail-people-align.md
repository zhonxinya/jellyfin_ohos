# 详情页「演职人员」左对齐修复

## 现象

详情页最下方的「演职人员」横滑行，在演职人员较少时会整排跑到屏幕中间，没有贴左边界。

## 复现（模拟器实测）

- 设备：HarmonyOS 模拟器，屏幕 1260×2844 px，density 3.375（1vp = 3.375px，16vp = 54px）
- 条目：`珍珠塔`（音乐，1 位演职人员）
- `uitest dumpLayout` 读数：该行 `ListItem` 的 bounds = `[509,1954][752,2063]`
  → 左边界 509px ≈ **150.8vp**；同一页面的海报行 / 简介 / 「演职人员」标题都在 16vp（56~58px）

## 根因

`DetailPage.PeopleRow` 里的横向 `List` 没有设置宽度：

```ts
List({ space: 12 }) { ... }
  .listDirection(Axis.Horizontal)
  .height(110)
  .scrollBar(BarState.Off)
  .padding({ left: 16, right: 16 })
```

ArkUI 的 `List` 宽度默认随内容自适应：内容宽 < 屏宽时 List 只有内容那么宽，
再被外层 `Column` 的默认 `HorizontalAlign.Center` 排到中间。演职人员多的条目内容超过屏宽、
List 被撑到屏幕宽，所以只有"人少"时才暴露出来。

工程内其它横滑货架（`components/HorizontalShelf.ets`、`components/MediaCollectionView.ets`）
一直都是 `List.width('100%')` + `Column.alignItems(HorizontalAlign.Start)`，
`PeopleRow` 恰好这两样都没写。

## 修复

`native/app/entry/src/main/ets/pages/DetailPage.ets` 的 `PeopleRow`：

- `List` 补 `.width('100%')` —— 占满页面内容宽，条目从 `padding.left(16vp)` 开始排；
- 外层 `Column` 补 `.alignItems(HorizontalAlign.Start)` —— 即使将来 List 收窄也贴左，与货架写法一致。

## 验证

验收脚本：`_people-align-verify.py`（工作区外，读 `uitest dumpLayout` 的 ListItem bounds + 截图像素左边界复核）。

| 条目 | 演职人员数 | 修复前首项左边界 | 修复后首项左边界（像素复核） |
| --- | --- | --- | --- |
| 珍珠塔 | 1 | 509px = 150.8vp（整排居中） | **54px = 16.0vp**（内容最左 55px） |
| 抽离 | 2 | 同上（内容宽 < 屏宽即居中） | **54px / 338px = 16.0vp / 100.1vp**（55px） |
| 城市猎人 | 6 | 54px = 16.0vp（本来正常） | 54px = 16.0vp，行内 x 与修复前完全一致 |

脚本输出：`验收结果: ALL PASS`（三种条目：首个 `ListItem` 左边界 = 54px±6 且行带像素最左内容 ≤ 66px）。

## 排查记录

- `uitest dumpLayout` 的节点 bounds 足够定位这类"对齐"问题，不必依赖截图肉眼判断；
- `uitest uiInput swipe/fling/dircFling` 在本环境下不会滚动详情页，因此验证明智地选了
  "简介为空 / 很短"的条目，让演职人员行直接落在首屏内。
