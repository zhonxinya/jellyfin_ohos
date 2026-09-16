import router from '@ohos.router';
import { ThemeColors } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { HomePage } from './HomePage';
import { SettingsPage } from './SettingsPage';
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

  @Builder
  NavItem(index: number, icon: Resource, selectedIcon: Resource, label: ResourceStr) {
    Column({ space: 4 }) {
      if (this.shellTabIndex === index) {
        Row()
          .width(32)
          .height(3)
          .backgroundColor(this.colors().primary)
          .borderRadius(2)
          .margin({ bottom: 2 })
      }
      Row() {
        SymbolGlyph(this.shellTabIndex === index ? selectedIcon : icon)
          .fontSize(22)
          .fontColor([this.shellTabIndex === index ? this.colors().primary : this.colors().onSurfaceVariant])
      }
        .width('100%')
        .height(28)
        .justifyContent(FlexAlign.Center)
        .alignItems(VerticalAlign.Center)
      Text(label)
        .fontSize(12)
        .fontColor(this.shellTabIndex === index ? this.colors().primary : this.colors().onSurfaceVariant)
    }
    .layoutWeight(1)
    .height(64)
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

  @Builder
  DrawerItem(label: string, icon: Resource, onTap: () => void) {
    Row({ space: 14 }) {
      SymbolGlyph(icon)
        .fontSize(22)
        .fontColor([this.colors().onSurfaceVariant])
      Text(label)
        .fontSize(16)
        .fontColor(this.colors().onSurface)
        .layoutWeight(1)
    }
    .width('100%')
    .height(52)
    .padding({ left: 20, right: 16 })
    .onClick(onTap)
  }

  @Builder
  NavigationDrawer() {
    Column() {
      Row({ space: 12 }) {
        Text('△')
          .fontSize(30)
          .fontColor(this.colors().primary)
        Text('Jellyfin')
          .fontSize(22)
          .fontColor(this.colors().onSurface)
        Blank()
        Button('×')
          .width(40)
          .height(40)
          .fontSize(24)
          .backgroundColor(Color.Transparent)
          .fontColor(this.colors().onSurfaceVariant)
          .onClick(() => { this.drawerOpen = false; })
      }
      .width('100%')
      .padding({ left: 20, right: 8, top: 18, bottom: 14 })

      Divider().color(this.colors().outline).strokeWidth(1)
      this.DrawerItem('首页', $r('sys.symbol.book_pages'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = 0;
      })
      this.DrawerItem('媒体库', $r('sys.symbol.book_pages'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = 0;
      })
      this.DrawerItem('搜索', $r('sys.symbol.magnifyingglass'), () => { this.openSearch(); })
      this.DrawerItem('继续观看', $r('sys.symbol.play_circle'), () => {
        this.drawerOpen = false;
        router.pushUrl({ url: 'pages/ContinueWatchingPage' });
      })
      this.DrawerItem('播放列表', $r('sys.symbol.play_circle'), () => {
        this.drawerOpen = false;
        router.pushUrl({ url: 'pages/PlaylistsPage' });
      })
      if (AppViewModel.getInstance().isAdmin) {
        this.DrawerItem('控制台', $r('sys.symbol.square_grid_2x2'), () => { this.openAdmin(); })
      }
      this.DrawerItem('设置', $r('sys.symbol.gearshape'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = 1;
      })
      Blank()
      Text(AppViewModel.getInstance().userName.length > 0 ? AppViewModel.getInstance().userName : '当前用户')
        .fontSize(14)
        .fontColor(this.colors().onSurfaceVariant)
        .width('100%')
        .padding({ left: 20, bottom: 20 })
    }
    .width(300)
    .height('100%')
    .backgroundColor(this.colors().surface)
    .shadow({ radius: 18, color: '#66000000', offsetX: 4, offsetY: 0 })
  }

  @Builder
  TopBar() {
    Row() {
      Button() {
        Text('☰')
          .fontSize(24)
          .fontColor(this.colors().onSurfaceVariant)
      }
      .width(48)
      .height(48)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => { this.drawerOpen = true; })
      Row({ space: 8 }) {
        Text('△')
          .fontSize(26)
          .fontColor(this.colors().primary)
        Text('Jellyfin')
          .fontSize(20)
          .fontColor(this.colors().onSurface)
      }
      .layoutWeight(1)
      Button() {
        SymbolGlyph($r('sys.symbol.magnifyingglass'))
          .fontSize(22)
          .fontColor([this.colors().onSurfaceVariant])
      }
      .width(48)
      .height(48)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => { this.openSearch(); })
      Button() {
        SymbolGlyph($r('sys.symbol.person_2'))
          .fontSize(22)
          .fontColor([this.colors().onSurfaceVariant])
      }
      .width(48)
      .height(48)
      .padding(0)
      .backgroundColor(Color.Transparent)
      .onClick(() => { this.shellTabIndex = 1; })
    }
    .width('100%')
    .height(64)
    .padding({ left: 8, right: 8 })
    .backgroundColor(this.colors().surface)
  }

  build() {
    Stack() {
      Column() {
        this.TopBar()
        Tabs({ barPosition: BarPosition.End, index: this.shellTabIndex }) {
        TabContent() {
          HomePage({ themeTick: $themeTick })
        }.tabBar($r('app.string.tab_library'))

        TabContent() {
          SettingsPage({ themeTick: $themeTick, embedded: true })
        }.tabBar($r('app.string.nav_settings'))
      }
      .layoutWeight(1)
      .width('100%')
      .barMode(BarMode.Fixed)
      .barHeight(0)
      .onChange((index: number) => {
        this.shellTabIndex = index;
      })

        Row() {
          this.NavItem(0, $r('sys.symbol.book_pages'), $r('sys.symbol.book_pages_fill'), $r('app.string.tab_library'))
          this.NavItem(1, $r('sys.symbol.gearshape'), $r('sys.symbol.gearshape_fill'), $r('app.string.nav_settings'))
        }
        .width('100%')
        .height(80)
        .backgroundColor(this.colors().surface)
        .border({ width: { top: 1 }, color: this.colors().outline })
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().background)

      if (this.drawerOpen) {
        Row() {
          this.NavigationDrawer()
          Blank()
            .layoutWeight(1)
            .height('100%')
            .backgroundColor('#99000000')
            .onClick(() => { this.drawerOpen = false; })
        }
        .width('100%')
        .height('100%')
      }
    }
    .width('100%')
    .height('100%')
  }
}
