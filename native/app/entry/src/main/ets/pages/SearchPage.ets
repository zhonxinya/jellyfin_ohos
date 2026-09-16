import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { MediaCollectionView, MediaViewToggle } from '../components/MediaCollectionView';
import { AsyncStateView } from '../components/AsyncStateView';

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

  @Builder
  SearchBar() {
    Row({ space: 8 }) {
      SymbolGlyph($r('sys.symbol.magnifyingglass'))
        .fontSize(18)
        .fontColor([this.colors().onSurfaceVariant])
      TextInput({ text: this.query, placeholder: $r('app.string.search_hint') })
        .layoutWeight(1)
        .height(40)
        .backgroundColor(this.colors().surfaceElevated)
        .fontColor(this.colors().onSurface)
        .placeholderColor(this.colors().outline)
        .onChange((value: string) => {
          this.scheduleSearch(value);
        })
        .onSubmit(() => {
          this.hintItems = [];
          this.runSearch(false);
        })
      if (this.query.length > 0) {
        Button('\u2715')
          .width(32)
          .height(32)
          .fontSize(16)
          .backgroundColor(Color.Transparent)
          .fontColor(this.colors().onSurfaceVariant)
          .onClick(() => {
            this.query = '';
            this.hintItems = [];
            this.items = [];
            this.status = UiState.INITIAL;
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
  }

  build() {
    Column() {
      // AppBar 内嵌搜索栏
      Column() {
        Row() {
          Button() {
            SymbolGlyph($r('sys.symbol.chevron_left'))
              .fontSize(24)
              .fontColor([this.colors().onSurface])
          }
            .width(48)
            .height(48)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              router.back();
            })
          Text($r('app.string.search_title'))
            .fontSize(ThemeConstants.TITLE_LARGE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onSurface)
            .layoutWeight(1)
          Button() {
            SymbolGlyph($r('sys.symbol.magnifyingglass'))
              .fontSize(20)
              .fontColor([this.colors().onSurface])
          }
            .width(48)
            .height(48)
            .padding(0)
            .backgroundColor(Color.Transparent)
            .onClick(() => {
              this.hintItems = [];
              this.runSearch(false);
            })
        }
        .width('100%')
        .height(56)
        .padding({ left: 4, right: 8 })

        this.SearchBar()
      }
      .width('100%')
      .backgroundColor(this.colors().background)

      if (this.status === UiState.INITIAL && this.hintItems.length > 0) {
        List() {
          ForEach(this.hintItems, (hint: MediaItem) => {
            ListItem() {
              Row() {
                Text(hint.displayTitle())
                  .fontSize(ThemeConstants.BODY_MEDIUM)
                  .fontColor(this.colors().onSurface)
                  .layoutWeight(1)
                Text(hint.typeLabel())
                  .fontSize(ThemeConstants.LABEL_SMALL)
                  .fontColor(this.colors().onSurfaceVariant)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 10, bottom: 10 })
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
        .scrollBar(BarState.Off)
      } else if (this.status === UiState.INITIAL) {
        Column() {
          SymbolGlyph($r('sys.symbol.magnifyingglass'))
            .fontSize(64)
            .fontColor([this.colors().outline])
          Text($r('app.string.search_prompt'))
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().onSurface)
            .margin({ top: 16 })
          Text($r('app.string.search_hint'))
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontColor(this.colors().onSurfaceVariant)
            .textAlign(TextAlign.Center)
            .margin({ top: 8 })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.status !== UiState.SUCCESS) {
        AsyncStateView({
          status: this.status,
          message: this.errorMsg,
          emptyHint: '没有找到结果',
          minHeight: 200,
          onRetry: () => {
            this.runSearch(false);
          }
        })
      } else {
        Row() {
          Text(`${this.items.length} 项`)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onSurfaceVariant)
            .layoutWeight(1)
          MediaViewToggle({
            mode: this.viewMode,
            onChange: (mode: string) => {
              this.viewMode = mode;
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

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
    .backgroundColor(this.colors().background)
  }
}
