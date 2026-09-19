import router from '@ohos.router';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { PageScaffold } from '../components/PageScaffold';
import { PRIVACY_POLICY, USER_AGREEMENT } from '../common/LegalTexts';
import { parseBoldSegments, splitLines, TextSegment } from '../common/RichText';

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

  /** 一行：`**加粗**` 拆成片段渲染，避免把星号原样显示给用户（审核会看这一页） */
  @Builder
  Line(line: string) {
    if (line.length === 0) {
      Blank().height(6)
    } else {
      Flex({ wrap: FlexWrap.Wrap }) {
        ForEach(parseBoldSegments(line), (seg: TextSegment, index: number) => {
          Text(seg.text)
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .lineHeight(23)
            .fontWeight(seg.bold ? FontWeight.Bold : FontWeight.Normal)
            .fontColor(seg.bold ? this.colors().textPrimary : this.colors().textSecondary)
        }, (seg: TextSegment, index: number) => `${index}_${seg.text}`)
      }
      .width('100%')
    }
  }

  @Builder
  pageContent() {
    Scroll() {
      Column({ space: 6 }) {
        Text(this.titleText())
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .width('100%')
        ForEach(splitLines(this.bodyText()), (line: string, index: number) => {
          this.Line(line)
        }, (line: string, index: number) => `${index}_${line.length}_${line.substring(0, 12)}`)
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
