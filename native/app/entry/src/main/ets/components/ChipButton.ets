import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 可选标签 —— 对齐 mybooks_ohos 的 ChipButton。
 *
 * 规格：高 34vp；圆角 10vp（写在 border 里）；左右各 14vp 内边距；
 * 选中 = 品牌色实底 + `on_brand` 文字 + 微弱品牌投影；未选中 = 卡片底 + `divider` 描边；
 * 按下态：选中 `brand_primary_pressed`，未选中 `chip_background_pressed`。
 * 用于筛选、类型切换、详情页的阅读状态，以及媒体库卡片上的一排操作按钮。
 *
 * 两个可选扩展（默认值保持原样，老调用点行为不变）：
 * - `icon`：前置系统符号；
 * - `tone='danger'`：危险操作配色（错误浅底 + on_brand 文字 + 按下态）。
 */
@Component
export struct ChipButton {
  @Prop label: string = '';
  @Prop selected: boolean = false;
  /**
   * 可选的触达高度覆盖（vp）。0 表示沿用 `ThemeConstants.CHIP_HEIGHT`。
   *
   * 为什么是"可选覆盖"而不是直接改全局 token：34vp 低于 48vp 的触达建议，
   * 但该 token 被多个页面共用，全局改动会牵动所有筛选/标签页布局（无法逐一目视验证）。
   * 播放页这类"单手操作、误触代价高"的场合按需传更大值，风险可控。
   */
  @Prop heightOverride: number = 0;
  /** 可选的前置图标（系统符号资源）；不传就只显示文字 */
  icon: Resource | null = null;
  /**
   * 语义色：`neutral` 普通操作，`danger` 不可逆操作（删除等）。
   *
   * 为什么做成枚举而不是让调用方自己传颜色：媒体库卡片一行里有 5 个操作胶囊
   * （路径 / 媒体库选项 / 扫描 / 重命名 / 删除），只有"删除"该是危险色；
   * 颜色散在调用方就会各自漂移 —— 改之前那几个胶囊就是各写底色的裸 Text。
   */
  @Prop tone: string = 'neutral';
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private isDanger(): boolean {
    return this.tone === 'danger';
  }

  /** 注意不能叫 `background()`：那是组件自带的属性方法，同名会与方法签名冲突（编译不过） */
  private chipBackground(): string {
    if (this.isDanger()) {
      return this.colors().errorLight;
    }
    return this.selected ? this.colors().brandPrimary : this.colors().cardBackground;
  }

  private foreground(): string {
    if (this.isDanger()) {
      return this.colors().onBrand;
    }
    return this.selected ? this.colors().onBrand : this.colors().textPrimary;
  }

  build() {
    Button({ type: ButtonType.Normal, stateEffect: false }) {
      Row({ space: 4 }) {
        if (this.icon !== null) {
          SymbolGlyph(this.icon)
            .fontSize(ThemeConstants.ICON_SMALL)
            .fontColor([this.foreground()])
        }
        Text(this.label)
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontWeight(this.selected ? FontWeight.Medium : FontWeight.Regular)
          .fontColor(this.foreground())
          .maxLines(1)
      }
      .alignItems(VerticalAlign.Center)
    }
    .height(this.heightOverride > 0 ? this.heightOverride : ThemeConstants.CHIP_HEIGHT)
    .padding({ left: 14, right: 14 })
    .backgroundColor(this.chipBackground())
    .border({
      width: 1,
      color: this.isDanger()
        ? this.colors().errorLight
        : (this.selected ? this.colors().brandPrimary : this.colors().divider),
      radius: ThemeConstants.CHIP_RADIUS
    })
    .shadow(this.selected && !this.isDanger()
      ? { radius: 6, color: '#26007DFF', offsetX: 0, offsetY: 2 }
      : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .stateStyles({
      pressed: {
        .backgroundColor(this.isDanger()
          ? this.colors().errorLightPressed
          : (this.selected
            ? this.colors().brandPrimaryPressed
            : this.colors().chipBackgroundPressed))
      }
    })
    .onClick(() => {
      this.onTap();
    });
  }
}
