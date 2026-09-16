import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { SessionStore } from '../services/SessionStore';
import { SessionUtil } from '../services/SessionUtil';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { PrimaryButton } from '../components/PrimaryButton';
import { SecondaryButton } from '../components/SecondaryButton';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { PageHeader } from '../components/PageHeader';

@Entry
@Component
struct LoginPage {
  @State private username: string = '';
  @State private password: string = '';
  @State private obscurePassword: boolean = true;
  @State private status: string = UiState.INITIAL;
  @State private errorMsg: string = '';
  @State private serverLabel: string = '';

  aboutToAppear(): void {
    this.serverLabel = AppViewModel.getInstance().serverUrl;
    // 预填上次登录用户名
    const lastUser: string = SessionUtil.getLastUsername();
    if (lastUser.length > 0) {
      this.username = lastUser;
    }
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async onLogin(): Promise<void> {
    const uname: string = this.username.trim();
    if (uname.length === 0 || this.password.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '请输入用户名和密码';
      return;
    }
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.login(uname, this.password);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      const msg: string = result.message;
      if (msg.includes('401')) {
        this.status = UiState.ERROR;
        this.errorMsg = '用户名或密码错误';
      } else if (msg.includes('403')) {
        this.status = UiState.ERROR;
        this.errorMsg = '没有权限访问该服务器';
      } else {
        this.status = UiState.ERROR;
        this.errorMsg = msg.length > 0 ? msg : '登录失败';
      }
      return;
    }
    const sessionRaw: string = JellyfinNative.getSession();
    const session: NativeResult = JellyfinNative.parseResult(sessionRaw);
    // 登录会由 C++ 随机生成 deviceId；这里统一替换为持久化的稳定值并重新 restore，
    // 使服务端 /Devices 与 /Sessions 始终对应同一台设备
    const stableDeviceId: string = await SessionStore.ensureDeviceId();
    const rawSession: string = SessionUtil.exportSessionJson();
    const payload: string = SessionUtil.stabilizeDeviceId(rawSession, stableDeviceId);
    if (payload.length > 0 && payload !== rawSession) {
      // deviceId 被替换过 → 让 C++ 会话也切到稳定标识
      JellyfinNative.restoreSession(payload);
    }
    if (payload.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '登录成功但会话无效，请重试';
      return;
    }
    const saved: boolean = await SessionStore.saveSession(payload);
    if (!saved) {
      this.status = UiState.ERROR;
      this.errorMsg = '无法保存登录状态，请重试';
      return;
    }
    const userName: string = JsonUtil.getString(session.data, 'userName',
      JsonUtil.getString(result.data, 'UserName', uname));
    const isAdmin: boolean = JsonUtil.getBoolean(session.data, 'isAdmin', false);
    AppViewModel.getInstance().setLoggedIn(userName, isAdmin);
    await SessionStore.saveLastUsername(uname);
    this.status = UiState.SUCCESS;
    router.replaceUrl({ url: 'pages/MainShell' });
  }

  build() {
    Column() {
      PageHeader({
        title: $r('app.string.login_title'),
        showBack: false
      })
      Scroll() {
        Column() {
          Row() {
            SymbolGlyph($r('sys.symbol.film'))
              .fontSize(ThemeConstants.ICON_LOGO)
              .fontColor([this.colors().brandPrimary])
          }
          .width('100%')
          .justifyContent(FlexAlign.Center)
          .margin({ bottom: 16 })

          Text(this.serverLabel.length > 0 ? this.serverLabel : 'Jellyfin')
            .fontSize(ThemeConstants.TITLE_LARGE)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().textPrimary)
            .width('100%')
            .textAlign(TextAlign.Center)

          Text(this.serverLabel.length > 0 ? AppViewModel.getInstance().serverUrl : '')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textTertiary)
            .width('100%')
            .textAlign(TextAlign.Center)
            .margin({ bottom: 28 })

          LoginTextInput({
            text: this.username,
            placeholder: '用户名',
            icon: $r('sys.symbol.person'),
            onChange: (value: string) => { this.username = value; }
          })
            .width('100%')

          SecurePasswordInput({
            text: this.password,
            obscure: this.obscurePassword,
            onChange: (v: string) => { this.password = v; },
            onSubmit: () => { this.onLogin(); },
            onToggleObscure: () => { this.obscurePassword = !this.obscurePassword; }
          })
            .margin({ top: 16 })

          if (this.status === UiState.ERROR && this.errorMsg.length > 0) {
            Text(this.errorMsg)
              .fontSize(ThemeConstants.META_MEDIUM)
              .fontColor(this.colors().error)
              .width('100%')
              .textAlign(TextAlign.Center)
              .margin({ top: 12 })
          }

          // 主按钮：参考项目规格（48vp / 12vp 圆角 / 品牌实底 / 品牌微光投影），加载中切换文案并禁用
          PrimaryButton({
            label: this.status === UiState.LOADING ? '登录中…' : '登录',
            buttonEnabled: this.status !== UiState.LOADING,
            onTap: () => {
              this.onLogin();
            }
          })
            .margin({ top: 24 })

          // 次级按钮：浅底 + 1vp 描边（参考项目 SecondaryButton）
          SecondaryButton({
            label: '更换服务器',
            compact: true,
            onTap: () => {
              router.replaceUrl({ url: 'pages/ServerPage' });
            }
          })
            .margin({ top: 10 })
        }
        .padding({ left: 24, right: 24, top: 24, bottom: 24 })
        .width('100%')
        .constraintSize({ maxWidth: ThemeConstants.FORM_MAX_WIDTH })
      }
      .layoutWeight(1)
      .width('100%')
      .align(Alignment.Center)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}

@Component
struct LoginTextInput {
  @Prop text: string = '';
  @Prop placeholder: string = '';
  @Prop icon: Resource = $r('sys.symbol.person');
  onChange: (value: string) => void = (_value: string) => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Row({ space: 0 }) {
      Row() {
        SymbolGlyph(this.icon)
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontColor([this.colors().textTertiary])
      }
        .width(ThemeConstants.INPUT_HEIGHT)
        .height(ThemeConstants.INPUT_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      TextInput({ text: this.text, placeholder: this.placeholder })
        .layoutWeight(1)
        .height(ThemeConstants.INPUT_HEIGHT)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .placeholderColor(this.colors().textTertiary)
        .backgroundColor(Color.Transparent)
        .enterKeyType(EnterKeyType.Next)
        .onChange((value: string) => {
          this.onChange(value);
        })
    }
    .width('100%')
    .height(ThemeConstants.INPUT_HEIGHT)
    .backgroundColor(this.colors().cardBackground)
    // 圆角必须写进 border：先 borderRadius 再 border 会把圆角重置为直角
    .border({ width: 1, color: this.colors().divider, radius: ThemeConstants.COVER_RADIUS })
  }
}

/** 带显示/隐藏密码切换的输入框 */
@Component
struct SecurePasswordInput {
  @Prop text: string = '';
  @Prop obscure: boolean = true;
  onChange: (value: string) => void = (_value: string) => {};
  onSubmit: () => void = () => {};
  onToggleObscure: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Row({ space: 0 }) {
      Row() {
        SymbolGlyph($r('sys.symbol.lock'))
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontColor([this.colors().textTertiary])
      }
        .width(ThemeConstants.INPUT_HEIGHT)
        .height(ThemeConstants.INPUT_HEIGHT)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      TextInput({ text: this.text, placeholder: '密码' })
        .layoutWeight(1)
        .height(ThemeConstants.INPUT_HEIGHT)
        .type(this.obscure ? InputType.Password : InputType.Normal)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .backgroundColor(Color.Transparent)
        .fontColor(this.colors().textPrimary)
        .placeholderColor(this.colors().textTertiary)
        .enterKeyType(EnterKeyType.Done)
        .onChange((value: string) => {
          this.onChange(value);
        })
        .onSubmit(() => {
          this.onSubmit();
        })
      Button() {
        SymbolGlyph(this.obscure ? $r('sys.symbol.eye') : $r('sys.symbol.eye_slash'))
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontColor([this.colors().textTertiary])
      }
        .width(ThemeConstants.INPUT_HEIGHT)
        .height(ThemeConstants.INPUT_HEIGHT)
        .padding(0)
        .backgroundColor(Color.Transparent)
        .onClick(() => {
          this.onToggleObscure();
        })
    }
    .width('100%')
    .height(ThemeConstants.INPUT_HEIGHT)
    .backgroundColor(this.colors().cardBackground)
    .border({ width: 1, color: this.colors().divider, radius: ThemeConstants.COVER_RADIUS })
  }
}
