import { JsonUtil } from '../common/JsonUtil';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { SessionStore } from './SessionStore';

/**
 * Normalize persisted session blobs and validate auth fields.
 */
export class SessionUtil {
  static normalizeStoredSession(raw: string): string {
    if (raw.length === 0) {
      return '';
    }
    const root: ESObject | null = JsonUtil.parseObject(raw);
    if (root === null) {
      return raw;
    }
    if (SessionUtil.isAuthenticatedPayload(root)) {
      return raw;
    }
    const data: ESObject | null = JsonUtil.getObject(root, 'data');
    if (data !== null && SessionUtil.isAuthenticatedPayload(data)) {
      return JSON.stringify(data);
    }
    return raw;
  }

  /**
   * 把会话 JSON 里的 deviceId 覆盖为持久化的稳定值。
   * C++ `restoreSession` 会优先采用 JSON 中的 deviceId（见 core/session.cpp），
   * 因此这里覆盖后重新 restore 即可让服务端看到稳定的设备标识。
   */
  static stabilizeDeviceId(sessionJson: string, deviceId: string): string {
    if (sessionJson.length === 0 || deviceId.length === 0) {
      return sessionJson;
    }
    const root: ESObject | null = JsonUtil.parseObject(sessionJson);
    if (root === null) {
      return sessionJson;
    }
    const current: string = JsonUtil.getString(root, 'deviceId', '');
    if (current === deviceId) {
      return sessionJson;
    }
    root['deviceId'] = deviceId;
    return JSON.stringify(root);
  }

  static isAuthenticatedPayload(data: ESObject | null): boolean {
    if (data === null) {
      return false;
    }
    const token: string = JsonUtil.getString(data, 'accessToken', '');
    const userId: string = JsonUtil.getString(data, 'userId', '');
    return token.length > 0 && userId.length > 0;
  }

  static exportSessionJson(): string {
    const sessionRaw: string = JellyfinNative.getSession();
    const session: NativeResult = JellyfinNative.parseResult(sessionRaw);
    if (!session.ok || session.data === null) {
      return '';
    }
    if (!SessionUtil.isAuthenticatedPayload(session.data)) {
      return '';
    }
    return JSON.stringify(session.data);
  }

  /** 返回上次登录用户名，供登录页预填 */
  static getLastUsername(): string {
    return SessionStore.getLastUsernameStorage();
  }
}
