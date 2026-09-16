import router from '@ohos.router';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { ThemeColors } from '../common/ThemeConstants';

@Entry
@Component
struct Index {
  aboutToAppear(): void {
    router.replaceUrl({ url: 'pages/SplashPage' });
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Column() {
      Text($r('app.string.state_loading'))
        .fontColor(this.colors().onSurfaceVariant)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.colors().background)
  }
}
