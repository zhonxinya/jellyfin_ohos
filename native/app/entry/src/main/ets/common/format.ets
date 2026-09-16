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
