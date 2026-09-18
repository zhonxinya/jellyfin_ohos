import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { collectionTypeLabel, collectionTypeColor } from '../../common/LibraryModels';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { ChipButton } from '../../components/ChipButton';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 一个本地媒体文件夹（`/Library/MediaFolders` 返回的就是 CollectionFolder 条目） */
class MediaFolder {
  name: string = '';
  path: string = '';
  collectionType: string = '';
  type: string = '';

  constructor(name: string, path: string, collectionType: string, type: string) {
    this.name = name;
    this.path = path;
    this.collectionType = collectionType;
    this.type = type;
  }
}

/**
 * 设置 → 控制台 → 本地媒体文件夹。
 *
 * 对应服务端 `GET /Library/MediaFolders`（返回的是**条目**，不只是路径：
 * `Name` / `Path` / `CollectionType` / `Type` / `Id` / `DateCreated`…）。
 *
 * 原来这一页只取了 `Path` 字段，用 📁 + 路径显示 ——
 * 于是"这个路径属于哪个媒体库"要靠肉眼读路径；播放列表目录和媒体库目录也混在一起。
 * 现在按「媒体库」与「其它文件夹」分开，行里显示名称 + 路径 + 类型标签。
 */
@Entry
@Component
struct LibrariesMetadataPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private libraries: MediaFolder[] = [];
  @State private others: MediaFolder[] = [];

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.adminGenericGet('/Library/MediaFolders');
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载失败';
      return;
    }
    const items: Object[] = JsonUtil.extractItems(result.data);
    const libs: MediaFolder[] = [];
    const rest: MediaFolder[] = [];
    for (let i = 0; i < items.length; i++) {
      const src: ESObject = items[i] as ESObject;
      const path: string = JsonUtil.getString(src, 'Path', '');
      if (path.length === 0) {
        continue;
      }
      const folder: MediaFolder = new MediaFolder(
        JsonUtil.getString(src, 'Name', path),
        path,
        JsonUtil.getString(src, 'CollectionType', ''),
        JsonUtil.getString(src, 'Type', ''));
      // 有 collectionType 的是媒体库；播放列表目录等归到"其它"
      if (folder.collectionType.length > 0 && folder.collectionType !== 'playlists') {
        libs.push(folder);
      } else {
        rest.push(folder);
      }
    }
    this.libraries = libs;
    this.others = rest;
    this.status = (libs.length + rest.length) === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  @Builder
  FolderRows(folders: MediaFolder[]) {
    Column() {
      ForEach(folders, (folder: MediaFolder, index: number) => {
        Column() {
          SettingCell({
            title: folder.name,
            subtitle: folder.path,
            showIcon: true,
            icon: $r('sys.symbol.folder')
          })
          if (folder.collectionType.length > 0) {
            Row() {
              ChipButton({
                label: collectionTypeLabel(folder.collectionType),
                selected: false,
                tone: 'neutral',
                onTap: () => {
                }
              })
              Blank()
            }
            .width('100%')
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
              bottom: 10 })
          }
          if (index < folders.length - 1) {
            Divider().color(this.colors().divider).strokeWidth(0.5)
          }
        }
        .width('100%')
      }, (folder: MediaFolder) => `${folder.name}-${folder.path}`)
    }
    .width('100%')
  }

  build() {
    Column() {
      PageHeader({
        title: '本地媒体文件夹',
        onBack: () => {
          router.back();
        }
      })

      if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
        LoadingState()
      } else if (this.status === UiState.ERROR || this.status === UiState.EMPTY) {
        EmptyState({
          message: this.status === UiState.EMPTY
            ? '服务器上没有配置任何本地媒体文件夹。'
            : (this.errorMsg.length > 0 ? this.errorMsg : '加载失败'),
          actionLabel: this.status === UiState.ERROR ? '重试' : '刷新',
          onAction: () => {
            this.reload();
          }
        })
      } else {
        Scroll() {
          Column() {
            if (this.libraries.length > 0) {
              SectionCard({ title: `媒体库（${this.libraries.length}）`,
                icon: $r('sys.symbol.folder'), showHeaderIcon: true }) {
                this.FolderRows(this.libraries)
              }
            }
            if (this.others.length > 0) {
              SectionCard({ title: `其它文件夹（${this.others.length}）`,
                icon: $r('sys.symbol.rectangle_stack'), showHeaderIcon: true }) {
                this.FolderRows(this.others)
              }
            }

            Text('这一页是只读的：媒体库路径的增删改在「媒体库管理」里做。')
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.colors().textTertiary)
              .width('100%')
              .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                top: 4 })

            Blank().height(24)
          }
          .width('100%')
          .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
