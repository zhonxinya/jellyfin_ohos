import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 加载态 —— 对齐 mybooks_ohos 的 LoadingState。
 *
 * 规格：48vp 品牌色 `LoadingProgress` + 14fp `text_secondary` 提示文案；
 * 容器 `width('100%')` + `layoutWeight(1)` + 居中——参考项目中只有加载态带 `layoutWeight`，
 * 因此它可以单独填满剩余空间，也常作为列表尾部的"加载更多"占位。
 */
@Component
export struct LoadingState {
  @Prop hint: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Column({ space: 12 }) {
      LoadingProgress()
        .width(48)
        .height(48)
        .color(this.colors().brandPrimary)
      Text(this.hint.length > 0 ? this.hint : $r('app.string.state_loading'))
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textSecondary)
    }
    .width('100%')
    .layoutWeight(1)
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
