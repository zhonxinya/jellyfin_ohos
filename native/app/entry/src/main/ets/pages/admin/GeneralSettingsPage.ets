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

const GENERAL_FIELDS: AdminConfigField[] = [
  new AdminConfigField('ServerName', '服务器名称', 'text',
    '客户端登录后看到的服务器名；留空则显示为 "Jellyfin"'),
  new AdminConfigField('UICulture', '界面语言', 'text',
    '服务端下发给 Web 客户端的界面语言（例如 zh-CN）；本应用的界面是中文，不受它影响'),
  new AdminConfigField('PreferredMetadataLanguage', '首选元数据语言', 'text',
    '全局默认的元数据语言（三字母码，例如 zh / eng）；单个媒体库可以在自己的选项里覆盖'),
  new AdminConfigField('MetadataCountryCode', '元数据国家/地区', 'text',
    '全局默认的国家代码（两字母，例如 CN）；影响分级与发行日期等地区字段'),
  new AdminConfigField('QuickConnectAvailable', '允许快速连接', 'toggle',
    '让新设备用「快速连接」配对，不必在这台设备上输入密码'),
  new AdminConfigField('MetadataPath', '元数据目录', 'text',
    '服务器存放元数据与图片的目录；改动后建议重启服务器'),
  new AdminConfigField('EnableMetrics', '允许遥测', 'toggle',
    '是否上报匿名使用数据'),
  new AdminConfigField('AllowClientLogUpload', '允许客户端上传日志', 'toggle',
    '允许客户端把本机日志发到服务器，便于排障'),
  new AdminConfigField('EnableSlowResponseWarning', '慢响应告警', 'toggle',
    '服务端响应过慢时写一条警告日志'),
  new AdminConfigField('SlowResponseThresholdMs', '慢响应阈值（毫秒）', 'number',
    '超过这个耗时才算"慢响应"'),
  new AdminConfigField('ActivityLogRetentionDays', '活动日志保留（天）', 'number',
    '超过天数的活动日志会被清理'),
  new AdminConfigField('LogFileRetentionDays', '日志文件保留（天）', 'number',
    '超过天数的日志文件会被删除'),
  new AdminConfigField('EnableExternalContentInSuggestions', '推荐里包含外部内容', 'toggle',
    '首页推荐里可以出现本服务器之外的内容'),
  new AdminConfigField('RemoveOldPlugins', '自动删除旧插件', 'toggle',
    '插件升级后自动删掉旧版本目录')
];

@Entry
@Component
struct GeneralSettingsPage {
  @State private status: string = UiState.LOADING;
  @State private draft: ESObject | null = null;
  @State private saving: boolean = false;
  @State private message: string = '';
  @State private messageError: boolean = false;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGenericGet('/System/Configuration'));
    if (result.ok && result.data !== null) {
      this.draft = result.data;
      this.status = UiState.SUCCESS;
    } else {
      this.draft = null;
      this.status = UiState.ERROR;
    }
  }

  private update(key: string, value: AdminConfigValue): void {
    if (this.draft === null) {
      return;
    }
    const copy: ESObject | null = JsonUtil.parseObject(JsonUtil.toPretty(this.draft));
    if (copy === null) {
      return;
    }
    const map: Record<string, Object> = copy as Record<string, Object>;
    map[key] = value as Object;
    this.draft = copy;
  }

  private async save(): Promise<void> {
    if (this.saving || this.draft === null) {
      return;
    }
    this.saving = true;
    this.message = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGenericPost('/System/Configuration', JsonUtil.toPretty(this.draft)));
    if (result.ok) {
      this.message = '保存成功';
      this.messageError = false;
      this.reload();
    } else {
      this.message = '保存失败，请检查服务器连接和权限';
      this.messageError = true;
    }
    this.saving = false;
  }

  build() {
    Column() {
      PageHeader({ title: '常规设置', onBack: () => { router.back(); } })
      if (this.status !== UiState.SUCCESS || this.draft === null) {
        if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState()
        } else if (this.status === UiState.ERROR) {
          EmptyState({
            message: '无法加载服务器配置',
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
              draft: this.draft,
              fields: GENERAL_FIELDS,
              saving: this.saving,
              message: this.message,
              messageError: this.messageError,
              onChange: (key: string, value: AdminConfigValue) => { this.update(key, value); },
              onSave: () => { this.save(); }
            })
          }
          .width('100%')
          .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
          .padding({ left: 16, right: 16, top: 8, bottom: 32 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
