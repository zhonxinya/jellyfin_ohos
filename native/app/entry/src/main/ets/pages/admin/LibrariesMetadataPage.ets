import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { AsyncStateView } from '../../components/AsyncStateView';

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
        .fontSize(20)
        .fontColor(this.colors().primary)
        .width(28)
      Text(path)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().onSurface)
        .layoutWeight(1)
        .maxLines(2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 14, bottom: 14 })
    .backgroundColor(this.colors().surface)
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
        AsyncStateView({
          status: this.status,
          message: this.errorMsg,
          emptyHint: '当前没有配置任何本地媒体文件夹。请确保 Jellyfin 服务器已添加媒体路径。',
          minHeight: 200,
          onRetry: () => {
            this.reload();
          }
        })
      } else {
        Column({ space: 8 }) {
          // 头部说明
          Row() {
            Text(`共 ${this.paths.length} 个本地路径`)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onSurfaceVariant)
            Blank()
            Button('刷新')
              .height(28)
              .fontSize(12)
              .padding({ left: 10, right: 10 })
              .backgroundColor(this.colors().surfaceElevated)
              .fontColor(this.colors().onSurface)
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
        .backgroundColor(this.colors().background)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().background)
  }
}
