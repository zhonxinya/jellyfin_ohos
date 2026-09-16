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
