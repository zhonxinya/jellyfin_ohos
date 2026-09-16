import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { AppIconButton } from './AppIconButton';

/**
 * 搜索栏 —— 对齐 mybooks_ohos 的 SearchBar。
 *
 * 规格：`Row({ space: 8 })`；40vp 输入框（卡片底 + `divider` 描边 + 12vp 圆角，圆角写在 border 里）
 * 左内边距 16vp；右侧独立的 40vp 品牌色圆形搜索按钮（不是把放大镜塞进输入框做装饰）；
 * 容器左右各 16vp、底部 8vp。
 */
@Component
export struct SearchBar {
  @Prop placeholder: ResourceStr = '搜索';
  @Prop keyword: string = '';
  /** 是否在输入框右侧显示清除按钮（参考项目未提供，本工程保留该交互） */
  @Prop showClear: boolean = false;
  onChange: (value: string) => void = () => {};
  onSearch: () => void = () => {};
  onClear: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Row({ space: 8 }) {
      TextInput({ placeholder: this.placeholder, text: this.keyword })
        .layoutWeight(1)
        .height(ThemeConstants.BUTTON_HEIGHT_COMPACT)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .placeholderColor(this.colors().textTertiary)
        .placeholderFont({ size: ThemeConstants.BODY_MEDIUM })
        .backgroundColor(this.colors().cardBackground)
        .caretColor(this.colors().brandPrimary)
        .border({
          width: 1,
          color: this.colors().divider,
          radius: ThemeConstants.BUTTON_RADIUS
        })
        .padding({ left: 16, right: 16 })
        .onChange((value: string) => {
          this.onChange(value);
        })
        .onSubmit(() => {
          this.onSearch();
        })
      if (this.showClear && this.keyword.length > 0) {
        Button('\u2715')
          .width(32)
          .height(32)
          .fontSize(16)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .fontColor(this.colors().textTertiary)
          .stateStyles({
            pressed: {
              .backgroundColor(this.colors().surfacePressed)
            }
          })
          .onClick(() => {
            this.onClear();
          })
      }
      AppIconButton({
        icon: $r('sys.symbol.magnifyingglass'),
        variant: 'primary',
        iconSize: 18,
        onTap: () => {
          this.onSearch();
        }
      })
    }
    .width('100%')
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }
}
