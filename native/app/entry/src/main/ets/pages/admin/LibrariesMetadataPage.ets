import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

@Entry
@Component
struct LibrariesMetadataPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private paths: string[] = [];

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
    // /Library/MediaFolders returns { Items: [{ Path: "..." }, ...] }
    const items: Object[] = JsonUtil.extractItems(result.data);
    const parsed: string[] = [];
    for (let i = 0; i < items.length; i++) {
      const p: string = JsonUtil.getString(items[i] as ESObject, 'Path', '');
      if (p.length > 0) {
        parsed.push(p);
      }
    }
    this.paths = parsed;
    this.status = parsed.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  @Builder
  PathItem(path: string) {
    Row({ space: 12 }) {
      Text('📁')
        .fontSize(ThemeConstants.TITLE_LARGE)
        .fontColor(this.colors().brandPrimary)
        .width(28)
      Text(path)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(this.colors().cardBackground)
  }

  build() {
    Column() {
      PageHeader({
        title: '媒体库元数据',
        onBack: () => {
          router.back();
        }
      })

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
          EmptyState({ message: '当前没有配置任何本地媒体文件夹。请确保 Jellyfin 服务器已添加媒体路径。' })
        }
      } else {
        Column({ space: 8 }) {
          // 头部说明
          Row() {
            Text(`共 ${this.paths.length} 个本地路径`)
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.colors().textSecondary)
            Blank()
            Button('刷新')
              .height(28)
              .fontSize(ThemeConstants.META_SMALL)
              .padding({ left: 10, right: 10 })
              .backgroundColor(this.colors().surfacePressed)
              .fontColor(this.colors().textPrimary)
              .onClick(() => {
                this.reload();
              })
          }
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 4 })

          // 路径列表
          List({ space: 8 }) {
            ForEach(this.paths, (p: string) => {
              ListItem() {
                this.PathItem(p)
              }
            }, (p: string) => p)
          }
          .width('100%')
          .layoutWeight(1)
          .padding({ left: 16, right: 16, bottom: 24 })
          .scrollBar(BarState.Auto)
        }
        .width('100%')
        .height('100%')
        .backgroundColor(this.colors().pageBackground)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
