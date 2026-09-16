import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 卡片分组 —— 抽取参考项目里重复了 10 次以上的"设置分组"容器。
 *
 * 参考项目的做法：一组行装进一张卡片（`card_background` + 12vp 圆角 + 裁剪），
 * 行之间用 0.5vp `divider` 分隔，卡片本身不带阴影（因为它贴在页面底色上，
 * 参考项目的规则是"浮动卡片给阴影，页内卡片不给"）。
 * 可选的头部是"图标 + 标题"区块头，对应参考项目 4 处重复的 `CardHead / SectionHead`。
 */
@Component
export struct SectionCard {
  /** 卡片头部标题，空则只渲染内容 */
  @Prop title: string = '';
  @Prop icon: Resource = $r('sys.symbol.rectangle_stack');
  @Prop showHeaderIcon: boolean = false;
  /** 是否在卡片之间留出外边距（页面内多卡片时用） */
  @Prop withMargin: boolean = true;
  @BuilderParam content: () => void = this.defaultContent;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  @Builder
  defaultContent(): void {
  }

  @LocalBuilder
  contentWrapper(): void {
    this.content();
  }

  build() {
    Column() {
      if (this.title.length > 0) {
        Row({ space: 8 }) {
          if (this.showHeaderIcon) {
            SymbolGlyph(this.icon)
              .fontSize(18)
              .fontColor([this.colors().brandPrimary])
          }
          Text(this.title)
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)
            .layoutWeight(1)
        }
        .width('100%')
        .padding({
          left: ThemeConstants.PAGE_PADDING,
          right: ThemeConstants.PAGE_PADDING,
          top: 14,
          bottom: 10
        })
        .alignItems(VerticalAlign.Center)
      }

      Column() {
        this.contentWrapper();
      }
      .width('100%')
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(ThemeConstants.CARD_RADIUS)
    .clip(true)
    .margin(this.withMargin
      ? { left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: ThemeConstants.CARD_STACK_SPACE }
      : { bottom: 0 })
  }
}
