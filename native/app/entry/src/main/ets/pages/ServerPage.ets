import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { SessionStore } from '../services/SessionStore';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';

@Entry
@Component
struct ServerPage {
  @State private serverUrl: string = '';
  @State private status: string = UiState.INITIAL;
  @State private errorMsg: string = '';

  aboutToAppear(): void {
    const vm: AppViewModel = AppViewModel.getInstance();
    if (vm.serverUrl.length > 0) {
      this.serverUrl = vm.serverUrl;
    }
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async onConnect(): Promise<void> {
    const url: string = this.serverUrl.trim();
    if (url.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '请输入服务器地址';
      return;
    }
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.configureServer(url);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '连接失败';
      return;
    }
    const vm: AppViewModel = AppViewModel.getInstance();
    vm.setServer(url);
    await SessionStore.saveServerUrl(url);
    this.status = UiState.SUCCESS;
    router.pushUrl({ url: 'pages/LoginPage' });
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.server_title'))
        .fontSize(ThemeConstants.TITLE_LARGE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().onSurface)
        .width('100%')

      Text($r('app.string.server_hint'))
        .fontSize(ThemeConstants.LABEL_SMALL)
        .fontColor(this.colors().onSurfaceVariant)
        .width('100%')

      TextInput({ text: this.serverUrl, placeholder: 'https://jellyfin.example.com' })
        .width('100%')
        .height(48)
        .backgroundColor(this.colors().surface)
        .fontColor(this.colors().onSurface)
        .placeholderColor(this.colors().outline)
        .onChange((value: string) => {
          this.serverUrl = value;
        })

      if (this.status === UiState.ERROR && this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().error)
          .width('100%')
      }

      Button(this.status === UiState.LOADING ? $r('app.string.state_loading') : $r('app.string.action_continue'))
        .width('100%')
        .backgroundColor(this.colors().primary)
        .fontColor(this.colors().onPrimary)
        .enabled(this.status !== UiState.LOADING)
        .onClick(() => {
          this.onConnect();
        })
    }
    .padding(24)
    .width('100%')
    .constraintSize({ maxWidth: ThemeConstants.FORM_MAX_WIDTH })
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.colors().background)
  }
}
