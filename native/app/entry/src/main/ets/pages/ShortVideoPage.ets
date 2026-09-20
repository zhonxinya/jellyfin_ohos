import router from '@ohos.router';
import media from '@ohos.multimedia.media';
import display from '@ohos.display';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { PlaybackState } from '../common/PlaybackState';
import { PlayerAspect, kScaleTypeFit, kScaleTypeFitCrop } from '../common/PlayerAspect';
import { WindowFullscreen, PlayerOrientation } from '../common/WindowFullscreen';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { MediaItem } from '../models/MediaItem';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';
import { ShortVideoPrefs, kShortVideoBatchSize } from '../common/ShortVideoPrefs';
import { formatSeconds, stripMarkup } from '../common/format';
import { JellyfinImage } from '../components/JellyfinImage';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';

/** 「视频」页在外壳底部页签中的下标（媒体库 / 视频 / 设置） */
const kVideoTabIndex: number = 1;

/**
 * 诊断日志域与标签。
 *
 * 为什么短视频页也要留痕：这一页的失败模式几乎都是"看不见的"——
 * 取流失败、编码不支持、转码流起播卡住、手势被浮层吃掉，画面上都只表现为
 * "停在某一帧"。设备实测（模拟器 + hilog）是唯一能把它们区分开的途径。
 */
const LOG_DOMAIN: number = 0x0000;
const LOG_TAG: string = 'JellyfinShortVideo';

/**
 * 单条播放失败后自动跳过下一条的等待时间（毫秒）。
 *
 * 短视频流的体验前提是"一直在放"：某一条硬解、软解都拿不下来（取流失败、编码不支持）时，
 * 停在原地等用户点一下就等于流程断了。因此如实提示后自动跳过，
 * 同时给出「去播放页」入口（那里有更完整的软解/转码回退）。
 */
const kAutoSkipMs: number = 4000;

/** 自动跳过倒计时的刷新间隔：文案要一秒一跳，不能是一个静态的"4 秒后跳过" */
const kSkipTickMs: number = 1000;

/** 进度上报节流（与播放页一致：5 秒一次 + 关键节点补发） */
const kReportIntervalMs: number = 5000;

/** 页内软解的拉帧下限间隔（与播放页同一套自调度思路：上一帧完成即排下一帧） */
const kSoftPullMinGapMs: number = 8;

/** 双击两侧的跳转步长（与播放页同一口径：±10 秒） */
const kSkipStepMs: number = 10000;

/**
 * 双击判定窗口（毫秒）。
 *
 * 350 而不是播放页的 300：设备实测用 `uitest uiInput doubleClick` 注入的两次点按间隔
 * 约 304ms（日志时间戳实测），300 的窗口会把它们判成两次单击 —— 真机上"双击慢一点"
 * 也会同样失效。放宽到 350 才能覆盖"人手没那么快"的情况。
 */
const kDoubleTapMs: number = 350;

/**
 * 单击动作延后执行的时间。
 *
 * **必须大于 `kDoubleTapMs`**：单击是"暂停/继续"，如果它先于双击判定执行，
 * 一次双击就会先暂停、再快进 10 秒 —— 用户看到的是"双击之后画面停了"。
 * 设备实测踩到过这个坑（260 < 304 时，双击被拆成"暂停 + 继续"）。
 */
const kSingleTapDelayMs: number = 380;

/** 双击跳转提示的停留时间 */
const kSeekHintMs: number = 1200;

/**
 * 起播看门狗：超过这么久还没出画面就当作这条播不了。
 *
 * 为什么需要：取流卡住或编码不支持时，`AVPlayer` 有"既不进 playing、也不报 error"的
 * 静默状态（转码流起播、弱网时都遇到过）。没有看门狗的话，用户看到的是一块黑屏 + 转圈，
 * 而且**永远不会自己好** —— 这与"刷"的心智直接冲突。
 */
const kPrepareTimeoutMs: number = 15000;

/**
 * 播放中多久没交互就把上下控件藏起来（毫秒）。
 *
 * 短视频是"一直在放"的场景：顶栏与底部信息长期挂在画面上既挡画面也容易误触，
 * 主流做法是"播放一会儿自动让位、一碰就回来"。4 秒是"刚点完还能看清、又不至于赖着不走"的折中。
 */
const kChromeAutoHideMs: number = 4000;

/**
 * 距离列表末尾还剩几条时就去取下一批。
 *
 * 为什么不是"滑到底再取"：滑到底才开始请求，中间必然出现一段空白等待；
 * 提前几条取，用户感知上就是"刷不完"。
 */
const kAppendAhead: number = 4;

/**
 * 手势遮罩的"非画面区"尺寸（vp）—— 落在这些区域里的点按不当作"点画面暂停/双击快进"。
 *
 * 为什么需要：工具行与操作栏的按钮是叠在画面上的浮层，浮层容器（透明、铺满整屏）
 * 与手势层是**兄弟节点**，一次点按会同时到达两者（因此浮层容器用
 * `HitTestMode.Transparent` 而不是默认值，否则按钮点不动）。也就是说"点按钮会不会顺带
 * 暂停"必须由手势层按坐标自己判断 —— 位置判定与事件顺序无关，比"按钮按下时打标记"可靠。
 */
const kTopChromeVp: number = 64;
const kBottomChromeVp: number = 108;
const kRailWidthVp: number = 84;
const kRailHeightVp: number = 380;
/**
 * 横屏下"底部控件带"的高度（vp）。
 *
 * 横屏可用高度只有 ~306vp（2844×1071px 的画面区），操作栏是横排的一行，
 * 因此整条底部带都算控件区 —— 竖屏那套"右侧一列"的判定放到横屏会把大半画面吃掉。
 */
const kLandscapeBottomVp: number = 92;

/**
 * 「视频」页 —— 短视频模式的承载页（底部导航第二个页签）。
 *
 * 心智与动线：短视频是"打开就刷"，与"进库 → 找片子 → 进详情 → 播放"是两条完全不同的
 * 动线；混在一个页面里会让两侧都变复杂。这里只做一件事：把**设置里勾选的短视频媒体库**
 * 随机抽出来，一屏一条、竖屏满屏连播，上下滑动切换、点画面暂停、双击两侧 ±10 秒。
 *
 * 视觉（本轮美化）：
 * - **画面铺满整屏**：外壳在「视频」页不再画自己的顶栏（见 `MainShell.build`），
 *   工具行/操作栏做成压在画面上的浮层（顶部/底部渐变 scrim 保证文字可读），
 *   页面不再是"顶栏 + 工具行 + 一小块画面"的三明治结构；
 * - **环境背景**：竖屏是 20:9 的窄长屏，横片按"适应"缩放后四周本来是两条纯黑边；
 *   现在把当前封面铺满、压暗后垫在视频面之下，观感上是"一整块画面"而不是"黑框"；
 * - **右侧操作栏**：收藏 / 已看 / 详情 / 换一批 收到右手边的竖排圆形按钮里，
 *   底部只留标题与元信息（此前是两个大按钮 + 页码挤在文字旁边）；
 * - **底部进度**：细进度线 + `已看 / 总时长`，能看出"还剩多少"。
 *
 * 弹幕式连播的实现要点见各方法注释（页内 AVPlayer + FFmpeg 软解回退 + 无限流追加）。
 */
@Component
export struct ShortVideoPage {
  @Link themeTick: number;
  /**
   * 外壳传来的"重读配置"信号（切到「视频」页签时自增）。
   *
   * 见 `MainShell.videoTabTick` 的说明：本页是从设置页返回后**不会重建**的嵌入式组件，
   * 只能靠外部信号触发重读。
   */
  @Prop @Watch('onRefreshTick') refreshTick: number = 0;
  /** 是否嵌在外壳里（当前恒为 true；保留参数便于以后单独路由打开） */
  @Prop embedded: boolean = true;
  /** 外壳当前页签下标：非「视频」页时暂停播放（见 onTabIndexChanged） */
  @Prop @Watch('onTabIndexChanged') activeTab: number = kVideoTabIndex;
  /**
   * 沉浸式全屏下工具层要避让的顶部像素（vp）。
   *
   * 「视频」页默认全屏沉浸式（外壳已隐藏系统栏）：**画面铺满整屏**，
   * 但工具行不能被挖孔或状态栏压住，因此浮层按这个值内缩。
   */
  @Prop topInsetVp: number = 0;

  @State private status: string = UiState.INITIAL;
  @State private errorMsg: string = '';
  @State private items: MediaItem[] = [];
  @State private currentIndex: number = 0;
  /** 已选媒体库的名称（用于顶部说明"内容来自哪儿"；id 才是配置，名称只用于展示） */
  @State private libraryNames: string[] = [];
  @State private refreshing: boolean = false;
  /** 本次取数所用的媒体库选择（用于判断"切回本页时配置是否变了"） */
  private loadedLibraryIds: string[] = [];

  // ─────────────────────────── 页内播放（短视频的核心）───────────────────────────
  //
  // 为什么必须页内播放而不是"点一下跳播放页"：短视频的心智是**连续**刷 ——
  // 每条都要退回上一页再点开，动线立刻就断了。这里给「视频」页自己一个
  // XComponent + AVPlayer：滑到哪条就自动播哪条，播完自动下一条，单击暂停/继续。
  // 直连在本机解不了时，先让**服务器解码**（强制转码）再试一次；仍不行才用 FFmpeg 软解接着播
  // （见 onItemFailed / startSoftPlayback）。
  /** XComponent 控制器：surface 就绪后取 surfaceId 交给 AVPlayer */
  private surfaceController: XComponentController = new XComponentController();
  private surfaceId: string = '';
  private avPlayer: media.AVPlayer | null = null;
  /** 当前正在播的条目 id（用于切换时补发 stopped，避免服务端会话堆积） */
  private playingItemId: string = '';
  @State private videoReady: boolean = false;
  @State private paused: boolean = false;
  @State private positionMs: number = 0;
  @State private durationMs: number = 0;
  /** 当前条目播放失败的原因（非空即显示失败浮层 + 自动跳过倒计时） */
  @State private playbackError: string = '';
  /**
   * 当前这一条的播放方式（`DirectPlay` / `DirectStream` / `Transcode`）。
   *
   * 为什么要显示出来：用户选了「720p」却还在放原画、或服务端转码失败退回直连时，
   * **画面上看不出任何区别** —— 这是"设置到底生效没有"的唯一可见证据。
   */
  @State private playMethod: string = '';
  /**
   * 本条是否已经用掉**唯一一次"换条路再试"**的机会（见 `onItemFailed`）。
   *
   * 为什么只给一次：两条坏路之间来回弹会把"刷"变成"等"，而且用户在失败卡片上看到的是
   * 反复重试却始终不出画面。一次换路之后仍失败就交给本机软解 / 自动跳过。
   */
  private retryTried: boolean = false;
  /** 当前播放地址是不是 HLS（`.m3u8`）—— 转码流的判据之一（另一个是 playMethod） */
  private lastUrlWasHls: boolean = false;
  /** 是否已滑到列表末尾且**再也取不到新内容**（末尾给"换一批"，不假装永远刷不完） */
  @State private reachedEnd: boolean = false;
  /** 正在准备当前条目（取流 / 建播放器 / 缓冲）：显示转圈，避免"点了没反应"的观感 */
  @State private preparing: boolean = false;
  /**
   * 上下控件（顶部工具行 / 底部信息与操作栏）当前是否显示。
   *
   * 播放中会自动隐藏（见 `kChromeAutoHideMs`），任何点按/滑动都把它们唤回来 ——
   * 这是"画面优先"的短视频该有的样子：控件是临时浮层，不是常驻栏。
   * 暂停、起播失败、正在准备时**始终显示**（那时用户需要看到状态与按钮）。
   */
  @State private chromeVisible: boolean = true;
  private chromeHideTimerId: number = -1;
  /** 自动跳过倒计时的剩余毫秒（0 = 不显示倒计时） */
  @State private skipLeftMs: number = 0;
  /** 双击快进的瞬时提示（非空即显示） */
  @State private seekHint: string = '';
  /**
   * 已收藏 / 已看的条目 id。
   *
   * 为什么用页面级 @State 而不是直接改 `MediaItem` 上的字段：`MediaItem` 是普通类实例，
   * 改字段不会触发渲染；把"哪些 id 是收藏/已看"放进 @State 数组后，
   * 按钮上读到它的那些属性（图标、配色、文案）会在操作完成后自行刷新。
   */
  @State private favoriteIds: string[] = [];
  @State private playedIds: string[] = [];
  private progressTimerId: number = -1;
  /** 当前这次暂停是否由"切走页签"造成（决定切回时是否自动续播） */
  private pausedByTabSwitch: boolean = false;
  /** 起播看门狗（见 kPrepareTimeoutMs） */
  private prepareWatchdogId: number = -1;
  /** 自动跳过倒计时定时器 */
  private skipTickId: number = -1;
  /** 双击提示的收起定时器 */
  private seekHintTimerId: number = -1;
  /** 是否已把窗口设为常亮（成对调用，离页要还原） */
  private screenOnApplied: boolean = false;
  /**
   * 取数代次：每次"换一批/重新加载"自增。
   *
   * 为什么需要：追加下一批是异步的（逐库请求），期间用户可能点了「换一批」把列表换成
   * 新的一批；不校验代次的话，追加请求返回后会把**上一批**的内容接到新列表后面。
   */
  private feedGeneration: number = 0;
  /** 追加请求在途（避免连续滑动时并发拉同一批） */
  private appending: boolean = false;
  /**
   * "正在为末尾补内容"（渲染用）。
   *
   * 为什么需要它：滑到末尾时先给 `reachedEnd`、再异步去取下一批，如果直接按
   * `reachedEnd` 渲染，取数那几百毫秒里会先闪一下「这批已经看完了」——
   * 而这批其实还没完。这个标记是 @State，取数结束才让「看完了」露出来。
   */
  @State private appendPending: boolean = false;
  /** 追加已经取不到新内容（服务端确实没有更多了），不再反复请求 */
  private exhausted: boolean = false;
  /**
   * 最近一次批量取数的错误信息。
   *
   * 为什么用字段而不是"出参字符串"：ArkTS 的 string 是按值传递的，早先版本把错误
   * 写进出参变量，调用方拿到的永远是空串 —— 结果是"取数失败"被当成"库里没有内容"，
   * 该给「重试」的时候给了「去设置」。
   */
  private batchError: string = '';
  /** 双击判定状态（与播放页同一套：单击延后执行，双击会取消待执行的单击） */
  private lastTapUpAt: number = 0;
  private lastTapX: number = 0;
  private singleTapTimerId: number = -1;

  // ─────────────────────── 横屏观看 ───────────────────────
  //
  // 短视频内容横竖皆有；横屏时同一个"适应"盒子计算会给出**更大的画面**
  // （可用区域从 20:9 的窄长变成宽屏），因此除了跟随传感器，还要给一个显式锁定入口
  // （躺卧观看时传感器会被机身姿态反复打断）。窗口实例与方向都复用播放页那套
  // `WindowFullscreen`，不另起一套平台调用。
  /** 窗口实例（方向控制 / 屏幕常亮都需要） */
  private windowRef: window.Window | null = null;
  /** 方向选择：跟随系统 / 横屏 / 竖屏 */
  @State private orientation: PlayerOrientation = 'auto';
  /** 进入本页签之前窗口的首选方向（离开页签时还原；<0 表示还没记录） */
  private savedOrientationValue: number = -1;

  // ─────────────────────── 主动全屏 ───────────────────────
  //
  // 与"进「视频」页就自动沉浸"（外壳隐藏系统栏）不是一回事：那是**被动**的默认态，
  // 底部仍留着外壳的 56vp 页签栏，画面只占 2655/2844px。主动全屏是用户按一下按钮，
  // **横屏 + 页签栏让位**，画面真正铺满整屏；再按一次回到进全屏之前的样子。
  //
  // 为什么页签栏要由外壳来收：它是 `MainShell` 画的（本页是嵌在 Tabs 里的组件），
  // 因此这里用 `@Link` 回写一个信号给外壳，由外壳决定画不画那一条。
  /** 是否处于主动全屏（= 横屏 + 外壳底部页签栏收起） */
  @Link fullscreenActive: boolean;
  /**
   * 进全屏之前的方向选择，退出全屏时还原；`null` 表示当前不在全屏。
   *
   * 为什么单独存一份而不是直接改偏好：全屏是"这一刻要铺满看"的临时动作，
   * 不该把用户「跟随系统 / 竖屏」的长期偏好改成横屏（偏好由「方向」按钮负责写）。
   */
  private orientationBeforeFullscreen: PlayerOrientation | null = null;
  /**
   * 全屏时底部控件要给系统手势提示条让出的高度（vp）。
   *
   * 页签栏收起后，本页的底部信息/进度第一次直接落在屏幕底边 —— 那一条上系统还会画
   * 手势提示条（沉浸式下系统栏已隐藏，但提示条仍在画）。让出它才不会压住标题与进度线。
   * 由本页自己量（窗口实例在本页手里，方向控制已在用）。
   *
   * 平台实测（模拟器 127.0.0.1:5555，进全屏时探针打印）：
   * `TYPE_NAVIGATION_INDICATOR` 报 **visible=1 但 bottomRect.height=0**、
   * `TYPE_SYSTEM` 同样是 0 —— 沉浸式下系统把避让区尺寸清零，"可见"并不带尺寸。
   * 因此这个值**在本机恒为 0**（等于不额外留白），保留它的意义是真机手势导航下若报出真实高度，
   * 底部就不会压在提示条上；本机横屏全屏实测底部也没有提示条绘制（截图逐行扫描未见），不存在重叠。
   */
  @State private fullscreenBottomInsetVp: number = 0;

  // ───────────────── 页内软解回退（硬解不支持时不再跳过）─────────────────
  //
  // 为什么能在本页做软解：软解需要一块 EGL 可渲染的显示面，本页的 XComponent 就有
  // （`surfaceId` 路径由原生侧自行创建 window）。**不需要**播放页那块
  // `OH_NativeXComponent` 桥 —— 那是全进程单例，两页同时用会互相抢状态。
  // 渲染器单例按"surfaceId 是否一致"校验复用（见 boundToSurfaceId），因此
  // 播放页与本页可以轮流接管同一个渲染器。
  /** 当前条目是否正走页内软解 */
  @State private softActive: boolean = false;
  private softPulling: boolean = false;
  private softPullTimerId: number = -1;
  /** XComponent 的像素尺寸（软解渲染缓冲几何按它协商） */
  private surfaceW: number = 0;
  private surfaceH: number = 0;

  // ───────────────── 画面比例（竖屏比例不对的修复）─────────────────
  //
  // 此前的做法是"XComponent 铺满整屏 + `videoScaleType = FIT_CROP`"：
  // 竖屏是 20:9 的窄长屏，而内容多为 16:9 / 2.35:1 的横片 —— 等比铺满意味着**横向被裁掉大半**
  // （观感就是"比例不对/画面被切"）；而一旦设备不支持该属性（setter 抛错被兜住），
  // AVPlayer 默认的 `VIDEO_SCALE_TYPE_FIT` 是**拉伸铺满**，直接变形。
  // 现在改成播放页那套已经验证过的做法：**把视频面的宽高比算成与画面一致**，
  // 再把 scaleType 设为 FIT —— 同比例的 FIT 没有可拉伸/可裁剪的余地，比例必然正确。
  /** 画面原始像素尺寸（硬解来自 AVPlayer.width/height，软解来自 softPlayOpen 返回值） */
  @State private videoW: number = 0;
  @State private videoH: number = 0;
  /** 可用区域（vp，来自根容器实测）：横竖屏切换后会变，画面盒子随之重算 */
  @State private areaW: number = 0;
  @State private areaH: number = 0;
  /** 当前是否横屏（宽 > 高）：控件布局与画面盒子都按它走 */
  @State private landscape: boolean = false;
  /** 页内软解的解码目标宽度（对齐协商出的渲染缓冲） */
  private softDecodeMaxWidth: number = 0;
  private lastReportAt: number = 0;

  aboutToAppear(): void {
    // 恢复上次的方向选择（横竖屏是用户偏好，见 ShortVideoPrefs.loadOrientation）
    const saved: string = ShortVideoPrefs.loadOrientation();
    this.orientation = saved === 'landscape' ? 'landscape'
      : (saved === 'portrait' ? 'portrait' : 'auto');
    this.loadFeed();
    // 只在本页签真的处于激活状态时应用方向：嵌入式组件在别的页签上被创建时
    // 不该把整个窗口转过去
    if (this.activeTab === kVideoTabIndex && this.orientation !== 'auto') {
      this.applyOrientation();
    }
  }

  aboutToDisappear(): void {
    this.stopProgressTicker();
    this.cancelAutoSkip();
    this.cancelChromeAutoHide();
    this.clearPrepareWatchdog();
    this.cancelPendingTap();
    this.hideSeekHint();
    this.stopSoftPlayback();
    this.releasePlayer();
    this.applyScreenOn(false);
  }

  /**
   * 外壳页签变化：离开「视频」页就暂停播放。
   *
   * 为什么必须处理：本页是嵌入式组件，切到"设置"页签时它**不会销毁** ——
   * 不暂停的话用户会在设置页里听到短视频的声音（而且看不见画面，无从暂停）。
   */
  onTabIndexChanged(): void {
    if (this.activeTab !== kVideoTabIndex) {
      // 离开本页不再需要屏幕常亮（用户在看别的页面）
      this.applyScreenOn(false);
      // 主动全屏要收回：底部页签栏是外壳画的，留着"收起"状态用户就切不回别的页签
      this.leaveFullscreenState();
      // 方向也是窗口级的：离开本页签要还原，否则「媒体库/设置」会跟着横屏
      this.restoreOrientationOnLeave();
      if (this.softActive) {
        // 软解：切走即停帧循环（回来自会自动续上，见下面 else 分支）
        this.stopSoftPullLoop();
        return;
      }
      // 只对"因切页签而暂停"做标记：用户自己按暂停的，切回来不该被自动续播
      if (this.avPlayer !== null && !this.paused) {
        this.pausePlayback();
        this.pausedByTabSwitch = true;
      }
      return;
    }
    // 切回本页：软解重启帧循环；硬解用 `play()` 续播（**不是** `playCurrent()`，后者会从头重开）
    // 方向也要重新应用（离开页签时还原过，见 restoreOrientationOnLeave）：
    // 放在分支之前，软解/硬解两条路径都会走到
    if (this.orientation !== 'auto') {
      this.applyOrientation();
    }
    if (this.softActive) {
      if (!this.paused) {
        this.startSoftPullLoop();
        this.startProgressTicker();
        this.applyScreenOn(true);
      }
      return;
    }
    if (this.pausedByTabSwitch && this.avPlayer !== null) {
      this.pausedByTabSwitch = false;
      try {
        this.avPlayer.play();
        this.applyScreenOn(true);
      } catch (err) {
        // 播放器可能已不可用：下一次滑动会重建
      }
    }
  }

  /**
   * 外部信号（切到本页签）：只在**配置真的变了**或当前没有内容时才重新取数。
   *
   * 为什么不每次切页签都重取：短视频流是随机的，来回切页签会导致"刚看的那条不见了"；
   * 只有用户改了媒体库选择（或本来就没内容）才需要换一批。
   */
  onRefreshTick(): void {
    const ids: string[] = ShortVideoPrefs.loadLibraryIds();
    if (!this.sameLibrarySelection(ids)) {
      this.loadFeed();
      return;
    }
    if (this.status === UiState.EMPTY || this.status === UiState.ERROR ||
      this.items.length === 0) {
      this.loadFeed();
    }
  }

  private sameLibrarySelection(ids: string[]): boolean {
    if (ids.length !== this.loadedLibraryIds.length) {
      return false;
    }
    for (let i = 0; i < ids.length; i++) {
      if (ids[i] !== this.loadedLibraryIds[i]) {
        return false;
      }
    }
    return true;
  }

  private colors(): ThemeColors {
    this.themeTick;
    return AppViewModel.getInstance().colors();
  }

  // ─────────────────────────── 取数 ───────────────────────────

  /**
   * 换一批：重新随机取数并从头开始刷。
   *
   * 取数策略：**每个已选媒体库各取一批、再合并**，而不是"一次请求多个库"——
   * Jellyfin 的 `/Items` 只接受单个 `ParentId`（多选父级要拼 `Ids` 且语义不同），
   * 逐库取也便于把某个库的失败隔离开（一个库挂了不影响其它库出内容）。
   * `SortBy=Random` 由服务端随机排序，天然满足"每次刷新不重样"。
   */
  private async loadFeed(): Promise<void> {
    const libraryIds: string[] = ShortVideoPrefs.loadLibraryIds();
    if (libraryIds.length === 0) {
      this.status = UiState.EMPTY;
      this.items = [];
      this.currentIndex = 0;
      this.stopPlaybackForEmptyFeed();
      return;
    }
    // 作废在途的追加请求（见 feedGeneration 的说明），并允许重新追加
    this.feedGeneration = this.feedGeneration + 1;
    this.appending = false;
    this.appendPending = false;
    this.exhausted = false;
    this.loadedLibraryIds = libraryIds;
    this.status = this.items.length > 0 ? UiState.REFRESHING : UiState.LOADING;
    this.refreshing = true;
    this.errorMsg = '';
    this.libraryNames = await this.resolveLibraryNames(libraryIds);

    // 换一批：不去重"上一批已经出现过的条目"（否则刷过的越多、可换的越少）
    const collected: MediaItem[] = await this.collectBatch(libraryIds, false);
    this.refreshing = false;
    if (collected.length === 0) {
      // 全空有两种可能：所选库里确实没有视频，或请求失败。失败要如实报错（可重试），
      // 空则给"这批库里没有内容"的引导 —— 两者的下一步动作完全不同。
      if (this.batchError.length > 0) {
        this.status = UiState.ERROR;
        this.errorMsg = this.batchError;
      } else {
        this.status = UiState.EMPTY;
      }
      this.items = [];
      this.currentIndex = 0;
      this.stopPlaybackForEmptyFeed();
      return;
    }
    // 逐库内已是随机序；这里再整体洗一次，避免"总是先放第一个库的内容"
    this.items = this.shuffle(collected);
    this.syncUserDataFlags(this.items);
    this.currentIndex = 0;
    this.reachedEnd = false;
    this.status = UiState.SUCCESS;
    // 内容就绪即自动开播第一条（"打开就刷"，不需要用户再点一次）
    this.playCurrent();
  }

  /**
   * 逐库取一批条目并合并。
   *
   * @param dedupeAgainstCurrent 是否剔除"列表里已有的条目"：
   *        追加下一批时必须去重（否则随机取数会把看过的那几条再塞回来，
   *        "刷不完"就变成了"反复刷同几条"）；而「换一批」**不能**去重 ——
   *        那样会把用户已经刷过的内容全部排除，刷得越多、可换的越少。
   *
   * 失败不会让整页失败：某个库报错时记下错误、继续取其它库；错误信息写进
   * `batchError` 供调用方判断"空"是"没内容"还是"取不到"。
   */
  private async collectBatch(libraryIds: string[],
                             dedupeAgainstCurrent: boolean): Promise<MediaItem[]> {
    this.batchError = '';
    const out: MediaItem[] = [];
    for (let i = 0; i < libraryIds.length; i++) {
      const batch: MediaItem[] = await this.fetchLibraryBatch(libraryIds[i]);
      for (let j = 0; j < batch.length; j++) {
        if (this.hasItemId(out, batch[j].id)) {
          continue;
        }
        if (dedupeAgainstCurrent && this.hasItemId(this.items, batch[j].id)) {
          continue;
        }
        out.push(batch[j]);
      }
    }
    return out;
  }

  /**
   * 列表被清空（没配库 / 取数失败 / 取不到内容）时把播放彻底收掉。
   *
   * 为什么必须显式收：状态切到「空态/错误态」后视频层（XComponent）不再参与构建，
   * 但 AVPlayer/软解会话**不会**因此停止 —— 用户会看到错误页却仍听到上一条的声音。
   */
  private stopPlaybackForEmptyFeed(): void {
    this.cancelAutoSkip();
    this.clearPrepareWatchdog();
    this.stopProgressTicker();
    this.stopSoftPlayback();
    this.releasePlayer();
    this.preparing = false;
  }

  /** 单个媒体库取一批条目（失败时登记 `batchError` 并返回空数组） */
  private async fetchLibraryBatch(libraryId: string): Promise<MediaItem[]> {
    const query: ItemsQueryOptions = new ItemsQueryOptions();
    query.parentId = libraryId;
    query.startIndex = 0;
    query.limit = kShortVideoBatchSize;
    // 短视频模式只关心"能直接播的视频类条目"：电影 / 单集 / 视频 / 音乐视频
    query.includeItemTypes = 'Movie,Episode,Video,MusicVideo';
    query.sortBy = 'Random';
    query.recursive = true;
    // 元信息按"卡片上真的要显示什么"取：简介、年份、时长、分级、类型、系列名。
    // 多要字段会让响应变大，少要则卡片上只能是空白（例如没有分级就只能不画那个徽标）。
    query.fields = 'Overview,PrimaryImageAspectRatio,RunTimeTicks,ProductionYear,'
      + 'OfficialRating,Genres,SeriesName';
    query.enableUserData = true;
    const raw: string = await JellyfinNative.queryItems(query.toJson());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      if (this.batchError.length === 0) {
        this.batchError = result.message.length > 0 ? result.message : '取短视频内容失败';
      }
      return [];
    }
    return MediaItem.fromArray(JsonUtil.extractItems(result.data));
  }

  /**
   * 追加下一批（无限流的实现）。
   *
   * @param playIndex 追加成功后要起播的下标（-1 = 只是后台预取，不起播）
   * @returns 新追加的条数（0 表示确实没有新内容了）
   */
  private async appendMore(playIndex: number): Promise<number> {
    if (this.appending || this.exhausted) {
      return 0;
    }
    const libraryIds: string[] = this.loadedLibraryIds.length > 0
      ? this.loadedLibraryIds : ShortVideoPrefs.loadLibraryIds();
    if (libraryIds.length === 0) {
      this.exhausted = true;
      return 0;
    }
    this.appending = true;
    this.appendPending = true;
    const generation: number = this.feedGeneration;
    // 追加必须去重：见 collectBatch 的说明
    const collected: MediaItem[] = await this.collectBatch(libraryIds, true);
    this.appending = false;
    this.appendPending = false;
    // 期间用户点了「换一批」：这批内容属于上一代列表，直接丢弃
    if (generation !== this.feedGeneration) {
      return 0;
    }
    if (collected.length === 0) {
      // 取不到新内容：可能是库里就这么多，也可能是这一轮请求失败。
      // 两者都不该让"刷"卡死 —— 有错误就再给一次机会（不置 exhausted），
      // 没错误说明服务端确实没有更多了。
      this.exhausted = this.batchError.length === 0;
      return 0;
    }
    const more: MediaItem[] = this.shuffle(collected);
    this.items = this.items.concat(more);
    this.syncUserDataFlags(more);
    if (playIndex >= 0) {
      if (playIndex < this.items.length) {
        this.reachedEnd = false;
        this.currentIndex = playIndex;
        this.playCurrent();
      } else {
        this.reachedEnd = true;
      }
    }
    return more.length;
  }

  /** 快到位了就提前取下一批（后台进行，不影响正在播的这条） */
  private prefetchIfNearEnd(): void {
    if (this.exhausted || this.appending) {
      return;
    }
    if (this.currentIndex + kAppendAhead < this.items.length) {
      return;
    }
    this.appendMore(-1);
  }

  private hasItemId(list: MediaItem[], id: string): boolean {
    for (let i = 0; i < list.length; i++) {
      if (list[i].id === id) {
        return true;
      }
    }
    return false;
  }

  /** 把条目自带的收藏/已看状态收进页面级 @State（进新一批时调用） */
  private syncUserDataFlags(list: MediaItem[]): void {
    const favorites: string[] = this.favoriteIds.slice();
    const played: string[] = this.playedIds.slice();
    for (let i = 0; i < list.length; i++) {
      if (list[i].isFavorite && favorites.indexOf(list[i].id) < 0) {
        favorites.push(list[i].id);
      }
      if (list[i].isPlayed && played.indexOf(list[i].id) < 0) {
        played.push(list[i].id);
      }
    }
    this.favoriteIds = favorites;
    this.playedIds = played;
  }

  /** 已选媒体库的名称（取服务器视图列表；取不到就退化为空，不影响出内容） */
  private async resolveLibraryNames(libraryIds: string[]): Promise<string[]> {
    const names: string[] = [];
    try {
      const raw: string = await JellyfinNative.getHomeSection('views', 60);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        return names;
      }
      // 同 ShortVideoSettingsPage：`views` 段返回的就是 `/Views` 原始响应（顶层 `Items`）
      const views: Object[] = JsonUtil.extractItems(result.data as ESObject);
      for (let i = 0; i < libraryIds.length; i++) {
        for (let j = 0; j < views.length; j++) {
          const view: ESObject = views[j] as ESObject;
          if (JsonUtil.getString(view, 'Id', '') === libraryIds[i]) {
            names.push(JsonUtil.getString(view, 'Name', '媒体库'));
            break;
          }
        }
      }
    } catch (err) {
      return [];
    }
    return names;
  }

  /** Fisher–Yates 洗牌：让"每次进来/换一批"的顺序都不同（随机感的来源） */
  private shuffle(list: MediaItem[]): MediaItem[] {
    const out: MediaItem[] = list.slice();
    for (let i = out.length - 1; i > 0; i--) {
      const j: number = Math.floor(Math.random() * (i + 1));
      const tmp: MediaItem = out[i];
      out[i] = out[j];
      out[j] = tmp;
    }
    return out;
  }

  // ─────────────────────────── 播放实现 ───────────────────────────

  /**
   * 播当前这一条：取播放地址 → 建 AVPlayer → 绑 surface → prepare → play。
   *
   * 每一步都可能失败（取流、建播放器、编码不支持…），失败统一走 `onItemFailed`：
   * **换条路再试一次 → 就地软解 → 提示 + 自动跳过**，不让"刷"停下来。
   */
  private async playCurrent(): Promise<void> {
    const item: MediaItem | null = this.currentItem();
    this.cancelAutoSkip();
    // 切条/重开前先把页内软解收掉：硬解与软解不能同时占同一块 surface
    this.stopSoftPlayback();
    this.stopProgressTicker();
    this.releasePlayer();
    this.playbackError = '';
    this.videoReady = false;
    this.paused = false;
    this.positionMs = 0;
    this.durationMs = 0;
    this.playMethod = '';
    this.retryTried = false;
    if (item === null) {
      this.preparing = false;
      return;
    }
    this.preparing = true;
    this.startPrepareWatchdog();
    // 播放参数按"设置里的清晰度"走：具体分辨率档位会让服务端转码，
    // 「自动」则由服务端按本机能力决定直连还是转码（见 ShortVideoPrefs.playbackOptionsJson）。
    const options: string = ShortVideoPrefs.playbackOptionsJson();
    hilog.info(LOG_DOMAIN, LOG_TAG, 'playCurrent item=%{public}s quality=%{public}s',
      item.id, ShortVideoPrefs.qualityShortLabel());
    const raw: string = await JellyfinNative.playerOpen(item.id, options);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.onItemFailed(result.message.length > 0 ? `获取播放地址失败：${result.message}` : '获取播放地址失败');
      return;
    }
    const playUrl: string = JsonUtil.getString(result.data as ESObject, 'playUrl', '');
    // 原生侧把最终采用的播放方式写在 playMethod 上（DirectPlay / DirectStream / Transcode）
    this.playMethod = JsonUtil.getString(result.data as ESObject, 'playMethod', '');
    this.lastUrlWasHls = playUrl.includes('.m3u8');
    hilog.info(LOG_DOMAIN, LOG_TAG, 'playCurrent method=%{public}s hls=%{public}s',
      this.playMethod, this.lastUrlWasHls ? '1' : '0');
    if (playUrl.length === 0) {
      this.onItemFailed('服务器没有给出播放地址');
      return;
    }
    try {
      this.avPlayer = await media.createAVPlayer();
    } catch (err) {
      this.onItemFailed('创建播放器失败');
      return;
    }
    this.playingItemId = item.id;
    this.attachPlayerHandlers(this.avPlayer);
    try {
      this.avPlayer.url = playUrl;
    } catch (err) {
      this.onItemFailed('设置播放地址失败');
    }
  }

  private attachPlayerHandlers(player: media.AVPlayer): void {
    player.on('stateChange', (state: string) => {
      // 切到下一条后旧播放器的事件必须忽略（否则会污染新条目的状态）
      if (this.avPlayer !== player) {
        return;
      }
      if (state === 'initialized') {
        this.bindSurface();
        if (this.surfaceId.length > 0) {
          player.prepare();
        }
        // surface 尚未就绪时由 XComponent.onLoad 补一次 prepare
      } else if (state === 'prepared') {
        if (player.duration > 0) {
          this.durationMs = player.duration;
        }
        // 画面真实尺寸：视频面按它重算宽高比（这是比例正确的前提）
        if (player.width > 0 && player.height > 0) {
          this.videoW = player.width;
          this.videoH = player.height;
        }
        // 设备实测（模拟器）：部分流在 `prepared` 阶段 `AVPlayer.duration` 仍是 0，
        // 于是进度条恒为 0、`已看 / 总时长` 读数根本不出现。
        // 这里如实留痕，便于判断"时长到底是谁给的"（服务端元数据还是播放器）。
        hilog.info(LOG_DOMAIN, LOG_TAG,
          'prepared duration=%{public}d size=%{public}dx%{public}d metaDuration=%{public}d',
          Math.round(player.duration), player.width, player.height,
          Math.round(this.itemDurationMs()));
        try {
          // 视频面已按画面比例设过尺寸 ⇒ 同比例的 FIT 不会拉伸；
          // 若拿不到画面尺寸（videoW/H 仍为 0，面暂时铺满），FIT_CROP 至少保证不出现黑边。
          player.videoScaleType = (this.videoW > 0 && this.videoH > 0)
            ? kScaleTypeFit : kScaleTypeFitCrop;
        } catch (err) {
          // 部分设备不支持该属性：此时靠"视频面与画面同比例"兜底，比例仍然正确
        }
        player.play();
      } else if (state === 'playing') {
        this.videoReady = true;
        this.paused = false;
        this.preparing = false;
        this.clearPrepareWatchdog();
        this.startProgressTicker();
        this.applyScreenOn(true);
        this.reportProgress(false);
        // 起播即开始"无交互自动隐藏"的计时
        this.revealChrome(true);
      } else if (state === 'paused') {
        this.paused = true;
        this.reportProgress(true);
      } else if (state === 'completed') {
        // 播完自动下一条 —— 这是"连续刷"的关键
        this.advance(1);
      } else if (state === 'error') {
        // 实测顺序：`stateChange='error'` 常常先于 `error` 事件到达，此时还拿不到错误码。
        // 文案因此给"人话 + 下一步"，而不是一个光秃秃的"播放出错"。
        hilog.warn(LOG_DOMAIN, LOG_TAG, 'stateChange=error method=%{public}s', this.playMethod);
        this.onItemFailed('本机无法播放该内容（可能是硬解不支持）');
      }
    });
    player.on('error', (err: BusinessError) => {
      if (this.avPlayer !== player) {
        return;
      }
      // 5400106 = 编码不支持（如模拟器上的 HEVC）；801 = 能力不支持。
      // 这类内容并非不可看 —— 本页紧接着会自动改走 FFmpeg 软解（见 onItemFailed）。
      const hint: string = (err.code === 5400106 || err.code === 801)
        ? '本机硬解不支持该编码' : `播放器错误(code=${err.code})`;
      this.onItemFailed(hint);
    });
  }

  /** surface 就绪/状态变化时把 surfaceId 交给播放器（AVPlayer 要求 initialized 及之后才能设） */
  private bindSurface(): void {
    if (this.avPlayer === null || this.surfaceId.length === 0) {
      return;
    }
    const state: string = this.avPlayer.state;
    if (state === 'initialized' || state === 'prepared' || state === 'playing' ||
      state === 'paused' || state === 'completed') {
      try {
        this.avPlayer.surfaceId = this.surfaceId;
      } catch (err) {
        // 状态恰好又变了：下一次事件里会再绑
      }
    }
  }

  /** 单击画面：暂停/继续（控件已隐藏时先唤出控件，不改播放状态） */
  private togglePause(): void {
    // 控件隐藏状态下的一次点按只负责"把控件唤回来"：直接暂停的话，用户会看到
    // "我点了一下想找按钮，画面却停了"。与主流播放器一致（先显控件，再操作）。
    if (!this.chromeVisible) {
      this.revealChrome(true);
      return;
    }
    if (this.softActive) {
      // 软解没有暂停 API：暂停 = 停掉帧循环（画面停在最后一帧），恢复 = 重启帧循环
      if (this.paused) {
        this.paused = false;
        this.startSoftPullLoop();
        this.startProgressTicker();
      } else {
        this.paused = true;
        this.stopSoftPullLoop();
        this.stopProgressTicker();
      }
      this.reportProgress(this.paused);
      this.revealChrome(!this.paused);
      return;
    }
    if (this.avPlayer === null || this.playbackError.length > 0) {
      return;
    }
    if (this.paused) {
      this.avPlayer.play();
      this.revealChrome(true);
    } else {
      this.avPlayer.pause();
      // 暂停时把控件留住（用户多半正要操作），并停掉自动隐藏计时
      this.revealChrome(false);
    }
  }

  private pausePlayback(): void {
    if (this.avPlayer !== null && !this.paused) {
      try {
        this.avPlayer.pause();
      } catch (err) {
        // 已处于不可暂停的状态：忽略
      }
    }
    this.stopProgressTicker();
  }

  /**
   * 上/下一条（delta = ±1）；越界即"到末尾"。
   *
   * 与上一版的差别：不再在末尾直接停住，而是**先试着再取一批**（追加成功后从下一条继续），
   * 只有确实取不到新内容时才显示「看完了」。
   */
  private advance(delta: number): void {
    const next: number = this.currentIndex + delta;
    if (next < 0) {
      return;
    }
    if (next >= this.items.length) {
      this.stopProgressTicker();
      this.releasePlayer();
      this.preparing = false;
      // 先给出「看完了 / 换一批」：追加成功时它会自己收起（见 appendMore），
      // 追加失败（弱网、服务端抽风）时用户也有明确的下一步，而不是停在一块死画面上。
      // 这一步不能用 `!this.appending` 之类的判定去挡 —— `appending` 是普通字段，
      // 不参与渲染刷新，写了也永远读到旧值。
      this.reachedEnd = true;
      this.appendMore(next);
      return;
    }
    this.reachedEnd = false;
    this.currentIndex = next;
    this.prefetchIfNearEnd();
    this.playCurrent();
  }

  /**
   * 条目播放失败：**换条路再试一次** → 就地软解 → 提示 + 自动跳过（见 `kAutoSkipMs`）。
   *
   * 换哪条路由"刚刚失败的是哪条"决定，且**每条内容只换一次**（`retryTried`）：
   *
   * | 刚失败的是 | 换到 | 为什么 |
   * |---|---|---|
   * | 服务端转码流 | 直连 | 转码任务本身可能起不来（ffmpeg 崩 / 分片 500），直连往往还能放 |
   * | 直连且档位是「自动」 | **服务端转码（让服务器解码）** | 直连是本机硬解，解不了就是解不了（典型：容器里带 DTS/TrueHD 音轨，系统解码器不认）；交给服务端转成 H.264/AAC 后走硬解，比本机 FFmpeg 软解省电，而且软解路径**没有音频输出** |
   * | 直连且档位是「原画直连」 | （不换，直接软解） | 用户明确选了"不请求转码、解不了走本机软解"，不该偷偷改成转码 |
   */
  private onItemFailed(message: string): void {
    hilog.warn(LOG_DOMAIN, LOG_TAG, 'onItemFailed method=%{public}s msg=%{public}s',
      this.playMethod, message);
    if (!this.retryTried) {
      // ── ① 服务器转码流失败 → 改直连再试一次 ─────────────────────────────
      // 服务端转码本身可能失败（ffmpeg 起不来 / 分片 500），此时换直连往往能放
      // （本机硬解或软解都行）。只试一次，避免在两条坏路之间来回弹。
      if (this.isTranscodeStream()) {
        this.retryTried = true;
        hilog.warn(LOG_DOMAIN, LOG_TAG, '转码流失败，回退直连播放');
        this.playCurrentDirect();
        return;
      }
      // ── ② 直连失败 + 「自动」档 → 让**服务器解码**（强制转码）再试一次 ──
      // 本机硬解拿不下直连流时（实测：视频是 h264、音轨是 DTS —— 系统解码器不认 DTS），
      // 「自动」档的意图就是"本机解不了的交给服务端"。这一步排在本机软解**之前**：
      // 软解吃 CPU/电量、容易掉帧，且本工程的软解路径没有音频输出。
      if (ShortVideoPrefs.quality().id === 'auto') {
        this.retryTried = true;
        hilog.warn(LOG_DOMAIN, LOG_TAG, '直连本机解不了，改由服务端解码（强制转码）再试一次');
        this.playCurrentServerDecode();
        return;
      }
    }
    this.playbackError = message;
    this.preparing = false;
    this.revealChrome(false);
    this.clearPrepareWatchdog();
    this.stopProgressTicker();
    this.releasePlayer();
    this.cancelAutoSkip();
    // ── 就地软解续播（本页自己的 surface）────────────────────────────────
    // 硬解解不了的内容（模拟器上的 HEVC 是常态）不再"提示 + 跳过"，
    // 而是当场用 FFmpeg 软解接着播 —— 这才是短视频该有的连续感。
    if (!this.softActive && this.surfaceId.length > 0) {
      this.startSoftPlayback();
      return;
    }
    // 软解也不行（如本构建未链接 FFmpeg）：退回"提示 + 自动跳过"，不把用户卡住
    this.startAutoSkip();
  }

  /** 当前这一条是不是"服务器转码流"（HLS/m3u8，或原生侧报的 Transcode） */
  private isTranscodeStream(): boolean {
    return this.playMethod === 'Transcode' || this.lastUrlWasHls;
  }

  /**
   * 用**直连参数**重开当前这一条（转码流失败后的回退）。
   *
   * 与 `playCurrent` 的差别只有播放参数：去掉 DeviceProfile、关掉转码，
   * 让服务端回到 `/Videos/{id}/stream?static=true`。
   */
  private async playCurrentDirect(): Promise<void> {
    await this.reopenCurrentWith(ShortVideoPrefs.directOptionsJson(), 'DirectPlay');
  }

  /**
   * 用**强制服务端转码**参数重开当前这一条（「自动」档下本机解不了直连流时的兜底）。
   *
   * 让服务器解码：视频与音频都会被转成客户端真能解的编码（H.264/AAC，走系统硬解）。
   * 为什么不用「直连 + 只转音频」的省服务器做法：那要求 DeviceProfile 不声明支持该音频编码，
   * 而当前能力表是按 FFmpeg 解码器列表写的（含 dts/truehd），服务端会认为"你本机能解"
   * —— 所以这里必须关掉直连/直接串流，逼服务端把音频一起转掉。
   */
  private async playCurrentServerDecode(): Promise<void> {
    await this.reopenCurrentWith(ShortVideoPrefs.transcodeOptionsJson(), 'Transcode');
  }

  /**
   * 用指定播放参数重开当前这一条（`playCurrentDirect` / `playCurrentServerDecode` 的共同实现）。
   *
   * @param options 交给 `playerOpen` 的播放参数
   * @param presetMethod 请求返回前的预期播放方式（只用于日志与失败时的判据，返回后会被真实值覆盖）
   */
  private async reopenCurrentWith(options: string, presetMethod: string): Promise<void> {
    const item: MediaItem | null = this.currentItem();
    this.cancelAutoSkip();
    this.stopSoftPlayback();
    this.stopProgressTicker();
    this.releasePlayer();
    this.playbackError = '';
    this.videoReady = false;
    this.paused = false;
    this.positionMs = 0;
    this.durationMs = 0;
    this.playMethod = presetMethod;
    this.lastUrlWasHls = false;
    if (item === null) {
      this.preparing = false;
      return;
    }
    this.preparing = true;
    this.revealChrome(false);
    this.startPrepareWatchdog();
    const raw: string = await JellyfinNative.playerOpen(item.id, options);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.onItemFailed(result.message.length > 0 ? `获取播放地址失败：${result.message}` : '获取播放地址失败');
      return;
    }
    const playUrl: string = JsonUtil.getString(result.data as ESObject, 'playUrl', '');
    const method: string = JsonUtil.getString(result.data as ESObject, 'playMethod', '');
    if (method.length > 0) {
      this.playMethod = method;
    }
    this.lastUrlWasHls = playUrl.includes('.m3u8');
    hilog.info(LOG_DOMAIN, LOG_TAG, 'reopen method=%{public}s hls=%{public}s',
      this.playMethod, this.lastUrlWasHls ? '1' : '0');
    if (playUrl.length === 0) {
      this.onItemFailed('服务器没有给出播放地址');
      return;
    }
    try {
      this.avPlayer = await media.createAVPlayer();
    } catch (err) {
      this.onItemFailed('创建播放器失败');
      return;
    }
    this.playingItemId = item.id;
    this.attachPlayerHandlers(this.avPlayer);
    try {
      this.avPlayer.url = playUrl;
    } catch (err) {
      this.onItemFailed('设置播放地址失败');
    }
  }

  /** 起播看门狗：到点还没出画面就按"这条播不了"处理（否则用户会一直盯着黑屏转圈） */
  private startPrepareWatchdog(): void {
    this.clearPrepareWatchdog();
    this.prepareWatchdogId = setTimeout(() => {
      this.prepareWatchdogId = -1;
      if (!this.videoReady && this.playbackError.length === 0 && this.avPlayer !== null) {
        this.onItemFailed('这条内容迟迟没能起播');
      }
    }, kPrepareTimeoutMs);
  }

  private clearPrepareWatchdog(): void {
    if (this.prepareWatchdogId >= 0) {
      clearTimeout(this.prepareWatchdogId);
      this.prepareWatchdogId = -1;
    }
  }

  /** 失败后的自动跳过：倒计时一秒一跳，归零即下一条 */
  private startAutoSkip(): void {
    this.cancelAutoSkip();
    this.skipLeftMs = kAutoSkipMs;
    this.skipTickId = setInterval(() => {
      const left: number = this.skipLeftMs - kSkipTickMs;
      if (left <= 0) {
        this.cancelAutoSkip();
        this.advance(1);
        return;
      }
      this.skipLeftMs = left;
    }, kSkipTickMs);
  }

  private cancelAutoSkip(): void {
    if (this.skipTickId >= 0) {
      clearInterval(this.skipTickId);
      this.skipTickId = -1;
    }
    this.skipLeftMs = 0;
  }

  // ─────────────────── 上下控件的自动隐藏（画面优先）───────────────────

  /**
   * 重新计时：播放中 4 秒无交互就把上下控件藏起来。
   *
   * 什么时候**不**隐藏：暂停、正在准备、本条播不了、没有内容 —— 这些状态本身就是
   * "用户需要看到的信息"，藏起来只会让人以为界面坏了。
   */
  private armChromeAutoHide(): void {
    this.cancelChromeAutoHide();
    if (this.paused || this.preparing || this.playbackError.length > 0
      || !this.videoReady || this.items.length === 0) {
      return;
    }
    this.chromeHideTimerId = setTimeout(() => {
      this.chromeHideTimerId = -1;
      if (this.paused || this.preparing || this.playbackError.length > 0) {
        return;
      }
      this.chromeVisible = false;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'chrome hidden（播放中自动隐藏）');
    }, kChromeAutoHideMs);
  }

  private cancelChromeAutoHide(): void {
    if (this.chromeHideTimerId >= 0) {
      clearTimeout(this.chromeHideTimerId);
      this.chromeHideTimerId = -1;
    }
  }

  /** 唤出上下控件；`autoHide=true` 时重新开始计时（用户还在看，稍后再收） */
  private revealChrome(autoHide: boolean): void {
    if (!this.chromeVisible) {
      this.chromeVisible = true;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'chrome shown（交互唤出）');
    }
    if (autoHide) {
      this.armChromeAutoHide();
    } else {
      this.cancelChromeAutoHide();
    }
  }

  /** 就地软解：打开会话 → 按当前位置起播 → 自调度拉帧 */
  private async startSoftPlayback(): Promise<void> {
    const item: MediaItem | null = this.currentItem();
    if (item === null) {
      return;
    }
    this.softActive = true;
    this.preparing = true;
    this.playbackError = '';   // 软解接管后不再显示"本机无法播放"
    this.cancelAutoSkip();
    const seekSec: number = this.positionMs / 1000;
    // softPlayOpen 是**异步**接口（内部要取 PlaybackInfo + 探测容器），必须 await。
    // 参数走**直连**（见 ShortVideoPrefs.directOptionsJson）：本工程的 FFmpeg 是
    // `--disable-network` 构建的，打不开 HLS 分片流，带 DeviceProfile 只会拿到 m3u8。
    const raw: string = await JellyfinNative.softPlayOpen(item.id, this.surfaceId, this.surfaceW,
                                                         this.surfaceH, 'surface',
                                                         ShortVideoPrefs.directOptionsJson());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null ||
        !JsonUtil.getBoolean(result.data as ESObject, 'ok', false)) {
      const why: string = result.data !== null
        ? JsonUtil.getString(result.data as ESObject, 'error', '软解打开失败') : '软解打开失败';
      this.softActive = false;
      this.preparing = false;
      this.playbackError = `本机无法播放该内容（${why}）`;
      this.startAutoSkip();
      return;
    }
    // ── EGL 渲染器必须在**本线程（UI 线程）**初始化 ────────────────────────
    // `softPlayOpen` 跑在原生工作线程上，**故意不做** EGL 初始化：
    // EGL/DGLES 的"当前上下文"是线程私有状态，在工作线程初始化、在 UI 线程逐帧
    // `eglSwapBuffers` 会每帧失败（`EGL_BAD_SURFACE`，画面全黑且无报错）——
    // 那正是此前"软解黑屏"的根因。因此这里用同步接口在当前线程建好渲染器，
    // 并走 `surfaceId` 路径（本页自己的 XComponent），不碰播放页那块原生桥单例。
    // 渲染缓冲几何必须**按视频尺寸**协商，不能直接用整屏尺寸：
    // 「视频」页的 XComponent 是满屏（实测 1260×2294），而模拟器的软件 GL 交换不了这么大的缓冲
    // （实测 `eglSwapBuffers 0x12301`，且降级阶梯折半后依旧失败 —— 表面创建后
    // `SET_BUFFER_GEOMETRY` 已不生效）。播放页之所以没这个问题，是因为它的 XComponent 本身
    // 就按画面比例设了尺寸（1259×537）。这里按"视频尺寸等比缩放到组件内"取几何，
    // 顺带把解码目标宽度对齐到该几何 —— 既省 swscale 又不浪费解码算力。
    const videoW: number = JsonUtil.getNumber(result.data as ESObject, 'width', 0);
    const videoH: number = JsonUtil.getNumber(result.data as ESObject, 'height', 0);
    if (videoW > 0 && videoH > 0) {
      // 软解路径同样要让视频面与画面同比例（否则 2.35:1 的片子会被拉进 16:9 的盒子）
      this.videoW = videoW;
      this.videoH = videoH;
    }
    let renderW: number = this.surfaceW;
    let renderH: number = this.surfaceH;
    if (videoW > 0 && videoH > 0 && this.surfaceW > 0 && this.surfaceH > 0) {
      const k: number = Math.min(this.surfaceW / videoW, this.surfaceH / videoH);
      renderW = Math.max(2, Math.floor(videoW * k));
      renderH = Math.max(2, Math.floor(videoH * k));
    }
    const initRaw: string = JellyfinNative.softPlayInitRenderer(this.surfaceId, renderW,
                                                               renderH, 'surface');
    const initResult: NativeResult = JellyfinNative.parseResult(initRaw);
    const renderReady: boolean = initResult.ok && initResult.data !== null
      && JsonUtil.getBoolean(initResult.data as ESObject, 'renderReady', false);
    if (!renderReady) {
      const renderErr: string = initResult.ok && initResult.data !== null
        ? JsonUtil.getString(initResult.data as ESObject, 'renderError', '') : initResult.message;
      this.softActive = false;
      this.preparing = false;
      this.playbackError = `软解画面无法上屏${renderErr.length > 0 ? '：' + renderErr : ''}`;
      JellyfinNative.softPlayClose();
      this.startAutoSkip();
      return;
    }
    this.playingItemId = item.id;
    // 解码宽度对齐渲染缓冲（0 = 按源分辨率，会白白多解一倍像素）
    const negotiated: number = initResult.data !== null
      ? JsonUtil.getNumber(initResult.data as ESObject, 'renderWidth', 0) : 0;
    this.softDecodeMaxWidth = negotiated > 0 ? negotiated : renderW;
    if (seekSec > 1) {
      JellyfinNative.softPlaySeek(seekSec);
    }
    this.videoReady = true;
    this.preparing = false;
    this.paused = false;
    this.startSoftPullLoop();
    this.startProgressTicker();
    this.applyScreenOn(true);
  }

  /** 页内软解的帧循环：自调度（上一帧完成即排下一帧），与播放页同一套思路 */
  private startSoftPullLoop(): void {
    this.stopSoftPullLoop();
    this.scheduleSoftPull(0);
  }

  private scheduleSoftPull(delayMs: number): void {
    if (this.softPullTimerId !== -1) {
      clearTimeout(this.softPullTimerId);
      this.softPullTimerId = -1;
    }
    this.softPullTimerId = setTimeout(() => {
      this.softPullTimerId = -1;
      this.pullSoftFrame();
    }, delayMs);
  }

  private stopSoftPullLoop(): void {
    if (this.softPullTimerId !== -1) {
      clearTimeout(this.softPullTimerId);
      this.softPullTimerId = -1;
    }
  }

  private async pullSoftFrame(): Promise<void> {
    if (!this.softActive || this.softPulling) {
      return;
    }
    // 切走页签/离开本页就停：软解也在放声音（无音频输出，但别白烧 CPU）
    if (this.activeTab !== kVideoTabIndex) {
      return;
    }
    this.softPulling = true;
    try {
      const raw: string = await JellyfinNative.softPlayNextFrame(this.softDecodeMaxWidth);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (result.ok && result.data !== null) {
        const frame: ESObject = result.data as ESObject;
        if (JsonUtil.getBoolean(frame, 'ok', false)) {
          // 渲染必须在 UI 线程（本函数运行在 ArkTS 侧 = UI 线程）
          JellyfinNative.softPlayRenderLast();
          const pts: number = JsonUtil.getNumber(frame, 'ptsSec', 0);
          if (pts > 0) {
            this.positionMs = Math.floor(pts * 1000);
          }
          if (this.playingItemId.length > 0) {
            this.reportProgress(false);
          }
        } else {
          const reason: string = JsonUtil.getString(frame, 'error', '');
          if (reason === 'eof') {
            this.advance(1);
            return;
          }
        }
      }
    } catch (err) {
      // 单帧失败不致命：下一次调度会重试
    } finally {
      this.softPulling = false;
      if (this.softActive && !this.paused && this.activeTab === kVideoTabIndex) {
        this.scheduleSoftPull(kSoftPullMinGapMs);
      }
    }
  }

  /** 关掉页内软解（切条/离页/改走硬解时都要调） */
  private stopSoftPlayback(): void {
    this.stopSoftPullLoop();
    if (this.softActive) {
      this.softActive = false;
      JellyfinNative.softPlayClose();
    }
  }

  // ─────────────────────── 点按手势（单击暂停 / 双击 ±10s）───────────────────────
  //
  // 与播放页同一套口径：单击**延后**执行，双击会取消待执行的单击
  // （否则双击快进时画面会先暂停一下，用户看到的是"闪了一下"）。

  /**
   * 卡片上的触摸：只处理"抬手"，且只处理落在**画面区**里的抬手。
   *
   * 为什么按坐标过滤：工具行/操作栏是叠在画面上的浮层，与手势层是兄弟节点，
   * 一次点按会同时到达两者（浮层容器用 HitTestMode.Transparent 才能点得动按钮）。
   * 因此"点按钮"与"点画面"必须由这里按位置分开（见 kTopChromeVp / kBottomChromeVp）。
   */
  private onCardTouch(event: TouchEvent): void {
    const touches: TouchObject[] = event.touches;
    if (touches.length !== 1) {
      return;
    }
    if (event.type !== TouchType.Up) {
      return;
    }
    const touch: TouchObject = touches[0];
    // 抬手时控件是不是藏着的 —— 必须在唤出**之前**记下来：单击动作是延后 380ms 执行的，
    // 那时控件已经被唤出，再判断"藏没藏"就永远是"没藏"，于是"第一下只唤出控件"会变成
    // "第一下既唤出又暂停"（设备实测踩到：日志里 chrome shown 与 singleTap paused=0 同时出现）。
    const wasHidden: boolean = !this.chromeVisible;
    // 任何抬手都算"用户在交互"：先把控件唤回来并重新计时
    this.revealChrome(true);
    if (this.inChromeZone(touch.x, touch.y)) {
      return;
    }
    this.handleTapUp(touch.x, wasHidden);
  }

  /** 触摸点是否落在浮层控件（工具行 / 操作栏 / 底部信息）所占的区域里 */
  private inChromeZone(x: number, y: number): boolean {
    if (y < kTopChromeVp + this.topInsetVp) {
      return true;
    }
    if (this.areaH <= 0 || this.areaW <= 0) {
      return false;
    }
    if (this.landscape) {
      // 横屏：操作栏是右下角的**横排**，整条底部信息带都算控件区
      // （竖屏那套"右侧一列 84×380"在横屏下会把大半个画面判成控件区）
      return y > this.areaH - kLandscapeBottomVp;
    }
    if (y > this.areaH - kBottomChromeVp) {
      return true;
    }
    // 竖屏：右侧操作栏是竖排，比底部信息区更高
    return x > this.areaW - kRailWidthVp && y > this.areaH - kRailHeightVp;
  }

  /**
   * 一次"抬手"到达：判定单击（暂停/继续）还是双击（两侧快进/快退）。
   *
   * 与播放页一致：单击必须**延后**执行，否则双击时画面会先暂停一下。
   */
  private handleTapUp(x: number, wasHidden: boolean): void {
    const now: number = Date.now();
    const width: number = this.areaW > 0 ? this.areaW : 360;
    const isDoubleTap: boolean = (now - this.lastTapUpAt) < kDoubleTapMs
      && Math.abs(x - this.lastTapX) < width / 3;
    if (isDoubleTap) {
      this.cancelPendingTap();
      const forward: boolean = x >= width / 2;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'doubleTap x=%{public}d forward=%{public}s',
        Math.round(x), forward ? '1' : '0');
      this.skipBy(forward ? kSkipStepMs : -kSkipStepMs);
      this.showSeekHint(forward);
      // 双击后不再把第二次抬手当成新一轮单击的起点
      this.lastTapUpAt = 0;
      return;
    }
    this.lastTapUpAt = now;
    this.lastTapX = x;
    this.cancelPendingTap();
    this.singleTapTimerId = setTimeout(() => {
      this.singleTapTimerId = -1;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'singleTap x=%{public}d paused=%{public}s wasHidden=%{public}s',
        Math.round(x), this.paused ? '1' : '0', wasHidden ? '1' : '0');
      // 单击始终是"暂停 / 继续"：自动隐藏只是让画面让位，不该改变点按的含义
      // （本页的"单击暂停"已被文档与验收固定）。暂停分支里会 `revealChrome(false)`
      // 把控件留住，用户立刻能看到状态与按钮。
      this.togglePause();
    }, kSingleTapDelayMs);
  }

  private cancelPendingTap(): void {
    if (this.singleTapTimerId >= 0) {
      clearTimeout(this.singleTapTimerId);
      this.singleTapTimerId = -1;
    }
  }

  /** 双击的瞬时提示（"快进 10 秒"这类文字反馈，比只看进度跳动更容易确认手势生效） */
  private showSeekHint(forward: boolean): void {
    this.clearSeekHintTimer();
    this.seekHint = forward ? '快进 10 秒' : '快退 10 秒';
    // 留痕：提示只显示 1 秒多，靠截图/布局抓取验证会漏（设备实测里就漏过）
    hilog.info(LOG_DOMAIN, LOG_TAG, 'seekHint %{public}s', this.seekHint);
    this.seekHintTimerId = setTimeout(() => {
      this.seekHintTimerId = -1;
      this.seekHint = '';
    }, kSeekHintMs);
  }

  private clearSeekHintTimer(): void {
    if (this.seekHintTimerId >= 0) {
      clearTimeout(this.seekHintTimerId);
      this.seekHintTimerId = -1;
    }
  }

  /** 收起提示（定时器与文案一起清；离页时用） */
  private hideSeekHint(): void {
    this.clearSeekHintTimer();
    this.seekHint = '';
  }

  /**
   * 相对跳转（±10 秒）：硬解与软解两条路径都要支持。
   *
   * 软解只接受"排队"式 seek（原生侧记录目标，由下一次拉帧在解码线程执行），
   * 硬解则要求播放器处于 prepared/playing/paused/completed 之一 —— 状态不对时直接丢弃，
   * 避免抛 `5400102` 把一次误触变成一条错误提示。
   */
  private skipBy(deltaMs: number): void {
    if (this.playbackError.length > 0 || this.items.length === 0) {
      return;
    }
    let target: number = Math.max(0, this.positionMs + deltaMs);
    const total: number = this.effectiveDurationMs();
    if (total > 0) {
      target = Math.min(target, Math.max(0, total - 500));
    }
    if (this.softActive) {
      JellyfinNative.softPlaySeek(target / 1000);
      this.positionMs = target;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'seek(soft) -> %{public}dms', Math.round(target));
      return;
    }
    const player: media.AVPlayer | null = this.avPlayer;
    if (player === null) {
      return;
    }
    const state: string = player.state;
    if (state === 'prepared' || state === 'playing' || state === 'paused' ||
      state === 'completed') {
      player.seek(target);
      this.positionMs = target;
      hilog.info(LOG_DOMAIN, LOG_TAG, 'seek -> %{public}dms state=%{public}s',
        Math.round(target), state);
    } else {
      hilog.warn(LOG_DOMAIN, LOG_TAG, 'seek 被丢弃：state=%{public}s', state);
    }
  }

  // ─────────────────────── 条目操作（收藏 / 已看 / 详情）───────────────────────

  /**
   * 收藏 / 取消收藏当前条目。
   *
   * 为什么要在短视频页做：刷到喜欢的内容时，用户的下一步动作就是"收起来"，
   * 而此前只能点进详情页再操作 —— 那一下就把"刷"的动线打断了。
   */
  private async toggleFavorite(item: MediaItem): Promise<void> {
    const next: boolean = !this.isFavoriteId(item.id);
    const result: NativeResult =
      JellyfinNative.parseResult(await JellyfinNative.toggleFavorite(item.id, next));
    if (!result.ok) {
      this.toast(result.message.length > 0 ? `收藏失败：${result.message}` : '收藏失败（服务端未接受）');
      return;
    }
    const ids: string[] = this.favoriteIds.slice();
    const at: number = ids.indexOf(item.id);
    if (next && at < 0) {
      ids.push(item.id);
    } else if (!next && at >= 0) {
      ids.splice(at, 1);
    }
    this.favoriteIds = ids;
    this.toast(next ? '已加入我的最爱' : '已取消收藏');
  }

  /** 标记已看 / 未看（服务端 `Played`），同样即时反馈 */
  private async togglePlayed(item: MediaItem): Promise<void> {
    const next: boolean = !this.isPlayedId(item.id);
    const result: NativeResult =
      JellyfinNative.parseResult(await JellyfinNative.togglePlayed(item.id, next));
    if (!result.ok) {
      this.toast(result.message.length > 0 ? `标记失败：${result.message}` : '标记失败（服务端未接受）');
      return;
    }
    const ids: string[] = this.playedIds.slice();
    const at: number = ids.indexOf(item.id);
    if (next && at < 0) {
      ids.push(item.id);
    } else if (!next && at >= 0) {
      ids.splice(at, 1);
    }
    this.playedIds = ids;
    this.toast(next ? '已标记为已播放' : '已标记为未播放');
  }

  private isFavoriteId(id: string): boolean {
    return this.favoriteIds.indexOf(id) >= 0;
  }

  private isPlayedId(id: string): boolean {
    return this.playedIds.indexOf(id) >= 0;
  }

  /** 操作结果用 toast 反馈（成功与失败都要可见，失败原因直接给用户看） */
  private toast(message: string): void {
    try {
      this.getUIContext().getPromptAction().showToast({ message: message, duration: 2000 });
    } catch (err) {
      // toast 不可用不影响功能本身
    }
  }

  /** 进入条目详情页（保留详情页里的完整操作） */
  private openDetail(item: MediaItem): void {
    if (item.id.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/DetailPage',
      params: { itemId: item.id, title: item.displayTitle() }
    });
  }

  /** 去播放页看这一条（那里有更完整的转码/软解回退与字幕、音轨能力） */
  private openInPlayer(item: MediaItem): void {
    this.cancelPendingTap();
    this.cancelAutoSkip();
    if (item.id.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/PlayerPage',
      params: {
        itemId: item.id,
        title: item.displayTitle(),
        startPositionMs: Math.floor(this.positionMs)
      }
    });
  }

  private openSettings(): void {
    router.pushUrl({ url: 'pages/settings/ShortVideoSettingsPage' });
  }

  /**
   * 方向按钮的文案：跟随系统 / 横屏 / 竖屏。
   *
   * 为什么短视频也要有方向控制：短视频内容横竖皆有，而**横屏时同一个"适应"盒子计算
   * 会给出更大的画面**（可用区域从 20:9 的窄长变成宽屏）；只靠传感器自动旋转，
   * 躺卧观看时会被机身姿态反复打断，所以和播放页一样给一个显式锁定入口。
   */
  private orientationLabel(): string {
    if (this.orientation === 'landscape') {
      return '横屏';
    }
    if (this.orientation === 'portrait') {
      return '竖屏';
    }
    return '跟随系统';
  }

  private orientationIcon(): Resource {
    if (this.orientation === 'landscape') {
      return $r('sys.symbol.rectangle_ratio_16_to_9');
    }
    if (this.orientation === 'portrait') {
      return $r('sys.symbol.rectangle_ratio_9_to_16');
    }
    return $r('sys.symbol.screen_rotation');
  }

  /** 循环切换方向（跟随系统 → 横屏 → 竖屏 → 跟随系统） */
  private async cycleOrientation(): Promise<void> {
    const next: PlayerOrientation = this.orientation === 'auto'
      ? 'landscape' : (this.orientation === 'landscape' ? 'portrait' : 'auto');
    this.orientation = next;
    // 记住选择（横竖屏是"躺着看/坐着看"的选择，不该每次进来重设）
    ShortVideoPrefs.saveOrientation(next);
    // 全屏的语义就是"横屏铺满"：用户在全屏里把方向切成非横屏时，这个前提已经不成立，
    // 直接退出全屏（底部页签栏回来）——否则会留下"竖屏 + 页签栏消失"这种自相矛盾的中间态，
    // 而且页签栏不见了用户连别的页签都切不回去。
    if (this.fullscreenActive && next !== 'landscape') {
      this.orientationBeforeFullscreen = null;
      this.fullscreenActive = false;
      this.fullscreenBottomInsetVp = 0;
    }
    await this.applyOrientation();
  }

  // ─────────────────────── 主动全屏：进入 / 退出 ───────────────────────

  /** 全屏按钮的图标：未全屏是"展开"，已全屏是"收起" */
  private fullscreenIcon(): Resource {
    return this.fullscreenActive
      ? $r('sys.symbol.arrow_down_right_and_arrow_up_left')
      : $r('sys.symbol.arrow_up_left_and_arrow_down_right');
  }

  /** 全屏按钮：点一下进全屏，再点一下退出 */
  private toggleFullscreen(): void {
    if (this.fullscreenActive) {
      this.exitFullscreen();
      return;
    }
    this.enterFullscreen();
  }

  /**
   * 进入主动全屏：**横屏 + 外壳底部页签栏收起**，画面铺满整屏。
   *
   * 为什么要"横屏 + 铺满"一起做：竖屏是 20:9 的窄长屏，横片按适应缩放后上下本是黑边，
   * 单把页签栏收掉只多出 56vp；横过来才是短视频/横片真正"变大"的那一步
   * （可用区域从窄长变成宽屏）。两者一起做才叫全屏。
   *
   * 进全屏前的方向选择先存起来，退出时原样还回去（见 exitFullscreen）。
   */
  private enterFullscreen(): void {
    if (this.fullscreenActive) {
      return;
    }
    this.orientationBeforeFullscreen = this.orientation;
    this.orientation = 'landscape';
    this.fullscreenActive = true;
    // 页签栏收起后本页底部直接落在屏幕底边：量一下要给系统手势提示条让出多少（见字段说明）
    const win: window.Window | null = this.windowRef;
    this.fullscreenBottomInsetVp = win === null
      ? 0 : WindowFullscreen.insets(win, true).bottom;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'fullscreen enter bottomInset=%{public}d',
      this.fullscreenBottomInsetVp);
    this.applyOrientation();
    // 刚进全屏时把控件亮出来（用户需要看到"我进了全屏"以及怎么退出去），随后照常自动隐藏
    this.revealChrome(true);
  }

  /** 退出主动全屏：方向还原成进全屏之前的选择，底部页签栏回来 */
  private exitFullscreen(): void {
    if (!this.fullscreenActive) {
      return;
    }
    const back: PlayerOrientation = this.orientationBeforeFullscreen !== null
      ? this.orientationBeforeFullscreen : 'auto';
    this.orientationBeforeFullscreen = null;
    this.orientation = back;
    this.fullscreenActive = false;
    this.fullscreenBottomInsetVp = 0;
    hilog.info(LOG_DOMAIN, LOG_TAG, 'fullscreen exit orientation=%{public}s', back);
    this.applyOrientation();
    this.revealChrome(true);
  }

  /**
   * 离开本页（切页签 / 销毁）时收回全屏状态。
   *
   * 必须收：底部页签栏是外壳画的，留着"收起"状态用户就切不回别的页签了
   * （页签栏是唯一的页签入口；「视频」页连外壳顶栏都不画，抽屉也进不去）。
   * 这里只改状态与方向偏好，窗口方向的还原交给 `restoreOrientationOnLeave`（同一处调用）。
   */
  private leaveFullscreenState(): void {
    if (this.orientationBeforeFullscreen !== null) {
      this.orientation = this.orientationBeforeFullscreen;
      this.orientationBeforeFullscreen = null;
    }
    this.fullscreenActive = false;
    this.fullscreenBottomInsetVp = 0;
  }

  /**
   * 把当前方向选择应用到窗口；同时记下"改之前的窗口方向"，供离开本页签时还原。
   *
   * 为什么要还原：方向是**窗口级**状态，本页是嵌入式组件 —— 用户在「视频」页选了横屏，
   * 切到「媒体库/设置」后那些页面也会跟着横着（它们并没有横屏布局）。
   * 因此离开页签时还原、回来时重新应用，形成成对的进出（与播放页同一套做法）。
   */
  private async applyOrientation(): Promise<void> {
    const win: window.Window | null = await this.ensureWindowRef();
    if (win === null) {
      // 取不到窗口：方向设置失败，但短视频页仍可用（跟随系统）
      return;
    }
    if (this.savedOrientationValue < 0) {
      this.savedOrientationValue = WindowFullscreen.currentOrientation(win);
    }
    WindowFullscreen.setOrientation(win, this.orientation);
  }

  /** 离开本页签时把窗口方向还原成"进来之前的样子" */
  private async restoreOrientationOnLeave(): Promise<void> {
    const win: window.Window | null = await this.ensureWindowRef();
    if (win === null) {
      return;
    }
    if (this.savedOrientationValue >= 0) {
      WindowFullscreen.restoreOrientation(win, this.savedOrientationValue);
      this.savedOrientationValue = -1;
    }
  }

  // ─────────────────────── 进度上报与窗口状态 ───────────────────────

  /** 进度：1 秒刷新界面读数，5 秒节流上报服务端（与播放页同一套节流口径） */
  private startProgressTicker(): void {
    this.stopProgressTicker();
    this.progressTimerId = setInterval(() => {
      if (this.avPlayer !== null) {
        this.positionMs = this.avPlayer.currentTime;
        if (this.avPlayer.duration > 0) {
          this.durationMs = this.avPlayer.duration;
        }
      }
      this.reportProgress(false);
    }, 1000);
  }

  private stopProgressTicker(): void {
    if (this.progressTimerId >= 0) {
      clearInterval(this.progressTimerId);
      this.progressTimerId = -1;
    }
  }

  private reportProgress(isPaused: boolean): void {
    if (this.playingItemId.length === 0) {
      return;
    }
    const now: number = Date.now();
    if (!isPaused && this.lastReportAt > 0 && now - this.lastReportAt < kReportIntervalMs) {
      return;
    }
    this.lastReportAt = now;
    const ticks: number = Math.floor(this.positionMs * 10000);
    PlaybackState.set(this.playingItemId, ticks);
    JellyfinNative.reportPlaybackProgress(this.playingItemId, ticks, isPaused);
  }

  /** 释放播放器并补发 stopped（切条/离页都必须走这里，避免服务端会话堆积） */
  private releasePlayer(): void {
    const player: media.AVPlayer | null = this.avPlayer;
    this.avPlayer = null;
    // 软解正在跑时不把 videoReady 打回 false（否则封面会盖住软解画面）
    if (!this.softActive) {
      this.videoReady = false;
    }
    if (player !== null) {
      try {
        player.off('stateChange');
        player.off('error');
      } catch (err) {
        // 监听器可能已随 release 清理
      }
      try {
        player.release();
      } catch (err) {
        // 已在错误态：忽略
      }
    }
    if (this.playingItemId.length > 0) {
      const ticks: number = Math.floor(this.positionMs * 10000);
      PlaybackState.set(this.playingItemId, ticks);
      JellyfinNative.reportPlaybackStopped(this.playingItemId, ticks);
      this.playingItemId = '';
    }
    this.lastReportAt = 0;
  }

  /** 取窗口实例（方向控制、屏幕常亮共用；取不到时相关能力静默降级） */
  private async ensureWindowRef(): Promise<window.Window | null> {
    if (this.windowRef !== null) {
      return this.windowRef;
    }
    try {
      this.windowRef = await window.getLastWindow(getContext(this) as common.UIAbilityContext);
      return this.windowRef;
    } catch (err) {
      return null;
    }
  }

  /**
   * 播放时保持屏幕常亮。
   *
   * 为什么需要：短视频是"长时间只看不摸屏幕"的用法，系统息屏时间一到画面就黑掉，
   * 而用户的手并没有碰屏幕 —— 观感上就是"看着看着断了"。播放页早有这个处理
   * （`setWindowKeepScreenOn`），短视频页此前漏了。
   */
  private async applyScreenOn(on: boolean): Promise<void> {
    if (on === this.screenOnApplied) {
      return;
    }
    const win: window.Window | null = await this.ensureWindowRef();
    if (win === null) {
      return;
    }
    try {
      await win.setWindowKeepScreenOn(on);
      this.screenOnApplied = on;
    } catch (err) {
      // 常亮失败不影响播放，只是不生效
    }
  }

  // ─────────────────────── 画面比例与读数 ───────────────────────

  /** 屏幕像素密度（px / vp）—— 「原始」比例换算用（与播放页同一口径） */
  private density(): number {
    try {
      const d: number = display.getDefaultDisplaySync().densityPixels;
      return d > 0 ? d : 1;
    } catch (err) {
      return 1;
    }
  }

  /**
   * 视频面（XComponent）的尺寸：**按画面比例**适配可用区域（vp）。
   *
   * 与播放页共用 `PlayerAspect.box(..., 'contain', ...)`：等比、完整可见、多余留黑边。
   * 画面尺寸未知（尚未 prepared）时铺满可用区域，拿到尺寸后本函数会被重新调用。
   * 横屏不做特殊分支 —— 可用区域横向变长，同一个"适应"计算自然给出更大的画面。
   */
  private videoBoxWidth(): Length {
    if (this.videoW <= 0 || this.videoH <= 0) {
      // 画面尺寸未知：先铺满（拿到尺寸后本函数会被重新求值）
      return this.areaW > 0 ? this.areaW : '100%';
    }
    return PlayerAspect.box('contain', this.videoW, this.videoH, this.areaW, this.areaH,
                            this.density()).width;
  }

  private videoBoxHeight(): Length {
    if (this.videoW <= 0 || this.videoH <= 0) {
      return this.areaH > 0 ? this.areaH : '100%';
    }
    return PlayerAspect.box('contain', this.videoW, this.videoH, this.areaW, this.areaH,
                            this.density()).height;
  }

  /** 进度百分比（0..1）；时长未知时为 0 */
  private progressRatio(): number {
    const total: number = this.effectiveDurationMs();
    if (total <= 0) {
      return 0;
    }
    const r: number = this.positionMs / total;
    return Math.min(1, Math.max(0, r));
  }

  /**
   * 当前条目的**元数据时长**（毫秒）。
   *
   * 为什么需要它：设备实测（模拟器）发现部分流在 `prepared` 阶段
   * `AVPlayer.duration` 仍是 0，于是进度条恒为 0、`已看 / 总时长` 读数根本不出现 ——
   * 而这条信息服务端早就给了（`RunTimeTicks`，取数时已随 `Fields` 一并请求）。
   */
  private itemDurationMs(): number {
    const item: MediaItem | null = this.currentItem();
    if (item === null || item.runTimeTicks <= 0) {
      return 0;
    }
    // Jellyfin 的 ticks 是 100ns：ms = ticks / 10000
    return Math.floor(item.runTimeTicks / 10000);
  }

  /** 可用的总时长：播放器给的优先，拿不到就用元数据（见 itemDurationMs） */
  private effectiveDurationMs(): number {
    return this.durationMs > 0 ? this.durationMs : this.itemDurationMs();
  }

  /** 当前条目是否正在页内播放（决定封面是否让位给视频） */
  private isVideoPlaying(index: number): boolean {
    return index === this.currentIndex && this.videoReady && this.playbackError.length === 0;
  }

  /**
   * 环境背景是否要出现。
   *
   * 只在**真的出画面了**才出现：还没起播时，卡片自己那张铺满的封面才是"底"，
   * 两者同时存在会白解一张整屏图（内存与解码都是浪费）。
   */
  private ambientVisible(): boolean {
    return this.videoReady && this.playbackError.length === 0 && this.currentItem() !== null;
  }

  private currentItem(): MediaItem | null {
    if (this.currentIndex < 0 || this.currentIndex >= this.items.length) {
      return null;
    }
    return this.items[this.currentIndex];
  }

  /** 封面取横图优先（Backdrop），没有就退化为竖图（Primary） */
  private coverUrl(item: MediaItem, width: number): string {
    return item.imageUrl(width, item.backdropTag.length > 0 ? 'Backdrop' : 'Primary');
  }

  /** 当前条目的封面地址（环境背景用；没有内容时返回空串，组件会画占位） */
  private ambientUrl(): string {
    const item: MediaItem | null = this.currentItem();
    return item === null ? '' : this.coverUrl(item, 900);
  }

  /** 当前条目的类型徽标文案（电影 / 单集 / 视频 …） */
  private typeBadge(item: MediaItem): string {
    return item.typeLabel();
  }

  /**
   * 顶部徽标文案：`清晰度设置 · 实际播放方式`。
   *
   * 例：`720p · 转码`（服务端转码生效）、`自动 · 直连`（服务端认为可直接播放）、
   * `自动 · 直连串流`（DirectStream）。设置与实际不一致时（服务端没转码/转码失败回退）
   * 一眼就能看出来，不必去翻日志。
   */
  private qualityBadge(): string {
    const setting: string = ShortVideoPrefs.qualityShortLabel();
    // 软解优先：页内软解接管后，"实际方式"就是本机解码 —— 不能还显示解析出来的
    // 转码/直连（设备实测：软解接管后徽标仍写着"直连"，与画面来源不符）。
    if (this.softActive) {
      return `${setting} · 本机软解`;
    }
    let actual: string = '准备中';
    if (this.playMethod === 'Transcode') {
      actual = '转码';
    } else if (this.playMethod === 'DirectStream') {
      actual = '直连串流';
    } else if (this.playMethod === 'DirectPlay') {
      actual = '直连';
    }
    return `${setting} · ${actual}`;
  }

  /**
   * 简介：去掉 HTML 标签再显示。
   *
   * 为什么必须处理：Jellyfin 的 `Overview` 常常带 HTML（实测某条 B 站视频的简介是
   * `<a href="https://www.bilibili.com/video/BV...">BV...</a><br/><br/>-`），
   * 直接渲染就会把标签当成正文显示出来 —— 设备实测截图里那一行非常刺眼。
   */
  private overviewText(item: MediaItem): string {
    return stripMarkup(item.overview);
  }

  /**
   * 元信息行：`2023 · 8.1 分 · 1:32:10 · 剧情 / 悬疑`
   *
   * 用 `MediaItem.metaLine()` 的年/评分/时长，再补一段类型（短视频用户往往先看类型）。
   */
  private metaLine(item: MediaItem): string {
    const base: string = item.metaLine();
    if (item.genres.length === 0) {
      return base;
    }
    const top: string[] = [];
    for (let i = 0; i < item.genres.length && i < 2; i++) {
      top.push(item.genres[i]);
    }
    const suffix: string = top.join(' / ');
    return base.length > 0 ? `${base} · ${suffix}` : suffix;
  }

  // ─────────────────────────── 画面（UI）───────────────────────────

  /**
   * 环境背景：当前封面铺满 + 压暗。
   *
   * 位置在**视频面之下**：视频面按"适应"缩放后四周留白，这里把留白填成同一张图的
   * 暗色放大版本（主流做法，Plex/Infuse 都这么处理黑边），比纯黑的两条边更完整。
   */
  @Builder
  AmbientBackdrop() {
    Stack() {
      JellyfinImage({
        url: this.ambientUrl(),
        imgWidth: 900,
        imgHeight: 1600,
        cornerRadius: 0,
        objectFit: ImageFit.Cover,
        placeholderIcon: 'movie',
        fillMode: true
      })
      // 压暗：环境背景是"底"，不能比画面本身更抢眼。
      //
      // 用 `scrim`（深色主题 53% 黑）而不是 `scrimHeavy`（80%）：设备实测
      // （截图像素采样）显示 80% 遮罩下留白区亮度只有 13/255 —— 看上去仍是一条黑边，
      // 等于"环境背景"白做；53% 下同一区域的结构清晰可见，又不与画面抢注意力。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(this.colors().scrim)
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 顶部工具行：标题 + 页码 + 来源，右侧是方向与设置。
   *
   * 做成浮层（而不是占一行高度的实体栏）：短视频页的画面就是内容本体，
   * 顶部/底部的渐变 scrim 保证文字在任何画面上都可读，同时不切走画面高度。
   */
  @Builder
  TopChrome(index: number) {
    Row({ space: 10 }) {
      Column({ space: 2 }) {
        Row({ space: 8 }) {
          Text('短视频')
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onOverlay)
          Text(`${index + 1}/${this.items.length}`)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onOverlayMuted)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor(this.colors().overlayControl)
            .borderRadius(ThemeConstants.BADGE_RADIUS)
          // 清晰度 / 播放方式：用户选了「720p」到底生效没有，画面上只有这里能看出来
          // （转码流是 HLS，走硬件解码；直连则可能是本机硬解或软解）
          Text(this.qualityBadge())
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.isTranscodeStream()
              ? this.colors().onBrand : this.colors().onOverlayMuted)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor(this.isTranscodeStream()
              ? this.colors().brandPrimary : this.colors().overlayControl)
            .borderRadius(ThemeConstants.BADGE_RADIUS)
        }
        .alignItems(VerticalAlign.Center)

        Text(this.libraryNames.length > 0
          ? `来自：${this.libraryNames.join(' / ')}`
          : '来自已选的短视频媒体库')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlayMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 方向：跟随系统 / 横屏 / 竖屏（图标 + 文案，状态一眼可见）
      Button({ type: ButtonType.Normal, stateEffect: false }) {
        Row({ space: 5 }) {
          SymbolGlyph(this.orientationIcon())
            .fontSize(ThemeConstants.ICON_SMALL)
            .fontColor([this.colors().onOverlay])
          Text(this.orientationLabel())
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onOverlay)
            .maxLines(1)
        }
        .alignItems(VerticalAlign.Center)
      }
      .height(32)
      .padding({ left: 10, right: 12 })
      .backgroundColor(this.colors().overlayControl)
      .borderRadius(ThemeConstants.CHIP_RADIUS)
      .onClick(() => { this.cycleOrientation(); })

      // 主动全屏：横屏 + 外壳页签栏收起，画面铺满整屏；再点一次退出。
      //
      // 为什么做成图标按钮而不是像「方向」那样带文字：竖屏 373vp 宽的工具行里已经有
      // 「方向」胶囊 + 「设置」圆钮，再塞一个文字胶囊会把左侧的页码/清晰度徽标挤到换行；
      // 展开/收起是全平台通用的形状，图标本身就够表意（与「设置」同尺寸，一行对齐）。
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph(this.fullscreenIcon())
          .fontSize(ThemeConstants.ICON_MEDIUM)
          .fontColor([this.colors().onOverlay])
      }
      .width(32)
      .height(32)
      .padding(0)
      .backgroundColor(this.colors().overlayControl)
      .onClick(() => { this.toggleFullscreen(); })

      // 设置：进入「短视频模式」媒体库选择
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph($r('sys.symbol.gearshape'))
          .fontSize(ThemeConstants.ICON_MEDIUM)
          .fontColor([this.colors().onOverlay])
      }
      .width(32)
      .height(32)
      .padding(0)
      .backgroundColor(this.colors().overlayControl)
      .onClick(() => { this.openSettings(); })
    }
    .width('100%')
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 右侧操作栏的一个按钮（圆形图标 + 一行小字）。
   *
   * ⚠️ 参数只收**稳定标识**（`kind` = 按钮种类、`itemId` = 条目 id），
   * 图标 / 文案 / 选中态一律在**函数体内**由页面状态算出来。
   *
   * 为什么必须这样（设备实测踩到的坑）：`@Builder` 的参数是**按值传递**的，
   * 参数表达式只在调用那一刻求值一次 —— 若把 `this.isFavoriteId(item.id)` 这类
   * **状态派生值**当参数传进来，"点收藏"之后服务端状态确实变了（toast 也弹了）
   * 但按钮的图标与文字永远停在旧值（实测：点了收藏仍显示「收藏」）。
   * 写在函数体里则每个属性都有自己的状态依赖，状态一变就重算。
   */
  @Builder
  RailButton(kind: string, itemId: string, onTap: () => void) {
    Column({ space: 5 }) {
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph(this.railIcon(kind, itemId))
          .fontSize(this.landscape ? ThemeConstants.ICON_MEDIUM : ThemeConstants.ICON_XLARGE)
          .fontColor([this.railSelected(kind, itemId)
            ? this.colors().onBrand : this.colors().onOverlay])
      }
      // 横屏可用高度只有 ~306vp：按钮缩到 40vp，四个横排才放得下且不与工具行打架
      .width(this.landscape ? 40 : 46)
      .height(this.landscape ? 40 : 46)
      .padding(0)
      .backgroundColor(this.railSelected(kind, itemId)
        ? this.colors().brandPrimary : this.colors().overlayControl)
      .onClick(() => { onTap(); })

      Text(this.railLabel(kind, itemId))
        .fontSize(ThemeConstants.LABEL_SMALL)
        .fontColor(this.colors().onOverlayMuted)
        .maxLines(1)
    }
    .alignItems(HorizontalAlign.Center)
  }

  /** 操作栏按钮的图标（按种类 + 当前状态算） */
  private railIcon(kind: string, itemId: string): Resource {
    if (kind === 'favorite') {
      return this.isFavoriteId(itemId) ? $r('sys.symbol.star_fill') : $r('sys.symbol.star');
    }
    if (kind === 'played') {
      return this.isPlayedId(itemId)
        ? $r('sys.symbol.checkmark_circle_fill') : $r('sys.symbol.checkmark');
    }
    if (kind === 'detail') {
      return $r('sys.symbol.info_circle');
    }
    return $r('sys.symbol.arrow_2_circlepath');
  }

  /** 操作栏按钮的文案 */
  private railLabel(kind: string, itemId: string): string {
    if (kind === 'favorite') {
      return this.isFavoriteId(itemId) ? '已收藏' : '收藏';
    }
    if (kind === 'played') {
      return this.isPlayedId(itemId) ? '已看' : '标记已看';
    }
    return kind === 'detail' ? '详情' : '换一批';
  }

  /** 操作栏按钮是否处于选中态（收藏 / 已看 两类才有） */
  private railSelected(kind: string, itemId: string): boolean {
    if (kind === 'favorite') {
      return this.isFavoriteId(itemId);
    }
    if (kind === 'played') {
      return this.isPlayedId(itemId);
    }
    return false;
  }

  /**
   * 一屏一条短视频的卡片。
   *
   * 层次（自下而上）：封面（仅"当前这条还没出画面"时画）→ 顶部/底部渐变 →
   * 手势层 → 顶部工具行 → 底部信息 + 右侧操作栏。
   *
   * 封面只在**当前条目**上画：`ForEach` 会为整批条目建组件，一屏只看得到一条，
   * 却要为每条拉一张 900px 的图（原生下载 + 解码）—— 24 条并发取图既慢又吃内存。
   */
  @Builder
  FeedCard(item: MediaItem, index: number) {
    Stack({ alignContent: Alignment.Center }) {
      if (index === this.currentIndex && !this.isVideoPlaying(index)) {
        JellyfinImage({
          url: this.coverUrl(item, 900),
          imgWidth: 900,
          imgHeight: 1600,
          cornerRadius: 0,
          objectFit: ImageFit.Cover,
          placeholderIcon: 'movie',
          fillMode: true
        })
      }

      // 顶部渐变：工具行压在亮画面上也读得清
      Column() {
        Column()
          .width('100%')
          .height(120 + this.topInsetVp)
          .linearGradient({
            angle: 0,
            colors: [['#00000000', 0.0], [this.colors().scrim, 1.0]]
          })
        Blank()
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)

      // 底部渐变：标题/元信息的可读性底（与播放页同一套 scrim 令牌）
      Column() {
        Blank()
        Column()
          .width('100%')
          .height('52%')
          .linearGradient({
            angle: 180,
            colors: [['#00000000', 0.0], [this.colors().scrimHeavy, 1.0]]
          })
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.Transparent)

      // 手势层：单击暂停/继续、双击两侧 ±10 秒。
      //
      // 为什么挂在**卡片自己的**全屏透明层上而不是页面根节点：它在 Swiper 内部，
      // 纵向滑动仍由 Swiper 接管（"点得着也滑得动"）；按钮在它**之上**作为兄弟节点，
      // 因此按钮的点击不会被它抢走，只有落在画面区的点按才交给它。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onTouch((event: TouchEvent) => {
          if (index === this.currentIndex) {
            this.onCardTouch(event);
          }
        })

      // 顶部工具行（Transparent：自身不挡下面的手势层，内部按钮照常响应）
      //
      // 用 `if` 而不是 `opacity(0)`：透明度为 0 的按钮**仍然能被点到**，
      // 控件"藏起来"却还吃触摸是最难查的一类 bug（本页此前在浮层上踩过）。
      if (this.chromeVisible) {
        Column() {
          this.TopChrome(index)
          Blank()
        }
        .width('100%')
        .height('100%')
        .padding({
          left: ThemeConstants.PAGE_PADDING,
          right: ThemeConstants.PAGE_PADDING,
          top: 10 + this.topInsetVp
        })
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseInOut }))
      }

      // 底部信息 + 操作栏（随上下控件一起自动隐藏）
      //
      // 布局分横竖两套（**不是**同一套量的缩放）：竖屏是 20:9 的窄长屏，竖排操作栏
      // 只占右侧一条；横屏可用高度只剩 ~306vp，竖排 4 个按钮（约 270vp）会直接顶到
      // 顶部工具行 —— 设备实测两者**重叠 85×108px**（收藏按钮压在「设置」上）。
      // 因此横屏把操作栏改成**右下角的横排**，信息区留在左侧。
      // 随上下控件自动隐藏：用 if 而不是 opacity(0)（透明按钮仍会被点到）
      if (this.chromeVisible) {
        Column() {
          Blank()
          if (this.landscape) {
            Row({ space: 12 }) {
              this.InfoBlock(item)
              Row({ space: 12 }) {
                this.RailButton('favorite', item.id, () => { this.toggleFavorite(item); })
                this.RailButton('played', item.id, () => { this.togglePlayed(item); })
                this.RailButton('detail', item.id, () => { this.openDetail(item); })
                this.RailButton('shuffle', item.id, () => { this.loadFeed(); })
              }
              .alignItems(VerticalAlign.Bottom)
            }
            .width('100%')
            .alignItems(VerticalAlign.Bottom)
            // 底部：12 的常规留白 + 全屏时给系统手势提示条让位（见 fullscreenBottomInsetVp）
            .padding({
              left: ThemeConstants.PAGE_PADDING,
              right: ThemeConstants.PAGE_PADDING,
              bottom: 12 + this.fullscreenBottomInsetVp
            })
          } else {
            Row({ space: 8 }) {
              this.InfoBlock(item)
              // 操作栏：收藏 / 已看 / 详情 / 换一批
              // （只传种类与条目 id，状态在 RailButton 内部读 —— 见该 Builder 的说明）
              Column({ space: 14 }) {
                this.RailButton('favorite', item.id, () => { this.toggleFavorite(item); })
                this.RailButton('played', item.id, () => { this.togglePlayed(item); })
                this.RailButton('detail', item.id, () => { this.openDetail(item); })
                this.RailButton('shuffle', item.id, () => { this.loadFeed(); })
              }
              .width(kRailWidthVp - 24)
              .alignItems(HorizontalAlign.Center)
            }
            .width('100%')
            .alignItems(VerticalAlign.Bottom)
            // 左右留白 + 底部让出进度线（见 BottomProgress）+ 全屏时给系统手势提示条让位
            .padding({
              left: ThemeConstants.PAGE_PADDING,
              right: ThemeConstants.PAGE_PADDING,
              bottom: 22 + this.fullscreenBottomInsetVp
            })
          }
        }
        .width('100%')
        .height('100%')
        .hitTestBehavior(HitTestMode.Transparent)
        .transition(TransitionEffect.OPACITY.animation({ duration: 220, curve: Curve.EaseInOut }))
      }
    }
    .width('100%')
    .height('100%')
  }

  /**
   * 底部信息区：类型徽标 + 系列名 + 标题 + 元信息 + 简介。
   *
   * 单独抽出来是因为横竖屏要把它放到不同的容器里（竖屏与竖排操作栏并排，
   * 横屏与横排操作栏并排）；简介行数按横竖屏取 1 / 2 行 —— 横屏高度紧张，
   * 多一行简介就会把标题挤出画面。
   */
  @Builder
  InfoBlock(item: MediaItem) {
    Column({ space: this.landscape ? 4 : 6 }) {
      Row({ space: 6 }) {
        Text(this.typeBadge(item))
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontWeight(FontWeight.Medium)
          // 类型徽标用品牌色实底 + `onBrand` 文字（品牌色上的专用前景色，
          // 明暗两套主题下都有足够对比度；用 `onOverlay` 会在浅色主题下发灰）
          .fontColor(this.colors().onBrand)
          .padding({ left: 8, right: 8, top: 2, bottom: 2 })
          .backgroundColor(this.colors().brandPrimary)
          .borderRadius(ThemeConstants.BADGE_RADIUS)
        if (item.officialRating.length > 0) {
          Text(item.officialRating)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onOverlay)
            .padding({ left: 8, right: 8, top: 2, bottom: 2 })
            .backgroundColor(this.colors().overlayControl)
            .borderRadius(ThemeConstants.BADGE_RADIUS)
        }
      }
      .alignItems(VerticalAlign.Center)

      if (item.seriesName.length > 0 && item.type === 'Episode') {
        Text(item.seriesName)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlayMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      Text(item.displayTitle())
        .fontSize(this.landscape ? ThemeConstants.TITLE_MEDIUM : ThemeConstants.TITLE_LARGE)
        .fontWeight(FontWeight.Medium)
        .fontColor(this.colors().onOverlay)
        .maxLines(this.landscape ? 1 : 2)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .width('100%')

      if (this.metaLine(item).length > 0) {
        Text(this.metaLine(item))
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().onOverlayMuted)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }

      if (this.overviewText(item).length > 0) {
        Text(this.overviewText(item))
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlayMuted)
          .maxLines(this.landscape ? 1 : 2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
      }
    }
    .alignItems(HorizontalAlign.Start)
    .layoutWeight(1)
  }

  /** 底部细进度线 + `已看 / 总时长` */
  @Builder
  BottomProgress() {
    Column() {
      if (this.effectiveDurationMs() > 0) {
        Row() {
          Blank()
          Text(`${formatSeconds(Math.floor(this.positionMs / 1000))} / ${formatSeconds(Math.floor(this.effectiveDurationMs() / 1000))}`)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onOverlayMuted)
        }
        .width('100%')
        .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 4 })
      }
      Progress({ value: this.progressRatio() * 100, total: 100, type: ProgressType.Linear })
        .color(this.colors().brandPrimary)
        .backgroundColor('#33000000')
        .width('100%')
        .height(3)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.End)
    // 全屏时页签栏已收起，进度线直接落在屏幕底边 —— 让出系统手势提示条那一条，
    // 否则进度线会被压在提示条下面（见 fullscreenBottomInsetVp）
    .padding({ bottom: this.fullscreenBottomInsetVp })
    // `Transparent` 而不是 `None`：设备实测里 `None` 的浮层**会把落在它身上的点按吃掉**
    // （暂停浮层挡住画面中部时，"再点一下继续"完全没反应）。
    // `Transparent` 的语义是"自身与子节点响应，且不阻塞兄弟节点"，正是浮层需要的。
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 中央"正在准备"：取流/建播放器期间给一个明确的进度感 */
  @Builder
  PreparingBadge() {
    Column({ space: 10 }) {
      LoadingProgress()
        .width(36)
        .height(36)
        .color(this.colors().onOverlay)
      Text('正在准备…')
        .fontSize(ThemeConstants.META_MEDIUM)
        .fontColor(this.colors().onOverlayMuted)
    }
    .padding({ left: 20, right: 20, top: 16, bottom: 16 })
    .backgroundColor(this.colors().overlayControlStrong)
    .borderRadius(ThemeConstants.CARD_RADIUS)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 暂停提示：中央一个大播放图标（点画面即继续） */
  @Builder
  PausedBadge() {
    Column({ space: 10 }) {
      Column() {
        SymbolGlyph($r('sys.symbol.play_fill'))
          .fontSize(ThemeConstants.ICON_HERO)
          .fontColor([this.colors().onOverlay])
      }
      .width(84)
      .height(84)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.colors().overlayControlStrong)
      .borderRadius(42)

      Text('已暂停')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().onOverlay)
        .padding({ left: 12, right: 12, top: 4, bottom: 4 })
        .backgroundColor(this.colors().overlayControlStrong)
        .borderRadius(ThemeConstants.BADGE_RADIUS)
    }
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 双击跳转的瞬时提示 */
  @Builder
  SeekHintBadge() {
    Row({ space: 8 }) {
      SymbolGlyph(this.seekHint.startsWith('快进')
        ? $r('sys.symbol.goforward_10') : $r('sys.symbol.gobackward_10'))
        .fontSize(ThemeConstants.ICON_XLARGE)
        .fontColor([this.colors().onOverlay])
      Text(this.seekHint)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().onOverlay)
    }
    .padding({ left: 18, right: 20, top: 12, bottom: 12 })
    .backgroundColor(this.colors().overlayControlStrong)
    .borderRadius(26)
    .alignItems(VerticalAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /** 本条播不了：如实说明 + 去播放页 + 自动跳过倒计时 */
  @Builder
  FailureCard() {
    Column({ space: 10 }) {
      SymbolGlyph($r('sys.symbol.xmark_circle_fill'))
        .fontSize(ThemeConstants.ICON_XXL)
        .fontColor([this.colors().warning])
      Text(this.playbackError)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().onOverlay)
        .textAlign(TextAlign.Center)
      if (this.skipLeftMs > 0) {
        Text(`${Math.ceil(this.skipLeftMs / 1000)} 秒后自动跳过`)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlayMuted)
      }
      Row({ space: 12 }) {
        Button('去播放页', { type: ButtonType.Normal, stateEffect: false })
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().onBrand)
          .backgroundColor(this.colors().brandPrimary)
          .borderRadius(ThemeConstants.BUTTON_RADIUS)
          .height(ThemeConstants.BUTTON_HEIGHT)
          .onClick(() => {
            const item: MediaItem | null = this.currentItem();
            if (item !== null) {
              this.openInPlayer(item);
            }
          })
        Button('跳过', { type: ButtonType.Normal, stateEffect: false })
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().onOverlay)
          .backgroundColor(this.colors().overlayControl)
          .borderRadius(ThemeConstants.BUTTON_RADIUS)
          .height(ThemeConstants.BUTTON_HEIGHT)
          .onClick(() => {
            this.cancelAutoSkip();
            this.advance(1);
          })
      }
    }
    .padding({ left: 24, right: 24, top: 20, bottom: 20 })
    .backgroundColor(this.colors().overlayControlStrong)
    .borderRadius(ThemeConstants.CARD_RADIUS)
  }

  /** 真的没有新内容了（服务端就这么多）：给「换一批」，不假装永远刷不完 */
  @Builder
  EndCard() {
    Column({ space: 12 }) {
      Text('这批已经看完了')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().onOverlay)
      Text('去设置里多选几个媒体库，能刷的内容会更多')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().onOverlayMuted)
        .textAlign(TextAlign.Center)
      Row({ space: 12 }) {
        Button('换一批', { type: ButtonType.Normal, stateEffect: false })
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().onBrand)
          .backgroundColor(this.colors().brandPrimary)
          .borderRadius(ThemeConstants.BUTTON_RADIUS)
          .height(ThemeConstants.BUTTON_HEIGHT)
          .onClick(() => { this.loadFeed(); })
        Button('设置', { type: ButtonType.Normal, stateEffect: false })
          .fontSize(ThemeConstants.META_MEDIUM)
          .fontColor(this.colors().onOverlay)
          .backgroundColor(this.colors().overlayControl)
          .borderRadius(ThemeConstants.BUTTON_RADIUS)
          .height(ThemeConstants.BUTTON_HEIGHT)
          .onClick(() => { this.openSettings(); })
      }
    }
    .padding({ left: 24, right: 24, top: 20, bottom: 20 })
    .backgroundColor(this.colors().overlayControlStrong)
    .borderRadius(ThemeConstants.CARD_RADIUS)
  }

  build() {
    Column() {
      if (this.status === UiState.INITIAL || this.status === UiState.LOADING) {
        LoadingState({ hint: '正在准备短视频…' })
      } else if (this.status === UiState.ERROR) {
        // 空态/错误态由父级加权容器负责垂直居中（EmptyState 自身不加 layoutWeight）
        Column() {
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
            detail: '请检查网络或服务器状态',
            actionLabel: '重试',
            onAction: () => { this.loadFeed(); }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.status === UiState.EMPTY) {
        // 空态分两种：没配过库 → 引导去设置；配过但没内容 → 如实说明
        Column() {
          EmptyState({
            message: ShortVideoPrefs.loadLibraryIds().length === 0
              ? '还没有设置短视频媒体库'
              : '所选的媒体库里没有可播放的视频',
            detail: ShortVideoPrefs.loadLibraryIds().length === 0
              ? '在设置里勾选要进入短视频模式的媒体库，「视频」页会随机连播这些库里的内容'
              : '可以换几个媒体库，或先往库里添加内容',
            actionLabel: '去设置',
            icon: $r('sys.symbol.play_circle'),
            onAction: () => { this.openSettings(); }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // 视频层（最底）→ 环境背景（更底下）→ 播放流（封面/文案/操作栏）→ 各类浮层
        Stack({ alignContent: Alignment.Center }) {
          // ① 环境背景：垫在视频面之下，只在真的出画面时出现（见 ambientVisible）
          if (this.ambientVisible()) {
            this.AmbientBackdrop()
          }

          // ② AVPlayer / 软解的渲染目标。**不要** `libraryname`：
          // 软解用的原生 XComponent 桥是全进程单例，本页走 `surfaceId` 路径，
          // 挂上同一个 libraryname 会与播放页争抢那块桥状态。
          XComponent({
            id: 'short_video_surface',
            type: XComponentType.SURFACE,
            controller: this.surfaceController
          })
            // 按画面比例设尺寸（Stack 居中）—— 这是"比例正确"的根本：
            // 不再让等比/裁剪逻辑去猜，而是让视频面的宽高比与画面一致。
            .width(this.videoBoxWidth())
            .height(this.videoBoxHeight())
            .onAreaChange((_oldArea: Area, newArea: Area) => {
              // 软解渲染缓冲几何按组件像素尺寸协商（与播放页同一口径）
              const density: number = display.getDefaultDisplaySync().densityPixels;
              this.surfaceW = Math.round(Number(newArea.width) * density);
              this.surfaceH = Math.round(Number(newArea.height) * density);
            })
            .onLoad(() => {
              this.surfaceId = this.surfaceController.getXComponentSurfaceId();
              this.bindSurface();
              // surface 比 url 晚到：此刻播放器多半已 initialized，补一次 prepare
              if (this.avPlayer !== null && this.avPlayer.state === 'initialized') {
                this.avPlayer.prepare();
              }
            })

          // ③ 一屏一条（滑到哪条播哪条）
          Swiper() {
            ForEach(this.items, (item: MediaItem, index: number) => {
              this.FeedCard(item, index)
            }, (item: MediaItem) => item.id)
          }
          .vertical(true)
          .loop(false)
          .indicator(false)
          .index(this.currentIndex)
          .onChange((index: number) => {
            if (index === this.currentIndex) {
              return;
            }
            // 滑到哪条就播哪条（这就是"连续刷"）
            this.currentIndex = index;
            this.revealChrome(true);
            this.prefetchIfNearEnd();
            this.playCurrent();
          })
          .width('100%')
          .height('100%')

          // ④ 底部进度（细线 + 时间读数）
          if (this.videoReady || this.paused) {
            this.BottomProgress()
          }

          // ⑤ 中央状态浮层（都是"看"的信息，不参与触摸）
          if (this.preparing && !this.videoReady && this.playbackError.length === 0) {
            this.PreparingBadge()
          }
          if (this.paused && this.playbackError.length === 0 && !this.preparing) {
            this.PausedBadge()
          }
          if (this.seekHint.length > 0) {
            this.SeekHintBadge()
          }

          // ⑥ 失败 / 到底（这两个卡片里有按钮，因此不设 hitTestBehavior：
          //    它们只有卡片那么大的命中区，卡片之外的点按照旧落到手势层）
          if (this.playbackError.length > 0) {
            this.FailureCard()
          } else if (this.reachedEnd && !this.appendPending) {
            this.EndCard()
          }
        }
        .layoutWeight(1)
        .width('100%')
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
    // 可用区域实测（vp）：横竖屏切换/窗口变化后画面盒子与控件布局都要重算
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      const w: number = Number(newArea.width);
      const h: number = Number(newArea.height);
      if (w > 0 && h > 0) {
        this.areaW = w;
        this.areaH = h;
        this.landscape = w > h;
      }
    })
  }
}
