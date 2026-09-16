import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { SessionStore } from '../services/SessionStore';
import { SessionUtil } from '../services/SessionUtil';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';

@Entry
@Component
struct SplashPage {
  @State private status: string = UiState.LOADING;
  @State private message: string = '正在恢复会话…';

  aboutToAppear(): void {
    this.bootstrap().catch(() => {
      this.status = UiState.ERROR;
      this.message = '启动失败，请重试';
    });
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async bootstrap(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    await SessionStore.init(ctx);
    const vm: AppViewModel = AppViewModel.getInstance();
    const serverUrl: string = await SessionStore.loadServerUrl();
    if (serverUrl.length > 0) {
      vm.setServer(serverUrl);
      await JellyfinNative.configureServer(serverUrl);
    }
    const sessionJson: string = await SessionStore.loadSession();
    if (sessionJson.length === 0) {
      this.routeNext(serverUrl.length > 0);
      return;
    }
    const normalized: string = SessionUtil.normalizeStoredSession(sessionJson);
    const restoreRaw: string = JellyfinNative.restoreSession(normalized);
    const restore: NativeResult = JellyfinNative.parseResult(restoreRaw);
    const sessionRaw: string = JellyfinNative.getSession();
    const session: NativeResult = JellyfinNative.parseResult(sessionRaw);
    if (restore.ok && SessionUtil.isAuthenticatedPayload(session.data)) {
      if (normalized.length > 0 && normalized !== sessionJson) {
        await SessionStore.saveSession(normalized);
      }
      const userName: string = JsonUtil.getString(session.data, 'userName',
        JsonUtil.getString(session.data, 'UserName', '用户'));
      const isAdmin: boolean = JsonUtil.getBoolean(session.data, 'isAdmin', false);
      vm.setLoggedIn(userName, isAdmin);
      // 从 session preferences 恢复主题偏好（与 AppViewModel 默认 dark/ocean 一致）
      const prefsRaw: string = JellyfinNative.getPreferences();
      const prefsResult: NativeResult = JellyfinNative.parseResult(prefsRaw);
      if (prefsResult.ok && prefsResult.data !== null) {
        const prefs: ESObject = prefsResult.data as ESObject;
        const savedMode: string = JsonUtil.getString(prefs, 'themeMode', '');
        const savedAccent: string = JsonUtil.getString(prefs, 'accent', '');
        if (savedMode.length > 0) {
          vm.setThemeMode(savedMode);
        }
        if (savedAccent.length > 0) {
          vm.setAccent(savedAccent);
        }
      }
      router.replaceUrl({ url: 'pages/MainShell' });
      return;
    }
    await SessionStore.clearSession();
    vm.resetAuth();
    this.routeNext(serverUrl.length > 0);
  }

  private routeNext(hasServer: boolean): void {
    if (hasServer) {
      router.replaceUrl({ url: 'pages/LoginPage' });
    } else {
      router.replaceUrl({ url: 'pages/ServerPage' });
    }
  }

  build() {
    Column({ space: 16 }) {
      Text($r('app.string.app_name'))
        .fontSize(28)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().onSurface)
      Text(this.message)
        .fontSize(14)
        .fontColor(this.colors().onSurfaceVariant)
      if (this.status === UiState.ERROR) {
        Button($r('app.string.action_retry'))
          .backgroundColor(this.colors().primary)
          .fontColor(this.colors().onPrimary)
          .onClick(() => {
            this.status = UiState.LOADING;
            this.bootstrap();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors().background)
  }
}
