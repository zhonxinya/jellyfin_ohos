import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { LibraryEntry, collectionTypeLabel, parseLibraryEntries } from '../../common/LibraryModels';
import { PageHeader } from '../../components/PageHeader';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 一行媒体路径：本机路径 + 它的网络路径映射（`MediaPathInfo.NetworkPath`） */
class PathRow {
  path: string = '';
  networkPath: string = '';
}

/**
 * 媒体库路径管理（媒体库卡片 → 「路径」）。
 *
 * 对应服务端的三个端点（`LibraryStructureController.cs`）：
 * - `POST   /Library/VirtualFolders/Paths`         添加（`MediaPathDto { Name, Path, PathInfo }`）
 * - `POST   /Library/VirtualFolders/Paths/Update`  改网络路径（服务端按 `PathInfo.Path` 匹配已有路径，
 *                                                  **只更新 NetworkPath**；要换真实路径只能"移除 + 添加"）
 * - `DELETE /Library/VirtualFolders/Paths`         移除（query `name` + `path`）
 *
 * 路径必须存在于 **Jellyfin 服务器本机**（`LibraryManager.AddVirtualFolder/AddMediaPath` 会校验），
 * 所以本页只做非空校验，是否存在交给服务端报错。
 */
@Entry
@Component
struct LibraryPathsPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private libraryName: string = '';
  @State private collectionType: string = '';
  @State private rows: PathRow[] = [];
  /** 列表版本号：拼进 ForEach 的 key，保证路径增删/网络路径改动后条目一定重建（见 LibrariesAdminPage 的说明） */
  @State private listRev: number = 0;
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private actionBusy: boolean = false;

  @State private showAddForm: boolean = false;
  @State private newPath: string = '';
  @State private newNetworkPath: string = '';
  @State private addRefresh: boolean = true;

  @State private editTarget: string = '';
  @State private editNetworkPath: string = '';
  @State private showEditForm: boolean = false;

  @State private removeTarget: string = '';
  @State private showRemoveConfirm: boolean = false;
  @State private removeRefresh: boolean = true;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    const params: Object | undefined = router.getParams();
    if (params !== undefined && params !== null) {
      const bag: ESObject = params as ESObject;
      const name: string | undefined = bag['name'] as string | undefined;
      const type: string | undefined = bag['collectionType'] as string | undefined;
      if (name !== undefined) {
        this.libraryName = name;
      }
      if (type !== undefined) {
        this.collectionType = type;
      }
    }
    this.reload();
  }

  /**
   * 重新拉列表并取出本库。
   * 服务端的路径增删没有"只返回这个库"的端点，而路径的权威来源（`Locations`，
   * 即虚拟文件夹目录下的 .mblink 快捷方式）只有列表接口会算出来，所以整表拉一次再挑。
   */
  private async reload(): Promise<void> {
    if (this.rows.length === 0) {
      this.status = UiState.LOADING;
    }
    this.errorMsg = '';
    const raw: string = await JellyfinNative.libraryVirtualFolders();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载失败';
      return;
    }
    const entries: LibraryEntry[] = parseLibraryEntries(result.data);
    let found: LibraryEntry | null = null;
    for (let i = 0; i < entries.length; i++) {
      if (entries[i].name === this.libraryName) {
        found = entries[i];
        break;
      }
    }
    if (found === null) {
      this.status = UiState.ERROR;
      this.errorMsg = `服务器上已找不到媒体库「${this.libraryName}」，它可能已被删除或重命名。`;
      return;
    }
    if (this.collectionType.length === 0) {
      this.collectionType = found.collectionType;
    }
    this.rows = LibraryPathsPage.buildRows(found);
    this.listRev = this.listRev + 1;
    this.status = UiState.SUCCESS;
  }

  /** 把 `Locations`（权威路径列表）与 `LibraryOptions.PathInfos`（网络路径映射）合成展示行 */
  private static buildRows(entry: LibraryEntry): PathRow[] {
    const rows: PathRow[] = [];
    for (let i = 0; i < entry.locations.length; i++) {
      const row: PathRow = new PathRow();
      row.path = entry.locations[i];
      for (let j = 0; j < entry.pathInfos.length; j++) {
        if (entry.pathInfos[j].path === row.path) {
          row.networkPath = entry.pathInfos[j].networkPath;
          break;
        }
      }
      rows.push(row);
    }
    return rows;
  }

  private notice(message: string, ok: boolean): void {
    this.actionMessage = message;
    this.actionOk = ok;
  }

  private errorOf(raw: string, fallback: string): string {
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok) {
      return '';
    }
    return result.message.length > 0 ? result.message : fallback;
  }

  private async addPath(): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    const path: string = this.newPath.trim();
    if (path.length === 0) {
      this.notice('请输入媒体路径', false);
      return;
    }
    this.actionBusy = true;
    const raw: string = await JellyfinNative.libraryAddMediaPath(
      this.libraryName, path, this.newNetworkPath.trim(), this.addRefresh);
    const message: string = this.errorOf(raw, '添加路径失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.notice(message, false);
      return;
    }
    this.showAddForm = false;
    this.newPath = '';
    this.newNetworkPath = '';
    this.notice(`已添加路径 ${path}`, true);
    this.reload();
  }

  private requestEdit(row: PathRow): void {
    if (this.actionBusy) {
      return;
    }
    this.editTarget = row.path;
    this.editNetworkPath = row.networkPath;
    this.notice('', true);
    this.showEditForm = true;
  }

  private async updateNetworkPath(): Promise<void> {
    if (this.actionBusy || this.editTarget.length === 0) {
      return;
    }
    this.actionBusy = true;
    const raw: string = await JellyfinNative.libraryUpdateMediaPath(
      this.libraryName, this.editTarget, this.editNetworkPath.trim());
    const message: string = this.errorOf(raw, '保存网络路径失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.notice(message, false);
      return;
    }
    this.showEditForm = false;
    this.notice('网络路径映射已保存', true);
    this.reload();
  }

  private requestRemove(row: PathRow): void {
    if (this.actionBusy) {
      return;
    }
    this.removeTarget = row.path;
    this.notice('', true);
    this.showRemoveConfirm = true;
  }

  private async removePath(): Promise<void> {
    if (this.actionBusy || this.removeTarget.length === 0) {
      return;
    }
    this.actionBusy = true;
    const raw: string = await JellyfinNative.libraryRemoveMediaPath(
      this.libraryName, this.removeTarget, this.removeRefresh);
    const message: string = this.errorOf(raw, '移除路径失败');
    this.actionBusy = false;
    this.showRemoveConfirm = false;
    if (message.length > 0) {
      this.notice(message, false);
      return;
    }
    this.notice(`已移除路径 ${this.removeTarget}`, true);
    this.removeTarget = '';
    this.reload();
  }

  @Builder
  PathRowView(row: PathRow) {
    Column({ space: 6 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.folder'))
          .fontSize(ThemeConstants.ICON_MEDIUM)
          .fontColor([this.colors().brandPrimary])
        Text(row.path)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textPrimary)
          .layoutWeight(1)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')

      if (row.networkPath.length > 0) {
        Text(`网络路径：${row.networkPath}`)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .width('100%')
      }

      Row({ space: 8 }) {
        Blank()
        Text('网络路径')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textPrimary)
          .backgroundColor(this.colors().surfacePressed)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(ThemeConstants.BADGE_RADIUS)
          .onClick(() => {
            this.requestEdit(row);
          })
        Text('移除')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onBrand)
          .backgroundColor(this.colors().errorLight)
          .padding({ left: 10, right: 10, top: 5, bottom: 5 })
          .borderRadius(ThemeConstants.BADGE_RADIUS)
          .onClick(() => {
            this.requestRemove(row);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
  }

  @Builder
  AddForm() {
    Column({ space: 12 }) {
      Text('添加媒体路径')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      TextInput({ text: this.newPath, placeholder: '服务器上的绝对路径（例如 /media/movies）' })
        .width('100%')
        .onChange((value: string) => {
          this.newPath = value;
        })
      TextInput({ text: this.newNetworkPath, placeholder: '网络路径映射（可选，留空表示与上面相同）' })
        .width('100%')
        .onChange((value: string) => {
          this.newNetworkPath = value;
        })
      Row({ space: 8 }) {
        Text('添加后立即扫描')
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.addRefresh })
          .selectedColor(this.colors().brandPrimary)
          .onChange((value: boolean) => {
            this.addRefresh = value;
          })
      }
      .width('100%')
      if (this.actionMessage.length > 0) {
        Text(this.actionMessage)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().error)
          .width('100%')
          .maxLines(3)
      }
      Row({ space: 8 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.colors().surfacePressed)
          .fontColor(this.colors().textPrimary)
          .onClick(() => {
            this.showAddForm = false;
            this.notice('', true);
          })
        Button(this.actionBusy ? '提交中...' : '添加')
          .layoutWeight(1)
          .backgroundColor(this.colors().brandPrimary)
          .fontColor(this.colors().onBrand)
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.addPath();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .width('85%')
    .onClick(() => {
    })
  }

  @Builder
  EditForm() {
    Column({ space: 12 }) {
      Text('网络路径映射')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(`服务器上的路径：${this.editTarget}`)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      Text('只对「库映射到其它路径」的情况有用：例如服务器把 /media/movies 挂载到别的目录。\n'
        + '要换真实路径请先「移除」再「添加」。')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      TextInput({ text: this.editNetworkPath, placeholder: '网络路径（留空表示不映射）' })
        .width('100%')
        .onChange((value: string) => {
          this.editNetworkPath = value;
        })
      if (this.actionMessage.length > 0) {
        Text(this.actionMessage)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().error)
          .width('100%')
          .maxLines(3)
      }
      Row({ space: 8 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.colors().surfacePressed)
          .fontColor(this.colors().textPrimary)
          .onClick(() => {
            this.showEditForm = false;
            this.notice('', true);
          })
        Button(this.actionBusy ? '保存中...' : '保存')
          .layoutWeight(1)
          .backgroundColor(this.colors().brandPrimary)
          .fontColor(this.colors().onBrand)
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.updateNetworkPath();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .width('85%')
    .onClick(() => {
    })
  }

  @Builder
  RemoveConfirm() {
    Column({ space: 12 }) {
      Text('移除媒体路径？')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(`将从「${this.libraryName}」移除路径：\n${this.removeTarget}\n`
        + '服务器上的文件不会被删除，但该路径下的媒体条目会在扫描后从媒体库中消失。')
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      Row({ space: 8 }) {
        Text('移除后立即扫描')
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.removeRefresh })
          .selectedColor(this.colors().brandPrimary)
          .onChange((value: boolean) => {
            this.removeRefresh = value;
          })
      }
      .width('100%')
      if (this.actionMessage.length > 0) {
        Text(this.actionMessage)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().error)
          .width('100%')
          .maxLines(3)
      }
      Row({ space: 8 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.colors().surfacePressed)
          .fontColor(this.colors().textPrimary)
          .onClick(() => {
            this.showRemoveConfirm = false;
            this.notice('', true);
          })
        Button(this.actionBusy ? '处理中...' : '移除')
          .layoutWeight(1)
          .backgroundColor(this.colors().errorLight)
          .fontColor(this.colors().onBrand)
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.removePath();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .width('85%')
    .onClick(() => {
    })
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '媒体路径',
          onBack: () => {
            router.back();
          }
        })

        if (this.status !== UiState.SUCCESS) {
          if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
            LoadingState()
          } else {
            EmptyState({
              message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
              actionLabel: '重试',
              onAction: () => {
                this.reload();
              }
            })
          }
        } else {
          Row({ space: 8 }) {
            Column({ space: 2 }) {
              Text(`${this.libraryName} · ${collectionTypeLabel(this.collectionType)}`)
                .fontSize(ThemeConstants.BODY_MEDIUM)
                .fontColor(this.colors().textPrimary)
              Text(`共 ${this.rows.length} 个路径`)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textSecondary)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            Button('添加路径')
              .height(30)
              .fontSize(ThemeConstants.META_SMALL)
              .padding({ left: 12, right: 12 })
              .backgroundColor(this.colors().brandPrimary)
              .fontColor(this.colors().onBrand)
              .enabled(!this.actionBusy)
              .onClick(() => {
                this.notice('', true);
                this.showAddForm = true;
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })

          if (this.actionMessage.length > 0 && !this.showAddForm && !this.showEditForm
            && !this.showRemoveConfirm) {
            Text(this.actionMessage)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.actionOk ? this.colors().success : this.colors().error)
              .width('100%')
              .padding({ left: 16, right: 16, bottom: 6 })
              .maxLines(3)
          }

          if (this.rows.length === 0) {
            EmptyState({
              message: '这个媒体库还没有配置任何媒体路径，点右上角「添加路径」。',
              actionLabel: '添加路径',
              onAction: () => {
                this.showAddForm = true;
              }
            })
          } else {
            List({ space: 10 }) {
              ForEach(this.rows, (row: PathRow) => {
                ListItem() {
                  this.PathRowView(row)
                }
              }, (row: PathRow) => `${row.path}#${this.listRev}`)
            }
            .width('100%')
            .layoutWeight(1)
            .padding({ left: 16, right: 16, bottom: 24 })
            .scrollBar(BarState.Auto)
          }
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.showAddForm || this.showEditForm || this.showRemoveConfirm) {
        Column() {
          if (this.showAddForm) {
            this.AddForm()
          } else if (this.showEditForm) {
            this.EditForm()
          } else {
            this.RemoveConfirm()
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.showAddForm = false;
          this.showEditForm = false;
          this.showRemoveConfirm = false;
          this.notice('', true);
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
