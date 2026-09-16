import display from '@ohos.display';

/**
 * Responsive layout helpers aligned with Flutter media_collection breakpoints.
 */
export class WindowLayout {
  static screenWidth(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const widthPx: number = info.width;
      const density: number = info.densityPixels > 0 ? info.densityPixels : 1;
      return Math.floor(widthPx / density);
    } catch (_e) {
      return 360;
    }
  }

  static gridColumns(width: number = WindowLayout.screenWidth()): number {
    if (width >= 700) {
      return 6;
    }
    if (width >= 500) {
      return 5;
    }
    if (width >= 400) {
      return 4;
    }
    if (width >= 300) {
      return 3;
    }
    return 2;
  }

  static cardWidth(columns: number, width: number = WindowLayout.screenWidth()): number {
    const horizontalPad: number = 32;
    const gap: number = 12;
    const usable: number = width - horizontalPad - (columns - 1) * gap;
    return Math.max(90, Math.floor(usable / columns));
  }
}
