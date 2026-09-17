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
  /**
   * 可选的触达高度覆盖（vp）。0 表示沿用 `ThemeConstants.CHIP_HEIGHT`。
   *
   * 为什么是"可选覆盖"而不是直接改全局 token：34vp 低于 48vp 的触达建议，
   * 但该 token 被多个页面共用，全局改动会牵动所有筛选/标签页布局（无法逐一目视验证）。
   * 播放页这类"单手操作、误触代价高"的场合按需传更大值，风险可控。
   */
  @Prop heightOverride: number = 0;
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
    .height(this.heightOverride > 0 ? this.heightOverride : ThemeConstants.CHIP_HEIGHT)
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
