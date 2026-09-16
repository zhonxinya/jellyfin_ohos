import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { AppTopBar } from './AppTopBar';

/**
 * 页面外壳 —— 对齐 mybooks_ohos 的 PageScaffold。
 *
 * 规格：整屏 `Column`，底色 `page_background`；顶部 `AppTopBar`（56vp）；内容区 `layoutWeight(1)`。
 * 内容留白由页面自己负责（参考项目同样如此），这样列表页可以做通栏分隔线。
 */
@Component
export struct PageScaffold {
  @Prop title: ResourceStr = '';
  @Prop showBack: boolean = false;
  onBackTap: () => void = () => {};
  @BuilderParam action: () => void = this.defaultAction;
  @BuilderParam content: () => void = this.defaultContent;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  @Builder
  defaultAction(): void {
  }

  @Builder
  defaultContent(): void {
  }

  /**
   * 转发壳：`@BuilderParam` 只能由 `@Builder` / `@LocalBuilder` 初始化，
   * 直接把本组件的 action 透传下去会触发编译告警；
   * 而普通 `@Builder` 作为 builder 参数传下去时 ArkUI 会把 `this` 重绑定到接收方组件，
   * `this.action()` 会解析成同一个 builder 造成无限递归（参考项目实测 Stack overflow）。
   * 因此必须用 `@LocalBuilder` 包一层保持 `this` 指向本组件。
   */
  @LocalBuilder
  actionWrapper(): void {
    this.action();
  }

  build() {
    Column() {
      AppTopBar({
        title: this.title,
        showBack: this.showBack,
        onBackTap: () => { this.onBackTap(); },
        action: this.actionWrapper
      })
      Column() {
        this.content();
      }
      .layoutWeight(1)
      .width('100%')
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
