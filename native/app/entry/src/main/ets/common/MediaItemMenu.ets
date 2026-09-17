import router from '@ohos.router';
import promptAction from '@ohos.promptAction';
import { UIContext } from '@ohos.arkui.UIContext';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from './JsonUtil';
import { MediaItem } from '../models/MediaItem';

/**
 * 网格/列表里对条目做操作的统一入口（长按卡片弹出的菜单）。
 *
 * 为什么需要它：此前"收藏 / 标记已看 / 加入播放列表 / 播放"**只能进详情页**再操作，
 * 在媒体库里管理观看状态要"进详情 → 操作 → 返回"，这是与主流 Jellyfin 客户端
 * 最大的交互差距。把菜单与动作收敛到一个 helper 里，各页面只要一行接线，
 * 避免 8 个列表页各写一份（也避免各处提示文案不一致）。
 */
export class MediaItemMenu {
  /** 弹出条目操作菜单；`onChanged` 在状态真的变化后调用（页面据此刷新卡片） */
  static show(ctx: UIContext, item: MediaItem, onChanged: () => void): void {
    const favLabel: string = item.isFavorite ? '取消收藏' : '加入我的最爱';
    const playedLabel: string = item.isPlayed ? '标记为未播放' : '标记为已播放';
    ctx.getPromptAction().showActionMenu({
      title: item.displayTitle(),
      buttons: [
        { text: '播放', color: '#007DFF' },
        { text: favLabel, color: '#007DFF' },
        { text: playedLabel, color: '#007DFF' },
        { text: '加入播放列表', color: '#007DFF' }
      ]
    }).then((result) => {
      if (result.index === 0) {
        MediaItemMenu.play(item);
      } else if (result.index === 1) {
        MediaItemMenu.toggleFavorite(ctx, item, onChanged);
      } else if (result.index === 2) {
        MediaItemMenu.togglePlayed(ctx, item, onChanged);
      } else if (result.index === 3) {
        MediaItemMenu.pickPlaylist(ctx, item, onChanged);
      }
    }).catch(() => {
      // 用户取消菜单
    });
  }

  static play(item: MediaItem): void {
    if (item.id.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/PlayerPage',
      params: { itemId: item.id, title: item.displayTitle() }
    });
  }

  /**
   * 让列表卡片重新渲染（菜单改了收藏/已看状态后调用）。
   *
   * 为什么是"浅拷贝数组"而不是重新请求：`MediaItem` 是类实例，直接改字段不会触发 `@State` 变化；
   * 而列表的 `ForEach` key 里带了观看/收藏状态，数组一变就会重建对应卡片。
   * 不重新拉取数据是为了保住用户的滚动位置（重新 reload 会跳回第一页顶部）。
   */
  static touch(items: MediaItem[]): MediaItem[] {
    return items.slice();
  }

  private static async toggleFavorite(ctx: UIContext, item: MediaItem,
                                       onChanged: () => void): Promise<void> {
    const next: boolean = !item.isFavorite;
    const result: NativeResult =
      JellyfinNative.parseResult(await JellyfinNative.toggleFavorite(item.id, next));
    if (!result.ok) {
      MediaItemMenu.toast(ctx, result.message.length > 0 ? `操作失败：${result.message}`
                                                          : '操作失败（服务端未接受）');
      return;
    }
    item.isFavorite = next;
    MediaItemMenu.toast(ctx, next ? '已加入我的最爱' : '已取消收藏');
    onChanged();
  }

  private static async togglePlayed(ctx: UIContext, item: MediaItem,
                                    onChanged: () => void): Promise<void> {
    const next: boolean = !item.isPlayed;
    const result: NativeResult =
      JellyfinNative.parseResult(await JellyfinNative.togglePlayed(item.id, next));
    if (!result.ok) {
      MediaItemMenu.toast(ctx, result.message.length > 0 ? `操作失败：${result.message}`
                                                          : '操作失败（服务端未接受）');
      return;
    }
    item.isPlayed = next;
    MediaItemMenu.toast(ctx, next ? '已标记为已播放' : '已标记为未播放');
    onChanged();
  }

  /** 加入播放列表：先列出现有列表让用户选（没有列表时明确告知去哪里新建） */
  private static async pickPlaylist(ctx: UIContext, item: MediaItem,
                                    onChanged: () => void): Promise<void> {
    const result: NativeResult = JellyfinNative.parseResult(await JellyfinNative.getPlaylists());
    if (!result.ok || result.data === null) {
      MediaItemMenu.toast(ctx, result.message.length > 0 ? result.message : '读取播放列表失败');
      return;
    }
    const playlists: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(result.data));
    if (playlists.length === 0) {
      MediaItemMenu.toast(ctx, '还没有播放列表：可在条目详情页的「加入播放列表」里新建');
      return;
    }
    try {
      MediaItemMenu.showPlaylistMenu(ctx, playlists, item, onChanged);
    } catch (err) {
      // 组织菜单本身失败也要说出来，否则表现为"点了加入播放列表没反应"
      MediaItemMenu.toast(ctx, `打开播放列表菜单失败：${(err as Error).message}`);
    }
  }

  /**
   * 二级菜单：选一个播放列表加进去。
   *
   * `showActionMenu` 的 `buttons` 是**元组**（1 个必填 + 5 个可选），不是数组 ——
   * 传 `Button[]` 编译不过，而"补 undefined 占位"在运行时不生效（菜单弹不出来），
   * 因此这里按实际数量分支，每次都用确定的字面量元组（最多 6 个）。
   */
  private static showPlaylistMenu(ctx: UIContext, playlists: MediaItem[], item: MediaItem,
                                  onChanged: () => void): void {
    const b = (i: number): promptAction.Button => {
      return { text: playlists[i].name, color: '#007DFF' };
    };
    const pick = (index: number): void => {
      if (index >= 0 && index < playlists.length) {
        MediaItemMenu.addToPlaylist(ctx, playlists[index], item, onChanged);
      }
    };
    const count: number = Math.min(playlists.length, 6);
    if (count === 1) {
      ctx.getPromptAction().showActionMenu({ title: '加入播放列表', buttons: [b(0)] })
        .then((r) => { pick(r.index); }).catch(() => {});
    } else if (count === 2) {
      ctx.getPromptAction().showActionMenu({ title: '加入播放列表', buttons: [b(0), b(1)] })
        .then((r) => { pick(r.index); }).catch(() => {});
    } else if (count === 3) {
      ctx.getPromptAction().showActionMenu({ title: '加入播放列表', buttons: [b(0), b(1), b(2)] })
        .then((r) => { pick(r.index); }).catch(() => {});
    } else if (count === 4) {
      ctx.getPromptAction().showActionMenu({ title: '加入播放列表', buttons: [b(0), b(1), b(2), b(3)] })
        .then((r) => { pick(r.index); }).catch(() => {});
    } else if (count === 5) {
      ctx.getPromptAction().showActionMenu({ title: '加入播放列表',
        buttons: [b(0), b(1), b(2), b(3), b(4)] })
        .then((r) => { pick(r.index); }).catch(() => {});
    } else {
      ctx.getPromptAction().showActionMenu({ title: '加入播放列表',
        buttons: [b(0), b(1), b(2), b(3), b(4), b(5)] })
        .then((r) => { pick(r.index); }).catch(() => {});
    }
  }

  private static async addToPlaylist(ctx: UIContext, playlist: MediaItem, item: MediaItem,
                                     onChanged: () => void): Promise<void> {
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.addToPlaylist(playlist.id, item.id));
    if (!result.ok) {
      MediaItemMenu.toast(ctx, result.message.length > 0 ? `加入失败：${result.message}` : '加入失败');
      return;
    }
    MediaItemMenu.toast(ctx, `已加入「${playlist.name}」`);
    onChanged();
  }

  private static toast(ctx: UIContext, message: string): void {
    try {
      ctx.getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // toast 不可用不影响功能本身
    }
  }
}
