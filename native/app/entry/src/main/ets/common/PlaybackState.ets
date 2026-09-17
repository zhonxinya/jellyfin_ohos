/**
 * 当前播放状态的最小持有者（进程级）。
 *
 * 为什么要它：播放进度是分散在播放页里的，而"应用退出/被回收"发生在 **Ability** 层
 * （`onDestroy`）。若不在那时上报 `reportPlaybackStopped`，服务端会留下一个"看起来还在播"的
 * 会话（实测 `/Sessions` 堆积到 60 条、多条空闲不收），进而污染观看记录、继续观看与设备列表
 * （同类现象此前表现为服务端出现 22 个重复设备）。
 *
 * 用法：播放页在每次上报进度时 `set()`；停止播放时 `clear()`；
 * `EntryAbility.onDestroy()` 里 `take()` 一次并上报 stopped（take 会清空，避免重复上报）。
 */
export class PlaybackState {
  private static activeItemId: string = '';
  private static activePositionTicks: number = 0;

  /** 记录正在播放的条目与位置（每次上报进度时调用即可） */
  static set(itemId: string, positionTicks: number): void {
    PlaybackState.activeItemId = itemId;
    PlaybackState.activePositionTicks = positionTicks;
  }

  /** 清除（正常停止播放时调用） */
  static clear(): void {
    PlaybackState.activeItemId = '';
    PlaybackState.activePositionTicks = 0;
  }

  static itemId(): string {
    return PlaybackState.activeItemId;
  }

  static positionTicks(): number {
    return PlaybackState.activePositionTicks;
  }

  /** 取出并清空：返回 itemId（无播放时返回空串），用于退出时一次性上报 stopped */
  static take(): string {
    const id: string = PlaybackState.activeItemId;
    PlaybackState.clear();
    return id;
  }
}
