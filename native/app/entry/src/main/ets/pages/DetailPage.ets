import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { PageHeader } from '../components/PageHeader';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { JellyfinImage } from '../components/JellyfinImage';
import { HorizontalShelf } from '../components/HorizontalShelf';
import { AppIconButton } from '../components/AppIconButton';
import { PrimaryButton } from '../components/PrimaryButton';
import { SecondaryButton } from '../components/SecondaryButton';
import { TextButton } from '../components/TextButton';

/** 预计算的媒体流条目，供 Builder 使用 */
interface StreamEntry {
  type: string;
  codec: string;
  sizeLabel: string;
}

@Entry
@Component
struct DetailPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private itemId: string = '';
  @State private item: MediaItem = new MediaItem();
  @State private seasons: MediaItem[] = [];
  @State private similar: MediaItem[] = [];
  @State private people: Object[] = [];
  @State private expandedSeasonId: string = '';
  @State private episodes: MediaItem[] = [];
  /**
   * 弹层状态 —— 参考项目用「一个 bindSheet 节点 + sheetKind 判别」承载所有详情页弹层，
   * 不再为每个弹层手写全屏遮罩 + 居中卡片 + 点遮罩关闭（原来有 4 套这样的代码）。
   * '' 表示关闭；其余取值见 `SheetContent()`。
   */
  @State private sheetShow: boolean = false;
  @State private sheetKind: string = '';
  @State private audioStreamIndex: number = -1;
  @State private subtitleStreamIndex: number = -1;
  @State private forceTranscode: boolean = false;
  @State private mediaStreams: Object[] = [];
  @State private playlistItems: MediaItem[] = [];
  @State private playlistName: string = '';
  @State private playlistMessage: string = '';
  @State private favoriting: boolean = false;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idVal: Object | undefined = params['itemId'];
      if (typeof idVal === 'string') {
        this.itemId = idVal;
      }
    }
    this.loadDetail();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async loadDetail(): Promise<void> {
    if (this.itemId.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '缺少 itemId';
      return;
    }
    this.status = UiState.LOADING;
    const raw: string = await JellyfinNative.getItemDetail(this.itemId);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载详情失败';
      return;
    }
    this.item = MediaItem.fromJson(result.data);
    this.people = JsonUtil.getArray(result.data, 'People');
    this.seasons = MediaItem.fromArray(JsonUtil.extractItems(JsonUtil.getObject(result.data, 'Seasons')));
    if (this.seasons.length === 0) {
      this.seasons = MediaItem.fromArray(JsonUtil.getArray(result.data, 'Seasons'));
    }
    this.similar = MediaItem.fromArray(JsonUtil.extractItems(JsonUtil.getObject(result.data, 'Similar')));
    if (this.similar.length === 0) {
      this.similar = MediaItem.fromArray(JsonUtil.getArray(result.data, 'Similar'));
    }
    this.mediaStreams = [];
    const sources: Object[] = JsonUtil.getArray(result.data, 'MediaSources');
    if (sources.length > 0) {
      const src: ESObject = sources[0] as ESObject;
      this.mediaStreams = JsonUtil.getArray(src, 'MediaStreams');
    }
    this.status = UiState.SUCCESS;
  }

  private async loadEpisodes(seasonId: string): Promise<void> {
    if (this.expandedSeasonId === seasonId) {
      this.expandedSeasonId = '';
      this.episodes = [];
      return;
    }
    this.expandedSeasonId = seasonId;
    const raw: string = await JellyfinNative.getSeasonEpisodes(this.itemId, seasonId);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.episodes = [];
      return;
    }
    this.episodes = MediaItem.fromArray(JsonUtil.extractItems(result.data));
  }

  private async toggleFavorite(): Promise<void> {
    if (this.favoriting) return;
    this.favoriting = true;
    const next: boolean = !this.item.isFavorite;
    const raw: string = await JellyfinNative.toggleFavorite(this.item.id, next);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) {
      this.item.isFavorite = next;
    }
    this.favoriting = false;
  }

  private async togglePlayed(): Promise<void> {
    const next: boolean = !this.item.isPlayed;
    const raw: string = await JellyfinNative.togglePlayed(this.item.id, next);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) {
      this.item.isPlayed = next;
    }
  }

  private async openPlaylistPicker(): Promise<void> {
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.getPlaylists());
    if (!result.ok || result.data === null) {
      this.playlistItems = [];
      this.playlistMessage = result.message.length > 0 ? result.message : '加载播放列表失败';
    } else {
      this.playlistItems = MediaItem.fromArray(JsonUtil.extractItems(result.data));
      this.playlistMessage = '';
    }
    this.sheetKind = 'playlist';
    this.sheetShow = true;
  }

  private async addToPlaylist(playlistId: string): Promise<void> {
    let result: NativeResult;
    if (playlistId.length > 0) {
      result = JellyfinNative.parseResult(await JellyfinNative.addToPlaylist(playlistId, this.item.id));
    } else {
      const name: string = this.playlistName.trim();
      if (name.length === 0) {
        this.playlistMessage = '请输入播放列表名称';
        return;
      }
      result = JellyfinNative.parseResult(await JellyfinNative.createPlaylist(name, this.item.id));
    }
    if (!result.ok) {
      this.playlistMessage = result.message.length > 0 ? result.message : '播放列表操作失败';
      return;
    }
    this.playlistName = '';
    // 添加成功后关闭弹层（参考项目：改 sheetKind/sheetShow 即可，无需手写遮罩）
    this.sheetShow = false;
  }

  /**
   * 打开弹层 —— 参考项目的做法：只设置判别字段与显示开关，
   * 弹层本体由根节点上一个 `bindSheet` 负责（不再手写遮罩、居中卡片与"点遮罩关闭"）。
   */
  private openSheet(kind: string): void {
    this.sheetKind = kind;
    this.sheetShow = true;
  }

  private buildPlaybackOptions(): string {
    const opts: Record<string, Object> = {
      'audioStreamIndex': this.audioStreamIndex,
      'subtitleStreamIndex': this.subtitleStreamIndex,
      'enableDirectPlay': !this.forceTranscode,
      'enableDirectStream': !this.forceTranscode,
      'enableTranscoding': true
    };
    return JSON.stringify(opts);
  }

  private playItem(id: string): void {
    router.pushUrl({
      url: 'pages/PlayerPage',
      params: {
        itemId: id,
        title: this.item.name,
        playbackOptions: this.buildPlaybackOptions()
      }
    });
  }

  /**
   * 播放动作统一入口。
   *
   * 剧集（Series）**不能直接播放**：设备实测服务端对 `/Items/{seriesId}/PlaybackInfo`
   * 返回 **HTTP 500**（同一服务器对剧集条目 `/Items/{episodeId}/PlaybackInfo` 返回 200 并给出播放地址）。
   * 因此这里先解析出"第一季第一集"再交给播放器，与各 Jellyfin 客户端的行为一致。
   */
  private async startPlayback(): Promise<void> {
    if (this.item.type !== 'Series') {
      this.playItem(this.item.id);
      return;
    }
    if (this.seasons.length === 0) {
      this.errorMsg = '该剧集暂无可播放的分集';
      return;
    }
    const raw: string = await JellyfinNative.getSeasonEpisodes(this.item.id, this.seasons[0].id);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.errorMsg = result.message.length > 0 ? result.message : '加载分集失败';
      return;
    }
    const episodes: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    if (episodes.length === 0) {
      this.errorMsg = '该剧集暂无可播放的分集';
      return;
    }
    this.playItem(episodes[0].id);
  }

  private mediaInfoLabels(): string[] {
    const info: string[] = [];
    for (let i = 0; i < this.mediaStreams.length; i++) {
      const stream: ESObject = this.mediaStreams[i] as ESObject;
      const type: string = JsonUtil.getString(stream, 'Type', '').toLowerCase();
      const codec: string = JsonUtil.getString(stream, 'Codec', '');
      const width: number = JsonUtil.getNumber(stream, 'Width', 0);
      const height: number = JsonUtil.getNumber(stream, 'Height', 0);
      const bitRate: number = JsonUtil.getNumber(stream, 'BitRate', 0);
      if (type === 'video' && width > 0 && height > 0 && info.indexOf(`${width}x${height}`) < 0) {
        info.push(`${width}x${height}`);
      }
      if (codec.length > 0 && info.indexOf(codec.toUpperCase()) < 0) {
        info.push(codec.toUpperCase());
      }
      if (type === 'video' && bitRate > 0) {
        const rate: string = `${(bitRate / 1000000).toFixed(1)} Mbps`;
        if (info.indexOf(rate) < 0) {
          info.push(rate);
        }
      }
    }
    return info.slice(0, 6);
  }

  private personId(person: Object): string {
    return JsonUtil.itemId(person);
  }

  private personName(person: Object): string {
    const name: string = JsonUtil.itemName(person);
    return name.length > 0 ? name : '\u672a\u77e5';
  }

  private personImageUrl(person: Object): string {
    const id: string = this.personId(person);
    if (id.length === 0) {
      return '';
    }
    const tag: string = JsonUtil.getString(person as ESObject, 'PrimaryImageTag', '');
    return JellyfinNative.getImageUrl(id, 'Primary', 200, tag).trim();
  }

  private openPerson(person: Object): void {
    const id: string = this.personId(person);
    if (id.length > 0) {
      // 一并带上姓名：人物页直接用这个名字渲染头部，
      // 无需请求 /Users/{uid}/Items/{personId}（实测部分 Jellyfin 版本对该端点会挂起不响应）
      router.pushUrl({
        url: 'pages/PersonPage',
        params: { personId: id, personName: this.personName(person) }
      });
    }
  }

  private streamIndexAt(optionIndex: number): number {
    if (optionIndex < 0 || optionIndex >= this.mediaStreams.length) {
      return -1;
    }
    return JsonUtil.getNumber(this.mediaStreams[optionIndex] as ESObject, 'Index', -1);
  }

  private audioOptions(): SelectOption[] {
    const options: SelectOption[] = [];
    for (let i = 0; i < this.mediaStreams.length; i++) {
      const stream: ESObject = this.mediaStreams[i] as ESObject;
      const index: number = JsonUtil.getNumber(stream, 'Index', -1);
      const displayTitle: string = JsonUtil.getString(stream, 'DisplayTitle',
        JsonUtil.getString(stream, 'Language', ''));
      options.push({ value: displayTitle.length > 0 ? displayTitle : `Audio ${index}` });
    }
    return options;
  }

  private subtitleOptions(): SelectOption[] {
    const options: SelectOption[] = [{ value: '\u5173\u95ed' }];
    for (let i = 0; i < this.mediaStreams.length; i++) {
      const stream: ESObject = this.mediaStreams[i] as ESObject;
      const index: number = JsonUtil.getNumber(stream, 'Index', -1);
      const displayTitle: string = JsonUtil.getString(stream, 'DisplayTitle',
        JsonUtil.getString(stream, 'Language', ''));
      options.push({ value: displayTitle.length > 0 ? displayTitle : `Subtitle ${index}` });
    }
    return options;
  }

  /** 构建媒体信息行 */
  @Builder
  MediaInfoRow() {
    Flex({ wrap: FlexWrap.Wrap }) {
      ForEach(this.mediaInfoLabels(), (text: string) => {
        Text(text)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textPrimary)
          .padding({ left: 8, right: 8, top: 4, bottom: 4 })
          .backgroundColor(this.colors().surfacePressed)
          .borderRadius(8)
          .margin({ right: 8, bottom: 4 })
      }, (text: string) => text)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12 })
  }

  /** 流信息描述文本 */
  private streamsSummary(): string {
    return this.mediaStreams.length > 0
      ? `${this.mediaStreams.length} 条媒体流`
      : '无媒体流信息';
  }

  /** 流条目数据结构 */
  private streamEntries(): StreamEntry[] {
    const entries: StreamEntry[] = [];
    for (let i = 0; i < this.mediaStreams.length; i++) {
      const s: ESObject = this.mediaStreams[i] as ESObject;
      const type: string = JsonUtil.getString(s, 'Type', '');
      const codec: string = JsonUtil.getString(s, 'Codec', '');
      const w: number = JsonUtil.getNumber(s, 'Width', 0);
      const h: number = JsonUtil.getNumber(s, 'Height', 0);
      const sizeLabel: string = (w > 0 && h > 0) ? `${w}x${h}` : '';
      entries.push({ type, codec, sizeLabel });
    }
    return entries;
  }

  /**
   * 详情页统一弹层 —— 参考项目「一个 bindSheet 节点 + sheetKind 判别」：
   * 通过 `sheetKind` 决定渲染哪一份内容，取代原来 4 套手写全屏遮罩。
   */
  @Builder
  SheetContent() {
    if (this.sheetKind === 'playOptions') {
      this.PlayOptionsSheet()
    } else if (this.sheetKind === 'mediaInfo') {
      this.MediaInfoDialog()
    } else if (this.sheetKind === 'markPlayed') {
      this.MarkPlayedSheet()
    } else if (this.sheetKind === 'playlist') {
      this.PlaylistSheet()
    }
  }

  /** 播放选项（强制转码 / 媒体信息 / 加入播放列表） */
  @Builder
  PlayOptionsSheet() {
    Column({ space: 8 }) {
      Text('\u64ad\u653e\u9009\u9879')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
      Row() {
        Column({ space: 2 }) {
          Text('\u5f3a\u5236\u8f6c\u7801\u64ad\u653e')
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().textPrimary)
          Text('\u4e0d\u8d70\u76f4\u63a5\u64ad\u653e\uff0c\u7531\u670d\u52a1\u5668\u8f6c\u7801\u540e\u64ad\u653e')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.forceTranscode })
          .selectedColor(this.colors().brandPrimary)
          .onChange((on: boolean) => {
            this.forceTranscode = on;
          })
      }
      .width('100%')
      .padding({ top: 4, bottom: 4 })
      SecondaryButton({
        label: '\u5a92\u4f53\u4fe1\u606f',
        onTap: () => {
          this.sheetKind = 'mediaInfo';
        }
      })
      SecondaryButton({
        label: '\u52a0\u5165\u64ad\u653e\u5217\u8868',
        onTap: () => {
          this.openPlaylistPicker();
        }
      })
      TextButton({
        label: '\u5173\u95ed',
        onTap: () => {
          this.sheetShow = false;
        }
      })
        .margin({ top: 4 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 标记已播放/未播放确认 */
  @Builder
  MarkPlayedSheet() {
    Column({ space: 8 }) {
      Text(this.item.isPlayed ? $r('app.string.play_mark_unplayed') : $r('app.string.play_mark_played'))
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
      Text(this.item.isPlayed ? '\u786e\u8ba4\u6807\u8bb0\u4e3a\u672a\u64ad\u653e\uff1f' : '\u786e\u8ba4\u6807\u8bb0\u4e3a\u5df2\u64ad\u653e\uff1f')
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textSecondary)
        .margin({ bottom: 8 })
      PrimaryButton({
        label: this.item.isPlayed ? $r('app.string.play_mark_unplayed') : $r('app.string.play_mark_played'),
        onTap: () => {
          this.togglePlayed();
          this.sheetShow = false;
        }
      })
      TextButton({
        label: '\u53d6\u6d88',
        onTap: () => {
          this.sheetShow = false;
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 加入播放列表（新建 + 选择已有） */
  @Builder
  PlaylistSheet() {
    Column({ space: 8 }) {
      Text('\u52a0\u5165\u64ad\u653e\u5217\u8868')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
      TextInput({ text: this.playlistName, placeholder: '\u65b0\u5efa\u64ad\u653e\u5217\u8868\u540d\u79f0' })
        .width('100%')
        .height(ThemeConstants.INPUT_HEIGHT)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .backgroundColor(this.colors().pageBackground)
        .fontColor(this.colors().textPrimary)
        .placeholderColor(this.colors().textTertiary)
        .border({ width: 1, color: this.colors().divider, radius: ThemeConstants.COVER_RADIUS })
        .onChange((value: string) => {
          this.playlistName = value;
        })
      if (this.playlistMessage.length > 0) {
        Text(this.playlistMessage)
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().error)
          .width('100%')
      }
      PrimaryButton({
        label: '\u65b0\u5efa\u5e76\u6dfb\u52a0',
        onTap: () => {
          this.addToPlaylist('');
        }
      })
      if (this.playlistItems.length > 0) {
        List({ space: 4 }) {
          ForEach(this.playlistItems, (playlist: MediaItem) => {
            ListItem() {
              Text(playlist.name)
                .width('100%')
                .fontSize(ThemeConstants.BODY_MEDIUM)
                .fontColor(this.colors().textPrimary)
                .padding({ top: 10, bottom: 10 })
                .onClick(() => {
                  this.addToPlaylist(playlist.id);
                })
            }
          }, (playlist: MediaItem) => playlist.id)
        }
        .width('100%')
        .height(Math.min(180, this.playlistItems.length * 44))
        .scrollBar(BarState.Auto)
      }
      TextButton({
        label: '\u53d6\u6d88',
        onTap: () => {
          this.sheetShow = false;
        }
      })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 完整媒体流信息（作为 sheet 内容渲染，不再自带遮罩与卡片外壳） */
  @Builder
  MediaInfoDialog() {
    Column({ space: 8 }) {
      Text($r('app.string.media_info_title'))
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
      Text(this.streamsSummary())
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
      List({ space: 4 }) {
        ForEach(this.streamEntries(), (entry: StreamEntry) => {
          ListItem() {
            Row() {
              Text(entry.type)
                .fontSize(ThemeConstants.BADGE_LABEL)
                .fontColor(this.colors().brandPrimary)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(this.colors().surfacePressed)
                .borderRadius(5)
              Text(entry.codec)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textPrimary)
                .margin({ left: 8 })
              Text(entry.sizeLabel)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(entry.sizeLabel.length > 0 ? this.colors().textSecondary : Color.Transparent)
                .margin({ left: 8 })
            }
            .width('100%')
            .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          }
        }, (_: StreamEntry, idx: number) => `${idx}`)
      }
      .width('100%')
      .height(200)
      .scrollBar(BarState.Auto)
      TextButton({
        label: '\u5173\u95ed',
        onTap: () => {
          this.sheetShow = false;
        }
      })
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Center)
  }

  /** 演职人员横滑 */
  @Builder
  PeopleRow(people: Object[]) {
    Column() {
      Text('\u6f14\u804c\u4eba\u5458')
        .fontSize(ThemeConstants.TITLE_SMALL)
        .fontColor(this.colors().textPrimary)
        .padding({ left: 16, top: 8, bottom: 8 })
        .width('100%')
      List({ space: 12 }) {
        ForEach(people, (p: Object) => {
          ListItem() {
            Column({ space: 4 }) {
              JellyfinImage({
                url: this.personImageUrl(p),
                imgWidth: 72,
                imgHeight: 72,
                cornerRadius: 36,
                placeholderIcon: 'person'
              })
              Text(this.personName(p))
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().textPrimary)
                .maxLines(1)
                .width(72)
                .textAlign(TextAlign.Center)
            }
            .width(72)
            .onClick(() => {
              this.openPerson(p);
            })
          }
        }, (p: Object, index: number) => `${this.personId(p)}_${index}`)
      }
      .listDirection(Axis.Horizontal)
      .height(110)
      .scrollBar(BarState.Off)
      .padding({ left: 16, right: 16 })
    }
    .width('100%')
  }

  build() {
    Stack() {
      if (this.status !== UiState.SUCCESS) {
        Column() {
          PageHeader({
            title: '\u8be6\u60c5',
            onBack: () => {
              router.back();
            }
          })
          if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
            LoadingState()
          } else if (this.status === UiState.ERROR) {
            EmptyState({
              message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
              actionLabel: '重试',
              onAction: () => {
                this.loadDetail();
              }
            })
          } else if (this.status === UiState.EMPTY) {
            EmptyState({ message: '暂无数据' })
          }
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.colors().pageBackground)
      } else {
        Scroll() {
          Column() {
            // 顶部背景横幅（BackdropBanner）
            Stack({ alignContent: Alignment.TopStart }) {
              Image(this.item.imageUrl(900, 'Backdrop'))
                .width('100%')
                .height(180)
                .objectFit(ImageFit.Cover)
                .onError(() => {
                  // 背景图加载失败不影响页面
                })
              Column()
                .width('100%')
                .height('100%')
                .linearGradient({
                  angle: 180,
                  colors: [[this.colors().posterScrim, 0.0], [this.colors().pageBackground, 1.0]]
                })
            }
            .width('100%')
            .height(180)

            PageHeader({
              title: '',
              onBack: () => {
                router.back();
              }
            })

            // 海报 + 信息区
            Row({ space: 16 }) {
              JellyfinImage({
                url: this.item.imageUrl(600, 'Primary'),
                imgWidth: ThemeConstants.DETAIL_POSTER_WIDTH,
                imgHeight: ThemeConstants.DETAIL_POSTER_HEIGHT,
                cornerRadius: ThemeConstants.POSTER_RADIUS
              })
              Column({ space: 8 }) {
                Text(this.item.name)
                  .fontSize(ThemeConstants.TITLE_LARGE)
                  .fontColor(this.colors().textPrimary)
                  .maxLines(2)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Text(this.item.metaLine())
                  .fontSize(ThemeConstants.LABEL_SMALL)
                  .fontColor(this.colors().textSecondary)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                  .width('100%')
                Flex({ wrap: FlexWrap.Wrap }) {
                  if (this.item.type.length > 0) {
                    Text(this.item.typeLabel())
                      .fontSize(ThemeConstants.LABEL_SMALL)
                      .fontColor(this.colors().textPrimary)
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .backgroundColor(this.colors().surfacePressed)
                      .borderRadius(8)
                      .margin({ right: 8, bottom: 4 })
                  }
                  ForEach(this.item.genres.slice(0, 3), (genre: string) => {
                    Text(genre)
                      .fontSize(ThemeConstants.LABEL_SMALL)
                      .fontColor(this.colors().textPrimary)
                      .padding({ left: 8, right: 8, top: 4, bottom: 4 })
                      .backgroundColor(this.colors().surfacePressed)
                      .borderRadius(8)
                      .margin({ right: 8, bottom: 4 })
                  }, (genre: string) => genre)
                }
                .width('100%')
                // 播放按钮行 —— 主操作按参考项目规格（48vp / 12vp 圆角 / 品牌实底 + 微光投影），
                // 其余操作用 40vp 圆形图标按钮 + 系统符号（原来用的是 ▼ ★ ⏱ ⋮ 文本字符）
                Flex({ wrap: FlexWrap.Wrap }) {
                  Button(this.item.type === 'Episode' ? '\u64ad\u653e\u672c\u96c6' : '\u64ad\u653e',
                    { type: ButtonType.Normal, stateEffect: false })
                    .height(ThemeConstants.BUTTON_HEIGHT)
                    .width(this.item.type === 'Series' || this.item.type === 'Episode' ? 150 : '100%')
                    .fontSize(ThemeConstants.TITLE_MEDIUM)
                    .fontWeight(FontWeight.Medium)
                    .backgroundColor(this.colors().brandPrimary)
                    .fontColor(this.colors().onBrand)
                    .borderRadius(ThemeConstants.BUTTON_RADIUS)
                    .shadow({
                      radius: 10,
                      color: this.colors().buttonShadow,
                      offsetX: 0,
                      offsetY: 4
                    })
                    .stateStyles({
                      pressed: {
                        .backgroundColor(this.colors().brandPrimaryPressed)
                      }
                    })
                    .margin({ right: 4, bottom: 4 })
                    .onClick(() => {
                      // 走统一入口：剧集会先解析分集（系列条目本身无法直接播放）
                      this.startPlayback();
                    })
                  AppIconButton({
                    icon: $r('sys.symbol.chevron_down'),
                    variant: 'surface',
                    iconSize: 18,
                    onTap: () => {
                      this.openSheet('playOptions');
                    }
                  })
                    .margin({ right: 4, bottom: 4 })
                  AppIconButton({
                    icon: this.item.isFavorite ? $r('sys.symbol.star_fill') : $r('sys.symbol.star'),
                    variant: this.item.isFavorite ? 'soft' : 'surface',
                    iconSize: 19,
                    onTap: () => {
                      this.toggleFavorite();
                    }
                  })
                    .margin({ right: 4, bottom: 4 })
                  AppIconButton({
                    icon: $r('sys.symbol.clock'),
                    variant: 'surface',
                    iconSize: 18,
                    iconColorOverride: this.item.isPlayed ? this.colors().success : '',
                    onTap: () => {
                      this.openSheet('markPlayed');
                    }
                  })
                    .margin({ right: 4, bottom: 4 })
                  AppIconButton({
                    icon: $r('sys.symbol.ellipsis_circle'),
                    variant: 'surface',
                    iconSize: 18,
                    onTap: () => {
                      // 更多菜单：直接打开媒体信息弹层
                      this.openSheet('mediaInfo');
                    }
                  })
                    .margin({ bottom: 4 })
                }
                .width('100%')
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
            }
            .width('100%')
            .padding({ left: 16, right: 16, top: 12, bottom: 4 })

            // 音频/字幕选择器（如果有多个音轨或字幕轨）
            if (this.mediaStreams.length > 1) {
              Column() {
                Text('\u97f3\u9891 / \u5b57\u5e55')
                  .fontSize(ThemeConstants.LABEL_SMALL)
                  .fontColor(this.colors().textSecondary)
                  .padding({ left: 16, bottom: 4 })
                  .width('100%')
                Row({ space: 12 }) {
                  // 音频轨选择
                  Select(this.audioOptions())
                    .backgroundColor(this.colors().surfacePressed)
                    .fontColor(this.colors().textPrimary)
                    .height(40)
                    .layoutWeight(1)
                    .border({ width: 1, color: this.colors().divider, radius: 4 })
                    .padding({ left: 12, right: 12 })
                    .onSelect((index: number, _value: string) => {
                      this.audioStreamIndex = this.streamIndexAt(index);
                    })
                  // 字幕轨选择
                  Select(this.subtitleOptions())
                    .backgroundColor(this.colors().surfacePressed)
                    .fontColor(this.colors().textPrimary)
                    .height(40)
                    .layoutWeight(1)
                    .border({ width: 1, color: this.colors().divider, radius: 4 })
                    .padding({ left: 12, right: 12 })
                    .onSelect((index: number, _value: string) => {
                      this.subtitleStreamIndex = index === 0 ? -1 : this.streamIndexAt(index - 1);
                    })
                }
                .width('100%')
                .padding({ left: 16, right: 16, top: 4, bottom: 8 })
              }
              .width('100%')
            }

            // 简介
            if (this.item.overview.length > 0) {
              Text(this.item.overview)
                .fontSize(ThemeConstants.BODY_MEDIUM)
                .fontColor(this.colors().textPrimary)
                .lineHeight(22)
                .padding({ left: 16, right: 16, top: 4, bottom: 16 })
                .width('100%')
            }

            // 演职人员
            if (this.people.length > 0) {
              this.PeopleRow(this.people)
            }

            // 媒体信息
            if (this.mediaInfoLabels().length > 0) {
              this.MediaInfoRow();
            }

            // 季-集浏览（Series 类型）
            if (this.item.type === 'Series' && this.seasons.length > 0) {
              Column() {
                Text('\u5b63\u4e0e\u96c6')
                  .fontSize(ThemeConstants.TITLE_SMALL)
                  .fontColor(this.colors().textPrimary)
                  .padding({ left: 16, top: 8, bottom: 8 })
                  .width('100%')
                ForEach(this.seasons, (season: MediaItem) => {
                  Column() {
                    Row() {
                      Text(season.name)
                        .fontSize(ThemeConstants.BODY_MEDIUM)
                        .fontColor(this.colors().textPrimary)
                        .layoutWeight(1)
                      SymbolGlyph(this.expandedSeasonId === season.id
                        ? $r('sys.symbol.chevron_down')
                        : $r('sys.symbol.chevron_right'))
                        .fontSize(ThemeConstants.TITLE_MEDIUM)
                        .fontColor([this.colors().textTertiary])
                    }
                    .width('100%')
                    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
                    .backgroundColor(this.colors().cardBackground)
                    .onClick(() => {
                      this.loadEpisodes(season.id);
                    })

                    if (this.expandedSeasonId === season.id) {
                      List({ space: 10 }) {
                        ForEach(this.episodes, (ep: MediaItem) => {
                          ListItem() {
                            Row({ space: 10 }) {
                              JellyfinImage({
                                url: ep.imageUrl(300, 'Primary'),
                                imgWidth: 128,
                                imgHeight: 72,
                                cornerRadius: 8
                              })
                              Column({ space: 4 }) {
                                Text(ep.displayTitle())
                                  .fontSize(ThemeConstants.BODY_MEDIUM)
                                  .fontColor(this.colors().textPrimary)
                                  .maxLines(2)
                                Text(ep.metaLine())
                                  .fontSize(ThemeConstants.LABEL_SMALL)
                                  .fontColor(this.colors().textSecondary)
                              }
                              .alignItems(HorizontalAlign.Start)
                              .layoutWeight(1)
                            }
                            .width('100%')
                            .padding({ left: 16, right: 16 })
                            .onClick(() => {
                              this.playItem(ep.id);
                            })
                          }
                        }, (ep: MediaItem) => ep.id)
                      }
                      .height(Math.min(320, this.episodes.length * 88 + 8))
                      .scrollBar(BarState.Auto)
                      .width('100%')
                    }
                  }
                  .width('100%')
                  .margin({ bottom: 4 })
                }, (season: MediaItem) => season.id)
              }
              .width('100%')
            }

            // 相关推荐
            if ((this.item.type === 'Movie' || this.item.type === 'Series') && this.similar.length > 0) {
              HorizontalShelf({
                title: '\u76f8\u4f3c\u63a8\u8350',
                icon: '',
                items: this.similar,
                shelfHeight: 235,
                onItemTap: (it: MediaItem) => {
                  router.pushUrl({ url: 'pages/DetailPage', params: { itemId: it.id } });
                }
              })
            }
          }
          .width('100%')
          .padding({ bottom: 32 })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Off)
      }

      // 所有弹层统一由根节点的 bindSheet + sheetKind 承载（见文件末尾），
      // 原来这里的 4 套「全屏遮罩 + 居中卡片 + 点遮罩关闭」已删除
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
    .bindSheet($$this.sheetShow, this.SheetContent(), {
      height: SheetSize.FIT_CONTENT,
      dragBar: false,
      backgroundColor: this.colors().cardBackground,
      onDisappear: () => {
        // 关闭后清空判别字段，下次打开时不会残留上次的内容
        this.sheetKind = '';
      }
    })
  }
}
