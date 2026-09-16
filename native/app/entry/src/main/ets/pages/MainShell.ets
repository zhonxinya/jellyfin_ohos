import router from '@ohos.router';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { AppIconButton } from '../components/AppIconButton';
import { AppTopBar } from '../components/AppTopBar';
import { HomePage } from './HomePage';
import { SettingsPage } from './SettingsPage';

/**
 * 应用外壳 —— 按 mybooks_ohos 的 MainTabs 重构。
 *
 * 视觉规格（参考项目逐项对齐）：
 * - 顶栏 56vp，`card_background` 底色，标题 20fp/Medium/`text_primary`，底部 0.5vp 分隔线；
 * - 底部标签栏 56vp，`card_background`，选中 `brand_primary`、未选中 `text_secondary`；
 *   图标 22fp + 文字 10fp，**不再用下划线指示器**（参考项目只用颜色区分）；
 * - 图标全部用 `SymbolGlyph` 系统符号，不再用 `☰ / △ / ×` 之类文本字符；
 * - 抽屉行 52vp、标题 16fp，按下态 `surface_pressed`，分隔线 0.5vp，遮罩用 `scrimHeavy` 令牌。
 */
@Entry
@Component
struct MainShell {
  @State private shellTabIndex: number = 0;
  @State private themeTick: number = 0;
  @State private drawerOpen: boolean = false;

  aboutToAppear(): void {
    AppViewModel.getInstance().onThemeChanged = () => {
      this.themeTick = this.themeTick + 1;
    };
    this.themeTick = AppViewModel.getInstance().themeVersion;
  }

  private colors(): ThemeColors {
    this.themeTick;
    return AppViewModel.getInstance().colors();
  }

  /**
   * 标签项：图标 22fp + 文字 10fp。
   * 对齐参考项目 tabBuilder：**选中与未选中共用同一个图标**，只靠颜色区分
   * （选中 `brand_primary`、未选中 `text_secondary`），不再画下划线指示器。
   */
  @Builder
  TabItem(index: number, icon: Resource, label: ResourceStr) {
    Column({ space: 4 }) {
      SymbolGlyph(icon)
        .fontSize(ThemeConstants.TAB_ICON)
        .fontColor([this.shellTabIndex === index ? this.colors().brandPrimary : this.colors().textSecondary])
      Text(label)
        .fontSize(ThemeConstants.TAB_LABEL)
        .fontColor(this.shellTabIndex === index ? this.colors().brandPrimary : this.colors().textSecondary)
    }
    .layoutWeight(1)
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .onClick(() => {
      this.shellTabIndex = index;
    })
  }

  private openSearch(): void {
    this.drawerOpen = false;
    router.pushUrl({ url: 'pages/SearchPage' });
  }

  private openAdmin(): void {
    this.drawerOpen = false;
    router.pushUrl({ url: 'pages/admin/AdminHubPage' });
  }

  private pushPage(url: string): void {
    this.drawerOpen = false;
    router.pushUrl({ url: url });
  }

  /** 抽屉行：52vp / 图标 20fp / 标题 16fp，按下态 surface_pressed（对齐参考项目设置行） */
  @Builder
  DrawerItem(label: string, icon: Resource, onTap: () => void) {
    Row({ space: 14 }) {
      SymbolGlyph(icon)
        .fontSize(20)
        .fontColor([this.colors().textSecondary])
        .width(28)
      Text(label)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .layoutWeight(1)
    }
    .width('100%')
    .height(52)
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })
    .backgroundColor(Color.Transparent)
    .stateStyles({
      pressed: {
        .backgroundColor(this.colors().surfacePressed)
      }
    })
    .onClick(onTap)
  }

  @Builder
  DrawerDivider() {
    Divider()
      .color(this.colors().divider)
      .strokeWidth(0.5)
      .margin({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })
  }

  @Builder
  NavigationDrawer() {
    Column() {
      Row({ space: 12 }) {
        SymbolGlyph($r('sys.symbol.play_circle'))
          .fontSize(26)
          .fontColor([this.colors().brandPrimary])
        Text('Jellyfin')
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .layoutWeight(1)
        AppIconButton({
          icon: $r('sys.symbol.chevron_left'),
          variant: 'ghost',
          iconSize: 18,
          onTap: () => {
            this.drawerOpen = false;
          }
        })
      }
      .width('100%')
      .padding({ left: ThemeConstants.PAGE_PADDING, right: 8, top: 14, bottom: 10 })
      .alignItems(VerticalAlign.Center)

      this.DrawerDivider()
      this.DrawerItem('首页', $r('sys.symbol.square_grid_2x2'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = 0;
      })
      this.DrawerItem('媒体库', $r('sys.symbol.rectangle_stack'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = 0;
      })
      this.DrawerDivider()
      this.DrawerItem('搜索', $r('sys.symbol.magnifyingglass'), () => { this.openSearch(); })
      this.DrawerItem('继续观看', $r('sys.symbol.play_circle'), () => { this.pushPage('pages/ContinueWatchingPage'); })
      this.DrawerItem('播放列表', $r('sys.symbol.list_bullet'), () => { this.pushPage('pages/PlaylistsPage'); })
      this.DrawerDivider()
      if (AppViewModel.getInstance().isAdmin) {
        this.DrawerItem('控制台', $r('sys.symbol.gearshape'), () => { this.openAdmin(); })
      }
      this.DrawerItem('设置', $r('sys.symbol.gearshape'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = 1;
      })

      Blank()
      Divider()
        .color(this.colors().divider)
        .strokeWidth(0.5)
      Text(AppViewModel.getInstance().userName.length > 0 ? AppViewModel.getInstance().userName : '当前用户')
        .fontSize(ThemeConstants.META_MEDIUM)
        .fontColor(this.colors().textSecondary)
        .width('100%')
        .padding({ left: ThemeConstants.PAGE_PADDING, top: 12, bottom: 16 })
    }
    .width(280)
    .height('100%')
    .backgroundColor(this.colors().cardBackground)
    .shadow({ radius: 18, color: '#66000000', offsetX: 4, offsetY: 0 })
  }

  build() {
    Stack() {
      Column() {
        AppTopBar({
          title: 'Jellyfin',
          showBack: true,
          backIcon: $r('sys.symbol.list_bullet'),
          onBackTap: () => {
            this.drawerOpen = true;
          },
          action: () => {
            this.TopBarActions();
          }
        })

        Tabs({ barPosition: BarPosition.End, index: this.shellTabIndex }) {
          TabContent() {
            HomePage({ themeTick: $themeTick })
          }
          .tabBar($r('app.string.tab_library'))

          TabContent() {
            SettingsPage({ themeTick: $themeTick, embedded: true })
          }
          .tabBar($r('app.string.nav_settings'))
        }
        .layoutWeight(1)
        .width('100%')
        .barMode(BarMode.Fixed)
        .barHeight(0)
        .onChange((index: number) => {
          this.shellTabIndex = index;
        })

        Row() {
          this.TabItem(0, $r('sys.symbol.square_grid_2x2'), $r('app.string.tab_library'))
          this.TabItem(1, $r('sys.symbol.gearshape'), $r('app.string.nav_settings'))
        }
        .width('100%')
        .height(ThemeConstants.TAB_BAR_HEIGHT)
        .backgroundColor(this.colors().cardBackground)
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.drawerOpen) {
        Row() {
          this.NavigationDrawer()
          Blank()
            .layoutWeight(1)
            .height('100%')
            .backgroundColor(this.colors().scrimHeavy)
            .onClick(() => {
              this.drawerOpen = false;
            })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }

  @Builder
  TopBarActions() {
    Row({ space: 4 }) {
      AppIconButton({
        icon: $r('sys.symbol.magnifyingglass'),
        variant: 'ghost',
        iconSize: 20,
        onTap: () => { this.openSearch(); }
      })
      AppIconButton({
        icon: $r('sys.symbol.person_2'),
        variant: 'ghost',
        iconSize: 20,
        onTap: () => {
          this.shellTabIndex = 1;
        }
      })
    }
  }
}
