import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 设置行 —— 对齐 mybooks_ohos 的 SettingCell。
 *
 * 规格（右侧插槽有严格的优先级链，顺序本身就是约定）：
 *   开关 > 徽标（可再跟 chevron）> 值文本 > chevron
 * - 行高由内容决定：四边 16vp 内边距；标题 16fp `text_primary`，副标题 12fp `text_secondary`；
 * - 行本身透明，由调用方把若干 `SettingCell` 装进一张卡片，并用 0.5vp `Divider` 分隔；
 * - 带开关的行不响应整行点击（避免重复触发）；按下态换 `surface_pressed`。
 */
@Component
export struct SettingCell {
  @Prop title: string = '';
  @Prop subtitle: string = '';
  @Prop valueText: string = '';
  @Prop badgeText: string = '';
  @Prop showChevron: boolean = false;
  @Prop showToggle: boolean = false;
  @Prop toggleOn: boolean = false;
  onToggle: (value: boolean) => void = () => {};
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Row() {
      Column({ space: 4 }) {
        Text(this.title)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      if (this.showToggle) {
        Toggle({ type: ToggleType.Switch, isOn: this.toggleOn })
          .selectedColor(this.colors().brandPrimary)
          .onChange((value: boolean) => {
            this.onToggle(value);
          })
      } else if (this.badgeText.length > 0) {
        Text(this.badgeText)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(Color.White)
          .backgroundColor(this.colors().brandPrimary)
          .borderRadius(ThemeConstants.BADGE_RADIUS)
          .padding({ left: 6, right: 6, top: 2, bottom: 2 })
        if (this.showChevron) {
          SymbolGlyph($r('sys.symbol.chevron_right'))
            .fontSize(16)
            .fontColor([this.colors().textTertiary])
        }
      } else if (this.valueText.length > 0) {
        Text(this.valueText)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      } else if (this.showChevron) {
        SymbolGlyph($r('sys.symbol.chevron_right'))
          .fontSize(16)
          .fontColor([this.colors().textTertiary])
      }
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
    .backgroundColor(Color.Transparent)
    .stateStyles({
      pressed: {
        .backgroundColor(this.colors().surfacePressed)
      }
    })
    .onClick(() => {
      if (!this.showToggle) {
        this.onTap();
      }
    });
  }
}
