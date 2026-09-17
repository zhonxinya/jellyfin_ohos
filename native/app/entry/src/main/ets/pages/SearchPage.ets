import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { MediaItemMenu } from '../common/MediaItemMenu';
import { SessionStore } from '../services/SessionStore';
import { MediaCollectionView, MediaViewToggle } from '../components/MediaCollectionView';
import { PageScaffold } from '../components/PageScaffold';
import { SearchBar } from '../components/SearchBar';
import { ChipButton } from '../components/ChipButton';
import { EmptyState } from '../components/EmptyState';
import { LoadingState } from '../components/LoadingState';
import { TextButton } from '../components/TextButton';

/** 搜索历史条数上限（落盘在 preferences 里） */
const kHistoryMax: number = 12;

/** 类型筛选：标签 → `IncludeItemTypes`（空串=不限） */
const kTypeFilters: string[] = ['全部', '电影', '剧集', '单集', '音乐', '合集'];
const kTypeValues: string[] = ['', 'Movie', 'Series', 'Episode', 'Audio,MusicAlbum', 'BoxSet'];

/**
 * 搜索页。
 *
 * 本轮补齐三件"媒体库该有的搜索"：
 * 1. **库内搜索**：从媒体库页进入时带 `parentId`，只搜该库（顶栏会显示搜索范围）；
 * 2. **类型筛选**：全部/电影/剧集/单集/音乐/合集，对应 `IncludeItemTypes`；
 * 3. **搜索历史**：命中过的关键词持久化在本地偏好里，空态可直接点历史词再搜。
 *
 * 另外两处修正：点搜索建议**直达该条目**（原来是把建议名当关键词再搜一遍）；
 * `aboutToDisappear` 里清掉防抖定时器（原来离开页面后仍可能触发一次搜索）。
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
  @State private typeIndex: number = 0;
  @State private history: string[] = [];
  /** 搜索范围（媒体库）：为空表示全服务器 */
  private parentId: string = '';
  @State private scopeTitle: string = '';
  @State private totalCount: number = -1;
  private debounceId: number = -1;
  private readonly pageSize: number = ThemeConstants.PAGE_SIZE;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const pid: Object | undefined = params['parentId'];
      if (typeof pid === 'string') {
        this.parentId = pid;
      }
      const scope: Object | undefined = params['scopeTitle'];
      if (typeof scope === 'string') {
        this.scopeTitle = scope;
      }
    }
    this.loadHistory();
  }

  aboutToDisappear(): void {
    // 离开页面时清掉防抖定时器：否则返回上一页后仍可能触发一次搜索与状态更新
    if (this.debounceId >= 0) {
      clearTimeout(this.debounceId);
      this.debounceId = -1;
    }
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private currentTypes(): string {
    if (this.typeIndex < 0 || this.typeIndex >= kTypeValues.length) {
      return '';
    }
    return kTypeValues[this.typeIndex];
  }

  /** 读取本地搜索历史（走真正落盘的 preferences，重启后仍在） */
  private async loadHistory(): Promise<void> {
    const raw: string = await SessionStore.loadSearchHistory();
    if (raw.length === 0) {
      this.history = [];
      return;
    }
    try {
      const arr: Object[] = JSON.parse(raw) as Object[];
      const out: string[] = [];
      for (let i = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string' && (arr[i] as string).length > 0) {
          out.push(arr[i] as string);
        }
      }
      this.history = out;
    } catch (err) {
      this.history = [];
    }
  }

  /** 记录一次搜索（去重、最近在前、有上限） */
  private rememberQuery(term: string): void {
    const text: string = term.trim();
    if (text.length === 0) {
      return;
    }
    const next: string[] = [text];
    for (let i = 0; i < this.history.length && next.length < kHistoryMax; i++) {
      if (this.history[i] !== text) {
        next.push(this.history[i]);
      }
    }
    this.history = next;
    SessionStore.saveSearchHistory(JSON.stringify(next));
  }

  private clearHistory(): void {
    this.history = [];
    SessionStore.saveSearchHistory('[]');
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
    this.totalCount = -1;
    this.status = UiState.INITIAL;
  }

  private async loadHints(): Promise<void> {
    // 建议也跟随搜索范围/类型筛选：否则会出现"库里搜不到、建议里却有"的不一致
    const raw: string = await JellyfinNative.searchHints(this.query.trim(), 6, this.parentId,
      this.currentTypes());
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
      this.totalCount = -1;
      this.rememberQuery(q);
    }
    const raw: string = await JellyfinNative.search(q, this.startIndex, this.pageSize, this.parentId,
      this.currentTypes());
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
    try {
      const page: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
      if (more) {
        this.items = this.items.concat(page);
      } else {
        this.items = page;
      }
      this.startIndex = this.startIndex + page.length;
      // 总数用服务端 TotalRecordCount（与媒体库页一致），hasMore 据此判断
      this.totalCount = JsonUtil.getNumber(result.data as ESObject, 'TotalRecordCount', -1);
      this.hasMore = this.totalCount >= 0
        ? this.items.length < this.totalCount
        : page.length >= this.pageSize;
      this.status = this.items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
    } catch (err) {
      // 解析异常也要落到终态，否则页面永远停在"加载中"
      if (!more) {
        this.status = UiState.ERROR;
        this.errorMsg = `搜索失败：${(err as Error).message}`;
      }
    }
  }

  /** 简单搜索时：换类型筛选需要重查（结果集变了） */
  private onTypeTap(index: number): void {
    if (this.typeIndex === index) {
      return;
    }
    this.typeIndex = index;
    if (this.query.trim().length > 0 && this.status !== UiState.INITIAL) {
      this.runSearch(false);
    }
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

  /** 搜索范围 + 类型筛选 */
  @Builder
  FilterRow() {
    Column({ space: 6 }) {
      if (this.scopeTitle.length > 0) {
        Row({ space: 8 }) {
          Text(`在「${this.scopeTitle}」中搜索`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().brandPrimary)
            .layoutWeight(1)
          TextButton({
            label: '全库搜索',
            onTap: () => {
              this.parentId = '';
              this.scopeTitle = '';
              this.hintItems = [];
              if (this.query.trim().length > 0 && this.status !== UiState.INITIAL) {
                this.runSearch(false);
              }
            }
          })
        }
        .width('100%')
        .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })
      }
      Scroll() {
        Row({ space: 8 }) {
          ForEach(kTypeFilters, (label: string, index: number) => {
            ChipButton({
              label: label,
              selected: this.typeIndex === index,
              onTap: () => {
                this.onTypeTap(index);
              }
            })
          }, (label: string, index: number) => `${label}_${this.typeIndex === index ? 1 : 0}`)
          Blank()
            .layoutWeight(1)
        }
        .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })
      }
      .scrollable(ScrollDirection.Horizontal)
      .scrollBar(BarState.Off)
      .width('100%')
    }
    .width('100%')
    .padding({ top: 8, bottom: 6 })
  }

  /** 搜索历史（空态展示，点一下再搜） */
  @Builder
  HistoryBlock() {
    if (this.history.length > 0) {
      Column({ space: 6 }) {
        Row() {
          Text('搜索历史')
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().textTertiary)
            .layoutWeight(1)
          TextButton({
            label: '清空',
            onTap: () => {
              this.clearHistory();
            }
          })
        }
        .width('100%')

        Flex({ wrap: FlexWrap.Wrap }) {
          ForEach(this.history, (term: string) => {
            Row() {
              Text(term)
                .fontSize(ThemeConstants.META_MEDIUM)
                .fontColor(this.colors().textPrimary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .padding({ left: 12, right: 12, top: 8, bottom: 8 })
            .margin({ right: 8, bottom: 8 })
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(ThemeConstants.CHIP_RADIUS)
            .stateStyles({
              pressed: {
                .backgroundColor(this.colors().chipBackgroundPressed)
              }
            })
            .onClick(() => {
              this.query = term;
              this.hintItems = [];
              this.runSearch(false);
            })
          }, (term: string) => term)
        }
        .width('100%')
      }
      .width('100%')
      .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 4 })
      .alignItems(HorizontalAlign.Start)
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

      this.FilterRow()

      if (this.status === UiState.INITIAL && this.hintItems.length > 0) {
        this.HintList()
      } else if (this.status === UiState.INITIAL) {
        Column() {
          EmptyState({
            message: '搜索你的媒体库',
            detail: '输入片名、演员或剧集名称，回车即可搜索',
            icon: $r('sys.symbol.magnifyingglass')
          })
          this.HistoryBlock()
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
            detail: '换个关键词、放宽类型筛选，或检查媒体库是否已刮削',
            icon: $r('sys.symbol.magnifyingglass')
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Row() {
          Text(this.totalCount >= 0 ? `共 ${this.totalCount} 项` : `${this.items.length} 项`)
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
          onItemLongPress: (item: MediaItem) => {
            MediaItemMenu.show(this.getUIContext(), item, () => {
              this.items = MediaItemMenu.touch(this.items);
            });
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
            // 直达条目：原实现把建议名当关键词再搜一次，用户得多点一步才能进详情
            this.rememberQuery(hint.name);
            router.pushUrl({ url: 'pages/DetailPage', params: { itemId: hint.id } });
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
        title: this.scopeTitle.length > 0 ? `搜索 · ${this.scopeTitle}`
                                          : $r('app.string.search_title'),
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
