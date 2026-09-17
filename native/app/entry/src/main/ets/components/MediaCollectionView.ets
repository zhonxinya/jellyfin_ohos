import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaCard } from './MediaCard';
import { LibraryTile } from './LibraryTile';
import { SectionHeader } from './SectionHeader';
import { WindowLayout } from '../common/WindowLayout';
import { AppIconButton } from './AppIconButton';

@Component
export struct MediaViewToggle {
  @Prop mode: string = 'grid';
  onChange: (mode: string) => void = (_mode: string) => {};

  /**
   * 单个图标按钮切换网格/列表 —— 对齐参考项目 `BookViewToggleButton`：
   * 图标表示"点击后切到的模式"（网格模式显示列表图标，反之亦然），40vp ghost 圆形按钮。
   */

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    AppIconButton({
      icon: this.mode === 'list' ? $r('sys.symbol.square_grid_2x2') : $r('sys.symbol.list_bullet'),
      variant: 'ghost',
      iconSize: 20,
      onTap: () => {
        this.onChange(this.mode === 'list' ? 'grid' : 'list');
      }
    })
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
  /** 长按条目（弹出操作菜单）；默认空实现，未接线的页面行为不变 */
  onItemLongPress: (item: MediaItem) => void = (_item: MediaItem) => {};
  /**
   * 是否在封面中央显示"继续播放"快捷按钮（继续观看/接下来这类带进度的列表用）。
   * 打开后必须处理 `onQuickPlay`，否则按钮点了没反应。
   */
  @Prop quickPlay: boolean = false;
  onQuickPlay: (item: MediaItem) => void = (_item: MediaItem) => {};
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
          LoadingProgress().width(24).height(24).color(this.colors().brandPrimary)
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
                },
                onLongPress: () => {
                  this.onItemLongPress(item);
                }
              })
            }
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })
            // key 里带上观看状态与收藏状态：ArkUI 对 key 未变的项不重建，
            // 长按菜单里改了状态后卡片（已看角标/进度条）不会刷新（设备实测过的同类缺陷）
          }, (item: MediaItem) => `${item.id}_${item.isPlayed ? 1 : 0}_${item.isFavorite ? 1 : 0}`)
          if (this.hasMore) {
            ListItem() {
              if (this.loadingMore) {
                Row() {
                  LoadingProgress().width(24).height(24).color(this.colors().brandPrimary)
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
                  },
                  onLongPress: () => {
                    this.onItemLongPress(item);
                  },
                  quickPlay: this.quickPlay,
                  onQuickPlay: () => {
                    this.onQuickPlay(item);
                  }
                })
              }.height(this.gridItemHeight())
              // 同上：key 带状态，长按菜单改状态后卡片能立刻刷新
            }, (item: MediaItem) => `${item.id}_${item.isPlayed ? 1 : 0}_${item.isFavorite ? 1 : 0}`)
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
