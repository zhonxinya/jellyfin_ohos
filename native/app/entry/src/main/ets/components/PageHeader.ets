import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

@Component
export struct PageHeader {
  @Prop title: ResourceStr = '';
  @Prop showBack: boolean = true;
  onBack: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Row() {
      if (this.showBack) {
        Button() {
          SymbolGlyph($r('sys.symbol.chevron_left'))
            .fontSize(24)
            .fontColor([this.colors().onSurfaceVariant])
        }
          .width(48)
          .height(48)
          .padding(0)
          .backgroundColor(Color.Transparent)
          .onClick(() => {
            this.onBack();
          })
      }
      Text(this.title)
        .fontSize(22)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().onSurface)
        .margin({ left: this.showBack ? 8 : 0 })
        .layoutWeight(1)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .height(64)
    .padding({ left: 16, right: 16 })
  }
}
