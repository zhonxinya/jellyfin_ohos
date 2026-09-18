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

/** 一行"标签 + 值"（值是长路径时允许换行） */
class InfoRow {
  label: string = '';
  value: string = '';
  /** 长路径之类的值用更小的字号并允许折行 */
  long: boolean = false;

  constructor(label: string, value: string, long: boolean = false) {
    this.label = label;
    this.value = value;
    this.long = long;
  }
}

/**
 * 设置 → 控制台 → 系统信息。
 *
 * 原来这一页走的是通用键值渲染：只显示 `AdminLoader` 里硬编码的十几个**英文键**
 * （`ServerName` / `ProgramDataPath` …），值被截到 4 行，`/System/Info` 里另外一半字段
 * （`OperatingSystemDisplayName`、`SystemArchitecture`、`SupportsLibraryMonitor`、
 * `HasUpdateAvailable`、`WebPath`、`ItemsByNamePath`、`EncoderLocation`…）根本看不到。
 *
 * 现在按用途分成三张卡，字段名对着 `MediaBrowser.Model/System/SystemInfo.cs` 核过，
 * 并如实区分"是 / 否 / 未知"（服务端没下发就不假装是 false）。
 */
@Entry
@Component
struct SystemInfoPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private serverRows: InfoRow[] = [];
  @State private runtimeRows: InfoRow[] = [];
  @State private pathRows: InfoRow[] = [];

  private info: ESObject = {} as ESObject;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  /** 只有服务端确实下发过这个键时才返回文本，否则返回空串（不猜默认值） */
  private text(key: string): string {
    const map: Record<string, Object> = this.info as Record<string, Object>;
    const value: Object | undefined = map[key];
    if (value === undefined || value === null) {
      return '';
    }
    if (typeof value === 'boolean') {
      return value ? '是' : '否';
    }
    if (typeof value === 'object') {
      return '';
    }
    return `${value}`;
  }

  private add(rows: InfoRow[], label: string, key: string, long: boolean = false): void {
    const value: string = this.text(key);
    if (value.length > 0) {
      rows.push(new InfoRow(label, value, long));
    }
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGetSystemInfo());
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取系统信息失败';
      return;
    }
    this.info = result.data;

    const server: InfoRow[] = [];
    this.add(server, '服务器名称', 'ServerName');
    this.add(server, '版本', 'Version');
    this.add(server, '服务器 ID', 'Id', true);
    this.add(server, '本地地址', 'LocalAddress', true);
    this.add(server, 'WebSocket 端口', 'WebSocketPortNumber');
    this.add(server, '待重启', 'HasPendingRestart');
    this.add(server, '正在关闭', 'IsShuttingDown');
    this.add(server, '有可用更新', 'HasUpdateAvailable');

    const runtime: InfoRow[] = [];
    this.add(runtime, '操作系统', 'OperatingSystemDisplayName');
    if (runtime.length === 0) {
      this.add(runtime, '操作系统', 'OperatingSystem');
    }
    this.add(runtime, '系统架构', 'SystemArchitecture');
    this.add(runtime, '支持媒体库监控', 'SupportsLibraryMonitor');
    this.add(runtime, '可以自我重启', 'CanSelfRestart');
    this.add(runtime, '可以打开浏览器', 'CanLaunchWebBrowser');
    this.add(runtime, '编码器位置', 'EncoderLocation');

    const paths: InfoRow[] = [];
    this.add(paths, '数据目录', 'ProgramDataPath', true);
    this.add(paths, '缓存目录', 'CachePath', true);
    this.add(paths, '日志目录', 'LogPath', true);
    this.add(paths, '元数据目录', 'InternalMetadataPath', true);
    this.add(paths, '转码临时目录', 'TranscodingTempPath', true);
    this.add(paths, 'Web 资源目录', 'WebPath', true);
    this.add(paths, '条目索引目录', 'ItemsByNamePath', true);

    this.serverRows = server;
    this.runtimeRows = runtime;
    this.pathRows = paths;
    this.status = (server.length + runtime.length + paths.length) === 0
      ? UiState.EMPTY : UiState.SUCCESS;
  }

  @Builder
  Rows(rows: InfoRow[]) {
    Column() {
      ForEach(rows, (row: InfoRow, index: number) => {
        Column() {
          Column({ space: 4 }) {
            Text(row.label)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().textSecondary)
              .width('100%')
            Text(row.value.length > 0 ? row.value : '—')
              .fontSize(row.long ? ThemeConstants.META_MEDIUM : ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .width('100%')
              .maxLines(row.long ? 4 : 2)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
            top: 10, bottom: 10 })
          if (index < rows.length - 1) {
            Divider().color(this.colors().divider).strokeWidth(0.5)
          }
        }
        .width('100%')
      }, (row: InfoRow) => `${row.label}-${row.value}`)
    }
    .width('100%')
  }

  build() {
    Column() {
      PageHeader({
        title: '系统信息',
        onBack: () => {
          router.back();
        }
      })

      if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
        LoadingState()
      } else if (this.status === UiState.ERROR || this.status === UiState.EMPTY) {
        EmptyState({
          message: this.status === UiState.EMPTY
            ? '服务器没有返回系统信息。'
            : (this.errorMsg.length > 0 ? this.errorMsg : '加载失败'),
          actionLabel: '重试',
          onAction: () => {
            this.reload();
          }
        })
      } else {
        Scroll() {
          Column() {
            SectionCard({ title: '服务器', icon: $r('sys.symbol.externaldrive'),
              showHeaderIcon: true }) {
              this.Rows(this.serverRows)
            }
            SectionCard({ title: '运行时', icon: $r('sys.symbol.gearshape'),
              showHeaderIcon: true }) {
              this.Rows(this.runtimeRows)
            }
            SectionCard({ title: '目录', icon: $r('sys.symbol.folder'), showHeaderIcon: true }) {
              this.Rows(this.pathRows)
            }

            Text('这里只显示服务端 `/System/Info` 实际下发的字段；没下发的不会假装成"否"。')
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.colors().textTertiary)
              .width('100%')
              .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                top: 4 })

            Blank().height(24)
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
  }
}
