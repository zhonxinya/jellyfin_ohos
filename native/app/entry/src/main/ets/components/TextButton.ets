import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

export type TextButtonTone = 'brand' | 'danger';

/**
 * 文字按钮 —— 对齐 mybooks_ohos 的 TextButton。
 *
 * 规格：无固定高度、无底色；13fp / Medium；品牌色或错误色；左右各 8vp 内边距；
 * 按下态换成 `surface_pressed`。用于"全部""重试""取消"等轻量入口。
 */
@Component
export struct TextButton {
  @Prop label: string = '';
  @Prop tone: TextButtonTone = 'brand';
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Button(this.label, { type: ButtonType.Normal, stateEffect: false })
      .fontSize(ThemeConstants.META_MEDIUM)
      .fontWeight(FontWeight.Medium)
      .fontColor(this.tone === 'danger' ? this.colors().error : this.colors().brandPrimary)
      .backgroundColor(Color.Transparent)
      .padding({ left: 8, right: 8 })
      .stateStyles({
        pressed: {
          .backgroundColor(this.colors().surfacePressed)
        }
      })
      .onClick(() => {
        this.onTap();
      });
  }
}
