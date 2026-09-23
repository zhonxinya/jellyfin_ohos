import media from '@ohos.multimedia.media';
import audio from '@ohos.multimedia.audio';
import avSession from '@ohos.multimedia.avsession';
import image from '@ohos.multimedia.image';
import wantAgent, { WantAgent } from '@ohos.app.ability.wantAgent';
import backgroundTaskManager from '@ohos.resourceschedule.backgroundTaskManager';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';
import { BusinessError } from '@ohos.base';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from './JsonUtil';
import { UiState } from './UiState';

const DOMAIN: number = 0x0000;
const TAG: string = 'MusicPlayback';

/** 进度刷新间隔（毫秒）。与视频播放页同一量级：太密会让受控 Slider 被回写弹回。 */
const kTickMs: number = 1000;
/** 进度上报节流：Jellyfin 侧不需要高频 */
const kReportEveryMs: number = 10000;
/**
 * 向系统会话对账播放状态的间隔。
 *
 * 面板进度条本可以靠 `position + speed` 自行推算，但状态会漂（会话创建晚于 `playing`、
 * 跨进程丢包），一漂控制中心的中间按钮就和本机反着来 —— 实测点一次发的是 `play` 而不是 `pause`。
 */
const kSessionSyncEveryMs: number = 5000;
/** 交给系统播控的封面边长：面板最大也就方形大图，按原图（常见 800~1400）解一次白占几兆内存 */
const kCoverDecodePx: number = 320;

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
 *   1. **AVSession（type=`'audio'`）** —— 让系统媒体控件（播控中心/锁屏/耳机按键）能看到并控制。
 *      面板要显示完整就得把元数据和状态都喂够：`duration` 缺了时间是 `--:--`、进度条不可用；
 *      封面必须是 `PixelMap`（控制中心是另一个进程，读不到本应用沙箱的 `file://`）；
 *      `previousAssetId`/`nextAssetId` 决定上一首/下一首是否置灰。
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
  private lastSessionSyncMs: number = 0;
  /**
   * 会话封面的解码缓存。
   *
   * 控制中心读不到应用沙箱里的 `file://` 路径（跨进程没有权限），只能收 `PixelMap`；
   * 解码有成本，而同一张专辑切歌时封面不变，故按 `coverUrl` 缓存并复用。
   */
  private coverPix: image.PixelMap | null = null;
  private coverKey: string = '';
  /** 拖动进度条期间冻结回写（受控 Slider 会被回写弹回，见 docs/player-seek-bar-drag.md） */
  private scrubbing: boolean = false;
  /** 这次暂停是"被系统抢焦点"造成的：焦点还回来要替他恢复（用户自己按的暂停不算，见 handleAudioInterrupt） */
  private interruptedBySystem: boolean = false;
  /**
   * 最近一次写入 `note` 的**能力降级**文案（会话不可用 / 长时任务失败）。
   *
   * 为什么要记住它：能力补齐（例如自愈后长时任务申请成功）时要能按内容擦掉，
   * 否则一次偶发失败会一直挂在播放页上，用户以为后台播放一直是坏的。
   */
  private capabilityNote: string = '';

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
      // 同一首只挂载不重启，但**顺手补申请一次长时任务**：长时任务失败后，
      // 用户重进播放页是唯一的重试时机（起播时机只在新曲目上出现）。
      // 会话已建好才申请 —— 没有活动会话的申请会被系统按 9800005 拒掉。
      if (this.session !== null) {
        this.startBackgroundTask();
      }
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
      // 用户自己按的暂停优先：别让随后到来的"焦点归还"把他按下的暂停顶掉
      this.interruptedBySystem = false;
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
    this.releaseCover();
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
    this.capabilityNote = '';
    this.errorMsg = '';
    this.status = UiState.INITIAL;
    this.interruptedBySystem = false;
    // 上下文只服务于会话与长时任务，两者都已释放，就不能再留着：
    // ability 销毁后旧上下文已失效，留着它会让新一轮播放拿着死上下文去申请长时任务
    // （真机表现：后台播放莫名"未启用"）。下一次 request() 会带新的上下文进来。
    this.ctx = null;
    this.wantAgentObj = null;
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
      this.interruptedBySystem = false;

      // 音频焦点被抢占（来电、别的应用开始播…）：系统会强制暂停并通知；
      // 焦点还回来时若没人接着恢复，用户看到的就是"音乐自己停了"——按规范接管这两个 hint。
      player.on('audioInterrupt', (event: audio.InterruptEvent) => {
        this.handleAudioInterrupt(player, event);
      });

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
          // 时长已知，此刻才适合把元数据交给会话（会话已存在时这一步同时刷新封面/时长）
          this.ensureSession();
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
      // 定期与系统会话对账：状态一漂，控制中心的播放/暂停就和本机反着来
      if (Date.now() - this.lastSessionSyncMs >= kSessionSyncEveryMs) {
        this.syncSessionState();
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

  /**
   * 音频中断（焦点被抢占 / 归还）。
   *
   * `FORCE` 表示系统已经替应用处理完了（暂停/停止），这里只记账；`SHARE` 是"交给你自己处理"，
   * 要主动暂停。恢复只认"这次暂停是被中断造成的"：用户自己按的暂停不能被焦点归还顶掉
   * （用户按暂停时清掉这个标记，见 `togglePlay` 与会话的 `pause` 回调）。
   *
   * `STOP` 也按"可恢复的暂停"处理，不按字面销毁会话/播放器：焦点归还就能接着播，
   * 而销毁会连带丢掉正在播的这首与迷你条 —— 用户要的是"被打断了，还能回来"。
   */
  private handleAudioInterrupt(player: media.AVPlayer, event: audio.InterruptEvent): void {
    if (player !== this.avPlayer) {
      // 已经被换掉的旧播放器（切歌了）：它的事件不该影响新曲目
      return;
    }
    hilog.info(DOMAIN, TAG, '音频中断：hint=%{public}d force=%{public}d',
      event.hintType, event.forceType);
    const hint: audio.InterruptHint = event.hintType;
    if (hint === audio.InterruptHint.INTERRUPT_HINT_PAUSE ||
      hint === audio.InterruptHint.INTERRUPT_HINT_STOP) {
      this.interruptedBySystem = true;
      if (event.forceType === audio.InterruptForceType.INTERRUPT_FORCE) {
        // 系统已经暂停/停止了它，等 stateChange 回来改写 playing
        return;
      }
      if (player.state === 'playing' || player.state === 'prepared') {
        player.pause();
      }
      return;
    }
    if (hint === audio.InterruptHint.INTERRUPT_HINT_RESUME && this.interruptedBySystem) {
      this.interruptedBySystem = false;
      // 被系统"停止"过（不是暂停）的播放器要重新 prepare 才能播，那不在这里偷偷做 ——
      // 保持暂停、让用户从迷你条/播放页点一下，比悄悄重开更不容易出怪状态
      if (player.state === 'paused' || player.state === 'prepared') {
        player.play();
      }
    }
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
    if (this.session === null) {
      if (this.ctx === null) {
        return;
      }
      try {
        // 类型必须是 'audio'：决定系统媒体控件把它当音乐会话展示（元数据、控制项都不同）
        const session: avSession.AVSession = await avSession.createAVSession(this.ctx, 'jellyfin_music', 'audio');
        session.on('play', () => {
          this.avPlayer?.play();
        });
        session.on('pause', () => {
          // 播控中心按暂停 = 用户意图，别被随后到来的"焦点归还"顶掉（见 handleAudioInterrupt）
          this.interruptedBySystem = false;
          this.avPlayer?.pause();
        });
        session.on('stop', () => {
          // 控制中心的"停止"要的是**整条播放结束**：只停 AVPlayer 会留下
          // "卡片还在、长时任务还在、迷你条还在"的半死状态。
          this.stop();
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
      } catch (err) {
        // 会话不可用不应阻断播放本身（后台控制是增强项），但要让用户知道
        this.setCapabilityNote('系统媒体控制不可用');
        return;
      }
    }
    // 长时任务**不在**"会话是否新建"的分支里：会话建好而任务申请失败时，下一首起播
    // 必须还能补申请 —— 嵌在分支里的话，一次失败就让整轮聆听都没有后台能力（退到后台即被挂起）。
    await this.startBackgroundTask();
    await this.updateSessionMetadata();
    this.syncSessionState();
  }

  /** 记一条"能力降级"提示（会话不可用 / 长时任务失败），能力恢复后由 `clearCapabilityNote` 擦掉 */
  private setCapabilityNote(text: string): void {
    this.capabilityNote = text;
    this.note = text;
  }

  /** 能力补齐：只在 note 里仍是自己写的那条降级文案时才擦（不误伤"已经是最后一首"这类瞬时提示） */
  private clearCapabilityNote(): void {
    if (this.note === this.capabilityNote) {
      this.note = '';
    }
    this.capabilityNote = '';
  }

  /** 队列里相邻的一首（`-1` 上一首 / `+1` 下一首）；没有则空串 —— 控制中心据此置灰按钮 */
  private neighborTrackId(delta: number): string {
    const i: number = this.currentIndex + delta;
    if (i < 0 || i >= this.trackIds.length) {
      return '';
    }
    return this.trackIds[i];
  }

  private async updateSessionMetadata(): Promise<void> {
    if (this.session === null) {
      return;
    }
    // 封面必须是位图：控制中心是另一个进程，读不到本应用沙箱的 file:// 路径
    // （实测设备日志 `SetMediaImageUri mediaImage uri empty`，面板退化成音符占位图）
    const cover: image.PixelMap | null = await this.coverPixel();
    try {
      await this.session.setAVMetadata({
        assetId: this.currentTrackId(),
        title: this.currentTrackName(),
        artist: this.artistName.length > 0 ? this.artistName : 'Jellyfin',
        album: this.albumName,
        // 时长缺失时，播控面板的时间显示成 `--:--`、进度条整条不可用
        duration: this.durationMs,
        mediaImage: cover === null ? undefined : cover,
        previousAssetId: this.neighborTrackId(-1),
        nextAssetId: this.neighborTrackId(1)
      });
    } catch (err) {
      // 元数据失败不影响播放
    }
  }

  /**
   * 会话封面位图：按 `coverUrl` 缓存，同一张专辑切歌不重复解码。
   *
   * 走 `JellyfinNative.loadImage`（与应用其它图片同一条链路：core 的 HTTP + 磁盘缓存），
   * 命中缓存时不会产生网络请求。取不到就返回 null，面板只是不显示封面，不影响播放。
   */
  private async coverPixel(): Promise<image.PixelMap | null> {
    const key: string = this.coverUrl;
    if (key.length === 0) {
      return null;
    }
    if (this.coverPix !== null && this.coverKey === key) {
      return this.coverPix;
    }
    let path: string = key.startsWith('file://') ? key.substring(7) : '';
    if (path.length === 0) {
      try {
        const raw: string = await JellyfinNative.loadImage(key);
        const result: NativeResult = JellyfinNative.parseResult(raw);
        if (!result.ok || result.data === null) {
          return null;
        }
        path = JsonUtil.getString(result.data as ESObject, 'path', '');
      } catch (err) {
        return null;
      }
    }
    if (path.length === 0) {
      return null;
    }
    try {
      const source: image.ImageSource = image.createImageSource(path);
      const options: image.DecodingOptions = {
        desiredSize: { width: kCoverDecodePx, height: kCoverDecodePx }
      };
      const pixel: image.PixelMap = await source.createPixelMap(options);
      await source.release();
      const previous: image.PixelMap | null = this.coverPix;
      this.coverPix = pixel;
      this.coverKey = key;
      if (previous !== null) {
        // 交给会话时已跨进程拷贝，旧的一张可以直接放掉
        await previous.release();
      }
      return pixel;
    } catch (err) {
      return null;
    }
  }

  /** 会话侧的播放状态：只报 PLAY/PAUSE 会让面板和本机反着来（缓冲/失败时也显示暂停） */
  private sessionState(): avSession.PlaybackState {
    if (this.status === UiState.ERROR) {
      return avSession.PlaybackState.PLAYBACK_STATE_ERROR;
    }
    if (this.playing) {
      return avSession.PlaybackState.PLAYBACK_STATE_PLAY;
    }
    if (this.status === UiState.LOADING) {
      return avSession.PlaybackState.PLAYBACK_STATE_PREPARE;
    }
    return avSession.PlaybackState.PLAYBACK_STATE_PAUSE;
  }

  private syncSessionState(): void {
    if (this.session === null) {
      return;
    }
    this.lastSessionSyncMs = Date.now();
    const playing: boolean = this.playing;
    // 暂停时只报 state + position：实测带上 `speed: 0` 会被会话判为 `state not valid`
    // 而**整条丢弃**（设备表现：播控中心停在"播放中"，再点一次发的是 pause 而不是 play，
    // 用户没法从面板恢复播放）。时长走元数据的 `duration`，这里不重复给。
    const playbackState: avSession.AVPlaybackState = {
      state: this.sessionState(),
      position: { elapsedTime: Math.floor(this.positionMs), updateTime: Date.now() }
    };
    if (playing) {
      playbackState.speed = 1.0;
      playbackState.duration = this.durationMs;
      // 不报 `activeItemId`：它要对照 `setAVQueueItems` 注册过的队列，本工程没有队列
      playbackState.loopMode = avSession.LoopMode.LOOP_MODE_SEQUENCE;
    }
    this.session.setAVPlaybackState(playbackState).catch(() => {
      // 状态同步失败不影响本机播放
    });
  }

  /**
   * 申请长时任务，使应用退到后台后不被挂起。
   *
   * **失败会自愈**：先 `stopBackgroundRunning` 清掉可能残留的长时任务再试一次 ——
   * 真机实测（#73）：上一次没收干净的长时任务会让新的申请被系统直接拒绝，而残留只有
   * `stopBackgroundRunning` 能清。少了这一步，一次失败就让整轮聆听都没有后台能力，
   * 用户看到的就是"离开播放页/锁屏后音乐停了"。
   *
   * 用 `wantAgent` 让系统在用户点击通知时回到本应用。仍失败（例如权限被拒）不阻断前台播放，
   * 只如实提示 —— 否则用户会以为整个播放坏了。
   */
  private async startBackgroundTask(): Promise<void> {
    if (this.inBackgroundTask || this.ctx === null) {
      return;
    }
    const ctx: common.UIAbilityContext = this.ctx;
    let error: BusinessError | null = await this.requestBackgroundTask(ctx);
    if (error !== null) {
      // 自愈：清残留后再试一次（真机实测过的拒因，见上）
      hilog.warn(DOMAIN, TAG, '长时任务申请被拒（%{public}d），清残留后重试', error.code);
      await this.clearBackgroundTask(ctx);
      error = await this.requestBackgroundTask(ctx);
    }
    if (error === null) {
      hilog.info(DOMAIN, TAG, '长时任务已就绪：退到后台不被挂起');
      this.clearCapabilityNote();
      return;
    }
    // 201 = 权限未授予；9800005 = 长时任务校验失败（多为残留/未声明 backgroundModes）。如实提示，不静默失败。
    hilog.error(DOMAIN, TAG, '长时任务申请失败：%{public}d %{public}s', error.code, error.message);
    this.setCapabilityNote(error.code === 201
      ? '缺少长时任务权限，退到后台可能暂停'
      : `后台播放未启用（${error.code}），退到后台可能暂停`);
  }

  /** 申请一次长时任务：成功返回 null，失败返回错误（不改状态、不提示，由调用方决定怎么办） */
  private async requestBackgroundTask(ctx: common.UIAbilityContext): Promise<BusinessError | null> {
    try {
      if (this.wantAgentObj === null) {
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
      }
      await backgroundTaskManager.startBackgroundRunning(
        ctx,
        backgroundTaskManager.BackgroundMode.AUDIO_PLAYBACK,
        this.wantAgentObj
      );
      this.inBackgroundTask = true;
      return null;
    } catch (err) {
      return err as BusinessError;
    }
  }

  /**
   * 结束长时任务。
   *
   * **不做"没申请过就跳过"的短路**：残留的长时任务（上一次进程被系统杀掉时留下的）
   * 只能在这次进程里靠这一步清掉，而它正是下一次申请被拒的原因。
   */
  private async stopBackgroundTask(): Promise<void> {
    if (this.ctx === null) {
      return;
    }
    await this.clearBackgroundTask(this.ctx);
  }

  /** 与系统的长时任务对账：无论本进程记没记，都通知系统结束一次（没有在跑的任务会报错，忽略即可） */
  private async clearBackgroundTask(ctx: common.UIAbilityContext): Promise<void> {
    try {
      await backgroundTaskManager.stopBackgroundRunning(ctx);
    } catch (err) {
      // "当前没有长时任务"之类的报错属正常情况，不阻断流程
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

  /** 停播即放掉封面位图；下次起播重新解码（同专辑切歌走 coverKey 缓存） */
  private releaseCover(): void {
    const previous: image.PixelMap | null = this.coverPix;
    this.coverPix = null;
    this.coverKey = '';
    if (previous !== null) {
      previous.release().catch(() => {
        // 释放失败交给 GC，不影响停播流程
      });
    }
  }
}
