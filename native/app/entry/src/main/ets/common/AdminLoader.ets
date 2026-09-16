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
    // Prefer known flat keys; avoid Object.keys for ArkTS compatibility.
    const known: string[] = [
      'ServerName', 'Version', 'Id', 'OperatingSystem', 'ProductName', 'LocalAddress',
      'StartupWizardCompleted', 'HasPendingRestart', 'CanSelfRestart', 'WebSocketPortNumber',
      'CompletedInstallations', 'CanLaunchWebBrowser', 'ProgramDataPath', 'CachePath',
      'LogPath', 'InternalMetadataPath', 'TranscodingTempPath', 'EncoderLocation',
      'Name', 'AppName', 'DeviceName', 'UserName', 'Client', 'ApplicationVersion'
    ];
    for (let i = 0; i < known.length; i++) {
      const key: string = known[i];
      const full: string = prefix.length > 0 ? `${prefix}.${key}` : key;
      const map: Record<string, Object> = data as Record<string, Object>;
      const value: Object | undefined = map[key];
      if (value === undefined) {
        continue;
      }
      if (value === null) {
        rows.push(new KeyValueRow(full, 'null'));
      } else if (typeof value === 'object') {
        rows.push(new KeyValueRow(full, JsonUtil.toPretty(value as ESObject)));
      } else {
        rows.push(new KeyValueRow(full, `${value}`));
      }
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
