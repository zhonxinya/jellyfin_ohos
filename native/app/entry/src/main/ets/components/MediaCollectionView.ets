import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaCard } from './MediaCard';
import { LibraryTile } from './LibraryTile';
import { SectionHeader } from './SectionHeader';
import { WindowLayout } from '../common/WindowLayout';

@Component
export struct MediaViewToggle {
  @Prop mode: string = 'grid';
  onChange: (mode: string) => void = (_mode: string) => {};

  @Builder
  ToggleButton(icon: Resource, value: string) {
    Button() {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.mode === value ? this.colors().primary : this.colors().onSurfaceVariant])
    }
      .width(40)
      .height(40)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.onChange(value);
      })
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Row({ space: 4 }) {
      this.ToggleButton($r('sys.symbol.square_grid_2x2'), 'grid')
      this.ToggleButton($r('sys.symbol.list_bullet'), 'list')
    }
    .height(40)
  }
}

@Component
export struct MediaCollectionView {
  @Link items: MediaItem[];
  @Prop viewMode: string = 'grid';
  @Prop loadingMore: boolean = false;
  @Prop hasMore: boolean = true;
  @Prop columns: number = 0;
  onItemTap: (item: MediaItem) => void = (_item: MediaItem) => {};
  onReachEnd: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private resolvedColumns(): number {
    if (this.columns > 0) {
      return this.columns;
    }
    return WindowLayout.gridColumns();
  }

  private cardWidthForColumns(): number {
    return WindowLayout.cardWidth(this.resolvedColumns());
  }

  /** 海报 0.7 宽高比 + 文案块高度（标题 2 行 + 间隙 + 元信息） */
  private gridItemHeight(): number {
    return Math.floor(this.cardWidthForColumns() / ThemeConstants.POSTER_RATIO) + 60;
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
  GridLoadingFooter() {
    GridItem() {
      if (this.loadingMore) {
        Row() {
          LoadingProgress().width(24).height(24).color(this.colors().primary)
        }
        .width('100%')
        .height(48)
        .justifyContent(FlexAlign.Center)
      } else {
        Text('')
          .height(1)
          .onAppear(() => {
            this.onReachEnd();
          })
      }
    }
    .columnStart(0)
    .columnEnd(this.resolvedColumns() - 1)
  }

  build() {
    Column() {
      if (this.viewMode === 'list') {
        List({ space: ThemeConstants.LIST_SPACE }) {
          ForEach(this.items, (item: MediaItem) => {
            ListItem() {
              MediaCard({
                item: item,
                mode: 'list',
                onTap: () => {
                  this.onItemTap(item);
                }
              })
            }
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })
          }, (item: MediaItem) => item.id)
          if (this.hasMore) {
            ListItem() {
              if (this.loadingMore) {
                Row() {
                  LoadingProgress().width(24).height(24).color(this.colors().primary)
                }
                .width('100%')
                .height(48)
                .justifyContent(FlexAlign.Center)
              } else {
                Text('')
                  .height(1)
                  .onAppear(() => {
                    this.onReachEnd();
                  })
              }
            }
          }
        }
        .layoutWeight(1)
        .width('100%')
        .cachedCount(8)
        .scrollBar(BarState.Auto)
      } else {
        Scroll() {
          Grid() {
            ForEach(this.items, (item: MediaItem) => {
              GridItem() {
                MediaCard({
                  item: item,
                  mode: 'grid',
                  cardWidth: this.cardWidthForColumns(),
                  onTap: () => {
                    this.onItemTap(item);
                  }
                })
              }.height(this.gridItemHeight())
            }, (item: MediaItem) => item.id)
            if (this.hasMore) {
              this.GridLoadingFooter()
            }
          }
          .columnsTemplate(this.columnsTemplate())
          .columnsGap(ThemeConstants.GRID_COLUMN_GAP)
          .rowsGap(ThemeConstants.GRID_ROW_GAP)
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: ThemeConstants.PAGE_PADDING })
          .cachedCount(12)
          .width('100%')
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
        .onScrollEdge((side: Edge) => {
          if (side === Edge.Bottom) {
            this.onReachEnd();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}

@Component
export struct LibraryShelf {
  @Prop title: ResourceStr = '';
  @Prop icon: string = '';
  @Prop items: MediaItem[] = [];
  @Prop showMore: boolean = false;
  onItemTap: (item: MediaItem) => void = (_item: MediaItem) => {};
  onMore: () => void = () => {};

  build() {
    if (this.items.length > 0) {
      Column() {
        SectionHeader({
          title: this.title,
          icon: this.icon,
          showMore: this.showMore,
          onMore: () => {
            this.onMore();
          }
        })
        List({ space: ThemeConstants.CARD_GAP }) {
          ForEach(this.items, (item: MediaItem) => {
            ListItem() {
              LibraryTile({
                item: item,
                onTap: () => {
                  this.onItemTap(item);
                }
              })
            }
          }, (item: MediaItem) => item.id)
        }
        .listDirection(Axis.Horizontal)
        .scrollBar(BarState.Off)
        .height(ThemeConstants.SHELF_LIBRARY_HEIGHT)
        .padding({ left: 16, right: 16 })
        .width('100%')
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}
