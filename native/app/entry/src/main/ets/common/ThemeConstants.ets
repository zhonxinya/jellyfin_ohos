/**
 * 设计令牌（Design Tokens）——对齐 mybooks_ohos 的视觉语言。
 *
 * 参考项目 `/vol1/home/zhonxinya/workspace/mybooks_ohos` 的令牌分三层：
 *   1. `resources/base|dark/element/color.json` —— 27 个同名颜色，靠资源限定词目录自动切换明暗；
 *   2. `resources/base/element/float.json` —— 13 个尺寸令牌（明暗通用，无 dark 版本）；
 *   3. 组件内字面量 —— 字号、阴影、图标尺寸。
 *
 * 本工程保留了「运行时可切换主题 + 强调色」的既有架构（`AppViewModel.themeMode/accent`），
 * 因此这里把参考项目的角色名做成运行时可解析的令牌：`ThemeColors` 同时提供
 *   - 参考项目词汇（pageBackground / cardBackground / textPrimary / brandPrimary / …）；
 *   - 旧词汇（background / surface / onSurface / primary / onSurfaceVariant / …）作为**弃用别名**，
 *     取值与参考项目词汇一致，保证既有页面无需改动即可切换到新视觉。
 * 资源层（color.json / float.json）同步维护同一套名字，供后续迁移到 `$r('app.color.*')` 的组件使用。
 */

export type ThemeMode = 'system' | 'light' | 'dark';
export type ThemeAccent = 'ocean' | 'jade' | 'amber' | 'coral';

/**
 * 调色板。字段名 = 参考项目 `app.color.*` 令牌名（驼峰化）。
 */
export class ThemeColors {
  // ── 参考项目词汇（推荐使用）────────────────────────────────────────────
  /** 页面底色：浅 #F1F3F5 / 深 #121417 */
  pageBackground: string = '#121417';
  /** 卡片与顶栏底色：浅 #FFFFFF / 深 #1C1F24 */
  cardBackground: string = '#1C1F24';
  /** 品牌色（强调色）：浅 #007DFF / 深 #4DA3FF */
  brandPrimary: string = '#4DA3FF';
  /** 品牌色浅底（次级按钮/标签底）：浅 #E6F2FF / 深 #14324D */
  brandPrimaryLight: string = '#14324D';
  /** 品牌色按下态 */
  brandPrimaryPressed: string = '#7AB8FF';
  /** 品牌色浅底按下态 */
  brandPrimaryLightPressed: string = '#0F2438';
  /** 主文字 */
  textPrimary: string = '#E8EAED';
  /** 次级文字（标题副行、作者） */
  textSecondary: string = '#99E8EAED';
  /** 三级文字（元信息、提示） */
  textTertiary: string = '#66E8EAED';
  /** 0.5vp 分隔线颜色 */
  divider: string = '#33E8EAED';
  /** 品牌色之上的文字：浅 #FFFFFF / 深 #0A0A0A */
  onBrand: string = '#0A0A0A';
  /** 卡片/行按下态底色 */
  surfacePressed: string = '#2A2E34';
  /** 未选中 chip 按下态 */
  chipBackgroundPressed: string = '#22262B';
  /** 错误（危险操作） */
  error: string = '#FF6B54';
  /** 错误浅底（危险按钮底） */
  errorLight: string = '#3A1B14';
  /** 错误浅底按下态 */
  errorLightPressed: string = '#4A231A';
  /** 成功 */
  success: string = '#7BD474';
  /** 成功浅底 */
  successLight: string = '#16301A';
  /** 警告 */
  warning: string = '#F0B860';
  /** 警告浅底 */
  warningLight: string = '#3A2E15';
  /** 主按钮投影 */
  buttonShadow: string = '#40000000';
  /** 海报占位色（首字块） */
  coverPlaceholder: string = '#4DA3FF';
  /** 海报占位底 */
  coverPlaceholderBg: string = '#FF2A2D31';
  /** 未读徽标底 */
  unreadBackground: string = '#14324D';
  /** 封面色渐变终点（详情页 hero 渐变用） */
  brandGradientEnd: string = '#121417';

  // ── 旧词汇（弃用别名，取值同上；新代码请使用上面的名字）──────────────
  /** @deprecated 用 pageBackground */
  background: string = '#121417';
  /** @deprecated 用 cardBackground */
  surface: string = '#1C1F24';
  /** @deprecated 用 surfacePressed */
  surfaceElevated: string = '#2A2E34';
  /** @deprecated 用 surfacePressed */
  surfaceContainerHighest: string = '#2A2E34';
  /** @deprecated 用 brandPrimary */
  primary: string = '#4DA3FF';
  /** @deprecated 用 textPrimary */
  onSurface: string = '#E8EAED';
  /** @deprecated 用 textSecondary */
  onSurfaceVariant: string = '#99E8EAED';
  /** @deprecated 用 onBrand */
  onPrimary: string = '#0A0A0A';
  /** @deprecated 用 divider */
  outline: string = '#33E8EAED';
  /** @deprecated 用 errorLight */
  destructive: string = '#3A1B14';
  /** @deprecated 用 divider */
  progressTrack: string = '#3A3A3A';

  // ── 海报/浮层专用（不随明暗翻转的叠加色）──────────────────────────────
  onOverlay: string = '#FFFFFF';
  onOverlayMuted: string = '#FFFFFFB3';
  scrim: string = '#00000088';
  scrimHeavy: string = '#000000CC';
  overlayControl: string = '#FFFFFF33';
  overlayControlStrong: string = '#00000066';
  posterScrim: string = '#00000061';
  posterGradientStart: string = '#0000009E';
  /** 图片上的格式徽标底（参考项目用 #B3000000） */
  badgeScrim: string = '#B3000000';
  /** 视频底色（播放器黑底，与明暗主题无关） */
  videoBackground: string = '#000000';
}

/**
 * 尺寸/排版令牌（对应参考项目 `app.float.*`，明暗通用）。
 */
export class ThemeConstants {
  // ── 间距与圆角 ──────────────────────────────────────────────────────
  /** 页面左右留白 */
  static readonly PAGE_PADDING: number = 16;
  /** 卡片内边距 */
  static readonly CARD_PADDING: number = 12;
  /** 卡片圆角 */
  static readonly CARD_RADIUS: number = 12;
  /** 封面圆角 */
  static readonly COVER_RADIUS: number = 8;
  /** chip 圆角 */
  static readonly CHIP_RADIUS: number = 10;
  /** 按钮/输入框圆角（与卡片对齐，避免胶囊观感） */
  static readonly BUTTON_RADIUS: number = 12;
  /** 徽标圆角 */
  static readonly BADGE_RADIUS: number = 10;

  // ── 高度与尺寸 ──────────────────────────────────────────────────────
  /** 顶栏高度 */
  static readonly TOP_BAR_HEIGHT: number = 56;
  /** 底部标签栏高度 */
  static readonly TAB_BAR_HEIGHT: number = 56;
  /** 列表行高度 */
  static readonly LIST_ITEM_HEIGHT: number = 108;
  /** 按钮高度 */
  static readonly BUTTON_HEIGHT: number = 48;
  /** 紧凑按钮/搜索框高度 */
  static readonly BUTTON_HEIGHT_COMPACT: number = 40;
  /** 圆形图标按钮尺寸 */
  static readonly ICON_BUTTON_SIZE: number = 40;
  /** chip 高度 */
  static readonly CHIP_HEIGHT: number = 34;
  /** 表单输入框高度 */
  static readonly INPUT_HEIGHT: number = 44;
  /** 表单多行输入高度 */
  static readonly TEXTAREA_HEIGHT: number = 90;

  // ── 海报与栅格 ──────────────────────────────────────────────────────
  /** 海报宽高比（宽/高），参考项目全站统一 0.7 */
  static readonly POSTER_RATIO: number = 0.7;
  /** 列表缩略图 */
  static readonly LIST_THUMB_WIDTH: number = 64;
  static readonly LIST_THUMB_HEIGHT: number = 92;
  /** 独立封面瓦片 */
  static readonly COVER_TILE_WIDTH: number = 100;
  static readonly COVER_TILE_HEIGHT: number = 140;
  /** 详情页 hero 封面 */
  static readonly DETAIL_POSTER_WIDTH: number = 120;
  static readonly DETAIL_POSTER_HEIGHT: number = 170;
  /** 横向轨道封面 */
  static readonly RAIL_POSTER_WIDTH: number = 110;
  static readonly RAIL_POSTER_HEIGHT: number = 154;
  /** 栅格列数与间距 */
  static readonly GRID_COLUMNS: number = 3;
  static readonly GRID_COLUMN_GAP: number = 10;
  static readonly GRID_ROW_GAP: number = 14;
  /** 列表项间距 */
  static readonly LIST_SPACE: number = 8;
  /** 卡片纵向堆叠间距 */
  static readonly CARD_STACK_SPACE: number = 12;

  // ── 字号阶梯（参考项目字面量，此处收敛为令牌）────────────────────────
  /** 页面/顶栏标题 */
  static readonly TITLE_XLARGE: number = 21;
  /** 封面角标/徽标（参考项目 9fp） */
  static readonly BADGE_LABEL: number = 9;
  static readonly TITLE_LARGE: number = 20;
  /** 区块标题、列表项标题、设置行标题 */
  static readonly TITLE_MEDIUM: number = 16;
  /** 正文 */
  static readonly BODY_MEDIUM: number = 14;
  /** 次级正文 */
  static readonly META_MEDIUM: number = 13;
  /** 元信息 */
  static readonly META_SMALL: number = 12;
  /** 三级元信息 */
  static readonly LABEL_SMALL: number = 11;
  /** 底部标签栏文字 */
  static readonly TAB_LABEL: number = 10;
  /** 空态图标 */
  static readonly EMPTY_ICON_SIZE: number = 48;
  // 图标字号梯度（SymbolGlyph 用；与文字字号分开，避免"图标当文字用"）
  static readonly ICON_SMALL: number = 16;
  static readonly ICON_MEDIUM: number = 18;
  static readonly ICON_LARGE: number = 20;
  static readonly ICON_XLARGE: number = 22;
  static readonly ICON_XXL: number = 28;
  static readonly ICON_HERO: number = 40;
  /** 空态/加载态主文案 */
  static readonly STATE_TITLE: number = 16;
  /** 空态说明文案 */
  static readonly STATE_DETAIL: number = 13;
  /** 底部标签栏图标 */
  static readonly TAB_ICON: number = 22;

  // ── 强调色种子 ──────────────────────────────────────────────────────
  /** 默认品牌色（对齐 mybooks_ohos 的 brand_primary） */
  static readonly ACCENT_OCEAN: string = '#007DFF';
  static readonly ACCENT_JADE: string = '#00897B';
  static readonly ACCENT_AMBER: string = '#F59E0B';
  static readonly ACCENT_CORAL: string = '#E76F51';

  /** 兼容旧代码：卡片宽度 */
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
  static readonly DETAIL_POSTER_WIDTH_LEGACY: number = 130;
  static readonly TITLE_SMALL: number = 14;

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

  /** 强调色在浅色主题下的浅底（品牌色 12% 混合白） */
  static accentLight(accent: string): string {
    if (accent === 'jade') {
      return '#E0F2F1';
    }
    if (accent === 'amber') {
      return '#FFF4E0';
    }
    if (accent === 'coral') {
      return '#FDEDE9';
    }
    return '#E6F2FF';
  }

  /** 强调色在深色主题下的浅底 */
  static accentLightDark(accent: string): string {
    if (accent === 'jade') {
      return '#14332F';
    }
    if (accent === 'amber') {
      return '#3A2E12';
    }
    if (accent === 'coral') {
      return '#3A211B';
    }
    return '#14324D';
  }

  /** 强调色在深色主题下的主色（提亮一档，保证对比度） */
  static accentDark(accent: string): string {
    if (accent === 'jade') {
      return '#4DB6AC';
    }
    if (accent === 'amber') {
      return '#F5B942';
    }
    if (accent === 'coral') {
      return '#F08A6E';
    }
    return '#4DA3FF';
  }

  static resolveDark(accent: string): ThemeColors {
    const c: ThemeColors = new ThemeColors();
    c.pageBackground = '#121417';
    c.cardBackground = '#1C1F24';
    c.brandPrimary = ThemeConstants.accentDark(accent);
    c.brandPrimaryLight = ThemeConstants.accentLightDark(accent);
    c.brandPrimaryPressed = ThemeConstants.accentDark(accent);
    c.brandPrimaryLightPressed = '#0F2438';
    c.textPrimary = '#E8EAED';
    c.textSecondary = '#99E8EAED';
    c.textTertiary = '#66E8EAED';
    c.divider = '#33E8EAED';
    c.onBrand = '#0A0A0A';
    c.surfacePressed = '#2A2E34';
    c.chipBackgroundPressed = '#22262B';
    c.error = '#FF6B54';
    c.errorLight = '#3A1B14';
    c.errorLightPressed = '#4A231A';
    c.success = '#7BD474';
    c.successLight = '#16301A';
    c.warning = '#F0B860';
    c.warningLight = '#3A2E15';
    c.buttonShadow = '#40000000';
    c.coverPlaceholder = ThemeConstants.accentDark(accent);
    c.coverPlaceholderBg = '#FF2A2D31';
    c.unreadBackground = '#14324D';
    c.brandGradientEnd = '#121417';

    c.background = c.pageBackground;
    c.surface = c.cardBackground;
    c.surfaceElevated = c.surfacePressed;
    c.surfaceContainerHighest = c.surfacePressed;
    c.primary = c.brandPrimary;
    c.onSurface = c.textPrimary;
    c.onSurfaceVariant = c.textSecondary;
    c.onPrimary = c.onBrand;
    c.outline = c.divider;
    c.destructive = c.errorLight;
    c.progressTrack = '#3A3A3A';

    c.onOverlay = '#FFFFFF';
    c.onOverlayMuted = '#FFFFFFB3';
    c.scrim = '#00000088';
    c.scrimHeavy = '#000000CC';
    c.overlayControl = '#FFFFFF33';
    c.overlayControlStrong = '#00000066';
    c.posterScrim = '#00000061';
    c.posterGradientStart = '#0000009E';
    c.badgeScrim = '#B3000000';
    return c;
  }

  static resolveLight(accent: string): ThemeColors {
    const c: ThemeColors = new ThemeColors();
    c.pageBackground = '#F1F3F5';
    c.cardBackground = '#FFFFFF';
    c.brandPrimary = ThemeConstants.accentSeed(accent);
    c.brandPrimaryLight = ThemeConstants.accentLight(accent);
    c.brandPrimaryPressed = '#0062CC';
    c.brandPrimaryLightPressed = '#CCE5FF';
    c.textPrimary = '#182431';
    c.textSecondary = '#99182431';
    c.textTertiary = '#66182431';
    c.divider = '#33182431';
    c.onBrand = '#FFFFFF';
    c.surfacePressed = '#E8EBEE';
    c.chipBackgroundPressed = '#F1F3F5';
    c.error = '#E84026';
    c.errorLight = '#FFF0ED';
    c.errorLightPressed = '#FFDAD4';
    c.success = '#64BB5C';
    c.successLight = '#EEF8EC';
    c.warning = '#B26A00';
    c.warningLight = '#FFF6E5';
    c.buttonShadow = '#40007DFF';
    c.coverPlaceholder = ThemeConstants.accentSeed(accent);
    c.coverPlaceholderBg = '#FFE8E8E8';
    c.unreadBackground = '#E6F2FF';
    c.brandGradientEnd = '#F5F8FC';

    c.background = c.pageBackground;
    c.surface = c.cardBackground;
    c.surfaceElevated = c.surfacePressed;
    c.surfaceContainerHighest = c.surfacePressed;
    c.primary = c.brandPrimary;
    c.onSurface = c.textPrimary;
    c.onSurfaceVariant = c.textSecondary;
    c.onPrimary = c.onBrand;
    c.outline = c.divider;
    c.destructive = c.errorLight;
    c.progressTrack = '#DDDDDD';

    c.onOverlay = '#FFFFFF';
    c.onOverlayMuted = '#FFFFFFB3';
    c.scrim = '#00000066';
    c.scrimHeavy = '#00000099';
    c.overlayControl = '#FFFFFF4D';
    c.overlayControlStrong = '#00000040';
    c.posterScrim = '#00000040';
    c.posterGradientStart = '#00000080';
    c.badgeScrim = '#B3000000';
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
