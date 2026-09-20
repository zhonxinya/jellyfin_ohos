# 详情页「约 20 秒后必崩」修复：OpenHarmony 的 `FD_SET` 会在 fd ≥ 1024 时直接 abort

> 面向：验收与后续迭代。记录**现象**、**根因（含系统头文件依据）**、**修复**与**设备实测证据**。
> 相关代码：`native/core/socket_util.h`、`native/core/http_client.cpp`、
> `native/core/tests/test_socket_util.cpp`。

---

## 一、现象

打开**媒体详情页**并停留，应用约 **20~46 秒后无提示消失**（回到桌面）。
不是卡死、不是报错页 —— 进程直接没了。

复现（模拟器，100%）：启动 → 媒体库 → 打开任意条目详情页 → 等待 → 崩溃。
实测两次：进程存活 **75s / 46s** 后崩溃。

## 二、根因

### 崩溃栈（符号化后）

设备 `/data/log/faultlog/faultlogger/` 里的 `cppcrash-*.log`：

```
Reason:Signal:SIGABRT(SI_TKILL)
#00 raise
#01 abort
#02 __fortify_error
#03 __fd_chk                      ← musl FORTIFY
#04 ConnectTcp                    http_client.cpp:190
#05 HttpClient::request           http_client.cpp
#06 HttpClient::get
#07 ImageCache::getOrDownload
#08 LoadImage（NAPI 图片加载）
#17 NativeAsyncWork::AsyncWorkCallback
```

`#04` 精确落在 `http_client.cpp:190`，那一行是：

```cpp
FD_SET(fd, &writeSet);      // 连接竞速循环里，把候选 fd 塞进 fd_set
```

### 为什么 `FD_SET` 会 abort

OpenHarmony 的 `<sys/select.h>`：

```c
#define FD_SETSIZE 1024

/*
 * This method will check fd(0 <= fd < 1024) is valid for select, abort if not.
 */
void __fd_chk(int fd);

#define FD_SET(d, s) do { __fd_chk(d); ... } while(0)
#define FD_CLR(d, s) do { __fd_chk(d); ... } while(0)
#define FD_ISSET(d, s) ((d) >= 0 && (d) < FD_SETSIZE && ...)   /* 注意这条没有 abort */
```

也就是 **`FD_SET` 传入 fd ≥ 1024 会直接 abort 进程**。
（`FD_ISSET` 自带边界判断，越界只返回 false —— 这种"同族宏行为不一致"正是问题容易漏掉的原因。）

### 为什么 fd 会到 1024

`select()` 的 `fd_set` 只有 1024 位，但**进程自身的 fd 上限是 32768**：

```
$ cat /proc/<pid>/limits
Max open files            32768                32768                files
```

两者相差 32 倍。只要进程瞬时持有 1024 个以上 fd，下一次 `FD_SET` 必崩。

### 为什么是「详情页」触发

详情页会**并发发起大量图片请求** —— 每张图一个 `RunAsync` 工作线程、各自一条 TCP 连接
（`LoadImage` → `ImageCache::getOrDownload` → `HttpClient::get`）。
fd 数量随图片数快速上升，越过 1024 就崩。这也解释了"为什么是详情页"和"为什么要等 20 秒"
（等图片陆续加载、fd 累积）。

## 三、修复

把两处 `select()`/`FD_SET` 换成 **`poll()`** —— `poll()` 用数组传 fd，**没有 1024 宽度限制**。

| 位置 | 改动 |
|---|---|
| `socket_util.h` `WaitSocketReady()` | `select()` → `poll()`，并补 `fd < 0` 入口保护 |
| `http_client.cpp` `ConnectTcp()` 竞速循环 | `fd_set` + `select()` → `std::vector<pollfd>` + `poll()` |
| `test_socket_util.cpp`（新增） | 守住"fd ≥ 1024 不 abort"的契约 |
| `scripts/force-build.ps1` | 注册新单测 |

顺带修掉一个**语义 bug**（由新单测发现）：`fd` 无效时 `poll()` 返回 `POLLNVAL`，
最初把它当成"就绪" → 调用方会拿着坏 fd 去 read/write，把"参数错误"伪装成"连接问题"。
现在 `POLLNVAL` 返回 `-1`。

保留的语义（与旧 `select()` 版一致，逐条有单测）：就绪 → `1`、超时 → `0`、
错误 → `-1`、`EINTR` 重试、对端关闭算"就绪"（交给后续 `recv` 拿到 `0`）。

## 四、验证

### 主机侧单测（`native/core/tests/test_socket_util.cpp`）

```
== WaitSocketReady 单测 ==
非法 fd 不崩、返回 -1        [ ok ] fd=-1（读/写）、大负数
可写 fd 就绪                 [ ok ] socketpair 可写 → 1；无数据可读 → 超时 0
有数据可读 → 就绪            [ ok ] 写入 1 字节后可读 → 1
对端关闭 → 就绪              [ ok ] → 1，随后 read 返回 0
超时行为                     [ ok ] 返回 0 且确实等满 ~1s
大 fd 值不触发 abort         [ ok ] fd=5000 安全返回；真实 fd >= 1050 安全返回（实测拿到 fd=1050）
== 全部通过 ==
```

其中"真实 fd >= 1050"这条**在旧实现上会 abort** —— 它是本次修复的核心回归防线。
（主机侧要先 `dup(0)` 占满前 1050 个 fd 才能拿到这么大的 fd；测试里已这么做，
拿不到时跳过而**不**判失败，避免把环境限制当缺陷。）

### 设备实测（模拟器 Pura70Pro / HarmonyOS 6.1.1(24)）

复现路径与修复前**完全一致**：启动 → 媒体库 → 打开详情页 → 停留。

| 判定 | 修复前 | 修复后 |
|---|---|---|
| 详情页停留 65 秒 | **崩溃**（46s / 75s 两次） | 进程存活（`pidof` 有值） |
| 再连续停留 90 秒 | — | 存活，**无新崩溃日志** |
| 滚动详情页 + 来回切库/进详情（制造更多图片请求） | — | 存活，**无新崩溃日志** |
| 崩溃日志数量 | +1（每次必崩） | **0** |

判据：对比 `/data/log/faultlog/faultlogger/` 最新文件名与基准名 —— 全程未产生新文件。

### 补充实测（第二轮，最严苛样本）

用**演职人员最多**的条目压测并发图片请求（106 人 → 详情页会并发加载 106 张图，
远高于普通条目）：

| 判定 | 结果 |
|---|---|
| 打开详情页后滚到「演职人员」区（触发 106 张图并发加载） | — |
| 停留 **103 秒**（旧崩溃窗口约 20 秒） | 进程存活，`pid` **与打开前一致**（= 从未重启） |
| 详情页是否仍正常渲染 | 是（演职人员行仍在，`uitest dumpLayout` 可读到古天乐/洪金宝/林峯等） |
| 滚动位置是否保持 | 保持（同一批 `y` 坐标）→ 佐证未重启 |

### 产物级验证（编译结果确已不含该 abort 路径）

| 检查对象 | `poll` | `select` | `__fd_chk` |
|---|---|---|---|
| `http_client.cpp.o`（本次构建） | **1** | **0** | **0** |
| `http_tls.cpp.o`（本次构建） | **1** | **0** | **0** |
| 主机侧单编 `http_client.cpp` | 1 | 0 | 0 |

即**自有代码已完全不引用** `select`/`__fd_chk`（`__fd_chk` 是 `FD_SET` 展开后的唯一入口，
它的存在就等于"仍有 FD_SET 路径"）。

> 排查提醒：构建目录里存在**多套路径变体**的目标文件
> （`vol3/@appdata/dsh-qddev/...`、`vol1/home/zhonxinya/...`、`home/zhonxinya/...`），
> 前两套是**别的用户/更早构建的陈旧产物**。用 `find ... | head -1` 取到的可能是它们，
> 会得出"仍有 select"的**错误结论**。本次构建真正使用的是相对路径那套
> （时间戳与构建时刻一致），判定前务必核对时间戳。

### 残留的第三方 `select` 引用（已确认不可达）

链接产物里仍能查到 `select`/`__fd_chk`，来自 **mbedTLS** 的
`library/net_sockets.c`（`FD_SET`）。它**不在本应用的 I/O 路径上**：

- `http_tls.cpp` 用 `mbedtls_ssl_set_bio(&ssl, &socketFd_, BioSend, BioRecv, nullptr)`
  —— 自己提供收发回调，**不使用** mbedTLS 的 `net_sockets` 系列；
  `#include <mbedtls/net_sockets.h>` 只为取错误码常量；
- mbedTLS 自己的 `net_sockets.c` 还带 `if (for_select && fd >= FD_SETSIZE)` 前置保护；
- 本次崩溃路径是**纯 HTTP**（`http://…:8097`），根本不经过 TLS。

因此它是"被静态链接进产物、但运行期不可达"的代码。若将来改用 mbedTLS 的
`net_sockets` 做 I/O，需重新评估这一点。

### 回归

全部主机侧单测通过：`test_items_query`、`test_socket_util`、`test_url_util`、
`test_http_response`、`test_device_profile`、`test_playback_resolve`、`test_image_url`、
`test_range_cache`、`test_library_admin_api`。

## 五、排查记录（可复用）

1. **先符号化，不要猜**。`__fd_chk` 只告诉你是"某个 fd 操作"，看不出是哪一处。
   把崩溃日志里的 `BuildID[sha1]` 与本地构建产物对比，**确认是同一份二进制**后
   再用 `addr2line -f -C -i` 逐帧符号化，一次就落到 `http_client.cpp:190`。
   （踩过：用旧 `.so` 符号化会得到完全无关的函数名 —— `#04` 曾被解析成
   `resolvePlayUrl`。二进制必须与崩溃日志的 BuildID 一致。）
2. **系统头文件是最终依据**。看到 `__fd_chk` 后直接读
   `sdk/.../sysroot/usr/include/sys/select.h`，注释里写明了契约
   （"abort if not (0 <= fd < 1024)"），比任何推测都直接。
3. **`ulimit` / `limits` 与 `select()` 的 1024 是两回事**。一开始看到 fd 上限 32768
   就排除了"fd 用尽"，但真正的问题不是"用尽"，而是"`select` 只支持 1024"。
   `FD_SETSIZE` 是编译期常量，与运行时上限无关。
4. **只有 `FD_SET`/`FD_CLR` 会 abort，`FD_ISSET` 不会**。所以旧代码里
   "看起来有边界检查"的地方其实没有 —— 别被 `FD_ISSET` 的表象误导。
5. **让单测在旧实现上失败**，而不是只断言"新实现能跑"。`fd >= 1050` 那条在
   `select()` 版会 abort，这才算真正的回归防线。

## 六、后续

- 该约束是 OpenHarmony 特有的（musl FORTIFY + 定制 `select.h`），
  换平台不会有同样的崩溃 —— 但用 `poll()` 本身也是更稳妥的选择（无 fd 宽度限制）。
- 若后续新增任何 fd 等待/多路复用代码，**一律用 `poll()`**，不要再引入 `select()`。
  已确认仓库内生产代码当前无 `select()`/`FD_SET` 残留
  （逐一核对：自有 C/C++ 里只剩**说明性注释**；ArkTS 的 `.select(...)` 是列表选中，
  与 socket 无关）。产物层面也只剩 mbedTLS 里运行期不可达的那份（见上）。
- **新增单测必须同时登记 CI**：`.github/workflows/build.yml` 会遍历
  `native/core/tests/test_*.cpp`，遇到未登记的测试直接报错并让整个任务失败
  （`新增的测试 $name 尚未在本工作流登记编译源文件`）。本次 `test_socket_util` 就漏了这一步，
  已在同一 PR 内补上（`extra=""`，因 `socket_util.h` 是 header-only）。
  `scripts/force-build.ps1` 那份登记当时已加，两处需一起维护。
