import util from '@ohos.util';

/**
 * 服务端文本乱码（mojibake）的**尽力修复**。
 *
 * ## 场景（为什么音乐库最容易遇到）
 *
 * 中文音乐库里的老文件常带 **GBK 编码的 ID3 标签**。这些标签如果声明成 ISO-8859-1，
 * 服务端的标签读取链会把 GBK 字节按 Latin-1 解释，于是「测试」变成「²âÊÔ」——
 * 一串**合法**字符，整条链路（服务端 JSON、本工程 C++ 解析、NAPI、ArkTS）都不会报错，
 * 只是显示出来是乱码。同名场景还有 UTF-8 字节被按 Latin-1 读出来的「æµ‹è¯•」。
 *
 * ## 为什么放在 ArkTS 而不是 C++ core
 *
 * 解码要靠 GBK 码表。C++ core 没有码表也没有链接 ICU，而系统的 `util.TextDecoder`
 * 就是 ICU —— 用它既符合「优先参考官方已实现的模块」，又不必往工程里塞一张几十 KB 的表。
 *
 * 而且修复只该作用于**展示**：core 层拿到的名字会被原样回写给服务端（条目元数据是整体替换），
 * 在那里改字会变成一次用户没要求的写入。放在 UI 模型层（`MediaItem.fromJson`）天然只影响显示。
 *
 * ## 判据保守到"宁可漏修，不能改坏"
 *
 * 只有同时满足下面几条才尝试修复（`looksLikeMojibake`）：
 *  1. 每个码位都 ≤ `0xFF` —— 正常 UTF-8 文本（含中文，码位 > `0xFF`）**第一个字符就会被排除**；
 *  2. 不含 ASCII 字母数字 —— 「Björk」「Ölçü」这类正常拉丁文名字因此不会被误改；
 *  3. 至少 2 个码位落在 `0x80..0xFF` —— 单个高位字符（「Café」）不算。
 *
 * 再要求**解码结果里必须出现 CJK**（`hasCjk`）才采纳：修不出中文就原样返回。
 * 于是德语/法语/土耳其语等名字即使过了前面的判据，也不会被改成汉字。
 *
 * 解码器取不到（设备 ICU 数据里没有 `gbk`）时静默退化：不修复、不报错，名字照旧显示。
 *
 * ## 已知边界
 *
 * - 服务端**已经**把非法字节替换成 U+FFFD 的（`�`）修不回来 —— 信息在服务端就丢了；
 * - 只认 ISO-8859-1 形态的乱码。CP1252 形态（`0x80..0x9F` 段被映射成 `€ ™ ‹` 等
 *   `> 0xFF` 的字符）过不了第 1 条判据，会原样保留。
 */
export class TextRepair {
  private static utf8Decoder: util.TextDecoder | null = null;
  private static gbkDecoder: util.TextDecoder | null = null;
  /** 本设备 ICU 里没有 `gbk` 时置位：避免每次调用都重建一次并抛一次异常 */
  private static gbkUnavailable: boolean = false;

  /**
   * 修复一个可能乱码的文本；判定不了、修不出来时**原样返回**（永不抛、永不返回空）。
   */
  static repair(text: string): string {
    if (text.length < 2 || !TextRepair.looksLikeMojibake(text)) {
      return text;
    }
    const bytes: Uint8Array = TextRepair.toLatin1Bytes(text);
    // 先 UTF-8 后 GBK：「æµ‹è¯•」是 UTF-8 字节被当 Latin-1 读出来的，
    // 「²âÊÔ」是 GBK 字节被当 Latin-1 读出来的 —— 后者在中文音乐库里最常见。
    const viaUtf8: string = TextRepair.decode(TextRepair.utf8DecoderOrNull(), bytes);
    if (viaUtf8.length > 0 && TextRepair.hasCjk(viaUtf8)) {
      return viaUtf8;
    }
    const viaGbk: string = TextRepair.decode(TextRepair.gbkDecoderOrNull(), bytes);
    if (viaGbk.length > 0 && TextRepair.hasCjk(viaGbk)) {
      return viaGbk;
    }
    return text;
  }

  /** 判据见类头。要求"整串都是高位 Latin-1 字符且不含 ASCII 字母数字" */
  private static looksLikeMojibake(text: string): boolean {
    let high: number = 0;
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if (code > 0xFF) {
        return false;
      }
      if ((code >= 0x30 && code <= 0x39) || (code >= 0x41 && code <= 0x5A) ||
        (code >= 0x61 && code <= 0x7A)) {
        return false;
      }
      if (code >= 0x80) {
        high++;
      }
    }
    return high >= 2;
  }

  /** 乱码串里的每个码位其实就是原始字节（Latin-1 是"字节 = 码位"的单字节编码） */
  private static toLatin1Bytes(text: string): Uint8Array {
    const bytes: Uint8Array = new Uint8Array(text.length);
    for (let i = 0; i < text.length; i++) {
      bytes[i] = text.charCodeAt(i) & 0xFF;
    }
    return bytes;
  }

  private static hasCjk(text: string): boolean {
    for (let i = 0; i < text.length; i++) {
      const code: number = text.charCodeAt(i);
      if ((code >= 0x3400 && code <= 0x9FFF) || (code >= 0xF900 && code <= 0xFAFF)) {
        return true;
      }
    }
    return false;
  }

  /**
   * `fatal: true` 是关键：非法序列要抛出来，这样"这串字节不属于这个编码"才能和
   * "解出了别的东西"区分开 —— 判据正是靠它实现的。
   */
  private static utf8DecoderOrNull(): util.TextDecoder | null {
    if (TextRepair.utf8Decoder === null) {
      try {
        TextRepair.utf8Decoder = util.TextDecoder.create('utf-8', { fatal: true });
      } catch (err) {
        return null;
      }
    }
    return TextRepair.utf8Decoder;
  }

  private static gbkDecoderOrNull(): util.TextDecoder | null {
    if (TextRepair.gbkDecoder !== null) {
      return TextRepair.gbkDecoder;
    }
    if (TextRepair.gbkUnavailable) {
      return null;
    }
    try {
      TextRepair.gbkDecoder = util.TextDecoder.create('gbk', { fatal: true });
    } catch (err) {
      // 设备 ICU 数据里没有 gbk：退化到"不修复"，不阻断任何显示
      TextRepair.gbkUnavailable = true;
      return null;
    }
    return TextRepair.gbkDecoder;
  }

  private static decode(decoder: util.TextDecoder | null, bytes: Uint8Array): string {
    if (decoder === null) {
      return '';
    }
    try {
      return decoder.decode(bytes);
    } catch (err) {
      return '';
    }
  }
}
