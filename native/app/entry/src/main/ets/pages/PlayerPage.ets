import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import media from '@ohos.multimedia.media';
import display from '@ohos.display';
import image from '@ohos.multimedia.image';
import componentSnapshot from '@ohos.arkui.componentSnapshot';
import fs from '@ohos.file.fs';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { WindowLayout } from '../common/WindowLayout';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { formatSeconds } from '../common/format';
import { AppIconButton } from '../components/AppIconButton';
import { ChipButton } from '../components/ChipButton';
import { EmptyState } from '../components/EmptyState';

/** 控制条自动隐藏延时（毫秒）：给用户留出"看到并点中控件"的时间 */
const kControlsAutoHideMs: number = 5000;

@Entry
@Component
struct PlayerPage {
  @State private itemId: string = '';
  @State private title: string = '播放';
  /** 集数/季信息文案：参数解析时一次性算好，不在 build 里调用 getter（见下方稳定性修复说明） */
  @State private typeLabel: string = '';
  @State private playUrl: string = '';
  @State private stateText: string = 'idle';
  @State private positionMs: number = 0;
  @State private durationMs: number = 0;
  @State private isPlaying: boolean = false;
  @State private status: string = UiState.INITIAL;
  /** FFmpeg 软解回放状态：逐帧拉取并用 PixelMap 渲染（硬解不支持的编码走这条路） */
  @State private softPlaying: boolean = false;
  /** 是否已因硬解失败自动回退过软解（只回退一次） */
  private softFallbackTried: boolean = false;
  @State private softStatus: string = '';
  /** 诊断结果（渲染自检/存帧），独立于逐帧状态，避免被 70ms 刷新覆盖 */
  @State private softDiag: string = '';
  private softTimerId: number = -1;
  private softPulling: boolean = false;
  @State private errorMsg: string = '';
  @State private showControls: boolean = true;
  @State private playbackSpeed: number = 1.0;
  @State private controlsLocked: boolean = false;
  @State private volume: number = 1.0;
  @State private showVolumeBar: boolean = false;
  @State private gestureFeedback: string = '';
  @State private gestureIcon: string = '';
  @State private gestureRatio: number = -1;
  @State private showFeedback: boolean = false;
  private brightnessBase: number = 0.5;
  private brightnessLastY: number = 0;
  private volumeBase: number = 1.0;
  private volumeLastY: number = 0;
  private playbackOptions: string = '{}';
  private stopped: boolean = false;
  private timerId: number = -1;
  private hideTimerId: number = -1;
  private feedbackTimerId: number = -1;
  private seekBaseMs: number = 0;
  private seekDragMs: number = 0;
  private seekLastX: number = 0;
  private lastSeekForward: boolean = true;
  private avPlayer: media.AVPlayer | null = null;
  private surfaceId: string = '';
  /** XComponent 控制器：surface 就绪后用它拿到 surfaceId（软解 EGL 渲染与 AVPlayer 共用） */
  private surfaceController: XComponentController = new XComponentController();
  /** XComponent 组件像素尺寸（vp → px），用于 EGL 缓冲几何 */
  private surfaceWidthPx: number = 0;
  private surfaceHeightPx: number = 0;

  // 支持倍速列表
  static readonly SPEEDS: number[] = [0.5, 1.0, 1.25, 1.5, 2.0];

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idVal: Object | undefined = params['itemId'];
      const titleVal: Object | undefined = params['title'];
      const urlVal: Object | undefined = params['playUrl'];
      const optsVal: Object | undefined = params['playbackOptions'];
      if (typeof idVal === 'string') {
        this.itemId = idVal;
      }
      if (typeof titleVal === 'string' && titleVal.length > 0) {
        this.title = titleVal;
      }
      if (typeof urlVal === 'string') {
        this.playUrl = urlVal;
      }
      if (typeof optsVal === 'string') {
        this.playbackOptions = optsVal;
      }
    }
    this.typeLabel = this.computeTypeLabel();
    this.openPlayer();
    this.timerId = setInterval(() => {
      if (this.isPlaying) {
        this.refreshState();
      }
    }, 1000);
    this.scheduleHideControls();
  }

  onPageHide(): void {
    this.flushStop();
  }

  aboutToDisappear(): void {
    // 离开播放页必须停掉软解会话（解码线程 + 取流都要释放）
    this.stopSoftPlay();
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    if (this.hideTimerId >= 0) {
      clearTimeout(this.hideTimerId);
      this.hideTimerId = -1;
    }
    if (this.feedbackTimerId >= 0) {
      clearTimeout(this.feedbackTimerId);
      this.feedbackTimerId = -1;
    }
    this.flushStop();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private scheduleHideControls(): void {
    if (this.hideTimerId >= 0) {
      clearTimeout(this.hideTimerId);
      this.hideTimerId = -1;
    }
    if (this.controlsLocked || !this.showControls) {
      return;
    }
    // 自动隐藏时间：3s → 5s。3 秒对"找到并点中某个控件"偏紧（用户与自动化都容易错过），
    // 5 秒是主流播放器的常见取值；播放中控件仍会自动让位给画面。
    this.hideTimerId = setTimeout(() => {
      if (this.isPlaying && !this.controlsLocked) {
        this.showControls = false;
      }
    }, kControlsAutoHideMs);
  }

  private revealControls(): void {
    this.showControls = true;
    this.scheduleHideControls();
  }

  private dismissFeedback(): void {
    if (this.feedbackTimerId >= 0) {
      clearTimeout(this.feedbackTimerId);
    }
    this.feedbackTimerId = setTimeout(() => {
      this.showFeedback = false;
      this.gestureFeedback = '';
      this.gestureIcon = '';
      this.gestureRatio = -1;
    }, 700);
    this.scheduleHideControls();
  }

  private formatTime(ms: number): string {
    return formatSeconds(Math.max(0, Math.floor(ms / 1000)));
  }

  /**
   * 启动 FFmpeg 软解回放：打开流式软解会话，然后由定时器逐帧拉取并用 PixelMap 渲染。
   *
   * 为什么需要：系统 AVPlayer 只走硬解，模拟器/部分设备解不了 HEVC 等编码；
   * 软解用 FFmpeg 在 CPU 上解码，虽然帧率有限，但能把这些内容放出来。
   */
  private async startSoftPlay(): Promise<void> {
    this.softStatus = '正在打开软解会话…';
    // 硬解失败后应停掉 AVPlayer，避免两路同时读流（同时把 surface 让给 EGL）
    this.softStopAvPlayer();
    const pxSize: number[] = this.surfacePixelSize();
    // XComponent 为 TEXTURE 类型：surfaceId 是 GL 纹理 id，原生侧走 OH_NativeImage 渲染并发布
    const raw: string = await JellyfinNative.softPlayOpen(this.itemId, this.surfaceId, pxSize[0],
                                                          pxSize[1], 'xcomponent', this.playbackOptions);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.softStatus = `软解打开失败：${result.message}`;
      return;
    }
    const data: ESObject = result.data as ESObject;
    if (!JsonUtil.getBoolean(data, 'ok', false)) {
      this.softStatus = `软解打开失败：${JsonUtil.getString(data, 'error', '未知错误')}`;
      return;
    }
    this.softPlaying = true;
    const renderReady: boolean = JsonUtil.getBoolean(data, 'renderReady', false);
    const renderError: string = JsonUtil.getString(data, 'renderError', '');
    this.softStatus = `软解中：${JsonUtil.getString(data, 'videoCodec', '?')} `
      + `${JsonUtil.getNumber(data, 'width', 0)}x${JsonUtil.getNumber(data, 'height', 0)}`
      + ` · EGL ${renderReady ? '就绪' : '未就绪'}`
      + (renderError.length > 0 ? `（${renderError}）` : '');
    this.startSoftTimer();
    // 启动即自检（清屏为红并回读）：把"渲染目标是否可用"的判定一次性落到 softDiag，
    // 不依赖再点一次按钮（避免自动化/人工都容易错过的时序）
    const selfRaw: string = JellyfinNative.softPlaySelfTest();
    const selfResult: NativeResult = JellyfinNative.parseResult(selfRaw);
    if (selfResult.ok && selfResult.data !== null) {
      const passed: boolean = JsonUtil.getBoolean(selfResult.data as ESObject, 'ok', false);
      const report: string = JsonUtil.getString(selfResult.data as ESObject, 'report',
        JsonUtil.getString(selfResult.data as ESObject, 'error', ''));
      this.softDiag = `渲染自检${passed ? '通过' : '未通过'}：${report}`;
    }
    // 渲染跑起来后自动导出一次帧缓冲（真实视频帧），无需再点任何按钮
    setTimeout(() => {
      if (this.softPlaying) {
        this.autoDumpRenderedFrame();
      }
    }, 10000);
  }

  /** XComponent 的像素尺寸：优先用组件实测尺寸，未拿到时退化为整屏像素 */
  private surfacePixelSize(): number[] {
    if (this.surfaceWidthPx > 0 && this.surfaceHeightPx > 0) {
      return [this.surfaceWidthPx, this.surfaceHeightPx];
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return [d.width, d.height];
    } catch (err) {
      return [0, 0];
    }
  }

  /** surface 就绪即判定渲染目标可用性，结果写入常驻 softDiag（诊断入口，与播放状态无关） */
  private async probeRenderTarget(): Promise<void> {
    try {
      const pxSize: number[] = this.surfacePixelSize();
      const raw: string = JellyfinNative.renderTargetProbe(this.surfaceId, pxSize[0], pxSize[1],
        'xcomponent');
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        this.softDiag = `渲染目标判定失败：${result.message}`;
        return;
      }
      const data: ESObject = result.data as ESObject;
      const ok: boolean = JsonUtil.getBoolean(data, 'ok', false);
      const report: string = JsonUtil.getString(data, 'report',
        JsonUtil.getString(data, 'error', ''));
      const mode: string = JsonUtil.getString(data, 'mode', '');
      this.softDiag = `渲染目标(${mode}) ${ok ? '可用' : '不可用'}：${report}`;
    } catch (err) {
      this.softDiag = `渲染目标判定异常：${(err as Error).message}`;
    }
  }

  /** 逐帧拉取（约 70ms 一帧 ≈ 14fps；软解 + PixelMap 创建的开销决定上限） */
  private startSoftTimer(): void {
    this.stopSoftTimer();
    this.softTimerId = setInterval(() => {
      this.pullSoftFrame();
    }, 70);
  }

  private stopSoftTimer(): void {
    if (this.softTimerId !== -1) {
      clearInterval(this.softTimerId);
      this.softTimerId = -1;
    }
  }

  private async pullSoftFrame(): Promise<void> {
    if (this.softPulling || !this.softPlaying) {
      return;
    }
    this.softPulling = true;
    try {
      // 渲染由原生侧 EGL 完成，这里只取元数据（帧号/时间戳/取流字节/是否已渲染）。
      // 帧宽限制 640：模拟器 GL 为软件光栅化，上传 1920x1080 大纹理会明显拖慢甚至失败。
      const frame: ESObject | null = JellyfinNative.softPlayNextFrame(640);
      if (frame === null) {
        return;
      }
      const ok: boolean = JsonUtil.getBoolean(frame, 'ok', false);
      if (!ok) {
        const reason: string = JsonUtil.getString(frame, 'error', '');
        if (reason === 'eof') {
          this.softStatus = '软解播放结束';
          this.stopSoftPlay();
        } else if (reason.length > 0) {
          this.softStatus = `软解失败：${reason}`;
          this.stopSoftPlay();
        }
        return;
      }
      const pts: number = JsonUtil.getNumber(frame, 'ptsSec', 0);
      const idx: number = JsonUtil.getNumber(frame, 'frameIndex', 0);
      const fetched: number = JsonUtil.getNumber(frame, 'bytesFetched', 0);
      const rendered: boolean = JsonUtil.getBoolean(frame, 'rendered', false);
      const renderError: string = JsonUtil.getString(frame, 'renderError', '');
      this.softStatus = `${Math.floor(pts / 60)}:${this.pad2(Math.floor(pts % 60))}`
        + ` · 第 ${idx} 帧 · ${(fetched / 1048576).toFixed(1)} MB`
        + ` · ${rendered ? 'EGL 已渲染' : '未渲染'}`
        + (renderError.length > 0 ? `（${renderError}）` : '');
    } catch (err) {
      this.softStatus = `软解异常：${(err as Error).message}`;
    } finally {
      this.softPulling = false;
    }
  }

  /**
   * 诊断：软解运行一段时间后**自动**导出一次渲染缓冲（不含清屏自检，故回读到的是真实视频帧）。
   *
   * 为什么要自动：手动点「存帧」需要控制条处于显示状态，设备自动化下时序很难对齐；
   * 这条路径只要软解在跑就必然产出文件，便于确证"软解画面确实渲染到了帧缓冲"。
   */
  private async autoDumpRenderedFrame(): Promise<void> {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      // ① 组件级快照：XComponent(TEXTURE) 的内容由 ArkUI 合成，
      //    componentSnapshot 能抓到组件真实显示结果（系统 snapshot_display 未必包含）。
      const capturePath: string = `${ctx.cacheDir}/softcapture.png`;
      try {
        const shot: image.PixelMap = await componentSnapshot.get('softVideoArea');
        const packer: image.ImagePacker = image.createImagePacker();
        const buf: ArrayBuffer = await packer.packing(shot, { format: 'image/png', quality: 100 });
        const file = fs.openSync(capturePath, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
        fs.writeSync(file.fd, buf);
        fs.closeSync(file);
        this.softDiag = `已组件快照 → ${capturePath}`;
      } catch (snapErr) {
        this.softDiag = `组件快照失败：${(snapErr as Error).message}`;
      }
      // ② 原生渲染缓冲回读（TEXTURE 路径不支持时会明确报错，不再给误导性黑图）
      const path: string = `${ctx.cacheDir}/softrender_frame.png`;
      const raw: string = JellyfinNative.softPlayDumpFrame(path);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (result.ok && result.data !== null) {
        const source: string = JsonUtil.getString(result.data as ESObject, 'source', '');
        const w: number = JsonUtil.getNumber(result.data as ESObject, 'width', 0);
        const h: number = JsonUtil.getNumber(result.data as ESObject, 'height', 0);
        this.softDiag = `${this.softDiag}\n已自动存帧：${source} ${w}x${h}`;
      } else {
        this.softDiag = `${this.softDiag}\n自动存帧：${result.message}`;
      }
    } catch (err) {
      this.softDiag = `自动存帧异常：${(err as Error).message}`;
    }
  }

  /** 诊断：先做 EGL 渲染自检（清屏为红并回读），再把渲染缓冲回读成 PNG */
  private async dumpSoftFrame(): Promise<void> {
    try {
      // 自检结果直接进状态栏：能判别"surface 不可作为 GL 目标"与"绘制路径有 bug"
      const selfRaw: string = JellyfinNative.softPlaySelfTest();
      const selfResult: NativeResult = JellyfinNative.parseResult(selfRaw);
      if (selfResult.ok && selfResult.data !== null) {
        const ok: boolean = JsonUtil.getBoolean(selfResult.data as ESObject, 'ok', false);
        const report: string = JsonUtil.getString(selfResult.data as ESObject, 'report',
          JsonUtil.getString(selfResult.data as ESObject, 'error', ''));
        this.softDiag = `自检${ok ? '通过' : '未通过'}：${report}`;
      }
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const path: string = `${ctx.cacheDir}/softplay_frame.png`;
      const raw: string = JellyfinNative.softPlayDumpFrame(path);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (result.ok && result.data !== null) {
        const source: string = JsonUtil.getString(result.data as ESObject, 'source', '');
        const w: number = JsonUtil.getNumber(result.data as ESObject, 'width', 0);
        const h: number = JsonUtil.getNumber(result.data as ESObject, 'height', 0);
        this.softDiag = `${this.softDiag}\n已存帧：${source} ${w}x${h} → ${path}`;
      } else {
        this.softDiag = `${this.softDiag}\n存帧失败：${result.message}`;
      }
    } catch (err) {
      this.softDiag = `存帧异常：${(err as Error).message}`;
    }
  }

  private pad2(v: number): string {
    return v < 10 ? `0${v}` : `${v}`;
  }

  private softStopAvPlayer(): void {
    if (this.avPlayer !== null) {
      try {
        this.avPlayer.stop();
        this.avPlayer.release();
      } catch (err) {
        // 忽略：AVPlayer 已在错误态
      }
      this.avPlayer = null;
    }
  }

  private stopSoftPlay(): void {
    this.stopSoftTimer();
    JellyfinNative.softPlayClose();
    this.softPlaying = false;
  }

  private async openPlayer(): Promise<void> {
    this.status = UiState.LOADING;
    const target: string = this.playUrl.length > 0 ? this.playUrl : this.itemId;
    const raw: string = await JellyfinNative.playerOpen(target, this.playbackOptions);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '打开播放器失败';
      this.refreshState();
      return;
    }
    // 从 C++ 后端获取实际播放 URL
    const resolvedUrl: string = JsonUtil.getString(result.data, 'playUrl', '');
    if (resolvedUrl.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '无法获取播放地址';
      return;
    }
    // 创建 AVPlayer 进行实际视频渲染
    this.createAvPlayer(resolvedUrl);
  }

  private async createAvPlayer(url: string): Promise<void> {
    try {
      this.avPlayer = await media.createAVPlayer();
      this.avPlayer.on('stateChange', (state: string) => {
        this.stateText = state;
        if (state === 'initialized') {
          // ⚠️ 关键修复：AVPlayer 状态机为 idle →(设置 url)→ initialized →prepare()→ preparing → prepared。
          // 原实现只设置 url 就等待 'prepared'，从不调用 prepare()，播放器会永远停在 initialized，
          // 界面一直显示"加载播放器..."（设备实测：H.264/MP4 也一样起不来）。
          this.avPlayer?.prepare();
        } else if (state === 'prepared') {
          this.durationMs = (this.avPlayer?.duration ?? 0);
          this.status = UiState.SUCCESS;
          this.avPlayer?.play();
          this.isPlaying = true;
          this.revealControls();
        } else if (state === 'completed') {
          this.isPlaying = false;
          this.revealControls();
          if (this.itemId.length > 0) {
            JellyfinNative.reportPlaybackStopped(this.itemId, this.positionMs * 10000);
          }
        } else if (state === 'error') {
          this.handlePlaybackFailure('播放出错');
        }
      });
      this.avPlayer.on('error', (_err: Error) => {
        this.handlePlaybackFailure('播放器错误');
      });
      // 如果 surfaceId 已经从 XComponent.onLoad 获取到，立即绑定
      if (this.surfaceId.length > 0) {
        this.avPlayer.surfaceId = this.surfaceId;
      }
      // 设置 URL 触发 AVPlayer 加载视频流
      this.avPlayer.url = url;
    } catch (_err) {
      this.handlePlaybackFailure('初始化播放器失败');
    }
  }

  /**
   * 播放失败统一入口：进入错误态，并尝试**自动回退到 FFmpeg 软解**。
   *
   * 这是"播放功能（硬解 + 软解）"的落地：系统硬解解不了的编码（如模拟器上的 HEVC、
   * 设备上不支持的 profile）不应直接把用户丢在错误页，而应自动改用 CPU 软解续播。
   * 只回退一次，避免与用户手动"重试"互相打架。
   */
  private handlePlaybackFailure(message: string): void {
    this.status = UiState.ERROR;
    this.errorMsg = message;
    this.maybeFallbackToSoftDecode(message);
  }

  private async maybeFallbackToSoftDecode(reason: string): Promise<void> {
    if (this.softFallbackTried || this.softPlaying) {
      return;
    }
    this.softFallbackTried = true;
    this.softDiag = `硬解不可用（${reason}）→ 自动切换 FFmpeg 软解…`;
    await this.startSoftPlay();
    if (!this.softPlaying) {
      // 软解也起不来时回到错误态，让用户看到原因并手动重试
      this.status = UiState.ERROR;
    }
  }

  private refreshState(): void {
    if (this.avPlayer !== null) {
      this.positionMs = this.avPlayer.currentTime;
      this.durationMs = this.avPlayer.duration;
      this.isPlaying = this.avPlayer.state === 'playing';
    }
  }

  private onPlayPause(): void {
    if (this.avPlayer === null) {
      return;
    }
    if (this.isPlaying) {
      this.avPlayer.pause();
      this.isPlaying = false;
      if (this.itemId.length > 0) {
        JellyfinNative.reportPlaybackProgress(this.itemId, this.positionMs * 10000, true);
      }
      this.showControls = true;
    } else {
      this.avPlayer.play();
      this.isPlaying = true;
      if (this.itemId.length > 0) {
        JellyfinNative.reportPlaybackProgress(this.itemId, this.positionMs * 10000, false);
      }
      this.scheduleHideControls();
    }
    this.refreshState();
  }

  private onSeek(deltaMs: number): void {
    if (this.avPlayer === null) {
      return;
    }
    const next: number = Math.max(0, this.positionMs + deltaMs);
    this.avPlayer.seek(next);
    this.positionMs = next;
    this.refreshState();
    this.revealControls();
  }

  private cycleSpeed(): void {
    const speeds: number[] = PlayerPage.SPEEDS;
    const currentIdx: number = speeds.indexOf(this.playbackSpeed);
    const nextIdx: number = (currentIdx + 1) % speeds.length;
    this.playbackSpeed = speeds[nextIdx];
    if (this.avPlayer !== null) {
      this.avPlayer.setPlaybackRate(this.playbackSpeed);
    }
    this.revealControls();
  }

  private flushStop(): void {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    if (this.itemId.length > 0) {
      JellyfinNative.reportPlaybackStopped(this.itemId, this.positionMs * 10000);
    }
    if (this.avPlayer !== null) {
      this.avPlayer.stop();
      this.avPlayer.release();
      this.avPlayer = null;
    }
    JellyfinNative.playerStop();
  }

  private sliderMax(): number {
    return this.durationMs > 0 ? this.durationMs : Math.max(this.positionMs + 1, 1);
  }

  private isCompleted(): boolean {
    return this.durationMs > 0 && this.positionMs >= this.durationMs * 0.98;
  }

  private getScreenWidth(): number {
    return WindowLayout.screenWidth();
  }

  /**
   * 计算集数/季信息文案。
   *
   * 稳定性修复（设备实测发现的崩溃）：原实现是 `private get itemTypeLabel()`，
   * 里面直接 `const album: string = opts['album']; ... album.length > 0`，
   * 当 DetailPage 未传 album 时 `opts['album']` 为 undefined，`album.length` 抛
   * `TypeError: Cannot read property length of undefined`；而 ArkTS 会把 getter 内联进
   * build，getter 里的 try/catch 拦不住，导致**进入播放页即崩溃**（jscrash 日志
   * PlayerPage.ets:320）。现在改为：字段值先做类型判断 + 结果缓存到 @State，build 里只读状态。
   */
  private computeTypeLabel(): string {
    try {
      const opts: ESObject = JSON.parse(this.playbackOptions) as ESObject;
      const seasonNum: number = typeof opts['seasonNumber'] === 'number' ? opts['seasonNumber'] as number : 0;
      const episodeNum: number = typeof opts['episodeNumber'] === 'number' ? opts['episodeNumber'] as number : 0;
      const albumRaw: string = typeof opts['album'] === 'string' ? opts['album'] as string : '';
      if (seasonNum > 0 && episodeNum > 0) {
        return `第${seasonNum}季 第${episodeNum}集`;
      }
      if (albumRaw.length > 0) {
        return albumRaw;
      }
    } catch (_e) {
      // 参数不是合法 JSON 时忽略
    }
    return '';
  }

  @Builder
  TopBar() {
    Column() {
      Row() {
        AppIconButton({
          icon: $r('sys.symbol.chevron_left'),
          variant: 'ghost',
          iconSize: 20,
          backgroundOverride: this.colors().overlayControlStrong,
          iconColorOverride: this.colors().onOverlay,
          onTap: () => {
            this.flushStop();
            router.back();
          }
        })
        Column({ space: 2 }) {
          Text(this.title)
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onOverlay)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.typeLabel.length > 0) {
            Text(this.typeLabel)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onOverlayMuted)
          }
        }
        .layoutWeight(1)
        .margin({ left: 8 })
        AppIconButton({
          icon: $r('sys.symbol.lock'),
          variant: 'ghost',
          iconSize: 18,
          backgroundOverride: this.colors().overlayControlStrong,
          // 锁定态用品牌色高亮（原来用 🔒/🔓 两个 emoji 区分）
          iconColorOverride: this.controlsLocked ? this.colors().brandPrimary : this.colors().onOverlay,
          onTap: () => {
            this.controlsLocked = !this.controlsLocked;
            if (this.controlsLocked) {
              this.showControls = false;
            } else {
              this.revealControls();
            }
          }
        })
      }
      .width('100%')
      .padding({ left: 12, right: 12, top: 12, bottom: 4 })
      if (this.showVolumeBar) {
        Row() {
          SymbolGlyph($r('sys.symbol.speaker_wave_2'))
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor([this.colors().onOverlay])
          Slider({
            value: this.volume,
            min: 0,
            max: 1,
            step: 0.01,
            style: SliderStyle.OutSet
          })
            .width(160)
            .selectedColor(this.colors().brandPrimary)
            .trackColor(this.colors().overlayControl)
            .trackThickness(4)
            .blockSize({ width: 12, height: 12 })
            .onChange((value: number) => {
              this.volume = value;
            })
        }
        .width('100%')
        .justifyContent(FlexAlign.Center)
        .padding({ bottom: 8 })
      }
    }
    .width('100%')
    // 顶部渐变遮罩：视频画面明暗不定，纯文字/图标容易在浅色画面上"消失"；
    // 与底部控制条同款 scrim 保证标题与按钮始终可读（主流播放器的通用做法）。
    .padding({ top: 8, bottom: 12 })
    .linearGradient({
      angle: 180,
      colors: [['#00000000', 0.0], [this.colors().scrimHeavy, 1.0]]
    })
  }

  @Builder
  BottomControls() {
    Column({ space: 10 }) {
      if (this.status === UiState.ERROR) {
        Text(this.errorMsg)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().error)
          .width('100%')
          .textAlign(TextAlign.Center)
      }

      // 进度条 + 时间：同一行呈现（已播时间在左、总时长在右），比"进度条独占一行 + 时间另起一行"
      // 更紧凑，也让时间与进度在视觉上直接对应；倍速不再重复显示文字（下方已有倍速 chip）。
      Row({ space: 12 }) {
        Text(this.formatTime(this.positionMs))
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlay)
          .fontWeight(FontWeight.Medium)
          .width(72)
          .textAlign(TextAlign.Start)
        Slider({
          value: this.positionMs,
          min: 0,
          max: this.sliderMax(),
          step: 100,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .selectedColor(this.colors().brandPrimary)
          .trackColor(this.colors().overlayControl)
          .trackThickness(4)
          .blockSize({ width: 14, height: 14 })
          .blockColor(this.colors().onOverlay)
          .onChange((value: number) => {
            const v: number = Math.floor(value);
            if (this.avPlayer !== null) {
              this.avPlayer.seek(v);
            }
            this.positionMs = v;
            this.revealControls();
          })
        Text(this.durationMs > 0 ? this.formatTime(this.durationMs) : '--:--')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlayMuted)
          .width(72)
          .textAlign(TextAlign.End)
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 控制按钮行
      Row({ space: 8 }) {
        Button('-10s')
          .layoutWeight(1)
          .backgroundColor(this.colors().overlayControl)
          .fontColor(this.colors().onOverlay)
          .height(40)
          .onClick(() => {
            this.onSeek(-10000);
          })
        Button({ type: ButtonType.Circle, stateEffect: false }) {
          SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause') : $r('sys.symbol.play'))
            .fontSize(ThemeConstants.TITLE_XLARGE)
            .fontColor([this.colors().onBrand])
        }
          .layoutWeight(1)
          .backgroundColor(this.colors().brandPrimary)
          .height(ThemeConstants.BUTTON_HEIGHT)
          .borderRadius(ThemeConstants.BUTTON_HEIGHT / 2)
          .stateStyles({
            pressed: {
              .backgroundColor(this.colors().brandPrimaryPressed)
            }
          })
          .onClick(() => {
            this.onPlayPause();
          })
        Button('+10s')
          .layoutWeight(1)
          .backgroundColor(this.colors().overlayControl)
          .fontColor(this.colors().onOverlay)
          .height(40)
          .onClick(() => {
            this.onSeek(10000);
          })
      }
      .width('100%')

      // 次级操作行：把"倍速 / 软解 / 存帧"这类非播放主操作从主控制行移出。
      // 主行只保留 -10s / 播放暂停 / +10s，播放意图更聚焦；这也是主流播放器的分组方式
      // （主操作居中、次级操作单独一排，避免一排挤满 chip 导致主次不分）。
      Row({ space: 8 }) {
        ChipButton({
          label: `${this.playbackSpeed}x`,
          selected: this.playbackSpeed !== 1,
          onTap: () => {
            this.cycleSpeed();
          }
        })
        // 软解开关：硬解解不了的编码（如模拟器上的 HEVC）可切到 FFmpeg 软解回放
        ChipButton({
          label: '软解',
          selected: this.softPlaying,
          onTap: () => {
            if (this.softPlaying) {
              this.stopSoftPlay();
              this.softStatus = '已停止软解';
            } else {
              this.startSoftPlay();
            }
          }
        })
        // 诊断：回读 EGL 渲染缓冲并写成 PNG（验证"确实渲染出来了"，不依赖系统截图是否含 surface）
        if (this.softPlaying) {
          ChipButton({
            label: '存帧',
            selected: false,
            onTap: () => {
              this.dumpSoftFrame();
            }
          })
        }
      }
      .width('100%')
      .justifyContent(FlexAlign.Center)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    .linearGradient({
      angle: 0,
      colors: [['#00000000', 0.0], [this.colors().scrimHeavy, 1.0]]
    })
  }

  @Builder
  CompletedOverlay() {
    Column() {
      Text('播放结束')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().onOverlayMuted)
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
          .fontSize(ThemeConstants.ICON_XXL)
          .fontColor([this.colors().onBrand])
      }
        .width(72)
        .height(72)
        .backgroundColor(this.colors().brandPrimary)
        .shadow({
          radius: 12,
          color: this.colors().buttonShadow,
          offsetX: 0,
          offsetY: 4
        })
        .stateStyles({
          pressed: {
            .backgroundColor(this.colors().brandPrimaryPressed)
          }
        })
        .margin({ top: 8 })
        .onClick(() => {
          this.onPlayPause();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  LockedOverlay() {
    Column({ space: 6 }) {
      // 圆形解锁按钮：品牌色 + 明确图标，让"下一步该点哪里"一目了然
      // （原来只有一行小字提示，用户得先读懂文案才知道能点）
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.lock'))
          .fontSize(26)
          .fontColor([this.colors().onBrand])
      }
      .width(64)
      .height(64)
      .backgroundColor(this.colors().brandPrimary)
      .margin({ bottom: 8 })
      .onClick(() => {
        this.controlsLocked = false;
        this.revealControls();
      })
      Text('屏幕已锁定')
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().onOverlay)
      Text('点击任意位置解锁')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().onOverlayMuted)
        .margin({ top: 2 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors().overlayControlStrong)
    .onClick(() => {
      this.controlsLocked = false;
      this.revealControls();
    })
  }

  /** 手势反馈图标 —— 用系统符号替代原来的 emoji（⏩ ⏪ 🔆 🔊） */
  private gestureSymbol(): Resource {
    if (this.gestureIcon === 'seek') {
      return this.lastSeekForward ? $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_left');
    }
    if (this.gestureIcon === 'brightness') {
      return $r('sys.symbol.bolt');
    }
    return $r('sys.symbol.speaker_wave_2');
  }

  @Builder
  GestureFeedback() {
    Column() {
      SymbolGlyph(this.gestureSymbol())
        .fontSize(ThemeConstants.ICON_HERO)
        .fontColor([this.colors().onOverlay])
      Text(this.gestureFeedback)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().onOverlay)
        .margin({ top: 8 })
      if (this.gestureRatio >= 0) {
        Progress({ value: this.gestureRatio * 100, total: 100, type: ProgressType.Linear })
          .width(140)
          .height(4)
          .color(this.colors().brandPrimary)
          .backgroundColor(this.colors().onOverlayMuted)
          .margin({ top: 8 })
      }
    }
    .width(200)
    .padding(16)
    .backgroundColor(this.colors().overlayControlStrong)
    .borderRadius(12)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  build() {
    Stack() {
      // XComponent 始终存在：软解时 EGL 直接渲染到它的 surface（不再走 PixelMap 逐帧刷新）
      // 官方 XComponent 原生渲染用法：type=SURFACE + libraryname 指向原生模块，
      // ArkUI 会在 surface 就绪时回调 OH_NativeXComponent_Callback.OnSurfaceCreated(component, window)，
      // 原生侧据此直接拿到 framework 的 window 做 EGL/GLES 渲染（见 native/feature/player/xcomponent_bridge.h）。
      XComponent({ id: 'jellyfin_player', type: XComponentType.SURFACE,
        libraryname: 'jellyfin_native', controller: this.surfaceController })
        .id('softVideoArea')
        .width('100%')
        .height('100%')
        .backgroundColor(this.colors().videoBackground)
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const density: number = display.getDefaultDisplaySync().densityPixels;
          this.surfaceWidthPx = Math.round(Number(newArea.width) * density);
          this.surfaceHeightPx = Math.round(Number(newArea.height) * density);
        })
        .onLoad(() => {
          // 关键：surfaceId 必须由 controller 取回；否则 AVPlayer 与软解 EGL 都拿不到视频面
          this.surfaceId = this.surfaceController.getXComponentSurfaceId();
          if (this.avPlayer !== null && this.surfaceId.length > 0) {
            this.avPlayer.surfaceId = this.surfaceId;
          }
          // surface 一就绪就判定"该设备能否把它当 GL 渲染目标"（清屏为红 + 回读），
          // 结果进常驻 softDiag：打开播放页即可看到结论，无需任何播放/控制条交互
          this.probeRenderTarget();
        })
      // 手势与"点击唤出控制条"的透明承载层。
      // 为什么需要它：官方 NativeXComponent 模式（XComponent 指定 libraryname）下，
      // ArkUI 会把该组件的输入交给原生侧（见 OH_NativeXComponent_Callback.DispatchTouchEvent），
      // 挂在 XComponent 自身上的 onTouch/onClick 不再触发。因此把原有手势逻辑原样挂到这一层，
      // 位置在视频面之上、控件之下，既不影响原生渲染，也保留全部交互。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onTouch((event: TouchEvent) => {
          if (this.controlsLocked) {
            return;
          }
          const touches: TouchObject[] = event.touches;
          if (touches.length === 1) {
            const touch: TouchObject = touches[0];
            const screenWidth: number = this.getScreenWidth();
            const isLeftSide: boolean = touch.x < screenWidth / 2;

            if (event.type === TouchType.Down) {
              this.seekBaseMs = this.positionMs;
              this.seekDragMs = 0;
              this.seekLastX = touch.x;
              this.brightnessBase = 0.5;
              this.brightnessLastY = touch.y;
              this.volumeBase = this.volume;
              this.volumeLastY = touch.y;
            } else if (event.type === TouchType.Move) {
              const deltaX: number = touch.x - this.seekLastX;
              const deltaY: number = touch.y - (isLeftSide ? this.brightnessLastY : this.volumeLastY);

              if (Math.abs(deltaX) > Math.abs(deltaY) && Math.abs(deltaX) > 5) {
                // 水平滑动 → seek
                this.seekLastX = touch.x;
                this.seekDragMs += deltaX * 2;
                const total: number = this.durationMs > 0 ? this.durationMs : 1;
                const clamped: number = Math.max(0, Math.min(total, this.seekBaseMs + this.seekDragMs));
                this.positionMs = clamped;
                this.lastSeekForward = deltaX >= 0;
                this.gestureFeedback = this.lastSeekForward ? `+${this.formatTime(Math.abs(this.seekDragMs))}` : `-${this.formatTime(Math.abs(this.seekDragMs))}`;
                this.gestureIcon = 'seek';
                this.gestureRatio = total > 0 ? clamped / total : 0;
                this.showFeedback = true;
              } else if (Math.abs(deltaY) > 3) {
                // 垂直滑动 → 亮度(左侧) 或 音量(右侧)
                if (isLeftSide) {
                  // 亮度：向上增加
                  const delta: number = -deltaY / 500;
                  const newBrightness: number = Math.max(0, Math.min(1, this.brightnessBase + delta));
                  // 鸿蒙暂不支持程序化调节系统亮度，显示反馈
                  this.gestureFeedback = `${Math.round(newBrightness * 100)}%`;
                  this.gestureIcon = 'brightness';
                  this.gestureRatio = newBrightness;
                  this.showFeedback = true;
                  this.brightnessLastY = touch.y;
                } else {
                  // 音量：向上增加
                  const delta: number = -deltaY / 500;
                  const newVolume: number = Math.max(0, Math.min(1, this.volumeBase + delta));
                  this.volume = newVolume;
                  if (this.avPlayer !== null) {
                    this.avPlayer.setVolume(newVolume);
                  }
                  this.gestureFeedback = `${Math.round(newVolume * 100)}%`;
                  this.gestureIcon = 'volume';
                  this.gestureRatio = newVolume;
                  this.showFeedback = true;
                  this.volumeLastY = touch.y;
                }
              }
            } else if (event.type === TouchType.Up) {
              if (Math.abs(this.seekDragMs) > 100 && this.avPlayer !== null) {
                this.avPlayer.seek(this.positionMs);
              }
              this.seekDragMs = 0;
              this.dismissFeedback();
            }
          }
        })
        .onClick(() => {
          if (this.controlsLocked) {
            this.controlsLocked = false;
            this.revealControls();
            return;
          }
          if (this.showControls) {
            this.showControls = false;
          } else {
            this.revealControls();
          }
        })

      // 手势反馈浮层
      if (this.showFeedback && this.gestureFeedback.length > 0) {
        this.GestureFeedback()
      }

      // 播放结束覆盖层
      if (this.isCompleted() && !this.controlsLocked) {
        this.CompletedOverlay()
      }

      // 锁定覆盖层
      if (this.controlsLocked) {
        this.LockedOverlay()
      }

      // 控制面板
      if (this.showControls && !this.controlsLocked) {
        Column() {
          Column() {
            this.TopBar()
          }
          .width('100%')
          .linearGradient({
            angle: 180,
            colors: [[this.colors().scrimHeavy, 0.0], ['#00000000', 1.0]]
          })

          Blank()

          this.BottomControls()
        }
        .width('100%')
        .height('100%')
      }

      // 加载状态：不只是转圈，同时给出"在播什么"与"在做什么"，
      // 避免打开播放器时只看到一块空白黑背景（观感与信息量都更接近成熟播放器）。
      if (this.status === UiState.LOADING) {
        Column({ space: 4 }) {
          Text(this.title.length > 0 ? this.title : '正在准备播放')
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onOverlay)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 32, right: 32 })
          if (this.typeLabel.length > 0) {
            Text(this.typeLabel)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onOverlayMuted)
          }
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.colors().brandPrimary)
            .margin({ top: 20 })
          Text(this.stateText.length > 0 ? `正在加载 · ${this.stateText}` : '正在加载…')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().onOverlayMuted)
            .margin({ top: 10 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.colors().videoBackground)
      }

      if (this.status === UiState.ERROR) {
        Column({ space: 16 }) {
          // 错误态复用 EmptyState（参考项目约定：错误不另造组件，配"重试"动作）
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '播放出错',
            actionLabel: '重试',
            onAction: () => {
              this.stopped = false;
              this.openPlayer();
            }
          })
          // 硬解不支持该编码（如 HEVC）时，提供 FFmpeg 软解回放
          if (this.softStatus.length > 0) {
            Text(this.softStatus)
              .fontSize(ThemeConstants.META_MEDIUM)
              .fontColor(this.colors().onOverlayMuted)
              .textAlign(TextAlign.Center)
          }
          Button(this.softPlaying ? '停止软解' : '用 FFmpeg 软解播放',
            { type: ButtonType.Normal, stateEffect: false })
            .height(ThemeConstants.BUTTON_HEIGHT)
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().onBrand)
            .backgroundColor(this.colors().brandPrimary)
            .borderRadius(ThemeConstants.BUTTON_RADIUS)
            .stateStyles({
              pressed: {
                .backgroundColor(this.colors().brandPrimaryPressed)
              }
            })
            .onClick(() => {
              if (this.softPlaying) {
                this.stopSoftPlay();
              } else {
                this.startSoftPlay();
              }
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.colors().videoBackground)
      }

      // 软解状态常驻浮层（不随控制条自动隐藏，便于用户与诊断查看进度）
      if (this.softDiag.length > 0) {
        Text(this.softDiag)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlay)
          .backgroundColor(this.colors().badgeScrim)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(ThemeConstants.BADGE_RADIUS)
          .margin({ top: 110 })
      }
      if (this.softStatus.length > 0) {
        Text(this.softStatus)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlay)
          .backgroundColor(this.colors().badgeScrim)
          .padding({ left: 10, right: 10, top: 4, bottom: 4 })
          .borderRadius(ThemeConstants.BADGE_RADIUS)
          .margin({ top: 72 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().videoBackground)
  }
}
