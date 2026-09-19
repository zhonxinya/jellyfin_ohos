/**
 * 服务端时间戳的显示格式（控制台各处共用）。
 *
 * 服务端给的都是 **UTC ISO**，而且小数位是 7 位（例如 `2026-09-18T23:23:02.2072103Z`），
 * 而 `Date.parse` 只认 3 位小数 —— 不处理的话在部分运行时上会得到 `NaN`。
 * 这里统一：先截到毫秒，再转成**设备本地时间**；解析失败就退回原字符串
 * （宁可不转，也不要显示一个错的时间）。
 */
export class TimeFormat {
  /** 把 ISO 截到毫秒并转成毫秒数；无法解析时返回 null */
  private static parse(iso: string): number | null {
    if (iso === undefined || iso === null || iso.length === 0) {
      return null;
    }
    let normalized: string = iso;
    const dot: number = iso.indexOf('.');
    if (dot > 0 && iso.endsWith('Z')) {
      normalized = `${iso.substring(0, dot)}.${iso.substring(dot + 1, dot + 4)}Z`;
    }
    const ms: number = Date.parse(normalized);
    return Number.isNaN(ms) ? null : ms;
  }

  private static pad(value: number): string {
    return value < 10 ? `0${value}` : `${value}`;
  }

  /** `MM-DD HH:mm`（列表里用） */
  static short(iso: string): string {
    const ms: number | null = TimeFormat.parse(iso);
    if (ms === null) {
      return iso;
    }
    const d: Date = new Date(ms);
    return `${TimeFormat.pad(d.getMonth() + 1)}-${TimeFormat.pad(d.getDate())} `
      + `${TimeFormat.pad(d.getHours())}:${TimeFormat.pad(d.getMinutes())}`;
  }

  /** `YYYY-MM-DD HH:mm` */
  static full(iso: string): string {
    const ms: number | null = TimeFormat.parse(iso);
    if (ms === null) {
      return iso;
    }
    const d: Date = new Date(ms);
    return `${d.getFullYear()}-${TimeFormat.pad(d.getMonth() + 1)}-${TimeFormat.pad(d.getDate())} `
      + `${TimeFormat.pad(d.getHours())}:${TimeFormat.pad(d.getMinutes())}`;
  }

  /** 两个时间戳之间的时长（秒级，用于"耗时"） */
  static durationSeconds(startIso: string, endIso: string): number {
    const start: number | null = TimeFormat.parse(startIso);
    const end: number | null = TimeFormat.parse(endIso);
    if (start === null || end === null || end < start) {
      return 0;
    }
    return Math.round((end - start) / 1000);
  }

  /** 秒 → `1 分 5 秒` / `12 秒` / `1 小时 2 分` */
  static durationLabel(seconds: number): string {
    if (seconds <= 0) {
      return '';
    }
    if (seconds < 60) {
      return `${seconds} 秒`;
    }
    if (seconds < 3600) {
      const minutes: number = Math.floor(seconds / 60);
      const rest: number = seconds % 60;
      return rest === 0 ? `${minutes} 分` : `${minutes} 分 ${rest} 秒`;
    }
    const hours: number = Math.floor(seconds / 3600);
    const minutes: number = Math.floor((seconds % 3600) / 60);
    return minutes === 0 ? `${hours} 小时` : `${hours} 小时 ${minutes} 分`;
  }
}
