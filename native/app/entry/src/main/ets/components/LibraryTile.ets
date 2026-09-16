import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { JellyfinImage } from './JellyfinImage';

/**
 * Home library shelf tile: 120x110 image + title (Flutter home_page library row).
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
      JellyfinImage({
        url: this.item.imageUrl(240, 'Primary'),
        imgWidth: ThemeConstants.LIBRARY_TILE_WIDTH,
        imgHeight: ThemeConstants.LIBRARY_TILE_IMAGE_HEIGHT,
        cornerRadius: ThemeConstants.LIST_THUMB_RADIUS,
        placeholderIcon: 'library'
      })
      Text(this.item.name)
        .fontSize(ThemeConstants.LABEL_SMALL)
        .fontColor(this.colors().onSurface)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(ThemeConstants.LIBRARY_TILE_WIDTH)
    }
    .width(ThemeConstants.LIBRARY_TILE_WIDTH)
    .onClick(() => {
      this.onTap();
    })
  }
}
