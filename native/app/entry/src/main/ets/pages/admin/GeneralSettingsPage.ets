import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { UiState } from '../../common/UiState';
import { JsonUtil } from '../../common/JsonUtil';
import { AdminConfigEditor, AdminConfigField, AdminConfigValue } from '../../components/AdminConfigEditor';
import { AsyncStateView } from '../../components/AsyncStateView';
import { PageHeader } from '../../components/PageHeader';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';

const GENERAL_FIELDS: AdminConfigField[] = [
  new AdminConfigField('ServerName', '服务器名称', 'text'),
  new AdminConfigField('UICulture', '界面语言', 'text'),
  new AdminConfigField('MetadataCountryCode', '元数据国家/地区', 'text'),
  new AdminConfigField('PreferredMetadataLanguage', '首选元数据语言', 'text'),
  new AdminConfigField('EnableMetrics', '允许遥测', 'toggle'),
  new AdminConfigField('EnableExternalContentInSuggestions', '允许推荐中的外部内容', 'toggle')
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
        AsyncStateView({
          status: this.status,
          message: '无法加载服务器配置',
          onRetry: () => { this.reload(); }
        })
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
