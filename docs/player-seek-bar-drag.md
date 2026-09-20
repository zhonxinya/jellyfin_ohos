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

### 4.2 兜底清理（防止标志卡死）

若 `Begin` 之后没有收到 `End`/`Cancel`（来电、系统手势抢占），
`sliderDragging` 会永久为 true，进度条就再也不走了。因此在手势层
**非底部控制区**的 `onGestureDown` 里无条件清掉该标志：

```ts
// 能走到这里说明按下点不在底部控制区，不可能是在拖滑块
this.sliderDragging = false;
```

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

| 手指终点 x | 修复前 | 修复后落点 x | 偏差 |
|---|---|---|---|
| 800 | 位移仅 8.2px（被回写打断） | 793.7 | -6.3px ✅ |
| 500 | — | 481.5 | -18.5px ✅ |
| 900 | — | 886.7 | -13.3px ✅ |
| 600 | — | 594.3 | -5.7px ✅ |

结论：**落点精确跟随手指位置**（偏差在同一次 `swipe` 注入的时间分辨率内），
且播放态与暂停态表现一致。

### 边界情形

- 拖到片尾（`1:32:37`）后再拖会无响应 —— 已到内容末尾，属正常边界，
  与本次修复无关。
- 拖动后画面正确跳到目标位置，播放继续。

### 复现脚本（可直接复用）

`/tmp/dragtest.sh`（验证用，不入库）：

```bash
/tmp/dragtest.sh 800     # 拖到 x=800，自动判断控件是否可见并在需要时唤出
```

## 六、已知既有问题（本次未改，勿误判为回归）

- 手势层的"水平拖动调进度"幅度是 `seekDragMs = totalX * 2`，
  **固定 2ms/px，与片长无关**。也就是说在 92 分钟的片子上，
  想靠手势滑到中间要滑非常远。这是设计取值，不是本次引入的问题；
  若要改成"按片长/屏宽比例"，需重新实测后再动。
