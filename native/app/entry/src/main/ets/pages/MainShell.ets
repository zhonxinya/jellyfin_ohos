import router from '@ohos.router';
import window from '@ohos.window';
import common from '@ohos.app.ability.common';
import { WindowFullscreen, FullscreenResult } from '../common/WindowFullscreen';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MusicPlayback, MusicPlaybackState } from '../common/MusicPlayback';
import { AppIconButton } from '../components/AppIconButton';
import { AppTopBar } from '../components/AppTopBar';
import { JellyfinImage } from '../components/JellyfinImage';
import { HomePage } from './HomePage';
import { ShortVideoPage } from './ShortVideoPage';
import { SettingsPage } from './SettingsPage';
import { MusicPage } from './MusicPage';

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
/** 「音乐」页在底部页签中的下标：媒体库 / 视频 / 音乐 / 设置 —— 三个"内容"页签相邻，设置收尾 */
const kMusicTabIndex: number = 2;
/** 「设置」页在底部页签中的下标 */
const kSettingsTabIndex: number = 3;
/**
 * 挖孔（刘海/胶囊）避让高度的 `AppStorage` 键。
 *
 * 外壳把 `WindowFullscreen.insets(win, false).top` 写进来，`AppTopBar` / `PageHeader`
 * 用 `@StorageProp` 读它做顶部内缩 —— 沉浸式下系统不再替应用避让，这一步必须自己做。
 */
const kTopInsetKey: string = 'shellTopInsetVp';

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
  /** 窗口实例：铺满整屏（全部页签）与沉浸式全屏（「视频」页）都依赖它 */
  private windowRef: window.Window | null = null;
  /** 当前是否为「视频」页应用了沉浸式全屏（记录状态，便于排查） */
  private immersiveForVideoTab: boolean = false;
  /**
   * 沉浸式下「视频」页顶部要避让的像素（vp，来自挖孔）—— 交给页面自己的工具层用。
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
  /**
   * 底部「正在播放」迷你条的状态（音乐由 `MusicPlayback` 单例持有，本页只是它的一个视图）。
   *
   * 为什么外壳要持有这些：音乐播放已经与播放页解耦（见 `common/MusicPlayback`），
   * 用户离开播放页后仍在播 —— 得有个常驻入口让他看得见、暂停得了、回得去。
   */
  @State private miniVisible: boolean = false;
  @State private miniTitle: string = '';
  @State private miniArtist: string = '';
  @State private miniCover: string = '';
  @State private miniPlaying: boolean = false;
  private miniTimer: number = -1;

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
    // 先把挖孔避让的键建出来：`@StorageProp` 只在键**已存在**时才会收到后续更新，
    // 顶栏组件在本方法之后就会绑定，晚一步建键会让它们永远拿不到那个值（踩过一次）。
    AppStorage.setOrCreate(kTopInsetKey, 0);
    // 迷你条跟随播放服务：外壳存活期间一直轮询（1s 一次足够 —— 条上不显示进度），
    // 播放页与迷你条看到的是同一份状态，谁在前台都不会出现"两套播放状态"。
    this.syncMiniBar();
    this.miniTimer = setInterval(() => {
      this.syncMiniBar();
    }, 1000);
    // 窗口实例提前取回：外壳要立刻进沉浸式（三个页签都铺满整屏），
    // 不能等到用户切页签时才开始异步取
    window.getLastWindow(getContext(this) as common.UIAbilityContext).then((win: window.Window) => {
      this.windowRef = win;
      this.applyChromeForTab(this.shellTabIndex);
      // 系统底部导航条的底色跟着应用走（部分机型/窗口模式下系统条是不透明的，
      // 不改颜色就会在页签行下面压出一条异色横带）
      WindowFullscreen.styleNavigationBarWith(win, this.colors().cardBackground);
    }).catch(() => {
      // 取不到窗口时页面仍可用，只是不沉浸（不做静默假设）
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
   * 外壳销毁（退出登录等）：把窗口还原成系统默认（两条系统栏都回来、取消沉浸式）。
   *
   * 为什么必须还原：沉浸式是**窗口级**状态。外壳是压栈路由的底页，一旦它带着"没有系统栏"
   * 退出，而后面的页面（服务器配置 / 登录页）仍按系统常规避让，
   * 那些页面就会顶着一个没人收拾的窗口状态 —— 它们并不走本外壳。
   */
  aboutToDisappear(): void {
    if (this.miniTimer >= 0) {
      clearInterval(this.miniTimer);
      this.miniTimer = -1;
    }
    AppStorage.setOrCreate(kTopInsetKey, 0);
    WindowFullscreen.exit(this.windowRef, this.colors().cardBackground);
  }

  /**
   * 按页签应用窗口外观。
   *
   * 现状（本轮之后）：
   * - 「视频」页：**保留系统状态栏**（隐藏导航栏 + 铺满整屏）—— 顶部 131px 让给系统，
   *   画面与浮层控件都从状态栏下方开始（用户口径："短视频顶部避免侵占系统空间"）；
   * - 「媒体库」「设置」页：全沉浸（隐藏状态栏与导航栏 + 铺满整屏）。
   *
   * 两种模式都隐藏导航栏，底部页签行都贴在屏幕最底边，PR #54/#56 的结论不受影响。
   *
   * 为什么非沉浸式页签当初也要铺满（用户口径："媒体库和设置页没有侵入底部空间，比视频页高"）：
   * 应用只能在**自身内容框**内接收点击。非沉浸式窗口的内容框被系统按可见系统栏内缩
   * （模拟器实测底部少 94px），底部页签行因此停在 y=2750，而沉浸式的「视频」页内容铺满整屏、
   * 页签行在 y=2655..2844 —— 同一个页签行在两处差了整整一个系统导航条。
   * 把它"画"下去没用：内容框外的部分**画得出来但点不动**（实测：负下边距把页签行推到
   * y=2656..2844 后，从非沉浸式页签点它的下半部分完全无响应；单独关掉系统导航条也一样）。
   *
   * 注意"铺满 + 保留状态栏"这一档**不能用在画了外壳顶栏的页签上**：实测该模式下平台会把外壳顶栏
   * 压扁（190px → 59px，标题只剩肉眼不可见的 2px），`flexShrink(0)` / `constraintSize({minHeight})`
   * / 插入 0 高度垫片都挡不住。「视频」页签不画外壳顶栏（见 build 里对 kVideoTabIndex 的判断），
   * 所以它可以用这一档；「媒体库」「设置」仍走全沉浸。
   *
   * 沉浸式下顶部不再由系统避让，挖孔（刘海/胶囊）要应用自己躲 —— 见 `kTopInsetKey` 与 `refreshTopInset`。
   *
   * 为什么每次都重新应用、不按"状态没变就跳过"提前返回：播放页 / 详情页会自己进出沉浸式，
   * 它们改的是**同一个窗口**。返回外壳时若按缓存布尔值跳过，窗口就会停在别人留下的状态上。
   * 这些调用都是幂等的，代价可接受。
   */
  private applyChromeForTab(index: number): void {
    const wantImmersive: boolean = index === kVideoTabIndex;
    // 离开「视频」页签时收回主动全屏：底部页签栏必须回来，否则用户没有切页签的入口
    // （页面自己也会在 `onTabIndexChanged` 里收回，这里是外壳侧的兜底，两条路都堵住）
    if (!wantImmersive) {
      this.videoFullscreen = false;
    }
    this.immersiveForVideoTab = wantImmersive;
    // 「视频」页保留系统状态栏（顶部 131px 让给系统，页面内容整体从状态栏下方开始），
    // 其余页签全沉浸；两种模式都隐藏导航栏，底部页签行都贴屏幕最底边。
    const win: window.Window | null = this.windowRef;
    const applied: Promise<FullscreenResult> = wantImmersive
      ? WindowFullscreen.enterWithStatusBar(win)
      : WindowFullscreen.enter(win);
    // 避让必须在系统栏状态**切换完成之后**再算：状态栏让不让出直接决定顶部安全区
    // （保留状态栏时挖孔就落在状态栏里，页面自己不用再缩）。先算一次是为了栏还没切完时也有值，
    // 切完再算一次覆盖它 —— 这两次都是幂等的。
    this.refreshTopInset(win, wantImmersive);
    applied.then(() => {
      this.refreshTopInset(win, wantImmersive);
    }).catch(() => {
      this.refreshTopInset(win, wantImmersive);
    });
  }

  /**
   * 重算并下发顶部避让。
   *
   * @param statusBarKept 该页签是否保留了系统状态栏（「视频」页）。
   *
   * 两个值分开用，**不能混**（设备实测的坑，见下）：
   *  - `cutout`：挖孔高度。沉浸式（系统栏已隐藏）的页签要避让它，否则内容被刘海/胶囊压住；
   *  - `statusBarVp`：**整条系统状态栏**的高度。保留状态栏的页签（「视频」页）要避让它。
   *
   * 为什么「视频」页要避让整条状态栏、而不是"挖孔减去状态栏"：
   * 本窗口是 `setWindowLayoutFullScreen(true)`，页面从 **y=0 全屏绘制** ——
   * `dumpLayout` 报的 root `y=132` 只是系统的内容框元数据，**不是绘制原点**。
   * 设备实测（1260×2844，density 3.375；状态栏 rect=[0,0,1260,131]）：
   * 工具行 `padding.top=10vp(34px)` 实际画在 y≈40，与系统时钟/电量（y=25..106）**重叠**；
   * 补偿整条状态栏（39vp）后，工具行落在 y≈165 —— 已在状态栏之下。
   * 挖孔就在状态栏那条里，因此保留状态栏时无需再叠加 `cutout`。
   */
  private refreshTopInset(win: window.Window | null, statusBarKept: boolean): void {
    // 系统栏隐藏后仍要避让挖孔：insets 的 visible 判定在 WindowFullscreen 里统一处理
    const cutout: number = WindowFullscreen.insets(win, false).top;
    // 压栈页面（详情/播放/设置…）与外壳顶栏都按挖孔内缩
    AppStorage.setOrCreate(kTopInsetKey, cutout);
    // 「视频」页的工具行是压在画面上的浮层，另行按整条状态栏内缩
    this.videoTopInsetVp = statusBarKept ? WindowFullscreen.statusBarTopVp(win) : cutout;
  }

  private colors(): ThemeColors {
    this.themeTick;
    return AppViewModel.getInstance().colors();
  }

  /**
   * 把播放服务状态同步到迷你条的 @State（只在值变化时回写）。
   *
   * 只取条上要显示的四项：曲名、副标题（艺术家，取不到就用专辑名）、封面、播放中。
   */
  private syncMiniBar(): void {
    const s: MusicPlaybackState = MusicPlayback.getInstance().snapshot();
    if (this.miniVisible !== s.hasTrack) {
      this.miniVisible = s.hasTrack;
    }
    const title: string = s.currentTrackName();
    if (this.miniTitle !== title) {
      this.miniTitle = title;
    }
    let artist: string = s.artistName;
    if (artist.length === 0) {
      artist = s.albumName;
    }
    if (this.miniArtist !== artist) {
      this.miniArtist = artist;
    }
    if (this.miniCover !== s.coverUrl) {
      this.miniCover = s.coverUrl;
    }
    if (this.miniPlaying !== s.playing) {
      this.miniPlaying = s.playing;
    }
  }

  private openMusicPlayer(): void {
    router.pushUrl({ url: 'pages/MusicPlayerPage' });
  }

  /**
   * 底部「正在播放」迷你条。
   *
   * 为什么需要它：音乐播放已与播放页解耦（离开播放页继续播），没有这条就"看不到、暂停不了、
   * 回不去"。点信息区回播放页（不带参数 = 挂载到当前曲目，不会重头播），右侧是暂停/下一首/关闭。
   *
   * 关闭（×）是**停止播放并释放**：上报已停止 + 结束长时任务 + 销毁 AVSession（见 MusicPlayback.stop），
   * 不是"收起这一条"—— 否则音乐会一直在后台播着却没有任何入口。
   */
  @Builder
  MiniPlayerBar() {
    Column() {
      Divider()
        .color(this.colors().divider)
        .strokeWidth(0.5)
      Row({ space: 8 }) {
        Row({ space: 10 }) {
          JellyfinImage({
            url: this.miniCover,
            imgWidth: 40,
            imgHeight: 40,
            cornerRadius: 6,
            placeholderIcon: 'music'
          })
          Column({ space: 2 }) {
            Text(this.miniTitle)
              .fontSize(ThemeConstants.META_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .width('100%')
            if (this.miniArtist.length > 0) {
              Text(this.miniArtist)
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
                .width('100%')
            }
          }
          .layoutWeight(1)
          .alignItems(HorizontalAlign.Start)
        }
        .layoutWeight(1)
        .height('100%')
        .onClick(() => {
          this.openMusicPlayer();
        })

        AppIconButton({
          icon: this.miniPlaying ? $r('sys.symbol.pause') : $r('sys.symbol.play_fill'),
          variant: 'ghost',
          iconSize: 22,
          onTap: () => {
            MusicPlayback.getInstance().togglePlay();
          }
        })
        AppIconButton({
          icon: $r('sys.symbol.forward_end_fill'),
          variant: 'ghost',
          iconSize: 20,
          onTap: () => {
            MusicPlayback.getInstance().playNext();
          }
        })
        AppIconButton({
          icon: $r('sys.symbol.xmark'),
          variant: 'ghost',
          iconSize: 18,
          onTap: () => {
            MusicPlayback.getInstance().stop();
            this.syncMiniBar();
          }
        })
      }
      .width('100%')
      .height(64)
      .padding({ left: ThemeConstants.PAGE_PADDING, right: 4 })
    }
    .width('100%')
    .backgroundColor(this.colors().cardBackground)
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
        this.shellTabIndex = kVideoTabIndex;
      })
      // 「音乐」同上（与底部页签同一入口）
      this.DrawerItem('音乐', $r('sys.symbol.music'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = kMusicTabIndex;
      })
      this.DrawerItem('继续观看', $r('sys.symbol.play_circle'), () => { this.pushPage('pages/ContinueWatchingPage'); })
      this.DrawerItem('播放列表', $r('sys.symbol.list_bullet'), () => { this.pushPage('pages/PlaylistsPage'); })
      this.DrawerDivider()
      if (AppViewModel.getInstance().isAdmin) {
        this.DrawerItem('控制台', $r('sys.symbol.gearshape'), () => { this.openAdmin(); })
      }
      this.DrawerItem('设置', $r('sys.symbol.gearshape'), () => {
        this.drawerOpen = false;
        this.shellTabIndex = kSettingsTabIndex;
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
    // 外壳根容器铺满整屏，底色用页签行的颜色（`cardBackground`）。
    //
    // 为什么底色要铺到屏幕最底边：三个页签现在都是**整屏沉浸式**（见 `applyChromeForTab`），
    // 内容区就是 0..屏幕高，页签行落在最底边；根容器这一层保证页签行下方不会露出任何系统底色
    // （浅色机型上系统底是纯白，露出来就是一条突兀的白带 —— 上轮实测过）。
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

            // 「音乐」页：音乐库的固定入口。音乐是本应用里少见的"点一首就播"的长内容形态，
            // 原来只能在「媒体库」页签里横滑到最右找到那张卡；四个视角的内容复用
            // `LibraryContentView`（见 MusicPage 与 LibraryPage 的壳/内容说明）。
            TabContent() {
              MusicPage({ themeTick: $themeTick })
            }
            .tabBar('音乐')

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
            // 「正在播放」迷你条：播放与播放页解耦后，用户离开播放页也能看到/控制/回到播放
            if (this.miniVisible) {
              this.MiniPlayerBar()
            }
            Row() {
              this.TabItem(0, $r('sys.symbol.square_grid_2x2'), $r('app.string.tab_library'))
              this.TabItem(1, $r('sys.symbol.play_circle'), '视频')
              this.TabItem(kMusicTabIndex, $r('sys.symbol.music'), '音乐')
              this.TabItem(kSettingsTabIndex, $r('sys.symbol.gearshape'), $r('app.string.nav_settings'))
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
          // 顶栏的人形图标 = 账号入口，落在「设置」页
          this.shellTabIndex = kSettingsTabIndex;
        }
      })
    }
  }
}
