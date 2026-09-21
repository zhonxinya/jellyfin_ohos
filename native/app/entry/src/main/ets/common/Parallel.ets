/**
 * 有界并发地跑一批"逐项异步请求"，并按**输入顺序**返回结果。
 *
 * 为什么需要：`ShortVideoPage` 的取数路径上有两类"逐项请求"——
 * 逐媒体库取条目、逐剧集问 NextUp。它们彼此毫无依赖，串行发就是让用户付 N 倍的
 * 往返时间（本工程 `HttpClient` 每次请求新建一条 TCP 连接，往返成本是实打实的）。
 * ArkTS 有 `Promise.all` 但**没有**内置的并发上限，全开又会让服务端与移动网络同时拥堵。
 *
 * 语义：
 * - 按 `items` 的顺序发起与返回（下标一一对应），结果顺序与输入一致；
 * - 并发数不超过 `limit`（至少 1）；
 * - **单项失败不影响其它项**：抛错的项其结果记为 `null`，由调用方决定怎么兜底
 *   （取数路径上一向是"某个库/某部剧取不到就跳过它"，不让整批失败）。
 *
 * @param items 待处理的输入项
 * @param limit 最大并发数
 * @param fn    对单项的处理（返回 Promise）
 */
export class Parallel {
  static async mapLimited<TIn, TOut>(
    items: TIn[],
    limit: number,
    fn: (item: TIn, index: number) => Promise<TOut | null>): Promise<(TOut | null)[]> {
    const results: (TOut | null)[] = new Array<TOut | null>(items.length);
    for (let i = 0; i < results.length; i++) {
      results[i] = null;
    }
    if (items.length === 0) {
      return results;
    }
    const width: number = Math.max(1, Math.min(Math.floor(limit), items.length));
    let next: number = 0;
    // 每个 worker 自己"领号"（`next` 只有一个派发点在 await 之后立即自增，
    // ArkTS 单线程事件循环下不会有两个 worker 领到同一个下标）
    const worker = async (): Promise<void> => {
      while (true) {
        const i: number = next;
        if (i >= items.length) {
          return;
        }
        next = i + 1;
        try {
          results[i] = await fn(items[i], i);
        } catch (err) {
          // 单项失败：记为 null，让调用方按"这一项取不到"处理（不中断其余项）
          results[i] = null;
        }
      }
    };
    const workers: Promise<void>[] = [];
    for (let i = 0; i < width; i++) {
      workers.push(worker());
    }
    await Promise.all(workers);
    return results;
  }
}
