import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 次级按钮 —— 对齐 mybooks_ohos 的 SecondaryButton。
 *
 * 规格：浅底 `brand_primary_light` + 品牌色文字；1vp 边框（圆角写在 border 里，
 * 否则 `.border()` 会把 `borderRadius` 重置为直角）；无投影；高 48vp（`compact` 时 40vp）。
 */
@Component
export struct SecondaryButton {
  @Prop label: string = '';
  @Prop buttonEnabled: boolean = true;
  @Prop fullWidth: boolean = true;
  @Prop compact: boolean = false;
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private horizontalPadding(): number {
    if (this.fullWidth) {
      return 16;
    }
    return this.compact ? 20 : 24;
  }

  build() {
    Button(this.label, { type: ButtonType.Normal, stateEffect: false })
      .height(this.compact ? ThemeConstants.BUTTON_HEIGHT_COMPACT : ThemeConstants.BUTTON_HEIGHT)
      .fontSize(this.compact ? ThemeConstants.BODY_MEDIUM : ThemeConstants.TITLE_MEDIUM)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.colors().brandPrimary)
      .enabled(this.buttonEnabled)
      .opacity(this.buttonEnabled ? 1 : 0.55)
      .width(this.fullWidth ? '100%' : undefined)
      .padding({ left: this.horizontalPadding(), right: this.horizontalPadding() })
      .backgroundColor(this.colors().brandPrimaryLight)
      .border({
        width: 1,
        color: '#66007DFF',
        radius: ThemeConstants.BUTTON_RADIUS
      })
      .stateStyles({
        pressed: {
          .backgroundColor(this.colors().brandPrimaryLightPressed)
        }
      })
      .onClick(() => {
        if (this.buttonEnabled) {
          this.onTap();
        }
      });
  }
}
