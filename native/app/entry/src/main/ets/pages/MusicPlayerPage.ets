import router from '@ohos.router';
import media from '@ohos.multimedia.media';
import avSession from '@ohos.multimedia.avsession';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { formatTicks } from '../common/format';
import { PageHeader } from '../components/PageHeader';
import { EmptyState } from '../components/EmptyState';
import { JellyfinImage } from '../components/JellyfinImage';

/** 进度条回写间隔（毫秒）。与视频播放页一致的量级，避免每帧回写导致 Slider 被弹回。 */
const kTickMs: number = 1000;
/** 进度上报节流：Jellyfin 侧不需要高频 */
const kReportEveryMs: number = 10000;

/**
 * 音乐播放页（音频专用）。
 *
 * ## 为什么单独一页而不是复用 PlayerPage
 * `PlayerPage` 是**视频**播放器：XComponent 画面、字幕叠加、软解渲染、全屏控制条，
 * 它的 AVSession 类型硬编码为 `'video'`、`setAVMetadata` 也按视频填。把它改成"既能视频又能音频"
 * 会让那条已经很敏感的链路（硬解/软解回退、字幕、手势）同时承受音频分支的风险。
 * 所以音频单独成页，但**复用同一套底层**：
 *   - 播放地址仍由原生侧 `playerOpen` 解析（本页不拼 URL，符合 AGENTS.md 的分层约定）；
 *   - 进度上报仍走 `reportPlaybackProgress` / `reportPlaybackStopped`；
 *   - 封面仍走 `JellyfinImage`（本工程 HTTP + 磁盘缓存）。
 *
 * ## 后台播放（用户明确要求"完整"）
 * 两件事缺一不可，只做 AVSession 是不够的：
 *   1. **AVSession（type=`'audio'`）** —— 让系统媒体控件（通知栏/锁屏/耳机按键）能看到并控制播放。
 *      类型必须是 `'audio'`：填 `'video'` 会让系统按视频会话处理（不显示音频元数据、控制项也不同）。
 *   2. **长时任务 `startBackgroundRunning`** —— 应用退到后台后**不被系统挂起**。
 *      只创建 AVSession 时，应用进后台仍可能被冻结、音频随之中断。
 *      需要 `ohos.permission.KEEP_BACKGROUND_RUNNING`（已在 module.json5 声明）。
 */
@Entry
@Component
struct MusicPlayerPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private trackNames: string[] = [];
  @State private trackIds: string[] = [];
  @State private currentIndex: number = 0;
  @State private albumName: string = '';
  @State private artistName: string = '';
  @State private coverUrl: string = '';
  @State private playing: boolean = false;
  @State private positionMs: number = 0;
  @State private durationMs: number = 0;
  @State private note: string = '';

  private avPlayer: media.AVPlayer | null = null;
  private avSessionRef: avSession.AVSession | null = null;
  private tickTimer: number = -1;
  private lastReportMs: number = 0;
  /** 拖动进度条期间冻结回写，避免受控 Slider 被弹回（与视频播放页同一个坑） */
  private sliderDragging: boolean = false;
  private wantAgentObj: WantAgent | null = null;
  /** 是否已进入长时任务（退出时必须显式 stopBackgroundRunning，否则下次启动会被拒） */
  private inBackgroundTask: boolean = false;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idsVal: Object | undefined = params['trackIds'];
      if (Array.isArray(idsVal)) {
        for (let i = 0; i < (idsVal as string[]).length; i++) {
          this.trackIds.push((idsVal as string[])[i]);
        }
      }
      const namesVal: Object | undefined = params['trackNames'];
      if (Array.isArray(namesVal)) {
        for (let i = 0; i < (namesVal as string[]).length; i++) {
          this.trackNames.push((namesVal as string[])[i]);
        }
      }
      const idxVal: Object | undefined = params['startIndex'];
      if (typeof idxVal === 'number') {
        this.currentIndex = idxVal;
      }
      const albumVal: Object | undefined = params['albumName'];
      if (typeof albumVal === 'string') {
        this.albumName = albumVal;
      }
      const artistVal: Object | undefined = params['artistName'];
      if (typeof artistVal === 'string') {
        this.artistName = artistVal;
      }
      const coverVal: Object | undefined = params['coverUrl'];
      if (typeof coverVal === 'string') {
        this.coverUrl = coverVal;
      }
    }
    if (this.trackIds.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '没有可播放的曲目';
      return;
    }
    this.openCurrent();
  }

  aboutToDisappear(): void {
    this.stopTick();
    this.releasePlayer();
    this.releaseSession();
    this.stopBackgroundTask();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private currentTrackId(): string {
    if (this.currentIndex < 0 || this.currentIndex >= this.trackIds.length) {
      return '';
    }
    return this.trackIds[this.currentIndex];
  }

  private currentTrackName(): string {
    if (this.currentIndex < 0 || this.currentIndex >= this.trackNames.length) {
      return '未知曲目';
    }
    return this.trackNames[this.currentIndex];
  }

  // ─────────────────────────────────────────────────────────────
  // 播放
  // ─────────────────────────────────────────────────────────────

  /** 打开当前曲目：先向原生侧解析播放地址，再交给 AVPlayer */
  private async openCurrent(): Promise<void> {
    const trackId: string = this.currentTrackId();
    if (trackId.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '曲目标识为空';
      return;
    }
    this.status = UiState.LOADING;
    this.errorMsg = '';
    this.positionMs = 0;
    this.durationMs = 0;

    // 音频不需要转码协商（服务端会返回直连静态流），故只传媒体源无关的默认选项。
    // 音频**必须**允许直连/直传：转码流是 HLS，本机软解读不了分片。
    const options: Record<string, Object> = {
      'enableDirectPlay': true,
      'enableDirectStream': true,
      'enableTranscoding': false,
      'includeDeviceProfile': true
    };
    const raw: string = await JellyfinNative.playerOpen(trackId, JSON.stringify(options));
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '无法获取播放地址';
      return;
    }
    const url: string = JsonUtil.getString(result.data as ESObject, 'playUrl', '');
    if (url.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '播放地址为空';
      return;
    }

    await this.startPlayback(url);
  }

  private async startPlayback(url: string): Promise<void> {
    this.releasePlayer();
    try {
      const player: media.AVPlayer = await media.createAVPlayer();
      this.avPlayer = player;

      player.on('stateChange', (state: string) => {
        if (state === 'initialized') {
          // **必须显式 prepare()**：只设 `url` 时 AVPlayer 停在 initialized，
          // 永远不会进入 prepared → 不会 play，界面表现为时长 `--:--`、点播放无效。
          // （视频播放页也是"设 url → prepare"，见 PlayerPage.createAvPlayer。
          //   那里 surface 可能比 url 晚到，所以还多了一个 preparePendingSurface 兜底；
          //   音频没有 surface，设完 url 直接 prepare 即可。）
          player.prepare();
        } else if (state === 'prepared') {
          this.durationMs = player.duration;
          this.status = UiState.SUCCESS;
          player.play();
          this.startTick();
          this.syncSessionState();
        } else if (state === 'playing') {
          this.playing = true;
          this.syncSessionState();
        } else if (state === 'paused') {
          this.playing = false;
          this.syncSessionState();
        } else if (state === 'completed') {
          // 播完自动下一首；最后一首则停在结尾
          this.playing = false;
          this.syncSessionState();
          this.playNext();
        }
      });

      player.on('error', (err: BusinessError) => {
        this.status = UiState.ERROR;
        this.errorMsg = `播放失败（${err.code}）：${err.message}`;
        this.stopTick();
      });

      player.on('timeUpdate', (time: number) => {
        if (this.sliderDragging) {
          return;
        }
        this.positionMs = time;
        this.reportProgressIfNeeded(false);
      });

      // 音频不设 XComponent / surfaceId，直接以 url 加载
      player.url = url;
    } catch (err) {
      this.status = UiState.ERROR;
      this.errorMsg = `打开播放器失败：${(err as Error).message}`;
    }
  }

  private togglePlay(): void {
    if (this.avPlayer === null) {
      return;
    }
    if (this.playing) {
      this.avPlayer.pause();
    } else {
      this.avPlayer.play();
    }
  }

  private playNext(): void {
    if (this.currentIndex + 1 >= this.trackIds.length) {
      this.note = '已经是最后一首';
      return;
    }
    this.currentIndex = this.currentIndex + 1;
    this.note = '';
    this.openCurrent();
    this.updateSessionMetadata();
  }

  private playPrev(): void {
    if (this.currentIndex <= 0) {
      this.note = '已经是第一首';
      return;
    }
    this.currentIndex = this.currentIndex - 1;
    this.note = '';
    this.openCurrent();
    this.updateSessionMetadata();
  }

  private seekTo(ms: number): void {
    if (this.avPlayer === null) {
      return;
    }
    this.avPlayer.seek(ms);
    this.positionMs = ms;
    this.reportProgressIfNeeded(true);
  }

  private startTick(): void {
    this.stopTick();
    this.tickTimer = setInterval(() => {
      // timeUpdate 已是主来源；这里只兜底刷新（部分状态 timeUpdate 不触发）
      if (this.avPlayer !== null && !this.sliderDragging) {
        const p: number = this.avPlayer.currentTime;
        if (p > 0) {
          this.positionMs = p;
        }
      }
    }, kTickMs);
  }

  private stopTick(): void {
    if (this.tickTimer >= 0) {
      clearInterval(this.tickTimer);
      this.tickTimer = -1;
    }
  }

  private releasePlayer(): void {
    if (this.avPlayer !== null) {
      try {
        this.avPlayer.release();
      } catch (err) {
        // 释放失败不影响后续（对象已不可用）
      }
      this.avPlayer = null;
    }
    this.playing = false;
  }

  // ─────────────────────────────────────────────────────────────
  // 进度上报（与视频页同一套桥接；音乐更需要它 —— 常听的专辑要能续播）
  // ─────────────────────────────────────────────────────────────

  private reportProgressIfNeeded(force: boolean): void {
    const now: number = Date.now();
    if (!force && now - this.lastReportMs < kReportEveryMs) {
      return;
    }
    this.lastReportMs = now;
    const trackId: string = this.currentTrackId();
    if (trackId.length === 0) {
      return;
    }
    // ticks = ms * 10000（Jellyfin 用 100ns 单位）
    JellyfinNative.reportPlaybackProgress(trackId, Math.floor(this.positionMs) * 10000, !this.playing);
  }

  private reportStopped(): void {
    const trackId: string = this.currentTrackId();
    if (trackId.length === 0) {
      return;
    }
    JellyfinNative.reportPlaybackStopped(trackId, Math.floor(this.positionMs) * 10000);
  }

  // ─────────────────────────────────────────────────────────────
  // AVSession（type=audio）+ 长时任务
  // ─────────────────────────────────────────────────────────────

  private async ensureSession(): Promise<void> {
    if (this.avSessionRef !== null) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      // 类型必须是 'audio'：决定系统媒体控件把它当音乐会话展示（元数据、控制项都不同）
      const session: avSession.AVSession = await avSession.createAVSession(ctx, 'jellyfin_music', 'audio');
      session.on('play', () => {
        if (this.avPlayer !== null) {
          this.avPlayer.play();
        }
      });
      session.on('pause', () => {
        if (this.avPlayer !== null) {
          this.avPlayer.pause();
        }
      });
      session.on('stop', () => {
        this.reportStopped();
        this.avPlayer?.stop();
      });
      session.on('playNext', () => {
        this.playNext();
      });
      session.on('playPrevious', () => {
        this.playPrev();
      });
      session.on('seek', (timeMs: number) => {
        // 与视频页一致：AVSession 的 seek 回调给的是**绝对时间**（毫秒），不是增量
        this.seekTo(timeMs);
      });
      await session.activate();
      this.avSessionRef = session;
      await this.updateSessionMetadata();
      this.syncSessionState();
      await this.startBackgroundTask();
    } catch (err) {
      // 会话不可用不应阻断播放本身（后台控制是增强项），但要让用户知道
      this.note = '系统媒体控制不可用';
    }
  }

  private async updateSessionMetadata(): Promise<void> {
    if (this.avSessionRef === null) {
      return;
    }
    // 封面必须是**本地** URI：系统媒体控件不接受远程地址，直接传 http(s) 会被
    // 判为无效并忽略（设备实测日志 `SetMediaImageUri mediaImage uri empty`）。
    // 这里先用本工程自己的取图接口把封面落到磁盘缓存，再把本地路径交给会话。
    const imageUri: string = await this.localCoverUri();
    try {
      await this.avSessionRef.setAVMetadata({
        assetId: this.currentTrackId(),
        title: this.currentTrackName(),
        artist: this.artistName.length > 0 ? this.artistName : 'Jellyfin',
        album: this.albumName,
        mediaImage: imageUri
      });
    } catch (err) {
      // 元数据失败不影响播放
    }
  }

  /**
   * 会话封面：把专辑封面取到本地并返回 `file://` URI。
   *
   * 走 `JellyfinNative.loadImage`（与应用其它图片同一条链路：core 的 HTTP + 磁盘缓存），
   * 命中缓存时不会产生网络请求。取不到就返回空串，会话只是不显示封面，不影响播放。
   */
  private async localCoverUri(): Promise<string> {
    if (this.coverUrl.length === 0) {
      return '';
    }
    if (this.coverUrl.startsWith('file://')) {
      return this.coverUrl;
    }
    try {
      const raw: string = await JellyfinNative.loadImage(this.coverUrl);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        return '';
      }
      const path: string = JsonUtil.getString(result.data as ESObject, 'path', '');
      if (path.length === 0) {
        return '';
      }
      return path.startsWith('file://') ? path : `file://${path}`;
    } catch (err) {
      return '';
    }
  }

  private syncSessionState(): void {
    if (this.avSessionRef === null) {
      return;
    }
    this.avSessionRef.setAVPlaybackState({
      state: this.playing
        ? avSession.PlaybackState.PLAYBACK_STATE_PLAY
        : avSession.PlaybackState.PLAYBACK_STATE_PAUSE,
      position: { elapsedTime: this.positionMs, updateTime: Date.now() },
      speed: 1.0
    }).catch(() => {
      // 状态同步失败不影响本机播放
    });
  }

  /**
   * 申请长时任务，使应用退到后台后不被挂起。
   *
   * 用 `wantAgent` 让系统在用户点击通知时回到本应用。
   * 失败（例如权限被拒）不阻断前台播放，只提示一次 —— 否则用户会以为整个播放坏了。
   */
  private async startBackgroundTask(): Promise<void> {
    if (this.inBackgroundTask) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      const agentInfo: wantAgent.WantAgentInfo = {
        wants: [{
          bundleName: ctx.abilityInfo.bundleName,
          abilityName: ctx.abilityInfo.name
        }],
        actionType: wantAgent.OperationType.START_ABILITY,
        requestCode: 0,
        actionFlags: [wantAgent.WantAgentFlags.UPDATE_PRESENT_FLAG]
      };
      this.wantAgentObj = await wantAgent.getWantAgent(agentInfo);
      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        this.wantAgentObj
      );
      this.inBackgroundTask = true;
    } catch (err) {
      const e = err as BusinessError;
      // 201 = 权限未授予；其它多为系统限制。如实提示，不静默失败。
      this.note = e.code === 201
        ? '缺少长时任务权限，退到后台可能暂停'
        : `后台播放未启用（${e.code}）`;
    }
  }

  private async stopBackgroundTask(): Promise<void> {
    if (!this.inBackgroundTask) {
      return;
    }
    try {
      const ctx = getContext(this) as common.UIAbilityContext;
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (err) {
      // 停止失败不阻断退出流程
    }
    this.inBackgroundTask = false;
  }

  private releaseSession(): void {
    if (this.avSessionRef !== null) {
      try {
        this.avSessionRef.deactivate();
        this.avSessionRef.destroy();
      } catch (err) {
        // 已在别处释放
      }
      this.avSessionRef = null;
    }
  }

  // ─────────────────────────────────────────────────────────────
  // UI
  // ─────────────────────────────────────────────────────────────

  @Builder
  Controls() {
    Row({ space: 28 }) {
      // 上一首
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.backward_end_fill'))
          .fontSize(30)
          .fontColor([this.colors().textPrimary])
      }
      .width(52)
      .height(52)
      .backgroundColor(this.colors().surfacePressed)
      .onClick(() => {
        this.playPrev();
      })

      // 播放 / 暂停
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph(this.playing ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'))
          .fontSize(34)
          .fontColor([this.colors().onBrand])
      }
      .width(68)
      .height(68)
      .backgroundColor(this.colors().brandPrimary)
      .onClick(() => {
        this.togglePlay();
      })

      // 下一首
      Button({ type: ButtonType.Circle, stateEffect: true }) {
        SymbolGlyph($r('sys.symbol.forward_end_fill'))
          .fontSize(30)
          .fontColor([this.colors().textPrimary])
      }
      .width(52)
      .height(52)
      .backgroundColor(this.colors().surfacePressed)
      .onClick(() => {
        this.playNext();
      })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  build() {
    Column() {
      PageHeader({ title: this.albumName.length > 0 ? this.albumName : '正在播放', onBack: () => { router.back(); } })

      if (this.status === UiState.ERROR) {
        EmptyState({
          message: this.errorMsg.length > 0 ? this.errorMsg : '播放失败',
          actionLabel: '重试',
          onAction: () => {
            this.openCurrent();
          }
        })
      } else {
        Column({ space: 16 }) {
          Blank().height(12)

          // 封面
          JellyfinImage({
            url: this.coverUrl,
            imgWidth: 260,
            imgHeight: 260,
            cornerRadius: ThemeConstants.CARD_RADIUS,
            placeholderIcon: 'music'
          })

          // 曲目 / 艺术家
          Column({ space: 6 }) {
            Text(this.currentTrackName())
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .maxLines(2)
              .textAlign(TextAlign.Center)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.artistName.length > 0 ? this.artistName : `${this.currentIndex + 1} / ${this.trackIds.length}`)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().textTertiary)
            Text(`${this.currentIndex + 1} / ${this.trackIds.length}`)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().textTertiary)
          }
          .width('100%')
          .padding({ left: 24, right: 24 })

          // 进度
          Column({ space: 4 }) {
            Slider({
              value: this.positionMs,
              min: 0,
              max: this.durationMs > 0 ? this.durationMs : 1,
              step: 1000,
              style: SliderStyle.OutSet
            })
              .width('100%')
              .trackColor(this.colors().surfacePressed)
              .selectedColor(this.colors().brandPrimary)
              .onChange((value: number, mode: SliderChangeMode) => {
                if (mode === SliderChangeMode.Begin || mode === SliderChangeMode.Moving) {
                  // 拖动期间冻结回写，否则受控 Slider 会被弹回（详见 docs/player-seek-bar-drag.md）
                  this.sliderDragging = true;
                  this.positionMs = value;
                } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.sliderDragging = false;
                  this.seekTo(value);
                }
              })
            Row() {
              Text(formatTicks(Math.floor(this.positionMs) * 10000))
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().textTertiary)
              Blank()
              Text(formatTicks(this.durationMs * 10000))
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().textTertiary)
            }
            .width('100%')
          }
          .width('100%')
          .padding({ left: 24, right: 24 })

          this.Controls()

          if (this.note.length > 0) {
            Text(this.note)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().textTertiary)
          }

          Blank()
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
    .onAppear(() => {
      // AVSession 与长时任务在页面出现后建立（需要 UIAbilityContext）
      this.ensureSession();
    })
  }
}
