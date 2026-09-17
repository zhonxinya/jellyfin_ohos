import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { formatTicks } from '../common/format';
import { PageHeader } from '../components/PageHeader';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { AppIconButton } from '../components/AppIconButton';
import { JellyfinImage } from '../components/JellyfinImage';
import { TextButton } from '../components/TextButton';

/**
 * 播放列表内容页。
 *
 * 为什么必须有这一页：此前在「播放列表」页点击一个列表会跳到**详情页**，
 * 而详情页不认识 Playlist（会拿 playlistId 去请求 PlaybackInfo）——
 * 结果是用户建完列表后既看不到里面的曲目、也播不了、更删不掉，整条功能等于不存在。
 *
 * 页面能力：查看条目（序号 + 封面 + 时长）、点条目播放、条目操作（上移/下移/从列表移除）、
 * 删除整个列表。条目操作走系统 ActionMenu（与设置页/媒体库排序一致）。
 *
 * 关键实现细节（设备实测得来）：
 * - 「移除/移动」必须用条目的 `PlaylistItemId`（列表条目 id），不是媒体条目 id ——
 *   用媒体 id 调删除会返回 204 但什么都不删；
 * - 读取列表内容时 `userId` 是必填参数，缺省服务端返回 400。
 */
@Entry
@Component
struct PlaylistPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private title: string = '播放列表';
  @State private playlistId: string = '';
  @State private items: MediaItem[] = [];
  @State private busy: boolean = false;
  /** 操作结果提示（成功/失败都要可见） */
  @State private actionNote: string = '';
  private totalCount: number = -1;

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idVal: Object | undefined = params['playlistId'];
      if (typeof idVal === 'string') {
        this.playlistId = idVal;
      }
      const titleVal: Object | undefined = params['title'];
      if (typeof titleVal === 'string' && titleVal.length > 0) {
        this.title = titleVal;
      }
    }
    this.reload();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async reload(): Promise<void> {
    if (this.playlistId.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '缺少播放列表标识';
      return;
    }
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult =
      JellyfinNative.parseResult(await JellyfinNative.getPlaylistItems(this.playlistId, 0, 200));
    if (!result.ok || result.data === null) {
      // 解析/请求异常也必须落到终态，否则界面永远停在"加载中"
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载播放列表内容失败';
      return;
    }
    try {
      this.items = MediaItem.fromArray(JsonUtil.extractItems(result.data));
      this.totalCount = JsonUtil.getNumber(result.data as ESObject, 'TotalRecordCount', -1);
      this.status = this.items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
    } catch (err) {
      this.status = UiState.ERROR;
      this.errorMsg = `加载失败：${(err as Error).message}`;
    }
  }

  /** 点条目：直接播放这一条（本播放器没有"播放队列"，故不做整表连播） */
  private playItem(item: MediaItem): void {
    if (item.id.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/PlayerPage',
      params: { itemId: item.id, title: item.displayTitle() }
    });
  }

  /** 播放第一条（"从头播放"） */
  private playFirst(): void {
    if (this.items.length === 0) {
      this.showNote('列表是空的');
      return;
    }
    this.playItem(this.items[0]);
  }

  private showNote(text: string): void {
    this.actionNote = text;
    try {
      this.getUIContext().getPromptAction().showToast({ message: text, duration: 2000 });
    } catch (err) {
      // toast 不可用不影响状态
    }
  }

  private openItemMenu(item: MediaItem, index: number): void {
    const ctx = this.getUIContext();
    ctx.getPromptAction().showActionMenu({
      title: item.displayTitle(),
      buttons: [
        { text: '播放', color: '#007DFF' },
        { text: '上移', color: '#007DFF' },
        { text: '下移', color: '#007DFF' },
        { text: '从列表移除', color: '#E84026' }
      ]
    }).then((result) => {
      if (result.index === 0) {
        this.playItem(item);
      } else if (result.index === 1) {
        this.moveItem(item, index - 1);
      } else if (result.index === 2) {
        this.moveItem(item, index + 1);
      } else if (result.index === 3) {
        this.removeItem(item);
      }
    }).catch(() => {
      // 用户取消
    });
  }

  private async moveItem(item: MediaItem, newIndex: number): Promise<void> {
    if (this.busy || newIndex < 0 || newIndex >= this.items.length) {
      return;
    }
    if (item.playlistItemId.length === 0) {
      this.showNote('该条目缺少列表条目 id，无法调整顺序');
      return;
    }
    this.busy = true;
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.movePlaylistItem(this.playlistId, item.playlistItemId, newIndex));
    this.busy = false;
    if (!result.ok) {
      this.showNote(result.message.length > 0 ? `调整顺序失败：${result.message}` : '调整顺序失败');
      return;
    }
    this.showNote(newIndex < this.items.length - 1 ? '已上移' : '已下移');
    await this.reload();
  }

  private async removeItem(item: MediaItem): Promise<void> {
    if (this.busy) {
      return;
    }
    if (item.playlistItemId.length === 0) {
      this.showNote('该条目缺少列表条目 id，无法移除');
      return;
    }
    this.busy = true;
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.removeFromPlaylist(this.playlistId, item.playlistItemId));
    this.busy = false;
    if (!result.ok) {
      this.showNote(result.message.length > 0 ? `移除失败：${result.message}` : '移除失败');
      return;
    }
    this.showNote('已从列表移除');
    await this.reload();
  }

  private confirmDelete(): void {
    const ctx = this.getUIContext();
    ctx.getPromptAction().showActionMenu({
      title: `删除播放列表「${this.title}」？`,
      buttons: [
        { text: '取消', color: '#007DFF' },
        { text: '删除', color: '#E84026' }
      ]
    }).then((result) => {
      if (result.index === 1) {
        this.deletePlaylist();
      }
    }).catch(() => {
      // 用户取消
    });
  }

  private async deletePlaylist(): Promise<void> {
    if (this.busy) {
      return;
    }
    this.busy = true;
    const result: NativeResult =
      JellyfinNative.parseResult(await JellyfinNative.deletePlaylist(this.playlistId));
    this.busy = false;
    if (!result.ok) {
      this.showNote(result.message.length > 0 ? `删除失败：${result.message}` : '删除失败');
      return;
    }
    router.back();
  }

  /** 列表条目：序号 + 封面 + 标题/元信息 + 操作入口 */
  @Builder
  PlaylistRow(item: MediaItem, index: number) {
    Row({ space: 12 }) {
      Text(`${index + 1}`)
        .fontSize(ThemeConstants.META_MEDIUM)
        .fontColor(this.colors().textTertiary)
        .width(28)
        .textAlign(TextAlign.Center)

      JellyfinImage({
        url: item.imageUrl(128, 'Primary'),
        imgWidth: ThemeConstants.LIST_THUMB_WIDTH,
        imgHeight: ThemeConstants.LIST_THUMB_HEIGHT,
        cornerRadius: ThemeConstants.COVER_RADIUS
      })

      Column({ space: 4 }) {
        Text(item.displayTitle())
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
        Text(item.metaLine().length > 0 ? item.metaLine() : formatTicks(item.runTimeTicks))
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)

      AppIconButton({
        icon: $r('sys.symbol.ellipsis_circle'),
        variant: 'ghost',
        iconSize: 18,
        onTap: () => {
          this.openItemMenu(item, index);
        }
      })
    }
    .width('100%')
    .padding(ThemeConstants.CARD_PADDING)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(ThemeConstants.CARD_RADIUS)
    .onClick(() => {
      this.playItem(item);
    })
  }

  build() {
    Column() {
      PageHeader({
        title: this.title,
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
          EmptyState({ message: '这个播放列表还没有内容' })
        }
      } else {
        Row({ space: 8 }) {
          Text(this.totalCount >= 0 ? `共 ${this.totalCount} 项` : `${this.items.length} 项`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .layoutWeight(1)
          TextButton({
            label: '从头播放',
            onTap: () => {
              this.playFirst();
            }
          })
          TextButton({
            label: '删除列表',
            onTap: () => {
              this.confirmDelete();
            }
          })
        }
        .width('100%')
        .padding({ left: 16, right: 16, bottom: 8 })

        if (this.actionNote.length > 0) {
          Text(this.actionNote)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().brandPrimary)
            .width('100%')
            .padding({ left: 16, right: 16, bottom: 6 })
        }

        List({ space: ThemeConstants.LIST_SPACE }) {
          ForEach(this.items, (item: MediaItem, index: number) => {
            ListItem() {
              this.PlaylistRow(item, index)
            }
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })
          }, (item: MediaItem, index: number) => `${item.playlistItemId}_${index}`)
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
