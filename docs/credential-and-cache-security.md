# 凭据传递与本地缓存安全约定

本文记录「凭据不得进入 URL」与「本地缓存必须可清除」两条约定，以及配套的实测证据与踩坑。
改动 `image_url` / `subtitle_url` / `image_cache` / 清除数据流程前请先读完。

## 一、凭据一律走请求头，禁止进入 URL

### 为什么

Jellyfin 会把请求 URL 写进**服务端**访问日志（`Jellyfin.log`，本机实测 1.2 GB）。
旧实现把访问令牌拼进图片/字幕 URL 的 query：

```
/Items/<id>/Images/Primary?maxWidth=300&api_key=<token>
```

结果：服务端日志里累计留下 **74285 处** `api_key=<token>`，
令牌等于被明文落盘到服务器上 —— 任何能读日志的人（运维、备份、日志采集、
工单附图）都能直接拿到用户凭据。URL 还会经 Referer、代理访问日志继续扩散。

### 约定

| 场景 | 凭据形式 | 状态 |
| --- | --- | --- |
| Jellyfin API 调用（`api_client.cpp`） | `X-Emby-Authorization` 头 | 一直是头 |
| 图片下载（`LoadImage` → `ImageCache`） | `X-Emby-Token` 头（`core/auth_headers.h`） | 已改为头 |
| 字幕文本下载（`FetchSubtitleText`） | 同上 | 已改为头 |
| **播放地址**（`playback_resolve.cpp`） | **URL 里的 `api_key=`** | **保留（见下）** |

统一入口：`native/core/auth_headers.h` 的 `BuildAuthHeaders(token)`。

### 唯一的例外：播放地址

`native/feature/player` 的取流抽象是

```cpp
using RangeFetchFn = std::function<RangeResponse(const std::string &url,
                                                int64_t start, int64_t end)>;
```

**没有头部参数**，且其头文件注释明确写着「url 应已包含鉴权参数；feature/player 不关心鉴权方式」
—— 这是为了让该目录能整目录移植到其它工程（只依赖注入的取流回调）。

因此播放地址保留 URL 鉴权是**刻意的接口设计结果**，不是遗漏。
要消除它必须先把取流抽象改成
`(url, headers, start, end)` 并调用链全部改签名，
属于跨模块接口变更，需单独评估后再做（不要顺手改）。

### 涉及文件

- `native/core/auth_headers.h`（新增，凭据头构造）
- `native/core/image_url.cpp`（去掉 `api_key`）
- `native/core/subtitle_url.cpp`（去掉 `api_key`）
- `native/core/image_cache.{h,cpp}`（支持请求头 + 头部参与缓存键）
- `native/napi/jellyfin_napi.cpp`（`LoadImage` / `FetchSubtitleText` 传头）

## 二、图片缓存必须支持"按凭据隔离"

`ImageCache` 的缓存键由 **URL + 请求头** 共同派生（`cacheKey(url, headers)`）。

为什么不能只用 URL：改造后同一张图的 URL 对**不同账号**是完全一样的
（URL 里不再含令牌），若键只用 URL，切换账号后会命中上一个账号的缓存图片。
把鉴权头并入哈希就没有这个问题，代价仅仅是不再跨账号复用图片。

## 三、`ImageCache` 并发语义（曾被写坏）

旧实现是一个 20 ms × 50 轮的多分支轮询，分支条件互相矛盾：
循环里一旦发现 `pending_[key]` 就 `shouldDownload = true; break;`，
**无条件**进入下载 —— 结果是多个线程同时下载同一张图。
另外等待分支里"发现文件已存在"时会 `pending_.erase(key)`，
误删的是**别的线程**的下载权标记。

现在的语义单一且可推理：

1. 命中缓存 → 直接返回；
2. 否则**抢到下载权**（`pending_` 置位）的那个线程负责下载，`claimed` 局部变量是唯一判据；
3. 没抢到的线程只等文件出现，100 ms × 30 ≈ 3 s 超时（超时返回空 → 上层显示占位图）；
4. 所有退出路径统一走 `finishDownload(key)`（释放下载权 + 触发淘汰），不会遗留 pending。

## 四、本地缓存必须能被"清除全部本地数据"清干净

### 清除范围（实测）

| 位置 | 内容 | 由谁清 |
| --- | --- | --- |
| `preferences/jellyfin_session` | 会话/偏好（密文） | `SessionStore.clearAll` |
| Asset Store Kit | 加密主密钥 | `SecureStore.clearKey` |
| `haps/entry/cache/jellyfin_images` | 我们自己下载的媒体封面（实测 66 MB / 500 张） | `JellyfinNative.clearImageCache` |
| `base/cache/preload_caches` | **系统图片管线**缓存的媒体封面（实测 101 MB / 283 个 JPEG） | `SessionStore.clearPreloadCaches` |

失败时曾出现的问题：只清前两项时，磁盘上仍留着 167 MB 可读的媒体封面
（能反推观看内容），"清除全部本地数据"名不副实。

### 陷阱：`context.cacheDir` 是**模块级**，`preload_caches` 在 **bundle 级**

设备探针实测（`hdc` 侧路径与运行期路径对照）：

```
module = /data/storage/el2/base/haps/entry/cache   (存在，preload_caches 不存在)
app    = /data/storage/el2/base/cache              (存在，preload_caches = 283 个文件)
```

所以清理 `preload_caches` 必须用
`this.context.getApplicationContext().cacheDir`，**不能用 `this.context.cacheDir`**。
用错的后果是"清理逻辑正常执行、但什么都没删"——静默失效，很难从日志看出。

## 五、验证方法

### 证明凭据不再进 URL（含服务端日志）

Jellyfin 服务端访问日志**默认只记录慢请求**（`ResponseTimeMiddleware` 的
`Slow HTTP Response`），因此"日志里搜不到 `api_key`"**不是充分证据**。
可靠的做法是看**客户端是否仍能取到图**，因为去掉 URL 令牌后若没补上头部，取图会直接 401：

```bash
export TMPDIR=/tmp/hdc-zhonxinya
T=~/workspace/harmony-sdk-6.1.1/extracted/command-line-tools
HDC="$T/sdk/default/openharmony/toolchains/hdc"
B=com.zhonxinya.jellyfin_hmos_flutter
D=/data/app/el2/100/base/$B/haps/entry/cache/jellyfin_images

"$HDC" shell "rm -f $D/*.img"            # 清空，强制重新下载
"$HDC" shell "aa force-stop $B; aa start -a EntryAbility -b $B"
sleep 20
"$HDC" shell "ls $D | wc -l"             # 期望 500（头部鉴权被服务端接受）
"$HDC" shell "ls $D | grep -c '\.tmp$'"  # 期望 0（无残留临时文件）
```

另可用字节级对照服务端日志增量（本机实测：改造后新增区间 `api_key=` 为 0）：

```bash
L=/vol3/@appdata/Jellyfin/Jellyfin.log
B4=$(stat -c %s "$L")                     # 改造后基线
# ... 触发取图 ...
python3 -c "
import re;data=open('$L','rb').read();B4=$B4;seg=data[B4:]
print('新增 api_key:',seg.count(b'api_key='))"   # 期望 0
```

### 证明缓存被清干净

```bash
P=/data/app/el2/100/base/$B/cache/preload_caches
"$HDC" shell "ls $P | wc -l; du -sk $P"   # 清除前：283 / 103916
# 走 UI：设置 → 清除全部本地数据 → 移除
"$HDC" shell "ls $P | wc -l; du -sk $P"   # 清除后期望：0 / ~44
"$HDC" shell "hilog -x | grep 'preloaded image file'"   # 期望：cleared 283 preloaded image file(s)
```

## 六、踩坑记录

- **`context.cacheDir` vs `getApplicationContext().cacheDir`**：模块级 vs bundle 级，
  `preload_caches` 只在后者下。用错 = 静默清不掉（本机实测踩到）。
- **服务端日志只记慢请求**：不能拿"日志里没有"当"没发生"。
  要证明改造有效，用"客户端仍能取到图"这种正向证据。
- **`ImageCache::clear()` 不能用 `ListCacheFiles`**：该函数会跳过 `.tmp`，
  而清除缓存时正需要删掉中断残留的临时文件，否则占用会持续累积。
- **不要用 `Image(远程URL)`**：既绕过本工程 HTTP/CA 与磁盘缓存，
  又会触发 ArkUI 自带图片并发下载（大图库下 fd 逼近上限导致 abort，见
  `components/JellyfinImage.ets` 的文件头说明）。全部封面应经 `JellyfinImage`。
- **改完后必须重装才生效**：验证前先 `hdc install -r`，否则测的是旧包
  （本机踩过：清空缓存后仍看到旧行为，实为旧包在跑）。
- **盲点坐标操作不可靠**：`uitest uiInput click` 依赖当前位置的界面，
  若前置页面（如隐私同意弹窗）已出现，后续点击会全部落到错误控件上。
  走 UI 流程时每一步都应 `dumpLayout` 确认当前页面再点。
