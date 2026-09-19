import router from '@ohos.router';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { AppIconButton } from './AppIconButton';

/**
 * 顶栏 —— 对齐 mybooks_ohos 的 HarmonyTopBar。
 *
 * 规格（参考项目逐项对齐）：
 * - 高度 56vp；底色 `card_background`，与页面底色 `page_background` 形成"卡片条 + 页面"的层次；
 * - 标题 20fp / Medium / `text_primary`，左侧留白 16（有返回按钮时为 4，由 40vp 圆形按钮补足）；
 * - 右侧由调用方通过 `action` 插槽提供（`@BuilderParam`）；
 * - 底部一条 0.5vp `divider` 分隔线；
 * - 返回按钮是 40vp ghost 圆形按钮（`sys.symbol.chevron_left`），默认行为 `router.back()`。
 */
@Component
export struct AppTopBar {
  @Prop title: ResourceStr = '';
  @Prop showBack: boolean = false;
  /** 左侧圆形按钮的图标，默认返回箭头；外壳页用它承载"抽屉菜单"入口 */
  @Prop backIcon: Resource = $r('sys.symbol.chevron_left');
  /** 页面自定义的返回行为；不传则走 router.back() */
  onBackTap: () => void = () => { router.back(); };
  @BuilderParam action: () => void = this.defaultAction;
  /**
   * 挖孔（刘海/胶囊）要避让的高度（vp，由外壳写入 `AppStorage`）。
   *
   * 为什么需要：外壳是**整屏沉浸式**（见 `MainShell.applyChromeForTab`），系统不再替应用
   * 避让顶部，56vp 的顶栏会顶到屏幕最上边 —— 有挖孔的机型上标题会被压住。
   * 为什么走 `AppStorage`：顶栏被外壳与几十个页面共用，让它们各自异步取窗口既啰嗦、
   * 也可能拿到不同窗口实例。外壳不在栈上（例如登录页）或无挖孔时该值为 0，行为与以前一致。
   */
  @StorageProp('shellTopInsetVp') topInsetVp: number = 0;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  @Builder
  defaultAction(): void {
  }

  build() {
    Column() {
      Row() {
        if (this.showBack) {
          AppIconButton({
            icon: this.backIcon,
            variant: 'ghost',
            onTap: () => { this.onBackTap(); }
          })
        }
        Text(this.title)
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: this.showBack ? 4 : 16 })
        this.action()
      }
      .width('100%')
      .height(ThemeConstants.TOP_BAR_HEIGHT)
      .padding({ right: 16 })
      .alignItems(VerticalAlign.Center)

      Divider()
        .color(this.colors().divider)
        .strokeWidth(0.5)
    }
    .width('100%')
    // 挖孔避让：沉浸式下顶栏顶到屏幕最上边，有挖孔的机型要让开那一条
    .padding({ top: this.topInsetVp })
    .backgroundColor(this.colors().cardBackground)
  }
}
