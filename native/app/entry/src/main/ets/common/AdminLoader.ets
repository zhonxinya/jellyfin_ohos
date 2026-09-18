import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from './JsonUtil';
import { UiState } from './UiState';
import { KeyValueRow } from '../components/AdminListViews';

export interface AdminLoadOutcome {
  status: string;
  errorMsg: string;
  lines: string[];
  rows: KeyValueRow[];
  detail: string;
}

/**
 * Shared load helpers for admin list / generic GET pages.
 */
export class AdminLoader {
  static async loadList(fetcher: () => Promise<string>): Promise<AdminLoadOutcome> {
    const raw: string = await fetcher();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      return {
        status: UiState.ERROR,
        errorMsg: result.message.length > 0 ? result.message : '加载失败',
        lines: [],
        rows: [],
        detail: ''
      };
    }
    const items: Object[] = JsonUtil.extractItems(result.data);
    if (items.length > 0) {
      const lines: string[] = [];
      for (let i = 0; i < items.length; i++) {
        lines.push(AdminLoader.formatItem(items[i]));
      }
      return {
        status: lines.length === 0 ? UiState.EMPTY : UiState.SUCCESS,
        errorMsg: '',
        lines: lines,
        rows: [],
        detail: ''
      };
    }
    if (result.data !== null) {
      const rows: KeyValueRow[] = AdminLoader.flattenObject(result.data, '');
      if (rows.length > 0) {
        return {
          status: UiState.SUCCESS,
          errorMsg: '',
          lines: [],
          rows: rows,
          detail: ''
        };
      }
      const pretty: string = JsonUtil.toPretty(result.data);
      if (pretty.length > 0 && pretty !== '{}' && pretty !== '[]') {
        return {
          status: UiState.SUCCESS,
          errorMsg: '',
          lines: [pretty],
          rows: [],
          detail: pretty
        };
      }
    }
    return {
      status: UiState.EMPTY,
      errorMsg: '',
      lines: [],
      rows: [],
      detail: ''
    };
  }

  static flattenObject(data: ESObject | null, prefix: string): KeyValueRow[] {
    const rows: KeyValueRow[] = [];
    if (data === null) {
      return rows;
    }
    // 先按"常见字段优先"的顺序列出，再把剩下的键按字典序补齐 ——
    // 以前只显示这张硬编码名单里的键，名单外的内容（例如 `/System/Configuration/metadata`
    // 的 `UseFileCreationTimeForDateAdded`）会退化成"一整块 JSON"，排障时看不到字段名。
    const known: string[] = [
      'ServerName', 'Version', 'Id', 'OperatingSystem', 'OperatingSystemDisplayName',
      'ProductName', 'SystemArchitecture', 'LocalAddress',
      'StartupWizardCompleted', 'HasPendingRestart', 'IsShuttingDown', 'CanSelfRestart',
      'HasUpdateAvailable', 'SupportsLibraryMonitor', 'CanLaunchWebBrowser',
      'WebSocketPortNumber', 'CompletedInstallations', 'ProgramDataPath', 'CachePath',
      'LogPath', 'InternalMetadataPath', 'MetadataPath', 'TranscodingTempPath',
      'EncoderLocation', 'WebPath', 'ItemsByNamePath',
      'Name', 'AppName', 'DeviceName', 'UserName', 'Client', 'ApplicationVersion',
      'DuplicateUsers', 'PathSubstitutions', 'Type', 'Severity', 'Date'
    ];
    const map: Record<string, Object> = data as Record<string, Object>;
    const seen: string[] = [];
    const push = (key: string): void => {
      const value: Object | undefined = map[key];
      if (value === undefined || seen.indexOf(key) >= 0) {
        return;
      }
      seen.push(key);
      const full: string = prefix.length > 0 ? `${prefix}.${key}` : key;
      rows.push(new KeyValueRow(full, JsonUtil.valueText(data, key)));
    };
    for (let i = 0; i < known.length; i++) {
      push(known[i]);
    }
    const all: string[] = JsonUtil.keysOf(data);
    for (let i = 0; i < all.length; i++) {
      push(all[i]);
    }
    if (rows.length === 0) {
      const pretty: string = JsonUtil.toPretty(data);
      if (pretty.length > 0) {
        rows.push(new KeyValueRow(prefix.length > 0 ? prefix : 'data', pretty));
      }
    }
    return rows;
  }

  static formatItem(item: Object): string {
    const obj: ESObject = item as ESObject;
    const name: string = JsonUtil.itemName(item);
    const id: string = JsonUtil.itemId(item);
    const extra: string = JsonUtil.getString(obj, 'LastActivityDate',
      JsonUtil.getString(obj, 'AppName',
        JsonUtil.getString(obj, 'State',
          JsonUtil.getString(obj, 'UserName',
            JsonUtil.getString(obj, 'Version', '')))));
    if (extra.length > 0) {
      return `${name} · ${extra}`;
    }
    if (id.length > 0 && id !== name) {
      return `${name} (${id})`;
    }
    return name;
  }
}
