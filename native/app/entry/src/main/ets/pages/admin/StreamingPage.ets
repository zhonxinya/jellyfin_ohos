import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { UiState } from '../../common/UiState';
import { JsonUtil } from '../../common/JsonUtil';
import { AdminConfigEditor, AdminConfigField, AdminConfigValue } from '../../components/AdminConfigEditor';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';
import { PageHeader } from '../../components/PageHeader';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';

const STREAMING_FIELDS: AdminConfigField[] = [
  new AdminConfigField('EnableUPnP', '启用 UPnP', 'toggle'),
  new AdminConfigField('EnableRemoteAccess', '允许远程访问', 'toggle'),
  new AdminConfigField('EnableRemoteControl', '允许远程控制', 'toggle'),
  new AdminConfigField('PublicHttpPort', '公网 HTTP 端口', 'number'),
  new AdminConfigField('PublicHttpsPort', '公网 HTTPS 端口', 'number'),
  new AdminConfigField('InternalHttpPort', '内部 HTTP 端口', 'number'),
  new AdminConfigField('InternalHttpsPort', '内部 HTTPS 端口', 'number'),
  new AdminConfigField('EnableHttps', '启用 HTTPS', 'toggle'),
  new AdminConfigField('RequireHttps', '要求 HTTPS', 'toggle'),
  new AdminConfigField('AutoDiscovery', '启用自动发现', 'toggle')
];

@Entry
@Component
struct StreamingPage {
  @State private status: string = UiState.LOADING;
  @State private draft: ESObject | null = null;
  @State private saving: boolean = false;
  @State private message: string = '';
  @State private messageError: boolean = false;

  private colors(): ThemeColors { return AppViewModel.getInstance().colors(); }

  aboutToAppear(): void { this.reload(); }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGenericGet('/System/Configuration/network'));
    if (result.ok && result.data !== null) {
      this.draft = result.data;
      this.status = UiState.SUCCESS;
    } else {
      this.draft = null;
      this.status = UiState.ERROR;
    }
  }

  private update(key: string, value: AdminConfigValue): void {
    if (this.draft === null) return;
    const copy: ESObject | null = JsonUtil.parseObject(JsonUtil.toPretty(this.draft));
    if (copy === null) return;
    const map: Record<string, Object> = copy as Record<string, Object>;
    map[key] = value as Object;
    this.draft = copy;
  }

  private async save(): Promise<void> {
    if (this.saving || this.draft === null) return;
    this.saving = true;
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGenericPost('/System/Configuration/network', JsonUtil.toPretty(this.draft)));
    if (result.ok) {
      this.message = '保存成功';
      this.messageError = false;
      this.saving = false;
      this.reload();
    } else {
      this.message = '保存失败，请检查服务器连接和权限';
      this.messageError = true;
      this.saving = false;
    }
  }

  build() {
    Column() {
      PageHeader({ title: '流媒体', onBack: () => { router.back(); } })
      if (this.status !== UiState.SUCCESS || this.draft === null) {
        if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState()
        } else if (this.status === UiState.ERROR) {
          EmptyState({
            message: '无法加载流媒体配置',
            actionLabel: '重试',
            onAction: () => { this.reload(); }
          })
        } else if (this.status === UiState.EMPTY) {
          EmptyState({ message: '暂无数据' })
        }
      } else {
        Scroll() {
          Column() {
            AdminConfigEditor({
              draft: this.draft, fields: STREAMING_FIELDS, saving: this.saving,
              message: this.message, messageError: this.messageError,
              onChange: (key: string, value: AdminConfigValue) => { this.update(key, value); },
              onSave: () => { this.save(); }
            })
          }
          .width('100%')
          .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
          .padding({ left: 16, right: 16, top: 8, bottom: 32 })
        }
        .layoutWeight(1).width('100%').scrollBar(BarState.Auto)
      }
    }
    .width('100%').height('100%').backgroundColor(this.colors().pageBackground)
  }
}
