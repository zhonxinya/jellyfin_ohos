# 详情页「音频 / 字幕」未选择态修复

## 现象

详情页的「音频 / 字幕」两个选择器在**没选任何轨道时按钮上是空白**，看不出当前处于"未选择"；
展开「音频」下拉还会发现里面混着视频流、字幕流（第一项是 `1080p H264 SDR` 这类视频标题）。

## 根因

两处：

1. **`Select` 的按钮文字由 `.value()` 决定，不是 `.selected()`。**
   SDK 里 `selected()` 的注释是 "Sets the serial number of the select item"（第几项被选中），
   而 `value()` 是 "Sets the text display of the select button itself"（按钮本身显示什么）。
   原代码只有 `Select(this.audioOptions())`，两个都没设 → 按钮上一个字都不渲染
   （实测：关闭态 Select 框内阈值 90 以上没有任何墨迹，dumpLayout 里 `text` 为空串）。

2. **选项列表没有按流类型过滤。** `audioOptions()`/`subtitleOptions()` 都直接遍历
   `mediaStreams`（包含 Video/Audio/Subtitle 全部流），而播放页取轨用的是
   `streamsOfType('Audio')` / `streamsOfType('Subtitle')`，两处口径不一致。
   于是「音频」下拉第一项是视频标题，「字幕」下拉里塞进了 5 条音轨。

## 修复

`native/app/entry/src/main/ets/pages/DetailPage.ets`：

- 新增 `streamsOfType()` / `audioStreams()` / `subtitleStreams()`，与播放页同一口径；
- `audioOptions()` / `subtitleOptions()` 第 0 项固定为 `未选择`（= 不指定轨道，
  播放时由播放页映射到文件/服务端的默认轨），其后只列对应类型的流
  （字幕下拉原来的「关闭」即 -1，与「未选择」是同一个值，故合并）；
- 新增 `optionIndexOf()`（当前选中流 → 下拉下标）与 `audioOptionText()` / `subtitleOptionText()`
  （下拉下标 → 按钮文字，未选择时恒为「未选择」）；
- `Select` 补 `.value(...)`（按钮文字）与 `.selected(...)`（选中项），
  `onSelect` 改为 `index === 0 ? -1 : streamIndexAt(该类型流列表, index - 1)`。

## 验证（模拟器 1260×2844，density 3.375）

条目 `阴阳路4：与鬼同行`（服务端真值：Audio idx1 粤语 / idx2 国语；Subtitle idx3 繁体 / idx4 简体；
另有 idx0 视频流）。

| 判定 | 修复前 | 修复后 |
| --- | --- | --- |
| 关闭态按钮文字（dumpLayout `Select.text`） | `''`（空白） | `未选择` / `未选择` |
| 关闭态墨迹宽度（像素复核） | 无墨迹 | 158px / 158px（3 个汉字，两框一致） |
| 音频下拉选项 | 混入视频、字幕流 | `未选择`、`粤语 - Chi - AAC - Stereo - Default`、`国语 - Chi - AAC - Stereo` |
| 字幕下拉选项 | `关闭` + 全部流混排 | `未选择`、`繁体中文 - Chi - 默认 - SUBRIP`、`简体中文 - Chi - SUBRIP` |
| 选一条音轨后按钮文字 | — | 158px → 331px（随选择更新） |
| 选一条字幕后按钮文字 | — | 158px → 318px |
| 点「播放」 | — | 服务端会话可见本次播放（阴阳路4：与鬼同行） |

验收脚本：`_track-unselected-verify.py`（工作区外）——读 `uitest dumpLayout` 的
`Select.text` 与 `type=Option` 弹层项，并用 `snapshot_display` 截图做像素墨迹宽度复核。

## 排查记录

- 弹层（下拉）和页面在**同一份 `dumpLayout` 里**，但走不同分支：
  页面是 `ROOT90,0,...`，弹层是 `ROOT90,1,...`，弹层项 `type=Option`、文字同时出现在
  `Option` 与其内部 `Text` 上 —— 按 `type=Option` 取即可干净地拿到选项列表。
- 「选中 → 状态 → 按钮文字」用像素墨迹宽度闭环校验：修复前空白，修复后 3 汉字 158px，
  选中真实轨道后变长，说明`.value()` 的计算确实来自当前状态而不是写死的常量。
- 按钮文字由 `.value()` 提供后，`dumpLayout` 的 `Select.text` 也会带上该文字，
  以后这类"选择器显示了什么"的验收可以直接读节点文本，不必再靠像素。
