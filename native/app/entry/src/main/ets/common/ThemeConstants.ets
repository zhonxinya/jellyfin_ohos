/**
 * Design tokens aligned with Flutter AppTheme (ocean/jade/amber/coral).
 */
export type ThemeMode = 'system' | 'light' | 'dark';
export type ThemeAccent = 'ocean' | 'jade' | 'amber' | 'coral';

export class ThemeColors {
  background: string = '#121212';
  surface: string = '#1E1E1E';
  surfaceElevated: string = '#2A2A2A';
  surfaceContainerHighest: string = '#2A2A2A';
  primary: string = '#00A4DC';
  onSurface: string = '#FFFFFF';
  onSurfaceVariant: string = '#AAAAAA';
  onOverlay: string = '#FFFFFF';
  onOverlayMuted: string = '#FFFFFFB3';
  error: string = '#FF6B6B';
  outline: string = '#666666';
  success: string = '#8BC34A';
  destructive: string = '#5A1A1A';
  onPrimary: string = '#FFFFFF';
  progressTrack: string = '#3A3A3A';
  scrim: string = '#00000088';
  scrimHeavy: string = '#000000CC';
  overlayControl: string = '#FFFFFF33';
  overlayControlStrong: string = '#00000066';
  posterScrim: string = '#00000061';
  posterGradientStart: string = '#0000009E';
}

export class ThemeConstants {
  static readonly ACCENT_OCEAN: string = '#00A4DC';
  static readonly ACCENT_JADE: string = '#00897B';
  static readonly ACCENT_AMBER: string = '#F59E0B';
  static readonly ACCENT_CORAL: string = '#E76F51';

  static readonly TITLE_LARGE: number = 24;
  static readonly TITLE_MEDIUM: number = 20;
  static readonly TITLE_SMALL: number = 14;
  static readonly BODY_MEDIUM: number = 14;
  static readonly LABEL_SMALL: number = 12;

  static readonly CARD_WIDTH: number = 120;
  static readonly LIBRARY_TILE_WIDTH: number = 120;
  static readonly LIBRARY_TILE_IMAGE_HEIGHT: number = 110;
  static readonly CARD_GAP: number = 12;
  static readonly GRID_MAIN_SPACING: number = 16;
  static readonly SHELF_MEDIA_HEIGHT: number = 240;
  static readonly SHELF_LIBRARY_HEIGHT: number = 150;
  static readonly POSTER_RADIUS: number = 12;
  static readonly LIST_THUMB_RADIUS: number = 8;
  static readonly PAGE_SIZE: number = 40;
  static readonly FORM_MAX_WIDTH: number = 420;
  static readonly SETTINGS_MAX_WIDTH: number = 720;
  static readonly DETAIL_POSTER_WIDTH: number = 130;
  static readonly DETAIL_POSTER_HEIGHT: number = 195;

  static accentSeed(accent: string): string {
    if (accent === 'jade') {
      return ThemeConstants.ACCENT_JADE;
    }
    if (accent === 'amber') {
      return ThemeConstants.ACCENT_AMBER;
    }
    if (accent === 'coral') {
      return ThemeConstants.ACCENT_CORAL;
    }
    return ThemeConstants.ACCENT_OCEAN;
  }

  static resolveDark(accent: string): ThemeColors {
    const c: ThemeColors = new ThemeColors();
    c.background = '#121212';
    c.surface = '#1E1E1E';
    c.surfaceElevated = '#2A2A2A';
    c.surfaceContainerHighest = '#2C2C2C';
    c.primary = ThemeConstants.accentSeed(accent);
    c.onSurface = '#FFFFFF';
    c.onSurfaceVariant = '#AAAAAA';
    c.onOverlay = '#FFFFFF';
    c.onOverlayMuted = '#FFFFFFB3';
    c.error = '#FF6B6B';
    c.outline = '#666666';
    c.success = '#8BC34A';
    c.destructive = '#5A1A1A';
    c.onPrimary = '#FFFFFF';
    c.progressTrack = '#3A3A3A';
    c.scrim = '#00000088';
    c.scrimHeavy = '#000000CC';
    c.overlayControl = '#FFFFFF33';
    c.overlayControlStrong = '#00000066';
    c.posterScrim = '#00000061';
    c.posterGradientStart = '#0000009E';
    return c;
  }

  static resolveLight(accent: string): ThemeColors {
    const c: ThemeColors = new ThemeColors();
    c.background = '#F5F7FA';
    c.surface = '#FFFFFF';
    c.surfaceElevated = '#E8ECF0';
    c.surfaceContainerHighest = '#E0E4EA';
    c.primary = ThemeConstants.accentSeed(accent);
    c.onSurface = '#1A1A1A';
    c.onSurfaceVariant = '#666666';
    c.onOverlay = '#FFFFFF';
    c.onOverlayMuted = '#FFFFFFB3';
    c.error = '#D32F2F';
    c.outline = '#B0B0B0';
    c.success = '#388E3C';
    c.destructive = '#C62828';
    c.onPrimary = '#FFFFFF';
    c.progressTrack = '#DDDDDD';
    c.scrim = '#00000066';
    c.scrimHeavy = '#00000099';
    c.overlayControl = '#FFFFFF4D';
    c.overlayControlStrong = '#00000040';
    c.posterScrim = '#00000040';
    c.posterGradientStart = '#00000080';
    return c;
  }

  static resolve(mode: string, accent: string, systemDark: boolean): ThemeColors {
    let dark: boolean = true;
    if (mode === 'light') {
      dark = false;
    } else if (mode === 'system') {
      dark = systemDark;
    }
    return dark ? ThemeConstants.resolveDark(accent) : ThemeConstants.resolveLight(accent);
  }
}
