/**
 * 时间与时长格式化工具（对齐 Flutter core/format.dart）
 */

/** 将 ticks（100ns 单位）格式化为 h:mm:ss 或 mm:ss */
export function formatTicks(ticks: number): string {
  if (ticks <= 0) return '--:--'
  const seconds = Math.floor(ticks / 10000000)
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  const secs = seconds % 60
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`
  }
  return `${minutes}:${String(secs).padStart(2, '0')}`
}

/** 将秒数格式化为 h:mm:ss 或 mm:ss */
export function formatSeconds(seconds: number): string {
  if (seconds < 0) seconds = 0
  const hours = Math.floor(seconds / 3600)
  const minutes = Math.floor((seconds % 3600) / 60)
  const secs = seconds % 60
  if (hours > 0) {
    return `${hours}:${String(minutes).padStart(2, '0')}:${String(secs).padStart(2, '0')}`
  }
  return `${minutes}:${String(secs).padStart(2, '0')}`
}

/** 将 ticks 转换为秒 */
export function ticksToSeconds(ticks: number): number {
  return Math.floor(ticks / 10000000)
}

/** 将秒转换为 ticks */
export function secondsToTicks(seconds: number): number {
  return seconds * 10000000
}

/**
 * 把带 HTML 的文本转成可读纯文本（Jellyfin 的 `Overview` 常常含标签）。
 *
 * 为什么需要：服务端的简介常带 `<a href="...">文字</a><br/>` 这类片段（实测某条
 * B 站视频的简介就是 `<a href="https://www.bilibili.com/video/BV...">BV...</a><br/><br/>-`），
 * 直接渲染会把标签原样显示出来。这里做最小必要的处理：
 *  - `<br>` / `</p>` / `</div>` 等块级标签换成空格（否则前后词会粘在一起）；
 *  - 其余标签直接删掉；
 *  - 常见实体（`&amp;` `&lt;` `&gt;` `&quot;` `&#39;` `&nbsp;`）还原；
 *  - 连续空白（含换行）收敛成一个空格。
 *
 * 纯函数、无依赖：放在 `format.ets` 里与其它文本格式化工具同处，
 * 页面（短视频信息区、详情页等）直接复用，不各写一份正则。
 */
export function stripMarkup(text: string): string {
  if (text.length === 0) {
    return ''
  }
  let out: string = text
  // 块级/换行标签先变成空格，避免"上一句最后两个字"和"下一句开头"粘成一个词
  out = out.replace(/<(br|BR)\s*\/?>/g, ' ')
  out = out.replace(/<\/(p|div|li|tr|h[1-6])>/gi, ' ')
  // 其余标签整体删除
  out = out.replace(/<[^>]*>/g, '')
  // 常见实体还原
  out = out.replace(/&nbsp;/gi, ' ')
  out = out.replace(/&lt;/gi, '<')
  out = out.replace(/&gt;/gi, '>')
  out = out.replace(/&quot;/gi, '"')
  out = out.replace(/&#0?39;/g, "'")
  out = out.replace(/&apos;/gi, "'")
  out = out.replace(/&amp;/gi, '&')
  // 连续空白收敛（简介里常有大量缩进与空行）
  out = out.replace(/\s+/g, ' ')
  return out.trim()
}
