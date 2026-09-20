import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 播放页工具按钮（图标 + 文字），对齐主流播放器（Infuse/iina）底部"工具行"的形态。
 *
 * 为什么不用通用的 `ChipButton`：
 * - 播放页的控件浮在**视频画面**之上，底色必须是半透明覆盖色（`overlayControl`）而不是
 *   卡片底（`cardBackground`）—— 后者在明亮画面上是一块突兀的白块，在暗画面上又会"糊"成一片；
 * - 播放页需要"图标在上、文字在下"的纵向排布（一眼可辨、又不占横向空间），
 *   `ChipButton` 是纯文字横排。
 *
 * 规格：高度 52vp（≥48vp 触达标准）、圆角 12vp、图标 20vp、文字 11vp；
 * 选中态用品牌色实底（与 `ChipButton` 的选中语义一致，便于用户形成稳定预期）。
 */
@Component
export struct PlayerToolButton {
  @Prop icon: Resource = $r('sys.symbol.circle');
  /** 是否显示图标（纯文字按钮如「软解」传 false） */
  @Prop showIcon: boolean = true;
  @Prop label: string = '';
  @Prop selected: boolean = false;
  /** 无底色变体：用于不希望有底块的位置 */
  @Prop transparent: boolean = false;
  /**
   * 最小宽度（vp）；0 = 不设下限（按内容自适应）。
   *
   * 为什么要它：播放页底部工具行用 `Flex` 换行排布，各按钮按内容自适应宽度 ——
   * 纯文字按钮（如「软解」，无图标）比带图标的窄 40vp 以上，换行后两行长度差距明显
   * （设备实测：第一行 294vp、第二行 220vp），观感参差。
   * 给一个统一下限后，同一行内按钮宽度接近，换行也显得整齐。
   */
  @Prop minWidth: number = 0;
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /**
   * 名字不能叫 `background()`：ArkUI 自定义组件继承自 `CustomComponent`，
   * 而 `background` 是它已有的通用属性方法（同名会被编译器判定为"类型不兼容的重写"，
   * 报 10505001）。同理 `brightness`、`width` 等通用属性名都不能用作成员名。
   */
  private resolvedBackground(): string {
    if (this.selected) {
      return this.colors().brandPrimary;
    }
    return this.transparent ? '#00000000' : this.colors().overlayControl;
  }

  private foreground(): string {
    if (this.selected) {
      return this.colors().onBrand;
    }
    return this.colors().onOverlay;
  }

  private labelColor(): string {
    if (this.selected) {
      return this.colors().onBrand;
    }
    return this.colors().onOverlayMuted;
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Row({ space: 6 }) {
        if (this.showIcon) {
          SymbolGlyph(this.icon)
            .fontSize(ThemeConstants.ICON_LARGE)
            .fontColor([this.foreground()])
        }
        Text(this.label)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.labelColor())
          .maxLines(1)
      }
      .alignItems(VerticalAlign.Center)
    }
    .height(48)
    // 统一高度与最小宽度：让换行后的两行长度接近（见 minWidth 的说明）。
    // `constraintSize` 只在内容比下限窄时才生效，宽按钮不受影响。
    .constraintSize(this.minWidth > 0
      ? { minWidth: this.minWidth, minHeight: 48 }
      : { minHeight: 48 })
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.resolvedBackground())
    .border({
      width: this.transparent ? 0 : 0.5,
      color: this.selected ? this.colors().brandPrimary : this.colors().divider,
      radius: ThemeConstants.CARD_RADIUS
    })
    .stateStyles({
      pressed: {
        .backgroundColor(this.selected
          ? this.colors().brandPrimaryPressed
          : this.colors().surfacePressed)
      }
    })
    .onClick(() => {
      this.onTap();
    });
  }
}
