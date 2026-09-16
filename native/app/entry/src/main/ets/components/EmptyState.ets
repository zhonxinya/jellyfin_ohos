import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { PrimaryButton } from './PrimaryButton';

/**
 * 空态 —— 对齐 mybooks_ohos 的 EmptyState。
 *
 * 参考项目的关键约定：**错误态复用空态**（`message` 传错误文案 + `actionLabel: '重试'`），
 * 不再单独造一个错误组件；容器不加 `layoutWeight(1)`，需要垂直居中时由父级加权容器负责。
 *
 * 与参考项目的差异：图标可配置，默认用 `sys.symbol.film`（参考项目硬编码 `sys.symbol.book`）。
 */
@Component
export struct EmptyState {
  @Prop message: string = '';
  @Prop detail: string = '';
  @Prop actionLabel: string = '';
  @Prop icon: Resource = $r('sys.symbol.film');
  onAction: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Column({ space: 12 }) {
      SymbolGlyph(this.icon)
        .fontSize(ThemeConstants.EMPTY_ICON_SIZE)
        .fontColor([this.colors().textTertiary])
      Text(this.message)
        .fontSize(ThemeConstants.STATE_TITLE)
        .fontColor(this.colors().textPrimary)
        .textAlign(TextAlign.Center)
      if (this.detail.length > 0) {
        Text(this.detail)
          .fontSize(ThemeConstants.STATE_DETAIL)
          .fontColor(this.colors().textSecondary)
          .textAlign(TextAlign.Center)
      }
      if (this.actionLabel.length > 0) {
        PrimaryButton({
          label: this.actionLabel,
          fullWidth: false,
          onTap: () => {
            this.onAction();
          }
        })
      }
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
