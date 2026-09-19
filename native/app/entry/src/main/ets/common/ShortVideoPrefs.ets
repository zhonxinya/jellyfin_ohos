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

/** 短视频清晰度（= 播放时向服务端请求的质量档位）的偏好键 */
export const kShortVideoQualityKey: string = 'shortVideoQuality';

/**
 * 一档清晰度。
 *
 * 为什么做成"档位"而不是让用户填码率：短视频是"打开就刷"的场景，
 * 用户要的是"选一个能接受的清晰度"，而不是调参。档位同时决定了**播放方式**：
 * 选具体分辨率 = 由服务端转码到该清晰度（设码率上限 + 关闭直连），
 * 选「自动」= 直连优先、服务端只在必要时转码。
 */
export class ShortVideoQuality {
  /** 稳定标识（存进偏好；改文案不影响已存的设置） */
  id: string = 'auto';
  /** 单选行标题 */
  label: string = '';
  /** 单选行副标题：说清"会走直连还是转码、码率多少" */
  subtitle: string = '';
  /** 请求的码率上限（bps）；0 = 不限制（交给服务端按源决定） */
  maxStreamingBitrate: number = 0;
  /** 是否强制服务端转码（关掉直连/直接串流） */
  forceTranscode: boolean = false;
  /** 是否随请求带 DeviceProfile（关掉 = 让服务端假定"什么都能直连"） */
  includeDeviceProfile: boolean = true;
}

/**
 * 清晰度档位表（单选，第一项为默认）。
 *
 * 「自动」之外的**具体分辨率档位一律强制转码**：用户选了 720p 就该真的拿到 720p，
 * 而不是"服务端觉得不用转、于是给你原画"。码率取主流档位
 * （10 / 4 / 1.5 Mbps 与 720 Kbps）。
 */
export const kShortVideoQualities: ShortVideoQuality[] = [
  {
    id: 'auto', label: '自动（推荐）',
    subtitle: '直连优先；本机解不了的编码由服务端转码，码率不设上限',
    maxStreamingBitrate: 0, forceTranscode: false, includeDeviceProfile: true
  },
  {
    id: 'direct', label: '原画直连',
    subtitle: '始终直连、不请求转码（服务端转码不可用时选它；解不了的编码走本机软解）',
    maxStreamingBitrate: 0, forceTranscode: false, includeDeviceProfile: false
  },
  {
    id: '1080p', label: '1080p · 10 Mbps',
    subtitle: '由服务端转码到该清晰度（画质优先）',
    maxStreamingBitrate: 10000000, forceTranscode: true, includeDeviceProfile: true
  },
  {
    id: '720p', label: '720p · 4 Mbps',
    subtitle: '由服务端转码到该清晰度（画质与流量的平衡点）',
    maxStreamingBitrate: 4000000, forceTranscode: true, includeDeviceProfile: true
  },
  {
    id: '480p', label: '480p · 1.5 Mbps',
    subtitle: '由服务端转码到该清晰度（移动网络下更稳）',
    maxStreamingBitrate: 1500000, forceTranscode: true, includeDeviceProfile: true
  },
  {
    id: '360p', label: '360p · 720 Kbps',
    subtitle: '由服务端转码到该清晰度（最省流量）',
    maxStreamingBitrate: 720000, forceTranscode: true, includeDeviceProfile: true
  }
];

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

  // ─────────────────────── 清晰度（服务器转码质量）───────────────────────

  /**
   * 读取清晰度档位 id。
   *
   * 为什么要"回落"：偏好里可能存着旧版本或未知的档位（也可能被人手改坏），
   * 这时必须回到「自动」而不是把播放参数拼错 —— 播放失败是最难排查的后果。
   */
  static loadQualityId(): string {
    try {
      const raw: string = JellyfinNative.getPreferences();
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        return 'auto';
      }
      const id: string = JsonUtil.getString(result.data as ESObject, kShortVideoQualityKey, '');
      return ShortVideoPrefs.isKnownQuality(id) ? id : 'auto';
    } catch (err) {
      return 'auto';
    }
  }

  /** 当前清晰度档位（未知 id 回落「自动」） */
  static quality(): ShortVideoQuality {
    const id: string = ShortVideoPrefs.loadQualityId();
    for (let i = 0; i < kShortVideoQualities.length; i++) {
      if (kShortVideoQualities[i].id === id) {
        return kShortVideoQualities[i];
      }
    }
    return kShortVideoQualities[0];
  }

  private static isKnownQuality(id: string): boolean {
    for (let i = 0; i < kShortVideoQualities.length; i++) {
      if (kShortVideoQualities[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /** 保存清晰度档位（写偏好 + 落盘 session） */
  static saveQualityId(id: string): void {
    JellyfinNative.setPreference(kShortVideoQualityKey, id);
    SessionStore.saveSession(JellyfinNative.getSession());
    AppViewModel.getInstance().notifyLocalPrefsChanged();
  }

  /** 当前档位的短标签（工具栏上显示"现在是什么清晰度"） */
  static qualityShortLabel(): string {
    const q: ShortVideoQuality = ShortVideoPrefs.quality();
    if (q.id === 'auto') {
      return '自动';
    }
    if (q.id === 'direct') {
      return '原画';
    }
    return q.id;
  }

  /**
   * 播放参数（交给 `playerOpen` 的 optionsJson）。
   *
   * 三条分支对应三种意图：
   * - 「自动」：直连优先，但带上 DeviceProfile —— 本机解不了的编码（AV1 等）
   *   由服务端转码成 H.264/AAC 的 HLS 流，交给系统硬解；
   * - 「原画直连」：关掉转码并去掉 DeviceProfile，服务端只给直连地址；
   * - 具体分辨率：**关掉直连/直接串流 + 设码率上限**，服务端必然转码到该清晰度。
   */
  static playbackOptionsJson(): string {
    const q: ShortVideoQuality = ShortVideoPrefs.quality();
    if (q.id === 'direct') {
      return ShortVideoPrefs.directOptionsJson();
    }
    if (q.forceTranscode) {
      return `{"maxStreamingBitrate":${q.maxStreamingBitrate},`
        + '"enableDirectPlay":false,"enableDirectStream":false,'
        + '"enableTranscoding":true,"includeDeviceProfile":true}';
    }
    return '{"enableDirectPlay":true,"enableDirectStream":true,'
      + '"enableTranscoding":true,"includeDeviceProfile":true}';
  }

  /**
   * **直连**播放参数：只给本机软解（FFmpeg）用。
   *
   * 为什么软解必须强制直连：本工程的 FFmpeg 是 `--disable-network` 构建的
   * （取流由宿主的 HTTP 客户端按 Range 取字节，见 `native/feature/player/README.md`），
   * 它**打不开 HLS（.m3u8 + 分片）**。若软解仍带 DeviceProfile，服务端会为
   * "本机不支持的编码"返回转码地址，软解拿到一个 m3u8 就只有失败一条路
   * （表现为"这条内容播不了，直接跳过"）。去掉 DeviceProfile 后服务端回到
   * 直连地址（`/Videos/{id}/stream?static=true`），dav1d / FFmpeg 才真的能解。
   */
  static directOptionsJson(): string {
    return '{"enableDirectPlay":true,"enableDirectStream":true,'
      + '"enableTranscoding":false,"includeDeviceProfile":false}';
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
