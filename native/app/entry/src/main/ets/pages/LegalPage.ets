import router from '@ohos.router';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { PageScaffold } from '../components/PageScaffold';
import { PRIVACY_POLICY, USER_AGREEMENT } from '../common/LegalTexts';

/**
 * 隐私政策 / 用户协议页面（应用内全文展示）。
 *
 * 上架合规要求：隐私政策必须能在应用内查看（不能只放一个外部链接），
 * 且首次启动的同意弹窗要能从弹窗内直接查看全文。
 * 通过路由参数 `title` 区分文档：'privacy' | 'terms'（复用设置页现有的 params 传参方式）。
 */
@Entry
@Component
struct LegalPage {
  @State private doc: string = 'privacy';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const raw: Object = params['title'];
      if (typeof raw === 'string' && raw.length > 0) {
        this.doc = raw;
      }
    }
  }

  private titleText(): string {
    return this.doc === 'terms' ? '用户协议' : '隐私政策';
  }

  private bodyText(): string {
    return this.doc === 'terms' ? USER_AGREEMENT : PRIVACY_POLICY;
  }

  @Builder
  pageContent() {
    Scroll() {
      Column({ space: 12 }) {
        Text(this.titleText())
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .width('100%')
        Text(this.bodyText())
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textSecondary)
          .lineHeight(23)
          .width('100%')
      }
      .width('100%')
      .padding({
        left: ThemeConstants.PAGE_PADDING,
        right: ThemeConstants.PAGE_PADDING,
        top: ThemeConstants.PAGE_PADDING,
        bottom: 32
      })
      .alignItems(HorizontalAlign.Start)
    }
    .layoutWeight(1)
    .width('100%')
    .align(Alignment.Top)
    .scrollBar(BarState.Auto)
  }

  build() {
    Column() {
      PageScaffold({
        title: this.titleText(),
        showBack: true,
        onBackTap: () => {
          router.back();
        },
        content: () => {
          this.pageContent();
        }
      })
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
