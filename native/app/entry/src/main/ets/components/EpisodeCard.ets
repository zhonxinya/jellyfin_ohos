import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { JellyfinImage } from './JellyfinImage';

const TITLE_LINE_HEIGHT: number = 18;
const META_LINE_HEIGHT: number = 15;

/**
 * 剧集卡片 —— 详情页「季与集」区横滑列表的单元。
 *
 * 为什么不复用 `MediaCard`：`MediaCard` 的封面是 **2:3 海报**（电影/剧集/合集），
 * 而分集封面是 **16:9 剧照**，塞进海报卡会把剧照两侧裁掉，画面主体（人物、场景）经常被切走。
 * 分集还需要"上次看到哪"的续播进度条与"已看完"标记，这两者在海报卡里也放不下。
 *
 * 规格沿用 `MediaCard` 的语言：封面圆角 `COVER_RADIUS` + 0.5vp hairline 描边（防止浅色剧照
 * 融进页面底色）；已看完 = 右上角 `checkmark_circle_fill`；未看完 = 封面底部品牌色进度条；
 * 文案阶梯：标题 13 Medium `text_primary`（行高 18、最多 2 行）、元信息 11 `text_tertiary`（行高 15）。
 */
@Component
export struct EpisodeCard {
  @Prop item: MediaItem = new MediaItem();
  /** 卡片宽度；剧照高度按 16:9 由宽度推出 */
  @Prop cardWidth: number = 176;
  onTap: (item: MediaItem) => void = (_item: MediaItem) => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /** 16:9 剧照高度 */
  private thumbHeight(): number {
    return Math.floor(this.cardWidth * 9 / 16);
  }

  build() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        JellyfinImage({
          url: this.item.imageUrl(320, 'Primary'),
          imgWidth: this.cardWidth,
          imgHeight: this.thumbHeight(),
          cornerRadius: ThemeConstants.COVER_RADIUS
        })
        // 已看标记（右上）与观看进度（底部）都叠在剧照内
        Column() {
          Row() {
            Blank()
            if (this.item.isPlayed) {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                .fontSize(ThemeConstants.TITLE_MEDIUM)
                .fontColor([this.colors().onOverlay])
            }
          }
          .width('100%')
          .padding({ right: 5, top: 5 })

          Blank()

          if (this.item.progress() > 0) {
            Row() {
              Row()
                .width(`${this.item.progress() * 100}%`)
                .height(3)
                .borderRadius(2)
                .backgroundColor(this.colors().brandPrimary)
            }
            .width('100%')
            .height(3)
            .borderRadius(2)
            .backgroundColor('#33FFFFFF')
            .margin({ left: 4, right: 4, bottom: 4 })
          }
        }
        .width('100%')
        .height('100%')
      }
      .width(this.cardWidth)
      .height(this.thumbHeight())
      .clip(true)
      .borderRadius(ThemeConstants.COVER_RADIUS)
      .border({ width: 0.5, color: this.colors().divider })

      Text(this.item.displayTitle())
        .fontSize(ThemeConstants.META_MEDIUM)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
        .lineHeight(TITLE_LINE_HEIGHT)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (this.item.metaLine().length > 0) {
        Text(this.item.metaLine())
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textTertiary)
          .lineHeight(META_LINE_HEIGHT)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .width(this.cardWidth)
    .alignItems(HorizontalAlign.Start)
    .onClick(() => {
      this.onTap(this.item);
    })
  }
}
