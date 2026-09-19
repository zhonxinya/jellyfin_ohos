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
import { TimeFormat } from '../../common/TimeFormat';

/** 一页取多少条（服务端不传 limit 时默认也是 100） */
const PAGE_SIZE = 50;

/** 一条活动记录（`ActivityLogEntry`：Id / Name / Type / Date / UserId / Severity） */
class ActivityEntry {
  id: string = '';
  name: string = '';
  type: string = '';
  date: string = '';
  severity: string = '';

  constructor(id: string, name: string, type: string, date: string, severity: string) {
    this.id = id;
    this.name = name;
    this.type = type;
    this.date = date;
    this.severity = severity;
  }
}

/**
 * 活动类型 → 中文标签 + 图标。
 *
 * 类型名来自服务端的 `ActivityLogEntry.Type`（`ActivityManager` 写入的字符串常量，
 * 例如 VideoPlayback / VideoPlaybackStopped / SessionStarted / AuthenticationSucceeded …），
 * 这里只覆盖常见的那些，未知类型原样显示，不猜。
 */
function typeLabel(type: string): string {
  if (type === 'VideoPlayback') return '开始播放';
  if (type === 'VideoPlaybackStopped') return '停止播放';
  if (type === 'AudioPlayback') return '开始播放音频';
  if (type === 'AudioPlaybackStopped') return '停止播放音频';
  if (type === 'SessionStarted') return '会话开始';
  if (type === 'SessionEnded') return '会话结束';
  if (type === 'AuthenticationSucceeded') return '登录成功';
  if (type === 'AuthenticationFailed') return '登录失败';
  if (type === 'UserCreated') return '创建用户';
  if (type === 'UserDeleted') return '删除用户';
  if (type === 'UserUpdated') return '修改用户';
  if (type === 'UserPasswordChanged') return '修改密码';
  if (type === 'LibraryCreated') return '新建媒体库';
  if (type === 'LibraryDeleted') return '删除媒体库';
  if (type === 'LibraryUpdated') return '修改媒体库';
  if (type === 'ItemAdded') return '新增媒体';
  if (type === 'PluginInstalled') return '安装插件';
  if (type === 'PluginUninstalled') return '卸载插件';
  if (type === 'TaskCompleted') return '任务完成';
  if (type === 'TaskFailed') return '任务失败';
  if (type === 'SubtitleDownloadFailure') return '字幕下载失败';
  return type.length > 0 ? type : '其他';
}

function isPlayback(type: string): boolean {
  return type === 'VideoPlayback' || type === 'VideoPlaybackStopped'
    || type === 'AudioPlayback' || type === 'AudioPlaybackStopped';
}

function isAuth(type: string): boolean {
  return type === 'AuthenticationSucceeded' || type === 'AuthenticationFailed'
    || type === 'UserPasswordChanged';
}

function isLibrary(type: string): boolean {
  return type === 'LibraryCreated' || type === 'LibraryDeleted' || type === 'LibraryUpdated'
    || type === 'ItemAdded';
}

/** 重要级别：服务端给 Information / Warning / Error */
function severityColor(colors: ThemeColors, severity: string): string {
  if (severity === 'Error' || severity === 'Critical') {
    return colors.error;
  }
  if (severity === 'Warning') {
    return colors.warning;
  }
  return colors.textTertiary;
}

/**
 * 服务端 UTC ISO → 设备本地时间（实现见 `common/TimeFormat.ets`，控制台几页共用）。
 */
function formatTime(iso: string): string {
  return TimeFormat.short(iso);
}

/**
 * 设置 → 控制台 → 活动。
 *
 * 原来这一页把 `/System/ActivityLog/Entries` 的每条记录压成一行字符串
 * （`formatItem` 只取 Name，时间字段都对不上，所以**连时间都不显示**），
 * 一页 100 条也没有分页与类型区分。现在：
 *
 * - 每条记录显示成"类型图标 + 名称 + 类型标签 · 本地时间"，按重要级别着色；
 * - 一次取 50 条，底部可以「加载更多」（服务端支持 `startIndex` / `limit`）。
 */
@Entry
@Component
struct ActivityPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private entries: ActivityEntry[] = [];
  @State private total: number = 0;
  @State private loadingMore: boolean = false;
  @State private moreError: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async fetchPage(startIndex: number): Promise<ActivityEntry[]> {
    const path: string = `/System/ActivityLog/Entries?startIndex=${startIndex}&limit=${PAGE_SIZE}`;
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGenericGet(path));
    if (!result.ok) {
      throw new Error(result.message.length > 0 ? result.message : '读取活动记录失败');
    }
    this.total = JsonUtil.getNumber(result.data, 'TotalRecordCount', 0);
    const out: ActivityEntry[] = [];
    const items: Object[] = JsonUtil.extractItems(result.data);
    for (let i = 0; i < items.length; i++) {
      const src: ESObject = items[i] as ESObject;
      const name: string = JsonUtil.getString(src, 'Name', '');
      if (name.length === 0) {
        continue;
      }
      out.push(new ActivityEntry(
        `${JsonUtil.getNumber(src, 'Id', 0)}`,
        name,
        JsonUtil.getString(src, 'Type', ''),
        JsonUtil.getString(src, 'Date', ''),
        JsonUtil.getString(src, 'Severity', 'Information')));
    }
    return out;
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    this.moreError = '';
    try {
      const first: ActivityEntry[] = await this.fetchPage(0);
      this.entries = first;
      this.status = first.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
    } catch (error) {
      this.entries = [];
      this.status = UiState.ERROR;
      this.errorMsg = `${(error as Error).message}`;
    }
  }

  private async loadMore(): Promise<void> {
    if (this.loadingMore || this.entries.length >= this.total) {
      return;
    }
    this.loadingMore = true;
    this.moreError = '';
    try {
      const next: ActivityEntry[] = await this.fetchPage(this.entries.length);
      this.entries = this.entries.concat(next);
    } catch (error) {
      this.moreError = `${(error as Error).message}`;
    }
    this.loadingMore = false;
  }

  private iconFor(type: string): Resource {
    if (isPlayback(type)) {
      return $r('sys.symbol.play_circle');
    }
    if (isAuth(type)) {
      return $r('sys.symbol.key');
    }
    if (isLibrary(type)) {
      return $r('sys.symbol.folder');
    }
    if (type === 'SessionStarted' || type === 'SessionEnded') {
      return $r('sys.symbol.person');
    }
    return $r('sys.symbol.list_bullet');
  }

  build() {
    Column() {
      PageHeader({
        title: '活动',
        onBack: () => {
          router.back();
        }
      })

      if (this.status === UiState.SUCCESS) {
        Text(`最近 ${this.entries.length}${this.total > 0 ? ` / 共 ${this.total}` : ''} 条记录`
          + '（时间是设备本地时间）')
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
            ? '还没有活动记录。'
            : (this.errorMsg.length > 0 ? this.errorMsg : '加载失败'),
          actionLabel: '重试',
          onAction: () => {
            this.reload();
          }
        })
      } else {
        Scroll() {
          Column() {
            SectionCard({ title: '活动记录', icon: $r('sys.symbol.list_bullet'),
              showHeaderIcon: true }) {
              Column() {
                ForEach(this.entries, (entry: ActivityEntry, index: number) => {
                  Column() {
                    SettingCell({
                      title: entry.name,
                      subtitle: `${typeLabel(entry.type)} · ${formatTime(entry.date)}`,
                      subtitleColor: severityColor(this.colors(), entry.severity),
                      showIcon: true,
                      icon: this.iconFor(entry.type)
                    })
                    if (index < this.entries.length - 1) {
                      Divider().color(this.colors().divider).strokeWidth(0.5)
                    }
                  }
                  .width('100%')
                }, (entry: ActivityEntry) => `${entry.id}-${entry.date}`)
              }
              .width('100%')
            }

            if (this.entries.length < this.total) {
              Button(this.loadingMore ? '加载中…' : `加载更多（还有 ${this.total - this.entries.length} 条）`)
                .width('100%')
                .height(44)
                .backgroundColor(this.colors().surfacePressed)
                .fontColor(this.colors().textPrimary)
                .enabled(!this.loadingMore)
                .onClick(() => {
                  this.loadMore();
                })
              if (this.moreError.length > 0) {
                Text(this.moreError)
                  .fontSize(ThemeConstants.META_SMALL)
                  .fontColor(this.colors().error)
                  .width('100%')
                  .padding({ top: 6 })
              }
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
  }
}
