import router from '@ohos.router';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { WindowFullscreen } from '../common/WindowFullscreen';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { AppIconButton } from '../components/AppIconButton';
import { AppTopBar } from '../components/AppTopBar';
import { HomePage } from './HomePage';
import { ShortVideoPage } from './ShortVideoPage';
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
/** 「视频」页在底部页签中的下标（与 ShortVideoPage.kVideoTabIndex 对应） */
const kVideoTabIndex: number = 1;
/** 「设置」页在底部页签中的下标 */
const kSettingsTabIndex: number = 2;

@Entry
@Component
struct MainShell {
  @State private shellTabIndex: number = 0;
  @State private themeTick: number = 0;
  @State private drawerOpen: boolean = false;
  /**
   * 「视频」页的重读信号：每次切到该页签就自增。
   *
   * 为什么需要它：`ShortVideoPage` 是嵌在 Tabs 里的普通组件，从「短视频模式」设置页
   * 返回时**不会重建**（`aboutToAppear` 不再触发），于是用户刚勾完媒体库、
   * 回到「视频」页却仍是空态 —— 必须由一个外部信号告诉它"配置可能变了"。
   */
  @State private videoTabTick: number = 0;
  /**
   * 「设置」页的重读信号：每次切到该页签就自增。
   *
   * 同样的道理：设置页里有些行是"现读本地偏好"算出来的（例如短视频模式的「已选 N 个媒体库」），
   * 而设置页是从子页返回时**不会重建**的嵌入式组件 —— 不给信号的话，
   * 用户刚在子页改完、返回设置页看到的还是旧数字（设备实测：取消勾选一个库后仍显示「已选 2 个」）。
   */
  @State private settingsTabTick: number = 0;
  /** 窗口实例：沉浸式全屏（「视频」页）需要它，进入/退出必须成对 */
  private windowRef: window.Window | null = null;
  /** 当前是否为「视频」页应用了沉浸式全屏（避免重复进入/退出） */
  private immersiveForVideoTab: boolean = false;
  /**
   * 沉浸式下「视频」页顶部要避让的像素（vp，来自挖孔/状态栏）。
   *
   * 为什么由外壳算并下发：窗口实例在外壳手里，而**视频层铺满、工具层内缩**是同一套规则 ——
   * 页面自己再取一次窗口既多一次异步、也可能拿到不同实例。
   */
  @State private videoTopInsetVp: number = 0;
  /**
   * 「视频」页是否处于**主动全屏**（页面按了全屏按钮：横屏 + 铺满）。
   *
   * 为什么由外壳持有：底部页签栏是**外壳**画的那一条，页面自己藏不掉。
   * 页面通过 `@Link` 回写这个信号，外壳据此决定画不画页签栏 —— 收起后
   * `Tabs`（`layoutWeight(1)`）自然拿到那 56vp，画面真正铺满整屏。
   * 只在「视频」页签下有意义，且**不持久化**（页签栏是唯一的页签入口，不能启动就没有）。
   */
  @State private videoFullscreen: boolean = false;

  aboutToAppear(): void {
    AppViewModel.getInstance().onThemeChanged = () => {
      this.themeTick = this.themeTick + 1;
    };
    // 子页改了本地偏好（例如短视频模式勾选的媒体库）：给设置页一个刷新信号，
    // 否则从子页返回时设置页不会重建，那几行"现读偏好"的文字仍是旧值。
    AppViewModel.getInstance().onLocalPrefsChanged = () => {
      this.settingsTabTick = this.settingsTabTick + 1;
    };
    this.themeTick = AppViewModel.getInstance().themeVersion;
    // 窗口实例提前取回：切到「视频」页要立刻隐藏系统栏，不能等到用户切页签时才开始异步取
    window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
      this.windowRef = win;
      this.applyChromeForTab(this.shellTabIndex);
      // 系统底部导航条的底色跟着应用走（部分机型/窗口模式下系统条是不透明的，
      // 不改颜色就会在页签行下面压出一条异色横带）。真正让底部连成一整块的是
      // build() 里的 expandSafeArea —— 见本文件 build() 开头与 WindowFullscreen.styleNavigationBarWith。
      WindowFullscreen.styleNavigationBarWith(win, this.colors().cardBackground);
    }).catch(() => {
      // 取不到窗口时「视频」页仍可用，只是不沉浸（不做静默假设）
    });
  }

  /**
   * 返回本页（从播放页/详情页返回）时重新应用一次窗口外观。
   *
   * 为什么需要：播放页自己也会进出沉浸式（`WindowFullscreen`），它退出时会把系统栏还回来；
   * 若用户本来就停在「视频」页签上，返回后不会触发页签变化，系统栏就会一直挂着。
   */
  onPageShow(): void {
    this.applyChromeForTab(this.shellTabIndex);
    // 系统栏刚被还回来（播放页/别的沉浸式页面退出）：底色必须按本页主题重新染一次
    WindowFullscreen.styleNavigationBarWith(this.windowRef, this.colors().cardBackground);
  }

  /**
   * 「视频」页默认**全屏沉浸式**（需求）：切到该页签即隐藏系统状态栏与导航栏并铺满整屏，
   * 切走/离开必须还原（其它页面是普通布局，顶着"没有系统栏"会被当成系统级异常）。
   */
  private applyChromeForTab(index: number): void {
    const wantImmersive: boolean = index === kVideoTabIndex;
    // 离开「视频」页签时收回主动全屏：底部页签栏必须回来，否则用户没有切页签的入口
    // （页面自己也会在 `onTabIndexChanged` 里收回，这里是外壳侧的兜底，两条路都堵住）
    if (!wantImmersive) {
      this.videoFullscreen = false;
    }
    if (wantImmersive === this.immersiveForVideoTab) {
      return;
    }
    this.immersiveForVideoTab = wantImmersive;
    if (wantImmersive) {
      WindowFullscreen.enter(this.windowRef);
      // 系统栏隐藏后仍要避让挖孔：insets 的 visible 判定在 WindowFullscreen 里统一处理
      this.videoTopInsetVp = WindowFullscreen.insets(this.windowRef, false).top;
    } else {
      // 退出沉浸式：还原系统栏时**必须同时**把底部导航条染回页签行的底色，
      // 否则系统栏一出现就露出默认白底，底部页签行下面又多出一条白带（见 styleNavigationBarWith）
      WindowFullscreen.exit(this.windowRef, this.colors().cardBackground);
      this.videoTopInsetVp = 0;
    }
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
      if (index === kVideoTabIndex) {
        // 切到「视频」页：重读短视频媒体库配置（设置页可能刚改过）+ 进入全屏沉浸式
        this.videoTabTick = this.videoTabTick + 1;
      }
      if (index === kSettingsTabIndex) {
        // 切到「设置」页：让"读本地偏好"的那几行重算（见 settingsTabTick 的说明）
        this.settingsTabTick = this.settingsTabTick + 1;
      }
      this.applyChromeForTab(index);
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
        .fontSize(ThemeConstants.ICON_LARGE)
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
          .fontSize(ThemeConstants.ICON_XXL)
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
      // 「视频」（短视频模式）与底部页签同一入口：抽屉里也放一个，长列表里更容易发现
      this.DrawerItem('视频', $r('sys.symbol.play_circle'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = 1;
      })
      this.DrawerItem('继续观看', $r('sys.symbol.play_circle'), () => { this.pushPage('pages/ContinueWatchingPage'); })
      this.DrawerItem('播放列表', $r('sys.symbol.list_bullet'), () => { this.pushPage('pages/PlaylistsPage'); })
      this.DrawerDivider()
      if (AppViewModel.getInstance().isAdmin) {
        this.DrawerItem('控制台', $r('sys.symbol.gearshape'), () => { this.openAdmin(); })
      }
      this.DrawerItem('设置', $r('sys.symbol.gearshape'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = 2;
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
    // 外壳根容器把页面底色**向下铺到屏幕底边**（`expandSafeArea` 到 BOTTOM），底色用底部页签行的颜色。
    //
    // 为什么：应用窗口本身是铺满整屏的，但**系统底部导航条不属于窗口安全区** —— 应用不在那一条里画东西时，
    // 露出的就是系统底（浅色机型上是纯白）。于是同一个底部页签行：「媒体库」「设置」页下面是
    // "56vp 页签行 + 28vp 白条"，「视频」页沉浸式下是"56vp 页签行 + 28vp 应用深色底" ——
    // 两处看起来页签行高度不一致（模拟器 127.0.0.1:5555 实测：窗口内容止于 y=2750，
    // 白/深色分界正好在 y=2750，也就是 `SCBGestureNavBar` 的顶边）。
    // 铺满之后三个页签下的底部是同一块连续底色，页签行的内容位置完全不变（只是背景多铺了 28vp）。
    Column() {
      Stack() {
        Column() {
          // 「视频」页不显示外壳顶栏（沉浸式视频流）。
          //
          // 为什么：该页的心智是"打开就刷"，顶栏的抽屉/搜索入口在这条动线上用不上，
          // 而 56vp 的顶栏是从画面里直接扣掉的 —— 竖屏手机上这接近可见高度的 1/10。
          // 页面自己的浮层工具行已经提供「方向 / 设置」入口，底部页签仍可切换到别的页。
          if (this.shellTabIndex !== kVideoTabIndex) {
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
          }

          Tabs({ barPosition: BarPosition.End, index: this.shellTabIndex }) {
            TabContent() {
              HomePage({ themeTick: $themeTick })
            }
            .tabBar($r('app.string.tab_library'))

            // 「视频」页：短视频模式的承载页。内容来自设置里勾选的短视频媒体库（见
            // pages/settings/ShortVideoSettingsPage），因此它既不属于"媒体库浏览"，
            // 也不属于"设置"，独立成一个页签。
            TabContent() {
              ShortVideoPage({
                themeTick: $themeTick,
                refreshTick: this.videoTabTick,
                // 页签下标传进去：离开「视频」页时页面自己要暂停播放
                // （嵌入式组件不会销毁，否则会在"设置"页里继续放声音）
                activeTab: this.shellTabIndex,
                // 沉浸式下工具层按挖孔内缩（视频层仍然铺满）
                topInsetVp: this.videoTopInsetVp,
                // 主动全屏信号（双向）：页面按全屏按钮 → 外壳收起底部页签栏，画面铺满整屏
                fullscreenActive: $videoFullscreen
              })
            }
            .tabBar('视频')

            TabContent() {
              SettingsPage({ themeTick: $themeTick, embedded: true,
                settingsTick: this.settingsTabTick })
            }
            .tabBar($r('app.string.nav_settings'))
          }
          .layoutWeight(1)
          .width('100%')
          .barMode(BarMode.Fixed)
          .barHeight(0)
          .onChange((index: number) => {
            this.shellTabIndex = index;
            this.applyChromeForTab(index);
          })

          // 主动全屏时整条页签栏收起（`Tabs` 是 layoutWeight(1)，自然拿到这 56vp）。
          // 用 `if` 而不是 `opacity(0)`：透明的页签按钮**仍然可点**，
          // "藏起来却还吃触摸"是本项目已经踩过的一类 bug（见 ShortVideoPage 的工具行说明）。
          if (!this.videoFullscreen) {
            Row() {
              this.TabItem(0, $r('sys.symbol.square_grid_2x2'), $r('app.string.tab_library'))
              this.TabItem(1, $r('sys.symbol.play_circle'), '视频')
              this.TabItem(2, $r('sys.symbol.gearshape'), $r('app.string.nav_settings'))
            }
            .width('100%')
            .height(ThemeConstants.TAB_BAR_HEIGHT)
            .backgroundColor(this.colors().cardBackground)
          }
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
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().cardBackground)
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
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
          this.shellTabIndex = 2;
        }
      })
    }
  }
}
