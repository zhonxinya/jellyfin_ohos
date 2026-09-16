import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

interface TaskInfo {
  id: string;
  name: string;
  state: string;
}

function parseTask(item: Object): TaskInfo {
  const obj: ESObject = item as ESObject;
  return {
    id: JsonUtil.itemId(item),
    name: JsonUtil.itemName(item),
    state: JsonUtil.getString(obj, 'State', JsonUtil.getString(obj, 'state', 'Unknown'))
  };
}

function taskStateLabel(state: string): string {
  if (state === 'Running') return '运行中';
  if (state === 'Queued') return '排队中';
  if (state === 'Cancelling') return '停止中';
  if (state === 'Idle') return '空闲';
  return state;
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
  @State private pendingTask: TaskInfo = { id: '', name: '', state: '' };

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
    this.pendingTask = { id: '', name: '', state: '' };
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
        Text(`${taskStateLabel(task.state)} · ${task.id}`)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
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
        if (this.status !== UiState.SUCCESS) {
          if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
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
