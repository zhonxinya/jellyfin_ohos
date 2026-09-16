import router from '@ohos.router';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';

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
    // 入口页只做一次跳转，视觉沿用参考项目：页面底色 + 次级文字
    Column() {
      Text($r('app.string.state_loading'))
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textSecondary)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.colors().pageBackground)
  }
}
