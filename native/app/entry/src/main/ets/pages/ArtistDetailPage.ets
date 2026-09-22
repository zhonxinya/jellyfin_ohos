import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { WindowLayout } from '../common/WindowLayout';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';
import { MediaItem } from '../models/MediaItem';
import { PageHeader } from '../components/PageHeader';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { JellyfinImage } from '../components/JellyfinImage';

/** 专辑一次取满即可（实测该库共 163 张，单艺术家最多数十张） */
const kAlbumLimit: number = 200;

/**
 * 艺术家详情页：列出这位艺术家的专辑。
 *
 * 为什么需要它：音乐库（`CollectionType=music`）的根内容**就是艺术家**
 * —— 实测该库根目录返回 42 个 `MusicArtist`，不是专辑。所以点进一位艺术家后必须有地方
 * 列出他/她的专辑，否则用户走不到曲目与播放。此前既没有这一页，也没有任何音乐分支。
 *
 * 数据来源走现有 `queryItems`（`ItemsQueryOptions` + `IncludeItemTypes=MusicAlbum`
 * + `ParentId=艺术家`），**不新增后端能力**：core 的 `BuildItemsQueryPath` 已支持这些参数，
 * 与媒体库/搜索页是同一条路径（符合 AGENTS.md「请求构造集中在 C++ core」的约定）。
 *
 * 封面走 `JellyfinImage`（经本工程 HTTP + 磁盘缓存），URL 由 `MediaItem.imageUrl` 生成。
 */
@Entry
@Component
struct ArtistDetailPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private artistName: string = '艺术家';
  @State private artistId: string = '';
  @State private albums: MediaItem[] = [];

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idVal: Object | undefined = params['artistId'];
      if (typeof idVal === 'string') {
        this.artistId = idVal;
      }
      const nameVal: Object | undefined = params['artistName'];
      if (typeof nameVal === 'string' && nameVal.length > 0) {
        this.artistName = nameVal;
      }
    }
    this.reload();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async reload(): Promise<void> {
    if (this.artistId.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '缺少艺术家标识';
      return;
    }
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const query: ItemsQueryOptions = new ItemsQueryOptions();
    query.parentId = this.artistId;
    query.startIndex = 0;
    query.limit = kAlbumLimit;
    query.includeItemTypes = 'MusicAlbum';
    // 只看这位艺术家名下的专辑，不递归进专辑内部的曲目
    query.recursive = false;
    query.sortBy = 'ProductionYear,PremiereDate,SortName';
    query.sortOrder = 'Ascending';
    query.enableUserData = false;

    const result: NativeResult =
      JellyfinNative.parseResult(await JellyfinNative.queryItems(query.toJson()));
    if (!result.ok || result.data === null) {
      // 失败也要落到终态，否则界面永远停在"加载中"
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载专辑失败';
      return;
    }
    try {
      this.albums = MediaItem.fromArray(JsonUtil.extractItems(result.data));
      this.status = this.albums.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
    } catch (err) {
      this.status = UiState.ERROR;
      this.errorMsg = `解析专辑列表失败：${(err as Error).message}`;
    }
  }

  private openAlbum(album: MediaItem): void {
    if (album.id.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/AlbumDetailPage',
      params: {
        albumId: album.id,
        albumName: album.displayTitle(),
        // 一并带下艺术家名，专辑页无需再请求艺术家
        artistName: this.artistName
      }
    });
  }

  /**
   * 卡片宽度 = 实际列宽。
   *
   * **为什么必须按列算而不是写死 vp**（设备实测的 bug）：原来固定 `width(150)`，
   * 而竖屏下 GridItem 的单元格宽是 556px（≈165vp）。卡片比列窄 15vp，
   * 就落进 GridItem 的默认居中对齐里 —— 实测标题文本中心 x=332，正好等于单元格中心
   * (54+610)/2=332，也就是"卡片在列内居中、右边空一条"。
   *
   * 这与工程既有写法一致（`MediaCollectionView.cardWidthForColumns` → `WindowLayout.cardWidth`），
   * 让卡片宽度贴合列宽，自然后续所有内容都左对齐，也与媒体库网格的观感统一。
   */
  private cardWidth(): number {
    return WindowLayout.cardWidth(this.resolvedColumns());
  }

  /** 列数由窗口宽度决定（与媒体库网格同一套规则） */
  private resolvedColumns(): number {
    return WindowLayout.gridColumns();
  }

  private columnsTemplate(): string {
    const cols: number = this.resolvedColumns();
    const parts: string[] = [];
    for (let i = 0; i < cols; i++) {
      parts.push('1fr');
    }
    return parts.join(' ');
  }

  @Builder
  AlbumGrid() {
    Grid() {
      ForEach(this.albums, (album: MediaItem) => {
        GridItem() {
          Column({ space: 6 }) {
            JellyfinImage({
              url: album.imageUrl(320, 'Primary'),
              // 封面用 1:1 方图（专辑封面是方的），宽度跟随列宽
              imgWidth: this.cardWidth(),
              imgHeight: this.cardWidth(),
              cornerRadius: ThemeConstants.CARD_RADIUS
            })
            Text(album.displayTitle())
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().textPrimary)
              .maxLines(2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
          }
          .width('100%')
          .height('100%')
          .alignItems(HorizontalAlign.Start)
          .onClick(() => {
            this.openAlbum(album);
          })
        }
      }, (album: MediaItem, index: number) => `${album.id}_${index}`)
    }
    .columnsTemplate(this.columnsTemplate())
    .columnsGap(ThemeConstants.GRID_COLUMN_GAP)
    .rowsGap(ThemeConstants.GRID_ROW_GAP)
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 24 })
    .width('100%')
  }

  build() {
    Column() {
      PageHeader({ title: this.artistName, onBack: () => { router.back(); } })

      if (this.status === UiState.LOADING) {
        LoadingState({ hint: '正在加载专辑…' })
      } else if (this.status === UiState.ERROR) {
        EmptyState({
          message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
          actionLabel: '重试',
          onAction: () => {
            this.reload();
          }
        })
      } else if (this.status === UiState.EMPTY) {
        EmptyState({ message: '这位艺术家下没有可显示的专辑' })
      } else {
        Scroll() {
          Column() {
            this.AlbumGrid()
          }
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
