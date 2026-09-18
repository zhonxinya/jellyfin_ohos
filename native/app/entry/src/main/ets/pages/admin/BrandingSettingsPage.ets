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

/** 这一段配置的 key（`GET /System/Configuration/{key}` 实测可用） */
const BRANDING_CONFIG_KEY = 'branding';

/**
 * 设置 → 品牌。
 *
 * 对应 jellyfin-web 的 Dashboard → Branding，落到服务端的 `BrandingOptions`：
 *
 * | 字段 | 含义 |
 * | --- | --- |
 * | `SplashscreenEnabled` | 是否显示启动画面（服务端下发给**客户端**的标记） |
 * | `LoginDisclaimer` | 登录页上的免责声明文本 |
 * | `CustomCss` | 注入到 Web 客户端的自定义 CSS |
 *
 * ⚠️ 这三项里有两项只被 **Web 客户端**消费（免责声明与自定义 CSS）：
 * 本应用的界面不受它们影响。这里如实标注，避免用户以为"改了手机端会变样"。
 *
 * 读写走 keyed 路由只替换这一段（不是整份 ServerConfiguration）。
 */
@Entry
@Component
struct BrandingSettingsPage {
  /** 服务端下发的这一段配置（底本，未知字段原样带回） */
  private base: ESObject = {} as ESObject;
  private originalJson: string = '';

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  @State private splashscreen: boolean = false;
  @State private disclaimer: string = '';
  @State private customCss: string = '';
  /**
   * 载入时这两个文本字段的原值。
   *
   * 服务端把它们当**可空字符串**（`JsonIgnoreCondition.WhenWritingNull`，没配过就不下发），
   * 而不带脑子地把它们写成 `""` 虽然行为等价（服务端各处用 `string.IsNullOrEmpty` 判断），
   * 却会让"打开页面什么都不改直接保存"也变成一次真实写入，页面还会一进来就显示
   * "有未保存的修改"。所以只在用户真的改过时才写这两个字段。
   */
  private loadedDisclaimer: string = '';
  private loadedCss: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.libraryNamedConfig(BRANDING_CONFIG_KEY);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取品牌设置失败';
      return;
    }
    this.originalJson = JsonUtil.toPretty(result.data);
    this.base = result.data;
    this.splashscreen = JsonUtil.getBoolean(this.base, 'SplashscreenEnabled', false);
    this.disclaimer = JsonUtil.getString(this.base, 'LoginDisclaimer', '');
    this.customCss = JsonUtil.getString(this.base, 'CustomCss', '');
    this.loadedDisclaimer = this.disclaimer;
    this.loadedCss = this.customCss;
    this.status = UiState.SUCCESS;
  }

  private buildPayload(): string {
    const draft: ESObject = JSON.parse(JSON.stringify(this.base)) as ESObject;
    const bag: Record<string, Object> = draft as Record<string, Object>;
    // 布尔字段不可空，原样写回是恒等操作
    bag['SplashscreenEnabled'] = this.splashscreen;
    // 两个可空文本只在用户改过时才写（见 loadedDisclaimer 的说明）
    if (this.disclaimer !== this.loadedDisclaimer) {
      bag['LoginDisclaimer'] = this.disclaimer;
    }
    if (this.customCss !== this.loadedCss) {
      bag['CustomCss'] = this.customCss;
    }
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
      await JellyfinNative.libraryUpdateNamedConfig(BRANDING_CONFIG_KEY, this.buildPayload()));
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = '品牌设置已保存';
    this.load();
  }

  @Builder
  TextAreaRow(title: string, hint: string, value: string, placeholder: string,
              onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(hint)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      TextArea({ text: value, placeholder: placeholder })
        .width('100%')
        .height(120)
        .onChange((text: string) => {
          onChange(text);
          this.touch();
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '品牌',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('服务器级设置（影响接入该服务器的客户端）')
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
              SectionCard({ title: '登录与启动', icon: $r('sys.symbol.paintpalette'),
                showHeaderIcon: true }) {
                Column() {
                  SettingCell({
                    title: '显示启动画面',
                    subtitle: '服务端下发的标记；Web 客户端据此决定是否显示启动画面',
                    showToggle: true,
                    toggleOn: this.splashscreen,
                    onToggle: (value: boolean) => {
                      this.splashscreen = value;
                      this.touch();
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.TextAreaRow('登录免责声明',
                    '显示在 Web 登录页上的说明文字；本应用的登录页不读取它',
                    this.disclaimer, '例如：本服务器仅供家庭内部使用',
                    (value: string) => {
                      this.disclaimer = value;
                    })
                }
                .width('100%')
              }

              SectionCard({ title: '自定义样式', icon: $r('sys.symbol.textformat'),
                showHeaderIcon: true }) {
                Column() {
                  this.TextAreaRow('自定义 CSS',
                    '注入到 Web 客户端的样式表；只影响 Web，不影响本应用界面',
                    this.customCss, '例如：.detailPagePrimaryContainer { background: #111 }',
                    (value: string) => {
                      this.customCss = value;
                    })
                }
                .width('100%')
              }

              Text('这些设置主要面向 Web 客户端；本应用（原生播放器与界面）不受免责声明与自定义 CSS 影响。')
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
    }
    .width('100%')
    .height('100%')
  }
}
