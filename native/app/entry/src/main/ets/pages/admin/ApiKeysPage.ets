import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { AsyncStateView } from '../../components/AsyncStateView';

interface ApiKeyInfo {
  token: string;
  app: string;
  created: string;
  lastActivity: string;
}

function maskToken(token: string): string {
  if (token.length <= 8) return '********';
  return `${token.substring(0, 4)}****${token.substring(token.length - 4)}`;
}

function parseApiKey(item: Object): ApiKeyInfo {
  const obj: ESObject = item as ESObject;
  return {
    token: JsonUtil.getString(obj, 'AccessToken', JsonUtil.getString(obj, 'accessToken', '')),
    app: JsonUtil.getString(obj, 'AppName', JsonUtil.getString(obj, 'appName', JsonUtil.getString(obj, 'Name', '未命名应用'))),
    created: JsonUtil.getString(obj, 'DateCreated', JsonUtil.getString(obj, 'dateCreated', '')),
    lastActivity: JsonUtil.getString(obj, 'DateLastActivity', JsonUtil.getString(obj, 'dateLastActivity', ''))
  };
}

@Entry
@Component
struct ApiKeysPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private keys: ApiKeyInfo[] = [];
  @State private appName: string = '';
  @State private actionMessage: string = '';
  @State private actionBusy: boolean = false;
  @State private showRevokeConfirm: boolean = false;
  @State private pendingKey: ApiKeyInfo = { token: '', app: '', created: '', lastActivity: '' };

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.adminGenericGet('/Auth/Keys'));
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载 API Key 失败';
      return;
    }
    const items: Object[] = JsonUtil.extractItems(result.data);
    const parsed: ApiKeyInfo[] = [];
    for (let i = 0; i < items.length; i++) {
      const key: ApiKeyInfo = parseApiKey(items[i]);
      if (key.token.length > 0) parsed.push(key);
    }
    this.keys = parsed;
    this.status = parsed.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private actionError(raw: string, fallback: string): string {
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) return '';
    return result.message.length > 0 ? result.message : fallback;
  }

  private async createKey(): Promise<void> {
    if (this.actionBusy) return;
    const app: string = this.appName.trim();
    if (app.length === 0) {
      this.actionMessage = '请输入应用名称';
      return;
    }
    this.actionBusy = true;
    this.actionMessage = '';
    const path: string = `/Auth/Keys?app=${encodeURIComponent(app)}`;
    const message: string = this.actionError(await JellyfinNative.adminGenericPostNoBody(path), '创建 API Key 失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionMessage = message;
      return;
    }
    this.appName = '';
    this.actionMessage = 'API Key 已创建';
    this.reload();
  }

  private requestRevoke(key: ApiKeyInfo): void {
    if (this.actionBusy) return;
    this.pendingKey = key;
    this.showRevokeConfirm = true;
  }

  private async revokeKey(): Promise<void> {
    if (this.actionBusy || this.pendingKey.token.length === 0) return;
    this.showRevokeConfirm = false;
    this.actionBusy = true;
    this.actionMessage = '';
    const path: string = `/Auth/Keys/${encodeURIComponent(this.pendingKey.token)}`;
    const message: string = this.actionError(await JellyfinNative.adminGenericDelete(path), '撤销 API Key 失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionMessage = message;
      return;
    }
    this.actionMessage = `应用“${this.pendingKey.app}”的 API Key 已撤销`;
    this.pendingKey = { token: '', app: '', created: '', lastActivity: '' };
    this.reload();
  }

  @Builder
  KeyCard(key: ApiKeyInfo) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(key.app)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().onSurface)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(maskToken(key.token))
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().onSurfaceVariant)
          .width('100%')
          .maxLines(1)
        if (key.created.length > 0) {
          Text(`创建：${key.created}`)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onSurfaceVariant)
            .width('100%')
        }
        if (key.lastActivity.length > 0) {
          Text(`最后使用：${key.lastActivity}`)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onSurfaceVariant)
            .width('100%')
        }
      }
      .layoutWeight(1)
      Button('撤销')
        .height(36)
        .padding({ left: 12, right: 12 })
        .backgroundColor(this.colors().destructive)
        .fontColor(this.colors().onPrimary)
        .enabled(!this.actionBusy)
        .onClick(() => {
          this.requestRevoke(key);
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.colors().surface)
    .borderRadius(10)
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: 'API Keys',
          onBack: () => {
            router.back();
          }
        })
        Row({ space: 8 }) {
          TextInput({ text: this.appName, placeholder: '应用名称' })
            .layoutWeight(1)
            .height(44)
            .onChange((value: string) => {
              this.appName = value;
            })
          Button(this.actionBusy ? '创建中...' : '创建')
            .height(44)
            .backgroundColor(this.colors().primary)
            .fontColor(this.colors().onPrimary)
            .enabled(!this.actionBusy)
            .onClick(() => {
              this.createKey();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
        if (this.actionMessage.length > 0) {
          Text(this.actionMessage)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.actionMessage.indexOf('失败') >= 0 ? this.colors().error : this.colors().success)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 6 })
        }
        if (this.status !== UiState.SUCCESS) {
          AsyncStateView({
            status: this.status,
            message: this.errorMsg,
            emptyHint: '当前没有 API Key',
            minHeight: 200,
            onRetry: () => {
              this.reload();
            }
          })
        } else {
          List({ space: 8 }) {
            ForEach(this.keys, (key: ApiKeyInfo) => {
              ListItem() {
                this.KeyCard(key)
              }
            }, (key: ApiKeyInfo) => key.token)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 16 })
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().background)

      if (this.showRevokeConfirm) {
        Column() {
          Column({ space: 12 }) {
            Text('撤销 API Key？')
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().onSurface)
              .width('100%')
            Text(`确认撤销应用“${this.pendingKey.app}”的 API Key？`)
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().onSurfaceVariant)
              .width('100%')
            Text(maskToken(this.pendingKey.token))
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onSurfaceVariant)
              .width('100%')
            Row({ space: 8 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(this.colors().surfaceElevated)
                .fontColor(this.colors().onSurface)
                .onClick(() => {
                  this.showRevokeConfirm = false;
                })
              Button(this.actionBusy ? '处理中...' : '撤销')
                .layoutWeight(1)
                .backgroundColor(this.colors().destructive)
                .fontColor(this.colors().onPrimary)
                .enabled(!this.actionBusy)
                .onClick(() => {
                  this.revokeKey();
                })
            }
            .width('100%')
          }
          .padding(20)
          .backgroundColor(this.colors().surface)
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
          this.showRevokeConfirm = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
