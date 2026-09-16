import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

interface PluginPackageInfo {
  name: string;
  overview: string;
  version: string;
  assemblyGuid: string;
  installing: boolean;
  installationId: string;
}

function firstPackageVersion(obj: ESObject): string {
  const versions: Object[] = JsonUtil.getArray(obj, 'versions');
  const pascalVersions: Object[] = JsonUtil.getArray(obj, 'Versions');
  const availableVersions: Object[] = versions.length > 0 ? versions : pascalVersions;
  if (availableVersions.length === 0) {
    return '';
  }
  const version: ESObject = availableVersions[0] as ESObject;
  return JsonUtil.getString(version, 'version', JsonUtil.getString(version, 'Version',
    JsonUtil.getString(version, 'VersionNumber', '')));
}

function packageInstallationId(obj: ESObject): string {
  const directId: string = JsonUtil.getString(obj, 'InstallationId',
    JsonUtil.getString(obj, 'installationId', JsonUtil.getString(obj, 'PackageId',
      JsonUtil.getString(obj, 'packageId', ''))));
  if (directId.length > 0) {
    return directId;
  }
  const installation: ESObject | null = JsonUtil.getObject(obj, 'InstallationInfo');
  if (installation === null) {
    return '';
  }
  return JsonUtil.getString(installation, 'Guid', JsonUtil.getString(installation, 'guid', ''));
}

function isPackageInstalling(obj: ESObject, installationId: string): boolean {
  if (installationId.length === 0) {
    return false;
  }
  if (JsonUtil.getBoolean(obj, 'IsInstalling', JsonUtil.getBoolean(obj, 'isInstalling', false))) {
    return true;
  }
  const status: string = JsonUtil.getString(obj, 'Status', JsonUtil.getString(obj, 'status', ''));
  if (status.length === 0) {
    return true;
  }
  return status === 'Installing' || status === 'installing' || status === 'Queued' ||
    status === 'queued' || status === 'Downloading' || status === 'downloading' ||
    status === 'Pending' || status === 'pending' || status === 'InProgress' ||
    status === 'inProgress';
}

function parsePackage(item: Object): PluginPackageInfo {
  const obj: ESObject = item as ESObject;
  const installationId: string = packageInstallationId(obj);
  return {
    name: JsonUtil.getString(obj, 'name', JsonUtil.getString(obj, 'Name', '')),
    overview: JsonUtil.getString(obj, 'overview', JsonUtil.getString(obj, 'Overview',
      JsonUtil.getString(obj, 'description', JsonUtil.getString(obj, 'Description', '')))),
    version: firstPackageVersion(obj),
    assemblyGuid: JsonUtil.getString(obj, 'guid', JsonUtil.getString(obj, 'Guid', '')),
    installing: isPackageInstalling(obj, installationId),
    installationId: installationId
  };
}

@Entry
@Component
struct PluginsPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private packages: PluginPackageInfo[] = [];
  @State private actionMessage: string = '';
  @State private actionFailed: boolean = false;
  @State private actionBusy: boolean = false;
  @State private showInstallConfirm: boolean = false;
  @State private showCancelConfirm: boolean = false;
  @State private pendingPackage: PluginPackageInfo = {
    name: '', overview: '', version: '', assemblyGuid: '', installing: false, installationId: ''
  };

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.adminGenericGet('/Packages'));
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载插件失败';
      return;
    }
    const items: Object[] = JsonUtil.extractItems(result.data);
    const parsed: PluginPackageInfo[] = [];
    for (let i = 0; i < items.length; i++) {
      const pkg: PluginPackageInfo = parsePackage(items[i]);
      if (pkg.name.length > 0) {
        parsed.push(pkg);
      }
    }
    this.packages = parsed;
    this.status = parsed.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private actionError(raw: string, fallback: string): string {
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) {
      return '';
    }
    return result.message.length > 0 ? result.message : fallback;
  }

  private installPath(pkg: PluginPackageInfo): string {
    let path: string = `/Packages/Installed/${encodeURIComponent(pkg.name)}`;
    const params: string[] = [];
    if (pkg.assemblyGuid.length > 0) {
      params.push(`assemblyGuid=${encodeURIComponent(pkg.assemblyGuid)}`);
    }
    if (pkg.version.length > 0) {
      params.push(`version=${encodeURIComponent(pkg.version)}`);
    }
    if (params.length > 0) {
      path = `${path}?${params.join('&')}`;
    }
    return path;
  }

  private requestInstall(pkg: PluginPackageInfo): void {
    if (this.actionBusy || pkg.name.length === 0 || pkg.installing) {
      return;
    }
    this.pendingPackage = pkg;
    this.showInstallConfirm = true;
  }

  private async installPackage(): Promise<void> {
    if (this.actionBusy || this.pendingPackage.name.length === 0) {
      return;
    }
    this.showInstallConfirm = false;
    this.actionBusy = true;
    this.actionMessage = '';
    const message: string = this.actionError(
      await JellyfinNative.adminGenericPostNoBody(this.installPath(this.pendingPackage)), '安装插件失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionFailed = true;
      this.actionMessage = message;
      return;
    }
    this.actionFailed = false;
    this.actionMessage = `插件“${this.pendingPackage.name}”已开始安装`;
    this.pendingPackage = { name: '', overview: '', version: '', assemblyGuid: '', installing: false, installationId: '' };
    this.reload();
  }

  private requestCancelInstall(pkg: PluginPackageInfo): void {
    if (this.actionBusy || !pkg.installing || pkg.installationId.length === 0) {
      return;
    }
    this.pendingPackage = pkg;
    this.showCancelConfirm = true;
  }

  private async cancelInstall(): Promise<void> {
    if (this.actionBusy || this.pendingPackage.installationId.length === 0) {
      return;
    }
    this.showCancelConfirm = false;
    this.actionBusy = true;
    this.actionMessage = '';
    const path: string = `/Packages/Installing/${encodeURIComponent(this.pendingPackage.installationId)}`;
    const message: string = this.actionError(await JellyfinNative.adminGenericDelete(path), '取消插件安装失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionFailed = true;
      this.actionMessage = message;
      return;
    }
    this.actionFailed = false;
    this.actionMessage = `插件“${this.pendingPackage.name}”的安装已取消`;
    this.pendingPackage = { name: '', overview: '', version: '', assemblyGuid: '', installing: false, installationId: '' };
    this.reload();
  }

  @Builder
  PackageCard(pkg: PluginPackageInfo) {
    Row({ space: 10 }) {
      Column({ space: 4 }) {
        Text(pkg.name)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
          .width('100%')
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (pkg.version.length > 0) {
          Text(`版本：${pkg.version}`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
        }
        if (pkg.overview.length > 0) {
          Text(pkg.overview)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .layoutWeight(1)
      if (pkg.installing) {
        Button(this.actionBusy ? '处理中...' : '取消安装')
          .height(36)
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.colors().errorLight)
          .fontColor(this.colors().onBrand)
          .enabled(!this.actionBusy && pkg.installationId.length > 0)
          .onClick(() => {
            this.requestCancelInstall(pkg);
          })
      } else {
        Button(this.actionBusy ? '安装中...' : '安装')
          .height(36)
          .padding({ left: 12, right: 12 })
          .backgroundColor(this.colors().brandPrimary)
          .fontColor(this.colors().onBrand)
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.requestInstall(pkg);
          })
      }
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(10)
  }

  @Builder
  ConfirmDialog() {
    Column({ space: 12 }) {
      Text(this.showInstallConfirm ? '安装插件？' : '取消插件安装？')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(this.showInstallConfirm ?
        `确认安装插件“${this.pendingPackage.name}”？` :
        `确认取消插件“${this.pendingPackage.name}”的安装？`)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      if (this.showInstallConfirm && this.pendingPackage.version.length > 0) {
        Text(`将安装版本：${this.pendingPackage.version}`)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .width('100%')
      }
      Row({ space: 8 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.colors().surfacePressed)
          .fontColor(this.colors().textPrimary)
          .onClick(() => {
            this.showInstallConfirm = false;
            this.showCancelConfirm = false;
          })
        Button(this.actionBusy ? '处理中...' : (this.showInstallConfirm ? '安装' : '取消安装'))
          .layoutWeight(1)
          .backgroundColor(this.showInstallConfirm ? this.colors().brandPrimary : this.colors().errorLight)
          .fontColor(this.colors().onBrand)
          .enabled(!this.actionBusy)
          .onClick(() => {
            if (this.showInstallConfirm) {
              this.installPackage();
            } else {
              this.cancelInstall();
            }
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

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '插件',
          onBack: () => {
            router.back();
          }
        })
        if (this.actionMessage.length > 0) {
          Text(this.actionMessage)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.actionFailed ? this.colors().error : this.colors().success)
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
            EmptyState({ message: '当前没有可用插件' })
          }
        } else {
          List({ space: 8 }) {
            ForEach(this.packages, (pkg: PluginPackageInfo) => {
              ListItem() {
                this.PackageCard(pkg)
              }
            }, (pkg: PluginPackageInfo) => `${pkg.name}-${pkg.version}-${pkg.installationId}`)
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

      if (this.showInstallConfirm || this.showCancelConfirm) {
        Column() {
          this.ConfirmDialog()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.showInstallConfirm = false;
          this.showCancelConfirm = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
