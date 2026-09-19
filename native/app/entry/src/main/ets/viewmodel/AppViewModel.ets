import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';

/**
 * App-level session flags and theme (singleton).
 */
export class AppViewModel {
  private static instance: AppViewModel = new AppViewModel();

  hasServer: boolean = false;
  isLoggedIn: boolean = false;
  serverUrl: string = '';
  /** 服务器名称（来自 /System/Info/Public，经 configureServer 返回） */
  serverName: string = '';
  userName: string = '';
  isAdmin: boolean = false;
  themeMode: string = 'dark';
  accent: string = 'ocean';
  systemDark: boolean = true;
  themeVersion: number = 0;
  onThemeChanged: () => void = () => {};
  /**
   * 本地偏好变更信号（与 `onThemeChanged` 同一套路）。
   *
   * 用途：设置主页有几行是"现读本地偏好"算出来的（例如短视频模式的「已选 N 个媒体库」），
   * 而设置页是从子页返回时**不会重建**的嵌入式组件 —— 子页改完偏好后得有人通知外壳，
   * 外壳再给设置页一个刷新信号；否则返回设置页看到的还是进子页之前的旧数字（设备实测过）。
   */
  onLocalPrefsChanged: () => void = () => {};

  /** 子页改完本地偏好后调用 */
  notifyLocalPrefsChanged(): void {
    this.onLocalPrefsChanged();
  }
  /** @deprecated use themeMode */
  theme: string = 'dark';

  static getInstance(): AppViewModel {
    return AppViewModel.instance;
  }

  colors(): ThemeColors {
    return ThemeConstants.resolve(this.themeMode, this.accent, this.systemDark);
  }

  notifyThemeChanged(): void {
    this.themeVersion = this.themeVersion + 1;
    this.onThemeChanged();
  }

  setThemeMode(mode: string): void {
    this.themeMode = mode;
    this.theme = mode === 'light' ? 'light' : 'dark';
    this.notifyThemeChanged();
  }

  setAccent(accent: string): void {
    this.accent = accent;
    this.notifyThemeChanged();
  }

  resetAuth(): void {
    this.isLoggedIn = false;
    this.userName = '';
    this.isAdmin = false;
  }

  setServerName(name: string): void {
    this.serverName = name;
  }

  setServer(url: string): void {
    this.serverUrl = url;
    this.hasServer = url.length > 0;
  }

  setLoggedIn(userName: string, isAdmin: boolean): void {
    this.isLoggedIn = true;
    this.userName = userName;
    this.isAdmin = isAdmin;
  }
}
