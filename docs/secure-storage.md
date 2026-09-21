# 敏感数据加密存储（禁止明文落盘）

本文记录「提升软件安全性，禁止明文保存」这一目标的实现方案、约束与验证方法。
**改动前请先读完本文，尤其是「硬约束」一节。**

## 背景：改动前的问题

改动前，应用把会话与其它持久化数据直接写进 `preferences`（`@ohos.data.preferences`）。

`preferences` 是**明文** XML 文件，落盘路径：

```
/data/app/el2/100/base/com.zhonxinya.jellyfin_hmos_flutter/preferences/jellyfin_session
```

设备实测（改动前）该文件可直接 `cat`，内容形如：

```xml
<string key="session_json">{"accessToken":"<32 字符令牌>","baseUrl":"http://<host>:<port>","userId":"…",…}</string>
<string key="server_url">http://<host>:<port></string>
<string key="last_username">…</string>
```

即：**拿到文件即拿到令牌**，可冒充用户访问其 Jellyfin 服务器。这在应用市场上架审核与安全要求下都不可接受。

## 方案

```
        ┌──────────────────────────────────────────┐
        │ SessionStore（唯一持久化入口）             │
        │  writeStored / readStored / readDecrypted │
        └───────────────┬──────────────────────────┘
                        │ 明文
                        ▼
        ┌──────────────────────────────────────────┐
        │ SecureStore                              │
        │  AES-256-GCM 加密/解密（cryptoFramework）  │
        │  信封：enc:v1:<base64(iv||ct||authTag)>   │
        └───────────────┬──────────────────────────┘
                        │ 32 字节主密钥
                        ▼
        ┌──────────────────────────────────────────┐
        │ 系统关键资产存储（@ohos.security.asset）    │
        │  别名 jellyfin_hmos_master_key_v1          │
        │  系统侧用硬件/TEE 派生密钥加密后落盘         │
        └──────────────────────────────────────────┘
                        │ 密文
                        ▼
        preferences/jellyfin_session（XML，全文无可读业务数据）
```

### 为什么是「Asset 存密钥 + preferences 存密文」

- 单纯把密钥硬编码或固定生成，等于没有加密：攻击者拿到应用包就能解密。
- `Asset Store Kit`（关键资产存储服务）的密钥**不进入应用数据目录**，由系统托管，
  普通文件读取、应用数据备份都拿不到，因此适合放主密钥。
- 业务数据继续放 `preferences`，好处是不改动既有读写路径与容量假设，
  同时 `preferences` 的 `MAX_VALUE_LENGTH` 是 8192 字符 —— 密文是 Base64，
  会话 JSON（实测约 480 字符）加密后仍在限额内。

### 为什么用 AES-GCM 而不是 AES-CBC

GCM 自带完整性校验（authTag）。密文若被篡改或截断，解密会**直接失败**，
不会被当成合法明文继续使用；CBC 没有这个能力，需要额外做 MAC。

## 硬约束（改代码前必读）

1. **禁止绕过 `SessionStore` 的 `writeStored()` 直接 `pref.put()` 写业务数据。**
   所有持久化必须经过加密层。`readStored` / `readDecrypted` 同理。
2. **禁止把密钥写进 `preferences`、资源文件、代码常量或日志。**
   密钥只允许存在于 `Asset Store Kit` 中。
3. **加密失败必须失败，不允许降级成明文写入。**
   `SecureStore.encrypt()` 在底座不可用时抛异常，`writeStored()` 会中止写入并记录错误日志
   —— 宁可写不进去，也不能悄悄写明文。
4. **解密失败不能当成明文。**
   `SecureStore.decrypt()` 对「信封格式但解密失败」返回空串，
   调用方必须把空串当「无数据」处理，绝不能把密文当业务数据用。
5. **不要删除 `ohos.permission.STORE_PERSISTENT_DATA`。**
   该权限是 `Asset.Tag.IS_PERSISTENT` 生效的前提，去掉它会导致设备重启后主密钥丢失、
   用户被迫重新登录。
6. **历史明文必须自动迁移，不能只靠新写入覆盖。**
   只在写入路径加密是不够的：`last_username` 走的是同步读取路径
   （`getLastUsernameStorage()`），`search_history` 在读取为空时会直接返回，
   两者都不会触发迁移。因此 `SessionStore.doInit()` 里有一个**同步一次性迁移**
   `migratePlaintextAtRest()`，扫全部 6 个已知键，遇到明文立即加密回写。该函数幂等。
7. **"密钥取不到" 与 "数据解不开" 必须分开处理，这是最容易写出严重 bug 的地方。**

   `SecureStore.decrypt()` 的三种返回契约：

   | 情况 | 返回 | 调用方该怎么做 |
   | --- | --- | --- |
   | 值为空 | `''` | 当作没有数据 |
   | 值是历史明文 | 原样返回 | 触发迁移（写回密文） |
   | 值是密文但解不开（被篡改/截断，或主密钥已被删除） | `''` | **可以丢弃**：密钥是可用的，这段数据永远不可恢复 |
   | 主密钥**暂时**取不到（资产服务异常等） | **抛 `KEY_UNAVAILABLE`** | **绝不能丢弃数据**，应当重试 |

   第 3 与第 4 行如果混为一谈，会出现两种严重故障（本项目都实际踩到过）：

   - 把第 4 行当第 3 行 → 一次瞬时故障就把用户完好登录态清掉；
   - 把第 3 行当第 4 行 → 用户点过"清除本地数据"后，残留的旧密文永远解不开，
     应用每次冷启动都卡在「启动失败」，**再也进不去**。

   同理，取密钥时**只有 `NOT_FOUND` 才允许新建密钥**。若把其它异常也当作"不存在"
   去新建并覆盖，一次瞬时故障就会让历史密文永久不可解（见 `SecureStore.getSymKey()`）。
8. **不可解的死数据要及时清掉。** `loadSession()` 与 `readDecrypted()` 在确认
   "密钥可用但数据解不开"时会顺手删除该键，避免设备上长期残留按旧密钥加密的死值。

## 涉及文件

| 文件 | 作用 |
| --- | --- |
| `native/app/entry/src/main/ets/services/SecureStore.ets` | 加密底座：主密钥管理 + AES-256-GCM 加解密 + 信封编解码 |
| `native/app/entry/src/main/ets/services/SessionStore.ets` | 唯一持久化入口，全部键加密落盘 + 旧明文迁移 |
| `native/app/entry/src/main/ets/common/LegalTexts.ets` | 隐私政策中的存储/权限说明（政策版本随改动递增） |
| `native/app/entry/src/main/module.json5` | 声明 `ohos.permission.STORE_PERSISTENT_DATA` |

### 落盘的 6 个键

| Key | 内容 | 敏感级别 |
| --- | --- | --- |
| `session_json` | 会话 JSON（含 `accessToken` / `baseUrl` / `userId` / 偏好） | 高 |
| `server_url` | 服务器地址 | 中 |
| `last_username` | 最近登录用户名 | 中 |
| `search_history` | 搜索历史（可反推观看偏好） | 中 |
| `device_id` | 设备标识 | 低 |
| `legal_consent_version` | 隐私政策同意版本 | 低 |

> 注意：`device_id` 与 `legal_consent_version` 属于「无需加密」的低敏感数据，
> 但本实现把它们一并加密，统一路径、减少「忘记加密」的机会。

## 设备验证方法（可复现）

```bash
export TMPDIR=/tmp/hdc-zhonxinya
T=~/workspace/harmony-sdk-6.1.1/extracted/command-line-tools
HDC="$T/sdk/default/openharmony/toolchains/hdc"
B=com.zhonxinya.jellyfin_hmos_flutter
F=/data/app/el2/100/base/$B/preferences/jellyfin_session
```

### 1. 逐键判定存储形态（不打印敏感值）

```bash
"$HDC" shell "cat $F" > /tmp/session.xml
python3 - <<'PY'
import re
raw=open('/tmp/session.xml',encoding='utf-8',errors='replace').read()
for m in re.finditer(r'<(string|int|bool|float) key="([^"]+)"(?:\s*/>|>([^<]*)</\1>)', raw):
    key, val = m.group(2), m.group(3) or ''
    kind='(empty)' if val=='' else ('ENCRYPTED len=%d'%len(val) if val.startswith('enc:v1:') else 'PLAINTEXT len=%d'%len(val))
    print(f'{key:24} {kind}')
PY
```

期望输出（6 行全部 ENCRYPTED）：

```
device_id                ENCRYPTED len=87
session_json             ENCRYPTED len=627
legal_consent_version    ENCRYPTED len=59
last_username            ENCRYPTED len=51
search_history           ENCRYPTED len=643
server_url               ENCRYPTED len=79
```

### 2. 全沙箱按内容搜令牌（最硬的一条判据）

从改动前保存的明文基线里取出令牌，然后按**内容**（不是文件名）搜整个沙箱。
命中文件数必须为 `0`：

```bash
TOKEN=$(python3 -c "
import re,html
raw=open('/tmp/session_baseline.xml',encoding='utf-8',errors='replace').read()
inner=html.unescape(re.search(r'<string key=\"session_json\">([^<]*)</string>',raw).group(1))
print(re.search(r'\"accessToken\"\s*:\s*\"([^\"]+)\"',inner).group(1))")
"$HDC" shell "grep -rl '$TOKEN' /data/app/el2/100/base/$B/ 2>/dev/null | wc -l"   # 期望 0
```

### 3. 功能性回归（确认加密没把功能改坏）

```bash
"$HDC" shell "aa force-stop $B; aa start -a EntryAbility -b $B"; sleep 12
"$HDC" shell "uitest dumpLayout -p /data/local/tmp/a.json"
"$HDC" file recv /data/local/tmp/a.json /tmp/boot.json
```

- 冷启动应直接进**已登录首页**（出现「首页 / 媒体库 / 继续观看 / 设置」），而不是登录页
  —— 证明主密钥在跨进程 / 重启后仍可用。
- 进「设置」页，用户名与服务器地址应正常显示
  —— 证明 AES-GCM 解密回读正确（不是解出乱码）。

## 踩坑记录

- **`preferences.put` 是异步、`getSync` 是同步**：`getLastUsernameStorage()` 必须在登录页
  同步取值，所以同步链路上用的必须是 `cryptoFramework` 的 `*Sync` 接口与 `asset.querySync`。
  `migratePlaintextAtRest()` 也必须是同步的（在 `doInit()` 里 `flushSync()`）。
- **只靠「读哪个键迁移哪个键」会漏**（本轮实测就漏了 `last_username` 与 `search_history`），
  必须在初始化时对全部已知键做一次性扫描迁移。
- **`Asset` 的 `Alias` 与 `Secret` 都是 `Uint8Array`**，不是字符串。
- **`Tag.IS_PERSISTENT` 需要权限**，缺权限时行为不是报错而是重启后密钥失效。
- **`asset.addSync` 在别名已存在时抛 `24000003`**，属于可接受的并发情形，
  代码里显式吞掉（配合 `CONFLICT_RESOLUTION = OVERWRITE` 更稳）。
- **ArkTS 严格空值检查**：`Uint8Array | null` 不能直接赋给 `Uint8Array`
  （`Type 'Uint8Array | null' is not assignable to type 'Uint8Array'`）。
  需要先判 `null` 再用局部变量承接。
- **"主密钥丢失 + 密文残留"是真实可达状态**：用户在设置里点「清除全部本地数据」
  就会得到它。所有读取路径都必须能正常退化，不能卡死。

## 已验证结论（本轮）

| 验证项 | 方法 | 结果 |
| --- | --- | --- |
| 6 个键全部加密落盘 | 设备读 `preferences` 逐键判定 | 全部 `ENCRYPTED` |
| 令牌无明文副本 | 用真实令牌全沙箱按内容 `grep -rl` | 命中文件数 **0** |
| 加密不破坏登录态 | 冷启动 + 设置页显示用户名/服务器 | 直接进已登录首页，显示正确 |
| 主密钥跨进程/重启可用 | 连续两次冷启动 | 均保持登录 |
| 历史明文自动迁移 | 构造全明文文件（假值）后启动 | 4 个明文键全部变密文，明文残留 0 |
| 迁移幂等 | 二次冷启动 | 无重复迁移日志 |
| 迁移后解密正确 | 迁移后看登录页回填 | 服务器地址、用户名均正确显示 |
| 真实会话恢复 | 历史明文会话（含有效令牌）→ 启动 | 迁移后进入已登录首页 |
| 真实会话冷启动保持 | 上一步后 `force-stop` + 重启 | 仍直接进已登录首页 |
| 清除数据销毁密钥 | 清除后把旧密文写回并重启 | 无法解密，正常退回到连接服务器页 |
| 不可解密文不卡启动 | 密钥已删 + 旧密文残留 | 正常进入连接服务器页（回归已修） |

> 复现「真实会话恢复」时注意：`preferences` 里 `session_json` 存的是 SessionUtil 的
> 信封结构 `{ok, data:{accessToken, baseUrl, userId, ...}}`，会话字段在 `data` 下。
> 伪造测试数据时必须带上这层信封，否则 `restoreSession` 必然失败
> （这不是应用缺陷，是测试数据构造错误）。
