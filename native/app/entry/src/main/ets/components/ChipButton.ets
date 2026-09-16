import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 可选标签 —— 对齐 mybooks_ohos 的 ChipButton。
 *
 * 规格：高 34vp；圆角 10vp（写在 border 里）；左右各 14vp 内边距；
 * 选中 = 品牌色实底 + `on_brand` 文字 + 微弱品牌投影；未选中 = 卡片底 + `divider` 描边；
 * 按下态：选中 `brand_primary_pressed`，未选中 `chip_background_pressed`。
 * 用于筛选、类型切换、详情页的阅读状态等。
 */
@Component
export struct ChipButton {
  @Prop label: string = '';
  @Prop selected: boolean = false;
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Text(this.label)
        .fontSize(ThemeConstants.META_MEDIUM)
        .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(this.selected ? this.colors().onBrand : this.colors().textPrimary)
        .maxLines(1)
    }
    .height(ThemeConstants.CHIP_HEIGHT)
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.selected ? this.colors().brandPrimary : this.colors().cardBackground)
    .border({
      width: 1,
      color: this.selected ? this.colors().brandPrimary : this.colors().divider,
      radius: ThemeConstants.CHIP_RADIUS
    })
    .shadow(this.selected
      ? { radius: 6, color: '#26007DFF', offsetX: 0, offsetY: 2 }
      : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .stateStyles({
      pressed: {
        .backgroundColor(this.selected
          ? this.colors().brandPrimaryPressed
          : this.colors().chipBackgroundPressed)
      }
    })
    .onClick(() => {
      this.onTap();
    });
  }
}
