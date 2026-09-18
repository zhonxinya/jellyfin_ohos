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

/** 一个日志文件（`LogFile`：Name / Size / DateCreated / DateModified） */
class LogEntry {
  name: string = '';
  size: number = 0;
  modified: string = '';

  constructor(name: string, size: number, modified: string) {
    this.name = name;
    this.size = size;
    this.modified = modified;
  }
}

/**
 * 只把日志的**结尾**交给界面。
 *
 * 服务端 `/System/Logs/Log` 返回整份文件，而且**没有** range/tail 端点
 * （`SystemController.GetLogFile` 的 `File(stream, "text/plain")` 不带 range 处理，
 * 实测响应里也没有 `Accept-Ranges`）；本机实测一天的文件有 15.5 MB。
 * 看日志本来就是看最新的那几屏，所以原生侧只取结尾这么多字节（见 `native/core/text_util.h`）。
 */
const LOG_TAIL_BYTES = 256 * 1024;

function humanSize(bytes: number): string {
  if (bytes < 1024) {
    return `${bytes} B`;
  }
  if (bytes < 1024 * 1024) {
    return `${(bytes / 1024).toFixed(1)} KB`;
  }
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}

function humanTime(iso: string): string {
  // 服务端给的是 UTC ISO（2026-09-18T22:51:08.1878504Z）：只显示到分钟并标明 UTC，
  // 不去猜设备时区（猜错比不显示更糟）
  if (iso.length < 16) {
    return iso;
  }
  return `${iso.substring(0, 10)} ${iso.substring(11, 16)} UTC`;
}

/**
 * 设置 → 控制台 → 日志。
 *
 * 原来这一页把 `/System/Logs` 的 JSON 当键值表列出来（文件名、大小、时间），
 * **看不到内容** —— 而"看日志"才是这一页的用途。现在：
 * 点开某个文件就取它的结尾 256 KB 显示出来（截断时明确写出文件总大小）。
 */
@Entry
@Component
struct LogsPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private entries: LogEntry[] = [];

  @State private viewerOpen: boolean = false;
  @State private viewerTitle: string = '';
  @State private viewerText: string = '';
  @State private viewerNotice: string = '';
  @State private viewerStatus: string = UiState.LOADING;
  @State private viewerError: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGenericGet('/System/Logs'));
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取日志列表失败';
      return;
    }
    const list: LogEntry[] = [];
    let items: Object[] = JsonUtil.getArray(result.data, 'Items');
    if (items.length === 0 && Array.isArray(result.data)) {
      items = result.data as Object[];
    }
    for (let i = 0; i < items.length; i++) {
      const src: ESObject = items[i] as ESObject;
      const name: string = JsonUtil.getString(src, 'Name', '');
      if (name.length > 0) {
        list.push(new LogEntry(name, JsonUtil.getNumber(src, 'Size', 0),
          JsonUtil.getString(src, 'DateModified', '')));
      }
    }
    // 新的排在前面
    list.sort((a: LogEntry, b: LogEntry) => a.modified < b.modified ? 1 : -1);
    this.entries = list;
    this.status = list.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private async openLog(entry: LogEntry): Promise<void> {
    this.viewerOpen = true;
    this.viewerTitle = entry.name;
    this.viewerText = '';
    this.viewerNotice = '';
    this.viewerError = '';
    this.viewerStatus = UiState.LOADING;
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGetLogText(entry.name, LOG_TAIL_BYTES));
    if (!result.ok || result.data === null) {
      this.viewerStatus = UiState.ERROR;
      this.viewerError = result.message.length > 0 ? result.message : '读取日志内容失败';
      return;
    }
    this.viewerText = JsonUtil.getString(result.data, 'text', '');
    const truncated: boolean = JsonUtil.getBoolean(result.data, 'truncated', false);
    const total: number = JsonUtil.getNumber(result.data, 'totalBytes', 0);
    this.viewerNotice = truncated
      ? `文件共 ${humanSize(total)}，这里只显示最后 ${humanSize(LOG_TAIL_BYTES)}`
      : `文件共 ${humanSize(total)}，已完整显示`;
    this.viewerStatus = UiState.SUCCESS;
  }

  private findEntry(name: string): LogEntry | null {
    for (let i = 0; i < this.entries.length; i++) {
      if (this.entries[i].name === name) {
        return this.entries[i];
      }
    }
    return null;
  }

  @Builder
  Viewer() {
    Column() {
      Row({ space: 8 }) {
        Column({ space: 2 }) {
          Text(this.viewerTitle)
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().textPrimary)
            .maxLines(1)
          if (this.viewerNotice.length > 0) {
            Text(this.viewerNotice)
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.colors().textSecondary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Button('关闭')
          .height(36)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .backgroundColor(this.colors().surfacePressed)
          .fontColor(this.colors().textPrimary)
          .onClick(() => {
            this.viewerOpen = false;
          })
      }
      .width('100%')
      .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
        top: 12, bottom: 8 })

      if (this.viewerStatus === UiState.LOADING || this.viewerStatus === UiState.REFRESHING) {
        LoadingState()
      } else if (this.viewerStatus === UiState.ERROR) {
        EmptyState({
          message: this.viewerError.length > 0 ? this.viewerError : '读取失败',
          actionLabel: '重试',
          onAction: () => {
            const entry: LogEntry | null = this.findEntry(this.viewerTitle);
            if (entry !== null) {
              this.openLog(entry);
            }
          }
        })
      } else {
        Scroll() {
          Column() {
            Text(this.viewerText)
              .fontSize(12)
              .fontColor(this.colors().textPrimary)
              .textAlign(TextAlign.Start)
              .width('100%')
          }
          .width('100%')
          .padding(ThemeConstants.PAGE_PADDING)
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

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '日志',
          onBack: () => {
            // 浮层打开时先关浮层，避免一下退出整个控制台
            if (this.viewerOpen) {
              this.viewerOpen = false;
            } else {
              router.back();
            }
          }
        })

        if (this.status === UiState.SUCCESS) {
          Text('点开某个日志看内容：只取结尾 256 KB（服务端只提供整份文件，一天就有十几 MB）')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
              bottom: 6 })
        }

        if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState()
        } else if (this.status === UiState.ERROR || this.status === UiState.EMPTY) {
          EmptyState({
            message: this.status === UiState.EMPTY
              ? '服务器上没有日志文件。'
              : (this.errorMsg.length > 0 ? this.errorMsg : '加载失败'),
            actionLabel: '重试',
            onAction: () => {
              this.reload();
            }
          })
        } else {
          Scroll() {
            Column() {
              SectionCard({ title: `日志文件（${this.entries.length}）`,
                icon: $r('sys.symbol.doc_text'), showHeaderIcon: true }) {
                Column() {
                  ForEach(this.entries, (entry: LogEntry, index: number) => {
                    Column() {
                      SettingCell({
                        title: entry.name,
                        subtitle: `${humanSize(entry.size)} · ${humanTime(entry.modified)}`,
                        showIcon: true,
                        icon: $r('sys.symbol.doc_text'),
                        showChevron: true,
                        onTap: () => {
                          this.openLog(entry);
                        }
                      })
                      if (index < this.entries.length - 1) {
                        Divider().color(this.colors().divider).strokeWidth(0.5)
                      }
                    }
                    .width('100%')
                  }, (entry: LogEntry) => `${entry.name}-${entry.size}-${entry.modified}`)
                }
                .width('100%')
              }

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

      if (this.viewerOpen) {
        this.Viewer()
      }
    }
    .width('100%')
    .height('100%')
  }
}
