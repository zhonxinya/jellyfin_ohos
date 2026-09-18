import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import {
  LibraryCollectionType,
  LibraryEntry,
  LIBRARY_COLLECTION_TYPES,
  collectionTypeColor,
  collectionTypeLabel,
  parseLibraryEntries
} from '../../common/LibraryModels';
import { PageHeader } from '../../components/PageHeader';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 每个媒体库卡片上的操作（对应服务端 LibraryStructureController 的各个端点） */
class LibraryAction {
  key: string;
  label: string;
  danger: boolean;

  constructor(key: string, label: string, danger: boolean) {
    this.key = key;
    this.label = label;
    this.danger = danger;
  }
}

const ACTIONS: LibraryAction[] = [
  new LibraryAction('paths', '路径', false),
  new LibraryAction('options', '媒体库选项', false),
  new LibraryAction('scan', '扫描', false),
  new LibraryAction('rename', '重命名', false),
  new LibraryAction('delete', '删除', true)
];

/**
 * 设置 → 媒体库管理。
 *
 * 对照服务端（`docs/jellyfin-10.8.12`）实现的完整能力：
 * - `GET  /Library/VirtualFolders`                    列表（名称/类型/路径/刷新进度/选项）
 * - `POST /Library/VirtualFolders`                    新增（名称 + 集合类型 + 路径，可带完整选项）
 * - `POST /Library/VirtualFolders/Name`               重命名
 * - `DELETE /Library/VirtualFolders`                  删除
 * - `POST /Library/VirtualFolders/Paths`              加路径
 * - `POST /Library/VirtualFolders/Paths/Update`       改路径（含网络路径映射）
 * - `DELETE /Library/VirtualFolders/Paths`            移除路径
 * - `POST /Library/VirtualFolders/LibraryOptions`     整体替换媒体库选项
 * - `POST /Library/Refresh`                           扫描全部媒体库
 * - `POST /Items/{itemId}/Refresh`                    只扫描一个媒体库
 *
 * 请求构造与响应解析都在 C++（`core/api/library_admin_api.*`），本页只管展示与表单状态。
 */
@Entry
@Component
struct LibrariesAdminPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private folders: LibraryEntry[] = [];
  /**
   * 列表版本号。
   * ArkUI 的 `ForEach` 按 key 复用条目：key 不变时条目不会重建，
   * 于是"同一个库扫描进度变了 / 路径增删了"这类**内容变化但 key 不变**的情况就会显示旧内容。
   * 这里把版本号拼进 key，让每次重新拉取都强制重建卡片。
   */
  @State private listRev: number = 0;
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private actionBusy: boolean = false;

  /** 新增表单 */
  @State private showAddForm: boolean = false;
  @State private newName: string = '';
  @State private newTypeIndex: number = 0;
  @State private newPath: string = '';
  @State private newRefresh: boolean = true;

  /** 重命名表单 */
  @State private showRenameForm: boolean = false;
  @State private renameTarget: string = '';
  @State private renameValue: string = '';

  /** 删除确认 */
  @State private showDeleteConfirm: boolean = false;
  @State private deleteTarget: LibraryEntry | null = null;
  @State private deleteRefresh: boolean = true;

  /** 扫描菜单（选一次扫描力度） */
  @State private showScanSheet: boolean = false;
  @State private scanTarget: LibraryEntry | null = null;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  onPageShow(): void {
    // 从「路径」「媒体库选项」子页返回后要刷新列表（选项摘要/路径数会变）
    if (this.status === UiState.SUCCESS) {
      this.reload();
    }
  }

  private async reload(): Promise<void> {
    if (this.folders.length === 0) {
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
    this.folders = parseLibraryEntries(result.data);
    this.listRev = this.listRev + 1;
    this.status = this.folders.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
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

  // ── 新增 ────────────────────────────────────────────────────────────────

  private async addLibrary(): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    const name: string = this.newName.trim();
    const path: string = this.newPath.trim();
    if (name.length === 0) {
      this.notice('请输入媒体库名称', false);
      return;
    }
    // 服务端要求路径在服务器本机真实存在（LibraryManager.AddVirtualFolder 里 Directory.Exists），
    // 这里只做空值校验：路径是否存在只有服务器知道，交给服务端报错更准确。
    const type: LibraryCollectionType = LIBRARY_COLLECTION_TYPES[this.newTypeIndex];
    const paths: string[] = path.length > 0 ? [path] : [];
    this.actionBusy = true;
    this.notice('', true);
    const raw: string = await JellyfinNative.libraryAddVirtualFolder(
      name, type.value, JSON.stringify(paths), '{}', this.newRefresh);
    const message: string = this.errorOf(raw, '添加媒体库失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.notice(message, false);
      return;
    }
    this.showAddForm = false;
    this.newName = '';
    this.newPath = '';
    this.notice(`已添加「${name}」，可在卡片上继续配置选项`, true);
    this.reload();
  }

  // ── 重命名 ──────────────────────────────────────────────────────────────

  private requestRename(folder: LibraryEntry): void {
    if (this.actionBusy) {
      return;
    }
    this.renameTarget = folder.name;
    this.renameValue = folder.name;
    this.notice('', true);
    this.showRenameForm = true;
  }

  private async renameLibrary(): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    const newName: string = this.renameValue.trim();
    if (newName.length === 0 || newName === this.renameTarget) {
      this.showRenameForm = false;
      return;
    }
    const oldName: string = this.renameTarget;
    this.actionBusy = true;
    const raw: string = await JellyfinNative.libraryRenameVirtualFolder(oldName, newName, false);
    const message: string = this.errorOf(raw, '重命名失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.notice(message, false);
      return;
    }
    this.showRenameForm = false;
    this.notice(`「${oldName}」已重命名为「${newName}」`, true);
    this.reload();
  }

  // ── 扫描 ────────────────────────────────────────────────────────────────

  private requestScan(folder: LibraryEntry): void {
    if (this.actionBusy) {
      return;
    }
    if (folder.itemId.length === 0) {
      this.notice('该媒体库缺少 ItemId，无法单独扫描；请用「扫描全部」', false);
      return;
    }
    this.scanTarget = folder;
    this.notice('', true);
    this.showScanSheet = true;
  }

  /**
   * 只扫描一个媒体库。参数含义（`ItemRefreshController`）：
   * - `ValidationOnly`：只补新增/缺失的文件，不动已有元数据（默认，最轻）
   * - `FullRefresh`：重新抓取元数据；`replaceMetadata` 才会覆盖已存在的字段
   */
  private async scanFolder(full: boolean, replaceMetadata: boolean, replaceImages: boolean): Promise<void> {
    const target: LibraryEntry | null = this.scanTarget;
    if (target === null || this.actionBusy) {
      return;
    }
    this.showScanSheet = false;
    this.actionBusy = true;
    const mode: string = full ? 'FullRefresh' : 'ValidationOnly';
    const raw: string = await JellyfinNative.libraryScanFolder(
      target.itemId, mode, mode, replaceMetadata, replaceImages);
    const message: string = this.errorOf(raw, '启动扫描失败');
    this.actionBusy = false;
    this.scanTarget = null;
    if (message.length > 0) {
      this.notice(message, false);
      return;
    }
    this.notice(`已排队扫描「${target.name}」，进度见卡片上的刷新状态`, true);
    this.reload();
  }

  private async scanAll(): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    const raw: string = await JellyfinNative.libraryScanAll();
    const message: string = this.errorOf(raw, '启动扫描失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.notice(message, false);
      return;
    }
    this.notice('已排队扫描全部媒体库', true);
    this.reload();
  }

  // ── 删除 ────────────────────────────────────────────────────────────────

  private requestDelete(folder: LibraryEntry): void {
    if (this.actionBusy) {
      return;
    }
    this.deleteTarget = folder;
    this.notice('', true);
    this.showDeleteConfirm = true;
  }

  private async deleteLibrary(): Promise<void> {
    const target: LibraryEntry | null = this.deleteTarget;
    if (target === null || this.actionBusy) {
      return;
    }
    this.actionBusy = true;
    const raw: string = await JellyfinNative.libraryRemoveVirtualFolder(target.name, this.deleteRefresh);
    const message: string = this.errorOf(raw, '删除媒体库失败');
    this.actionBusy = false;
    this.showDeleteConfirm = false;
    this.deleteTarget = null;
    if (message.length > 0) {
      this.notice(message, false);
      return;
    }
    this.notice(`已删除「${target.name}」`, true);
    this.reload();
  }

  // ── 跳转 ────────────────────────────────────────────────────────────────

  /** 子页只需要库名 + ItemId + 类型 + 选项，用 router 参数整体带过去（避免子页再拉一次列表） */
  private openChild(url: string, folder: LibraryEntry): void {
    router.pushUrl({
      url: url,
      params: {
        name: folder.name,
        itemId: folder.itemId,
        collectionType: folder.collectionType,
        options: folder.options.toJson()
      }
    });
  }

  private handleAction(actionKey: string, folder: LibraryEntry): void {
    if (actionKey === 'paths') {
      this.openChild('pages/admin/LibraryPathsPage', folder);
    } else if (actionKey === 'options') {
      this.openChild('pages/admin/LibraryOptionsPage', folder);
    } else if (actionKey === 'scan') {
      this.requestScan(folder);
    } else if (actionKey === 'rename') {
      this.requestRename(folder);
    } else if (actionKey === 'delete') {
      this.requestDelete(folder);
    }
  }

  // ── 视图 ────────────────────────────────────────────────────────────────

  @Builder
  ActionChip(action: LibraryAction, folder: LibraryEntry) {
    Text(action.label)
      .fontSize(ThemeConstants.META_SMALL)
      .fontColor(action.danger ? this.colors().onBrand : this.colors().textPrimary)
      .backgroundColor(action.danger ? this.colors().errorLight : this.colors().surfacePressed)
      .padding({ left: 10, right: 10, top: 5, bottom: 5 })
      .borderRadius(ThemeConstants.BADGE_RADIUS)
      .onClick(() => {
        this.handleAction(action.key, folder);
      })
  }

  /** 卡片上的"选项摘要"：只显示用户最关心、又能一眼看出差异的几项 */
  @Builder
  OptionSummary(folder: LibraryEntry) {
    Row() {
      Text(folder.options.getBool('EnableRealtimeMonitor', true) ? '实时监控开' : '实时监控关')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
      Text(` · ${folder.options.getBool('EnableChapterImageExtraction', false) ? '章节图开' : '章节图关'}`)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
      Text(` · 元数据语言 ${folder.options.getString('PreferredMetadataLanguage', '').length > 0
        ? folder.options.getString('PreferredMetadataLanguage', '') : '默认'}`)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
    }
    .width('100%')
  }

  @Builder
  LibraryCard(folder: LibraryEntry) {
    Column({ space: 8 }) {
      Row() {
        Text(collectionTypeLabel(folder.collectionType))
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().onBrand)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(collectionTypeColor(folder.collectionType, this.colors().brandPrimary,
            this.colors().onSurfaceVariant))
          .borderRadius(6)
          .maxLines(1)
        Text(folder.name)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .layoutWeight(1)
          .margin({ left: 8 })
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(`${folder.locations.length} 个路径`)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
      }
      .width('100%')

      if (folder.locations.length > 0) {
        Column({ space: 4 }) {
          ForEach(folder.locations, (p: string) => {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.folder'))
                .fontSize(ThemeConstants.ICON_SMALL)
                .fontColor([this.colors().textTertiary])
              Text(p)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textSecondary)
                .layoutWeight(1)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
          }, (p: string) => p)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      } else {
        Text('未配置媒体路径 —— 点「路径」添加（服务器上的绝对路径）')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().warning)
          .width('100%')
      }

      this.OptionSummary(folder)

      // 扫描进度：服务端只在正在扫描时给出 RefreshProgress（0–100）
      if (folder.refreshing) {
        Row({ space: 8 }) {
          Text(`扫描中 ${Math.round(folder.refreshProgress)}%`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().brandPrimary)
          Progress({ value: folder.refreshProgress, total: 100, type: ProgressType.Linear })
            .layoutWeight(1)
            .color(this.colors().brandPrimary)
        }
        .width('100%')
      } else if (folder.refreshStatus.length > 0) {
        Text(`刷新状态：${folder.refreshStatus}`)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .width('100%')
      }

      Row({ space: 8 }) {
        ForEach(ACTIONS, (action: LibraryAction) => {
          this.ActionChip(action, folder)
        }, (action: LibraryAction) => action.key)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .clip(true)
  }

  @Builder
  AddForm() {
    Column({ space: 12 }) {
      Text('添加媒体库')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      TextInput({ text: this.newName, placeholder: '媒体库名称（例如：电影）' })
        .width('100%')
        .onChange((value: string) => {
          this.newName = value;
        })
      Text('内容类型')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
        ForEach(LIBRARY_COLLECTION_TYPES, (item: LibraryCollectionType, index: number) => {
          Text(item.label)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(index === this.newTypeIndex ? this.colors().onBrand : this.colors().textPrimary)
            .backgroundColor(index === this.newTypeIndex
              ? this.colors().brandPrimary : this.colors().surfacePressed)
            .padding({ left: 10, right: 10, top: 6, bottom: 6 })
            .borderRadius(ThemeConstants.BADGE_RADIUS)
            .margin({ right: 8, bottom: 8 })
            .onClick(() => {
              this.newTypeIndex = index;
            })
        }, (item: LibraryCollectionType) => item.value)
      }
      .width('100%')
      TextInput({ text: this.newPath, placeholder: '媒体路径（服务器上的绝对路径，可留空稍后添加）' })
        .width('100%')
        .onChange((value: string) => {
          this.newPath = value;
        })
      Row({ space: 8 }) {
        Text('添加后立即扫描')
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.newRefresh })
          .selectedColor(this.colors().brandPrimary)
          .onChange((value: boolean) => {
            this.newRefresh = value;
          })
      }
      .width('100%')
      Text('路径必须是 Jellyfin 服务器本机能访问到的目录；不符合时服务端会直接拒绝。')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      if (this.actionMessage.length > 0) {
        Text(this.actionMessage)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.actionOk ? this.colors().success : this.colors().error)
          .width('100%')
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
            this.addLibrary();
          })
      }
      .width('100%')
    }
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .width('85%')
    .onClick(() => {
      // 阻止点穿到遮罩
    })
  }

  @Builder
  RenameForm() {
    Column({ space: 12 }) {
      Text('重命名媒体库')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(`当前名称：${this.renameTarget}`)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      TextInput({ text: this.renameValue, placeholder: '新名称' })
        .width('100%')
        .onChange((value: string) => {
          this.renameValue = value;
        })
      if (this.actionMessage.length > 0) {
        Text(this.actionMessage)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().error)
          .width('100%')
      }
      Row({ space: 8 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.colors().surfacePressed)
          .fontColor(this.colors().textPrimary)
          .onClick(() => {
            this.showRenameForm = false;
            this.notice('', true);
          })
        Button(this.actionBusy ? '提交中...' : '重命名')
          .layoutWeight(1)
          .backgroundColor(this.colors().brandPrimary)
          .fontColor(this.colors().onBrand)
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.renameLibrary();
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
  ScanSheet() {
    Column({ space: 10 }) {
      Text(`扫描「${this.scanTarget !== null ? this.scanTarget.name : ''}」`)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text('缺什么补什么：只处理新增或变更的文件，不改动已有元数据。')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      Button('扫描新增与变更')
        .width('100%')
        .backgroundColor(this.colors().brandPrimary)
        .fontColor(this.colors().onBrand)
        .onClick(() => {
          this.scanFolder(false, false, false);
        })
      Text('完整刷新：重新抓取元数据，但保留服务器上已经存在的字段与图片。')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      Button('完整刷新（保留已有）')
        .width('100%')
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
        .onClick(() => {
          this.scanFolder(true, false, false);
        })
      Text('覆盖刷新：用抓取结果覆盖已有元数据与图片。')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      Button('覆盖元数据与图片')
        .width('100%')
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
        .onClick(() => {
          this.scanFolder(true, true, true);
        })
      Button('取消')
        .width('100%')
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textSecondary)
        .onClick(() => {
          this.showScanSheet = false;
          this.scanTarget = null;
        })
    }
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .width('85%')
    .onClick(() => {
    })
  }

  @Builder
  DeleteConfirm() {
    Column({ space: 12 }) {
      Text('删除媒体库？')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(`将删除「${this.deleteTarget !== null ? this.deleteTarget.name : ''}」的媒体库配置`
        + '（服务器上的文件不会被删除，媒体条目会在下次扫描时清理）。')
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      Row({ space: 8 }) {
        Text('删除后立即扫描（清理媒体条目）')
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textPrimary)
          .layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.deleteRefresh })
          .selectedColor(this.colors().brandPrimary)
          .onChange((value: boolean) => {
            this.deleteRefresh = value;
          })
      }
      .width('100%')
      if (this.actionMessage.length > 0) {
        Text(this.actionMessage)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().error)
          .width('100%')
      }
      Row({ space: 8 }) {
        Button('取消')
          .layoutWeight(1)
          .backgroundColor(this.colors().surfacePressed)
          .fontColor(this.colors().textPrimary)
          .onClick(() => {
            this.showDeleteConfirm = false;
            this.deleteTarget = null;
            this.notice('', true);
          })
        Button(this.actionBusy ? '处理中...' : '删除')
          .layoutWeight(1)
          .backgroundColor(this.colors().errorLight)
          .fontColor(this.colors().onBrand)
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.deleteLibrary();
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
  Header() {
    Column() {
      PageHeader({
        title: '媒体库管理',
        onBack: () => {
          router.back();
        }
      })
      if (this.status === UiState.SUCCESS || this.status === UiState.EMPTY) {
        Row({ space: 8 }) {
          Text(`共 ${this.folders.length} 个媒体库`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .layoutWeight(1)
          Button(this.actionBusy ? '处理中...' : '扫描全部')
            .height(30)
            .fontSize(ThemeConstants.META_SMALL)
            .padding({ left: 12, right: 12 })
            .backgroundColor(this.colors().surfacePressed)
            .fontColor(this.colors().textPrimary)
            .enabled(!this.actionBusy)
            .onClick(() => {
              this.scanAll();
            })
          Button('刷新列表')
            .height(30)
            .fontSize(ThemeConstants.META_SMALL)
            .padding({ left: 12, right: 12 })
            .backgroundColor(this.colors().surfacePressed)
            .fontColor(this.colors().textPrimary)
            .enabled(!this.actionBusy)
            .onClick(() => {
              this.reload();
            })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 4 })
      }
      if (this.actionMessage.length > 0 && !this.showAddForm && !this.showRenameForm
        && !this.showDeleteConfirm && !this.showScanSheet) {
        Text(this.actionMessage)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.actionOk ? this.colors().success : this.colors().error)
          .width('100%')
          .padding({ left: 16, right: 16, top: 6 })
          .maxLines(3)
      }
    }
    .width('100%')
  }

  build() {
    Stack() {
      Column() {
        this.Header()

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
            EmptyState({ message: '这台服务器还没有配置媒体库，点右下角「+」新建一个。' })
          }
        } else {
          List({ space: 12 }) {
            ForEach(this.folders, (folder: LibraryEntry) => {
              ListItem() {
                this.LibraryCard(folder)
              }
            }, (folder: LibraryEntry) => `${folder.key()}#${this.listRev}`)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, top: 12, bottom: 96 })
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (!this.showAddForm && !this.showRenameForm && !this.showDeleteConfirm && !this.showScanSheet) {
        Button('+')
          .width(56)
          .height(56)
          .fontSize(ThemeConstants.ICON_XXL)
          .fontColor(this.colors().onBrand)
          .backgroundColor(this.colors().brandPrimary)
          .borderRadius(28)
          .position({ x: '90%', y: '85%' })
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.notice('', true);
            this.showAddForm = true;
          })
      }

      if (this.showAddForm || this.showRenameForm || this.showDeleteConfirm || this.showScanSheet) {
        Column() {
          if (this.showAddForm) {
            this.AddForm()
          } else if (this.showRenameForm) {
            this.RenameForm()
          } else if (this.showScanSheet) {
            this.ScanSheet()
          } else {
            this.DeleteConfirm()
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.showAddForm = false;
          this.showRenameForm = false;
          this.showDeleteConfirm = false;
          this.showScanSheet = false;
          this.scanTarget = null;
          this.deleteTarget = null;
          this.notice('', true);
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
