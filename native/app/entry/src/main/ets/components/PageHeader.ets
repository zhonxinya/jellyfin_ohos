import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { AppIconButton } from './AppIconButton';

/**
 * 页面顶栏（兼容壳）—— 内部实现已换成 mybooks_ohos 的 `HarmonyTopBar` / `AppTopBar` 规格。
 *
 * 规格：高度 **56vp**（原 64vp）；底色 `card_background`，与页面底色 `page_background` 形成层次；
 * 标题 20fp / Medium / `text_primary`，左侧留白 16vp（有返回按钮时为 4vp，由 40vp 圆形按钮补足）；
 * 右侧插槽 `action`；底部一条 0.5vp `divider`；返回按钮为 40vp ghost 圆形按钮（18fp 图标）。
 *
 * 说明：保留 `title` / `showBack` / `onBack` 原 API，因此所有既有调用点无需改动即切换到新规格。
 * `transparent` 用于需要叠在图片上的场景（不画底色与分隔线）。
 *
 * @deprecated 新代码建议直接用 `PageScaffold` + `AppTopBar`（可承载 `action` 插槽）。
 */
@Component
export struct PageHeader {
  @Prop title: ResourceStr = '';
  @Prop showBack: boolean = true;
  /** 叠在图片上时使用：不画底色与底部分隔线 */
  @Prop transparent: boolean = false;
  onBack: () => void = () => {};
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
            icon: $r('sys.symbol.chevron_left'),
            variant: 'ghost',
            iconSize: 18,
            onTap: () => {
              this.onBack();
            }
          })
        }
        Text(this.title)
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
          .margin({ left: this.showBack ? 4 : ThemeConstants.PAGE_PADDING })
        this.action()
      }
      .width('100%')
      .height(ThemeConstants.TOP_BAR_HEIGHT)
      .padding({ right: ThemeConstants.PAGE_PADDING })
      .alignItems(VerticalAlign.Center)

      if (!this.transparent) {
        Divider()
          .color(this.colors().divider)
          .strokeWidth(0.5)
      }
    }
    .width('100%')
    .backgroundColor(this.transparent ? Color.Transparent : this.colors().cardBackground)
  }
}
