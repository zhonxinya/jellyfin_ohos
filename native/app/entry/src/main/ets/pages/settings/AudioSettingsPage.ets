import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import {
  LibraryLocalization,
  LocalizationChoice,
  languageDisplayName,
  parseLocalization
} from '../../common/LibraryModels';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/**
 * 设置 → 音频。
 *
 * 对应 `UserConfiguration` 里的三个字段（用户级偏好，`POST /Users/{userId}/Configuration`）：
 * - `AudioLanguagePreference`   优先选择的音轨语言（三字母 ISO 码，与元数据语言同一套）
 * - `PlayDefaultAudioTrack`     找不到匹配语言时是否播放默认音轨
 * - `RememberAudioSelections`   记住上次为这部影片选的音轨
 *
 * 语言列表来自 `/Localization/Cultures`；值必须取 `ThreeLetterISOLanguageName`
 * （服务端 `MediaSourceManager` 就是拿三字母码去比 `ThreeLetterISOLanguageNames` 的）。
 */
@Entry
@Component
struct AudioSettingsPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  @State private languageCode: string = '';
  @State private playDefaultTrack: boolean = true;
  @State private rememberSelections: boolean = true;

  @State private localization: LibraryLocalization = new LibraryLocalization();
  @State private sheet: string = '';
  @State private sheetFilter: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.load();
  }

  private userId(): string {
    const raw: string = JellyfinNative.getSession();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok && result.data !== null) {
      return JsonUtil.getString(result.data as ESObject, 'userId',
        JsonUtil.getString(result.data as ESObject, 'UserId', ''));
    }
    return '';
  }

  private async load(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';

    const userRaw: string = await JellyfinNative.getUserById(this.userId());
    const userResult: NativeResult = JellyfinNative.parseResult(userRaw);
    if (!userResult.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = userResult.message.length > 0 ? userResult.message : '读取用户配置失败';
      return;
    }
    const config: ESObject | null = JsonUtil.getObject(userResult.data, 'Configuration');
    this.languageCode = JsonUtil.getString(config, 'AudioLanguagePreference', '');
    this.playDefaultTrack = JsonUtil.getBoolean(config, 'PlayDefaultAudioTrack', true);
    this.rememberSelections = JsonUtil.getBoolean(config, 'RememberAudioSelections', true);

    // 语言列表拿不到也要能用（只是选择器里只剩当前值），所以失败不阻断页面
    const localizationResult: NativeResult =
      JellyfinNative.parseResult(await JellyfinNative.libraryLocalization());
    if (localizationResult.ok) {
      this.localization = parseLocalization(localizationResult.data);
    }
    this.status = UiState.SUCCESS;
  }

  private async save(patch: Record<string, Object>, okMessage: string): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.patchUserConfiguration(JSON.stringify(patch)));
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = okMessage;
  }

  private savedLanguage(): string {
    return languageDisplayName(this.localization, this.languageCode);
  }

  private toggleDefaultTrack(value: boolean): void {
    this.playDefaultTrack = value;
    const patch: Record<string, Object> = {};
    patch['PlayDefaultAudioTrack'] = value;
    this.save(patch, '已保存：优先播放默认音轨');
  }

  private toggleRemember(value: boolean): void {
    this.rememberSelections = value;
    const patch: Record<string, Object> = {};
    patch['RememberAudioSelections'] = value;
    this.save(patch, '已保存：记住音频选择');
  }

  private pickLanguage(choice: LocalizationChoice | null): void {
    this.languageCode = choice === null ? '' : choice.name;
    const patch: Record<string, Object> = {};
    patch['AudioLanguagePreference'] = this.languageCode;
    this.sheet = '';
    this.sheetFilter = '';
    this.save(patch, `已保存：优先音轨语言为 ${this.savedLanguage()}`);
  }

  private static filtered(items: LocalizationChoice[], filter: string): LocalizationChoice[] {
    const needle: string = filter.trim().toLowerCase();
    if (needle.length === 0) {
      return items;
    }
    const out: LocalizationChoice[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].name.toLowerCase().indexOf(needle) >= 0
        || items[i].displayName.toLowerCase().indexOf(needle) >= 0) {
        out.push(items[i]);
      }
    }
    return out;
  }

  @Builder
  LanguageSheet() {
    Column({ space: 10 }) {
      Text('优先音轨语言')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text('播放时优先选这个语言的音轨；找不到时才轮到默认音轨设置。')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      TextInput({ text: this.sheetFilter, placeholder: '筛选语言' })
        .width('100%')
        .onChange((value: string) => {
          this.sheetFilter = value;
        })
      List({ space: 2 }) {
        ListItem() {
          Row() {
            Text('不指定（跟随默认音轨）')
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .layoutWeight(1)
            if (this.languageCode.length === 0) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(ThemeConstants.ICON_SMALL)
                .fontColor([this.colors().brandPrimary])
            }
          }
          .width('100%')
          .padding({ top: 10, bottom: 10 })
          .onClick(() => {
            this.pickLanguage(null);
          })
        }
        ForEach(AudioSettingsPage.filtered(this.localization.languages, this.sheetFilter),
          (choice: LocalizationChoice) => {
            ListItem() {
              Row() {
                Text(choice.displayName)
                  .fontSize(ThemeConstants.BODY_MEDIUM)
                  .fontColor(this.colors().textPrimary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(choice.name)
                  .fontSize(ThemeConstants.META_SMALL)
                  .fontColor(this.colors().textTertiary)
                if (choice.name === this.languageCode) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(ThemeConstants.ICON_SMALL)
                    .fontColor([this.colors().brandPrimary])
                    .margin({ left: 8 })
                }
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .onClick(() => {
                this.pickLanguage(choice);
              })
            }
          }, (choice: LocalizationChoice) => choice.name)
      }
      .width('100%')
      .height(300)
      .scrollBar(BarState.Auto)
      Button('关闭')
        .width('100%')
        .height(44)
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
        .onClick(() => {
          this.sheet = '';
          this.sheetFilter = '';
        })
    }
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .width('88%')
    .onClick(() => {
    })
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '音频',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('账号级偏好（跟随账号同步到其它客户端）')
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
            if (this.actionMessage.length > 0) {
              Text(this.actionMessage)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.actionOk ? this.colors().success : this.colors().error)
                .maxLines(2)
            } else {
              Text(this.saving ? '保存中...' : '改动即时保存到服务器')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textSecondary)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 4 })
        }

        if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState()
        } else if (this.status === UiState.ERROR) {
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
            actionLabel: '重试',
            onAction: () => {
              this.load();
            }
          })
        } else {
          Scroll() {
            Column() {
              SectionCard({ title: '音轨选择', icon: $r('sys.symbol.speaker_wave_2'),
                showHeaderIcon: true }) {
                Column() {
                  SettingCell({
                    title: '优先音轨语言',
                    subtitle: '播放时优先选这个语言的音轨',
                    valueText: this.savedLanguage(),
                    showChevron: true,
                    onTap: () => {
                      this.sheetFilter = '';
                      this.sheet = 'language';
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '优先播放默认音轨',
                    subtitle: '找不到匹配语言的音轨时，用影片自带的默认音轨（关掉则用第一条）',
                    showToggle: true,
                    toggleOn: this.playDefaultTrack,
                    onToggle: (value: boolean) => {
                      this.toggleDefaultTrack(value);
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '记住音频选择',
                    subtitle: '记住你为这部影片选过的音轨，下次直接用它',
                    showToggle: true,
                    toggleOn: this.rememberSelections,
                    onToggle: (value: boolean) => {
                      this.toggleRemember(value);
                    }
                  })
                }
                .width('100%')
              }

              Text('这些设置保存在你的账号上，换设备登录同一账号也会生效。')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textTertiary)
                .width('100%')
                .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 4 })

              Blank().height(60)
            }
            .width('100%')
            .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.sheet.length > 0) {
        Column() {
          this.LanguageSheet()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.sheet = '';
          this.sheetFilter = '';
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
