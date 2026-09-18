import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/**
 * 设置 → 继续观看。
 *
 * 对应 `ServerConfiguration` 里那五个"续播/已看"阈值（`ServerConfiguration.cs` 的默认值写在这里）：
 *
 * | 字段 | 默认 | 含义 |
 * | --- | --- | --- |
 * | `MinResumePct` | 5 | 至少要播到这个百分比，才算"看过一点"，才会进继续观看 |
 * | `MaxResumePct` | 90 | 播超过这个百分比就当成"看完"，续播点清零并标记已看 |
 * | `MinResumeDurationSeconds` | 300 | 时长不足这个秒数的条目（短片/预告）不参与续播记录 |
 * | `MinAudiobookResume` | 5 | 有声书：距结尾还剩这么多分钟时，续播点会重置到开头 |
 * | `MaxAudiobookResume` | 5 | 有声书：少于这么多分钟就当成听完 |
 *
 * ⚠️ 这一页原来指向 `/System/Configuration`（整份配置的原始键值列表），
 * 标题写着"继续观看"，内容却是服务器全部配置 —— 既看不懂也改不了。
 *
 * 服务端这段是 `ServerConfiguration` 的**顶层字段**，没有独立的 keyed 路由，
 * 所以读写走整份 `GET/POST /System/Configuration`（整份 GET → 原样 POST 实测逐字节相同），
 * 只改这五个数字。
 */
@Entry
@Component
struct ResumeSettingsPage {
  /** 整份服务器配置（保存时的底本，没动过的字段原样回传） */
  private config: ESObject = {} as ESObject;
  private originalJson: string = '';

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  // 表单值用字符串承载：数字输入框在清空重输时会给出空串/非法值，
  // 直接绑 number 会把用户中途的输入吞掉（只剩 0），这里只在校验通过时才回写数字。
  @State private minResumePct: number = 5;
  @State private maxResumePct: number = 90;
  @State private minDurationMinutes: number = 5;
  @State private minAudiobookResume: number = 5;
  @State private maxAudiobookResume: number = 5;

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
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取服务器配置失败';
      return;
    }
    this.originalJson = JsonUtil.toPretty(result.data);
    this.config = result.data;
    this.minResumePct = JsonUtil.getNumber(this.config, 'MinResumePct', 5);
    this.maxResumePct = JsonUtil.getNumber(this.config, 'MaxResumePct', 90);
    // 服务端存秒，界面按分钟更好填
    this.minDurationMinutes = Math.round(
      JsonUtil.getNumber(this.config, 'MinResumeDurationSeconds', 300) / 60);
    this.minAudiobookResume = JsonUtil.getNumber(this.config, 'MinAudiobookResume', 5);
    this.maxAudiobookResume = JsonUtil.getNumber(this.config, 'MaxAudiobookResume', 5);
    this.status = UiState.SUCCESS;
  }

  private buildPayload(): string {
    const draft: ESObject = JSON.parse(JSON.stringify(this.config)) as ESObject;
    const bag: Record<string, Object> = draft as Record<string, Object>;
    bag['MinResumePct'] = this.minResumePct;
    bag['MaxResumePct'] = this.maxResumePct;
    bag['MinResumeDurationSeconds'] = this.minDurationMinutes * 60;
    bag['MinAudiobookResume'] = this.minAudiobookResume;
    bag['MaxAudiobookResume'] = this.maxAudiobookResume;
    return JsonUtil.toPretty(draft);
  }

  private isDirty(): boolean {
    return this.buildPayload() !== this.originalJson;
  }

  private touch(): void {
    this.actionMessage = '';
  }

  /** 续播百分比必须递进：下限要小于上限，否则"看完"的判定会盖掉"看过一点" */
  private percentValid(): boolean {
    return this.minResumePct >= 0 && this.maxResumePct <= 100
      && this.minResumePct < this.maxResumePct;
  }

  private durationValid(): boolean {
    return this.minDurationMinutes >= 0;
  }

  private async save(): Promise<void> {
    if (this.saving || !this.isDirty()) {
      return;
    }
    if (!this.percentValid()) {
      this.actionOk = false;
      this.actionMessage = '续播百分比要满足 0 ≤ 起始 < 结束 ≤ 100';
      return;
    }
    if (!this.durationValid()) {
      this.actionOk = false;
      this.actionMessage = '最短时长不能是负数';
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.libraryUpdateServerConfig(this.buildPayload()));
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = '已保存；对之后的播放状态上报立即生效';
    this.load();
  }

  @Builder
  NumberRow(title: string, hint: string, value: number, unit: string,
            onChange: (value: number) => void) {
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
      Row({ space: 4 }) {
        TextInput({ text: `${value}` })
          .type(InputType.Number)
          .width(96)
          .textAlign(TextAlign.End)
          .onChange((text: string) => {
            const parsed: number = Math.floor(Number(text));
            onChange(Number.isNaN(parsed) ? 0 : parsed);
            this.touch();
          })
        Text(unit)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
      }
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '继续观看',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('服务器级设置（影响所有用户与客户端）')
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
              SectionCard({ title: '续播点记录', icon: $r('sys.symbol.goforward_10'),
                showHeaderIcon: true }) {
                Column() {
                  this.NumberRow('开始记录的百分比', '播到这个比例之后才算"看过一点"，才会出现在继续观看里',
                    this.minResumePct, '%', (value: number) => {
                      this.minResumePct = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('视为看完成的百分比', '播超过这个比例就当成看完，续播点清零并标记已看',
                    this.maxResumePct, '%', (value: number) => {
                      this.maxResumePct = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('最短时长', '时长不足这个分钟的条目（短片、预告）不记录续播点',
                    this.minDurationMinutes, '分钟', (value: number) => {
                      this.minDurationMinutes = value;
                    })
                }
                .width('100%')
              }

              SectionCard({ title: '有声书', icon: $r('sys.symbol.book'), showHeaderIcon: true }) {
                Column() {
                  this.NumberRow('结尾前重置续播点', '距结尾还剩这么多分钟时，续播点回到开头（避免每次都从最后几分钟开始）',
                    this.minAudiobookResume, '分钟', (value: number) => {
                      this.minAudiobookResume = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('视为听完成', '剩余不足这么多分钟就当听完',
                    this.maxAudiobookResume, '分钟', (value: number) => {
                      this.maxAudiobookResume = value;
                    })
                }
                .width('100%')
              }

              Text('这些阈值是服务器级的：客户端上报播放进度，服务端据此决定写入还是清零续播点。')
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
