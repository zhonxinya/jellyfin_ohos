import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { AsyncStateView } from '../../components/AsyncStateView';

interface UserInfo {
  id: string;
  name: string;
  isAdmin: boolean;
  isDisabled: boolean;
  isHidden: boolean;
  policy: ESObject | null;
  configuration: ESObject | null;
}

const EMPTY_USER: UserInfo = {
  id: '',
  name: '',
  isAdmin: false,
  isDisabled: false,
  isHidden: false,
  policy: null,
  configuration: null
};

function parseUser(item: Object): UserInfo {
  const obj: ESObject = item as ESObject;
  const policy: ESObject | null = JsonUtil.getObject(obj, 'Policy');
  const policyLower: ESObject | null = policy === null ? JsonUtil.getObject(obj, 'policy') : policy;
  const configuration: ESObject | null = JsonUtil.getObject(obj, 'Configuration');
  const configurationLower: ESObject | null = configuration === null ? JsonUtil.getObject(obj, 'configuration') : configuration;
  return {
    id: JsonUtil.getString(obj, 'Id', JsonUtil.getString(obj, 'id', '')),
    name: JsonUtil.getString(obj, 'Name', JsonUtil.getString(obj, 'name', '未命名用户')),
    isAdmin: JsonUtil.getBoolean(policyLower, 'IsAdministrator',
      JsonUtil.getBoolean(policyLower, 'isAdministrator', false)),
    isDisabled: JsonUtil.getBoolean(policyLower, 'IsDisabled',
      JsonUtil.getBoolean(policyLower, 'isDisabled', false)),
    isHidden: JsonUtil.getBoolean(policyLower, 'IsHidden',
      JsonUtil.getBoolean(policyLower, 'isHidden', false)),
    policy: policyLower,
    configuration: configurationLower
  };
}

@Entry
@Component
struct UsersPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private users: UserInfo[] = [];
  @State private actionMessage: string = '';
  @State private actionBusy: boolean = false;
  @State private loggedInUserId: string = '';

  @State private showCreateForm: boolean = false;
  @State private createName: string = '';
  @State private createPassword: string = '';

  @State private editingUser: UserInfo | null = null;
  @State private editPolicy: ESObject | null = null;
  @State private editConfiguration: ESObject | null = null;

  @State private showDeleteConfirm: boolean = false;
  @State private pendingDelete: UserInfo = EMPTY_USER;
  @State private showAdminConfirm: boolean = false;
  @State private pendingAdminValue: boolean = false;
  @State private adminChangeConfirmed: boolean = false;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.loggedInUserId = this.detectCurrentUserId();
    this.reload();
  }

  private detectCurrentUserId(): string {
    const result: NativeResult = JellyfinNative.parseResult(JellyfinNative.getSession());
    if (!result.ok || result.data === null) {
      return '';
    }
    return JsonUtil.getString(result.data, 'userId', JsonUtil.getString(result.data, 'UserId', ''));
  }

  private async reload(): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.adminListUsers());
    if (!result.ok) {
      this.users = [];
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载用户失败';
      return;
    }
    const items: Object[] = JsonUtil.extractItems(result.data);
    const parsed: UserInfo[] = [];
    for (let i = 0; i < items.length; i++) {
      const user: UserInfo = parseUser(items[i]);
      if (user.id.length > 0) {
        parsed.push(user);
      }
    }
    this.users = parsed;
    this.status = parsed.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private cloneObject(source: ESObject | null): ESObject {
    const copy: ESObject | null = JsonUtil.parseObject(JsonUtil.toPretty(source));
    if (copy !== null) {
      return copy;
    }
    const empty: ESObject | null = JsonUtil.parseObject('{}');
    return empty === null ? ({} as ESObject) : empty;
  }

  private encoded(value: string): string {
    return encodeURIComponent(value);
  }

  private actionError(raw: string, fallback: string): string {
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) {
      return '';
    }
    return result.message.length > 0 ? result.message : fallback;
  }

  private isCurrentLoggedInAdmin(user: UserInfo): boolean {
    const vm: AppViewModel = AppViewModel.getInstance();
    if (!vm.isAdmin) {
      return false;
    }
    if (this.loggedInUserId.length > 0 && user.id === this.loggedInUserId) {
      return true;
    }
    return vm.userName.length > 0 && user.name === vm.userName;
  }

  private async createUser(): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    const name: string = this.createName.trim();
    if (name.length === 0) {
      this.actionMessage = '请输入用户名';
      return;
    }
    this.actionBusy = true;
    this.actionMessage = '';
    const password: string = this.createPassword;
    const body: string = password.length > 0
      ? JSON.stringify({ Name: name, Password: password })
      : JSON.stringify({ Name: name });
    const message: string = this.actionError(
      await JellyfinNative.adminGenericPost('/Users/New', body), '创建用户失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionMessage = message;
      return;
    }
    this.showCreateForm = false;
    this.createName = '';
    this.createPassword = '';
    this.actionMessage = '用户已创建';
    this.reload();
  }

  private requestDelete(user: UserInfo): void {
    if (this.actionBusy) {
      return;
    }
    if (this.isCurrentLoggedInAdmin(user)) {
      this.actionMessage = '为避免锁定当前会话，不能删除当前登录管理员';
      return;
    }
    this.pendingDelete = user;
    this.showDeleteConfirm = true;
  }

  private async deleteUser(): Promise<void> {
    if (this.actionBusy || this.pendingDelete.id.length === 0) {
      return;
    }
    if (this.isCurrentLoggedInAdmin(this.pendingDelete)) {
      this.showDeleteConfirm = false;
      this.actionMessage = '为避免锁定当前会话，不能删除当前登录管理员';
      return;
    }
    this.showDeleteConfirm = false;
    this.actionBusy = true;
    this.actionMessage = '';
    const path: string = `/Users/${this.encoded(this.pendingDelete.id)}`;
    const message: string = this.actionError(await JellyfinNative.adminGenericDelete(path), '删除用户失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionMessage = message;
      return;
    }
    this.actionMessage = `用户“${this.pendingDelete.name}”已删除`;
    this.pendingDelete = EMPTY_USER;
    this.reload();
  }

  private async openEdit(user: UserInfo): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    this.actionMessage = '';
    const detailResult: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGenericGet(`/Users/${this.encoded(user.id)}`));
    if (!detailResult.ok || detailResult.data === null) {
      this.actionMessage = detailResult.message.length > 0 ? detailResult.message : '加载用户详情失败';
      return;
    }
    const detail: UserInfo = parseUser(detailResult.data as Object);
    this.editingUser = detail;
    this.editPolicy = this.cloneObject(detail.policy);
    this.editConfiguration = this.cloneObject(detail.configuration);
    this.adminChangeConfirmed = false;
  }

  private closeEdit(): void {
    if (this.actionBusy) {
      return;
    }
    this.editingUser = null;
    this.editPolicy = null;
    this.editConfiguration = null;
  }

  private policyBoolean(key: string): boolean {
    return JsonUtil.getBoolean(this.editPolicy, key, false);
  }

  private configurationBoolean(key: string): boolean {
    return JsonUtil.getBoolean(this.editConfiguration, key, false);
  }

  private configurationText(key: string): string {
    return JsonUtil.getString(this.editConfiguration, key, '');
  }

  private updateObjectBoolean(source: ESObject | null, key: string, value: boolean): ESObject {
    const copy: ESObject = this.cloneObject(source);
    const map: Record<string, Object> = copy as Record<string, Object>;
    map[key] = value as Object;
    return copy;
  }

  private updateObjectText(source: ESObject | null, key: string, value: string): ESObject {
    const copy: ESObject = this.cloneObject(source);
    const map: Record<string, Object> = copy as Record<string, Object>;
    map[key] = value as Object;
    return copy;
  }

  private requestAdminChange(value: boolean): void {
    if (this.editingUser === null || this.actionBusy) {
      return;
    }
    if (this.isCurrentLoggedInAdmin(this.editingUser)) {
      this.actionMessage = '为避免锁定当前会话，不能修改当前登录管理员';
      return;
    }
    this.pendingAdminValue = value;
    this.adminChangeConfirmed = false;
    this.showAdminConfirm = true;
  }

  private confirmAdminChange(): void {
    if (this.actionBusy || this.editingUser === null) {
      return;
    }
    if (this.isCurrentLoggedInAdmin(this.editingUser)) {
      this.showAdminConfirm = false;
      this.actionMessage = '为避免锁定当前会话，不能修改当前登录管理员';
      return;
    }
    this.editPolicy = this.updateObjectBoolean(this.editPolicy, 'IsAdministrator', this.pendingAdminValue);
    this.adminChangeConfirmed = true;
    this.showAdminConfirm = false;
  }

  private async saveUser(): Promise<void> {
    if (this.actionBusy || this.editingUser === null || this.editPolicy === null ||
      this.editConfiguration === null) {
      return;
    }
    if (this.isCurrentLoggedInAdmin(this.editingUser)) {
      this.actionMessage = '为避免锁定当前会话，不能修改当前登录管理员';
      return;
    }
    if (this.policyBoolean('IsAdministrator') !== this.editingUser.isAdmin && !this.adminChangeConfirmed) {
      this.pendingAdminValue = this.policyBoolean('IsAdministrator');
      this.showAdminConfirm = true;
      return;
    }
    this.actionBusy = true;
    this.actionMessage = '';
    const userId: string = this.editingUser.id;
    const policyPath: string = `/Users/${this.encoded(userId)}/Policy`;
    const policyMessage: string = this.actionError(
      await JellyfinNative.adminGenericPost(policyPath, JsonUtil.toPretty(this.editPolicy)), '保存用户策略失败');
    if (policyMessage.length > 0) {
      this.actionBusy = false;
      this.actionMessage = policyMessage;
      return;
    }
    const configurationPath: string = `/Users/Configuration?userId=${this.encoded(userId)}`;
    const configurationMessage: string = this.actionError(
      await JellyfinNative.adminGenericPost(configurationPath, JsonUtil.toPretty(this.editConfiguration)), '保存用户配置失败');
    this.actionBusy = false;
    if (configurationMessage.length > 0) {
      this.actionMessage = configurationMessage;
      return;
    }
    this.actionMessage = '用户设置已保存';
    this.closeEdit();
    this.reload();
  }

  @Builder
  UserCard(user: UserInfo) {
    Row({ space: 10 }) {
      Column({ space: 5 }) {
        Row({ space: 8 }) {
          Text(user.name)
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().onSurface)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .layoutWeight(1)
          if (user.isAdmin) {
            Text('管理员')
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onPrimary)
              .backgroundColor(this.colors().primary)
              .padding({ left: 6, right: 6, top: 2, bottom: 2 })
              .borderRadius(4)
          }
        }
        Text(`ID：${user.id}`)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(user.isDisabled ? '已禁用' : (user.isHidden ? '隐藏用户' : '可登录'))
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(user.isDisabled ? this.colors().error : this.colors().onSurfaceVariant)
      }
      .layoutWeight(1)
      Button('编辑')
        .height(36)
        .padding({ left: 12, right: 12 })
        .backgroundColor(this.colors().surfaceElevated)
        .fontColor(this.colors().onSurface)
        .enabled(!this.actionBusy)
        .onClick(() => {
          this.openEdit(user);
        })
      Button('删除')
        .height(36)
        .padding({ left: 12, right: 12 })
        .backgroundColor(this.colors().destructive)
        .fontColor(this.colors().onPrimary)
        .enabled(!this.actionBusy && !this.isCurrentLoggedInAdmin(user))
        .onClick(() => {
          this.requestDelete(user);
        })
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(10)
  }

  @Builder
  ToggleRow(label: string, key: string, policy: boolean) {
    Row() {
      Text(label)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().onSurface)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: policy })
        .selectedColor(this.colors().primary)
        .enabled(!this.actionBusy && this.editingUser !== null && !this.isCurrentLoggedInAdmin(this.editingUser))
        .onChange((value: boolean) => {
          if (key === 'IsAdministrator') {
            this.requestAdminChange(value);
          } else {
            this.editPolicy = this.updateObjectBoolean(this.editPolicy, key, value);
          }
        })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  ConfigurationToggleRow(label: string, key: string) {
    Row() {
      Text(label)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().onSurface)
        .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: this.configurationBoolean(key) })
        .selectedColor(this.colors().primary)
        .enabled(!this.actionBusy && this.editingUser !== null && !this.isCurrentLoggedInAdmin(this.editingUser))
        .onChange((value: boolean) => {
          this.editConfiguration = this.updateObjectBoolean(this.editConfiguration, key, value);
        })
    }
    .width('100%')
    .padding({ top: 8, bottom: 8 })
  }

  @Builder
  EditForm() {
    if (this.editingUser !== null) {
      Column() {
        Column({ space: 10 }) {
          Text(`编辑用户：${this.editingUser.name}`)
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().onSurface)
            .width('100%')
          if (this.isCurrentLoggedInAdmin(this.editingUser)) {
            Text('当前登录管理员受保护，不能删除或修改。')
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().error)
              .width('100%')
          }
          Text('用户策略')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
          this.ToggleRow('管理员', 'IsAdministrator', this.policyBoolean('IsAdministrator'))
          this.ToggleRow('禁用登录', 'IsDisabled', this.policyBoolean('IsDisabled'))
          this.ToggleRow('隐藏用户', 'IsHidden', this.policyBoolean('IsHidden'))
          this.ToggleRow('允许媒体播放', 'EnableMediaPlayback', this.policyBoolean('EnableMediaPlayback'))
          this.ToggleRow('允许远程访问', 'EnableRemoteAccess', this.policyBoolean('EnableRemoteAccess'))
          this.ToggleRow('允许视频转码', 'EnableVideoPlaybackTranscoding', this.policyBoolean('EnableVideoPlaybackTranscoding'))
          this.ToggleRow('允许音频转码', 'EnableAudioPlaybackTranscoding', this.policyBoolean('EnableAudioPlaybackTranscoding'))
          this.ToggleRow('允许下载', 'EnableContentDownloading', this.policyBoolean('EnableContentDownloading'))
          Text('用户偏好')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
          TextInput({ text: this.configurationText('AudioLanguagePreference'), placeholder: '音频语言偏好（可选）' })
            .width('100%')
            .enabled(!this.actionBusy && !this.isCurrentLoggedInAdmin(this.editingUser))
            .onChange((value: string) => {
              this.editConfiguration = this.updateObjectText(this.editConfiguration, 'AudioLanguagePreference', value);
            })
          TextInput({ text: this.configurationText('SubtitleLanguagePreference'), placeholder: '字幕语言偏好（可选）' })
            .width('100%')
            .enabled(!this.actionBusy && !this.isCurrentLoggedInAdmin(this.editingUser))
            .onChange((value: string) => {
              this.editConfiguration = this.updateObjectText(this.editConfiguration, 'SubtitleLanguagePreference', value);
            })
          this.ConfigurationToggleRow('自动播放下一集', 'EnableNextEpisodeAutoPlay')
          this.ConfigurationToggleRow('播放默认音轨', 'PlayDefaultAudioTrack')
          this.ConfigurationToggleRow('记住音轨选择', 'RememberAudioSelections')
          this.ConfigurationToggleRow('记住字幕选择', 'RememberSubtitleSelections')
          if (this.actionMessage.length > 0) {
            Text(this.actionMessage)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().error)
              .width('100%')
          }
          Row({ space: 8 }) {
            Button('取消')
              .layoutWeight(1)
              .backgroundColor(this.colors().surfaceElevated)
              .fontColor(this.colors().onSurface)
              .enabled(!this.actionBusy)
              .onClick(() => {
                this.closeEdit();
              })
            Button(this.actionBusy ? '保存中...' : '保存')
              .layoutWeight(1)
              .backgroundColor(this.colors().primary)
              .fontColor(this.colors().onPrimary)
              .enabled(!this.actionBusy && !this.isCurrentLoggedInAdmin(this.editingUser))
              .onClick(() => {
                this.saveUser();
              })
          }
          .width('100%')
        }
        .padding(20)
        .backgroundColor(this.colors().cardBackground)
        .borderRadius(12)
        .width('90%')
        .onClick(() => {
          // Keep dialog content clicks from dismissing the scrim.
        })
      }
      .width('100%')
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .backgroundColor(this.colors().scrim)
      .onClick(() => {
        this.closeEdit();
      })
    }
  }

  build() {
    Stack() {
      Column() {
        PageHeader({ title: '用户', onBack: () => { router.back(); } })
        if (this.actionMessage.length > 0 && !this.showCreateForm && this.editingUser === null && !this.showDeleteConfirm && !this.showAdminConfirm) {
          Text(this.actionMessage)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.actionMessage.indexOf('失败') >= 0 || this.actionMessage.indexOf('不能') >= 0 ? this.colors().error : this.colors().success)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 6 })
        }
        if (this.status !== UiState.SUCCESS) {
          AsyncStateView({
            status: this.status,
            message: this.errorMsg,
            emptyHint: '当前没有用户',
            minHeight: 200,
            onRetry: () => { this.reload(); }
          })
        } else {
          List({ space: 8 }) {
            ForEach(this.users, (user: UserInfo) => {
              ListItem() { this.UserCard(user) }
            }, (user: UserInfo) => user.id)
          }
          .layoutWeight(1)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 80 })
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().background)

      if (!this.showCreateForm && this.editingUser === null && !this.showDeleteConfirm && !this.showAdminConfirm) {
        Button('+')
          .width(56)
          .height(56)
          .fontSize(ThemeConstants.ICON_XXL)
          .fontColor(this.colors().onPrimary)
          .backgroundColor(this.colors().primary)
          .borderRadius(28)
          .position({ x: '90%', y: '85%' })
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.actionMessage = '';
            this.showCreateForm = true;
          })
      }

      if (this.showCreateForm) {
        Column() {
          Column({ space: 12 }) {
            Text('新增用户')
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().onSurface)
              .width('100%')
            TextInput({ text: this.createName, placeholder: '用户名' })
              .width('100%')
              .enabled(!this.actionBusy)
              .onChange((value: string) => { this.createName = value; })
            TextInput({ text: this.createPassword, placeholder: '密码（可选）' })
              .width('100%')
              .type(InputType.Password)
              .enabled(!this.actionBusy)
              .onChange((value: string) => { this.createPassword = value; })
            if (this.actionMessage.length > 0) {
              Text(this.actionMessage)
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().error)
                .width('100%')
            }
            Row({ space: 8 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(this.colors().surfaceElevated)
                .fontColor(this.colors().onSurface)
                .enabled(!this.actionBusy)
                .onClick(() => {
                  this.showCreateForm = false;
                  this.createName = '';
                  this.createPassword = '';
                  this.actionMessage = '';
                })
              Button(this.actionBusy ? '创建中...' : '创建')
                .layoutWeight(1)
                .backgroundColor(this.colors().primary)
                .fontColor(this.colors().onPrimary)
                .enabled(!this.actionBusy)
                .onClick(() => { this.createUser(); })
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
          if (!this.actionBusy) {
            this.showCreateForm = false;
            this.actionMessage = '';
          }
        })
      }

      if (this.showDeleteConfirm) {
        Column() {
          Column({ space: 12 }) {
            Text('删除用户？')
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().onSurface)
              .width('100%')
            Text(`确认删除用户“${this.pendingDelete.name}”？此操作不可撤销。`)
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textSecondary)
              .width('100%')
            Row({ space: 8 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(this.colors().surfaceElevated)
                .fontColor(this.colors().onSurface)
                .enabled(!this.actionBusy)
                .onClick(() => { this.showDeleteConfirm = false; })
              Button(this.actionBusy ? '处理中...' : '删除')
                .layoutWeight(1)
                .backgroundColor(this.colors().destructive)
                .fontColor(this.colors().onPrimary)
                .enabled(!this.actionBusy)
                .onClick(() => { this.deleteUser(); })
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
        .onClick(() => { this.showDeleteConfirm = false; })
      }

      if (this.showAdminConfirm) {
        Column() {
          Column({ space: 12 }) {
            Text('确认修改管理员权限？')
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().onSurface)
              .width('100%')
            Text(this.pendingAdminValue ? '该用户将获得管理员权限。请确认你了解此权限范围。' : '该用户将失去管理员权限。')
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textSecondary)
              .width('100%')
            Row({ space: 8 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(this.colors().surfaceElevated)
                .fontColor(this.colors().onSurface)
                .enabled(!this.actionBusy)
                .onClick(() => { this.showAdminConfirm = false; })
              Button(this.actionBusy ? '处理中...' : '确认')
                .layoutWeight(1)
                .backgroundColor(this.colors().primary)
                .fontColor(this.colors().onPrimary)
                .enabled(!this.actionBusy)
                .onClick(() => { this.confirmAdminChange(); })
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
        .onClick(() => { this.showAdminConfirm = false; })
      }

      if (this.editingUser !== null && !this.showAdminConfirm) {
        this.EditForm()
      }
    }
    .width('100%')
    .height('100%')
  }
}
