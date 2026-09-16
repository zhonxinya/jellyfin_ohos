import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

export type AppIconVariant = 'ghost' | 'soft' | 'primary' | 'surface';

/**
 * 圆形图标按钮 —— 对齐 mybooks_os 的 IconCircleButton。
 *
 * 用法约定（参考项目规则）：
 * - 顶栏返回/搜索/更多等图标入口统一用 40vp 圆形按钮（`ButtonType.Circle`）；
 * - 按下反馈只用 `stateStyles.pressed` 换底色，按钮本身 `stateEffect: false`，不做缩放/水波纹；
 * - 阴影只出现在 `surface` 变体上（浮起的小圆按钮），其余变体显式声明零阴影。
 *
 * 与参考项目的差异：颜色来自运行时主题（`AppViewModel.colors()`），
 * 以便保留本工程的应用内明暗切换与强调色。
 */
@Component
export struct AppIconButton {
  @Prop icon: Resource = $r('sys.symbol.circle');
  @Prop variant: AppIconVariant = 'ghost';
  @Prop iconSize: number = 20;
  @Prop buttonSize: number = ThemeConstants.ICON_BUTTON_SIZE;
  /** 显式覆盖图标色（不传则按 variant 解析） */
  @Prop iconColorOverride: string = '';
  /** 显式覆盖底色（不传则按 variant 解析） */
  @Prop backgroundOverride: string = '';
  onTap: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private resolvedIconColor(): string {
    if (this.iconColorOverride.length > 0) {
      return this.iconColorOverride;
    }
    const c: ThemeColors = this.colors();
    if (this.variant === 'primary') {
      return c.onBrand;
    }
    if (this.variant === 'soft') {
      return c.brandPrimary;
    }
    return c.textPrimary;
  }

  private resolvedBackground(): string {
    if (this.backgroundOverride.length > 0) {
      return this.backgroundOverride;
    }
    const c: ThemeColors = this.colors();
    if (this.variant === 'primary') {
      return c.brandPrimary;
    }
    if (this.variant === 'soft') {
      return c.brandPrimaryLight;
    }
    if (this.variant === 'surface') {
      return c.cardBackground;
    }
    return '#00000000';
  }

  private pressedBackground(): string {
    const c: ThemeColors = this.colors();
    if (this.variant === 'primary') {
      return c.brandPrimaryPressed;
    }
    if (this.variant === 'soft') {
      return c.brandPrimaryLightPressed;
    }
    return c.surfacePressed;
  }

  build() {
    Button({ type: ButtonType.Circle, stateEffect: false }) {
      SymbolGlyph(this.icon)
        .fontSize(this.iconSize)
        .fontColor([this.resolvedIconColor()])
    }
    .width(this.buttonSize)
    .height(this.buttonSize)
    .padding(0)
    .backgroundColor(this.resolvedBackground())
    .shadow(this.variant === 'surface'
      ? { radius: 8, color: '#14000000', offsetX: 0, offsetY: 2 }
      : { radius: 0, color: Color.Transparent, offsetX: 0, offsetY: 0 })
    .stateStyles({
      pressed: {
        .backgroundColor(this.pressedBackground())
      }
    })
    .onClick(() => {
      // 诊断探针（临时）：记录图标按钮确实收到了点击。
      // 用于排查"播放页锁定按钮用 click/doubleClick/longClick 都点不中"：
      // 文件有内容 ⇒ 事件送达（问题在状态逻辑）；为空 ⇒ 事件没到按钮（层级/容器吞掉）。
      // 定位完成后移除或改为调试开关。
      try {
        const ctx = getContext(this) as common.UIAbilityContext;
        const f = fs.openSync(`${ctx.cacheDir}/ui_tap_probe.txt`,
          fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.APPEND);
        fs.writeSync(f.fd, 'iconTap\n');
        fs.closeSync(f);
      } catch (err) {
        // 诊断写入失败不影响交互
      }
      this.onTap();
    });
  }
}
