import router from '@ohos.router';
import media from '@ohos.multimedia.media';
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
    this.hideTimerId = setTimeout(() => {
      if (this.isPlaying && !this.controlsLocked) {
        this.showControls = false;
      }
    }, 3000);
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
          this.status = UiState.ERROR;
          this.errorMsg = '播放出错';
        }
      });
      this.avPlayer.on('error', (_err: Error) => {
        this.status = UiState.ERROR;
        this.errorMsg = '播放器错误';
      });
      // 如果 surfaceId 已经从 XComponent.onLoad 获取到，立即绑定
      if (this.surfaceId.length > 0) {
        this.avPlayer.surfaceId = this.surfaceId;
      }
      // 设置 URL 触发 AVPlayer 加载视频流
      this.avPlayer.url = url;
    } catch (_err) {
      this.status = UiState.ERROR;
      this.errorMsg = '初始化播放器失败';
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
            .fontSize(ThemeConstants.BODY_MEDIUM)
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
            .selectedColor(this.colors().primary)
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

      // 进度条
      Slider({
        value: this.positionMs,
        min: 0,
        max: this.sliderMax(),
        step: 100,
        style: SliderStyle.OutSet
      })
        .width('100%')
        .selectedColor(this.colors().primary)
        .trackColor(this.colors().overlayControl)
        .trackThickness(4)
        .blockSize({ width: 12, height: 12 })
        .onChange((value: number) => {
          const v: number = Math.floor(value);
          if (this.avPlayer !== null) {
            this.avPlayer.seek(v);
          }
          this.positionMs = v;
          this.revealControls();
        })

      // 时间显示 + 倍速
      Row() {
        Text(this.formatTime(this.positionMs))
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlayMuted)
        Blank()
        Text(`${this.playbackSpeed}x`)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlayMuted)
          .margin({ right: 8 })
        Text(this.durationMs > 0 ? this.formatTime(this.durationMs) : '--:--')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlayMuted)
      }
      .width('100%')

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
        ChipButton({
          label: `${this.playbackSpeed}x`,
          selected: this.playbackSpeed !== 1,
          onTap: () => {
            this.cycleSpeed();
          }
        })
      }
      .width('100%')
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
    Column() {
      SymbolGlyph($r('sys.symbol.lock'))
        .fontSize(ThemeConstants.ICON_XXL)
        .fontColor([this.colors().onOverlay])
      Text('已锁定，点击解锁')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().onOverlayMuted)
        .margin({ top: 4 })
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
          .color(this.colors().primary)
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
      XComponent({ id: 'jellyfin_player', type: XComponentType.SURFACE })
        .width('100%')
        .height('100%')
        .backgroundColor(this.colors().videoBackground)
        .onLoad(() => {
          // XComponent surface is created after load; bind to AVPlayer if available
          if (this.avPlayer !== null && this.surfaceId.length > 0) {
            this.avPlayer.surfaceId = this.surfaceId;
          }
        })
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

      // 加载状态
      if (this.status === UiState.LOADING) {
        Column() {
          LoadingProgress()
            .width(48)
            .height(48)
            .color(this.colors().primary)
          Text('加载播放器...')
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontColor(this.colors().onOverlayMuted)
            .margin({ top: 16 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.colors().videoBackground)
      }

      if (this.status === UiState.ERROR) {
        Column() {
          // 错误态复用 EmptyState（参考项目约定：错误不另造组件，配"重试"动作）
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '播放出错',
            actionLabel: '重试',
            onAction: () => {
              this.stopped = false;
              this.openPlayer();
            }
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.colors().videoBackground)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().videoBackground)
  }
}
