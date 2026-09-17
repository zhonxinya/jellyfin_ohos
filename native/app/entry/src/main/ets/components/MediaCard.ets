import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { JellyfinImage } from './JellyfinImage';

const TITLE_LINE_HEIGHT: number = 18;
const META_LINE_HEIGHT: number = 15;

/**
 * 媒体卡片 —— 按 mybooks_ohos 的卡片语言重做。
 *
 * 栅格卡片（对应参考项目 `BookGridCard` 的"轻卡片"）：
 * - 无卡片底色、无内边距、无投影，封面直接坐在页面底色上；
 * - 封面宽高比 **0.7**（参考项目全站统一），圆角 8vp，并加 0.5vp hairline 描边，
 *   避免浅色封面融进页面底色；
 * - 类型徽标 9fp / Medium / 白字 / `#B3000000` 底 / 圆角 5 / 距顶右各 5vp；
 * - 文案阶梯：标题 13 Medium `text_primary`（行高 18、最多 2 行）、元信息 11 `text_tertiary`（行高 15）。
 * 列表卡片（对应参考项目 `BookListItem`）：卡片底 + 12vp 内边距 + 12vp 圆角，封面 64×92，
 * 标题 16 Medium，次级 13 `text_secondary`，元信息 12 `text_tertiary`，尾部 chevron 用系统符号。
 */
@Component
export struct MediaCard {
  @Prop item: MediaItem = new MediaItem();
  @Prop mode: string = 'grid';
  @Prop cardWidth: number = ThemeConstants.CARD_WIDTH;
  onTap: () => void = () => {};
  /**
   * 长按（弹出条目操作菜单：播放/收藏/标记已看/加入播放列表）。
   *
   * 为什么要有它：媒体库里管理观看状态原来必须"进详情页 → 操作 → 返回"，
   * 这是与主流 Jellyfin 客户端最大的交互差距。默认空实现，老调用点不受影响。
   */
  onLongPress: () => void = () => {};
  /**
   * 是否显示"继续播放"快捷按钮（叠在封面中央）。
   *
   * 只有"继续观看 / 接下来"这类带进度的列表才需要：用户的目标是**接着看**，
   * 而不是先进详情页再点一次播放。默认关闭，其它列表的观感不受影响。
   */
  @Prop quickPlay: boolean = false;
  onQuickPlay: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /** 参考项目统一 0.7 宽高比（宽/高） */
  private posterHeight(): number {
    return Math.floor(this.cardWidth / ThemeConstants.POSTER_RATIO);
  }

  @Builder
  GridMode() {
    Column({ space: 6 }) {
      Stack({ alignContent: Alignment.TopEnd }) {
        JellyfinImage({
          url: this.item.imageUrl(300, 'Primary'),
          imgWidth: this.cardWidth,
          imgHeight: this.posterHeight(),
          cornerRadius: ThemeConstants.COVER_RADIUS
        })
        // 已看标记（左上）与观看进度（底部）都叠在封面内
        Column() {
          Row() {
            if (this.item.isPlayed) {
              SymbolGlyph($r('sys.symbol.checkmark_circle_fill'))
                .fontSize(ThemeConstants.TITLE_MEDIUM)
                .fontColor([this.colors().onOverlay])
            }
            Blank()
          }
          .width('100%')
          .padding({ left: 5, top: 5 })

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

        if (this.item.type.length > 0) {
          Text(this.item.typeLabel())
            .fontSize(ThemeConstants.BADGE_LABEL)
            .fontWeight(FontWeight.Medium)
            .fontColor(Color.White)
            .padding({ left: 5, right: 5, top: 2, bottom: 2 })
            .backgroundColor('#B3000000')
            .borderRadius(5)
            .margin({ top: 5, right: 5 })
        }

        // 快捷继续播放：叠在封面中央的圆形按钮（点它直接起播，点卡片其它区域仍进详情页）。
        // 外层 Stack 用 Center 对齐覆盖整张封面 —— 外层 Stack 的 alignContent 是 TopEnd（给徽标用），
        // 直接放按钮会被摆到右上角。
        if (this.quickPlay) {
          Stack({ alignContent: Alignment.Center }) {
            Button({ type: ButtonType.Circle, stateEffect: true }) {
              SymbolGlyph($r('sys.symbol.play_fill'))
                .fontSize(26)
                .fontColor([this.colors().onBrand])
            }
            .width(56)
            .height(56)
            .backgroundColor(this.colors().brandPrimary)
            .shadow({ radius: 10, color: '#66000000', offsetX: 0, offsetY: 3 })
            .onClick(() => {
              this.onQuickPlay();
            })
          }
          .width('100%')
          .height('100%')
        }
      }
      .width(this.cardWidth)
      .height(this.posterHeight())
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
      this.onTap();
    })
    .gesture(LongPressGesture({ repeat: false, duration: 500 })
      .onAction(() => {
        this.onLongPress();
      }))
  }

  @Builder
  ListMode() {
    Row({ space: 12 }) {
      JellyfinImage({
        url: this.item.imageUrl(128, 'Primary'),
        imgWidth: ThemeConstants.LIST_THUMB_WIDTH,
        imgHeight: ThemeConstants.LIST_THUMB_HEIGHT,
        cornerRadius: ThemeConstants.COVER_RADIUS
      })
      Column({ space: 4 }) {
        Text(this.item.displayTitle())
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        if (this.item.metaLine().length > 0) {
          Text(this.item.metaLine())
            .fontSize(ThemeConstants.META_MEDIUM)
            .fontColor(this.colors().textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .width('100%')
        }
        if (this.item.progress() > 0) {
          Progress({ value: this.item.progress() * 100, total: 100, type: ProgressType.Linear })
            .width('100%')
            .height(4)
            .color(this.colors().brandPrimary)
            .backgroundColor(this.colors().surfacePressed)
            .margin({ top: 6 })
            .borderRadius(2)
        }
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor([this.colors().textTertiary])
    }
    .width('100%')
    .padding(ThemeConstants.CARD_PADDING)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(ThemeConstants.CARD_RADIUS)
    .onClick(() => {
      this.onTap();
    })
    .gesture(LongPressGesture({ repeat: false, duration: 500 })
      .onAction(() => {
        this.onLongPress();
      }))
  }

  build() {
    if (this.mode === 'list') {
      this.ListMode()
    } else {
      this.GridMode()
    }
  }
}
