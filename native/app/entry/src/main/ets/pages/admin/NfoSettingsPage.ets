import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/**
 * 服务端那段配置的 key。
 *
 * ⚠️ 是 `xbmcmetadata` 而不是 `nfo`：实测 `GET /System/Configuration/nfo` 返回 404，
 * 只有 `xbmcmetadata` 能拿到 `XbmcMetadataOptions`。（本页原来在「控制台」里指向
 * `/System/Configuration/nfo`，点进去只有一句报错。）
 */
const NFO_CONFIG_KEY = 'xbmcmetadata';

/** 发布日期格式的可选项（写进 nfo 的 `<premiered>` 等字段用哪种格式） */
class DateFormatChoice {
  value: string;
  label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

const DATE_FORMATS: DateFormatChoice[] = [
  new DateFormatChoice('yyyy-MM-dd', 'yyyy-MM-dd（如 2024-03-07）'),
  new DateFormatChoice('yyyy-MM-ddTHH:mm:ssZ', 'ISO 8601（如 2024-03-07T00:00:00Z）'),
  new DateFormatChoice('yyyyMMdd', 'yyyyMMdd（如 20240307）')
];

/**
 * 设置 → NFO 设置。
 *
 * 对应 jellyfin-web 的 Dashboard → NFO Settings，落到服务端的
 * `XbmcMetadataOptions`（key = `xbmcmetadata`）：
 * - `ReleaseDateFormat`：写进 nfo 的日期格式；
 * - `SaveImagePathsInNfo`：把图片路径也写进 nfo；
 * - `EnablePathSubstitution`：写入 nfo 时应用服务器的路径替换规则；
 * - `EnableExtraThumbsDuplication`：额外缩略图复制（`-thumb` 与 `-landscape` 同时生成）。
 *
 * `POST /System/Configuration/{key}` 只替换这一段配置（不是整份 ServerConfiguration），
 * 所以这里同样只回传服务端下发的那几个字段。
 */
@Entry
@Component
struct NfoSettingsPage {
  /** 服务端下发的这一段配置（保存时的底本，未知字段原样带回） */
  private base: ESObject = {} as ESObject;
  private originalJson: string = '';

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  @State private dateFormat: string = 'yyyy-MM-dd';
  @State private saveImagePaths: boolean = true;
  @State private pathSubstitution: boolean = true;
  @State private extraThumbs: boolean = false;
  @State private sheet: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.libraryNamedConfig(NFO_CONFIG_KEY);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取 NFO 设置失败';
      return;
    }
    this.originalJson = JsonUtil.toPretty(result.data);
    this.base = result.data;
    this.dateFormat = JsonUtil.getString(this.base, 'ReleaseDateFormat', 'yyyy-MM-dd');
    this.saveImagePaths = JsonUtil.getBoolean(this.base, 'SaveImagePathsInNfo', true);
    this.pathSubstitution = JsonUtil.getBoolean(this.base, 'EnablePathSubstitution', true);
    this.extraThumbs = JsonUtil.getBoolean(this.base, 'EnableExtraThumbsDuplication', false);
    this.status = UiState.SUCCESS;
  }

  private buildPayload(): string {
    // 以服务端对象为底：这一段的未知字段（或旧/新版本多出来的字段）原样带回
    const draft: ESObject = JSON.parse(JSON.stringify(this.base)) as ESObject;
    const bag: Record<string, Object> = draft as Record<string, Object>;
    bag['ReleaseDateFormat'] = this.dateFormat;
    bag['SaveImagePathsInNfo'] = this.saveImagePaths;
    bag['EnablePathSubstitution'] = this.pathSubstitution;
    bag['EnableExtraThumbsDuplication'] = this.extraThumbs;
    return JsonUtil.toPretty(draft);
  }

  private isDirty(): boolean {
    return this.buildPayload() !== this.originalJson;
  }

  private touch(): void {
    this.actionMessage = '';
  }

  private async save(): Promise<void> {
    if (this.saving || !this.isDirty()) {
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.libraryUpdateNamedConfig(NFO_CONFIG_KEY, this.buildPayload()));
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = 'NFO 设置已保存';
    this.load();
  }

  @Builder
  DateFormatSheet() {
    Column({ space: 10 }) {
      Text('发布日期格式')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text('写进 nfo（premiered / releasedate）时用的日期格式。')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      ForEach(DATE_FORMATS, (choice: DateFormatChoice) => {
        Row() {
          Text(choice.label)
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontColor(this.colors().textPrimary)
            .layoutWeight(1)
          if (choice.value === this.dateFormat) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(ThemeConstants.ICON_SMALL)
              .fontColor([this.colors().brandPrimary])
          }
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.dateFormat = choice.value;
          this.sheet = '';
          this.touch();
        })
      }, (choice: DateFormatChoice) => choice.value)
      Button('取消')
        .width('100%')
        .height(44)
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textSecondary)
        .onClick(() => {
          this.sheet = '';
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
          title: 'NFO 设置',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('服务器级设置（影响所有媒体库写出的 nfo 文件）')
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
            if (this.actionMessage.length > 0) {
              Text(this.actionMessage)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.actionOk ? this.colors().success : this.colors().error)
                .maxLines(2)
            } else {
              Text(this.isDirty() ? '有未保存的修改' : '与服务器一致')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.isDirty() ? this.colors().warning : this.colors().textSecondary)
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
              SectionCard({ title: '写出 nfo 时的行为', icon: $r('sys.symbol.doc_text'),
                showHeaderIcon: true }) {
                Column() {
                  SettingCell({
                    title: '发布日期格式',
                    subtitle: 'nfo 里 premiered / releasedate 的写法',
                    valueText: this.dateFormat,
                    showIcon: true,
                    icon: $r('sys.symbol.clock'),
                    showChevron: true,
                    onTap: () => {
                      this.sheet = 'date';
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '把图片路径写进 nfo',
                    subtitle: '在 nfo 里记录图片相对路径（关掉则只写图片类型）',
                    showToggle: true,
                    toggleOn: this.saveImagePaths,
                    onToggle: (value: boolean) => {
                      this.saveImagePaths = value;
                      this.touch();
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '应用路径替换规则',
                    subtitle: '按服务器的路径映射（PathSubstitutions）写出路径，便于其它客户端读取',
                    showToggle: true,
                    toggleOn: this.pathSubstitution,
                    onToggle: (value: boolean) => {
                      this.pathSubstitution = value;
                      this.touch();
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '生成额外缩略图副本',
                    subtitle: '同时生成 -thumb 与 -landscape 两份缩略图',
                    showToggle: true,
                    toggleOn: this.extraThumbs,
                    onToggle: (value: boolean) => {
                      this.extraThumbs = value;
                      this.touch();
                    }
                  })
                }
                .width('100%')
              }

              Text('这些选项只在服务器写入 nfo 时生效；读取 nfo 的行为在「媒体库元数据」页里配置。')
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

          Row({ space: 10 }) {
            Button('恢复')
              .layoutWeight(1)
              .height(44)
              .backgroundColor(this.colors().surfacePressed)
              .fontColor(this.colors().textPrimary)
              .enabled(!this.saving && this.isDirty())
              .onClick(() => {
                this.load();
                this.actionOk = true;
                this.actionMessage = '已恢复为服务器上的当前设置';
              })
            Button(this.saving ? '保存中...' : '保存')
              .layoutWeight(2)
              .height(44)
              .backgroundColor(this.colors().brandPrimary)
              .fontColor(this.colors().onBrand)
              .enabled(!this.saving && this.isDirty())
              .onClick(() => {
                this.save();
              })
          }
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
            top: 8, bottom: 8 })
          .backgroundColor(this.colors().cardBackground)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.sheet.length > 0) {
        Column() {
          this.DateFormatSheet()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.sheet = '';
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
