/**
 * Safe JSON helpers for ArkTS (no `any`).
 */
export class JsonUtil {
  static parseObject(text: string): ESObject | null {
    if (text === undefined || text === null || text.length === 0) {
      return null;
    }
    try {
      const parsed: Object = JSON.parse(text);
      if (parsed === null) {
        return null;
      }
      if (typeof parsed === 'object') {
        return parsed as ESObject;
      }
      return null;
    } catch (_e) {
      return null;
    }
  }

  static getString(obj: ESObject | null, key: string, fallback: string = ''): string {
    if (obj === null || obj === undefined) {
      return fallback;
    }
    const map: Record<string, Object> = obj as Record<string, Object>;
    const value: Object | undefined = map[key];
    if (typeof value === 'string') {
      return value;
    }
    if (typeof value === 'number' || typeof value === 'boolean') {
      return `${value}`;
    }
    return fallback;
  }

  static getNumber(obj: ESObject | null, key: string, fallback: number = 0): number {
    if (obj === null || obj === undefined) {
      return fallback;
    }
    const map: Record<string, Object> = obj as Record<string, Object>;
    const value: Object | undefined = map[key];
    if (typeof value === 'number' && !Number.isNaN(value)) {
      return value;
    }
    if (typeof value === 'string') {
      const n: number = Number(value);
      if (!Number.isNaN(n)) {
        return n;
      }
    }
    return fallback;
  }

  static getBoolean(obj: ESObject | null, key: string, fallback: boolean = false): boolean {
    if (obj === null || obj === undefined) {
      return fallback;
    }
    const map: Record<string, Object> = obj as Record<string, Object>;
    const value: Object | undefined = map[key];
    if (typeof value === 'boolean') {
      return value;
    }
    if (typeof value === 'string') {
      return value === 'true' || value === '1';
    }
    if (typeof value === 'number') {
      return value !== 0;
    }
    return fallback;
  }

  static getObject(obj: ESObject | null, key: string): ESObject | null {
    if (obj === null || obj === undefined) {
      return null;
    }
    const map: Record<string, Object> = obj as Record<string, Object>;
    const value: Object | undefined = map[key];
    if (value !== null && value !== undefined && typeof value === 'object') {
      return value as ESObject;
    }
    return null;
  }

  static getArray(obj: ESObject | null, key: string): Object[] {
    if (obj === null || obj === undefined) {
      return [];
    }
    const map: Record<string, Object> = obj as Record<string, Object>;
    const value: Object | undefined = map[key];
    if (Array.isArray(value)) {
      const out: Object[] = [];
      for (let i = 0; i < value.length; i++) {
        out.push(value[i] as Object);
      }
      return out;
    }
    return [];
  }

  static itemName(item: Object): string {
    const obj: ESObject = item as ESObject;
    const name: string = JsonUtil.getString(obj, 'Name', '');
    if (name.length > 0) {
      return name;
    }
    return JsonUtil.getString(obj, 'name', JsonUtil.getString(obj, 'Id', '未命名'));
  }

  static itemId(item: Object): string {
    const obj: ESObject = item as ESObject;
    const id: string = JsonUtil.getString(obj, 'Id', '');
    if (id.length > 0) {
      return id;
    }
    return JsonUtil.getString(obj, 'id', '');
  }

  static toPretty(obj: ESObject | null): string {
    if (obj === null || obj === undefined) {
      return '';
    }
    try {
      return JSON.stringify(obj);
    } catch (_e) {
      return '';
    }
  }

  static extractItems(data: ESObject | null): Object[] {
    if (data === null) {
      return [];
    }
    const items: Object[] = JsonUtil.getArray(data, 'Items');
    if (items.length > 0) {
      return items;
    }
    const itemsLower: Object[] = JsonUtil.getArray(data, 'items');
    if (itemsLower.length > 0) {
      return itemsLower;
    }
    if (Array.isArray(data)) {
      const out: Object[] = [];
      const arr: Object[] = data as Object[];
      for (let i = 0; i < arr.length; i++) {
        out.push(arr[i]);
      }
      return out;
    }
    return [];
  }
}
