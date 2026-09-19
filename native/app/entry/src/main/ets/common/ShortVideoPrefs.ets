import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from './JsonUtil';
import { SessionStore } from '../services/SessionStore';
import { AppViewModel } from '../viewmodel/AppViewModel';

/**
 * 短视频模式的**媒体库配置**（本地偏好）。
 *
 * 为什么存在偏好里而不是服务端：这是"这台设备上我想怎么刷"的客户端偏好，
 * 与服务端配置无关（也不该污染服务端用户配置）。偏好的落盘方式与其它设置一致：
 * `setPreference()` 写进原生 session 的 preferences，再由 `SessionStore.saveSession()`
 * 把 session JSON 落盘 —— 重启后仍在（见 `SettingsPage.persistPreference`）。
 *
 * 存的是**媒体库 id 列表**（不是名称）：名称会随服务端改名/多语言变化，id 才是稳定标识；
 * 名称在渲染时从服务端拿，不在本地缓存副本。
 */
export const kShortVideoLibrariesKey: string = 'shortVideoLibraries';

/** 「视频」页一次批量取的条目数（够滑一阵子，又不至于一次拉太多） */
export const kShortVideoBatchSize: number = 24;

export class ShortVideoPrefs {
  /** 读取已选媒体库 id（保持用户勾选顺序；解析失败按空处理，不让坏数据卡住界面） */
  static loadLibraryIds(): string[] {
    const ids: string[] = [];
    try {
      const raw: string = JellyfinNative.getPreferences();
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        return ids;
      }
      const arr: Object[] = JsonUtil.getArray(result.data as ESObject, kShortVideoLibrariesKey);
      for (let i = 0; i < arr.length; i++) {
        if (typeof arr[i] === 'string') {
          const id: string = arr[i] as string;
          if (id.length > 0 && ids.indexOf(id) < 0) {
            ids.push(id);
          }
        }
      }
    } catch (err) {
      return [];
    }
    return ids;
  }

  /** 保存已选媒体库 id（写偏好 + 落盘 session） */
  static saveLibraryIds(ids: string[]): void {
    const unique: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      const id: string = ids[i];
      if (id.length > 0 && unique.indexOf(id) < 0) {
        unique.push(id);
      }
    }
    JellyfinNative.setPreference(kShortVideoLibrariesKey, JSON.stringify(unique));
    SessionStore.saveSession(JellyfinNative.getSession());
    // 通知外壳：设置主页那行「已选 N 个媒体库」需要重算
    // （设置页是嵌入式组件，从本页返回时不会重建）
    AppViewModel.getInstance().notifyLocalPrefsChanged();
  }

  /** 勾选/取消勾选某个媒体库，返回新的列表 */
  static withToggled(ids: string[], libraryId: string, enabled: boolean): string[] {
    const out: string[] = [];
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] !== libraryId) {
        out.push(ids[i]);
      }
    }
    if (enabled) {
      out.push(libraryId);
    }
    return out;
  }
}
