import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { JellyfinImage } from './JellyfinImage';

/**
 * 媒体库瓦片 —— 文案与描边对齐 mybooks_ohos 的封面瓦片规格。
 *
 * - 库封面保持 Jellyfin 的横版比例（120×110），但圆角用 `cover_radius`(8vp)、
 *   并加 0.5vp hairline 描边（参考项目"轻卡片"约定：浅色封面靠细描边站住）；
 * - 标题 13fp / Medium / `text_primary` / 行高 18 / 最多 2 行（原 12fp、1 行）。
 */
@Component
export struct LibraryTile {
  @Prop item: MediaItem = new MediaItem();
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Column({ space: 6 }) {
      Stack() {
        JellyfinImage({
          url: this.item.imageUrl(240, 'Primary'),
          imgWidth: ThemeConstants.LIBRARY_TILE_WIDTH,
          imgHeight: ThemeConstants.LIBRARY_TILE_IMAGE_HEIGHT,
          cornerRadius: ThemeConstants.COVER_RADIUS,
          placeholderIcon: 'library'
        })
      }
      .width(ThemeConstants.LIBRARY_TILE_WIDTH)
      .height(ThemeConstants.LIBRARY_TILE_IMAGE_HEIGHT)
      .borderRadius(ThemeConstants.COVER_RADIUS)
      .border({ width: 0.5, color: this.colors().divider })
      Text(this.item.name)
        .fontSize(ThemeConstants.META_MEDIUM)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
        .lineHeight(18)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(ThemeConstants.LIBRARY_TILE_WIDTH)
        .textAlign(TextAlign.Start)
    }
    .width(ThemeConstants.LIBRARY_TILE_WIDTH)
    .onClick(() => {
      this.onTap();
    })
  }
}
