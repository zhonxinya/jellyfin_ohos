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
 * 设置 → 播放（服务器级）。
 *
 * 这一页原来是 `AdminConfigEditor` 形式的 10 字段编辑器，其中 8 个字段（续播阈值、
 * 特别篇显示、合集分组、文件夹视图、慢响应告警）**已经在各自的专页里**了 ——
 * 同一个值能在两处改、单位还不一致（这边 `MinResumeDurationSeconds` 按秒，
 * 「继续观看」页按分钟）。现在只留服务器级里真正属于"播放带宽"的那一项
 * `RemoteClientBitrateLimit`，其余相关设置给入口指过去，标题也改成如实描述。
 *
 * 读写走整份 `GET/POST /System/Configuration`（整份往返实测逐字节相同），只改这一个字段。
 */
@Entry
@Component
struct PlaybackSettingsPage {
  private config: ESObject = {} as ESObject;
  private originalJson: string = '';

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  /** 界面单位是 Mbps，0 表示不限（服务端存的是 bit/s） */
  @State private bitrateLimitMbps: number = 0;

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
    const bitsPerSecond: number = JsonUtil.getNumber(this.config, 'RemoteClientBitrateLimit', 0);
    this.bitrateLimitMbps = bitsPerSecond > 0 ? Math.round(bitsPerSecond / 1000000) : 0;
    this.status = UiState.SUCCESS;
  }

  private buildPayload(): string {
    const draft: ESObject = JSON.parse(JSON.stringify(this.config)) as ESObject;
    // 服务端这一项是 bit/s；0 表示不限
    (draft as Record<string, Object>)['RemoteClientBitrateLimit'] =
      this.bitrateLimitMbps > 0 ? this.bitrateLimitMbps * 1000000 : 0;
    return JsonUtil.toPretty(draft);
  }

  private isDirty(): boolean {
    return this.buildPayload() !== this.originalJson;
  }

  private async save(): Promise<void> {
    if (this.saving || !this.isDirty()) {
      return;
    }
    if (this.bitrateLimitMbps < 0) {
      this.actionOk = false;
      this.actionMessage = '码率上限不能是负数（0 表示不限）';
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
    this.actionMessage = '已保存；新的播放会话会按新的上限来';
    this.load();
  }

  private openPage(url: string, title: string): void {
    router.pushUrl({ url: url, params: { title: title } });
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '播放（服务器）',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('服务器级设置（影响所有客户端的播放）')
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
              SectionCard({ title: '带宽', icon: $r('sys.symbol.wifi'), showHeaderIcon: true }) {
                Column() {
                  Row({ space: 8 }) {
                    Column({ space: 4 }) {
                      Text('远程播放码率上限')
                        .fontSize(ThemeConstants.TITLE_MEDIUM)
                        .fontColor(this.colors().textPrimary)
                      Text('局域网之外的播放超过这个码率就转码；0 表示不限。'
                        + '网络不好时设一个上限，比让播放一直卡顿更好')
                        .fontSize(ThemeConstants.META_SMALL)
                        .fontColor(this.colors().textSecondary)
                    }
                    .alignItems(HorizontalAlign.Start)
                    .layoutWeight(1)
                    Row({ space: 4 }) {
                      TextInput({ text: `${this.bitrateLimitMbps}` })
                        .type(InputType.Number)
                        .width(92)
                        .textAlign(TextAlign.End)
                        .onChange((text: string) => {
                          const parsed: number = Math.floor(Number(text));
                          this.bitrateLimitMbps = Number.isNaN(parsed) ? 0 : parsed;
                          this.actionMessage = '';
                        })
                      Text('Mbps')
                        .fontSize(ThemeConstants.META_SMALL)
                        .fontColor(this.colors().textSecondary)
                    }
                  }
                  .width('100%')
                  .padding(ThemeConstants.PAGE_PADDING)
                }
                .width('100%')
              }

              SectionCard({ title: '相关设置', icon: $r('sys.symbol.play_circle'),
                showHeaderIcon: true }) {
                Column() {
                  SettingCell({
                    title: '转码',
                    subtitle: '硬件加速、编码质量、限速与 HDR→SDR',
                    showIcon: true,
                    icon: $r('sys.symbol.video_speed'),
                    showChevron: true,
                    onTap: () => {
                      this.openPage('pages/admin/TranscodingSettingsPage', '转码');
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '继续观看',
                    subtitle: '续播/已看的百分比与时长阈值、有声书续播',
                    showIcon: true,
                    icon: $r('sys.symbol.goforward_10'),
                    showChevron: true,
                    onTap: () => {
                      this.openPage('pages/admin/ResumeSettingsPage', '继续观看');
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '媒体库显示',
                    subtitle: '扫描并发、实时监控延迟、图片落盘约定',
                    showIcon: true,
                    icon: $r('sys.symbol.display'),
                    showChevron: true,
                    onTap: () => {
                      this.openPage('pages/admin/LibraryDisplaySettingsPage', '媒体库显示');
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '网络',
                    subtitle: '远程访问、端口、HTTPS 与代理',
                    showIcon: true,
                    icon: $r('sys.symbol.wifi'),
                    showChevron: true,
                    onTap: () => {
                      this.openPage('pages/admin/NetworkSettingsPage', '网络');
                    }
                  })
                }
                .width('100%')
              }

              Text('客户端自己的播放偏好（默认播放器、自动播放下一集、音轨语言等）在「设置」主页里。')
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
