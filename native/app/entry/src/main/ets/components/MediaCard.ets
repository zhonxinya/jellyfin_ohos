import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { JellyfinImage } from './JellyfinImage';

@Component
export struct MediaCard {
  @Prop item: MediaItem = new MediaItem();
  @Prop mode: string = 'grid';
  @Prop cardWidth: number = ThemeConstants.CARD_WIDTH;
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private posterHeight(): number {
    return Math.floor(this.cardWidth * 1.5);
  }

  @Builder
  GridMode() {
    Column({ space: 2 }) {
      Stack({ alignContent: Alignment.TopStart }) {
        JellyfinImage({
          url: this.item.imageUrl(300, 'Primary'),
          imgWidth: this.cardWidth,
          imgHeight: this.posterHeight(),
          cornerRadius: ThemeConstants.POSTER_RADIUS
        })
        Column() {
          Row() {
            if (this.item.type.length > 0) {
              Text(this.item.typeLabel())
                .fontSize(10)
                .fontColor(this.colors().onOverlay)
                .padding({ left: 6, right: 6, top: 2, bottom: 2 })
                .backgroundColor(this.colors().posterScrim)
                .borderRadius(6)
                .margin({ left: 6, top: 6 })
            }
            Blank()
            if (this.item.isPlayed) {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                .fontSize(18)
                .fontColor([this.colors().onOverlay])
                .margin({ right: 7, top: 7 })
            }
          }
          .width('100%')
          Blank()
          Column()
            .width('100%')
            .height(48)
            .linearGradient({
              angle: 180,
              colors: [['#00000000', 0.0], ['#00000000', 0.6], [this.colors().posterScrim, 1.0]]
            })
          if (this.item.progress() > 0) {
            Progress({ value: this.item.progress() * 100, total: 100, type: ProgressType.Linear })
              .width('100%')
              .height(3)
              .color(this.colors().primary)
              .backgroundColor(this.colors().posterScrim)
          }
        }
        .width('100%')
        .height('100%')
      }
      .width(this.cardWidth)
      .height(this.posterHeight())
      .clip(true)
      .borderRadius(ThemeConstants.POSTER_RADIUS)

      Text(this.item.displayTitle())
        .fontSize(ThemeConstants.TITLE_SMALL)
        .fontColor(this.colors().onSurface)
        .margin({ top: 6 })
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width(this.cardWidth)

      if (this.item.metaLine().length > 0) {
        Text(this.item.metaLine())
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().onSurfaceVariant)
          .margin({ top: 2 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width(this.cardWidth)
      }
    }
    .width(this.cardWidth)
    .onClick(() => {
      this.onTap();
    })
  }

  @Builder
  ListMode() {
    Row({ space: 12 }) {
      JellyfinImage({
        url: this.item.imageUrl(128, 'Primary'),
        imgWidth: 64,
        imgHeight: 96,
        cornerRadius: ThemeConstants.LIST_THUMB_RADIUS
      })
      Column({ space: 4 }) {
        Text(this.item.displayTitle())
          .fontSize(ThemeConstants.TITLE_SMALL)
          .fontColor(this.colors().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.item.metaLine().length > 0) {
          Text(this.item.metaLine())
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onSurfaceVariant)
        }
        if (this.item.progress() > 0) {
          Progress({ value: this.item.progress() * 100, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(4)
            .color(this.colors().primary)
            .backgroundColor(this.colors().surfaceContainerHighest)
            .margin({ top: 8 })
            .borderRadius(2)
        } else {
          Blank()
            .height(4)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      Text('\u203A')
        .fontSize(22)
        .fontColor(this.colors().onSurfaceVariant)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(() => {
      this.onTap();
    })
  }

  build() {
    if (this.mode === 'list') {
      this.ListMode()
    } else {
      this.GridMode()
    }
  }
}
