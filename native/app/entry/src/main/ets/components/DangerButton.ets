import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 危险操作按钮 —— 对齐 mybooks_ohos 的 DangerButton。
 *
 * 规格：`error_light` 浅底 + `error` 文字 + 1vp 描边；高 48vp；圆角写在 border 内；无投影。
 * 用于退出登录、删除等需要二次确认的入口（参考项目配 `AlertDialog` 确认）。
 */
@Component
export struct DangerButton {
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
      .fontColor(this.colors().error)
      .enabled(this.buttonEnabled)
      .opacity(this.buttonEnabled ? 1 : 0.55)
      .width(this.fullWidth ? '100%' : undefined)
      .padding({ left: this.fullWidth ? 16 : 24, right: this.fullWidth ? 16 : 24 })
      .backgroundColor(this.colors().errorLight)
      .border({
        width: 1,
        color: '#33E84026',
        radius: ThemeConstants.BUTTON_RADIUS
      })
      .stateStyles({
        pressed: {
          .backgroundColor(this.colors().errorLightPressed)
        }
      })
      .onClick(() => {
        if (this.buttonEnabled) {
          this.onTap();
        }
      });
  }
}
