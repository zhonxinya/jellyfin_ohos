import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { SessionStore } from '../services/SessionStore';
import { SessionUtil } from '../services/SessionUtil';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { LEGAL_VERSION } from '../common/LegalTexts';
import { PrivacyConsentDialog } from '../components/PrivacyConsentDialog';

@Entry
@Component
struct SplashPage {
  @State private status: string = UiState.LOADING;
  @State private message: string = '正在恢复会话…';
  /** 未同意隐私政策时先展示同意弹窗，同意前不进行任何信息处理与网络请求 */
  @State private needConsent: boolean = false;

  aboutToAppear(): void {
    this.start().catch(() => {
      this.status = UiState.ERROR;
      this.message = '启动失败，请重试';
    });
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /** 启动入口：先校验隐私政策同意状态，未同意则只展示弹窗 */
  private async start(): Promise<void> {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    await SessionStore.init(ctx);
    // 稳定设备标识必须在任何网络请求（恢复会话/登录）之前注入 C++ 会话，
    // 否则 C++ 会用自己的随机 id 先向服务端注册一次设备，导致设备列表堆积
    const stableDeviceId: string = await SessionStore.ensureDeviceId();
    JellyfinNative.setDeviceId(stableDeviceId);
    const accepted: string = await SessionStore.loadLegalConsent();
    if (accepted !== LEGAL_VERSION) {
      this.needConsent = true;
      this.message = '请阅读并同意隐私政策后继续';
      return;
    }
    await this.bootstrap();
  }

  /** 用户点击"同意并继续"：落盘同意版本号后继续启动 */
  private async onPrivacyAgree(): Promise<void> {
    await SessionStore.saveLegalConsent(LEGAL_VERSION);
    this.needConsent = false;
    this.status = UiState.LOADING;
    this.message = '正在恢复会话…';
    await this.bootstrap();
  }

  /** 用户点击"不同意并退出"：直接退出应用（不得在未同意的情况下继续收集信息） */
  private onPrivacyDecline(): void {
    const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
    ctx.terminateSelf();
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
    // 设备标识独立持久化：恢复会话时统一覆盖为稳定值，避免退出/重新登录后服务端堆积重复设备
    const deviceId: string = await SessionStore.ensureDeviceId();
    const normalized: string = SessionUtil.stabilizeDeviceId(
      SessionUtil.normalizeStoredSession(sessionJson), deviceId);
    const restoreRaw: string = JellyfinNative.restoreSession(normalized);
    const restore: NativeResult = JellyfinNative.parseResult(restoreRaw);
    const sessionRaw: string = JellyfinNative.getSession();
    const session: NativeResult = JellyfinNative.parseResult(sessionRaw);
    if (restore.ok && SessionUtil.isAuthenticatedPayload(session.data)) {
      if (normalized.length > 0 && normalized !== sessionJson) {
        await SessionStore.saveSession(normalized);
      }
      // 会话里的 baseUrl 才是 API 客户端实际使用的地址；持久化的 serverUrl 可能陈旧
      // （设备实测：应用连的是 :8097，设置页却显示旧的 :80），这里以会话为准并回写持久化
      const sessionBaseUrl: string = JsonUtil.getString(session.data, 'baseUrl',
        JsonUtil.getString(session.data, 'BaseUrl', ''));
      if (sessionBaseUrl.length > 0) {
        if (sessionBaseUrl !== serverUrl) {
          vm.setServer(sessionBaseUrl);
          await SessionStore.saveServerUrl(sessionBaseUrl);
        }
        // 始终调用：configureServer 会顺带用 /System/Info/Public 填充会话的 serverName，
        // 否则设置页「服务器名称」只能回落到地址（上一轮设备实测的现象）
        const cfgRaw: string = await JellyfinNative.configureServer(sessionBaseUrl);
        // configureServer 的返回里带 serverName（取自 /System/Info/Public），
        // 这是界面显示服务器名称的权威来源（会话 JSON 里的 serverName 可能为空）
        const cfg: NativeResult = JellyfinNative.parseResult(cfgRaw);
        if (cfg.ok && cfg.data !== null) {
          const name: string = JsonUtil.getString(cfg.data, 'serverName', '');
          if (name.length > 0) {
            vm.setServerName(name);
          }
        }
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
    Stack() {
      this.Splash()
      if (this.needConsent) {
        PrivacyConsentDialog({
          onAgree: () => {
            this.onPrivacyAgree();
          },
          onDecline: () => {
            this.onPrivacyDecline();
          }
        })
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  Splash() {
    Column({ space: 16 }) {
      Text($r('app.string.app_name'))
        .fontSize(ThemeConstants.TITLE_DISPLAY)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
      Text(this.message)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textSecondary)
      if (this.status === UiState.ERROR) {
        Button($r('app.string.action_retry'))
          .backgroundColor(this.colors().brandPrimary)
          .fontColor(this.colors().onBrand)
          .onClick(() => {
            this.status = UiState.LOADING;
            this.start();
          })
      }
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors().pageBackground)
  }
}
