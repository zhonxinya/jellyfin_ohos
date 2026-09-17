import { ThemeColors } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';

/**
 * 封面图组件。
 *
 * **重要**：这里**不再把远程 URL 直接交给 ArkUI**（原来是 `Image(远程URL)`）。
 *
 * 为什么必须改（设备实测的崩溃根因）：`Image(远程URL)` 会让 ArkUI 用自己的网络栈
 * （hilog 里的 `NETSTACK` + `PreloadNative`）逐张并发下载图片，既不受本工程控制、
 * 也没有磁盘缓存。打开 720 项的大媒体库时并发量暴涨，进程 fd 逼近上限，
 * musl FORTIFY 的 `__fd_chk` 判定 fd 非法并 **直接 abort**（小库 23 项则不崩，已对照验证）。
 *
 * 现在改为经 `JellyfinNative.loadImage()` 取图：由本工程 core 的 HTTP 客户端下载 +
 * 落磁盘缓存，ArkUI 只读本地文件。收益：
 *  - 不再触发系统网络栈的图片并发（消除崩溃触发条件）；
 *  - 图片有磁盘缓存，滚动不再重复下载（体验与流量都更好）；
 *  - 取图路径可控（后续可在原生侧加在途请求上限）。
 */
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
  /** 本地缓存文件路径（file:// URI）；为空表示尚未就绪 */
  @State private localUri: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.resolveImage();
  }

  /**
   * 经原生缓存取图：命中缓存直接返回本地路径，未命中则下载后落盘。
   * 失败时显示占位图标（**不回退到远程 URL**，否则又把并发下载还给系统网络栈）。
   */
  private async resolveImage(): Promise<void> {
    if (this.url.length === 0) {
      this.loading = false;
      return;
    }
    try {
      const raw: string = await JellyfinNative.loadImage(this.url);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        this.loadFailed = true;
        this.loading = false;
        return;
      }
      const path: string = JsonUtil.getString(result.data as ESObject, 'path', '');
      if (path.length === 0) {
        this.loadFailed = true;
        this.loading = false;
        return;
      }
      this.localUri = path.startsWith('file://') ? path : `file://${path}`;
    } catch (err) {
      this.loadFailed = true;
      this.loading = false;
    }
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
          .color(this.colors().brandPrimary)
      } else {
        SymbolGlyph(this.iconResource())
          .fontSize(Math.min(40, Math.max(24, Math.floor(Math.min(this.imgWidth, this.imgHeight) / 4))))
          .fontColor([this.colors().textTertiary])
      }
    }
    .width(this.imgWidth)
    .height(this.imgHeight)
    .borderRadius(this.cornerRadius)
    .backgroundColor(this.colors().surfacePressed)
    .justifyContent(FlexAlign.Center)
  }

  build() {
    Stack() {
      if (this.localUri.length > 0 && !this.loadFailed) {
        Image(this.localUri)
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
