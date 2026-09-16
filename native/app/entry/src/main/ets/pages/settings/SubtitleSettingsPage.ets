import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { SessionStore } from '../../services/SessionStore';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { PageHeader } from '../../components/PageHeader';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';

/**
 * 字幕偏好设置页，对齐 Flutter SubtitleSettingsPage：
 * 字幕卡（服务器配置 + 本地烧录偏好）与字幕外观卡（纯本地）。
 */

interface SelectEntry {
  value: string;
  label: string;
}

const SUBTITLE_LANGUAGES: SelectEntry[] = [
  { value: '', label: '\u65e0\uff08\u8ddf\u968f\u9ed8\u8ba4\uff09' },
  { value: 'chi', label: '\u4e2d\u6587' },
  { value: 'eng', label: '\u82f1\u8bed' },
  { value: 'jpn', label: '\u65e5\u8bed' },
  { value: 'kor', label: '\u97e9\u8bed' },
  { value: 'fra', label: '\u6cd5\u8bed' },
  { value: 'deu', label: '\u5fb7\u8bed' },
  { value: 'spa', label: '\u897f\u73ed\u7259\u8bed' },
  { value: 'rus', label: '\u4fc4\u8bed' },
  { value: 'por', label: '\u8461\u8404\u7259\u8bed' },
  { value: 'ita', label: '\u610f\u5927\u5229\u8bed' },
  { value: 'tha', label: '\u6cf0\u8bed' },
  { value: 'ara', label: '\u963f\u62c9\u4f2f\u8bed' }
];

const SUBTITLE_MODES: SelectEntry[] = [
  { value: 'Default', label: '\u9ed8\u8ba4' },
  { value: 'Smart', label: '\u667a\u80fd\u6a21\u5f0f' },
  { value: 'Always', label: '\u603b\u662f\u663e\u793a' },
  { value: 'OnlyForced', label: '\u4ec5\u5f3a\u5236\u5b57\u5e55' },
  { value: 'None', label: '\u65e0' }
];

const BURN_MODES: SelectEntry[] = [
  { value: '', label: '\u81ea\u52a8' },
  { value: 'onlyimageformats', label: '\u4ec5\u56fe\u50cf\u683c\u5f0f\uff08VobSub\u3001PGS\u3001SUB\uff09' },
  { value: 'allcomplexformats', label: '\u6240\u6709\u590d\u6742\u683c\u5f0f\u5b57\u5e55\uff08ASS\u3001SSA\u3001VobSub\u3001PGS\u3001SUB\u3001IDX\u2026\uff09' },
  { value: 'all', label: '\u5168\u90e8' }
];

const STYLING_OPTIONS: SelectEntry[] = [
  { value: 'Auto', label: '\u81ea\u52a8' },
  { value: 'Custom', label: '\u81ea\u5b9a\u4e49' },
  { value: 'Native', label: '\u539f\u751f' }
];

const TEXT_SIZES: SelectEntry[] = [
  { value: 'smaller', label: '\u66f4\u5c0f' },
  { value: 'small', label: '\u5c0f' },
  { value: '', label: '\u6b63\u5e38' },
  { value: 'large', label: '\u5927' },
  { value: 'larger', label: '\u8f83\u5927\u7684' },
  { value: 'huge', label: '\u7279\u5927' }
];

const TEXT_WEIGHTS: SelectEntry[] = [
  { value: 'normal', label: '\u6b63\u5e38' },
  { value: 'bold', label: '\u7c97\u4f53' }
];

const FONT_OPTIONS: SelectEntry[] = [
  { value: '', label: '\u9ed8\u8ba4' },
  { value: 'monospace', label: '\u6253\u5b57\u673a' },
  { value: 'sans-serif', label: '\u6253\u5370' },
  { value: 'sans-serif-condensed', label: '\u63a7\u5236\u53f0' },
  { value: 'cursive', label: '\u8349\u4e66' },
  { value: 'casual', label: '\u4f11\u95f2' },
  { value: 'small-caps', label: '\u5c0f\u578b\u5927\u5199\u5b57\u6bcd' }
];

const DROP_SHADOWS: SelectEntry[] = [
  { value: 'none', label: '\u65e0' },
  { value: 'raised', label: '\u63d0\u9ad8' },
  { value: 'depressed', label: '\u51f9\u9677' },
  { value: 'uniform', label: '\u8f6e\u5ed3' },
  { value: '', label: '\u9634\u5f71\u6548\u679c' }
];

const TEXT_COLORS: string[] = [
  '#ffffff', '#ffff00', '#ffa500', '#ff0000',
  '#00ff00', '#00ffff', '#0000ff', '#ff00ff'
];

function labelOf(entries: SelectEntry[], value: string): string {
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].value === value) {
      return entries[i].label;
    }
  }
  return entries[0].label;
}

function indexOfValue(entries: SelectEntry[], value: string): number {
  for (let i = 0; i < entries.length; i++) {
    if (entries[i].value === value) {
      return i;
    }
  }
  return 0;
}

@Entry
@Component
export struct SubtitleSettingsPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private saving: boolean = false;
  // 服务器用户配置
  @State private subtitleLanguage: string = '';
  @State private subtitleMode: string = 'Default';
  @State private rememberSubtitleSelections: boolean = true;
  // 本地偏好
  @State private burnMode: string = '';
  @State private renderPgs: boolean = false;
  @State private alwaysBurnWhenTranscoding: boolean = false;
  // 字幕外观（本地）
  @State private styling: string = 'Auto';
  @State private textSize: string = '';
  @State private textWeight: string = 'normal';
  @State private font: string = '';
  @State private textColor: string = '#ffffff';
  @State private dropShadow: string = '';
  @State private verticalPosition: number = -3;

  aboutToAppear(): void {
    this.loadServerConfig();
    this.loadLocalPreferences();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async loadServerConfig(): Promise<void> {
    this.status = UiState.LOADING;
    const raw: string = await JellyfinNative.getUserById(this.currentUserId());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      // 用户配置读取失败时降级为仅本地偏好可编辑
      this.status = UiState.SUCCESS;
      this.errorMsg = '';
      return;
    }
    const cfg: ESObject = JsonUtil.getObject(result.data, 'Configuration');
    if (cfg !== null) {
      this.subtitleLanguage = JsonUtil.getString(cfg, 'SubtitleLanguagePreference', '');
      this.subtitleMode = JsonUtil.getString(cfg, 'SubtitleMode', 'Default');
      this.rememberSubtitleSelections = JsonUtil.getBoolean(cfg, 'RememberSubtitleSelections', true);
    }
    this.status = UiState.SUCCESS;
  }

  private currentUserId(): string {
    const raw: string = JellyfinNative.getSession();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok && result.data !== null) {
      return JsonUtil.getString(result.data, 'userId', JsonUtil.getString(result.data, 'UserId', ''));
    }
    return '';
  }

  private loadLocalPreferences(): void {
    const raw: string = JellyfinNative.getPreferences();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok && result.data !== null) {
      const prefs: ESObject = result.data as ESObject;
      this.burnMode = JsonUtil.getString(prefs, 'subtitleBurnMode', '');
      this.renderPgs = JsonUtil.getBoolean(prefs, 'subtitleRenderPgs', false);
      this.alwaysBurnWhenTranscoding = JsonUtil.getBoolean(prefs, 'alwaysBurnInSubtitleWhenTranscoding', false);
      this.styling = JsonUtil.getString(prefs, 'subtitleStyling', 'Auto');
      this.textSize = JsonUtil.getString(prefs, 'subtitleTextSize', '');
      this.textWeight = JsonUtil.getString(prefs, 'subtitleTextWeight', 'normal');
      this.font = JsonUtil.getString(prefs, 'subtitleFont', '');
      this.textColor = JsonUtil.getString(prefs, 'subtitleTextColor', '#ffffff');
      this.dropShadow = JsonUtil.getString(prefs, 'subtitleDropShadow', '');
      this.verticalPosition = JsonUtil.getNumber(prefs, 'subtitleVerticalPosition', -3);
    }
  }

  private saveLocal(key: string, value: string | number | boolean): void {
    JellyfinNative.setPreference(key, JSON.stringify(value));
    SessionStore.saveSession(JellyfinNative.getSession());
  }

  private async saveServerField(patch: Record<string, Object>): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    const config: Record<string, Object> = {
      'SubtitleLanguagePreference': this.subtitleLanguage,
      'SubtitleMode': this.subtitleMode,
      'RememberSubtitleSelections': this.rememberSubtitleSelections
    };
    const keys: string[] = Object.keys(patch);
    for (let i = 0; i < keys.length; i++) {
      config[keys[i]] = patch[keys[i]];
    }
    const result: NativeResult =
      JellyfinNative.parseResult(await JellyfinNative.updateUserConfiguration(JSON.stringify(config)));
    this.saving = false;
    if (!result.ok) {
      this.errorMsg = result.message.length > 0 ? result.message : '\u4fdd\u5b58\u5931\u8d25';
    }
  }

  /** Flutter PopupMenu 行：标题 + 当前值副标题 + Select */
  @Builder
  PickerRow(title: string, displayValue: string, options: SelectEntry[],
    selectedIndex: number, onPick: (entry: SelectEntry) => void) {
    Row() {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textPrimary)
        Text(displayValue)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textSecondary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Select([{ value: displayValue }] as SelectOption[])
        .fontColor(this.colors().textPrimary)
        .height(36)
        .onSelect((index: number, _v: string) => {
          if (index >= 0 && index < options.length) {
            onPick(options[index]);
          }
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 10, bottom: 10 })
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  SwitchRow(title: string, subtitle: string, isOn: boolean, onChange: (v: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 2 }) {
        Text(title)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textPrimary)
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().textSecondary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: isOn })
        .selectedColor(this.colors().brandPrimary)
        .onChange((v: boolean) => {
          onChange(v);
        })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  /** Flutter _SettingCard 头部 */
  @Builder
  CardHead(iconRes: Resource, title: string) {
    Row({ space: 8 }) {
      SymbolGlyph(iconRes)
        .fontSize(ThemeConstants.ICON_MEDIUM)
        .fontColor([this.colors().brandPrimary])
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().textPrimary)
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 4 })
  }

  build() {
    Column() {
      PageHeader({
        title: '\u5b57\u5e55',
        onBack: () => {
          router.back();
        }
      })

      if (this.status !== UiState.SUCCESS) {
        if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState()
        } else if (this.status === UiState.ERROR) {
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
            actionLabel: '重试',
            onAction: () => {
              this.loadServerConfig();
            }
          })
        } else if (this.status === UiState.EMPTY) {
          EmptyState({ message: '暂无数据' })
        }
      } else {
        Scroll() {
          Column() {
            // 字幕卡
            Column() {
              this.CardHead($r('sys.symbol.doc_text'), '\u5b57\u5e55')
              this.PickerRow('\u9996\u9009\u5b57\u5e55\u8bed\u8a00',
                labelOf(SUBTITLE_LANGUAGES, this.subtitleLanguage), SUBTITLE_LANGUAGES,
                indexOfValue(SUBTITLE_LANGUAGES, this.subtitleLanguage), (entry: SelectEntry) => {
                  this.subtitleLanguage = entry.value;
                  this.saveServerField({ 'SubtitleLanguagePreference': entry.value });
                })
              Divider().color(this.colors().divider).strokeWidth(1)
              Column() {
                this.PickerRow('\u5b57\u5e55\u6a21\u5f0f',
                  labelOf(SUBTITLE_MODES, this.subtitleMode), SUBTITLE_MODES,
                  indexOfValue(SUBTITLE_MODES, this.subtitleMode), (entry: SelectEntry) => {
                    this.subtitleMode = entry.value;
                    this.saveServerField({ 'SubtitleMode': entry.value });
                  })
                Text('\u5b57\u5e55\u5c06\u57fa\u4e8e\u5185\u5d4c\u5143\u6570\u636e\u4e2d\u7684\u300c\u9ed8\u8ba4\u300d\u6807\u5fd7\u548c\u300c\u5f3a\u5236\u300d\u6807\u5fd7\u6765\u8f7d\u5165\u3002\u5f53\u591a\u4e2a\u9009\u9879\u53ef\u7528\u65f6\uff0c\u5c06\u6839\u636e\u8bed\u8a00\u504f\u597d\u51b3\u5b9a\u3002')
                  .fontSize(ThemeConstants.LABEL_SMALL)
                  .fontColor(this.colors().textSecondary)
                  .padding({ left: 16, right: 16 })
                  .width('100%')
              }
              .width('100%')
              .padding({ bottom: 6 })
              Divider().color(this.colors().divider).strokeWidth(1)
              this.SwitchRow('\u8bb0\u4f4f\u5b57\u5e55\u9009\u62e9', '\u81ea\u52a8\u9009\u62e9\u4e0a\u6b21\u4f7f\u7528\u7684\u5b57\u5e55',
                this.rememberSubtitleSelections, (v: boolean) => {
                  this.rememberSubtitleSelections = v;
                  this.saveServerField({ 'RememberSubtitleSelections': v });
                })
              Divider().color(this.colors().divider).strokeWidth(1)
              this.PickerRow('\u70e7\u5f55\u5b57\u5e55',
                labelOf(BURN_MODES, this.burnMode), BURN_MODES,
                indexOfValue(BURN_MODES, this.burnMode), (entry: SelectEntry) => {
                  this.burnMode = entry.value;
                  this.saveLocal('subtitleBurnMode', entry.value);
                })
              Divider().color(this.colors().divider).strokeWidth(1)
              this.SwitchRow('\u5b9e\u9a8c\u6027 PGS \u5b57\u5e55\u6e32\u67d3',
                '\u5728\u5ba2\u6237\u7aef\u6e32\u67d3 PGS \u5b57\u5e55\uff0c\u800c\u4e0d\u662f\u70e7\u5f55\u5b57\u5e55\u3002\u8fd9\u4ee5\u964d\u4f4e\u5ba2\u6237\u7aef\u6e32\u67d3\u6027\u80fd\u4e3a\u4ee3\u4ef7\u6765\u907f\u514d\u670d\u52a1\u5668\u7aef\u8f6c\u7801\u3002',
                this.renderPgs, (v: boolean) => {
                  this.renderPgs = v;
                  this.saveLocal('subtitleRenderPgs', v);
                })
              Divider().color(this.colors().divider).strokeWidth(1)
              this.SwitchRow('\u8f6c\u7801\u65f6\u603b\u662f\u70e7\u5f55\u5b57\u5e55',
                '\u5f53\u8f6c\u7801\u89e6\u53d1\u65f6\u70e7\u5f55\u6240\u6709\u5b57\u5e55\u3002\u8fd9\u6837\u53ef\u4ee5\u4fdd\u8bc1\u8f6c\u7801\u540e\u7684\u5b57\u5e55\u540c\u6b65\uff0c\u4f46\u8f6c\u7801\u901f\u5ea6\u4f1a\u964d\u4f4e\u3002',
                this.alwaysBurnWhenTranscoding, (v: boolean) => {
                  this.alwaysBurnWhenTranscoding = v;
                  this.saveLocal('alwaysBurnInSubtitleWhenTranscoding', v);
                })
            }
            .width('100%')
            .padding({ bottom: 8 })
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(12)
            .clip(true)
            .margin({ left: 16, right: 16, top: 8, bottom: 8 })
            .alignItems(HorizontalAlign.Start)

            // 字幕外观卡
            Column() {
              this.CardHead($r('sys.symbol.textformat'), '\u5b57\u5e55\u5916\u89c2')
              Text('\u8fd9\u4e9b\u8bbe\u7f6e\u4ec5\u5f71\u54cd\u8be5\u8bbe\u5907\u7684\u5b57\u5e55\u663e\u793a\uff0c\u4e0d\u9002\u7528\u4e8e\u56fe\u5f62\u5b57\u5e55\u6216\u5d4c\u5165\u5176\u81ea\u8eab\u6837\u5f0f\u7684 ASS/SSA \u5b57\u5e55\u3002')
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().textSecondary)
                .padding({ left: 16, right: 16, top: 4, bottom: 8 })
                .width('100%')
              this.PickerRow('\u5b57\u5e55\u6837\u5f0f',
                labelOf(STYLING_OPTIONS, this.styling), STYLING_OPTIONS,
                indexOfValue(STYLING_OPTIONS, this.styling), (entry: SelectEntry) => {
                  this.styling = entry.value;
                  this.saveLocal('subtitleStyling', entry.value);
                })
              Divider().color(this.colors().divider).strokeWidth(1)
              this.PickerRow('\u6587\u672c\u5927\u5c0f',
                labelOf(TEXT_SIZES, this.textSize), TEXT_SIZES,
                indexOfValue(TEXT_SIZES, this.textSize), (entry: SelectEntry) => {
                  this.textSize = entry.value;
                  this.saveLocal('subtitleTextSize', entry.value);
                })
              Divider().color(this.colors().divider).strokeWidth(1)
              this.PickerRow('\u6587\u672c\u7c97\u7ec6',
                labelOf(TEXT_WEIGHTS, this.textWeight), TEXT_WEIGHTS,
                indexOfValue(TEXT_WEIGHTS, this.textWeight), (entry: SelectEntry) => {
                  this.textWeight = entry.value;
                  this.saveLocal('subtitleTextWeight', entry.value);
                })
              Divider().color(this.colors().divider).strokeWidth(1)
              this.PickerRow('\u5b57\u4f53',
                labelOf(FONT_OPTIONS, this.font), FONT_OPTIONS,
                indexOfValue(FONT_OPTIONS, this.font), (entry: SelectEntry) => {
                  this.font = entry.value;
                  this.saveLocal('subtitleFont', entry.value);
                })
              Divider().color(this.colors().divider).strokeWidth(1)

              // 文本颜色色块
              Column({ space: 8 }) {
                Text('\u6587\u672c\u989c\u8272')
                  .fontSize(ThemeConstants.BODY_MEDIUM)
                  .fontColor(this.colors().textPrimary)
                Flex({ wrap: FlexWrap.Wrap }) {
                  ForEach(TEXT_COLORS, (color: string) => {
                    Column()
                      .width(32)
                      .height(32)
                      .backgroundColor(color)
                      .borderRadius(16)
                      .border({
                        width: this.textColor === color ? 3 : 1,
                        color: this.textColor === color ? this.colors().brandPrimary : this.colors().divider
                      })
                      .margin({ right: 8, bottom: 8 })
                      .onClick(() => {
                        this.textColor = color;
                        this.saveLocal('subtitleTextColor', color);
                      })
                  }, (color: string) => color)
                }
                .width('100%')
                Text(`\u5f53\u524d\u503c\uff1a${this.textColor}`)
                  .fontSize(ThemeConstants.LABEL_SMALL)
                  .fontColor(this.colors().textSecondary)
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 12, bottom: 12 })
              .alignItems(HorizontalAlign.Start)
              Divider().color(this.colors().divider).strokeWidth(1)

              this.PickerRow('\u5b57\u4f53\u63cf\u8fb9',
                labelOf(DROP_SHADOWS, this.dropShadow), DROP_SHADOWS,
                indexOfValue(DROP_SHADOWS, this.dropShadow), (entry: SelectEntry) => {
                  this.dropShadow = entry.value;
                  this.saveLocal('subtitleDropShadow', entry.value);
                })
              Divider().color(this.colors().divider).strokeWidth(1)

              // 垂直位置 Slider
              Column({ space: 8 }) {
                Text(`\u5782\u76f4\u4f4d\u7f6e\uff1a${Math.round(this.verticalPosition)}`)
                  .fontSize(ThemeConstants.BODY_MEDIUM)
                  .fontColor(this.colors().textPrimary)
                Slider({
                  value: Math.max(-16, Math.min(16, Math.round(this.verticalPosition))),
                  min: -16,
                  max: 16,
                  step: 1,
                  style: SliderStyle.OutSet
                })
                  .width('100%')
                  .selectedColor(this.colors().brandPrimary)
                  .trackColor(this.colors().surfacePressed)
                  .blockSize({ width: 20, height: 20 })
                  .onChange((value: number) => {
                    this.verticalPosition = Math.round(value);
                  })
                Text('\u6587\u5b57\u51fa\u73b0\u7684\u884c\u53f7\u3002\u6b63\u6570\u8868\u793a\u7531\u4e0a\u5230\u4e0b\uff0c\u8d1f\u6570\u8868\u793a\u7531\u4e0b\u5230\u4e0a\u3002')
                  .fontSize(ThemeConstants.LABEL_SMALL)
                  .fontColor(this.colors().textSecondary)
                Button('\u4fdd\u5b58\u5782\u76f4\u4f4d\u7f6e')
                  .width('100%')
                  .height(40)
                  .backgroundColor(this.colors().brandPrimary)
                  .fontColor(this.colors().onBrand)
                  .onClick(() => {
                    this.saveLocal('subtitleVerticalPosition', this.verticalPosition);
                  })
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 8, bottom: 12 })
              .alignItems(HorizontalAlign.Start)
            }
            .width('100%')
            .padding({ bottom: 8 })
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(12)
            .clip(true)
            .margin({ left: 16, right: 16, bottom: 8 })
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
    .backgroundColor(this.colors().pageBackground)
  }
}
