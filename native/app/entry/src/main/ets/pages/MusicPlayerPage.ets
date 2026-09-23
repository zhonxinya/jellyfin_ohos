import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { formatTicks } from '../common/format';
import { MusicPlayback, MusicPlaybackState } from '../common/MusicPlayback';
import { PageHeader } from '../components/PageHeader';
import { EmptyState } from '../components/EmptyState';
import { JellyfinImage } from '../components/JellyfinImage';

/** 与服务状态同步的间隔：与服务内部 tick 同量级（进度每秒推进，500ms 足够跟手） */
const kSyncMs: number = 500;

/**
 * 音乐播放页 —— **播放服务的视图层**。
 *
 * ## 为什么单独一页而不是复用 PlayerPage
 * `PlayerPage` 是**视频**播放器：XComponent 画面、字幕叠加、软解渲染、全屏控制条，
 * 它的 AVSession 类型硬编码为 `'video'`、`setAVMetadata` 也按视频填。把它改成"既能视频又能音频"
 * 会让那条已经很敏感的链路（硬解/软解回退、字幕、手势）同时承受音频分支的风险。
 *
 * ## 播放不归本页所有（用户口径："实现播放音乐加入后台"）
 * AVPlayer / AVSession / 长时任务都由 `common/MusicPlayback`（单例）持有，本页只做两件事：
 * 把服务状态同步到 @State 渲染、把用户操作转成服务调用。因此**离开本页音乐继续播**，
 * 迷你条（`MainShell`）与本页看到的是同一份状态；再次进入本页会回到原来的进度，
 * 不会从头开始（`MusicPlayback.request` 对"同一首"只挂载不重启）。
 *
 * 两种进入方式：
 *   - 带曲目参数（「曲目」列表、专辑页）→ 请求播放；
 *   - 不带参数（点底部迷你条）→ 直接显示当前正在播的那一首。
 */
@Entry
@Component
struct MusicPlayerPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private note: string = '';
  @State private albumTitle: string = '';
  @State private trackName: string = '';
  @State private artistLabel: string = '';
  @State private counterLabel: string = '';
  @State private coverUrl: string = '';
  @State private playing: boolean = false;
  @State private positionMs: number = 0;
  @State private durationMs: number = 0;

  private service: MusicPlayback = MusicPlayback.getInstance();
  private syncTimer: number = -1;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    const ids: string[] = [];
    const names: string[] = [];
    let index: number = 0;
    let albumName: string = '';
    let artistName: string = '';
    let cover: string = '';
    if (params !== undefined && params !== null) {
      const idsVal: Object | undefined = params['trackIds'];
      if (Array.isArray(idsVal)) {
        for (let i = 0; i < (idsVal as string[]).length; i++) {
          ids.push((idsVal as string[])[i]);
        }
      }
      const namesVal: Object | undefined = params['trackNames'];
      if (Array.isArray(namesVal)) {
        for (let i = 0; i < (namesVal as string[]).length; i++) {
          names.push((namesVal as string[])[i]);
        }
      }
      const idxVal: Object | undefined = params['startIndex'];
      if (typeof idxVal === 'number') {
        index = idxVal;
      }
      const albumVal: Object | undefined = params['albumName'];
      if (typeof albumVal === 'string') {
        albumName = albumVal;
      }
      const artistVal: Object | undefined = params['artistName'];
      if (typeof artistVal === 'string') {
        artistName = artistVal;
      }
      const coverVal: Object | undefined = params['coverUrl'];
      if (typeof coverVal === 'string') {
        cover = coverVal;
      }
    }

    if (ids.length > 0) {
      this.service.request(
        getContext(this) as common.UIAbilityContext, ids, names, index, albumName, artistName, cover);
    } else if (!this.service.snapshot().hasTrack) {
      // 既没带曲目、也没有在播的曲目：正常入口（迷你条）不会走到这里
      this.status = UiState.ERROR;
      this.errorMsg = '没有可播放的曲目';
    }

    this.syncFromService();
    this.syncTimer = setInterval(() => {
      this.syncFromService();
    }, kSyncMs);
  }

  aboutToDisappear(): void {
    if (this.syncTimer >= 0) {
      clearInterval(this.syncTimer);
      this.syncTimer = -1;
    }
    // 刻意**不**停播放：播放归 MusicPlayback 所有，离开本页要继续播（这就是"后台播放"）
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /**
   * 把服务状态同步到页面 @State。
   *
   * 只在**值变化**时回写：这里每 500ms 跑一次，无脑赋值会让整页每 500ms 重建一次。
   */
  private syncFromService(): void {
    const s: MusicPlaybackState = this.service.snapshot();
    if (this.status !== s.status) {
      this.status = s.status;
    }
    if (this.errorMsg !== s.errorMsg) {
      this.errorMsg = s.errorMsg;
    }
    if (this.note !== s.note) {
      this.note = s.note;
    }
    if (this.playing !== s.playing) {
      this.playing = s.playing;
    }
    if (this.positionMs !== s.positionMs) {
      this.positionMs = s.positionMs;
    }
    if (this.durationMs !== s.durationMs) {
      this.durationMs = s.durationMs;
    }
    if (this.coverUrl !== s.coverUrl) {
      this.coverUrl = s.coverUrl;
    }
    if (this.albumTitle !== s.albumName) {
      this.albumTitle = s.albumName;
    }
    const trackName: string = s.currentTrackName();
    if (this.trackName !== trackName) {
      this.trackName = trackName;
    }
    if (this.artistLabel !== s.artistName) {
      this.artistLabel = s.artistName;
    }
    const counter: string = s.trackIds.length > 0
      ? `${s.currentIndex + 1} / ${s.trackIds.length}`
      : '';
    if (this.counterLabel !== counter) {
      this.counterLabel = counter;
    }
  }

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
        this.service.playPrev();
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
        this.service.togglePlay();
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
        this.service.playNext();
      })
    }
    .justifyContent(FlexAlign.Center)
    .width('100%')
  }

  build() {
    Column() {
      PageHeader({
        title: this.albumTitle.length > 0 ? this.albumTitle : '正在播放',
        onBack: () => {
          router.back();
        }
      })

      if (this.status === UiState.ERROR) {
        EmptyState({
          message: this.errorMsg.length > 0 ? this.errorMsg : '播放失败',
          actionLabel: '重试',
          onAction: () => {
            this.service.retry();
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
            Text(this.trackName)
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .maxLines(2)
              .textAlign(TextAlign.Center)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            Text(this.artistLabel.length > 0 ? this.artistLabel : this.counterLabel)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().textTertiary)
            Text(this.counterLabel)
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
                  this.service.setScrubbing(true);
                  this.positionMs = value;
                } else if (mode === SliderChangeMode.End || mode === SliderChangeMode.Click) {
                  this.service.setScrubbing(false);
                  this.service.seekTo(value);
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
  }
}
