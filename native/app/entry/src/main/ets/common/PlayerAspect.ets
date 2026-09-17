/**
 * 播放页「画面比例」纯计算模块。
 *
 * 为什么单独抽出来：
 * 1. 这是播放器最容易做错、也最容易被忽略的一处体验 —— 系统 `AVPlayer` 的
 *    `videoScaleType` 默认值是 `VIDEO_SCALE_TYPE_FIT`，按官方文档它的语义是
 *    **拉伸铺满**（"the aspect of the content is not maintained"），
 *    即 16:9 的片子铺到 20:9 的手机屏幕上会被横向拉长。主流播放器（含 Infuse）
 *    默认都是等比「适应」，所以必须显式指定，不能依赖默认值。
 * 2. 比例计算是纯函数（输入视频尺寸、可用区域、屏幕密度，输出画面盒子的 vp 尺寸），
 *    与 ArkUI 无关，便于逐分支推演与后续补单测。
 *
 * 术语对齐主流播放器（Infuse/iina/VLC）的「缩放/比例」菜单：
 * - `contain`  适应：等比缩放，整幅画面可见，多余区域留黑边（默认）
 * - `cover`    填充：等比放大到铺满屏幕，超出部分裁掉（不变形）
 * - `stretch`  拉伸：非等比铺满屏幕（消除黑边，但会变形）
 * - `original` 原始：1 个视频像素对应 1 个屏幕像素（1:1），超出屏幕时退回「适应」
 */
export type PlayerAspectMode = 'contain' | 'cover' | 'stretch' | 'original';

/** 画面盒子的布局结果 */
export interface AspectBox {
  /** 视频面宽度（vp） */
  width: number;
  /** 视频面高度（vp） */
  height: number;
  /**
   * 传给 `AVPlayer.videoScaleType` 的取值：
   * 0 = `VIDEO_SCALE_TYPE_FIT`（拉伸铺满）、1 = `VIDEO_SCALE_TYPE_FIT_CROP`（等比裁剪铺满）。
   *
   * 为什么把「等比」交给视频面的尺寸而不是只靠 scaleType：
   * 把 XComponent 的尺寸算成与视频相同的宽高比之后，FIT 的「拉伸」就没有可拉伸的余地
   * （surface 与画面同比例），于是硬解路径与软解 EGL 路径的表现完全一致，
   * 也不依赖 API 20 才有的 `VIDEO_SCALE_TYPE_SCALED_ASPECT`（本工程 compatibleSdkVersion 为 18）。
   */
  scaleType: number;
}

/** `media.VideoScaleType.VIDEO_SCALE_TYPE_FIT`：拉伸铺满（系统默认，会变形） */
export const kScaleTypeFit: number = 0;
/** `media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP`：等比铺满并裁剪 */
export const kScaleTypeFitCrop: number = 1;

/** 比例模式顺序（点击「比例」按钮按此循环） */
export const kAspectModes: PlayerAspectMode[] = ['contain', 'cover', 'stretch', 'original'];

export class PlayerAspect {
  /** 模式的中文名（按钮与提示文案） */
  static label(mode: PlayerAspectMode): string {
    if (mode === 'cover') {
      return '填充';
    }
    if (mode === 'stretch') {
      return '拉伸';
    }
    if (mode === 'original') {
      return '原始';
    }
    return '适应';
  }

  /** 下一个模式（循环） */
  static next(mode: PlayerAspectMode): PlayerAspectMode {
    const idx: number = kAspectModes.indexOf(mode);
    const nextIdx: number = idx < 0 ? 0 : (idx + 1) % kAspectModes.length;
    return kAspectModes[nextIdx];
  }

  /**
   * 计算视频面盒子。
   *
   * @param mode    比例模式
   * @param videoW  视频宽（像素，来自 AVPlayer.width 或软解会话的 width）
   * @param videoH  视频高（像素）
   * @param areaW   可用区域宽（vp，通常是整屏宽）
   * @param areaH   可用区域高（vp，通常是整屏高）
   * @param density 屏幕像素密度（px / vp），用于「原始」模式的 1:1 换算
   */
  static box(mode: PlayerAspectMode, videoW: number, videoH: number,
             areaW: number, areaH: number, density: number): AspectBox {
    const safeAreaW: number = areaW > 0 ? areaW : 360;
    const safeAreaH: number = areaH > 0 ? areaH : 640;
    const hasVideo: boolean = videoW > 0 && videoH > 0;

    if (mode === 'cover') {
      // 等比铺满 + 裁剪：交给 AVPlayer；软解路径由 EglRenderer 的 cover 模式做同样的裁剪
      return { width: safeAreaW, height: safeAreaH, scaleType: kScaleTypeFitCrop };
    }
    if (mode === 'stretch') {
      return { width: safeAreaW, height: safeAreaH, scaleType: kScaleTypeFit };
    }
    if (!hasVideo) {
      // 视频尺寸未知（尚未 prepared）：先铺满，拿到尺寸后本函数会被重新调用
      return { width: safeAreaW, height: safeAreaH, scaleType: kScaleTypeFit };
    }

    const videoAspect: number = videoW / videoH;
    if (mode === 'original') {
      const d: number = density > 0 ? density : 1;
      let w: number = videoW / d;
      let h: number = videoH / d;
      if (w > safeAreaW || h > safeAreaH) {
        // 1:1 已经超出屏幕：退回「适应」，保证画面完整可见（否则用户会以为播放坏了）
        const fit: number[] = PlayerAspect.fitInside(videoAspect, safeAreaW, safeAreaH);
        return { width: fit[0], height: fit[1], scaleType: kScaleTypeFit };
      }
      return { width: Math.round(w), height: Math.round(h), scaleType: kScaleTypeFit };
    }

    // contain：等比缩放到可用区域之内
    const fit: number[] = PlayerAspect.fitInside(videoAspect, safeAreaW, safeAreaH);
    return { width: fit[0], height: fit[1], scaleType: kScaleTypeFit };
  }

  /** 在 areaW × areaH 内按 aspect 等比缩放，返回 [宽, 高]（vp，整数） */
  private static fitInside(aspect: number, areaW: number, areaH: number): number[] {
    if (aspect <= 0) {
      return [Math.round(areaW), Math.round(areaH)];
    }
    const areaAspect: number = areaW / areaH;
    let w: number = areaW;
    let h: number = areaH;
    if (aspect > areaAspect) {
      // 画面比区域更"宽" → 宽度顶满，高度按比例缩
      h = areaW / aspect;
    } else {
      w = areaH * aspect;
    }
    return [Math.max(1, Math.round(w)), Math.max(1, Math.round(h))];
  }

  /**
   * 把视频像素尺寸说成人话：`1920×1080 · 16:9`。
   *
   * 为什么值得做：用户点「比例」时最需要知道的就是"这片子本身是什么比例"，
   * 主流播放器都会在缩放菜单里标注（Infuse 显示 16:9 / 2.39:1 之类）。
   */
  static describe(videoW: number, videoH: number): string {
    if (videoW <= 0 || videoH <= 0) {
      return '';
    }
    const ratio: string = PlayerAspect.ratioLabel(videoW, videoH);
    const size: string = `${Math.round(videoW)}×${Math.round(videoH)}`;
    return ratio.length > 0 ? `${size} · ${ratio}` : size;
  }

  /**
   * 常见画幅比的中文标签。
   *
   * 只识别业界常见画幅（电影 2.39:1 / 2.35:1、宽银幕 21:9、16:9、16:10、4:3、3:2、1:1、竖屏 9:16），
   * 其余返回空串而不是硬凑一个"接近值"—— 宁可不说，也不要说错。
   */
  static ratioLabel(videoW: number, videoH: number): string {
    if (videoW <= 0 || videoH <= 0) {
      return '';
    }
    const ar: number = videoW / videoH;
    const table: string[][] = [
      ['2.39:1', '2.39'],
      ['2.35:1', '2.35'],
      ['21:9', '2.33'],
      ['2:1', '2'],
      ['16:9', '1.778'],
      ['16:10', '1.6'],
      ['3:2', '1.5'],
      ['4:3', '1.333'],
      ['1:1', '1'],
      ['3:4', '0.75'],
      ['9:16', '0.5625']
    ];
    for (let i: number = 0; i < table.length; i++) {
      const target: number = Number.parseFloat(table[i][1]);
      // 容差 1.5%：真实片源的画幅常有极小偏差（如 1918×800 ≈ 2.3975）
      if (Math.abs(ar - target) / target < 0.015) {
        return table[i][0];
      }
    }
    return '';
  }
}
