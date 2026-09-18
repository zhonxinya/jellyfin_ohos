import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { LibraryOptionSet } from '../../common/LibraryModels';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 图片保存约定（服务端 `ImageSavingConvention` 枚举） */
class ImageConventionChoice {
  value: string;
  label: string;
  hint: string;

  constructor(value: string, label: string, hint: string) {
    this.value = value;
    this.label = label;
    this.hint = hint;
  }
}

const IMAGE_CONVENTIONS: ImageConventionChoice[] = [
  new ImageConventionChoice('Legacy', 'Legacy（旧版）',
    '图片直接放在影片同目录，文件名沿用旧规则（兼容既有媒体库）'),
  new ImageConventionChoice('Compatible', 'Compatible（新版）',
    '图片目录名与类型后缀按新版规范命名，对多版本影片更友好')
];

function imageConventionLabel(value: string): string {
  for (let i = 0; i < IMAGE_CONVENTIONS.length; i++) {
    if (IMAGE_CONVENTIONS[i].value === value) {
      return IMAGE_CONVENTIONS[i].label;
    }
  }
  return value;
}

/**
 * 设置 → 媒体库显示（服务器级媒体库设置）。
 *
 * 这是 jellyfin-web 「媒体库」页底部那组**全局**设置：媒体库列表怎么显示、
 * 抓到的图片怎么落盘、扫描的并发与文件监控延迟。每个媒体库自己的设置（元数据语言、
 * 抓取器、路径等）在「媒体库管理 → 媒体库选项」里，两者不是一回事。
 *
 * 服务端 `POST /System/Configuration` 是**整体替换**
 * （`SystemConfigurationController.UpdateConfiguration` → `ReplaceConfiguration`），
 * 所以这里与媒体库选项用的是同一套纪律：GET 全量 → 只改用户动过的字段 → POST 全量。
 * 实测这台服务器 GET → 原样 POST 往返逐字节相同，因此"恒等保存"不会改坏别的字段。
 */
@Entry
@Component
struct LibraryDisplaySettingsPage {
  /** 服务端下发的完整配置对象（保存时的底本，未改动的字段原样回传） */
  private base: LibraryOptionSet = new LibraryOptionSet(null);
  private originalJson: string = '';

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  @State private folderView: boolean = false;
  @State private groupingIntoCollections: boolean = false;
  @State private specialsWithinSeasons: boolean = true;
  @State private saveMetadataHidden: boolean = false;
  @State private imageConvention: string = 'Legacy';
  @State private monitorDelay: number = 60;
  @State private scanConcurrency: number = 0;
  @State private metadataConcurrency: number = 0;

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
    const raw: string = await JellyfinNative.libraryServerConfig();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取服务器配置失败';
      return;
    }
    this.originalJson = JsonUtil.toPretty(result.data);
    this.base = LibraryOptionSet.fromJson(this.originalJson);
    this.applyToForm();
    this.status = UiState.SUCCESS;
  }

  private applyToForm(): void {
    this.folderView = this.base.getBool('EnableFolderView', false);
    this.groupingIntoCollections = this.base.getBool('EnableGroupingIntoCollections', false);
    this.specialsWithinSeasons = this.base.getBool('DisplaySpecialsWithinSeasons', true);
    this.saveMetadataHidden = this.base.getBool('SaveMetadataHidden', false);
    this.imageConvention = this.base.getString('ImageSavingConvention', 'Legacy');
    this.monitorDelay = this.base.getNumber('LibraryMonitorDelay', 60);
    this.scanConcurrency = this.base.getNumber('LibraryScanFanoutConcurrency', 0);
    this.metadataConcurrency = this.base.getNumber('LibraryMetadataRefreshConcurrency', 0);
  }

  private touch(): void {
    this.actionMessage = '';
  }

  /**
   * 是否有未保存的改动 —— 直接比较待提交的对象与载入时的 JSON。
   * 与媒体库选项页同样的做法：不维护布尔标记，避免被程序化回填触发的 onChange 骗到。
   */
  private isDirty(): boolean {
    return this.buildPayload() !== this.originalJson;
  }

  private buildPayload(): string {
    const draft: LibraryOptionSet = this.base.clone();
    draft.setBool('EnableFolderView', this.folderView);
    draft.setBool('EnableGroupingIntoCollections', this.groupingIntoCollections);
    draft.setBool('DisplaySpecialsWithinSeasons', this.specialsWithinSeasons);
    draft.setBool('SaveMetadataHidden', this.saveMetadataHidden);
    draft.setString('ImageSavingConvention', this.imageConvention);
    draft.setNumber('LibraryMonitorDelay', this.monitorDelay < 0 ? 0 : Math.floor(this.monitorDelay));
    draft.setNumber('LibraryScanFanoutConcurrency',
      this.scanConcurrency < 0 ? 0 : Math.floor(this.scanConcurrency));
    draft.setNumber('LibraryMetadataRefreshConcurrency',
      this.metadataConcurrency < 0 ? 0 : Math.floor(this.metadataConcurrency));
    return draft.toJson();
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    const raw: string = await JellyfinNative.libraryUpdateServerConfig(this.buildPayload());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = '已保存（部分设置需要重新打开媒体库或重启客户端后生效）';
    // 重新拉一次：以服务端实际落库的结果为准，避免界面上留着"看起来生效了"的假状态
    this.load();
  }

  private resetForm(): void {
    this.base = LibraryOptionSet.fromJson(this.originalJson);
    this.applyToForm();
    this.actionOk = true;
    this.actionMessage = '已恢复为上次从服务器读取的配置（尚未提交）';
  }

  @Builder
  NumberRow(title: string, hint: string, value: number, onChange: (value: number) => void) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
        Text(hint)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      TextInput({ text: `${value}` })
        .type(InputType.Number)
        .width(110)
        .onChange((text: string) => {
          const parsed: number = Number(text);
          onChange(Number.isNaN(parsed) ? 0 : parsed);
        })
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  @Builder
  ConventionSheet() {
    Column({ space: 10 }) {
      Text('图片保存约定')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      ForEach(IMAGE_CONVENTIONS, (choice: ImageConventionChoice) => {
        Column({ space: 4 }) {
          Row() {
            Text(choice.label)
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .layoutWeight(1)
            if (choice.value === this.imageConvention) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(ThemeConstants.ICON_SMALL)
                .fontColor([this.colors().brandPrimary])
            }
          }
          .width('100%')
          Text(choice.hint)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ top: 10, bottom: 10 })
        .onClick(() => {
          this.imageConvention = choice.value;
          this.sheet = '';
          this.touch();
        })
      }, (choice: ImageConventionChoice) => choice.value)
      Button('关闭')
        .width('100%')
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
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

  @Builder
  Body() {
    Scroll() {
      Column() {
        SectionCard({ title: '媒体库显示', icon: $r('sys.symbol.display'), showHeaderIcon: true }) {
          Column() {
            SettingCell({
              title: '显示文件夹视图',
              subtitle: '在媒体库里把子文件夹也作为可进入的条目显示',
              showToggle: true,
              toggleOn: this.folderView,
              onToggle: (value: boolean) => {
                this.folderView = value;
                this.touch();
              }
            })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            SettingCell({
              title: '自动归入合集',
              subtitle: '影片属于同一合集时自动建立合集条目（也可在单个媒体库里关掉）',
              showToggle: true,
              toggleOn: this.groupingIntoCollections,
              onToggle: (value: boolean) => {
                this.groupingIntoCollections = value;
                this.touch();
              }
            })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            SettingCell({
              title: '特别篇显示在季中',
              subtitle: '把第 0 季的特别篇显示在它所属的季里，而不是单独一季',
              showToggle: true,
              toggleOn: this.specialsWithinSeasons,
              onToggle: (value: boolean) => {
                this.specialsWithinSeasons = value;
                this.touch();
              }
            })
          }
          .width('100%')
        }

        SectionCard({ title: '图片与元数据落盘', icon: $r('sys.symbol.doc_text'),
          showHeaderIcon: true }) {
          Column() {
            SettingCell({
              title: '图片保存约定',
              subtitle: '抓到的图片写回媒体目录时用哪套命名规则',
              valueText: imageConventionLabel(this.imageConvention),
              showChevron: true,
              onTap: () => {
                this.sheet = 'convention';
              }
            })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            SettingCell({
              title: '保存隐藏字段',
              subtitle: '把标记为"不显示"的元数据字段也写进 nfo',
              showToggle: true,
              toggleOn: this.saveMetadataHidden,
              onToggle: (value: boolean) => {
                this.saveMetadataHidden = value;
                this.touch();
              }
            })
          }
          .width('100%')
        }

        SectionCard({ title: '扫描与监控', icon: $r('sys.symbol.timer'), showHeaderIcon: true }) {
          Column() {
            this.NumberRow('扫描时的并发数', '0 表示自动（跟随服务器 CPU）；媒体库很多时可适当提高',
              this.scanConcurrency, (value: number) => {
                this.scanConcurrency = value;
                this.touch();
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.NumberRow('元数据刷新并发数', '0 表示自动；抓取器被限流时可以调低',
              this.metadataConcurrency, (value: number) => {
                this.metadataConcurrency = value;
                this.touch();
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.NumberRow('文件变化后的延迟（秒）', '检测到文件变动后等多久再扫描，避免拷大文件时反复触发',
              this.monitorDelay, (value: number) => {
                this.monitorDelay = value;
                this.touch();
              })
          }
          .width('100%')
        }

        Text('这些是服务器级设置，会影响所有媒体库与所有客户端；单个媒体库自己的设置'
          + '（元数据语言、抓取器、路径、扫描范围）在「媒体库管理 → 媒体库选项」里。')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textTertiary)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 4 })

        Blank().height(80)
      }
      .width('100%')
      .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  @Builder
  Footer() {
    Row({ space: 10 }) {
      Button('恢复')
        .layoutWeight(1)
        .height(44)
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
        .enabled(!this.saving && this.isDirty())
        .onClick(() => {
          this.resetForm();
        })
      Button(this.saving ? '保存中...' : '保存')
        .layoutWeight(2)
        .height(44)
        .backgroundColor(this.colors().brandPrimary)
        .fontColor(this.colors().onBrand)
        .enabled(!this.saving)
        .onClick(() => {
          this.save();
        })
    }
    .width('100%')
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
      top: 8, bottom: 8 })
    .backgroundColor(this.colors().cardBackground)
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '媒体库显示',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('服务器级设置（影响所有媒体库）')
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
          this.Body()
          this.Footer()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.sheet.length > 0) {
        Column() {
          this.ConventionSheet()
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
