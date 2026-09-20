/**
 * 字幕解析：WebVTT / SRT 文本 → 可按播放位置查询的时间轴。
 *
 * **为什么需要它（这是"字幕无法使用"的真正根因）**：
 * HarmonyOS 的 `AVPlayer.addSubtitleFromUrl()` 官方契约要求
 *   "the external subtitle must be set **after fdSrc** of the video resource is set"
 * （SDK `@ohos.multimedia.media.d.ts`，API 12 起即如此），
 * 而本工程的播放走 `avPlayer.url = <网络地址>`，不是 `fdSrc` ——
 * 于是该调用成了**静默空操作**：Promise 正常 resolve（上层误以为"已加载"），
 * 但播放器根本不去取字幕（服务端日志可证：客户端从未发出字幕请求），
 * 也不触发 `subtitleUpdate` 事件，画面上永远没有字幕。
 * `setMediaSource` 同样帮不上：`MediaSource` 只有 `setMimeType` /
 * `enableOfflineCache` / `setMediaResourceLoaderDelegate`，没有字幕字段。
 *
 * 因此字幕改由应用自己取文本 → 用本文件解析 → 按播放位置渲染。
 * 播放页本来就有 `subtitleText` 的自绘路径（原生 SURFACE 上画不了文本），正好复用。
 *
 * 格式：服务端会把文本字幕统一转成 **WebVTT**（见 `native/core/subtitle_url.cpp` 的
 * `SubtitleFormatForCodec`：ass/srt/ttml… 一律请求 `vtt`），所以这里以 VTT 为主，
 * 同时兼容 SRT（时间戳用逗号）与带 BOM 的文件。
 */

/** 纯数字判断（不依赖正则，避免 ArkTS 上 RegExp 的兼容差异） */
export function isAllDigits(text: string): boolean {
  if (text.length === 0) {
    return false;
  }
  for (let i = 0; i < text.length; i++) {
    const code: number = text.charCodeAt(i);
    if (code < 48 || code > 57) {
      return false;
    }
  }
  return true;
}

/** 一条字幕：起止时间（毫秒）与显示文本 */
export interface SubtitleCue {
  startMs: number;
  endMs: number;
  text: string;
}

/**
 * 把 `hh:mm:ss.mmm` / `mm:ss.mmm`（VTT）或 `hh:mm:ss,mmm`（SRT）解析成毫秒。
 * 解析不出来返回 -1（调用方据此丢弃该条时间轴，不当作 0 处理 —— 否则会显示在开头）。
 */
export function parseSubtitleTimestamp(raw: string): number {
  const s: string = raw.trim().replace(',', '.');
  if (s.length === 0) {
    return -1;
  }
  const parts: string[] = s.split(':');
  if (parts.length < 2 || parts.length > 3) {
    return -1;
  }
  const last: number = Number.parseFloat(parts[parts.length - 1]);
  const minutes: number = Number.parseInt(parts[parts.length - 2], 10);
  const hours: number = parts.length === 3 ? Number.parseInt(parts[0], 10) : 0;
  if (!Number.isFinite(last) || !Number.isFinite(minutes) || !Number.isFinite(hours)) {
    return -1;
  }
  return Math.round((hours * 3600 + minutes * 60 + last) * 1000);
}

/**
 * 去掉字幕文本里的样式/定位标记，只留可读内容。
 *
 * 需要处理的来源：
 * - ASS 经过服务端转 VTT 后，仍可能残留 `{\an8}` `{\pos(...)}` 这类**花括号指令**
 *   （本工程实测的影片字幕就带 `{\blur3\fad(500,500)\fn华文楷体}`）；
 * - VTT 内联标签 `<i>` `<b>` `<c.classname>` `<00:00:01.000>`；
 * - SRT 的 `{\an8}` 与 `\N` 换行。
 */
export function stripSubtitleMarkup(text: string): string {
  let out: string = text;
  // 花括号指令（ASS 覆写块），可能跨行嵌套，循环剥到干净为止
  while (out.indexOf('{') >= 0 && out.indexOf('}') > out.indexOf('{')) {
    const from: number = out.indexOf('{');
    const to: number = out.indexOf('}', from);
    out = out.slice(0, from) + out.slice(to + 1);
  }
  // VTT 内联标签（含 <c.foo> 与时间戳标签）
  while (out.indexOf('<') >= 0 && out.indexOf('>') > out.indexOf('<')) {
    const from: number = out.indexOf('<');
    const to: number = out.indexOf('>', from);
    out = out.slice(0, from) + out.slice(to + 1);
  }
  // SRT/ASS 的转义换行 → 真换行；`\h` 是 ASS 的硬空格
  out = out.split('\\N').join('\n').split('\\n').join('\n').split('\\h').join(' ');
  return out.trim();
}

/**
 * 解析 VTT / SRT 文本为时间轴（按 startMs 升序）。
 *
 * 容错取向：**坏行跳过，不整段失败**。字幕文件来自服务端转码，个别行残缺时
 * 让其余字幕照常显示，比"整条字幕用不了"好得多。
 */
export function parseSubtitleVtt(content: string): SubtitleCue[] {
  const cues: SubtitleCue[] = [];
  let body: string = content;
  // 去 UTF-8 BOM（服务端返回的 SRT 实测带 `\ufeff`）
  if (body.length > 0 && body.charCodeAt(0) === 0xFEFF) {
    body = body.slice(1);
  }
  const lines: string[] = body.split('\n');
  let i: number = 0;
  while (i < lines.length) {
    const line: string = lines[i].trim();
    // 时间轴行形如 `00:00:01.020 --> 00:00:05.880`（VTT 用 `.`，SRT 用 `,`）
    const arrowAt: number = line.indexOf('-->');
    if (arrowAt < 0) {
      i++;
      continue;
    }
    const startMs: number = parseSubtitleTimestamp(line.slice(0, arrowAt));
    // 右侧可能带 VTT 的定位参数（`align:start position:10%`），只取时间部分
    const right: string = line.slice(arrowAt + 3).trim().split(' ')[0];
    const endMs: number = parseSubtitleTimestamp(right);
    i++;
    // 收集文本行直到空行（或下一个时间轴行）
    const textLines: string[] = [];
    while (i < lines.length) {
      const t: string = lines[i].trim();
      if (t.length === 0 || t.indexOf('-->') >= 0) {
        break;
      }
      // VTT 的 cue 标识行 / SRT 的序号都是纯数字。**不引入正则**（本工程 ArkTS 侧统一用
      // 字符判断，见 DetailPage.isAllDigits —— 避免 RegExp 在不同 ArkTS 版本上的兼容差异）。
      if (!(textLines.length === 0 && isAllDigits(t))) {
        textLines.push(t);
      } else {
        // 纯数字且还无文本：可能是 SRT 序号，跳过；但也可能是真的字幕内容"1984"。
        // 按"下一行是时间轴才当序号"判断，避免误删数字字幕。
        const next: string = i + 1 < lines.length ? lines[i + 1].trim() : '';
        if (next.indexOf('-->') < 0) {
          textLines.push(t);
        }
      }
      i++;
    }
    if (startMs < 0 || endMs < 0 || endMs <= startMs) {
      continue;
    }
    const text: string = stripSubtitleMarkup(textLines.join('\n'));
    if (text.length > 0) {
      cues.push({ startMs: startMs, endMs: endMs, text: text });
    }
  }
  cues.sort((a: SubtitleCue, b: SubtitleCue) => a.startMs - b.startMs);
  return cues;
}

/**
 * 取某个播放位置应显示的字幕文本；没有则返回空串。
 *
 * 用**二分查找**而不是线性扫描：字幕动辄上千条，而本函数随播放进度每秒被调用，
 * 线性扫描在长片上是可感知的开销（也容易在多条重叠时取错）。
 */
export function subtitleTextAt(cues: SubtitleCue[], positionMs: number): string {
  if (cues.length === 0 || positionMs < 0) {
    return '';
  }
  let lo: number = 0;
  let hi: number = cues.length - 1;
  let idx: number = -1;
  while (lo <= hi) {
    const mid: number = (lo + hi) >> 1;
    if (cues[mid].startMs <= positionMs) {
      idx = mid;
      lo = mid + 1;
    } else {
      hi = mid - 1;
    }
  }
  // 从候选位置向前回看：相邻字幕可能重叠（卡拉OK、双行），取起点最晚且在区间内的那条
  for (let k: number = idx; k >= 0 && k > idx - 5; k--) {
    if (positionMs >= cues[k].startMs && positionMs < cues[k].endMs) {
      return cues[k].text;
    }
  }
  return '';
}
