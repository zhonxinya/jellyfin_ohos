import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 单选行 —— 对齐 mybooks_ohos 的 `RadioListTile`。
 *
 * 为什么单独成一个组件：主题设置页（外观模式 / 强调色）与短视频设置页（清晰度）
 * 需要**同一套单选外观**，而"选中态怎么画"（外圈 2vp 描边 + 内圈品牌色圆点、
 * 40vp 触达圈、16vp 横向内边距）是需要保持一致的设计规格 ——
 * 各处各写一份，改一次就会漂移一处（主题页此前就是独有的一份 @Builder）。
 *
 * 规格：整行可点（点击即选中并即时保存，不设"确定"按钮）；圆点直径 20vp、内点 10vp；
 * 行高由内容决定（上下各 8vp），标题 14fp，副标题 11fp。
 */
@Component
export struct SettingRadioRow {
  @Prop selected: boolean = false;
  @Prop title: string = '';
  @Prop subtitle: string = '';
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /** 未选中用 `divider`（细描边）、选中用品牌色 —— 与 chip/开关的选中语义一致 */
  private strokeColor(): ResourceColor {
    return this.selected ? this.colors().brandPrimary : this.colors().divider;
  }

  build() {
    Row({ space: 16 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(20)
          .height(20)
          .fill(Color.Transparent)
          .stroke(this.strokeColor())
          .strokeWidth(2)
        if (this.selected) {
          Circle()
            .width(10)
            .height(10)
            .fill(this.colors().brandPrimary)
        }
      }
      .width(40)
      .height(40)

      Column({ space: 2 }) {
        Text(this.title)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textPrimary)
        if (this.subtitle.length > 0) {
          Text(this.subtitle)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().textSecondary)
            .maxLines(2)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(() => {
      this.onTap();
    })
  }
}
