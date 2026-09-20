# 播放页进度条"拖不动"修复（设备实测）

## 一、用户报告的现象

> 修复无法滑动调整时间轴的 bug

即：在播放页拖动底部进度条，位置不跟手 / 松手后又跳回去。

## 二、先纠正一个误判（重要）

排查初期曾把"在进度条上拖 60px，位置从 21:09 跳到 34:23（+9 分钟）"当成
"拖动失控"的证据，并据此写进了代码注释。**这个判断是错的**，必须纠正：

本片（97 家有喜事，时长 `1:32:37` = 5557s）的进度条 `Slider` 实测：

| 项 | 实测值 |
|---|---|
| `Slider` 节点 bounds | `[311,2244][930,2379]` |
| 轨道可视宽度 | 619px |
| 有效轨道（`OutSet` + `blockSize 18`，两端各让出滑块半径 9px） | ≈ x∈[355, 887]，宽 ≈ 532px |
| 换算比例 | 5557s / 532px ≈ **10.45 s/px** |

所以 **60px 对应约 10 分钟是正常比例**，一点都没有失控。

### 标定方法（可复现）

在轨道上点一串已知 x 坐标，用 `uitest dumpLayout` 读出 `Slider` 的值，
反推坐标→时间的线性映射：

```bash
export TMPDIR=/tmp/hdc-zhonxinya
HDC=.../sdk/default/openharmony/toolchains/hdc
CMD=""
for x in 350 450 550 650 750 850 950; do
  CMD="$CMD uitest uiInput click $x 2311; sleep 0.8; uitest dumpLayout -p /data/local/tmp/cal_$x.json;"
done
"$HDC" shell "$CMD"
```

实测线性度极好（拟合 `ms = 5722·x - 299122`，即 5.72 s/px 于 619px 粗轨），
证明 `click` 定位是**位置精确映射**的，可作标尺使用。

## 三、真正的根因

`Slider({ value: this.positionMs })` 是**受控组件** —— 任何对 `positionMs`
的异步回写都会把滑块**弹回**，用户的手指与滑块脱开，拖动被中止。

而播放页里恰好有一个每秒一次的回写：

```
playback 启动 (setInterval 1000ms)
  → refreshState()
      → this.positionMs = this.avPlayer.currentTime     // ← 覆写，滑块被弹回
```

两点佐证这个判断：

1. **只在播放态出现**：暂停时 `if (this.isPlaying) this.refreshState()` 不成立，
   没有回写，所以暂停下能拖；播放时每秒被弹回一次。
2. **播放态 vs 暂停态实测对比**（同一拖动动作，`swipe 450 2311 650 2311`）：

| 状态 | 结果 |
|---|---|
| 暂停态 | 位移 187.9px（期望 200px）✅ |
| 播放态（修复前） | 位移 **8.2px** ❌ 被回写打断 |

另有第二个结构性问题：**全屏透明手势层与 `Slider` 抢同一次水平拖动**。
手势层把水平拖动一律判成 seek（`seekDragMs = totalX * 2`）并在抬手时 `seekTo`，
与 `Slider` 各算一次（谁生效取决于事件分发顺序）。

## 四、修复

### 4.1 拖动期间冻结进度回写（核心）

新增 `sliderDragging` 标志，`Slider.onChange` 按 `SliderChangeMode` 分阶段处理：

```ts
.onChange((value: number, mode: SliderChangeMode) => {
  if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
    this.sliderDragging = true;      // ← 冻结 refreshState 的回写
    this.positionMs = Math.floor(value);
    return;
  }
  // End / Click：落地
  this.sliderDragging = false;
  this.positionMs = Math.floor(value);
  this.seekTo(Math.floor(value));
})
```

`refreshState()` 开头提前返回：

```ts
if (this.sliderDragging || this.gestureAxis === 'seek') {
  return;   // 拖动期间滑块只跟手指走
}
```

> 顺带修掉了一个性能问题：原实现在**每一帧** `onChange` 都调 `seekTo`。
> 硬解要不停 flush 管线、软解要重排 seek，表现是"拖起来一顿一顿"。
> 现在改为**拖动预览、松手定位**（主流播放器形态）。

### 4.2 兜底清理 + 看门狗（防止标志卡死）

若 `Begin` 之后没有收到 `End`/`Cancel`，`sliderDragging` 会永久为 true，
`refreshState()` 一直提前返回 → **进度条再也不走、字幕也不再刷新**，
这比原缺陷更糟。两道防线：

**第一道：按触摸归属清理。** 在手势层**非底部控制区**的 `onGestureDown` 里无条件清掉：

```ts
// 能走到这里说明按下点不在底部控制区，不可能是在拖滑块
this.sliderDragging = false;
this.sliderDragTs = Date.now();
```

**第二道：看门狗。** 事件序列可能**整条丢失**（系统手势/来电抢占，
或注入式触摸只投递了 `Down` 而丢了 `Move/Up` —— 本机 `uitest uiInput swipe`
实测约三成丢事件），此时第一道防线也不一定触发。因此记录最后事件时刻：

```ts
const kSliderDragStaleMs: number = 1500;   // 拖动事件多久没来就判定已结束

if (this.sliderDragging) {
  if (Date.now() - this.sliderDragTs > kSliderDragStaleMs) {
    this.sliderDragging = false;   // 自动解除冻结
  } else {
    return;
  }
}
```

`onChange` 的 `Begin`/`Moving`/`End` 各分支都会刷新 `sliderDragTs`。
正常情况下 `Moving` 间隔只有约 16ms，1500ms 的阈值比它宽两个数量级，
**只有真的没有事件了才会触发**；实测极慢拖动（`velocity 150`，约 1s 走完全程）
也不会误触发（见第五节）。

> 这个看门狗是必要的：写本文档时第一次只加了 4.1 的冻结，设备上就复现过
> "拖动后进度条永久停住"。加上看门狗后实测拖完立即恢复走动。

### 4.3 手势层让开底部控制区

新增常量与判定：

```ts
const kBottomControlZoneVp: number = 200;

private isInBottomControlZone(y: number): boolean {
  const dens: number = this.density();
  if (dens <= 0) { return false; }
  const screenHeightPx: number = this.areaHeight() * dens;
  if (screenHeightPx <= 0) { return false; }
  return y >= screenHeightPx - kBottomControlZoneVp * dens;
}
```

按下若落在该区，标记 `gestureAxis = 'control'` 并**直接返回**，
后续 Move/Up 据此整段忽略（不参与手势判定，点击由 Button/Slider 自己处理）。
归属在**按下那一刻**确定，手指中途移出控制区也不会被手势"抢"回去。

取值依据：底部控制区实测自 `y=2190px` 起（屏高 2844px、density 3.375）
→ `(2844-2190)/3.375 ≈ 194vp`，取 200vp 留余量。
（横屏时"底部"仍是屏幕下边缘，同一判定成立。）

## 五、设备验证（Pura70Pro 模拟器，HarmonyOS 6.1.1 API 24）

验证方式：`uitest uiInput swipe` 注入拖动，`uitest dumpLayout` 读 `Slider` 的值，
用第二节标定出的映射反推"落点 x"，与手指终点比较。

> **注意总时长要按当前播放的片子读取**（从界面上"总时长"文本解析），
> 不要硬编码 —— 用错时长会把"正确跟随"误判成"未跟随"（本文档写作过程中踩过）。

**修复后（同一片 1:35:28 = 5728000ms）**：

| 手指终点 x | 落点反推 x | 偏差 | 拖动时长参数 |
|---|---|---|---|
| 700 | 695.4 | -4.6px ✅ | 1000 |
| 500 | 512.6 | +12.6px ✅ | 1000 |
| 850 | 845.7 | -4.3px ✅ | 1000 |
| 620 | 600.3 | -19.7px ✅ | 1000 |
| 750 | 747.5 | -2.5px ✅ | **150（极慢，约 1s 走完）** |

结论：**落点精确跟随手指位置**，播放态与暂停态表现一致；
极慢拖动也不会触发看门狗误释放（4.2 的阈值经此验证是安全的）。

**修复前对照**（同一拖动动作，`swipe 450 2311 650 2311`，期望位移 200px）：

| 状态 | 实际位移 |
|---|---|
| 暂停态 | 187.9px ✅ |
| 播放态 | **8.2px** ❌ 被每秒进度回写打断 |

**看门狗有效性**：拖动后恢复播放，实测进度在 2 秒内
`2906142ms → 2909370ms`（增长 3.2s），**进度条正常走动**，冻结被正确释放。

### 关于触摸注入的可靠性（重要）

本机 `uitest uiInput swipe` 有**约三成丢事件**（实测失败时读数**完全不变**，
即落点 = 起点，说明整条注入事件没被应用收到）。

因此**不能用单次 swipe 判定"功能没生效"**；要么重复 ≥5 次取统计，
要么在同一 shell 会话内做 before/after 对照。
`uitest uiInput click` 的定位则很准（第二节的标定能证明），只有 `swipe` 容易丢。

### 边界情形

- 拖到片尾后再拖会无响应 —— 已到内容末尾，属正常边界，与本次修复无关。
- 拖动后画面正确跳到目标位置，播放继续。

### 复现脚本（可直接复用，不入库）

```bash
# /tmp/vfy.sh <终点x> —— 自动读总时长、自动探测控件可见性
/tmp/vfy.sh 800
```

要点：
- 先 `dumpLayout` 探测 `Slider` 是否存在，不存在才单击唤出
  （播放页控件 5s 自动隐藏，且**单击是 toggle**，连点两次 = 显了又隐）。
- **暂停态控件常驻**（`scheduleHideControls` 里只在 `isPlaying` 时隐藏），
  需要稳定连续采样时应先暂停。

## 六、已知既有问题（本次未改，勿误判为回归）

- 手势层的"水平拖动调进度"幅度是 `seekDragMs = totalX * 2`，
  **固定 2ms/px，与片长无关**。也就是说在 92 分钟的片子上，
  想靠手势滑到中间要滑非常远。这是设计取值，不是本次引入的问题；
  若要改成"按片长/屏宽比例"，需重新实测后再动。
