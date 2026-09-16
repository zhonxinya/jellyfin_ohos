import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { SectionState } from '../models/SectionState';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';
import { HorizontalShelf } from '../components/HorizontalShelf';
import { EmptyState } from '../components/EmptyState';
import { LoadingState } from '../components/LoadingState';
import { SectionHeader } from '../components/SectionHeader';
import { MediaCollectionView, MediaViewToggle, LibraryShelf } from '../components/MediaCollectionView';
import { HeroBannerLoader } from '../components/HeroBanner';

@Component
export struct HomePage {
  @State private homeTabIndex: number = 0;
  @State private resumeSection: SectionState = SectionState.loading();
  @State private librariesSection: SectionState = SectionState.loading();
  @State private nextUpSection: SectionState = SectionState.loading();
  @State private latestSection: SectionState = SectionState.loading();
  @State private favorites: MediaItem[] = [];
  @State private favoritesViewMode: string = 'grid';
  @State private favoritesStatus: string = UiState.LOADING;
  @State private favoritesError: string = '';
  @State private favStartIndex: number = 0;
  @State private favLoadingMore: boolean = false;
  @State private favHasMore: boolean = true;
  @State private favFooterTriggered: boolean = false;
  @Link themeTick: number;

  aboutToAppear(): void {
    this.loadAllSections();
  }

  private selectHomeTab(index: number): void {
    this.homeTabIndex = index;
    if (index === 1 && this.favoritesStatus === UiState.LOADING && this.favorites.length === 0) {
      this.reloadFavorites(false);
    }
  }

  private colors(): ThemeColors {
    this.themeTick;
    return AppViewModel.getInstance().colors();
  }

  private extractItems(data: ESObject | null): MediaItem[] {
    if (data === null) {
      return [];
    }
    const list: Object[] = JsonUtil.extractItems(data);
    if (list.length > 0) {
      return MediaItem.fromArray(list);
    }
    return MediaItem.fromArray(JsonUtil.getArray(data, 'Items'));
  }

  private async loadSection(section: string, apply: (s: SectionState) => void): Promise<void> {
    apply(SectionState.loading());
    const raw: string = await JellyfinNative.getHomeSection(section, 12);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      apply(SectionState.error(result.message.length > 0 ? result.message : '加载失败'));
      return;
    }
    apply(SectionState.data(this.extractItems(result.data)));
  }

  private loadAllSections(): void {
    this.resumeSection = SectionState.loading();
    this.librariesSection = SectionState.loading();
    this.nextUpSection = SectionState.loading();
    this.latestSection = SectionState.loading();
    this.loadSection('resume', (s: SectionState) => { this.resumeSection = s; });
    this.loadSection('views', (s: SectionState) => { this.librariesSection = s; });
    this.loadSection('nextUp', (s: SectionState) => { this.nextUpSection = s; });
    this.loadSection('latest', (s: SectionState) => { this.latestSection = s; });
  }

  private async reloadFavorites(more: boolean): Promise<void> {
    if (more) {
      if (!this.favHasMore || this.favLoadingMore) {
        return;
      }
      this.favLoadingMore = true;
    } else {
      this.favoritesStatus = UiState.LOADING;
      this.favoritesError = '';
      this.favStartIndex = 0;
      this.favHasMore = true;
      this.favorites = [];
      this.favFooterTriggered = false;
    }
    const query: ItemsQueryOptions = new ItemsQueryOptions();
    query.startIndex = this.favStartIndex;
    query.limit = ThemeConstants.PAGE_SIZE;
    query.favoriteOnly = true;
    query.sortBy = 'SortName';
    query.sortOrder = 'Ascending';
    const raw: string = await JellyfinNative.queryItems(query.toJson());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.favLoadingMore = false;
    this.favFooterTriggered = false;
    if (!result.ok) {
      if (!more) {
        this.favoritesStatus = UiState.ERROR;
        this.favoritesError = result.message.length > 0 ? result.message : '加载失败';
      }
      return;
    }
    const page: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    if (more) {
      this.favorites = this.favorites.concat(page);
    } else {
      this.favorites = page;
    }
    this.favStartIndex = this.favStartIndex + page.length;
    this.favHasMore = page.length >= ThemeConstants.PAGE_SIZE;
    this.favoritesStatus = this.favorites.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private openBrowse(browseType: string, title: string): void {
    router.pushUrl({
      url: 'pages/BrowsePage',
      params: { browseType: browseType, title: title }
    });
  }

  private openItem(item: MediaItem): void {
    if (item.id.length === 0) {
      return;
    }
    if (item.isFolder || item.type === 'CollectionFolder' || item.type === 'UserView') {
      router.pushUrl({
        url: 'pages/LibraryPage',
        params: {
          parentId: item.id,
          title: item.name,
          collectionType: item.collectionType.length > 0 ? item.collectionType : item.type
        }
      });
      return;
    }
    router.pushUrl({ url: 'pages/DetailPage', params: { itemId: item.id } });
  }

  @Builder
  HomeTabContent() {
    Refresh({ refreshing: false }) {
      Scroll() {
        Column() {
          // 首页推荐海报横幅（Jellyfin Web Hero Banner 对齐）
          HeroBannerLoader()
          // 我的媒体（LibraryShelf 横滑卡片）
          if (this.librariesSection.status === UiState.LOADING) {
            SectionHeader({ title: $r('app.string.section_libraries'), icon: '\u{1F4DA}' })
            Column() {
              LoadingState({})
            }
            .width('100%')
            .height(ThemeConstants.SHELF_LIBRARY_HEIGHT)
          } else if (this.librariesSection.status === UiState.ERROR) {
            SectionHeader({ title: $r('app.string.section_libraries'), icon: '\u{1F4DA}' })
            Column() {
              EmptyState({
                message: this.librariesSection.errorMsg,
                actionLabel: '重试',
                onAction: () => {
                  this.loadSection('views', (s: SectionState) => { this.librariesSection = s; });
                }
              })
            }
            .width('100%')
            .height(ThemeConstants.SHELF_LIBRARY_HEIGHT)
            .justifyContent(FlexAlign.Center)
          } else if (this.librariesSection.items.length > 0) {
            LibraryShelf({
              title: $r('app.string.section_libraries'),
              icon: '\u{1F4DA}',
              items: this.librariesSection.items,
              showMore: false,
              onItemTap: (item: MediaItem) => { this.openItem(item); },
              onMore: () => {}
            })
          } else {
            SectionHeader({ title: $r('app.string.section_libraries'), icon: '\u{1F4DA}' })
            Text('').height(12)
          }

          // 继续观看
          if (this.resumeSection.status === UiState.LOADING) {
            SectionHeader({ title: $r('app.string.section_resume'), icon: '\u25B6\uFE0F' })
            Column() {
              LoadingState({})
            }
            .width('100%')
            .height(ThemeConstants.SHELF_MEDIA_HEIGHT)
          } else if (this.resumeSection.status === UiState.ERROR) {
            SectionHeader({ title: $r('app.string.section_resume'), icon: '\u25B6\uFE0F' })
            Column() {
              EmptyState({
                message: this.resumeSection.errorMsg,
                actionLabel: '重试',
                onAction: () => {
                  this.loadSection('resume', (s: SectionState) => { this.resumeSection = s; });
                }
              })
            }
            .width('100%')
            .height(ThemeConstants.SHELF_MEDIA_HEIGHT)
            .justifyContent(FlexAlign.Center)
          } else if (this.resumeSection.items.length > 0) {
            HorizontalShelf({
              title: $r('app.string.section_resume'),
              icon: '\u25B6\uFE0F',
              items: this.resumeSection.items,
              shelfHeight: ThemeConstants.SHELF_MEDIA_HEIGHT,
              cardWidth: ThemeConstants.CARD_WIDTH,
              showMore: true,
              onItemTap: (item: MediaItem) => { this.openItem(item); },
              onMore: () => { this.openBrowse('resume', '继续观看'); }
            })
          } else {
            SectionHeader({ title: $r('app.string.section_resume'), icon: '\u25B6\uFE0F', showMore: true,
              onMore: () => { this.openBrowse('resume', '继续观看'); } })
            Text('').height(12)
          }

          // 接下来
          if (this.nextUpSection.status === UiState.LOADING) {
            SectionHeader({ title: $r('app.string.section_next_up'), icon: '\u{1F4FA}' })
            Column() {
              LoadingState({})
            }
            .width('100%')
            .height(ThemeConstants.SHELF_MEDIA_HEIGHT)
          } else if (this.nextUpSection.status === UiState.ERROR) {
            SectionHeader({ title: $r('app.string.section_next_up'), icon: '\u{1F4FA}' })
            Column() {
              EmptyState({
                message: this.nextUpSection.errorMsg,
                actionLabel: '重试',
                onAction: () => {
                  this.loadSection('nextUp', (s: SectionState) => { this.nextUpSection = s; });
                }
              })
            }
            .width('100%')
            .height(ThemeConstants.SHELF_MEDIA_HEIGHT)
            .justifyContent(FlexAlign.Center)
          } else if (this.nextUpSection.items.length > 0) {
            HorizontalShelf({
              title: $r('app.string.section_next_up'),
              icon: '\u{1F4FA}',
              items: this.nextUpSection.items,
              shelfHeight: ThemeConstants.SHELF_MEDIA_HEIGHT,
              cardWidth: ThemeConstants.CARD_WIDTH,
              showMore: true,
              onItemTap: (item: MediaItem) => { this.openItem(item); },
              onMore: () => { this.openBrowse('nextUp', '接下来'); }
            })
          } else {
            SectionHeader({ title: $r('app.string.section_next_up'), icon: '\u{1F4FA}', showMore: true,
              onMore: () => { this.openBrowse('nextUp', '接下来'); } })
            Text('').height(12)
          }

          // 最新添加
          if (this.latestSection.status === UiState.LOADING) {
            SectionHeader({ title: $r('app.string.section_latest'), icon: '\u{1F195}' })
            Column() {
              LoadingState({})
            }
            .width('100%')
            .height(ThemeConstants.SHELF_MEDIA_HEIGHT)
          } else if (this.latestSection.status === UiState.ERROR) {
            SectionHeader({ title: $r('app.string.section_latest'), icon: '\u{1F195}' })
            Column() {
              EmptyState({
                message: this.latestSection.errorMsg,
                actionLabel: '重试',
                onAction: () => {
                  this.loadSection('latest', (s: SectionState) => { this.latestSection = s; });
                }
              })
            }
            .width('100%')
            .height(ThemeConstants.SHELF_MEDIA_HEIGHT)
            .justifyContent(FlexAlign.Center)
          } else if (this.latestSection.items.length > 0) {
            HorizontalShelf({
              title: $r('app.string.section_latest'),
              icon: '\u{1F195}',
              items: this.latestSection.items,
              shelfHeight: ThemeConstants.SHELF_MEDIA_HEIGHT,
              cardWidth: ThemeConstants.CARD_WIDTH,
              showMore: true,
              onItemTap: (item: MediaItem) => { this.openItem(item); },
              onMore: () => { this.openBrowse('latest', '最新添加'); }
            })
          } else {
            SectionHeader({ title: $r('app.string.section_latest'), icon: '\u{1F195}', showMore: true,
              onMore: () => { this.openBrowse('latest', '最新添加'); } })
            Text('').height(12)
          }
        }
        .width('100%')
        .padding({ bottom: 24 })
      }
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .onRefreshing(() => {
      this.loadAllSections();
    })
    .layoutWeight(1)
    .width('100%')
  }

  @Builder
  HomeTabItem(label: ResourceStr, index: number) {
    Column() {
      Text(label)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.homeTabIndex === index ? this.colors().primary : this.colors().onSurfaceVariant)
      Row()
        .width(index === 0 ? 28 : 56)
        .height(3)
        .backgroundColor(this.homeTabIndex === index ? this.colors().primary : Color.Transparent)
        .borderRadius(2)
        .margin({ top: 8 })
    }
    .layoutWeight(1)
    .height(46)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .onClick(() => {
      this.selectHomeTab(index);
    })
  }

  @Builder
  FavoritesTabContent() {
    Column() {
      if (this.favoritesStatus === UiState.LOADING) {
        LoadingState({})
      } else if (this.favoritesStatus === UiState.ERROR) {
        Column() {
          EmptyState({
            message: this.favoritesError.length > 0 ? this.favoritesError : '加载失败',
            actionLabel: '重试',
            onAction: () => {
              this.reloadFavorites(false);
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.favoritesStatus === UiState.EMPTY) {
        Column() {
          EmptyState({
            message: '暂无收藏',
            detail: '在媒体详情页点击收藏按钮，即可在这里查看',
            icon: $r('sys.symbol.star')
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Row() {
          Text(`${this.favorites.length} 项`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .layoutWeight(1)
          MediaViewToggle({
            mode: this.favoritesViewMode,
            onChange: (mode: string) => {
              this.favoritesViewMode = mode;
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 8, top: 4 })

        MediaCollectionView({
          items: $favorites,
          viewMode: this.favoritesViewMode,
          loadingMore: this.favLoadingMore,
          hasMore: this.favHasMore,
          onItemTap: (item: MediaItem) => {
            this.openItem(item);
          },
          onReachEnd: () => {
            if (!this.favFooterTriggered) {
              this.favFooterTriggered = true;
              this.reloadFavorites(true);
            }
          }
        })
      }
    }
    .layoutWeight(1)
    .width('100%')
  }

  build() {
    Column() {
      // Jellyfin Web 风格的首页内容标签栏；全局应用栏由 MainShell 提供
      Row({ space: 0 }) {
        this.HomeTabItem($r('app.string.tab_home'), 0)
        this.HomeTabItem($r('app.string.tab_favorites'), 1)
      }
      .width('100%')
      .height(46)
      .backgroundColor(this.colors().surface)
      .border({ width: { bottom: 1 }, color: this.colors().outline })

      if (this.homeTabIndex === 0) {
        this.HomeTabContent()
      } else {
        this.FavoritesTabContent()
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().background)
  }
}
