import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { PageHeader } from '../components/PageHeader';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { MediaCollectionView } from '../components/MediaCollectionView';
import { TextButton } from '../components/TextButton';

@Entry
@Component
struct PlaylistsPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private items: MediaItem[] = [];
  @State private viewMode: string = 'grid';

  aboutToAppear(): void {
    this.reload();
  }

  /**
   * 每次回到本页都刷新。
   *
   * 为什么需要：删除播放列表后返回本页时，页面还挂着删除前的那份列表
   * （只在 aboutToAppear 加载），用户会看到"删掉的列表又回来了"。
   */
  onPageShow(): void {
    this.reload();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.getPlaylists());
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载播放列表失败';
      return;
    }
    this.items = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    this.status = this.items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private openItem(item: MediaItem): void {
    if (item.id.length === 0) {
      return;
    }
    // 播放列表要进"列表内容页"，不能进详情页：
    // 详情页不认识 Playlist，会拿 playlistId 去请求 PlaybackInfo（失败），
    // 用户也就看不到曲目、播不了、删不掉。
    router.pushUrl({
      url: 'pages/PlaylistPage',
      params: { playlistId: item.id, title: item.name }
    });
  }

  build() {
    Column() {
      PageHeader({ title: '播放列表', onBack: () => { router.back(); } })
      if (this.status !== UiState.SUCCESS) {
        if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState()
        } else if (this.status === UiState.ERROR) {
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
            actionLabel: '重试',
            onAction: () => { this.reload(); }
          })
        } else if (this.status === UiState.EMPTY) {
          EmptyState({ message: '暂无播放列表' })
        }
      } else {
        Row() {
          Text(`${this.items.length} 个播放列表`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .layoutWeight(1)
          // 刷新入口改用参考项目 TextButton（13fp Medium 品牌色 + 按下态），
          // 原来是 32vp/12fp 的临时小按钮
          TextButton({
            label: '刷新',
            onTap: () => {
              this.reload();
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })
        MediaCollectionView({
          items: $items,
          viewMode: this.viewMode,
          loadingMore: false,
          hasMore: false,
          onItemTap: (item: MediaItem) => { this.openItem(item); },
          onReachEnd: () => {}
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
