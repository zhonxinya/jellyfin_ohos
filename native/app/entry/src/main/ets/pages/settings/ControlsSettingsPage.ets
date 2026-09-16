import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { SessionStore } from '../../services/SessionStore';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { PageHeader } from '../../components/PageHeader';
import { JsonUtil } from '../../common/JsonUtil';

/**
 * 操控设置页，对齐 Flutter ControlsSettingsPage：
 * 启用游戏手柄 + 启用平滑滚动，本地偏好，显式保存按钮。
 */
@Entry
@Component
export struct ControlsSettingsPage {
  @State private gamepad: boolean = false;
  @State private smoothScroll: boolean = true;
  @State private loading: boolean = true;
  @State private saving: boolean = false;
  @State private message: string = '';
  @State private messageError: boolean = false;

  aboutToAppear(): void {
    this.load();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private load(): void {
    this.loading = true;
    const raw: string = JellyfinNative.getPreferences();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.gamepad = false;
    this.smoothScroll = true;
    if (result.ok && result.data !== null) {
      const prefs: ESObject = result.data as ESObject;
      this.gamepad = JsonUtil.getBoolean(prefs, 'gamepadEnabled', false);
      this.smoothScroll = JsonUtil.getBoolean(prefs, 'smoothScrollEnabled', true);
    }
    this.loading = false;
  }

  private save(): void {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.message = '';
    JellyfinNative.setPreference('gamepadEnabled', JSON.stringify(this.gamepad));
    JellyfinNative.setPreference('smoothScrollEnabled', JSON.stringify(this.smoothScroll));
    SessionStore.saveSession(JellyfinNative.getSession());
    this.saving = false;
    this.message = '\u8bbe\u7f6e\u5df2\u4fdd\u5b58';
    this.messageError = false;
  }

  /** Flutter SwitchListTile：secondary 图标 + 标题 + 副标题 + 尾部开关 */
  @Builder
  SwitchRow(iconRes: Resource, title: string, subtitle: string, isOn: boolean,
    onChange: (v: boolean) => void) {
    Row({ space: 12 }) {
      SymbolGlyph(iconRes)
        .fontSize(20)
        .fontColor([this.colors().onSurfaceVariant])
        .width(28)
      Column({ space: 2 }) {
        Text(title)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().onSurface)
        Text(subtitle)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().onSurfaceVariant)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(this.colors().primary)
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Column() {
      PageHeader({
        title: '\u64cd\u63a7',
        onBack: () => {
          router.back();
        }
      })

      if (this.loading) {
        LoadingProgress()
          .width(40)
          .height(40)
          .color(this.colors().primary)
          .margin({ top: 120 })
      } else {
        Scroll() {
          Column() {
            Column() {
              Row({ space: 8 }) {
                SymbolGlyph($r('sys.symbol.gamecontroller'))
                  .fontSize(18)
                  .fontColor([this.colors().primary])
                Text('\u64cd\u63a7')
                  .fontSize(ThemeConstants.TITLE_SMALL)
                  .fontWeight(FontWeight.Bold)
                  .fontColor(this.colors().onSurface)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 4 })

              this.SwitchRow($r('sys.symbol.gamecontroller'), '\u542f\u7528\u6e38\u620f\u624b\u67c4',
                '\u76d1\u542c\u6765\u81ea\u4efb\u4f55\u8fde\u63a5\u7684\u63a7\u5236\u5668\u7684\u8f93\u5165\n\u6539\u52a8\u5c06\u5728\u624b\u52a8\u91cd\u542f\u5ba2\u6237\u7aef\u540e\u751f\u6548',
                this.gamepad, (v: boolean) => {
                  this.gamepad = v;
                })
              Divider().color(this.colors().outline).strokeWidth(1)
              this.SwitchRow($r('sys.symbol.swipe'), '\u542f\u7528\u5e73\u6ed1\u6eda\u52a8',
                '\u5728\u5a92\u4f53\u5217\u8868\u4e2d\u4f7f\u7528\u5e73\u6ed1\u6eda\u52a8\u6548\u679c',
                this.smoothScroll, (v: boolean) => {
                  this.smoothScroll = v;
                })

              Button() {
                Row() {
                  if (this.saving) {
                    LoadingProgress()
                      .width(16)
                      .height(16)
                      .color(this.colors().onPrimary)
                  } else {
                    SymbolGlyph($r('sys.symbol.save'))
                      .fontSize(18)
                      .fontColor([this.colors().onPrimary])
                  }
                  Text(this.saving ? '\u4fdd\u5b58\u4e2d...' : '\u4fdd\u5b58')
                    .fontSize(ThemeConstants.BODY_MEDIUM)
                    .fontColor(this.colors().onPrimary)
                    .margin({ left: 8 })
                }
              }
              .width('100%')
              .height(40)
              .backgroundColor(this.saving ? this.colors().onSurfaceVariant : this.colors().primary)
              .enabled(!this.saving)
              .margin({ top: 12 })
              .onClick(() => {
                this.save();
              })
              .padding({ left: 16, right: 16 })

              if (this.message.length > 0) {
                Text(this.message)
                  .fontSize(ThemeConstants.LABEL_SMALL)
                  .fontColor(this.messageError ? this.colors().error : this.colors().success)
                  .margin({ top: 12 })
              }
            }
            .width('100%')
            .padding({ bottom: 12 })
            .backgroundColor(this.colors().surface)
            .borderRadius(12)
            .clip(true)
            .margin({ left: 16, right: 16, top: 8, bottom: 8 })
            .alignItems(HorizontalAlign.Start)
          }
          .width('100%')
          .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
          .padding({ bottom: 32 })
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
    .backgroundColor(this.colors().background)
  }
}
