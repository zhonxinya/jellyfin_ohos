import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { MediaCollectionView, MediaViewToggle } from '../components/MediaCollectionView';
import { PageScaffold } from '../components/PageScaffold';
import { SearchBar } from '../components/SearchBar';
import { EmptyState } from '../components/EmptyState';
import { LoadingState } from '../components/LoadingState';

/**
 * 搜索页 —— 已按 mybooks_ohos 的页面模板重构。
 *
 * 迁移要点：
 * - 顶栏换成 `PageScaffold` + 56vp `AppTopBar`（原来是 56vp 手写 AppBar，标题字号/边距都是字面量）；
 * - 搜索栏换成 `SearchBar` 组件（40vp 输入框 + 右侧品牌色圆形搜索按钮），
 *   清除按钮作为可选能力保留；
 * - **卡片/列表切换按钮移到顶栏右侧插槽**（参考项目把视图切换放在顶栏 action 位，而不是内容区）；
 * - 状态渲染统一成 `LoadingState` / `EmptyState`（错误态复用空态 + "重试"），不再用 `AsyncStateView`；
 * - 搜索建议行改用参考项目的列表行语言：内容 16vp 内边距、0.5vp 分隔线、按下态 `surface_pressed`。
 */
@Entry
@Component
struct SearchPage {
  @State private query: string = '';
  @State private status: string = UiState.INITIAL;
  @State private errorMsg: string = '';
  @State private items: MediaItem[] = [];
  @State private hintItems: MediaItem[] = [];
  @State private startIndex: number = 0;
  @State private hasMore: boolean = true;
  @State private loadingMore: boolean = false;
  @State private viewMode: string = 'grid';
  @State private footerTriggered: boolean = false;
  private debounceId: number = -1;
  private readonly pageSize: number = ThemeConstants.PAGE_SIZE;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private scheduleSearch(value: string): void {
    this.query = value;
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
    if (value.trim().length === 0) {
      this.items = [];
      this.hintItems = [];
      this.status = UiState.INITIAL;
      return;
    }
    this.debounceId = setTimeout(() => {
      this.loadHints();
    }, 300);
  }

  private clearQuery(): void {
    this.query = '';
    this.hintItems = [];
    this.items = [];
    this.status = UiState.INITIAL;
  }

  private async loadHints(): Promise<void> {
    const raw: string = await JellyfinNative.searchHints(this.query.trim(), 6);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.hintItems = [];
      return;
    }
    const hints: Object[] = JsonUtil.getArray(result.data, 'SearchHints');
    this.hintItems = MediaItem.fromArray(hints.length > 0 ? hints : JsonUtil.extractItems(result.data));
  }

  private async runSearch(more: boolean): Promise<void> {
    const q: string = this.query.trim();
    if (q.length === 0) {
      return;
    }
    if (more) {
      if (!this.hasMore || this.loadingMore) {
        return;
      }
      this.loadingMore = true;
    } else {
      this.status = UiState.LOADING;
      this.errorMsg = '';
      this.startIndex = 0;
      this.hasMore = true;
      this.items = [];
      this.footerTriggered = false;
    }
    const raw: string = await JellyfinNative.search(q, this.startIndex, this.pageSize);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.loadingMore = false;
    this.footerTriggered = false;
    if (!result.ok) {
      if (!more) {
        this.status = UiState.ERROR;
        this.errorMsg = result.message.length > 0 ? result.message : '搜索失败';
      }
      return;
    }
    const page: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    if (more) {
      this.items = this.items.concat(page);
    } else {
      this.items = page;
    }
    this.startIndex = this.startIndex + page.length;
    this.hasMore = page.length >= this.pageSize;
    this.status = this.items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  /** 顶栏右侧：结果列表出现后提供卡片/列表切换（对齐参考项目的顶栏视图切换） */
  @Builder
  topBarAction() {
    if (this.status === UiState.SUCCESS) {
      MediaViewToggle({
        mode: this.viewMode,
        onChange: (mode: string) => {
          this.viewMode = mode;
        }
      })
    }
  }

  @Builder
  pageContent() {
    Column() {
      SearchBar({
        placeholder: $r('app.string.search_hint'),
        keyword: this.query,
        showClear: true,
        onChange: (value: string) => {
          this.scheduleSearch(value);
        },
        onSearch: () => {
          this.hintItems = [];
          this.runSearch(false);
        },
        onClear: () => {
          this.clearQuery();
        }
      })

      if (this.status === UiState.INITIAL && this.hintItems.length > 0) {
        this.HintList()
      } else if (this.status === UiState.INITIAL) {
        Column() {
          EmptyState({
            message: '搜索你的媒体库',
            detail: '输入片名、演员或剧集名称，回车即可搜索',
            icon: $r('sys.symbol.magnifyingglass')
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
        LoadingState({})
      } else if (this.status === UiState.ERROR) {
        Column() {
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '搜索失败',
            actionLabel: '重试',
            onAction: () => {
              this.runSearch(false);
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.status === UiState.EMPTY) {
        Column() {
          EmptyState({
            message: '没有找到结果',
            detail: '换个关键词，或检查媒体库是否已刮削',
            icon: $r('sys.symbol.magnifyingglass')
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Row() {
          Text(`${this.items.length} 项`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
        }
        .width('100%')
        .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 8 })

        MediaCollectionView({
          items: $items,
          viewMode: this.viewMode,
          loadingMore: this.loadingMore,
          hasMore: this.hasMore,
          onItemTap: (item: MediaItem) => {
            router.pushUrl({ url: 'pages/DetailPage', params: { itemId: item.id } });
          },
          onReachEnd: () => {
            if (!this.footerTriggered) {
              this.footerTriggered = true;
              this.runSearch(true);
            }
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  /** 搜索建议：参考项目的列表行语言（卡片底行 + 0.5vp 分隔 + 按下态） */
  @Builder
  HintList() {
    List() {
      ForEach(this.hintItems, (hint: MediaItem) => {
        ListItem() {
          Row() {
            Text(hint.displayTitle())
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
            Text(hint.typeLabel())
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.colors().textTertiary)
          }
          .width('100%')
          .padding({
            left: ThemeConstants.PAGE_PADDING,
            right: ThemeConstants.PAGE_PADDING,
            top: 12,
            bottom: 12
          })
          .backgroundColor(this.colors().cardBackground)
          .stateStyles({
            pressed: {
              .backgroundColor(this.colors().surfacePressed)
            }
          })
          .onClick(() => {
            this.query = hint.name;
            this.hintItems = [];
            this.runSearch(false);
          })
        }
      }, (hint: MediaItem) => hint.id)
    }
    .width('100%')
    .height(Math.min(260, this.hintItems.length * 48))
    .divider({ strokeWidth: 0.5, color: this.colors().divider })
    .scrollBar(BarState.Off)
  }

  build() {
    Column() {
      PageScaffold({
        title: $r('app.string.search_title'),
        showBack: true,
        action: () => {
          this.topBarAction();
        },
        content: () => {
          this.pageContent();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
