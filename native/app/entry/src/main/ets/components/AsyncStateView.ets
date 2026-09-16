import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { UiState } from '../common/UiState';
import { AppViewModel } from '../viewmodel/AppViewModel';

@Component
export struct AsyncStateView {
  @Prop status: string = UiState.LOADING;
  @Prop message: string = '';
  @Prop emptyHint: string = '暂无数据';
  @Prop minHeight: number = 120;
  onRetry: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Column() {
      if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color(this.colors().primary)
        Text($r('app.string.state_loading'))
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().onSurfaceVariant)
          .margin({ top: 12 })
      } else if (this.status === UiState.ERROR) {
        Text(this.message.length > 0 ? this.message : '加载失败')
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().error)
          .textAlign(TextAlign.Center)
          .padding(16)
        Button($r('app.string.action_retry'))
          .backgroundColor(this.colors().primary)
          .fontColor(this.colors().onPrimary)
          .onClick(() => {
            this.onRetry();
          })
      } else if (this.status === UiState.EMPTY) {
        Text(this.emptyHint)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().onSurfaceVariant)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.minHeight })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
