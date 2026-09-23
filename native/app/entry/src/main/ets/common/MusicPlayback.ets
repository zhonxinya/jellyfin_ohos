import media from '@ohos.multimedia.media';
import avSession from '@ohos.multimedia.avsession';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from './JsonUtil';
import { UiState } from './UiState';

/** 进度刷新间隔（毫秒）。与视频播放页同一量级：太密会让受控 Slider 被回写弹回。 */
const kTickMs: number = 1000;
/** 进度上报节流：Jellyfin 侧不需要高频 */
const kReportEveryMs: number = 10000;

/**
 * 播放状态的**值拷贝**快照，供 UI 渲染。
 *
 * 为什么不做成"服务持有 @State、页面 @Link"：服务是普通类（非组件），ArkUI 的状态装饰器
 * 只作用于组件。页面每帧从 `snapshot()` 拿一份数据、与自己的 @State 比对后再回写，
 * 这样播放状态的生命周期就与页面的创建/销毁彻底解耦。
 */
export class MusicPlaybackState {
  status: string = UiState.INITIAL;
  errorMsg: string = '';
  note: string = '';
  trackIds: string[] = [];
  trackNames: string[] = [];
  currentIndex: number = 0;
  albumName: string = '';
  artistName: string = '';
  coverUrl: string = '';
  playing: boolean = false;
  positionMs: number = 0;
  durationMs: number = 0;
  /** 是否已载入曲目（成功/S 暂停/缓冲中都算）—— 迷你播放条的显示条件 */
  hasTrack: boolean = false;

  currentTrackName(): string {
    if (this.currentIndex < 0 || this.currentIndex >= this.trackNames.length) {
      return '未知曲目';
    }
    return this.trackNames[this.currentIndex];
  }

  currentTrackId(): string {
    if (this.currentIndex < 0 || this.currentIndex >= this.trackIds.length) {
      return '';
    }
    return this.trackIds[this.currentIndex];
  }
}

/**
 * 音乐播放服务（单例）—— 播放能力的**唯一持有者**。
 *
 * ## 为什么必须从页面里拆出来（用户口径："实现播放音乐加入后台"）
 * 原来 AVPlayer / AVSession / 长时任务都挂在 `MusicPlayerPage` 上，而页面的
 * `aboutToDisappear` 会把三者全部释放 —— 于是**从播放页返回去浏览，音乐就断了**，
 * 想一边听歌一边用应用根本不可能；而且应用退到后台能继续播，全靠"那个页面恰好还在栈顶没被销毁"，
 * 属于巧合而非常态。
 *
 * 现在：播放由本服务持有，页面（`MusicPlayerPage`）与迷你条（`MainShell` 里那一条）
 * 都只是它的视图/控制器。页面关闭只解绑、不释放；只有用户显式关闭播放（迷你条的 ×）、
 * 切歌到列表尽头、或应用退出（`EntryAbility.onDestroy` → `shutdown()`）才真正释放。
 *
 * ## 后台播放的两件事（缺一不可，见 #73 的设备实测）
 *   1. **AVSession（type=`'audio'`）** —— 让系统媒体控件（通知栏/锁屏/耳机按键）能看到并控制。
 *   2. **长时任务 `startBackgroundRunning`** —— 应用退到后台后不被系统挂起；需要
 *      `ohos.permission.KEEP_BACKGROUND_RUNNING` + ability 的 `backgroundModes: ["audioPlayback"]`。
 *
 * ## 线程与上下文
 * 本类不持有任何 UI 引用；`UIAbilityContext` 在 `request()` 时由页面传入并留存，
 * 长时任务的申请/停止都要用它（服务被非 UI 代码（如 EntryAbility）调用时也拿得到）。
 */
export class MusicPlayback {
  private static instance: MusicPlayback = new MusicPlayback();

  static getInstance(): MusicPlayback {
    return MusicPlayback.instance;
  }

  // ── 播放核心 ───────────────────────────────────────────────────────
  private avPlayer: media.AVPlayer | null = null;
  private session: avSession.AVSession | null = null;
  private ctx: common.UIAbilityContext | null = null;
  private wantAgentObj: WantAgent | null = null;
  private inBackgroundTask: boolean = false;
  private tickTimer: number = -1;
  private lastReportMs: number = 0;
  /** 拖动进度条期间冻结回写（受控 Slider 会被回写弹回，见 docs/player-seek-bar-drag.md） */
  private scrubbing: boolean = false;

  // ── 状态 ───────────────────────────────────────────────────────────
  private status: string = UiState.INITIAL;
  private errorMsg: string = '';
  private note: string = '';
  private trackIds: string[] = [];
  private trackNames: string[] = [];
  private currentIndex: number = 0;
  private albumName: string = '';
  private artistName: string = '';
  private coverUrl: string = '';
  private playing: boolean = false;
  private positionMs: number = 0;
  private durationMs: number = 0;

  snapshot(): MusicPlaybackState {
    const s: MusicPlaybackState = new MusicPlaybackState();
    s.status = this.status;
    s.errorMsg = this.errorMsg;
    s.note = this.note;
    s.trackIds = this.trackIds.slice(0);
    s.trackNames = this.trackNames.slice(0);
    s.currentIndex = this.currentIndex;
    s.albumName = this.albumName;
    s.artistName = this.artistName;
    s.coverUrl = this.coverUrl;
    s.playing = this.playing;
    s.positionMs = this.positionMs;
    s.durationMs = this.durationMs;
    s.hasTrack = this.hasTrack();
    return s;
  }

  private hasTrack(): boolean {
    return this.trackIds.length > 0 && (this.status === UiState.SUCCESS || this.status === UiState.LOADING);
  }

  /**
   * 请求播放。
   *
   * 与当前**正在播的那一首**相同时只做挂载、不打断（用户从列表再点一次同一首、
   * 或从播放页返回后再进来，都应该回到原来的进度而不是重头播）。
   */
  request(ctx: common.UIAbilityContext, trackIds: string[], trackNames: string[],
    index: number, albumName: string, artistName: string, coverUrl: string): void {
    const wantIndex: number = index >= 0 && index < trackIds.length ? index : 0;
    const wantId: string = trackIds[wantIndex];
    if (this.hasTrack() && wantId === this.currentTrackId()) {
      this.ctx = ctx;
      return;
    }
    this.ctx = ctx;
    this.trackIds = trackIds.slice(0);
    this.trackNames = trackNames.slice(0);
    this.currentIndex = wantIndex;
    this.albumName = albumName;
    this.artistName = artistName;
    this.coverUrl = coverUrl;
    this.note = '';
    this.errorMsg = '';
    this.openCurrent();
  }

  /** 当前曲目（迷你条/播放页都靠它判断"是不是同一首"） */
  currentTrackId(): string {
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

  togglePlay(): void {
    if (this.avPlayer === null) {
      return;
    }
    if (this.playing) {
      this.avPlayer.pause();
    } else {
      this.avPlayer.play();
    }
  }

  playNext(): void {
    if (this.trackIds.length === 0) {
      return;
    }
    if (this.currentIndex + 1 >= this.trackIds.length) {
      this.note = '已经是最后一首';
      return;
    }
    this.currentIndex = this.currentIndex + 1;
    this.note = '';
    this.openCurrent();
    this.updateSessionMetadata();
  }

  playPrev(): void {
    if (this.trackIds.length === 0) {
      return;
    }
    if (this.currentIndex <= 0) {
      this.note = '已经是第一首';
      return;
    }
    this.currentIndex = this.currentIndex - 1;
    this.note = '';
    this.openCurrent();
    this.updateSessionMetadata();
  }

  seekTo(ms: number): void {
    if (this.avPlayer === null) {
      return;
    }
    this.avPlayer.seek(ms);
    this.positionMs = ms;
    this.reportProgressIfNeeded(true);
    this.syncSessionState();
  }

  /** 拖动进度条期间置位：冻结 timeUpdate 回写（否则受控 Slider 会被弹回） */
  setScrubbing(value: boolean): void {
    this.scrubbing = value;
  }

  /** 失败后重试当前曲目 */
  retry(): void {
    this.openCurrent();
  }

  /**
   * 停止播放并释放全部资源（迷你条的 ×）。
   *
   * 顺序有讲究：先上报"已停止"（服务端会话不能留着），再停长时任务，
   * 最后释放播放器与会话 —— 顺序反了会出现"通知栏还在、声音没了"的中间态。
   */
  stop(): void {
    this.reportStopped();
    this.stopTick();
    this.stopBackgroundTask();
    this.releasePlayer();
    this.releaseSession();
    this.trackIds = [];
    this.trackNames = [];
    this.currentIndex = 0;
    this.albumName = '';
    this.artistName = '';
    this.coverUrl = '';
    this.positionMs = 0;
    this.durationMs = 0;
    this.playing = false;
    this.note = '';
    this.errorMsg = '';
    this.status = UiState.INITIAL;
  }

  /** 应用退出（`EntryAbility.onDestroy`）：与 stop() 同义，但语义上强调"收尾" */
  shutdown(): void {
    this.stop();
  }

  // ── 播放器 ────────────────────────────────────────────────────────

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

    // 音频不需要转码协商（服务端返回直连静态流），故只传媒体源无关的默认选项。
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

    await this.startPlayer(url);
  }

  private async startPlayer(url: string): Promise<void> {
    this.releasePlayer();
    try {
      const player: media.AVPlayer = await media.createAVPlayer();
      this.avPlayer = player;

      player.on('stateChange', (state: string) => {
        if (state === 'initialized') {
          // **必须显式 prepare()**：只设 `url` 时 AVPlayer 停在 initialized，
          // 永远不会进入 prepared → 不会 play，界面表现为时长 `--:--`、点播放无效。
          player.prepare();
        } else if (state === 'prepared') {
          this.durationMs = player.duration;
          this.status = UiState.SUCCESS;
          player.play();
          this.startTick();
          this.ensureSession();
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
        if (this.scrubbing) {
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

  private startTick(): void {
    this.stopTick();
    this.tickTimer = setInterval(() => {
      // timeUpdate 已是主来源；这里只兜底刷新（部分状态 timeUpdate 不触发）
      if (this.avPlayer !== null && !this.scrubbing) {
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

  // ── 进度上报（与视频页同一套桥接；音乐更需要它 —— 常听的专辑要能续播）────────

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

  // ── AVSession（type=audio）+ 长时任务 ─────────────────────────────

  private async ensureSession(): Promise<void> {
    if (this.session !== null || this.ctx === null) {
      return;
    }
    try {
      // 类型必须是 'audio'：决定系统媒体控件把它当音乐会话展示（元数据、控制项都不同）
      const session: avSession.AVSession = await avSession.createAVSession(this.ctx, 'jellyfin_music', 'audio');
      session.on('play', () => {
        this.avPlayer?.play();
      });
      session.on('pause', () => {
        this.avPlayer?.pause();
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
      this.session = session;
      await this.updateSessionMetadata();
      this.syncSessionState();
      await this.startBackgroundTask();
    } catch (err) {
      // 会话不可用不应阻断播放本身（后台控制是增强项），但要让用户知道
      this.note = '系统媒体控制不可用';
    }
  }

  private async updateSessionMetadata(): Promise<void> {
    if (this.session === null) {
      return;
    }
    // 封面必须是**本地** URI：系统媒体控件不接受远程地址，直接传 http(s) 会被
    // 判为无效并忽略（设备实测日志 `SetMediaImageUri mediaImage uri empty`）。
    // 这里先用本工程自己的取图接口把封面落到磁盘缓存，再把本地路径交给会话。
    const imageUri: string = await this.localCoverUri();
    try {
      await this.session.setAVMetadata({
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
    if (this.session === null) {
      return;
    }
    this.session.setAVPlaybackState({
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
    if (this.inBackgroundTask || this.ctx === null) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext = this.ctx;
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
    if (!this.inBackgroundTask || this.ctx === null) {
      return;
    }
    try {
      await backgroundTaskManager.stopBackgroundRunning(this.ctx);
    } catch (err) {
      // 停止失败不阻断退出流程
    }
    this.inBackgroundTask = false;
  }

  private releaseSession(): void {
    if (this.session !== null) {
      try {
        this.session.deactivate();
        this.session.destroy();
      } catch (err) {
        // 已在别处释放
      }
      this.session = null;
    }
  }
}
