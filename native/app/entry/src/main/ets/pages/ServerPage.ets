import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { SessionStore } from '../services/SessionStore';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { PrimaryButton } from '../components/PrimaryButton';

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
        .fontColor(this.colors().textPrimary)
        .width('100%')

      Text($r('app.string.server_hint'))
        .fontSize(ThemeConstants.META_MEDIUM)
        .fontColor(this.colors().textSecondary)
        .width('100%')

      TextInput({ text: this.serverUrl, placeholder: 'https://jellyfin.example.com' })
        .width('100%')
        .height(ThemeConstants.INPUT_HEIGHT)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .backgroundColor(this.colors().cardBackground)
        .fontColor(this.colors().textPrimary)
        .placeholderColor(this.colors().textTertiary)
        // 圆角写进 border（先 borderRadius 再 border 会重置圆角）
        .border({ width: 1, color: this.colors().divider, radius: ThemeConstants.COVER_RADIUS })
        .onChange((value: string) => {
          this.serverUrl = value;
        })

      if (this.status === UiState.ERROR && this.errorMsg.length > 0) {
        Text(this.errorMsg)
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().error)
          .width('100%')
      }

      PrimaryButton({
        label: this.status === UiState.LOADING ? '连接中…' : '继续',
        buttonEnabled: this.status !== UiState.LOADING,
        onTap: () => {
          this.onConnect();
        }
      })
    }
    .padding(24)
    .width('100%')
    .constraintSize({ maxWidth: ThemeConstants.FORM_MAX_WIDTH })
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.colors().pageBackground)
  }
}
