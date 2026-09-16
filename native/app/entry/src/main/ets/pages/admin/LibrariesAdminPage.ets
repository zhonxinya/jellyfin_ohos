import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { AsyncStateView } from '../../components/AsyncStateView';

/** 虚拟媒体库条目 */
interface VirtualFolderInfo {
  id: string;
  name: string;
  collectionType: string;
  paths: string[];
  metadataPaths: string[];
  refreshMode: string;
  metadataFetchers: string[];
  imageFetcher: string;
  locale: string;
}

/** 集合类型 → 徽章文案 */
function collectionLabel(ct: string): string {
  if (ct === 'movies') return '电影';
  if (ct === 'tvshows') return '剧集';
  if (ct === 'music') return '音乐';
  if (ct === 'photos') return '照片';
  if (ct === 'boxsets') return '合集';
  if (ct === 'books') return '书籍';
  return ct;
}

/** 集合类型 → 徽章颜色 */
function collectionBadgeColor(ct: string, colors: ThemeColors): string {
  if (ct === 'movies') return colors.primary;
  if (ct === 'tvshows') return '#A855F7';
  if (ct === 'music') return '#F59E0B';
  if (ct === 'photos') return '#10B981';
  if (ct === 'boxsets') return colors.onSurfaceVariant;
  if (ct === 'books') return '#EC4899';
  return colors.onSurfaceVariant;
}

/** 解析单个 VirtualFolder */
function parseVirtualFolder(obj: Object): VirtualFolderInfo {
  const s: ESObject = obj as ESObject;
  const id: string = JsonUtil.getString(s, 'Id', '');
  const name: string = JsonUtil.getString(s, 'Name', '未命名库');
  const ct: string = JsonUtil.getString(s, 'CollectionType', '');

  const libFolders: Object[] = JsonUtil.getArray(s, 'LibraryFolders');
  const paths: string[] = [];
  for (let i = 0; i < libFolders.length; i++) {
    const fp: string = JsonUtil.getString(libFolders[i] as ESObject, 'Path', '');
    if (fp.length > 0) {
      paths.push(fp);
    }
  }

  const metadataPaths: string[] = [];
  const mpItems: Object[] = JsonUtil.getArray(s, 'MetadataPaths');
  for (let i = 0; i < mpItems.length; i++) {
    const mp: string = JsonUtil.getString(mpItems[i] as ESObject, '$value', '');
    if (mp.length > 0) {
      metadataPaths.push(mp);
    }
  }

  const refreshMode: string = JsonUtil.getString(s, 'RefreshMode', 'FullRefresh');
  const metadataFetchers: string[] = [];
  const mfItems: Object[] = JsonUtil.getArray(s, 'MetadataFetchers');
  for (let i = 0; i < mfItems.length; i++) {
    const mf: string = JsonUtil.getString(mfItems[i] as ESObject, '$value', '');
    if (mf.length > 0) {
      metadataFetchers.push(mf);
    }
  }
  const imageFetcher: string = JsonUtil.getString(s, 'ImageFetcher', '');
  const locale: string = JsonUtil.getString(s, 'Locale', '');

  return { id, name, collectionType: ct, paths, metadataPaths, refreshMode, metadataFetchers, imageFetcher, locale };
}

/** refreshMode → 展示文案 */
function refreshModeLabel(mode: string): string {
  if (mode === 'FullRefresh') return '完整刷新';
  if (mode === 'MinimalRefresh') return '最小刷新';
  if (mode === 'DefaultRefresh') return '默认';
  return mode;
}

@Entry
@Component
struct LibrariesAdminPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private folders: VirtualFolderInfo[] = [];
  @State private actionMessage: string = '';
  @State private actionBusy: boolean = false;
  @State private showAddForm: boolean = false;
  @State private showDeleteConfirm: boolean = false;
  @State private pendingDeleteName: string = '';
  @State private libraryName: string = '';
  @State private collectionType: string = 'movies';
  @State private libraryPath: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.adminGenericGet('/Library/VirtualFolders');
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载失败';
      return;
    }
    const items: Object[] = JsonUtil.extractItems(result.data);
    const parsed: VirtualFolderInfo[] = [];
    for (let i = 0; i < items.length; i++) {
      parsed.push(parseVirtualFolder(items[i]));
    }
    this.folders = parsed;
    this.status = parsed.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
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

  private async addLibrary(): Promise<void> {
    if (this.actionBusy) {
      return;
    }
    const name: string = this.libraryName.trim();
    const path: string = this.libraryPath.trim();
    const type: string = this.collectionType.trim();
    if (name.length === 0 || path.length === 0 || type.length === 0) {
      this.actionMessage = '请输入媒体库名称、集合类型和路径';
      return;
    }
    this.actionBusy = true;
    this.actionMessage = '';
    const apiPath: string = `/Library/VirtualFolders?name=${this.encoded(name)}&collectionType=${this.encoded(type)}&paths=${this.encoded(path)}`;
    const message: string = this.actionError(await JellyfinNative.adminGenericPost(apiPath, '{}'), '添加媒体库失败');
    this.actionBusy = false;
    if (message.length > 0) {
      this.actionMessage = message;
      return;
    }
    this.showAddForm = false;
    this.libraryName = '';
    this.libraryPath = '';
    this.actionMessage = '媒体库已添加';
    this.reload();
  }

  private requestDelete(folder: VirtualFolderInfo): void {
    if (this.actionBusy) {
      return;
    }
    this.pendingDeleteName = folder.name;
    this.showDeleteConfirm = true;
  }

  private async deleteLibrary(): Promise<void> {
    if (this.actionBusy || this.pendingDeleteName.length === 0) {
      return;
    }
    this.showDeleteConfirm = false;
    this.actionBusy = true;
    this.actionMessage = '';
    const apiPath: string = `/Library/VirtualFolders?name=${this.encoded(this.pendingDeleteName)}&refreshLibrary=true`;
    const message: string = this.actionError(await JellyfinNative.adminGenericDelete(apiPath), '删除媒体库失败');
    this.actionBusy = false;
    this.pendingDeleteName = '';
    if (message.length > 0) {
      this.actionMessage = message;
      return;
    }
    this.actionMessage = '媒体库已删除';
    this.reload();
  }

  @Builder
  LibraryCard(folder: VirtualFolderInfo) {
    Column({ space: 8 }) {
      Row() {
        Text(collectionLabel(folder.collectionType))
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().onBrand)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(collectionBadgeColor(folder.collectionType, this.colors()))
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
        Text(`${folder.paths.length} 个路径`)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
      }
      .width('100%')

      if (folder.paths.length > 0) {
        Column({ space: 4 }) {
          ForEach(folder.paths, (p: string) => {
            Row() {
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
            .padding({ left: 4, right: 4, top: 2, bottom: 2 })
          }, (p: string) => p)
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
      }

      Row() {
        Text(refreshModeLabel(folder.refreshMode))
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
        if (folder.metadataFetchers.length > 0) {
          Text(` · ${folder.metadataFetchers.join(', ')}`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
        }
        if (folder.locale.length > 0 && folder.locale !== 'en') {
          Text(` · ${folder.locale}`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
        }
      }
      .width('100%')

      Row() {
        Blank()
        Button('删除')
          .height(36)
          .padding({ left: 16, right: 16 })
          .backgroundColor(this.colors().errorLight)
          .fontColor(this.colors().onBrand)
          .enabled(!this.actionBusy)
          .onClick(() => {
            this.requestDelete(folder);
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .clip(true)
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '媒体库管理',
          onBack: () => {
            router.back();
          }
        })

        if (this.status !== UiState.SUCCESS) {
          AsyncStateView({
            status: this.status,
            message: this.errorMsg,
            emptyHint: '当前服务器没有配置任何虚拟媒体库，请先在 Jellyfin Web 控制台中添加媒体库。',
            minHeight: 200,
            onRetry: () => {
              this.reload();
            }
          })
        } else {
          List({ space: 12 }) {
            ForEach(this.folders, (folder: VirtualFolderInfo) => {
              ListItem() {
                this.LibraryCard(folder)
              }
            }, (folder: VirtualFolderInfo) => folder.id)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, top: 12, bottom: 80 })
          .scrollBar(BarState.Auto)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.actionMessage.length > 0 && !this.showAddForm && !this.showDeleteConfirm) {
        Text(this.actionMessage)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.actionMessage === '媒体库已添加' || this.actionMessage === '媒体库已删除' ? this.colors().success : this.colors().error)
          .position({ x: 16, y: 70 })
      }

      if (!this.showAddForm && !this.showDeleteConfirm) {
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
            this.actionMessage = '';
            this.showAddForm = true;
          })
      }

      if (this.showAddForm) {
        Column() {
          Column({ space: 12 }) {
            Text('添加媒体库')
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .width('100%')
            TextInput({ text: this.libraryName, placeholder: '媒体库名称' })
              .width('100%')
              .onChange((value: string) => {
                this.libraryName = value;
              })
            TextInput({ text: this.collectionType, placeholder: '集合类型，例如 movies' })
              .width('100%')
              .onChange((value: string) => {
                this.collectionType = value;
              })
            TextInput({ text: this.libraryPath, placeholder: '媒体路径' })
              .width('100%')
              .onChange((value: string) => {
                this.libraryPath = value;
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
                  this.showAddForm = false;
                  this.actionMessage = '';
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
            // Keep dialog content clicks from dismissing the scrim.
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.showAddForm = false;
          this.actionMessage = '';
        })
      }

      if (this.showDeleteConfirm) {
        Column() {
          Column({ space: 12 }) {
            Text('删除媒体库？')
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .width('100%')
            Text(`将删除“${this.pendingDeleteName}”的媒体库配置，此操作不可撤销。`)
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textSecondary)
              .width('100%')
            Row({ space: 8 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor(this.colors().surfacePressed)
                .fontColor(this.colors().textPrimary)
                .onClick(() => {
                  this.showDeleteConfirm = false;
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
            // Keep dialog content clicks from dismissing the scrim.
          })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.showDeleteConfirm = false;
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
