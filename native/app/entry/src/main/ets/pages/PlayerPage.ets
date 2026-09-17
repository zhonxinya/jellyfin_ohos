import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import media from '@ohos.multimedia.media';
import display from '@ohos.display';
import image from '@ohos.multimedia.image';
import componentSnapshot from '@ohos.arkui.componentSnapshot';
import avSession from '@ohos.multimedia.avsession';
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
import { PlaybackState } from '../common/PlaybackState';

/** 控制条自动隐藏延时（毫秒）：给用户留出"看到并点中控件"的时间 */
const kControlsAutoHideMs: number = 5000;

/** 播放器轨道类型（对应 media.MediaType：0=音频 1=视频 2=字幕 3=附件…） */
const kMediaTypeAudio: number = 0;
const kMediaTypeVideo: number = 1;
const kMediaTypeSubtitle: number = 2;

/**
 * 是否是图形字幕（位图字幕：PGS/SUP/VOBSUB/DVB…）。
 *
 * 这类字幕的内容是图片，服务端**无法**转成文本，播放器也解析不出可渲染的文本，
 * 因此面板里明确标注"暂不支持"，而不是让用户点了没反应。
 * 与原生 `jellyfin::IsImageSubtitleCodec`（native/core/subtitle_url.cpp）保持一致。
 */
function isImageSubtitleCodec(codec: string): boolean {
  const c: string = codec.toLowerCase();
  return c === 'pgssub' || c === 'hdmv_pgs_subtitle' || c === 'pgs' || c === 'sup'
    || c === 'dvdsub' || c === 'dvd_subtitle' || c === 'vobsub' || c === 'dvbsub'
    || c === 'dvb_subtitle' || c === 'xsub';
}

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
  /** 最近一次锁定/解锁时刻：用于屏蔽"同一次点击穿透到覆盖层"造成的立即解锁 */
  private lockChangedAt: number = 0;
  /** 软解播放：最近一次进度上报时刻（节流用）与当前位置 */
  private lastProgressReportAt: number = 0;
  private softPositionMs: number = 0;
  /** 长按 2× 快进：计时器与"是否处于长按加速中"（主流播放器标配的手势） */
  private longPressTimerId: number = -1;
  private longPressBoosting: boolean = false;
  /** 系统媒体会话（AVSession）；null 表示未创建 */
  private avSessionRef: avSession.AVSession | null = null;
  /** 可切换的媒体流列表（由详情页随路由参数传入）与当前音频/字幕索引 */
  @State private mediaStreams: Object[] = [];
  @State private audioStreamIndex: number = -1;
  @State private subtitleStreamIndex: number = -1;
  /** 音频/字幕选择面板是否展开（播放页自有覆盖层，不依赖详情页的 bindSheet 机制） */
  @State private showTrackSheet: boolean = false;
  /**
   * 播放器（AVPlayer）自带的音轨列表 —— 来自 `getTrackDescription()`。
   *
   * 为什么以播放器的轨道为准而不是 Jellyfin 的 MediaStreams：
   * 直连/直传时播放器拿到的是**原始文件**，能切换的轨道就是文件里的轨道；
   * 用 `selectTrack()` 切换不需要重新请求播放地址，**不打断播放**。
   * Jellyfin 的 MediaStreams 只用来补全"这条轨道是什么语言/什么编码"的文案。
   */
  @State private avAudioTracks: Object[] = [];
  /** 播放器自带的字幕轨（内嵌字幕）：直接 selectTrack 即可切换，无需再取字幕文件 */
  @State private avSubtitleTracks: Object[] = [];
  /** 播放器当前选中的音轨 index（-1 = 未知/未取到） */
  @State private avAudioIndex: number = -1;
  /** 已加载的外挂字幕在播放器里的轨道 index（-1 = 未加载） */
  @State private avSubtitleIndex: number = -1;
  /** 当前字幕文本：外挂字幕由 `subtitleUpdate` 推给应用，需要应用自己渲染 */
  @State private subtitleText: string = '';
  /** 轨道面板内的提示（切换结果、失败原因、软解模式限制等） */
  @State private trackNote: string = '';
  /** 当前 MediaSourceId（Jellyfin 字幕端点需要它） */
  private mediaSourceId: string = '';
  private feedbackTimerId: number = -1;
  private seekBaseMs: number = 0;
  /** 本次手势判定出的方向：'' 未定 / 'seek' 水平 / 'level' 垂直（亮度或音量） */
  private gestureAxis: string = '';
  /** 按下点坐标：方向与幅度都按"相对按下点的累计位移"计算（见 onTouch 里的说明） */
  private touchDownX: number = 0;
  private touchDownY: number = 0;
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
      const streamsVal: Object | undefined = params['mediaStreams'];
      if (typeof streamsVal === 'string' && streamsVal.length > 2) {
        try {
          this.mediaStreams = JSON.parse(streamsVal) as Object[];
        } catch (err) {
          this.mediaStreams = [];
        }
      }
    }
    // 从传入的播放参数里取出当前音频/字幕索引，供播放中切换时显示与改值
    try {
      const opts: ESObject = JSON.parse(this.playbackOptions) as ESObject;
      this.audioStreamIndex = JsonUtil.getNumber(opts, 'audioStreamIndex', -1);
      this.subtitleStreamIndex = JsonUtil.getNumber(opts, 'subtitleStreamIndex', -1);
    } catch (err) {
      this.audioStreamIndex = -1;
      this.subtitleStreamIndex = -1;
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
    // 轨道面板展开时不自动隐藏控件：面板是挂在控制条之上的覆盖层，
    // 控制条一消失用户就会觉得"面板也跟着没了"，且面板需要持续可点。
    if (this.showTrackSheet) {
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
      // 软解播放的进度上报（节流）：此前软解只出画面、不向服务端报告进度，
      // 导致"继续观看"位置、多端同步都不生效。按 5 秒节流，与硬解路径一致。
      this.softPositionMs = Math.floor(pts * 1000);
      this.reportSoftProgressThrottled(pts);
      this.softStatus = `${Math.floor(pts / 60)}:${this.pad2(Math.floor(pts % 60))}`
        + ` · 第 ${idx} 帧 · ${(fetched / 1048576).toFixed(1)} MB`
        + ` · ${rendered ? 'EGL 已渲染' : '未渲染'}`
        // 把交互状态也放进常驻诊断行：锁定/控制条这类状态无法靠"看覆盖层"可靠判断
        // （UI 可能被其它层遮挡或自动隐藏），写进文字后一次 dump 即可确知真实状态。
        + ` · 锁定=${this.controlsLocked ? '是' : '否'} 控件=${this.showControls ? '显示' : '隐藏'}`
        + (this.lastProgressReportAt > 0 ? ' · 已上报进度' : '')
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

  /**
   * 软解播放的进度上报（5 秒节流）。
   *
   * 为什么需要：软解路径此前只把画面渲染出来，**从不向服务端上报进度**，
   * 于是"继续观看"、跨端续播、观看记录都不会更新——功能上等于半成品。
   * 节流策略与硬解路径保持一致（避免高频请求）。
   */
  /**
   * 创建 AVSession（官方"媒体会话"能力）：让播放进入系统媒体控制/后台播放体系。
   *
   * 官方文档路径：`avSession.createAVSession(context, tag, 'video')` → `setAVMetadata` → `activate`，
   * 并订阅 play/pause/stop/seek 回调，使系统媒体控件（通知栏/锁屏/耳机按键）能驱动本播放器。
   * 结果写入探针文件（读屏对播放页不可靠，文件通道已验证可写）。
   */
  private async initAvSession(): Promise<void> {
    try {
      if (this.avSessionRef !== null) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      const session: avSession.AVSession = await avSession.createAVSession(ctx, 'jellyfin_player', 'video');
      await session.setAVMetadata({ assetId: this.itemId, title: this.title,
        artist: this.typeLabel.length > 0 ? this.typeLabel : 'Jellyfin' });
      session.on('play', () => {
        this.onPlayPause();
      });
      session.on('pause', () => {
        this.onPlayPause();
      });
      session.on('stop', () => {
        this.flushStop();
      });
      session.on('seek', (timeMs: number) => {
        // AVSession 的 seek 回调给的是**绝对时间**（毫秒），不是偏移量。
        // 之前写成 onSeek(timeMs - this.positionMs) 是错的：会把绝对位置当作增量再叠加一次。
        this.positionMs = timeMs;
        if (this.avPlayer !== null) {
          this.avPlayer.seek(timeMs);
        }
        this.appendProbeFile('player_avsession.txt', `sessionSeek to=${timeMs}\n`);
      });
      await session.activate();
      // 把播放状态同步进系统会话（通知栏/锁屏媒体控件据此显示播放/暂停与进度）
      await session.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        position: { elapsedTime: 0, updateTime: Date.now() }
      });
      this.avSessionRef = session;
      this.appendProbeFile('player_avsession.txt',
        `created+activated+statePlay item=${this.itemId}\n`);
    } catch (err) {
      this.appendProbeFile('player_avsession.txt',
        `error ${(err as Error).message}\n`);
    }
  }

  // ---------------------------------------------------------------------------
  // 播放中切换音频 / 字幕
  //
  // 两条路径，"不打断播放"的优先：
  //
  // A. **播放器轨道切换（首选）**：AVPlayer 的 `getTrackDescription()` + `selectTrack()`。
  //    直连/直传时播放器拿到的是**原始文件**，音轨切换是解复用层面的操作：
  //    画面不中断、进度不跳、也不需要重新向服务端请求播放地址 —— 主流播放器都是这么做的。
  // B. **重新请求播放地址（兜底）**：转码等由服务端决定轨道的场景，
  //    只能把新的 `AudioStreamIndex`/`SubtitleStreamIndex` 带回 PlaybackInfo 重新取流，再 seek 回原位。
  //
  // 字幕额外说明：外挂字幕由播放器解析后通过 `subtitleUpdate` 回调交给应用渲染
  // （`SubtitleInfo { startTime, duration, text }`），所以页面自己画字幕文本。
  // ---------------------------------------------------------------------------

  /** Jellyfin MediaStreams 中指定类型的流；Type 取 "Audio" / "Subtitle" */
  private streamsOfType(type: string): Object[] {
    const out: Object[] = [];
    for (let i = 0; i < this.mediaStreams.length; i++) {
      const s: ESObject = this.mediaStreams[i] as ESObject;
      if (JsonUtil.getString(s, 'Type', '') === type) {
        out.push(this.mediaStreams[i]);
      }
    }
    return out;
  }

  /** 面板是否值得给出"可切换"入口：播放器轨道或 Jellyfin 流列表任一可用 */
  private hasSwitchableTracks(): boolean {
    return this.mediaStreams.length > 0 || this.avAudioTracks.length > 0;
  }

  /** 展开轨道面板：顺带刷新一次播放器轨道（重新打开播放后轨道会变） */
  private openTrackSheet(): void {
    this.trackNote = '';
    this.showTrackSheet = true;
    this.revealControls();
    if (this.avPlayer !== null && !this.softPlaying) {
      this.refreshAvTracks();
    }
    this.appendProbeFile('player_tracks.txt',
      `openSheet avAudio=${this.avAudioTracks.length} jfStreams=${this.mediaStreams.length}`
      + ` soft=${this.softPlaying ? 1 : 0}\n`);
  }

  private closeTrackSheet(): void {
    this.showTrackSheet = false;
    this.revealControls();
  }

  /**
   * 读取播放器的轨道列表（prepared 之后才可用），并写入探针。
   *
   * 探针 `player_tracks.txt` 是这条链路的设备验证依据：轨道总数、每轨的类型/语言/编码，
   * 以及当前被选中的轨道 index —— 这些都是"能不能切、切成功了没"的直接证据，
   * 比看画面可靠（模拟器上无法用读屏观察播放页）。
   */
  private async refreshAvTracks(): Promise<void> {
    if (this.avPlayer === null) {
      return;
    }
    try {
      const tracks: media.MediaDescription[] = await this.avPlayer.getTrackDescription();
      const audios: Object[] = [];
      const subs: Object[] = [];
      let line: string = `avTracks n=${tracks.length}`;
      for (let i = 0; i < tracks.length; i++) {
        const t: ESObject = tracks[i] as ESObject;
        const type: number = JsonUtil.getNumber(t, 'track_type', -1);
        const idx: number = JsonUtil.getNumber(t, 'track_index', -1);
        const lang: string = JsonUtil.getString(t, 'language', '');
        const name: string = JsonUtil.getString(t, 'track_name', '');
        const mime: string = JsonUtil.getString(t, 'mime_type', '');
        const ch: number = JsonUtil.getNumber(t, 'channel_count', 0);
        line += ` | idx=${idx} type=${type} lang=${lang} name=${name} mime=${mime} ch=${ch}`;
        if (type === kMediaTypeAudio) {
          const row: ESObject = {
            'idx': idx, 'lang': lang, 'name': name, 'mime': mime, 'ch': ch
          };
          audios.push(row as Object);
        } else if (type === kMediaTypeSubtitle) {
          // 内嵌字幕轨：直接 selectTrack 就能切，不需要再去服务端取字幕文件
          const row: ESObject = { 'idx': idx, 'lang': lang, 'name': name, 'mime': mime };
          subs.push(row as Object);
        }
      }
      this.avAudioTracks = audios;
      this.avSubtitleTracks = subs;
      let selected: number = -1;
      let selectedSub: number = -1;
      try {
        const sel: number[] = await this.avPlayer.getSelectedTracks();
        let selText: string = '';
        for (let i = 0; i < sel.length; i++) {
          selText += (i === 0 ? '' : ',') + sel[i];
          for (let j = 0; j < audios.length; j++) {
            if (JsonUtil.getNumber(audios[j] as ESObject, 'idx', -2) === sel[i]) {
              selected = sel[i];
            }
          }
          for (let j = 0; j < subs.length; j++) {
            if (JsonUtil.getNumber(subs[j] as ESObject, 'idx', -2) === sel[i]) {
              selectedSub = sel[i];
            }
          }
        }
        line += ` selected=[${selText}]`;
      } catch (selErr) {
        line += ` selected=err(${(selErr as Error).message})`;
      }
      this.avAudioIndex = selected;
      this.avSubtitleIndex = selectedSub;
      // 让面板/参数与播放器的真实选择一致：播放器默认选的轨道往往就是文件里的默认轨，
      // 只有把它映射回 Jellyfin 的流索引，面板的选中标记才不会"什么都没选"。
      const audioOrdinal: number = this.avOrdinalOf(selected);
      const jfAudios: Object[] = this.streamsOfType('Audio');
      if (audioOrdinal >= 0 && audioOrdinal < jfAudios.length && this.audioStreamIndex < 0) {
        this.audioStreamIndex = JsonUtil.getNumber(jfAudios[audioOrdinal] as ESObject, 'Index', -1);
      }
      const subOrdinal: number = this.avSubtitleOrdinalOf(selectedSub);
      const jfSubs: Object[] = this.streamsOfType('Subtitle');
      if (subOrdinal >= 0 && subOrdinal < jfSubs.length && this.subtitleStreamIndex < 0) {
        this.subtitleStreamIndex =
          JsonUtil.getNumber(jfSubs[subOrdinal] as ESObject, 'Index', -1);
      }
      this.appendProbeFile('player_tracks.txt', line + '\n');
    } catch (err) {
      this.appendProbeFile('player_tracks.txt',
        `getTrackDescription error ${(err as Error).message}\n`);
    }
  }

  /** 播放器里已加载的字幕轨 index 列表 */
  private async subtitleTrackIndexes(): Promise<number[]> {
    const out: number[] = [];
    if (this.avPlayer === null) {
      return out;
    }
    try {
      const tracks: media.MediaDescription[] = await this.avPlayer.getTrackDescription();
      for (let i = 0; i < tracks.length; i++) {
        const t: ESObject = tracks[i] as ESObject;
        if (JsonUtil.getNumber(t, 'track_type', -1) === kMediaTypeSubtitle) {
          out.push(JsonUtil.getNumber(t, 'track_index', -1));
        }
      }
    } catch (err) {
      this.appendProbeFile('player_tracks.txt',
        `subtitleTrackIndexes error ${(err as Error).message}\n`);
    }
    return out;
  }

  /** 切换音轨：直接让播放器切（不打断播放） */
  private async selectAudioTrack(avIndex: number): Promise<void> {
    if (this.avPlayer === null) {
      this.trackNote = '播放器未就绪，无法切换音轨';
      return;
    }
    try {
      await this.avPlayer.selectTrack(avIndex);
      let confirm: string = '';
      try {
        const sel: number[] = await this.avPlayer.getSelectedTracks();
        for (let i = 0; i < sel.length; i++) {
          confirm += (i === 0 ? '' : ',') + sel[i];
        }
      } catch (selErr) {
        confirm = `err(${(selErr as Error).message})`;
      }
      this.avAudioIndex = avIndex;
      // 同步到播放参数：兜底重开（转码/软解）时保持同一选择
      const ordinal: number = this.avOrdinalOf(avIndex);
      const jfAudios: Object[] = this.streamsOfType('Audio');
      if (ordinal >= 0 && ordinal < jfAudios.length) {
        this.audioStreamIndex = JsonUtil.getNumber(jfAudios[ordinal] as ESObject, 'Index', -1);
      }
      this.persistTrackOptions();
      this.trackNote = '已切换音频';
      this.appendProbeFile('player_tracks.txt',
        `selectAudio ok track=${avIndex} confirmed=[${confirm}]\n`);
    } catch (err) {
      this.trackNote = `切换音频失败：${(err as Error).message}`;
      this.appendProbeFile('player_tracks.txt',
        `selectAudio fail track=${avIndex} ${(err as Error).message}\n`);
    }
  }

  /** 播放器音轨 index → 它在音轨列表中的序号（用于映射回 Jellyfin 的音轨顺序） */
  private avOrdinalOf(avIndex: number): number {
    for (let i = 0; i < this.avAudioTracks.length; i++) {
      if (JsonUtil.getNumber(this.avAudioTracks[i] as ESObject, 'idx', -2) === avIndex) {
        return i;
      }
    }
    return -1;
  }

  /** 播放器字幕轨 index → 它在字幕轨列表中的序号（与 Jellyfin 字幕流顺序一一对应） */
  private avSubtitleOrdinalOf(avIndex: number): number {
    for (let i = 0; i < this.avSubtitleTracks.length; i++) {
      if (JsonUtil.getNumber(this.avSubtitleTracks[i] as ESObject, 'idx', -2) === avIndex) {
        return i;
      }
    }
    return -1;
  }

  /** Jellyfin 字幕流索引 → 它在字幕流列表中的序号 */
  private jfSubtitleOrdinalOf(streamIndex: number): number {
    const subs: Object[] = this.streamsOfType('Subtitle');
    for (let i = 0; i < subs.length; i++) {
      if (JsonUtil.getNumber(subs[i] as ESObject, 'Index', -2) === streamIndex) {
        return i;
      }
    }
    return -1;
  }

  /** 把当前选择写回播放参数（供后续重开播放/软解使用） */
  private persistTrackOptions(): void {
    try {
      const opts: ESObject = JSON.parse(this.playbackOptions) as ESObject;
      opts['audioStreamIndex'] = this.audioStreamIndex;
      opts['subtitleStreamIndex'] = this.subtitleStreamIndex;
      this.playbackOptions = JSON.stringify(opts);
    } catch (err) {
      this.appendProbeFile('player_tracks.txt',
        `persistTrackOptions error ${(err as Error).message}\n`);
    }
  }

  /**
   * 加载并显示某条 Jellyfin 字幕流。
   *
   * 两条路：
   * 1）**内嵌字幕（首选）**：文件里就有这条字幕轨（AVPlayer 的轨道列表里有 type=2 的轨），
   *    直接 `selectTrack`，不联网、不中断播放 —— 设备实测这样就够用。
   * 2）**外挂字幕（兜底）**：字幕是独立文件（Jellyfin 的 External 字幕），
   *    先用原生构造的字幕地址 `addSubtitleFromUrl` 加进来，再 selectTrack。
   */
  private async applySubtitleStream(streamIndex: number, codec: string): Promise<void> {
    if (this.avPlayer === null) {
      this.trackNote = '播放器未就绪，无法切换字幕';
      return;
    }
    // 1）内嵌字幕：按序号映射到播放器的字幕轨
    const ordinal: number = this.jfSubtitleOrdinalOf(streamIndex);
    if (this.avSubtitleTracks.length > 0 && ordinal >= 0
      && ordinal < this.avSubtitleTracks.length) {
      const avIdx: number = JsonUtil.getNumber(this.avSubtitleTracks[ordinal] as ESObject, 'idx', -1);
      this.appendProbeFile('player_tracks.txt',
        `subtitle embedded stream=${streamIndex} ordinal=${ordinal} track=${avIdx}\n`);
      await this.selectSubtitleTrack(avIdx, streamIndex);
      return;
    }
    // 2）外挂字幕
    const raw: string = JellyfinNative.subtitleUrl(this.itemId, this.mediaSourceId, streamIndex, codec);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.trackNote = result.message.length > 0 ? result.message : '无法构造字幕地址';
      return;
    }
    const url: string = JsonUtil.getString(result.data as ESObject, 'url', '');
    const format: string = JsonUtil.getString(result.data as ESObject, 'format', '');
    if (url.length === 0) {
      this.trackNote = '字幕地址为空';
      return;
    }
    try {
      const before: number[] = await this.subtitleTrackIndexes();
      this.appendProbeFile('player_tracks.txt',
        `subtitle external stream=${streamIndex} format=${format} before=${before.length}`
        + ` urlLen=${url.length} loading...\n`);
      await this.avPlayer.addSubtitleFromUrl(url);
      this.appendProbeFile('player_tracks.txt', `subtitle external loaded stream=${streamIndex}\n`);
      const after: number[] = await this.subtitleTrackIndexes();
      let target: number = -1;
      for (let i = 0; i < after.length; i++) {
        let known: boolean = false;
        for (let j = 0; j < before.length; j++) {
          if (before[j] === after[i]) {
            known = true;
          }
        }
        if (!known) {
          target = after[i];
        }
      }
      if (target < 0 && after.length > 0) {
        target = after[after.length - 1];
      }
      if (target < 0) {
        this.trackNote = '字幕已加载，但播放器未暴露该字幕轨';
        this.appendProbeFile('player_tracks.txt',
          `subtitle loaded stream=${streamIndex} format=${format} but no track\n`);
        return;
      }
      await this.selectSubtitleTrack(target, streamIndex);
    } catch (err) {
      this.trackNote = `切换字幕失败：${(err as Error).message}`;
      this.appendProbeFile('player_tracks.txt',
        `subtitle fail stream=${streamIndex} ${(err as Error).message}\n`);
    }
  }

  /** 选中某条播放器字幕轨（先关掉上一条，避免多轨叠加） */
  private async selectSubtitleTrack(avIndex: number, streamIndex: number): Promise<void> {
    if (this.avPlayer === null) {
      return;
    }
    try {
      if (this.avSubtitleIndex >= 0 && this.avSubtitleIndex !== avIndex) {
        try {
          await this.avPlayer.deselectTrack(this.avSubtitleIndex);
        } catch (desErr) {
          this.appendProbeFile('player_tracks.txt',
            `deselect old subtitle ${this.avSubtitleIndex} err ${(desErr as Error).message}\n`);
        }
      }
      await this.avPlayer.selectTrack(avIndex);
      this.avSubtitleIndex = avIndex;
      this.subtitleStreamIndex = streamIndex;
      this.persistTrackOptions();
      this.trackNote = '字幕已切换';
      this.appendProbeFile('player_tracks.txt',
        `subtitle ok stream=${streamIndex} track=${avIndex}\n`);
    } catch (err) {
      this.trackNote = `切换字幕失败：${(err as Error).message}`;
      this.appendProbeFile('player_tracks.txt',
        `subtitle select fail track=${avIndex} ${(err as Error).message}\n`);
    }
  }

  /** 关闭字幕 */
  private async clearSubtitle(): Promise<void> {
    if (this.avPlayer !== null && this.avSubtitleIndex >= 0) {
      try {
        await this.avPlayer.deselectTrack(this.avSubtitleIndex);
        this.appendProbeFile('player_tracks.txt', `subtitle off track=${this.avSubtitleIndex}\n`);
      } catch (err) {
        this.appendProbeFile('player_tracks.txt',
          `subtitle off fail ${(err as Error).message}\n`);
      }
    }
    this.avSubtitleIndex = -1;
    this.subtitleStreamIndex = -1;
    this.subtitleText = '';
    this.persistTrackOptions();
    this.trackNote = '字幕已关闭';
  }

  /**
   * 兜底路径：重新请求播放地址并 seek 回原位。
   *
   * 什么时候用：播放器没有暴露可切换的轨道（例如服务端转码，轨道由服务端决定）。
   * 代价是播放会重开一次（画面短暂黑一下、需要 seek 回原位），所以只作为次选。
   */
  private async reopenWithTrack(audioIndex: number, subtitleIndex: number): Promise<void> {
    const resumeMs: number = this.positionMs;
    this.audioStreamIndex = audioIndex;
    this.subtitleStreamIndex = subtitleIndex;
    this.persistTrackOptions();
    this.appendProbeFile('player_tracks.txt',
      `reopen audio=${audioIndex} subtitle=${subtitleIndex} resumeMs=${resumeMs}\n`);
    await this.openPlayer();
    // 回到切换前的位置（AVPlayer 在 prepared 后 seek 最稳妥，这里做一次兜底 seek）
    setTimeout(() => {
      if (this.avPlayer !== null && resumeMs > 1000) {
        this.avPlayer.seek(resumeMs);
        this.positionMs = resumeMs;
      }
    }, 1200);
  }

  /** 面板里点击某条音轨（播放器轨道，按 track index 切换） */
  private onPickAvAudio(avIndex: number): void {
    if (this.softPlaying) {
      this.trackNote = '软解模式暂不支持切换音轨（软解只解码视频）';
      return;
    }
    this.selectAudioTrack(avIndex);
  }

  /** 兜底：没有播放器轨道信息时，按 Jellyfin 音轨序号重新取流 */
  private onPickJfAudio(ordinal: number): void {
    if (this.softPlaying) {
      this.trackNote = '软解模式暂不支持切换音轨（软解只解码视频）';
      return;
    }
    const jfAudios: Object[] = this.streamsOfType('Audio');
    if (ordinal < 0 || ordinal >= jfAudios.length) {
      this.trackNote = '未找到对应的音轨';
      return;
    }
    this.reopenWithTrack(JsonUtil.getNumber(jfAudios[ordinal] as ESObject, 'Index', -1),
      this.subtitleStreamIndex);
  }

  /** 面板里点击某条字幕 */
  private onPickSubtitleStream(streamIndex: number, codec: string): void {
    if (this.softPlaying) {
      this.trackNote = '软解模式暂不支持外挂字幕（软解只渲染视频帧）';
      return;
    }
    if (this.avPlayer === null) {
      this.trackNote = '播放器未就绪，无法切换字幕';
      return;
    }
    this.applySubtitleStream(streamIndex, codec);
  }

  /** 流列表 → 选项文案：优先显示语言/标题，其次编码与声道 */
  private trackLabel(stream: ESObject): string {
    const type: string = JsonUtil.getString(stream, 'Type', '');
    const lang: string = JsonUtil.getString(stream, 'Language', '');
    const display: string = JsonUtil.getString(stream, 'DisplayTitle', '');
    const name: string = display.length > 0 ? display : JsonUtil.getString(stream, 'Title', '');
    const codec: string = JsonUtil.getString(stream, 'Codec', '');
    const channels: number = JsonUtil.getNumber(stream, 'Channels', 0);
    let text: string = name.length > 0 ? name : (lang.length > 0 ? lang : type);
    if (codec.length > 0) {
      text += ` · ${codec}`;
    }
    if (channels > 0) {
      text += ` · ${channels}ch`;
    }
    return text;
  }

  /** 播放器音轨 → 选项文案：以 Jellyfin 的语言/标题为准（播放器通常只有语言码） */
  private avAudioLabel(track: ESObject, ordinal: number): string {
    const jfAudios: Object[] = this.streamsOfType('Audio');
    const lang: string = JsonUtil.getString(track, 'lang', '');
    const name: string = JsonUtil.getString(track, 'name', '');
    const mime: string = JsonUtil.getString(track, 'mime', '');
    const ch: number = JsonUtil.getNumber(track, 'ch', 0);
    let text: string = '';
    if (ordinal >= 0 && ordinal < jfAudios.length) {
      text = this.trackLabel(jfAudios[ordinal] as ESObject);
    } else {
      text = name.length > 0 ? name : (lang.length > 0 ? lang : `音轨 ${ordinal + 1}`);
      if (mime.length > 0) {
        text += ` · ${mime}`;
      }
      if (ch > 0) {
        text += ` · ${ch}ch`;
      }
    }
    return text;
  }

  /**
   * 轨道面板里的一行（整行可点、选中态高亮 + ✓）。
   *
   * 为什么不用 ChipButton：一集剧常有几十条字幕，chip 流式排布既不好读也不好点，
   * 主流播放器的轨道菜单都是"整行列表 + 右侧选中标记"。
   *
   * 参数用 `kind + value` 而不是回调函数：@Builder 的参数由 ArkTS 统一转译，
   * 传函数类型参数在转译产物里不被接受（es2abc 语法错误），改为参数化事件再分发。
   */
  @Builder
  TrackRow(label: string, selected: boolean, kind: string, value: number) {
    Row() {
      Text(label)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontWeight(selected ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(selected ? this.colors().brandPrimary : this.colors().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (selected) {
        Text('✓')
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().brandPrimary)
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .borderRadius(ThemeConstants.CHIP_RADIUS)
    .backgroundColor(selected ? this.colors().chipBackgroundPressed : '#00000000')
    .onClick(() => {
      this.onTrackRowTap(kind, value);
    })
  }

  /** 轨道行点击分发：kind 见 TrackSheet（av / jfaudio / sub / suboff / none） */
  private onTrackRowTap(kind: string, value: number): void {
    if (kind === 'av') {
      this.onPickAvAudio(value);
    } else if (kind === 'jfaudio') {
      this.onPickJfAudio(value);
    } else if (kind === 'sub') {
      this.onPickSubtitleStream(value, this.subtitleCodecAt(value));
    } else if (kind === 'suboff') {
      this.clearSubtitle();
    }
  }

  /** 某条字幕流的编码（用于决定请求格式与是否图形字幕） */
  private subtitleCodecAt(streamIndex: number): string {
    const subs: Object[] = this.streamsOfType('Subtitle');
    for (let i = 0; i < subs.length; i++) {
      if (JsonUtil.getNumber(subs[i] as ESObject, 'Index', -2) === streamIndex) {
        return JsonUtil.getString(subs[i] as ESObject, 'Codec', '');
      }
    }
    return '';
  }

  @Builder
  TrackSectionTitle(text: string) {
    Text(text)
      .fontSize(ThemeConstants.LABEL_SMALL)
      .fontColor(this.colors().textTertiary)
      .width('100%')
      .margin({ top: 6, bottom: 2 })
  }

  /** 音频/字幕选择面板内容 */
  @Builder
  TrackSheet() {
    Column() {
      this.TrackSectionTitle('音频')
      if (this.avAudioTracks.length > 0) {
        // ForEach 的 key 里带上"是否选中"：ArkUI 对 key 未变的项不会重建，
        // 若只用轨道 index 作 key，切换后选中标记不会移动（设备实测的缺陷）。
        ForEach(this.avAudioTracks, (item: Object, index: number) => {
          this.TrackRow(this.avAudioLabel(item as ESObject, index),
            this.avAudioIndex === JsonUtil.getNumber(item as ESObject, 'idx', -2),
            'av', JsonUtil.getNumber(item as ESObject, 'idx', -1))
        }, (item: Object) => `av${JsonUtil.getNumber(item as ESObject, 'idx', -1)}`
          + `-${this.avAudioIndex === JsonUtil.getNumber(item as ESObject, 'idx', -2) ? 1 : 0}`)
      } else {
        // 播放器没给出轨道列表（转码等）：按 Jellyfin 流列表走兜底重开
        ForEach(this.streamsOfType('Audio'), (item: Object, index: number) => {
          this.TrackRow(this.trackLabel(item as ESObject),
            this.audioStreamIndex === JsonUtil.getNumber(item as ESObject, 'Index', -2),
            'jfaudio', index)
        }, (item: Object) => `jfa${JsonUtil.getNumber(item as ESObject, 'Index', -1)}`
          + `-${this.audioStreamIndex === JsonUtil.getNumber(item as ESObject, 'Index', -2) ? 1 : 0}`)
        if (this.streamsOfType('Audio').length === 0) {
          this.TrackRow('无可切换的音轨', false, 'none', -1)
        }
      }

      this.TrackSectionTitle('字幕')
      this.TrackRow('关闭字幕',
        this.avSubtitleIndex < 0 && this.subtitleStreamIndex < 0, 'suboff', -1)
      ForEach(this.streamsOfType('Subtitle'), (item: Object) => {
        this.TrackRow(this.subtitleLabel(item as ESObject),
          this.subtitleStreamIndex === JsonUtil.getNumber(item as ESObject, 'Index', -2),
          'sub', JsonUtil.getNumber(item as ESObject, 'Index', -1))
      }, (item: Object) => `sub${JsonUtil.getNumber(item as ESObject, 'Index', -1)}`
        + `-${this.subtitleStreamIndex === JsonUtil.getNumber(item as ESObject, 'Index', -2) ? 1 : 0}`)
      if (this.streamsOfType('Subtitle').length === 0) {
        this.TrackRow('该视频没有字幕', false, 'none', -1)
      }

      if (this.trackNote.length > 0) {
        Text(this.trackNote)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().brandPrimary)
          .width('100%')
          .margin({ top: 8 })
      }
      Text(this.softPlaying
        ? '软解模式：轨道切换不可用（软解只解码视频帧）'
        : '切换即时生效，不中断播放')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textTertiary)
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 字幕行文案：图形字幕标注"本机不支持" */
  private subtitleLabel(stream: ESObject): string {
    const codec: string = JsonUtil.getString(stream, 'Codec', '');
    const base: string = this.trackLabel(stream);
    if (isImageSubtitleCodec(codec)) {
      return `${base}（图形字幕，暂不支持）`;
    }
    return base;
  }

  private async reportSoftProgressThrottled(ptsSec: number): Promise<void> {
    if (this.itemId.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (this.lastProgressReportAt > 0 && now - this.lastProgressReportAt < 5000) {
      return;
    }
    this.lastProgressReportAt = now;
    // 记录"正在播放"，供 Ability.onDestroy 在应用退出时上报 stopped（会话卫生）
    PlaybackState.set(this.itemId, Math.floor(ptsSec * 10000000));
    const raw: string = await JellyfinNative.reportPlaybackProgress(this.itemId,
      Math.floor(ptsSec * 10000000), false);
    // 同步进系统媒体会话（通知栏/锁屏进度条随播放推进）；与进度上报同一节流节奏。
    if (this.avSessionRef !== null) {
      this.avSessionRef.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        position: { elapsedTime: Math.floor(ptsSec * 1000), updateTime: Date.now() }
      }).then(() => {
        this.appendProbeFile('player_avsession.txt',
          `syncPlaybackState pos=${Math.floor(ptsSec)}s\n`);
      }).catch(() => {
        // 同步失败不影响播放
      });
    }
    // 文件探针：便于设备验证时直接确认"软解路径确实上报了、服务端是否接受"
    // （读屏对播放页不可靠，见 writeStateProbe 的说明）
    this.appendProbeFile('player_progress.txt',
      `softProgress pts=${ptsSec.toFixed(1)} resp=${raw.length > 160 ? raw.substring(0, 160) : raw}\n`);
  }

  /** 追加一行到沙箱诊断文件（失败不影响播放） */
  private appendProbeFile(name: string, line: string): void {
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      const file = fs.openSync(`${ctx.cacheDir}/${name}`,
        fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
      fs.writeSync(file.fd, line);
      fs.closeSync(file);
    } catch (err) {
      // 诊断写入失败忽略
    }
  }

  /**
   * 长按 2× 快进：按住 600ms 未松开即把播放速度临时设为 2×，松手恢复。
   * 这是主流播放器的标准手势；对硬解与软解都有效（AVPlayer 走 setSpeed，
   * 软解路径由帧循环的节流上报体现位置推进速度）。
   */
  private startLongPressBoost(): void {
    this.cancelLongPressTimer();
    this.longPressTimerId = setTimeout(() => {
      this.longPressTimerId = -1;
      if (this.controlsLocked || this.avPlayer === null) {
        return;
      }
      if (!this.isPlaying) {
        return;
      }
      this.longPressBoosting = true;
      this.avPlayer.setSpeed(2);
      this.gestureFeedback = '2× 快进';
      this.gestureIcon = 'seek';
      this.gestureRatio = -1;
      this.showFeedback = true;
      this.appendProbeFile('player_gesture.txt', 'longPressBoost start speed=2\n');
    }, 600);
  }

  private cancelLongPressTimer(): void {
    if (this.longPressTimerId >= 0) {
      clearTimeout(this.longPressTimerId);
      this.longPressTimerId = -1;
    }
  }

  private stopLongPressBoost(): void {
    this.cancelLongPressTimer();
    if (!this.longPressBoosting) {
      return;
    }
    this.longPressBoosting = false;
    if (this.avPlayer !== null) {
      this.avPlayer.setSpeed(this.playbackSpeed);
    }
    this.appendProbeFile('player_gesture.txt',
      `longPressBoost stop restore=${this.playbackSpeed}\n`);
    this.dismissFeedback();
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
    // 停止/切换/退出时补发最终进度：只靠节流中的周期上报会丢失最后几秒位置
    // （与硬解路径的 flushStop 行为保持一致）
    if (this.itemId.length > 0 && this.lastProgressReportAt > 0) {
      JellyfinNative.reportPlaybackStopped(this.itemId, this.softPositionMs * 10000);
      this.lastProgressReportAt = 0;
    }
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
    // MediaSourceId：Jellyfin 外挂字幕端点需要（字幕切换时用）
    this.mediaSourceId = JsonUtil.getString(result.data, 'mediaSourceId', '');
    // 创建 AVPlayer 进行实际视频渲染
    this.createAvPlayer(resolvedUrl);
    // 进入系统媒体会话体系（后台播放/媒体控件）；失败不影响播放
    this.initAvSession();
  }

  private async createAvPlayer(url: string): Promise<void> {
    // 先释放"上一个"播放器与软解会话，再创建新的。
    //
    // 为什么必须这样（服务端实证的缺陷）：`createAvPlayer` 原来直接覆盖 `this.avPlayer`，
    // 于是"重试"或再次进入播放页时会**同时存在两个活跃播放器**——服务端 `/Sessions`
    // 会看到同一客户端的两条播放会话都在推进（实测：`我爱体育 70s` 与 `说事儿 393s` 同时推进），
    // 观看记录与"继续观看"随之被污染。
    this.softStopAvPlayer();
    this.stopSoftPlay();
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
          // 硬解已就绪：清掉软解留下的诊断文案（否则会一直挂着"EGL 已渲染/第 N 帧"这类
          // 上一段软解会话的信息，看起来像两路同时在播）
          this.softDiag = '';
          this.softStatus = '';
          // 轨道列表只有 prepared 之后才取得到（音轨/字幕切换的基础）
          this.refreshAvTracks();
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
      // 外挂字幕：播放器解析字幕文件后把"当前该显示哪句"推给应用，由应用渲染
      // （`SubtitleInfo { startTime, duration, text }`；文本型字幕才有内容）
      this.avPlayer.on('subtitleUpdate', (info: media.SubtitleInfo) => {
        const text: string = info.text !== undefined ? info.text : '';
        this.subtitleText = text;
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
          iconSize: 22,
          // 触达区对齐 48vp 标准（默认 40vp；设备实测顶部栏按钮曾为 45vp，偏小）
          buttonSize: 48,
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
          iconSize: 20,
          // 与返回按钮一致：48vp 触达区（锁定按钮此前实测 45vp，且是唯一"点不中"的控件）
          buttonSize: 48,
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
            // 记录切换时刻：锁定覆盖层会盖满整屏，若无此时间戳，
            // 同一次点击的抬手事件会"穿透"到刚出现的覆盖层上把它立刻解锁
            // （实测表现为"点了锁定却没锁上"）。
            this.lockChangedAt = Date.now();
            this.refreshStateDiag(this.controlsLocked ? '锁定' : '取消锁定');
            this.writeStateProbe(this.controlsLocked ? '锁定' : '取消锁定');
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
      Row({ space: 12 }) {
        Button('-10s')
          .layoutWeight(1)
          .backgroundColor(this.colors().overlayControl)
          .fontColor(this.colors().onOverlay)
          // 触达高度 40 → 48vp：常用操作应满足"一指可点"的最小触达区
          // （鸿蒙触控最佳实践建议 ≥48vp），行间距 8 → 12 同时避免误触相邻按钮
          .height(48)
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
          // 与 -10s 保持一致（设备实测两者曾为 162px vs 135px，左右高度不齐）
          .height(48)
          .onClick(() => {
            this.onSeek(10000);
          })
      }
      .width('100%')

      // 次级操作行：把"倍速 / 软解 / 存帧"这类非播放主操作从主控制行移出。
      // 主行只保留 -10s / 播放暂停 / +10s，播放意图更聚焦；这也是主流播放器的分组方式
      // （主操作居中、次级操作单独一排，避免一排挤满 chip 导致主次不分）。
      // 次级操作行：与主控制行统一为 12vp 间距（本轮前为 8vp，两行间距不一致）
      Row({ space: 12 }) {
        ChipButton({
          label: `${this.playbackSpeed}x`,
          selected: this.playbackSpeed !== 1,
          // 播放页单手操作、误触代价高，触达高度按 48vp 标准放大（全局 token 仍为 34vp）
          heightOverride: 48,
          onTap: () => {
            this.cycleSpeed();
          }
        })
        // 软解开关：硬解解不了的编码（如模拟器上的 HEVC）可切到 FFmpeg 软解回放
        ChipButton({
          label: '软解',
          selected: this.softPlaying,
          heightOverride: 48,
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
            heightOverride: 48,
            onTap: () => {
              this.dumpSoftFrame();
            }
          })
        }
        // 播放中切换音频/字幕：播放页自己的覆盖层面板（不依赖详情页的 bindSheet）
        ChipButton({
          label: '音频/字幕',
          selected: this.showTrackSheet,
          heightOverride: 48,
          onTap: () => {
            this.openTrackSheet();
          }
        })
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
        this.unlockByUser();
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
      this.unlockByUser();
    })
  }

  /**
   * 把播放页状态写进沙箱文件（`cache/player_state.txt`），供设备验证直接读取。
   *
   * 为什么要用文件而不是读屏：实测 `uitest dumpLayout` 对播放页**不可靠**
   * （XComponent/控件经常不出现，甚至整页只剩状态栏），而文件产物可以稳定 pull 回来，
   * 与前面用 `softcapture.png` 验证渲染的做法一致。
   */
  private writeStateProbe(action: string): void {
    this.appendProbeFile('player_state.txt',
      `${action} locked=${this.controlsLocked ? 1 : 0}`
      + ` controls=${this.showControls ? 1 : 0} playing=${this.softPlaying ? 1 : 0}`
      + ` status=${this.status}\n`);
  }

  /**
   * 解锁：忽略"刚锁定后极短时间内的点击"。
   *
   * 为什么需要：锁定覆盖层是整屏的，点锁定按钮的同一次抬手事件会穿透到刚出现的覆盖层，
   * 导致"点了锁定立刻又被解锁"（诊断设备上表现为锁定态无法复现，实际是真实缺陷）。
   */
  private unlockByUser(): void {
    if (Date.now() - this.lockChangedAt < 400) {
      return;
    }
    this.controlsLocked = false;
    this.lockChangedAt = Date.now();
    this.revealControls();
    this.refreshStateDiag('解锁');
    this.writeStateProbe('解锁');
  }

  /**
   * 把交互状态写进常驻诊断行（渲染目标探测行）。
   *
   * 为什么需要：锁定/控制条显隐这类状态无法靠"看覆盖层是否存在"可靠判断
   * （覆盖层可能被遮挡、控件会自动隐藏），写进文字后一次 dump 即可确知真实状态，
   * 无需依赖"猜坐标点击 + 目视判断"。
   */
  private refreshStateDiag(action: string): void {
    this.softDiag = `[${action}] 锁定=${this.controlsLocked ? '是' : '否'} 控件=${this.showControls ? '显示' : '隐藏'}`;
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
    // 横向 HUD：图标在左、数值与进度在右。
    // 原来是纵向堆叠且无形状边界，在明暗画面之间观感松散；改成胶囊状 HUD 更聚焦、
    // 也更符合主流播放器"手势反馈是瞬时浮层"的定位。
    Row({ space: 12 }) {
      SymbolGlyph(this.gestureSymbol())
        .fontSize(ThemeConstants.ICON_HERO)
        .fontColor([this.colors().onOverlay])
      Column({ space: 6 }) {
        Text(this.gestureFeedback)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().onOverlay)
        if (this.gestureRatio >= 0) {
          Progress({ value: this.gestureRatio * 100, total: 100, type: ProgressType.Linear })
            .width(140)
            .height(4)
            .color(this.colors().brandPrimary)
            .backgroundColor(this.colors().onOverlayMuted)
        }
      }
      .alignItems(HorizontalAlign.Start)
    }
    .padding({ left: 18, right: 20, top: 14, bottom: 14 })
    .backgroundColor(this.colors().overlayControlStrong)
    .borderRadius(28)
    .alignItems(VerticalAlign.Center)
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
              // 手势方向判定用"相对按下点的累计位移"，不用单次 Move 的位移。
              //
              // 为什么必须这样（设备实测的缺陷）：注入/慢速滑动时每个 Move 事件的位移常常只有 1–5px，
              // 原来"单次位移 > 5px"的阈值会把整段慢速滑动全部过滤掉 —— 实测 500ms 滑完 500px
              // 时 seekDeltaMs 恒为 0（完全不响应），100ms 滑同样距离才识别。
              this.touchDownX = touch.x;
              this.touchDownY = touch.y;
              this.gestureAxis = '';
              // 长按 2× 快进：按住 600ms 未松开即临时加速，松手恢复原速
              this.startLongPressBoost();
            } else if (event.type === TouchType.Move) {
              const totalX: number = touch.x - this.touchDownX;
              const totalY: number = touch.y - this.touchDownY;
              // 先定方向：累计位移超过 12px 才判定，避免抖动误判
              if (this.gestureAxis.length === 0) {
                if (Math.abs(totalX) > 12 || Math.abs(totalY) > 12) {
                  this.gestureAxis = Math.abs(totalX) >= Math.abs(totalY) ? 'seek' : 'level';
                }
              }
              if (this.gestureAxis === 'seek') {
                // 水平滑动 → seek：幅度按"按下点起的累计位移"算，与事件密度无关
                this.seekLastX = touch.x;
                this.seekDragMs = totalX * 2;
                const total: number = this.durationMs > 0 ? this.durationMs : 1;
                const clamped: number = Math.max(0, Math.min(total, this.seekBaseMs + this.seekDragMs));
                this.positionMs = clamped;
                this.lastSeekForward = totalX >= 0;
                this.gestureFeedback = this.lastSeekForward ? `+${this.formatTime(Math.abs(this.seekDragMs))}` : `-${this.formatTime(Math.abs(this.seekDragMs))}`;
                this.gestureIcon = 'seek';
                this.gestureRatio = total > 0 ? clamped / total : 0;
                this.showFeedback = true;
              } else if (this.gestureAxis === 'level' && Math.abs(totalY) > 12) {
                // 垂直滑动 → 亮度(左侧) 或 音量(右侧)；同样按累计位移计算
                if (isLeftSide) {
                  // 亮度：向上增加（鸿蒙暂不支持程序化调节系统亮度，只给反馈）
                  const newBrightness: number =
                    Math.max(0, Math.min(1, this.brightnessBase - totalY / 500));
                  this.gestureFeedback = `${Math.round(newBrightness * 100)}%`;
                  this.gestureIcon = 'brightness';
                  this.gestureRatio = newBrightness;
                  this.showFeedback = true;
                  this.brightnessLastY = touch.y;
                } else {
                  // 音量：向上增加
                  const newVolume: number =
                    Math.max(0, Math.min(1, this.volumeBase - totalY / 500));
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
              // 松手结束长按加速（无论是否已进入加速态）
              this.stopLongPressBoost();
              // 文件探针：手势结束时记录一次结果，便于设备验证直接确认"手势确实被识别"
              // （进度条/浮层这类瞬时 UI 无法用读屏稳定观察）
              this.appendProbeFile('player_gesture.txt',
                `gesture seekDeltaMs=${this.seekDragMs} volume=${this.volume.toFixed(2)}`
                + ` longPressBoost=${this.longPressBoosting ? 1 : 0} positionMs=${this.positionMs}\n`);
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

      // 字幕：外挂字幕由播放器推文本、应用绘制（原生 SURFACE 上画不了文本）
      // hitTestBehavior(None)：字幕只是显示，不能挡住手势层与控制条
      if (this.subtitleText.length > 0 && !this.controlsLocked) {
        Column() {
          Text(this.subtitleText)
            .fontSize(20)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .backgroundColor('#99000000')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(6)
            .constraintSize({ maxWidth: '88%' })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: 150 })
        .hitTestBehavior(HitTestMode.None)
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

      // 音频/字幕面板：播放页自有的覆盖层（详情页那套 bindSheet 在播放页不可用）
      if (this.showTrackSheet && !this.controlsLocked) {
        Column() {
          Column({ space: 2 }) {
            Row() {
              Text('音频 / 字幕')
                .fontSize(ThemeConstants.TITLE_MEDIUM)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.colors().textPrimary)
              Blank()
              Text('关闭')
                .fontSize(ThemeConstants.META_MEDIUM)
                .fontColor(this.colors().brandPrimary)
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .onClick(() => {
                  this.closeTrackSheet();
                })
            }
            .width('100%')
            .margin({ bottom: 4 })

            Scroll() {
              this.TrackSheet()
            }
            .width('100%')
            .constraintSize({ maxHeight: 560 })
            .scrollBar(BarState.Off)
          }
          .width('88%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .backgroundColor(this.colors().cardBackground)
          .borderRadius(ThemeConstants.CARD_RADIUS)
          .shadow({ radius: 16, color: this.colors().buttonShadow, offsetX: 0, offsetY: 6 })
          // 组件 id：设备验证时用 componentSnapshot.get('trackSheetCard') 抓面板实际渲染结果
          .id('trackSheetCard')
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.colors().overlayControlStrong)
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
