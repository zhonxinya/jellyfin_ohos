import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import hilog from '@ohos.hilog';

const DOMAIN: number = 0x0000;
const TAG: string = 'SessionStore';
const STORE_NAME: string = 'jellyfin_session';
const KEY_SESSION: string = 'session_json';
const KEY_SERVER: string = 'server_url';
const KEY_LAST_USERNAME: string = 'last_username';
const KEY_LEGAL_CONSENT: string = 'legal_consent_version';
const KEY_DEVICE_ID: string = 'device_id';

/**
 * Persist session / server URL via preferences.
 */
export class SessionStore {
  private static pref: preferences.Preferences | null = null;
  private static initPromise: Promise<boolean> | null = null;

  static async init(context: common.Context): Promise<boolean> {
    if (SessionStore.initPromise !== null) {
      return SessionStore.initPromise;
    }
    SessionStore.initPromise = SessionStore.doInit(context);
    return SessionStore.initPromise;
  }

  private static async doInit(context: common.Context): Promise<boolean> {
    try {
      const appCtx: common.Context = context.getApplicationContext();
      SessionStore.pref = await preferences.getPreferences(appCtx, STORE_NAME);
      return true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(error));
      SessionStore.pref = null;
      SessionStore.initPromise = null;
      return false;
    }
  }

  static async saveSession(sessionJson: string): Promise<boolean> {
    if (SessionStore.pref === null) {
      hilog.warn(DOMAIN, TAG, 'saveSession skipped: preferences not initialized');
      return false;
    }
    try {
      await SessionStore.pref.put(KEY_SESSION, sessionJson);
      await SessionStore.pref.flush();
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveSession failed: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  static async loadSession(): Promise<string> {
    if (SessionStore.pref === null) {
      return '';
    }
    try {
      const value: preferences.ValueType = await SessionStore.pref.get(KEY_SESSION, '');
      if (typeof value === 'string') {
        return value;
      }
      return '';
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadSession failed: %{public}s', JSON.stringify(error));
      return '';
    }
  }

  static async clearSession(): Promise<void> {
    if (SessionStore.pref === null) {
      return;
    }
    try {
      await SessionStore.pref.delete(KEY_SESSION);
      await SessionStore.pref.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clearSession failed: %{public}s', JSON.stringify(error));
    }
  }

  static async saveServerUrl(url: string): Promise<void> {
    if (SessionStore.pref === null) {
      return;
    }
    try {
      await SessionStore.pref.put(KEY_SERVER, url);
      await SessionStore.pref.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveServerUrl failed: %{public}s', JSON.stringify(error));
    }
  }

  static async saveLastUsername(username: string): Promise<void> {
    if (SessionStore.pref === null) {
      return;
    }
    try {
      await SessionStore.pref.put(KEY_LAST_USERNAME, username);
      await SessionStore.pref.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveLastUsername failed: %{public}s', JSON.stringify(error));
    }
  }

  static getLastUsernameStorage(): string {
    if (SessionStore.pref === null) {
      return '';
    }
    try {
      const value: preferences.ValueType = SessionStore.pref.getSync(KEY_LAST_USERNAME, '');
      if (typeof value === 'string') {
        return value;
      }
    } catch (_e) {
      // ignore
    }
    return '';
  }

  static async loadServerUrl(): Promise<string> {
    if (SessionStore.pref === null) {
      return '';
    }
    try {
      const value: preferences.ValueType = await SessionStore.pref.get(KEY_SERVER, '');
      if (typeof value === 'string') {
        return value;
      }
      return '';
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadServerUrl failed: %{public}s', JSON.stringify(error));
      return '';
    }
  }

  /** 保存用户已同意的隐私政策/用户协议版本号（上架合规：政策更新后需重新征得同意） */
  static async saveLegalConsent(version: string): Promise<void> {
    if (SessionStore.pref === null) {
      return;
    }
    try {
      await SessionStore.pref.put(KEY_LEGAL_CONSENT, version);
      await SessionStore.pref.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveLegalConsent failed: %{public}s', JSON.stringify(error));
    }
  }

  /** 读取已同意的政策版本号；未同意时返回空串 */
  static async loadLegalConsent(): Promise<string> {
    if (SessionStore.pref === null) {
      return '';
    }
    try {
      const value: preferences.ValueType = await SessionStore.pref.get(KEY_LEGAL_CONSENT, '');
      if (typeof value === 'string') {
        return value;
      }
      return '';
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadLegalConsent failed: %{public}s', JSON.stringify(error));
      return '';
    }
  }

  /** 清除全部本地数据（会话、服务器地址、偏好、隐私同意状态）——上架合规的"数据清除"入口使用 */
  static async clearAll(): Promise<void> {
    if (SessionStore.pref === null) {
      return;
    }
    try {
      await SessionStore.pref.clear();
      await SessionStore.pref.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clearAll failed: %{public}s', JSON.stringify(error));
    }
  }

  /**
   * 读取设备标识；不存在时生成并持久化一个。
   *
   * 为什么需要：C++ `SessionManager` 只在内存里随机生成 deviceId，且仅随 session JSON 持久化，
   * 于是"退出登录 → 重新登录"就会换一个设备标识，服务端 /Devices 与 /Sessions 里会不断堆积
   * 重复设备（本轮设备实测：累积 15 条本客户端会话）。这里把设备标识独立持久化，使其在一次安装内稳定。
   */
  static async ensureDeviceId(): Promise<string> {
    const existing: string = await SessionStore.loadDeviceId();
    if (existing.length > 0) {
      return existing;
    }
    const generated: string = SessionStore.randomDeviceId();
    await SessionStore.saveDeviceId(generated);
    return generated;
  }

  static async loadDeviceId(): Promise<string> {
    if (SessionStore.pref === null) {
      return '';
    }
    try {
      const value: preferences.ValueType = await SessionStore.pref.get(KEY_DEVICE_ID, '');
      return typeof value === 'string' ? value : '';
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadDeviceId failed: %{public}s', JSON.stringify(error));
      return '';
    }
  }

  static async saveDeviceId(id: string): Promise<void> {
    if (SessionStore.pref === null || id.length === 0) {
      return;
    }
    try {
      await SessionStore.pref.put(KEY_DEVICE_ID, id);
      await SessionStore.pref.flush();
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveDeviceId failed: %{public}s', JSON.stringify(error));
    }
  }

  /** 无加密需求，仅需一次安装内稳定且全局唯一，格式与 Jellyfin 常见客户端一致 */
  private static randomDeviceId(): string {
    const chars: string = '0123456789abcdef';
    let out: string = '';
    for (let i = 0; i < 32; i++) {
      out += chars.charAt(Math.floor(Math.random() * chars.length));
    }
    return out;
  }
}
