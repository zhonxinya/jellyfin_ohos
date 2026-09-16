import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 区块标题 —— 内部实现已换成 mybooks_ohos 的 `SectionTitle` 规格。
 *
 * 参考项目统一用「4×16vp 品牌色竖条 + 17fp / Medium 标题 + 可选右侧动作文字」，
 * 不用 emoji 图标；容器左右 16vp、上 12vp 下 8vp（参考项目的区块节奏）。
 *
 * 保留 `icon` 参数是为了不破坏既有调用点（HomePage/DetailPage/LibraryShelf 仍在传 emoji），
 * 但它**已被忽略**：新视觉不再使用 emoji → 系统符号的映射。后续轮次可直接从调用点移除。
 *
 * @deprecated 新代码请直接用 `SectionTitle`；本组件保留为兼容壳。
 */
@Component
export struct SectionHeader {
  @Prop title: ResourceStr = '';
  /** @deprecated 已忽略（参考项目不使用图标） */
  @Prop icon: string = '';
  @Prop showMore: boolean = false;
  @Prop actionLabel: string = '';
  onMore: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Row({ space: 8 }) {
      Column()
        .width(4)
        .height(16)
        .borderRadius(2)
        .backgroundColor(this.colors().brandPrimary)
      Text(this.title)
        .fontSize(ThemeConstants.TITLE_SECTION)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (this.showMore) {
        Text(this.actionLabel.length > 0 ? this.actionLabel : $r('app.string.view_all'))
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().brandPrimary)
          .padding({ left: 8, right: 8, top: 6, bottom: 6 })
          .onClick(() => {
            this.onMore();
          })
      }
    }
    .width('100%')
    .padding({
      left: ThemeConstants.PAGE_PADDING,
      right: ThemeConstants.PAGE_PADDING,
      top: 12,
      bottom: 8
    })
    .alignItems(VerticalAlign.Center)
  }
}
