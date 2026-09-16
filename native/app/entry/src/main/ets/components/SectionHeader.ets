import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

@Component
export struct SectionHeader {
  @Prop title: ResourceStr = '';
  @Prop icon: string = '';
  @Prop showMore: boolean = false;
  onMore: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /** emoji 输入 → 系统符号资源；全部名称已在本机 SDK sysResource 核验 */
  private iconResource(): Resource {
    if (this.icon === '📚') {
      return $r('sys.symbol.book_pages');
    }
    if (this.icon === '▶️') {
      return $r('sys.symbol.play');
    }
    if (this.icon === '🎦') {
      return $r('sys.symbol.video');
    }
    if (this.icon === '⭐') {
      return $r('sys.symbol.star');
    }
    if (this.icon === '🎬') {
      return $r('sys.symbol.film');
    }
    if (this.icon === '👥') {
      return $r('sys.symbol.person_2');
    }
    if (this.icon.length > 0) {
      return $r(this.icon as string);
    }
    return $r('sys.symbol.rectangle_stack');
  }

  build() {
    Row() {
      if (this.icon.length > 0) {
        SymbolGlyph(this.iconResource())
          .fontSize(20)
          .fontColor([this.colors().onSurfaceVariant])
          .margin({ right: 8 })
      }
      Text(this.title)
        .fontSize(16)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().onSurface)
        .layoutWeight(1)
      if (this.showMore) {
        Button($r('app.string.view_all'))
          .height(40)
          .padding({ left: 8, right: 8 })
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().primary)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.onMore();
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 8, top: 20, bottom: 8 })
  }
}
