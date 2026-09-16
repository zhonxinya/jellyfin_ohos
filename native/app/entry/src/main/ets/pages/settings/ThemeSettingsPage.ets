import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { SessionStore } from '../../services/SessionStore';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { PageHeader } from '../../components/PageHeader';
import { JsonUtil } from '../../common/JsonUtil';

/**
 * 主题与显示设置页，对齐 Flutter ThemeSettingsPage：
 * 外观模式 + 强调色两组 RadioListTile，选中即时保存。
 */

interface ThemeOption {
  value: string;
  label: string;
  subtitle: string;
}

const MODE_OPTIONS: ThemeOption[] = [
  { value: 'system', label: '\u8ddf\u968f\u7cfb\u7edf', subtitle: '\u8ddf\u968f\u8bbe\u5907\u7cfb\u7edf\u8bbe\u7f6e' },
  { value: 'light', label: '\u6d45\u8272', subtitle: '\u4f7f\u7528\u6d45\u8272\u754c\u9762' },
  { value: 'dark', label: '\u6df1\u8272', subtitle: '\u4f7f\u7528\u6df1\u8272\u754c\u9762' }
];

interface AccentOption {
  value: string;
  label: string;
  color: string;
}

const ACCENT_OPTIONS: AccentOption[] = [
  { value: 'ocean', label: '\u6d77\u6d0b\u84dd', color: '#00A4DC' },
  { value: 'jade', label: '\u7fe1\u7fe0\u7eff', color: '#00897B' },
  { value: 'amber', label: '\u7425\u73c0', color: '#F59E0B' },
  { value: 'coral', label: '\u73ca\u7469', color: '#E76F51' }
];

/** 持久化偏好并落盘 session（session JSON 携带 preferences） */
function persistPreference(key: string, value: string): void {
  JellyfinNative.setPreference(key, JSON.stringify(value));
  SessionStore.saveSession(JellyfinNative.getSession());
}

@Entry
@Component
export struct ThemeSettingsPage {
  @State private themeMode: string = 'system';
  @State private accent: string = 'ocean';
  @State private loaded: boolean = false;
  @State private themeVersion: number = 0;

  aboutToAppear(): void {
    const vm: AppViewModel = AppViewModel.getInstance();
    this.themeMode = vm.themeMode;
    this.accent = vm.accent;
    this.themeVersion = vm.themeVersion;
    this.loaded = true;
  }

  private colors(): ThemeColors {
    this.themeVersion;
    return AppViewModel.getInstance().colors();
  }

  private reloadTheme(): void {
    AppViewModel.getInstance().setThemeMode(this.themeMode);
    AppViewModel.getInstance().setAccent(this.accent);
    this.themeVersion = AppViewModel.getInstance().themeVersion;
  }

  private selectMode(value: string): void {
    if (value === this.themeMode) {
      return;
    }
    this.themeMode = value;
    this.reloadTheme();
    persistPreference('themeMode', value);
  }

  private selectAccent(value: string): void {
    if (value === this.accent) {
      return;
    }
    this.accent = value;
    this.reloadTheme();
    persistPreference('accent', value);
  }

  /** Flutter RadioListTile：dense、contentPadding h16、选中项强调 */
  @Builder
  RadioRow(selected: boolean, title: string, subtitle: string, onTap: () => void) {
    Row({ space: 16 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(20)
          .height(20)
          .fill(Color.Transparent)
          .stroke(this.selectedStroke(selected))
          .strokeWidth(2)
        if (selected) {
          Circle()
            .width(10)
            .height(10)
            .fill(this.colors().primary)
        }
      }
      .width(40)
      .height(40)
      Column({ space: 2 }) {
        Text(title)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().onSurface)
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onSurfaceVariant)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 8, bottom: 8 })
    .onClick(() => {
      onTap();
    })
  }

  private selectedStroke(selected: boolean): ResourceColor {
    return selected ? this.colors().primary : this.colors().onSurfaceVariant;
  }

  /** Flutter _SectionHeader：icon18 primary + 14 bold 标题 + 12 副标题 */
  @Builder
  SectionHead(iconRes: Resource, title: string, subtitle: string) {
    Row({ space: 8 }) {
      SymbolGlyph(iconRes)
        .fontSize(18)
        .fontColor([this.colors().primary])
      Column({ space: 2 }) {
        Text(title)
          .fontSize(ThemeConstants.TITLE_SMALL)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().onSurface)
        Text(subtitle)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().onSurfaceVariant)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 4 })
  }

  build() {
    Column() {
      PageHeader({
        title: '\u4e3b\u9898\u4e0e\u663e\u793a',
        onBack: () => {
          router.back();
        }
      })

      if (!this.loaded) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color(this.colors().primary)
          .margin({ top: 120 })
      } else {
        Scroll() {
          Column() {
            this.SectionHead($r('sys.symbol.paintpalette'), '\u5916\u89c2\u6a21\u5f0f', '\u9009\u62e9\u5e94\u7528\u7684\u6574\u4f53\u4eae\u5ea6\u98ce\u683c')
            Column() {
              ForEach(MODE_OPTIONS, (mode: ThemeOption) => {
                this.RadioRow(this.themeMode === mode.value, mode.label, mode.subtitle, () => {
                  this.selectMode(mode.value);
                })
              }, (mode: ThemeOption) => mode.value)
            }
            .width('100%')
            .backgroundColor(this.colors().surface)
            .borderRadius(12)
            .clip(true)
            .margin({ left: 16, right: 16 })

            this.SectionHead($r('sys.symbol.circle_grid_2x2'), '\u5f3a\u8c03\u8272', '\u9009\u62e9\u5e94\u7528\u7684\u6807\u8bc6\u8272\u5f69')
            Column() {
              ForEach(ACCENT_OPTIONS, (accent: AccentOption) => {
                this.RadioRow(this.accent === accent.value, accent.label,
                  this.accent === accent.value ? '\u5df2\u9009\u62e9' : '', () => {
                    this.selectAccent(accent.value);
                  })
              }, (accent: AccentOption) => accent.value)
            }
            .width('100%')
            .backgroundColor(this.colors().surface)
            .borderRadius(12)
            .clip(true)
            .margin({ left: 16, right: 16 })
          }
          .width('100%')
          .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
          .padding({ top: 8, bottom: 32 })
          .alignItems(HorizontalAlign.Center)
        }
        .width('100%')
        .height('100%')
        .align(Alignment.Top)
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().surface)
  }
}
