import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 主按钮 —— 对齐 mybooks_ohos 的 PrimaryButton。
 *
 * 规格：实心 `brand_primary` + `on_brand` 文字；高 48vp；圆角 12vp（不是胶囊）；
 * 字号 16 / Medium；投影 `radius 10 / offsetY 4`（品牌色微光）；
 * 禁用态 `.enabled(false)` + `opacity 0.55`（不换色）；按下态换 `brand_primary_pressed`。
 * 非全宽时给足左右内边距（24vp），否则文字会顶到圆角。
 */
@Component
export struct PrimaryButton {
  @Prop label: string = '';
  @Prop buttonEnabled: boolean = true;
  @Prop fullWidth: boolean = true;
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Button(this.label, { type: ButtonType.Normal, stateEffect: false })
      .height(ThemeConstants.BUTTON_HEIGHT)
      .fontSize(ThemeConstants.TITLE_MEDIUM)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors().onBrand)
      .enabled(this.buttonEnabled)
      .opacity(this.buttonEnabled ? 1 : 0.55)
      .width(this.fullWidth ? '100%' : undefined)
      .padding({ left: this.fullWidth ? 16 : 24, right: this.fullWidth ? 16 : 24 })
      .borderRadius(ThemeConstants.BUTTON_RADIUS)
      .backgroundColor(this.colors().brandPrimary)
      .shadow({
        radius: 10,
        color: this.colors().buttonShadow,
        offsetX: 0,
        offsetY: 4
      })
      .stateStyles({
        pressed: {
          .backgroundColor(this.colors().brandPrimaryPressed)
        }
      })
      .onClick(() => {
        if (this.buttonEnabled) {
          this.onTap();
        }
      });
  }
}
