import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { LibraryContentView } from './LibraryPage';

/**
 * 底部页签「音乐」的承载页。
 *
 * 为什么需要它：音乐的入口原来埋在「媒体库」页签里的媒体库横排里（要横滑到最右才看得到
 * 「音乐」那张卡），而音乐是本应用里唯一"点一首就播"的长内容形态 —— 值得一个固定入口。
 *
 * 这一页只做两件事：
 *  1. 从用户的媒体库视图里找出音乐库（`CollectionType === 'music'`）；
 *  2. 把音乐库交给 `LibraryPage`（`embedded`）渲染 —— 艺术家/专辑/曲目/我的最爱四个视角、
 *     排序筛选、分页、长按菜单、以及"点曲目直接播放/点专辑播放全部"都在那边，本页不重复实现。
 *
 * 服务端可能**没有**音乐库（用户没建、或权限里没勾）：这时给一条明确空态，不留白屏。
 */
@Component
export struct MusicPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private libraryId: string = '';
  @State private libraryName: string = '音乐';
  @Link themeTick: number;

  aboutToAppear(): void {
    this.resolveMusicLibrary();
  }

  private colors(): ThemeColors {
    this.themeTick;
    return AppViewModel.getInstance().colors();
  }

  /**
   * 取音乐库。
   *
   * 为什么走 `getUserViews` 而不是写死库名：库名由用户自定义（本机测试服叫「音乐」，
   * 别人的服务器可能叫「Music」「我的歌单」…），只有 `CollectionType` 是 Jellyfin 的固定语义。
   * 这也与「媒体库」页签里的那张卡是同一个数据源（HomePage 的 views 段），两处入口不会打架。
   */
  private async resolveMusicLibrary(): Promise<void> {
    // 局部变量累积、末尾一次性回写 @State（codelinter 的 @State 赋值计数按整个函数算）
    let status: string = UiState.LOADING;
    let errorMsg: string = '';
    let libraryId: string = '';
    let libraryName: string = '音乐';

    try {
      const raw: string = await JellyfinNative.getUserViews();
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        status = UiState.ERROR;
        errorMsg = result.message.length > 0 ? result.message : '加载媒体库失败';
      } else {
        const views: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
        for (let i = 0; i < views.length; i++) {
          if (views[i].collectionType === 'music') {
            libraryId = views[i].id;
            if (views[i].name.length > 0) {
              libraryName = views[i].name;
            }
            break;
          }
        }
        status = libraryId.length > 0 ? UiState.SUCCESS : UiState.EMPTY;
      }
    } catch (err) {
      status = UiState.ERROR;
      errorMsg = `加载媒体库失败：${(err as Error).message}`;
    }

    this.libraryId = libraryId;
    this.libraryName = libraryName;
    this.errorMsg = errorMsg;
    this.status = status;
  }

  build() {
    Column() {
      if (this.status === UiState.LOADING) {
        LoadingState({ hint: '正在加载音乐库…' })
      } else if (this.status === UiState.ERROR) {
        EmptyState({
          message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
          actionLabel: '重试',
          onAction: () => {
            this.resolveMusicLibrary();
          }
        })
      } else if (this.status === UiState.EMPTY) {
        EmptyState({ message: '服务器上没有音乐库' })
      } else {
        // 库 ID 到手后才创建 LibraryPage：它的 aboutToAppear 只跑一次，
        // 属性为空的第一次创建会拿不到 parentId（空库、白屏）
        LibraryContentView({
          embedded: true,
          embeddedParentId: this.libraryId,
          embeddedTitle: this.libraryName,
          embeddedCollectionType: 'music',
          themeTick: this.themeTick
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
