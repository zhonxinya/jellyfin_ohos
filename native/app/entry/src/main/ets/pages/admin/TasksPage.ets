import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';
import { TimeFormat } from '../../common/TimeFormat';

interface TaskInfo {
  id: string;
  name: string;
  state: string;
  /** 上次执行结果：`Completed` / `Failed` / `Aborted` / `Cancelled`；没跑过就是空串 */
  lastStatus: string;
  lastStart: string;
  lastEnd: string;
  lastError: string;
}

/** 空占位（`pendingTask` 的初始值 / 停止后复位） */
function emptyTask(): TaskInfo {
  return { id: '', name: '', state: '', lastStatus: '', lastStart: '', lastEnd: '', lastError: '' };
}

function parseTask(item: Object): TaskInfo {  const obj: ESObject = item as ESObject;
  const last: ESObject | null = JsonUtil.getObject(obj, 'LastExecutionResult');
  return {
    id: JsonUtil.itemId(item),
    name: JsonUtil.itemName(item),
    state: JsonUtil.getString(obj, 'State', JsonUtil.getString(obj, 'state', 'Unknown')),
    lastStatus: JsonUtil.getString(last, 'Status', ''),
    lastStart: JsonUtil.getString(last, 'StartTimeUtc', ''),
    lastEnd: JsonUtil.getString(last, 'EndTimeUtc', ''),
    lastError: JsonUtil.getString(last, 'ErrorMessage', '')
  };
}

function taskStateLabel(state: string): string {
  if (state === 'Running') return '运行中';
  if (state === 'Queued') return '排队中';
  if (state === 'Cancelling') return '停止中';
  if (state === 'Idle') return '空闲';
  return state;
}

/** 服务端 `TaskCompletionStatus` 的中文标签 */
function taskResultLabel(status: string): string {
  if (status === 'Completed') return '成功';
  if (status === 'Failed') return '失败';
  if (status === 'Aborted') return '已中止';
  if (status === 'Cancelled') return '已取消';
  return status;
}

/**
 * 卡片副标题：状态 + 上次执行（时间、结果、耗时）。
 *
 * 原来这里显示的是 `状态 · <32 位任务 id>` —— 那个 GUID 对用户没有任何意义，
 * 而服务端 `LastExecutionResult` 里其实带着上次执行时间、结果与耗时。
 */
function taskSubtitle(task: TaskInfo): string {
  if (task.lastStart.length === 0) {
    return `${taskStateLabel(task.state)} · 还没执行过`;
  }
  const parts: string[] = [`${taskStateLabel(task.state)} · 上次 ${TimeFormat.full(task.lastStart)}`];
  if (task.lastStatus.length > 0) {
    parts.push(taskResultLabel(task.lastStatus));
  }
  const took: string = TimeFormat.durationLabel(
    TimeFormat.durationSeconds(task.lastStart, task.lastEnd));
  if (took.length > 0) {
    parts.push(`耗时 ${took}`);
  }
  return parts.join(' · ');
}

/** 上次执行失败时的红字提示；没失败就是空串 */
function taskErrorLine(task: TaskInfo): string {
  if (task.lastStatus !== 'Failed') {
    return '';
  }
  return task.lastError.length > 0 ? `上次失败：${task.lastError}` : '上次执行失败';
}

@Entry
@Component
struct TasksPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private tasks: TaskInfo[] = [];
  @State private actionMessage: string = '';
  @State private actionBusy: boolean = false;
  @State private showStopConfirm: boolean = false;
  @State private pendingTask: TaskInfo = emptyTask();

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.adminListTasks());
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载任务失败';
      return;
    }
    const items: Object[] = JsonUtil.extractItems(result.data);
    const parsed: TaskInfo[] = [];
    for (let i = 0; i < items.length; i++) {
      parsed.push(parseTask(items[i]));
    }
    this.tasks = parsed;
    this.status = parsed.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private actionError(raw: string, fallback: string): string {
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) return '';
    return result.message.length > 0 ? result.message : fallback;
  }

  private async startTask(task: TaskInfo): Promise<void> {
    if (this.actionBusy || task.id.length === 0) return;
    this.actionBusy = true;
    this.actionMessage = '';
    const path: string = `/ScheduledTasks/Running/${encodeURIComponent(task.id)}`;
    const message: string = this.actionError(await JellyfinNative.adminGenericPostNoBody(path), '启动任务失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionMessage = message;
      return;
    }
    this.actionMessage = `任务“${task.name}”已启动`;
    this.reload();
  }

  private requestStop(task: TaskInfo): void {
    if (this.actionBusy || task.id.length === 0) return;
    this.pendingTask = task;
    this.showStopConfirm = true;
  }

  private async stopTask(): Promise<void> {
    if (this.actionBusy || this.pendingTask.id.length === 0) return;
    this.showStopConfirm = false;
    this.actionBusy = true;
    this.actionMessage = '';
    const path: string = `/ScheduledTasks/Running/${encodeURIComponent(this.pendingTask.id)}`;
    const message: string = this.actionError(await JellyfinNative.adminGenericDelete(path), '停止任务失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionMessage = message;
      return;
    }
    this.actionMessage = `任务“${this.pendingTask.name}”已停止`;
    this.pendingTask = emptyTask();
    this.reload();
  }

  @Builder
  TaskCard(task: TaskInfo) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(task.name)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(taskSubtitle(task))
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .width('100%')
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (taskErrorLine(task).length > 0) {
          Text(taskErrorLine(task))
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().error)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      Row({ space: 6 }) {
        if (task.state === 'Running' || task.state === 'Cancelling') {
          Button('停止')
            .height(36)
            .padding({ left: 12, right: 12 })
            .backgroundColor(this.colors().errorLight)
            .fontColor(this.colors().onBrand)
            .enabled(!this.actionBusy && task.state === 'Running')
            .onClick(() => {
              this.requestStop(task);
            })
        } else {
          Button('启动')
            .height(36)
            .padding({ left: 12, right: 12 })
            .backgroundColor(this.colors().brandPrimary)
            .fontColor(this.colors().onBrand)
            .enabled(!this.actionBusy)
            .onClick(() => {
              this.startTask(task);
            })
        }
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(10)
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '计划任务',
          onBack: () => {
            router.back();
          }
        })
        if (this.actionMessage.length > 0) {
          Text(this.actionMessage)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.actionMessage.indexOf('失败') >= 0 ? this.colors().error : this.colors().success)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 6 })
        }
        if (this.status !== UiState.SUCCESS) {          if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
            LoadingState()
          } else if (this.status === UiState.ERROR) {
            EmptyState({
              message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
              actionLabel: '重试',
              onAction: () => {
                this.reload();
              }
            })
          } else if (this.status === UiState.EMPTY) {
            EmptyState({ message: '当前没有计划任务' })
          }
        } else {
          List({ space: 8 }) {
            ForEach(this.tasks, (task: TaskInfo) => {
              ListItem() {
                this.TaskCard(task)
              }
            }, (task: TaskInfo) => task.id)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 16 })
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.showStopConfirm) {
        Column() {
          Column({ space: 12 }) {
            Text('停止计划任务？')
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .width('100%')
            Text(`确认停止“${this.pendingTask.name}”？`)
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textSecondary)
              .width('100%')
            Row({ space: 8 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(this.colors().surfacePressed)
                .fontColor(this.colors().textPrimary)
                .onClick(() => {
                  this.showStopConfirm = false;
                })
              Button(this.actionBusy ? '处理中...' : '停止')
                .layoutWeight(1)
                .backgroundColor(this.colors().errorLight)
                .fontColor(this.colors().onBrand)
                .enabled(!this.actionBusy)
                .onClick(() => {
                  this.stopTask();
                })
            }
            .width('100%')
          }
          .padding(20)
          .backgroundColor(this.colors().cardBackground)
          .borderRadius(12)
          .width('85%')
          .onClick(() => {
            // Keep dialog content clicks from dismissing the scrim.
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.showStopConfirm = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
