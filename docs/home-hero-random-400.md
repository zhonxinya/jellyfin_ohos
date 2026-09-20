# 首页推荐「偶尔消失」修复：服务端 `SortBy=Random` 会随机返回 400

> 面向：验收与后续迭代。记录**现象**、**根因（含服务端源码证据）**、**绕行方案**与**设备实测证据**。
> 相关代码：`components/HeroBanner.ets`、`common/ItemsQueryOptions.ets`、
> `native/core/api/items_query.{h,cpp}`、`native/core/api/media_api.cpp`、`native/napi/jellyfin_napi.cpp`。

---

## 一、现象

首页顶部的推荐横幅**偶尔整个消失**：不是显示错误文案，而是静默退化成一块同高度的纯色占位，
首页其余区块（我的媒体 / 继续观看 / 最新添加）一切正常。重新进首页可能又好了。

用户口径："首页推荐重启后偶尔消失"——**重启后**出现，且**偶发**。

## 二、复现（模拟器实测）

设备：HarmonyOS 模拟器 1260×2844（Pura 70 Pro），服务端 Jellyfin 10.8.12（本机 `:8097`）。

冷启动 25 次，用 `uitest dumpLayout` 判定横幅区（`Swiper`，高 965px、起点 y≈346）是否存在：

| 轮次 | 结果 |
| --- | --- |
| 25 次冷启动 | **2 次失败**（run 15、run 23）→ 命中率约 **8%** |

判定方式：横幅出现时该区域是 `Swiper + Image + 标题 Text`；
失败时该区域只剩一个空的 `Column`（即 `HeroBanner.build()` 的"无内容占位"分支）。

## 三、根因

### 客户端日志（诊断插桩，已移除）

```
W JellyfinHero: DIAG queryItems failed code=400 msg=HTTP 400 detail=
```

`HTTP 400`，且响应体为空 —— 不是鉴权、不是参数拼错。

### 服务端日志（决定性证据）

`/vol3/@appdata/Jellyfin/Jellyfin.log`，与上面同一时刻：

```
[ERR] Jellyfin.Server.Middleware.ExceptionMiddleware: Error processing request.
      URL GET /Users/<uid>/Items.
System.ArgumentException: Unable to sort because the IComparer.Compare() method returns
inconsistent results. Either a value does not compare equal to itself, or one value
repeatedly compared to another value yields different results.
      IComparer: 'System.Comparison`1[System.Int32]'.
   at System.Linq.EnumerableSorter`2.QuickSort(Int32[] keys, Int32 lo, Int32 hi)
   at MediaBrowser.Controller.Entities.UserViewBuilder.SortAndPage(...)
[WRN] ... Slow HTTP Response from .../Items?...&SortBy=Random ... with Status Code 400
```

### 服务端源码（本仓库 `docs/jellyfin-10.8.12/`）

`Emby.Server.Implementations/Sorting/RandomComparer.cs`：

```csharp
public int Compare(BaseItem? x, BaseItem? y)
{
    return Guid.NewGuid().CompareTo(Guid.NewGuid());
}
```

**每次比较都返回一个全新的随机结果** —— 同一个元素和自己比较都可能不相等。
这是一个**不自洽的比较器**，违反 `IComparer` 的契约。

`LibraryManager.Sort()` 把它交给 `items.OrderBy(i => i, comparer)`，
.NET 的 `ArraySortHelper`（`EnumerableSorter.QuickSort`）在排序过程中会检测这种不自洽性，
发现后抛 `ArgumentException`。Kestrel 把它变成 **HTTP 400**。

### 为什么是"偶尔"

排序过程中**是否触发**那个自洽性检测，取决于快排每次选择的轴心与数据分布 ——
同一份数据、同样的代码，有的请求能排完（200），有的中途被发现（400）。
所以表现是偶发，且与数据量有关（首页只取 6 条，命中率约 8%）。

### 为什么表现为"整个消失"

`HeroBannerLoader.loadBanner()` 在 `!result.ok` 时直接置 `status = ERROR` 并清空 `items`，
而 `HeroBanner.build()` 对"有错误但无内容"的情况**故意**退化成纯色占位
（原设计意图：推荐位挂了不该把首页整块弄成错误页）。

这个设计本身是合理的，但配上"随机 400"就变成了**静默消失**：
用户看不到任何提示，也不会想到要下拉刷新。这是本轮一并处理的问题（加重试）。

## 四、修复

### 主修复：不在服务端做随机排序，改为**取候选池 + 本地抽样**

服务端那个比较器是 Jellyfin 10.8 的缺陷，客户端改不了它 —— 但可以不碰它。

- `ItemsQuery` 新增 `randomSamplePoolSize`（0 = 关闭，走原行为）；
- `BuildItemsQueryPath()`（`items_query.cpp`）在该开关打开且 `sortBy` 含 `Random` 时：
  - **不下发** `SortBy=Random`，改用稳定排序 `SortBy=SortName`；
  - `Limit` 换成池子大小（`randomSamplePoolSize`），让服务端返回一批候选；
- `queryItems()`（`media_api.cpp`）拿到结果后，在**本地**用 `std::shuffle` 随机挑出调用方要的条数。

随机效果不变（每次进首页仍是不同的一批），但**完全绕开了坏比较器** ——
而且这个做法对**任何** Jellyfin 版本都成立，不依赖服务端是否修好。

判定"走不走抽样"抽成了 `UsesLocalRandomSample()`（`items_query.h`）：
拼 URL 与真正抽样必须用**同一个**判断，否则会出现"改了 Limit 但没抽样"或反过来的错配。
单选测同时断言了这个函数的返回值与 URL 里的实际参数（见第五节）。

### 顺带修掉同一根因的另一处

`ShortVideoPage.fetchLibraryBatch()` 也用 `SortBy=Random`，同样会命中 400 ——
只是它的表现不是"消失"而是"取不到内容"（走 `batchError`）。同样改为本地抽样（池子 120）。

### 防御：一次同参数重试

`loadBanner()` 失败时再试一次。根因修掉后这条路径理论上不会走到，
但它同时覆盖网络抖动、服务端重启这类瞬时失败 ——
推荐位消失一整轮很显眼，值得多发一次请求换自愈。

## 五、验证

### 主机侧单测（`native/core/tests/test_items_query.cpp`）

新增 `TestRandomSortAvoidedWhenLocalSampling()`，断言：

| 用例 | 断言 |
| --- | --- |
| 开抽样 + `sortBy=Random` | URL 里**不含** `Random`；`SortBy=SortName`；`Limit=60` |
| 同上 | `UsesLocalRandomSample()` 返回 true（与 URL 判断一致） |
| 关抽样 + `sortBy=Random` | `SortBy=Random`、`Limit=6`（保持原行为） |
| 关抽样 | `UsesLocalRandomSample()` 返回 false |
| 普通排序 + 开抽样 | `SortBy`/`SortOrder`/`Limit` 都不被改写；不抽样 |

```
== 全部通过 ==
```

### 设备实测（模拟器，同一台 Jellyfin 10.8.12）

| 判定 | 修复前 | 修复后 |
| --- | --- | --- |
| 冷启动 40 次，横幅出现 | — | **40 / 40（0 失败）** |
| 修复前 25 次 | 23 / 25（2 失败） | — |
| 服务端收到的请求 | `...&Limit=6&...&SortBy=Random` | `...&Limit=60&...&SortBy=SortName` |
| 该请求的状态码 | 偶发 **400** | **200** |

服务端日志中被替换后的请求（原文）：

```
GET /Users/<uid>/Items?Recursive=true&...&Limit=60&SortBy=SortName
    ... with Status Code 200
```

修复前后对比的关键差别：`Limit=6 & SortBy=Random`（会 400）→
`Limit=60 & SortBy=SortName`（稳定 200，由客户端抽样成 6 条）。

## 六、排查记录（下次遇到同类问题可复用）

1. **先加插桩再猜**。首页推荐没有自己的日志，第一版插桩只打了 `code/msg`，
   拿到 `HTTP 400` 但仍不知道原因；补上 `detail`（服务端响应体）后发现**响应体为空**，
   这时才确定要去读服务端日志 —— 空 body 的 400 基本意味着**服务端抛异常**而不是参数校验失败。
2. **服务端日志是决定性证据**。`ArgumentException: ... IComparer ... inconsistent results`
   直接把范围从"客户端请求有问题"改成"服务端排序实现有问题"，一步到位。
3. **本仓库里带着 Jellyfin 服务端源码**（`docs/jellyfin-10.8.12/`），
   拿到异常类型后可以直接读 `RandomComparer.cs` 与 `LibraryManager.Sort()` 确认调用链，
   不必靠猜或翻外网。
4. **偶发问题要跑够次数**。8% 的命中率意味着 10 次里大概率一次都碰不到；
   实测跑了 25 次才抓到 2 次，修复后又跑 40 次确认 0 次。
5. **验收脚本用结构判定而不是文本**。横幅区出现与否用 `Swiper` 的 bounds 判定，
   比"找某一部片名"可靠（推荐是随机的，片名每次都不一样）。
