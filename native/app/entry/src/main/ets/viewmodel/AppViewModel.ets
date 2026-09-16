import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';

/**
 * App-level session flags and theme (singleton).
 */
export class AppViewModel {
  private static instance: AppViewModel = new AppViewModel();

  hasServer: boolean = false;
  isLoggedIn: boolean = false;
  serverUrl: string = '';
  userName: string = '';
  isAdmin: boolean = false;
  themeMode: string = 'dark';
  accent: string = 'ocean';
  systemDark: boolean = true;
  themeVersion: number = 0;
  onThemeChanged: () => void = () => {};
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
