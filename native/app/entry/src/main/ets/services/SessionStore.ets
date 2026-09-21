import preferences from '@ohos.data.preferences';
import common from '@ohos.app.ability.common';
import fs from '@ohos.file.fs';
import hilog from '@ohos.hilog';
import { SecureStore } from './SecureStore';

const DOMAIN: number = 0x0000;
const TAG: string = 'SessionStore';
const STORE_NAME: string = 'jellyfin_session';
const KEY_SESSION: string = 'session_json';
const KEY_SERVER: string = 'server_url';
const KEY_LAST_USERNAME: string = 'last_username';
const KEY_LEGAL_CONSENT: string = 'legal_consent_version';
const KEY_DEVICE_ID: string = 'device_id';
const KEY_SEARCH_HISTORY: string = 'search_history';

/**
 * Persist session / server URL via preferences.
 *
 * 安全约定（不要回退，见 docs/secure-storage.md）：
 * 落到 preferences 的每个值都必须是 `SecureStore` 产出的 AES-256-GCM 密文信封，
 * 主密钥保存在系统关键资产库（Asset Store Kit）中，preferences 文件里不允许出现
 * accessToken / baseUrl / 用户名等敏感明文。读取路径自动兼容历史明文并完成迁移。
 */
export class SessionStore {
  private static pref: preferences.Preferences | null = null;
  private static initPromise: Promise<boolean> | null = null;
  /** 应用沙箱 cache 目录（`context.cacheDir`），由 EntryAbility 在启动时注入 */
  private static appCacheDir: string = '';

  /** 注入应用 cache 目录路径（供清理预加载图片缓存使用） */
  static setAppCacheDir(dir: string): void {
    SessionStore.appCacheDir = dir;
  }

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
      SessionStore.migratePlaintextAtRest();
      return true;
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'init failed: %{public}s', JSON.stringify(error));
      SessionStore.pref = null;
      SessionStore.initPromise = null;
      return false;
    }
  }

  /**
   * 同步迁移：把历史版本的明文键就地改写为密文。
   *
   * 为什么必须在 init 阶段做、且必须同步：`getLastUsernameStorage()` 是同步读取（登录页进入即回填），
   * 它没有任何机会触发异步迁移；只靠"读哪个键迁移哪个键"会让这类同步键长期停留在明文。
   * 所以这里一次性扫全部已知键，遇到明文就立刻加密回写。幂等，重复执行无副作用。
   */
  private static migratePlaintextAtRest(): void {
    const keys: string[] = [KEY_SESSION, KEY_SERVER, KEY_LAST_USERNAME, KEY_LEGAL_CONSENT,
      KEY_DEVICE_ID, KEY_SEARCH_HISTORY];
    try {
      const pref: preferences.Preferences = SessionStore.pref!;
      let migrated: number = 0;
      for (const key of keys) {
        const value: preferences.ValueType = pref.getSync(key, '');
        if (typeof value !== 'string' || value.length === 0 || SecureStore.isEncrypted(value)) {
          continue;
        }
        pref.putSync(key, SecureStore.encrypt(value));
        migrated++;
      }
      if (migrated > 0) {
        pref.flushSync();
        hilog.info(DOMAIN, TAG, 'migrated %{public}d plaintext value(s) to encrypted storage', migrated);
      }
    } catch (error) {
      // 迁移失败不能阻断启动：未迁移的键在读取路径上仍会按明文或密文正确处理
      hilog.warn(DOMAIN, TAG, 'plaintext migration skipped: %{public}s', JSON.stringify(error));
    }
  }

  static async saveSession(sessionJson: string): Promise<boolean> {
    if (SessionStore.pref === null) {
      hilog.warn(DOMAIN, TAG, 'saveSession skipped: preferences not initialized');
      return false;
    }
    if (sessionJson.length === 0) {
      return false;
    }
    try {
      await SessionStore.pref.put(KEY_SESSION, SecureStore.encrypt(sessionJson));
      await SessionStore.pref.flush();
      return true;
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveSession failed: %{public}s', JSON.stringify(error));
      return false;
    }
  }

  /**
   * 读取会话 JSON。
   *
   * 返回空串表示"本机没有可用会话"（包括历史遗留的、已无法解密的密文 —— 那种数据
   * 永远恢复不了，必须当作没有，否则应用每次冷启动都会卡在启动失败）。
   * 主密钥**暂时**不可用时抛错，由调用方决定重试，绝不在这里删数据。
   */
  static async loadSession(): Promise<string> {
    if (SessionStore.pref === null) {
      return '';
    }
    try {
      const stored: string = await SessionStore.readStored(KEY_SESSION);
      const sessionJson: string = SecureStore.decrypt(stored);
      if (stored.length > 0 && sessionJson.length === 0 && SecureStore.isEncrypted(stored)) {
        // 主密钥可用、但这段密文解不开（例如主密钥曾被"清除本地数据"删过）。
        // 这类数据永远不可恢复，必须当成"没有会话"：否则每次冷启动都会因为
        // "有值却解不开"而卡在启动失败，应用再也进不去。同时顺手清掉这个死值。
        hilog.error(DOMAIN, TAG, 'loadSession: undecryptable session dropped');
        await SessionStore.clearSession();
        return '';
      }
      // 历史明文会话：立即原地迁移成密文，避免设备上继续残留明文令牌
      if (sessionJson.length > 0 && !SecureStore.isEncrypted(stored)) {
        await SessionStore.writeStored(KEY_SESSION, sessionJson);
      }
      return sessionJson;
    } catch (error) {
      // 主密钥暂时不可用等异常：向上抛，由调用方决定重试，绝不在这里删数据
      hilog.warn(DOMAIN, TAG, 'loadSession failed: %{public}s', JSON.stringify(error));
      throw error as Error;
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
      await SessionStore.writeStored(KEY_SERVER, url);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveServerUrl failed: %{public}s', JSON.stringify(error));
    }
  }

  static async saveLastUsername(username: string): Promise<void> {
    if (SessionStore.pref === null) {
      return;
    }
    try {
      await SessionStore.writeStored(KEY_LAST_USERNAME, username);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveLastUsername failed: %{public}s', JSON.stringify(error));
    }
  }

  /**
   * 同步读取最近登录用户名（登录页进入时立即回填，必须同步）。
   *
   * 同步路径不能走 Asset/Cipher 的异步接口，这里的做法是：读原始值 →
   * `SecureStore.decrypt` 内部全部使用 cryptoFramework 的 *Sync 接口与 asset.querySync，
   * 因此同步解密是安全的；解密失败返回空串（宁可让用户重填用户名，也不回退成明文读取）。
   */
  static getLastUsernameStorage(): string {
    if (SessionStore.pref === null) {
      return '';
    }
    try {
      const value: preferences.ValueType = SessionStore.pref.getSync(KEY_LAST_USERNAME, '');
      if (typeof value !== 'string' || value.length === 0) {
        return '';
      }
      return SecureStore.decrypt(value);
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
      return await SessionStore.readDecrypted(KEY_SERVER);
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
      await SessionStore.writeStored(KEY_LEGAL_CONSENT, version);
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
      return await SessionStore.readDecrypted(KEY_LEGAL_CONSENT);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadLegalConsent failed: %{public}s', JSON.stringify(error));
      return '';
    }
  }

  /**
   * 清除沙箱内"系统图片管线"的预加载缓存目录（`cache/preload_caches`）。
   *
   * 为什么必须清（设备实测）：该目录以 JPEG 明文保存媒体封面，
   * 实测 283 个文件 / 约 101 MB —— 属于"可反推观看内容"的用户数据。
   * 「清除全部本地数据」只清会话与偏好是不够的，封面图仍留在磁盘上。
   *
   * 目录本身保留（由系统组件管理），只删除其中的文件。
   */
  private static clearPreloadCaches(): void {
    const base: string = SessionStore.appCacheDir;
    if (base.length === 0) {
      return;
    }
    const dir: string = base + '/preload_caches';
    try {
      if (!fs.accessSync(dir)) {
        return;
      }
      let removed: number = 0;
      for (const name of fs.listFileSync(dir)) {
        try {
          fs.unlinkSync(`${dir}/${name}`);
          removed++;
        } catch (_e) {
          // 单个文件被占用/已删除都不影响整体清理
        }
      }
      if (removed > 0) {
        hilog.info(DOMAIN, TAG, 'cleared %{public}d preloaded image file(s)', removed);
      }
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'clearPreloadCaches skipped: %{public}s', JSON.stringify(error));
    }
  }

  /**
   * 清除全部本地数据（会话、服务器地址、偏好、隐私同意状态、图片与预加载缓存）
   * ——上架合规的"数据清除"入口使用。
   *
   * 同时删除系统关键资产库中的主密钥：否则用户点了"清除数据"但凭证的加密密钥仍留在设备上。
   */
  static async clearAll(): Promise<void> {
    if (SessionStore.pref === null) {
      return;
    }
    try {
      await SessionStore.pref.clear();
      await SessionStore.pref.flush();
      SecureStore.clearKey();
      SessionStore.clearPreloadCaches();
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
      return await SessionStore.readDecrypted(KEY_DEVICE_ID);
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
      await SessionStore.writeStored(KEY_DEVICE_ID, id);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveDeviceId failed: %{public}s', JSON.stringify(error));
    }
  }

  /**
   * 搜索历史（JSON 数组字符串）。
   *
   * 为什么不用 `JellyfinNative.setPreference`：那只是 C++ `SessionManager` 里的**内存** map
   * （`setPreference` 不落盘，只有会话 JSON 被持久化时才会顺带写下去），
   * 重启应用就没了 —— 而"搜索历史"必须跨重启保留，所以走真正落盘的 preferences。
   *
   * 搜索历史同样是用户隐私数据（能反推观看偏好），因此与凭证一样加密落盘。
   */
  static async saveSearchHistory(json: string): Promise<void> {
    if (SessionStore.pref === null) {
      return;
    }
    try {
      await SessionStore.writeStored(KEY_SEARCH_HISTORY, json);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'saveSearchHistory failed: %{public}s', JSON.stringify(error));
    }
  }

  static async loadSearchHistory(): Promise<string> {
    if (SessionStore.pref === null) {
      return '';
    }
    try {
      return await SessionStore.readDecrypted(KEY_SEARCH_HISTORY);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'loadSearchHistory failed: %{public}s', JSON.stringify(error));
      return '';
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

  // ---------------- 加密落盘的统一出入口 ----------------
  // 所有持久化读写都必须走这两个方法，禁止再直接 pref.put 明文。

  /** 读取原始存储值（可能是密文信封，也可能是历史明文） */
  private static async readStored(key: string): Promise<string> {
    const value: preferences.ValueType = await SessionStore.pref!.get(key, '');
    return typeof value === 'string' ? value : '';
  }

  /** 加密写入（SecureStore.encrypt 抛错则不落盘，宁可失败也不写明文） */
  private static async writeStored(key: string, plain: string): Promise<boolean> {
    const alreadyEncrypted: boolean = SecureStore.isEncrypted(plain);
    const stored: string = alreadyEncrypted ? plain : SecureStore.encrypt(plain);
    if (!alreadyEncrypted && !SecureStore.isEncrypted(stored)) {
      hilog.error(DOMAIN, TAG, 'writeStored aborted: encryption unavailable for %{public}s', key);
      return false;
    }
    await SessionStore.pref!.put(key, stored);
    await SessionStore.pref!.flush();
    return true;
  }

  /**
   * 读取并解密；兼容历史明文（就地迁移成密文）。
   *
   * 若某个值"是密文但解不开"（主密钥被清除过、数据被篡改/截断），
   * 该值永远恢复不了，这里会顺手删掉，避免设备上长期残留按旧密钥加密的死数据。
   */
  private static async readDecrypted(key: string): Promise<string> {
    const stored: string = await SessionStore.readStored(key);
    if (stored.length === 0) {
      return '';
    }
    const plain: string = SecureStore.decrypt(stored);
    if (SecureStore.isEncrypted(stored) && plain.length === 0) {
      hilog.error(DOMAIN, TAG, 'dropping undecryptable value for %{public}s', key);
      await SessionStore.pref!.delete(key);
      await SessionStore.pref!.flush();
      return '';
    }
    if (!SecureStore.isEncrypted(stored)) {
      // 历史明文：就地迁移为密文（值不变，仅换存储形态）
      await SessionStore.writeStored(key, plain);
    }
    return plain;
  }
}
