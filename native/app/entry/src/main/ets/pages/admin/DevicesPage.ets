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

interface DeviceInfo {
  id: string;
  name: string;
  appName: string;
  userName: string;
  lastActivity: string;
}

function parseDevice(item: Object): DeviceInfo {
  const obj: ESObject = item as ESObject;
  return {
    id: JsonUtil.getString(obj, 'Id', JsonUtil.getString(obj, 'DeviceId', JsonUtil.getString(obj, 'id', ''))),
    name: JsonUtil.getString(obj, 'Name', JsonUtil.getString(obj, 'DeviceName', '未命名设备')),
    appName: JsonUtil.getString(obj, 'AppName', JsonUtil.getString(obj, 'Client', '')),
    userName: JsonUtil.getString(obj, 'LastUserName', JsonUtil.getString(obj, 'UserName', '')),
    lastActivity: JsonUtil.getString(obj, 'DateLastActivity', JsonUtil.getString(obj, 'LastActivityDate', ''))
  };
}

@Entry
@Component
struct DevicesPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private devices: DeviceInfo[] = [];
  @State private actionMessage: string = '';
  @State private actionBusy: boolean = false;
  @State private showLogoutConfirm: boolean = false;
  @State private pendingDevice: DeviceInfo = { id: '', name: '', appName: '', userName: '', lastActivity: '' };

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.adminListDevices());
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载设备失败';
      return;
    }
    const items: Object[] = JsonUtil.extractItems(result.data);
    const parsed: DeviceInfo[] = [];
    for (let i = 0; i < items.length; i++) {
      const device: DeviceInfo = parseDevice(items[i]);
      if (device.id.length > 0) parsed.push(device);
    }
    // 按最后活动时间倒序：设备会越攒越多（每次装应用都会注册一台），
    // 想找的那台几乎总是最近在用的那台。ISO（UTC）按字典序比较就是按时间比较。
    parsed.sort((a: DeviceInfo, b: DeviceInfo) => {
      if (a.lastActivity === b.lastActivity) {
        return a.name < b.name ? -1 : 1;
      }
      return a.lastActivity < b.lastActivity ? 1 : -1;
    });
    this.devices = parsed;
    this.status = parsed.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private actionError(raw: string, fallback: string): string {
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) return '';
    return result.message.length > 0 ? result.message : fallback;
  }

  private requestLogout(device: DeviceInfo): void {
    if (this.actionBusy) return;
    this.pendingDevice = device;
    this.showLogoutConfirm = true;
  }

  private async logoutDevice(): Promise<void> {
    if (this.actionBusy || this.pendingDevice.id.length === 0) return;
    this.showLogoutConfirm = false;
    this.actionBusy = true;
    this.actionMessage = '';
    const path: string = `/Devices?id=${encodeURIComponent(this.pendingDevice.id)}`;
    const message: string = this.actionError(await JellyfinNative.adminGenericDelete(path), '设备注销失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionMessage = message;
      return;
    }
    this.actionMessage = `设备“${this.pendingDevice.name}”已注销`;
    this.pendingDevice = { id: '', name: '', appName: '', userName: '', lastActivity: '' };
    this.reload();
  }

  @Builder
  DeviceCard(device: DeviceInfo) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(device.name)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (device.appName.length > 0) {
          Text(device.appName)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
        }
        if (device.userName.length > 0) {
          Text(`用户：${device.userName}`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
        }
        if (device.lastActivity.length > 0) {
          Text(`最后活动：${TimeFormat.full(device.lastActivity)}`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
        }
      }
      .layoutWeight(1)
      Button('注销')
        .height(36)
        .padding({ left: 12, right: 12 })
        .backgroundColor(this.colors().errorLight)
        .fontColor(this.colors().onBrand)
        .enabled(!this.actionBusy)
        .onClick(() => {
          this.requestLogout(device);
        })
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
          title: '设备',
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
            EmptyState({ message: '当前没有已注册设备' })
          }
        } else {
          Text(`共 ${this.devices.length} 台设备（按最后活动时间排列）`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 6 })
          List({ space: 8 }) {
            ForEach(this.devices, (device: DeviceInfo) => {
              ListItem() {
                this.DeviceCard(device)
              }
            }, (device: DeviceInfo) => device.id)
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

      if (this.showLogoutConfirm) {
        Column() {
          Column({ space: 12 }) {
            Text('注销设备？')
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .width('100%')
            Text(`确认注销设备“${this.pendingDevice.name}”？该设备将被移出已注册设备列表。`)
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textSecondary)
              .width('100%')
            Row({ space: 8 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(this.colors().surfacePressed)
                .fontColor(this.colors().textPrimary)
                .onClick(() => {
                  this.showLogoutConfirm = false;
                })
              Button(this.actionBusy ? '处理中...' : '注销')
                .layoutWeight(1)
                .backgroundColor(this.colors().errorLight)
                .fontColor(this.colors().onBrand)
                .enabled(!this.actionBusy)
                .onClick(() => {
                  this.logoutDevice();
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
          this.showLogoutConfirm = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
