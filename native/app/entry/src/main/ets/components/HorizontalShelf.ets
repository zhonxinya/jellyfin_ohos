import { ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { MediaCard } from './MediaCard';
import { SectionHeader } from './SectionHeader';

@Component
export struct HorizontalShelf {
  @Prop title: ResourceStr = '';
  @Prop icon: string = '';
  @Prop items: MediaItem[] = [];
  @Prop shelfHeight: number = ThemeConstants.SHELF_MEDIA_HEIGHT;
  @Prop cardWidth: number = ThemeConstants.CARD_WIDTH;
  @Prop showMore: boolean = false;
  onItemTap: (item: MediaItem) => void = (_item: MediaItem) => {};
  /** 长按条目（弹出操作菜单）；默认空实现 */
  onItemLongPress: (item: MediaItem) => void = (_item: MediaItem) => {};
  onMore: () => void = () => {};

  build() {
    if (this.items.length > 0 || this.showMore) {
      Column() {
        SectionHeader({
          title: this.title,
          icon: this.icon,
          showMore: this.showMore && this.items.length > 0,
          onMore: () => {
            this.onMore();
          }
        })
        if (this.items.length > 0) {
          List({ space: ThemeConstants.CARD_GAP }) {
            ForEach(this.items, (item: MediaItem) => {
              ListItem() {
                MediaCard({
                  item: item,
                  mode: 'grid',
                  cardWidth: this.cardWidth,
                  onTap: () => {
                    this.onItemTap(item);
                  },
                  onLongPress: () => {
                    this.onItemLongPress(item);
                  }
                })
              }
            }, (item: MediaItem) => `${item.id}_${item.isPlayed ? 1 : 0}_${item.isFavorite ? 1 : 0}`)
          }
          .listDirection(Axis.Horizontal)
          .scrollBar(BarState.Off)
          .height(this.shelfHeight)
          .padding({ left: 16, right: 16 })
          .width('100%')
        }
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
  }
}
