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
    .backgroundColor(this.colors().cardBackground)
  }
}
