# 音乐专辑名 / 歌曲名的乱码支持

中文音乐库里，「测试」这类名字常常显示成 `²âÊÔ`。本文记录这个现象的成因、客户端能做的两层处理、
以及实测验收。

## 结论先行

**客户端从不改写名字**（逐条读过音乐链路的每个显示点：`MusicPage` / `ArtistDetailPage` /
`AlbumDetailPage` / `MusicPlayerPage` / `MusicPlayback` / `MainShell` 迷你条），
既没有按字节截断，也没有做字符集转换 —— 乱码**来自服务端返回的数据本身**。

客户端能做、也已经做了两件事：

1. **读入容错**：非法 UTF-8 不再毁掉整份响应（C++ core）；
2. **显示修复**：常见的"编码被误读"型乱码在显示前尽力还原（ArkTS，用系统 ICU）。

## 乱码的几种形态

| 形态 | 例子 | 成因 | 本客户端 |
| --- | --- | --- | --- |
| **GBK 字节被当成 Latin-1** | `测试` → `²âÊÔ` | 音乐标签（ID3）以 GBK 写入，服务端按 Latin-1 解码后当 UTF-8 吐出来；码位全部 ≤ 0xFF | **修复**（需要 GBK 码表 → 走系统 ICU） |
| **UTF-8 字节被当成 Latin-1** | `测试` → `æµ‹è¯•` | 同上但中间按 Latin-1 解了一层；码位全部 ≤ 0xFF | **修复**（不需要码表，按 Latin-1 收字节再按 UTF-8 解） |
| **CP1252 形态** | `测试` → `æµ‹è¯•` 里混入 `€ ™ ‹` | 同 UTF-8 形态，但中间层用的是 CP1252 而非 Latin-1，码位会 > 0xFF | **不处理**（见「已知边界」） |
| **服务端已经写成 `�`** | `测试` → `��` | 服务端或上游在入库时就已把无法解码的字节替换成 U+FFFD | **不可恢复**（信息已经丢了） |
| **响应体里是非法 UTF-8 字节** | JSON 里直接出现 `\xB2\xE2` | 服务端把 GBK 字节原样塞进 JSON | **容错**（清洗成 `�`，但不再毁掉整份响应） |

前两种是"可逆"的：字节还在，只是被按错误的字符集解释了一遍。后三种要么信息已丢，
要么需要额外假设，故明确不猜。

## 第一层：读入容错（C++ core）

### 为什么必须做

`nlohmann::json::parse()` 对非法 UTF-8 是**抛异常**，没有容错档位 ——
`dump()` 有 `error_handler_t::replace`，`parse()` 没有。

实测（nlohmann 3.11.3，`native/core/tests/test_text_repair.cpp` 里有真实字节的断言）：

```
json::parse("{\"Name\":\"\xB2\xE2\xCA\xD4\"}")  →  parse_error.101 ... ill-formed UTF-8 byte
```

`api_client.cpp` 的 `interpret()` 是**所有**响应的唯一收口，它一旦在 `parse()` 上抛，
整份响应就退化成 `JSON parse error`：**一首曲目的标签是 GBK，整个音乐库（乃至首页）都打不开**。
用户要的是"其余内容照常能看，只有那一个名字显示成 `�`"。

### 怎么做的

- `native/core/text_util.h` 新增 `Utf8SequenceLength()` / `IsValidUtf8()` / `SanitizeUtf8()`。
  按 RFC 3629 **严格**判定：过长编码（`C0 AF`、`E0 80 AF`）、代理区（`ED A0 80`）、
  超出 `U+10FFFF`（`F4 90 80 80`）都算非法 —— 这些序列在标准解析器（含 nlohmann、ICU）里都会被拒。
- `api_client.cpp::interpret()` 在成功与失败两条路径上，都把响应体先过一遍 `SanitizeUtf8()` 再 `parse()`。
- 非法字节**逐个**替换成 U+FFFD（`EF BF BD`），合法文本原样返回（`IsValidUtf8()` 为真时零拷贝返回）。

这与 `json_dump.h` 的 `SafeDumpJson()`（写出方向：非法字节 → U+FFFD）是同一策略的两端：
读入方向也必须在进 JSON 之前把非法字节收敛掉。

## 第二层：显示修复（ArkTS）

`native/app/entry/src/main/ets/common/TextRepair.ets`：把显示文本按 Latin-1 收成字节，
再依次尝试用系统 ICU 按 **UTF-8**、**GBK** 解码，谁解出中文用谁。

```ts
util.TextDecoder.create('utf-8' | 'gbk', { fatal: true })
```

`fatal: true` 是关键：非法序列会抛，于是"这些字节不属于这个编码"与"解出了别的东西"可以区分开。
GBK 解码器拿不到（设备 ICU 缺该转换器）时置位 `gbkUnavailable` 并永久跳过，不影响播放与列表。

### 判据（宁可漏修，不可误改）

`looksLikeMojibake()` 必须**同时**满足，才进入解码尝试：

1. 全部码位 ≤ 0xFF（否则是正常文本，或 CP1252 形态）；
2. 不含 ASCII 字母与数字（正常英文名不该被拿去解码）；
3. 高位字符（≥ 0x80）至少 2 个。

解码结果还必须**含 CJK**（`U+3400..U+9FFF` / `U+F900..U+FAFF`）才采纳，否则原样返回。
任何一步失败都退回原文 —— 最坏情况是"没修"，不会把好名字改坏。

### 只修显示名，且**不放在 C++ core**

应用范围是 `MediaItem.fromJson` 里的**展示类字段**：`Name`、`Overview`、`SeriesName`、
`AlbumArtist`、`Genres`。`Id` / `Type` / `CollectionType` / `Tags` / 评分 / `PlaylistItemId` /
`SeriesId` 等**不做修复**（标识与枚举值不该被猜）。

放在 ArkTS 而不是 core 的两个理由：

1. core 里没有 ICU，也没有字符集码表；引入 `libicu` 会给构建与主机单测增加依赖，
   而 vendor 一份 GBK 码表是几万行生成代码；
2. **core 里的名字会被写回服务端** —— 元数据编辑器保存是"整体替换"（见
   `docs/item-metadata-management.md`），若在 core 层把名字修好，用户只是打开一下编辑器再保存，
   就会把服务端数据悄悄改掉。显示层修复没有这个问题。

`AlbumDetailPage` 里有一处原来自己读 `AlbumArtist` 原文，已改为取 `MediaItem` 上已修复的字段。

## 已知边界

- **`�`（U+FFFD）不可恢复**：那是服务端已经替换过的痕迹，字节信息已丢。
- **CP1252 形态不处理**：码位会 > 0xFF，与"正常文本"无法用上面的判据区分，猜错代价大。
- **元数据编辑器显示原文**：`ItemMetadataPage` 读的是服务端原始 `Name`（不经修复），
  这样编辑框里是服务端的真实值，保存时原样回传，不会把修复结果写进服务端。
- 本层只处理**名字类**文本；简介等字段同样过修复，但标签（`Tags`）不过。

## 单测

`native/core/tests/test_text_repair.cpp`（31 条断言，已登记进 `scripts/force-build.ps1`
与 CI 的 `.github/workflows/build.yml`）。覆盖：合法 UTF-8（ASCII / 中文 / 四字节 emoji / 两字节 `©`）、
各种非法序列（截断、孤立 lead、孤立续字节、过长编码、代理区、超出 `U+10FFFF`）、
`SanitizeUtf8` 的语义（合法原样返回、每个非法字节一个 `�`、前后文保留），
以及端到端那条：**含 GBK 字节的 JSON 体裸 `parse()` 确实抛，清洗后不抛且其余字段完好**。

ArkTS 侧没有单测框架（`native/app` 只有 `main`，无 ohosTest），`TextRepair` 靠真机验收。

## 验收记录（模拟器，2026-09-24）

- **无回归 / 无误改**：音乐库 42 位艺术家、163 张专辑、专辑曲目列表、播放页、迷你条
  的中文名全部正常；繁体（`11月的蕭邦`）与英文名（`Office有鬼`）均未被改动。
- **修复确实生效**：借应用自身的元数据编辑器把某影片的「名称」改成 `²âÊÔ`
  （即 GBK `测试` 被当 Latin-1 读出的形态，码位 `b2 e2 ca d4`），保存后重启应用，
  媒体库网格与详情页标题都显示为 **`测试`**。验收后已把该条目名称还原为原值并确认。
- **工具链**：`6.1.1.300` 干净构建 BUILD SUCCESSFUL；生成的 110 个 `.ts` 逐个 `es2abc --parse-only` 全通过；
  codelinter 与 main 基线差分 **0 新增 / 0 消失**（181 命中 / 55 文件）。
- 顺带发现（**与本改动无关**）：专辑「9公主 (2006)」的曲目播放时服务端返回 **HTTP 500**，
  属服务端侧问题（本改动只清洗响应体，对合法 UTF-8 是零拷贝直通，不参与请求构造）。
