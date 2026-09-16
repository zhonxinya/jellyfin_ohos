import router from '@ohos.router';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 首次启动隐私政策同意弹窗（应用市场合规必需）。
 *
 * 华为应用市场的高频驳回项之一是"在同意隐私政策前，应用获取了用户的个人信息"。
 * 因此本弹窗必须在**任何个人信息处理与网络请求之前**展示，且：
 * - 不同意时提供明确的退出入口（不得强制同意后仍继续收集）；
 * - 弹窗内可直接查看《隐私政策》与《用户协议》全文，不以外部链接代替；
 * - 同意结果按政策版本号持久化，政策更新后重新征求同意。
 */
@Component
export struct PrivacyConsentDialog {
  /** 不同意时的处理（通常为退出应用） */
  onDecline: () => void = () => {};
  /** 同意时的处理（保存同意状态后继续启动流程） */
  onAgree: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Column() {
      Column({ space: 12 }) {
        Text('隐私政策与用户协议')
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .width('100%')

        Text('感谢使用本应用。在开始之前，请阅读并同意以下内容：')
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().textSecondary)
          .width('100%')

        Column({ space: 6 }) {
          Text('· 本应用是 Jellyfin 的非官方第三方客户端，不提供任何服务器与媒体内容，需连接你自行部署的服务器。')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
          Text('· 为完成连接与登录，本应用会在本机保存服务器地址、用户名与访问令牌，并生成一个随机设备标识；这些信息仅保存在本机与你自己指定的服务器上。')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
          Text('· 本应用仅申请网络访问权限，不含广告、不含第三方统计 SDK，不会向任何第三方共享你的信息。')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)

        Row({ space: 16 }) {
          Text('查看《隐私政策》')
            .fontSize(ThemeConstants.META_MEDIUM)
            .fontColor(this.colors().brandPrimary)
            .onClick(() => {
              router.pushUrl({ url: 'pages/LegalPage', params: { title: 'privacy' } });
            })
          Text('查看《用户协议》')
            .fontSize(ThemeConstants.META_MEDIUM)
            .fontColor(this.colors().brandPrimary)
            .onClick(() => {
              router.pushUrl({ url: 'pages/LegalPage', params: { title: 'terms' } });
            })
        }
        .width('100%')

        Row({ space: 10 }) {
          Button('不同意并退出', { type: ButtonType.Normal, stateEffect: false })
            .layoutWeight(1)
            .height(ThemeConstants.BUTTON_HEIGHT)
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontColor(this.colors().textSecondary)
            .backgroundColor(this.colors().cardBackground)
            .border({ width: 1, color: this.colors().divider, radius: ThemeConstants.BUTTON_RADIUS })
            .stateStyles({
              pressed: {
                .backgroundColor(this.colors().surfacePressed)
              }
            })
            .onClick(() => {
              this.onDecline();
            })
          Button('同意并继续', { type: ButtonType.Normal, stateEffect: false })
            .layoutWeight(1)
            .height(ThemeConstants.BUTTON_HEIGHT)
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onBrand)
            .backgroundColor(this.colors().brandPrimary)
            .borderRadius(ThemeConstants.BUTTON_RADIUS)
            .stateStyles({
              pressed: {
                .backgroundColor(this.colors().brandPrimaryPressed)
              }
            })
            .onClick(() => {
              this.onAgree();
            })
        }
        .width('100%')
        .margin({ top: 4 })
      }
      .width('88%')
      .padding(20)
      .backgroundColor(this.colors().cardBackground)
      .borderRadius(ThemeConstants.CARD_RADIUS)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.colors().scrimHeavy)
  }
}
