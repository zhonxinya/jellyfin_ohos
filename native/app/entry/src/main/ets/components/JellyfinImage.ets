import { ThemeColors } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

@Component
export struct JellyfinImage {
  @Prop url: string = '';
  @Prop imgWidth: number = 120;
  @Prop imgHeight: number = 180;
  @Prop cornerRadius: number = 12;
  @Prop objectFit: ImageFit = ImageFit.Cover;
  @Prop placeholderIcon: string = 'movie';
  @State private loadFailed: boolean = false;
  @State private loading: boolean = true;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /** 占位图标 —— 用系统符号（原来返回 📚/👤/🎬 emoji 文本） */
  private iconResource(): Resource {
    if (this.placeholderIcon === 'library') {
      return $r('sys.symbol.folder');
    }
    if (this.placeholderIcon === 'person') {
      return $r('sys.symbol.person');
    }
    return $r('sys.symbol.video');
  }

  @Builder
  Placeholder() {
    Column() {
      if (this.loading && this.url.length > 0 && !this.loadFailed) {
        LoadingProgress()
          .width(24)
          .height(24)
          .color(this.colors().primary)
      } else {
        SymbolGlyph(this.iconResource())
          .fontSize(Math.min(40, Math.max(24, Math.floor(Math.min(this.imgWidth, this.imgHeight) / 4))))
          .fontColor([this.colors().textTertiary])
      }
    }
    .width(this.imgWidth)
    .height(this.imgHeight)
    .borderRadius(this.cornerRadius)
    .backgroundColor(this.colors().surfaceContainerHighest)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      if (this.url.length > 0 && !this.loadFailed) {
        Image(this.url)
          .width(this.imgWidth)
          .height(this.imgHeight)
          .borderRadius(this.cornerRadius)
          .objectFit(this.objectFit)
          .onComplete(() => {
            this.loading = false;
          })
          .onError(() => {
            this.loadFailed = true;
            this.loading = false;
          })
        if (this.loading) {
          this.Placeholder()
        }
      } else {
        this.Placeholder()
      }
    }
    .width(this.imgWidth)
    .height(this.imgHeight)
  }
}
