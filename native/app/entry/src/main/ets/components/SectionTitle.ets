import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 区块标题 —— 对齐 mybooks_ohos 的 SectionTitle。
 *
 * 规格：左侧 4×16vp 品牌色竖条（圆角 2）+ 17fp / Medium 标题 + 可选右侧动作文字（13fp 品牌色）；
 * 容器左右各 16vp，上 12vp 下 8vp——这是参考项目的"区块节奏"。
 *
 * 与参考项目的差异：本工程还有一套"图标 + 标题"的 shelf 头（`SectionHeader`），
 * 迁移时优先用本组件（参考项目统一用竖条 + 文字，不用 emoji 图标）。
 */
@Component
export struct SectionTitle {
  @Prop title: string = '';
  @Prop actionLabel: string = '';
  onAction: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Row({ space: 8 }) {
      Column()
        .width(4)
        .height(16)
        .borderRadius(2)
        .backgroundColor(this.colors().brandPrimary)
      Text(this.title)
        .fontSize(17)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.actionLabel.length > 0) {
        Text(this.actionLabel)
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().brandPrimary)
          .onClick(() => {
            this.onAction();
          })
      }
    }
    .width('100%')
    .padding({
      left: ThemeConstants.PAGE_PADDING,
      right: ThemeConstants.PAGE_PADDING,
      top: 12,
      bottom: 8
    })
    .alignItems(VerticalAlign.Center)
  }
}
