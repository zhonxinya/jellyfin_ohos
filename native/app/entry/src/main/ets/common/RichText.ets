/**
 * 极简"强调文本"渲染。
 *
 * 起因：隐私政策 / 用户协议 / 短视频模式说明里用了 markdown 的 `**加粗**` 写法，
 * 而 ArkUI 的 `Text` 不认 markdown —— 不处理的话界面上会**原样显示星号**
 * （应用市场审核看隐私政策时会直接看到 `**非官方第三方客户端**` 这种字面量）。
 *
 * 这里把一行文本拆成若干片段，由调用方用 `Flex({ wrap: FlexWrap.Wrap })` +
 * 每段一个 `Text` 渲染：加粗段用更重的字重与主文字色，其余用次要色。
 * 没有用 `Text() { Span(...) }`：本工程目前没有任何 Span 用法，
 * 而这种写法在这套 ArkTS 工具链上没有先例，风险更高；Flex 换行同样能保持段落排版。
 */
export class TextSegment {
  text: string = '';
  bold: boolean = false;

  constructor(text: string, bold: boolean) {
    this.text = text;
    this.bold = bold;
  }
}

/** 把 `**加粗**` 拆成片段；未闭合的 `**` 按普通文本处理（不吞字） */
export function parseBoldSegments(line: string): TextSegment[] {
  const out: TextSegment[] = [];
  let rest: string = line;
  while (rest.length > 0) {
    const start: number = rest.indexOf('**');
    if (start < 0) {
      out.push(new TextSegment(rest, false));
      break;
    }
    const end: number = rest.indexOf('**', start + 2);
    if (end < 0) {
      out.push(new TextSegment(rest, false));
      break;
    }
    if (start > 0) {
      out.push(new TextSegment(rest.substring(0, start), false));
    }
    out.push(new TextSegment(rest.substring(start + 2, end), true));
    rest = rest.substring(end + 2);
  }
  return out;
}

/** 按行拆（一行一个渲染单元，段落之间留一点空） */
export function splitLines(text: string): string[] {
  return text.split('\n');
}
