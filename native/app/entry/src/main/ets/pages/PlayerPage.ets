import router from '@ohos.router';
import common from '@ohos.app.ability.common';
import { BusinessError } from '@ohos.base';
import window from '@ohos.window';
import media from '@ohos.multimedia.media';
import display from '@ohos.display';
import avSession from '@ohos.multimedia.avsession';
import { PiPWindow } from '@kit.ArkUI';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { WindowLayout } from '../common/WindowLayout';
import { PlayerAspect, PlayerAspectMode, AspectBox, kScaleTypeFitCrop } from '../common/PlayerAspect';
import { WindowFullscreen, WindowInsets, PlayerOrientation } from '../common/WindowFullscreen';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { formatSeconds } from '../common/format';
import { AppIconButton } from '../components/AppIconButton';
import { PlayerToolButton } from '../components/PlayerToolButton';
import { EmptyState } from '../components/EmptyState';
import { PlaybackState } from '../common/PlaybackState';

/** 控制条自动隐藏延时（毫秒）：给用户留出"看到并点中控件"的时间 */
const kControlsAutoHideMs: number = 5000;

/** 双击快进/快退的步长（毫秒）—— 与屏幕上 ±10s 按钮一致，符合主流播放器习惯 */
const kSkipStepMs: number = 10000;

/**
 * 单击/双击判定窗口（毫秒）。
 *
 * 为什么必须区分：主流播放器里"单击唤出控制条"与"双击两侧快进/快退"是同一块区域上的两个手势，
 * 若不区分，用户双击时控制条会闪一下（观感很差），或者单击时白送一次 10 秒跳转。
 * 300ms 与系统双击间隔阈值一致；单击动作延后 `kSingleTapDelayMs` 执行，
 * 在这段时间内若来了第二次抬手就判定为双击。
 */
const kDoubleTapMs: number = 300;
const kSingleTapDelayMs: number = 260;

/** 手指移动多少 vp 之后就不再算"点击"（判定为滑动，交给 seek/亮度/音量） */
const kTapSlopVp: number = 12;

/** 双击反馈浮层的停留时间（毫秒） */
const kRippleMs: number = 620;

/** 软解瞬时提示（打开中/跳转失败等）的自动隐去时间（毫秒） */
const kSoftNoticeMs: number = 4000;

/** 音量/亮度手势的灵敏度：约 500vp 的竖直位移对应满量程 */
const kLevelGestureRange: number = 500;

/** 播放器轨道类型（对应 media.MediaType：0=音频 1=视频 2=字幕 3=附件…） */
const kMediaTypeAudio: number = 0;
const kMediaTypeVideo: number = 1;
const kMediaTypeSubtitle: number = 2;

/**
 * 原生触摸事件类型（对齐官方 `OH_NativeXComponent_TouchEventType` 枚举值）。
 *
 * 为什么用常量而不是字面量：这些值与官方 SDK 头文件一一对应，
 * 写死数字后一旦平台调整枚举（或我们误判）就无法察觉；命名后语义自解释。
 * 来源：`ace/xcomponent/native_interface_xcomponent.h`
 *   OH_NATIVEXCOMPONENT_DOWN = 0 / UP = 1 / MOVE = 2 / CANCEL = 3 / UNKNOWN = 4
 */
const kTouchTypeDown: number = 0;
const kTouchTypeUp: number = 1;
const kTouchTypeMove: number = 2;
const kTouchTypeCancel: number = 3;

/**
 * 原生触摸兜底通道的轮询节奏（自适应退避）。
 *
 * 背景：ArkUI 手势层已经在应用层消化了触摸，原生 `DispatchTouchEvent` 实测从不回调
 * （见 startTouchPollTimer 的说明），所以常驻 60fps 轮询是纯浪费。
 * 连续 kTouchPollBackoffLimit 次读不到事件就降到 kTouchPollSlowMs；
 * 一旦读到事件立刻回到 kTouchPollFastMs，保证兜底通道真被用到时依然跟手。
 */
const kTouchPollFastMs: number = 16;
const kTouchPollSlowMs: number = 250;
const kTouchPollBackoffLimit: number = 120;

/**
 * 软解单次拉帧的最长容忍时间（毫秒）。超过即判定"原生侧卡死"并进入终态。
 *
 * 依据：正常一帧的耗时是几十毫秒（模拟器 4K 软解约 100ms 级）；
 * 设备实测「流浪地球2」(4K 8-bit HEVC) 会永久卡住不返回，
 * 因此 20 秒足以区分"慢"与"死"，又不会误杀正常的慢帧。
 */
const kSoftPullStallMs: number = 20000;

/**
 * 软解**打开会话**阶段的最长容忍时间（毫秒）。超过即判定挂起并进入终态。
 *
 * 依据：正常打开（取流探测 + 解容器 + 找流信息）在设备上是秒级；
 * 实测 4K 8-bit HEVC 会卡在 `openUrl` 90 秒以上不返回，
 * 因此 30 秒足以区分"慢"与"死"。
 */
const kSoftOpenTimeoutMs: number = 30000;

/**
 * 软解**上屏连续失败**多少次即判定"渲染不可用"并停止软解（终态）。
 *
 * 为什么要有一个（而不是"失败就一直重试"）：软解只解码视频（无音频输出），
 * 上屏失败就是"用户什么都看不到"。历史上失败被静默忽略，表现成永远的黑屏
 * （设备实测：EGL 在工作线程初始化，UI 线程每帧 `eglSwapBuffers` 报
 * `EGL_BAD_SURFACE`，帧号照涨、屏幕全黑、无任何提示）。
 * 取 3 而不是 1：偶发一次（surface 正在重建等）允许自愈（原生侧会在帧循环里
 * 重新绑定当前 surface），连续失败才说明真的上不了屏。
 */
const kSoftRenderErrorLimit: number = 3;

/**
 * 锁定态"锁提示"的停留时间（毫秒）。
 *
 * 锁定后画面应当干净，锁只在用户单击时亮一下（见 `showLockBadge`）：
 * 3.5 秒足够看清"锁在哪、怎么解"，又不至于长期压在画面上。
 */
const kLockBadgeMs: number = 3500;

/**
 * 刚点完锁定按钮后的"宽限期"（毫秒）：这段时间内的单击不再显示锁提示。
 *
 * 为什么需要（设备实测）：锁定按钮就在视频画面之上，同一次点击的抬手事件
 * 还会被视频区的手势状态机看到（原生触摸通道与 ArkUI 手势层是两条通道），
 * 于是"点锁定"立刻又被判成"单击 → 显示锁"，锁提示当场就弹出来了 ——
 * 与"锁模式单击才显示锁"的语义不符。给 450ms 宽限期把这次点击吃掉。
 */
const kLockGraceMs: number = 450;

/**
 * 是否是图形字幕（位图字幕：PGS/SUP/VOBSUB/DVB…）。
 *
 * 这类字幕的内容是图片，服务端**无法**转成文本，播放器也解析不出可渲染的文本，
 * 因此面板里明确标注"暂不支持"，而不是让用户点了没反应。
 * 与原生 `jellyfin::IsImageSubtitleCodec`（native/core/subtitle_url.cpp）保持一致。
 */
function isImageSubtitleCodec(codec: string): boolean {
  const c: string = codec.toLowerCase();
  return c === 'pgssub' || c === 'hdmv_pgs_subtitle' || c === 'pgs' || c === 'sup'
    || c === 'dvdsub' || c === 'dvd_subtitle' || c === 'vobsub' || c === 'dvbsub'
    || c === 'dvb_subtitle' || c === 'xsub';
}

@Entry
@Component
struct PlayerPage {
  @State private itemId: string = '';
  @State private title: string = '播放';
  /** 集数/季信息文案：参数解析时一次性算好，不在 build 里调用 getter（见下方稳定性修复说明） */
  @State private typeLabel: string = '';
  @State private playUrl: string = '';
  @State private stateText: string = 'idle';
  @State private positionMs: number = 0;
  @State private durationMs: number = 0;
  @State private isPlaying: boolean = false;
  @State private status: string = UiState.INITIAL;
  /** FFmpeg 软解回放状态：逐帧拉取并用 PixelMap 渲染（硬解不支持的编码走这条路） */
  @State private softPlaying: boolean = false;
  /**
   * 软解暂停：软解会话没有 pause API，暂停即"停掉拉帧定时器"，
   * 恢复时重新启动定时器继续从当前 pts 拉帧（画面停在最后一帧，符合暂停语义）。
   */
  @State private softPaused: boolean = false;
  /** 已到 initialized 但视频面尚未就绪：等 XComponent onLoad 拿到 surfaceId 后再 prepare */
  private preparePendingSurface: boolean = false;
  /**
   * 软解跳转的"乐观位置"与保持窗口：seek 是排队的（见 seekTo），
   * 在画面追上目标之前不要让旧位置的帧把进度条拽回去。
   */
  private softSeekTargetMs: number = -1;
  private softSeekHoldUntil: number = 0;
  /** 是否已因硬解失败自动回退过软解（只回退一次） */
  private softFallbackTried: boolean = false;
  /**
   * 回退软解时要接上的播放位置（毫秒，0 表示没有）。
   *
   * 只有"播放中途硬解失败"才会有值：这时软解必须从当前位置续上，
   * 而不是用进播放页时的续播点（那是"从头/从上次退出点"的语义）。
   */
  private softFallbackStartMs: number = 0;
  /**
   * 软解播放的**用户可见**提示：只在需要用户知情/操作时出现
   * （正在打开、超时、打开失败、跳转失败、播放结束、已自动切换软解）。
   *
   * 为什么不再保留原来的常驻诊断行：那一行会把"第 N 帧 / 抓了多少 MB / EGL 是否已渲染 /
   * 锁定与控制条状态"直接压在画面上，属于开发期的调试显示，不能出现在正式播放界面里。
   * 软解正常的播放进度由进度条与时间文案承担，无需额外文字。
   */
  @State private softStatus: string = '';
  private softTimerId: number = -1;
  /**
   * 软解解码目标宽度（px）：由原生侧协商出的渲染缓冲宽度决定（见 startSoftPlay）。
   * 0 表示按源分辨率解码，不做缩放。
   */
  private softDecodeMaxWidth: number = 0;
  /** 软解提示的自动隐去定时器（用户可见的提示不该永久压在画面上） */
  private softNoticeTimerId: number = -1;
  /**
   * 软解的渲染器是否起不来（EGL 初始化失败/上屏失败）。
   *
   * 为什么要单独记一个标志：软解只解码视频（无音频输出），渲染起不来就等于"什么都没有"。
   * 此时**必须**让用户看到原因、并让后续流程进入终态，而不是让会话继续偷偷解码、
   * 把画面丢进虚空（历史缺陷：渲染每帧失败却只显示"已自动切换软解播放"，屏幕全黑）。
   */
  private softRenderFailed: boolean = false;
  /** 连续上屏失败计数：偶发一次可容忍，连续失败必须给终态（否则就是"永久黑屏"） */
  private softRenderErrorStreak: number = 0;
  private softPulling: boolean = false;
  /** 当前这次拉帧的起始时刻（0 表示空闲）；用于卡死看门狗 */
  private softPullStartedAt: number = 0;
  /** 最近一次成功解出的帧号；卡死时用它说明"卡在哪一帧" */
  private softLastFrameIndex: number = 0;
  /** 打开软解会话是否已按超时判定为挂起（true 时不再继续后续流程） */
  private softOpenTimedOut: boolean = false;
  @State private errorMsg: string = '';
  @State private showControls: boolean = true;
  @State private playbackSpeed: number = 1.0;
  @State private controlsLocked: boolean = false;
  /**
   * 锁定态下"锁提示"是否可见。
   *
   * 需求：锁模式**单击显示锁**，再次点击锁才取消锁定 —— 所以锁定后默认什么都不显示
   * （画面干净），单击才把锁亮出来；解锁也只能点锁本身。
   */
  @State private lockBadgeVisible: boolean = false;
  /** 锁提示的自动收起定时器 */
  private lockBadgeTimerId: number = -1;
  @State private volume: number = 1.0;
  @State private gestureFeedback: string = '';
  @State private gestureIcon: string = '';
  @State private gestureRatio: number = -1;
  @State private showFeedback: boolean = false;
  /**
   * 画面比例模式：适应 / 填充 / 拉伸 / 原始（见 `common/PlayerAspect.ets`）。
   *
   * 为什么要有它：系统 AVPlayer 的 `videoScaleType` 默认值是"拉伸铺满"，
   * 16:9 的片子铺到 20:9 的手机上会被拉长；而不同用户对"黑边 / 裁剪"的偏好也不同，
   * 主流播放器（Infuse 的「缩放」菜单）都会把选择权交给用户。
   */
  @State private aspectMode: PlayerAspectMode = 'contain';
  /** 视频原始像素尺寸（硬解来自 AVPlayer.width/height，软解来自 softPlayOpen 返回值） */
  @State private videoWidthPx: number = 0;
  @State private videoHeightPx: number = 0;
  /**
   * 播放区实测尺寸（vp，来自根 Stack 的 onAreaChange），用于按比例算视频面尺寸。
   *
   * 为什么必须是 `@State` 而不能是普通字段：ArkUI 只重新执行"读到了变化状态"的那部分更新闭包。
   * XComponent 的 `.width(this.videoAreaWidth())` 只读取 `aspectMode` / `videoWidthPx` / `videoHeightPx`
   * 这几个 @State，**并不读 `landscape`**；若这里是普通字段，横竖屏切换时虽然 `landscape` 变了
   * （底部工具行会重排），但 XComponent 那段闭包不会被重新执行 —— 视频面会一直停在竖屏算出的几何上，
   * 表现为"横屏后画面缩在屏幕中间、两侧大片黑边"。设备实测确认过该缺陷（横屏 2844x1260 时视频面仍是竖屏的 371x209vp）。
   */
  @State private areaWidthVp: number = 0;
  @State private areaHeightVp: number = 0;
  /** 单击/双击判定状态 */
  private lastTapUpAt: number = 0;
  private lastTapX: number = 0;
  private singleTapTimerId: number = -1;
  /** 双击反馈：'forward' | 'backward' | '' */
  @State private rippleSide: string = '';
  @State private rippleOpacity: number = 0;
  @State private rippleScale: number = 1;
  private rippleTimerId: number = -1;
  /**
   * 亮度（0–1，窗口级）。手势调节直接作用于窗口亮度，和主流播放器一致。
   *
   * 名字不能叫 `brightness`：`CustomComponent` 已有同名通用属性方法（`.brightness()`），
   * 组件成员同名会被编译器判为"类型不兼容的重写"（10505001）。
   */
  @State private windowBrightness: number = 0.5;
  /** `setWindowBrightness` 是否可用；不可用时退化为"画面上盖一层黑"的模拟调暗 */
  private windowBrightnessOk: boolean = false;
  /** 右侧时间显示：false 显示总时长，true 显示剩余时长（点击可切换） */
  @State private showRemaining: boolean = false;
  private windowRef: window.Window | null = null;
  /** 播放期间保持常亮；退出播放页时恢复系统默认 */
  private keepScreenOnApplied: boolean = false;
  private brightnessBase: number = 0.5;
  private brightnessLastY: number = 0;
  private volumeBase: number = 1.0;
  private volumeLastY: number = 0;
  private playbackOptions: string = '{}';
  private stopped: boolean = false;
  private timerId: number = -1;
  private hideTimerId: number = -1;
  /** 最近一次锁定/解锁时刻：用于屏蔽"同一次点击穿透到覆盖层"造成的立即解锁 */
  private lockChangedAt: number = 0;
  /** 软解播放：最近一次进度上报时刻（节流用）与当前位置 */
  private lastProgressReportAt: number = 0;
  private softPositionMs: number = 0;
  /** 长按 2× 快进：计时器与"是否处于长按加速中"（主流播放器标配的手势） */
  private longPressTimerId: number = -1;
  private longPressBoosting: boolean = false;
  /** 系统媒体会话（AVSession）；null 表示未创建 */
  private avSessionRef: avSession.AVSession | null = null;
  /** 视频区触摸事件轮询定时器（用于原生侧 DispatchTouchEvent 转发） */
  private touchPollTimerId: number = -1;
  /** 上一次处理的触摸事件时间戳（避免重复处理） */
  private lastProcessedTouchTs: number = 0;
  /** 自适应退避：连续读不到事件的次数（达到上限后降到低频轮询） */
  private touchPollBackoff: number = 0;
  /** 当前轮询间隔（毫秒），用于判断是否需要重建定时器 */
  private touchPollIntervalMs: number = 16;
  /** 可切换的媒体流列表（由详情页随路由参数传入）与当前音频/字幕索引 */
  @State private mediaStreams: Object[] = [];
  @State private audioStreamIndex: number = -1;
  @State private subtitleStreamIndex: number = -1;
  /** 音频/字幕选择面板是否展开（播放页自有覆盖层，不依赖详情页的 bindSheet 机制） */
  @State private showTrackSheet: boolean = false;
  /**
   * 播放器（AVPlayer）自带的音轨列表 —— 来自 `getTrackDescription()`。
   *
   * 为什么以播放器的轨道为准而不是 Jellyfin 的 MediaStreams：
   * 直连/直传时播放器拿到的是**原始文件**，能切换的轨道就是文件里的轨道；
   * 用 `selectTrack()` 切换不需要重新请求播放地址，**不打断播放**。
   * Jellyfin 的 MediaStreams 只用来补全"这条轨道是什么语言/什么编码"的文案。
   */
  @State private avAudioTracks: Object[] = [];
  /** 播放器自带的字幕轨（内嵌字幕）：直接 selectTrack 即可切换，无需再取字幕文件 */
  @State private avSubtitleTracks: Object[] = [];
  /** 播放器当前选中的音轨 index（-1 = 未知/未取到） */
  @State private avAudioIndex: number = -1;
  /** 已加载的外挂字幕在播放器里的轨道 index（-1 = 未加载） */
  @State private avSubtitleIndex: number = -1;
  /** 当前字幕文本：外挂字幕由 `subtitleUpdate` 推给应用，需要应用自己渲染 */
  @State private subtitleText: string = '';
  /** 轨道面板内的提示（切换结果、失败原因、软解模式限制等） */
  @State private trackNote: string = '';
  /** 当前 MediaSourceId（Jellyfin 字幕端点需要它） */
  private mediaSourceId: string = '';
  /**
   * 续播起点（毫秒）：由宿主页面按条目的观看进度传入。
   *
   * 为什么要有它：媒体库「继续观看」的语义就是"接着上次看"，而此前播放器
   * 一律从 0:00 起播 —— 点继续观看卡片 → 详情页 → 播放，等于**从头再来**，
   * 进度条与"继续观看"也就名不副实。这里在 `prepared` 之后 seek 到该位置。
   */
  private startPositionMs: number = 0;
  /** 续播只做一次（重开播放/切轨道后不重复 seek 回起点） */
  private resumeApplied: boolean = false;
  private feedbackTimerId: number = -1;
  private seekBaseMs: number = 0;
  /** 本次手势判定出的方向：'' 未定 / 'seek' 水平 / 'level' 垂直（亮度或音量） */
  private gestureAxis: string = '';
  /** 按下点坐标：方向与幅度都按"相对按下点的累计位移"计算（见 onTouch 里的说明） */
  private touchDownX: number = 0;
  private touchDownY: number = 0;
  private seekDragMs: number = 0;
  private seekLastX: number = 0;
  private lastSeekForward: boolean = true;
  private avPlayer: media.AVPlayer | null = null;
  private surfaceId: string = '';
  /** XComponent 控制器：surface 就绪后用它拿到 surfaceId（软解 EGL 渲染与 AVPlayer 共用） */
  private surfaceController: XComponentController = new XComponentController();

  // ─────────────────────────── 画中画（PiP）───────────────────────────
  /**
   * PiP 控制器（`@ohos.PiPWindow`）。
   *
   * 为什么用系统画中画而不是自己画小窗：画中画的价值是"退到桌面/切到别的应用后还能看"，
   * 这必须由窗口管理器提供小窗能力，应用侧只负责把视频画面挂上去。
   * 用系统视频模板（`VIDEO_PLAY`）还能白拿小窗里的播放/暂停控件与"一键回全屏"。
   */
  private pipController: PiPWindow.PiPController | null = null;
  /** 画中画是否已启动（按钮选中态、二次点击退出） */
  @State private pipActive: boolean = false;
  /** XComponent 组件像素尺寸（vp → px），用于 EGL 缓冲几何 */
  private surfaceWidthPx: number = 0;
  private surfaceHeightPx: number = 0;

  // ─────────────────────────── 全屏观看 ───────────────────────────
  /**
   * 是否已进入沉浸式全屏（系统栏已隐藏）。
   *
   * 用途有二：① 避免重复进入/退出造成无谓的平台调用；
   * ② 告诉 `WindowFullscreen.insets()` 要不要避让系统栏 ——
   *    系统栏已被我们隐藏时就不该再留出它的高度，否则横屏下会白丢一条可用区。
   */
  private immersive: boolean = false;
  /** `setWindowLayoutFullScreen(true)` 是否成功（失败时页面仍可用，只是不铺满） */
  private layoutFullscreenOk: boolean = false;
  /** 播放页的屏幕方向选择：默认跟随传感器（横过来即横屏全屏，主流播放器行为） */
  @State private orientation: PlayerOrientation = 'auto';
  /**
   * 进入播放页前的窗口首选方向，退出时还原。
   *
   * 为什么不统一还原成 `PORTRAIT`：本应用其它页面（首页/媒体库/详情）都是竖屏布局，
   * 但用户在系统设置里的方向偏好未知（可能是"自动旋转"）。还原成进入前的实际值
   * 才既保证其它页面回到竖屏形态、又不越权改用户自己的设定。-1 表示当时没读到。
   */
  private savedOrientation: number = -1;
  /**
   * 当前需要避让的安全区（vp）。
   *
   * 视频层不需要它（全屏观看的目的就是铺满），但**控件层必须**：
   * 沉浸式布局之后系统不再替我们避让，若不内缩，返回按钮会被状态栏/挖孔压住。
   */
  @State private insets: WindowInsets = { top: 0, bottom: 0, left: 0, right: 0 };
  /** 当前播放区是否为横向（宽 > 高）：控件布局按它切换紧凑/常规形态 */
  @State private landscape: boolean = false;
  /** 方向切换是否不受平台支持（如不支持传感器旋转的设备）：一次性告知用户 */
  private orientationUnavailableNotified: boolean = false;
  /** 是否已订阅窗口尺寸变化（旋转后需要重算避让区与视频面几何） */
  private windowSizeSubscribed: boolean = false;

  // 支持倍速列表
  static readonly SPEEDS: number[] = [0.5, 1.0, 1.25, 1.5, 2.0];

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idVal: Object | undefined = params['itemId'];
      const titleVal: Object | undefined = params['title'];
      const urlVal: Object | undefined = params['playUrl'];
      const optsVal: Object | undefined = params['playbackOptions'];
      const startVal: Object | undefined = params['startPositionMs'];
      if (typeof idVal === 'string') {
        this.itemId = idVal;
      }
      if (typeof startVal === 'number' && startVal > 1000) {
        this.startPositionMs = startVal;
      }
      if (typeof titleVal === 'string' && titleVal.length > 0) {
        this.title = titleVal;
      }
      if (typeof urlVal === 'string') {
        this.playUrl = urlVal;
      }
      if (typeof optsVal === 'string') {
        this.playbackOptions = optsVal;
      }
      const streamsVal: Object | undefined = params['mediaStreams'];
      if (typeof streamsVal === 'string' && streamsVal.length > 2) {
        try {
          this.mediaStreams = JSON.parse(streamsVal) as Object[];
        } catch (err) {
          this.mediaStreams = [];
        }
      }
    }
    // 从传入的播放参数里取出当前音频/字幕索引，供播放中切换时显示与改值
    try {
      const opts: ESObject = JSON.parse(this.playbackOptions) as ESObject;
      this.audioStreamIndex = JsonUtil.getNumber(opts, 'audioStreamIndex', -1);
      this.subtitleStreamIndex = JsonUtil.getNumber(opts, 'subtitleStreamIndex', -1);
    } catch (err) {
      this.audioStreamIndex = -1;
      this.subtitleStreamIndex = -1;
    }
    this.typeLabel = this.computeTypeLabel();
    // 画面尺寸**先从服务端元数据取**（MediaStreams 的 Width/Height）：
    // 这样视频面在 surface 创建之前就是正确比例，播放中不需要再改 surface 尺寸。
    // 为什么重要：AVPlayer 绑定 surface 之后再改 XComponent 尺寸会触发 surface 重建，
    // 实测会把硬解播放打成错误 → 自动回退软解（等于"本该硬解的片子只能软解"）。
    this.applyVideoSizeFromStreams();
    this.openPlayer();
    this.timerId = setInterval(() => {
      if (this.isPlaying) {
        this.refreshState();
      }
    }, 1000);
    this.scheduleHideControls();
    // 启动视频区触摸事件轮询：从原生侧 DispatchTouchEvent 捕获的触摸事件中读取并处理手势
    this.startTouchPollTimer();
    // 窗口实例 + 进入沉浸式全屏：亮度手势 / 播放常亮 / 全屏都依赖窗口实例，
    // 这里一次取回并立刻进入全屏，避免"先竖屏带系统栏看一会儿再进全屏"的跳变。
    this.enterFullscreen();
  }

  /**
   * 重新显示播放页（从详情页返回、或从后台切回）时再次进入全屏。
   *
   * 为什么必须在 onPageShow 而不是只在 aboutToAppear：
   * 播放页切到后台时我们已经退出全屏（见 onPageHide），若不在这里恢复，
   * "按 Home 再回来"之后播放页就变成带系统栏的普通页面了。
   */
  onPageShow(): void {
    if (!this.immersive) {
      this.enterFullscreen();
    }
  }

  onPageHide(): void {
    this.stopTouchPollTimer();
    // 离开播放页（后台/切页）不主动退小窗：画中画的意义正是"离开页面还能看"；
    // 但组件真正销毁时必须收掉，否则会留下一个孤儿小窗（见 aboutToDisappear）。

    // 页面切到后台：恢复系统亮度与常亮设置，避免把"播放页的窗口亮度"带到其它界面
    this.releaseWindowOverrides();
    // 同时退出沉浸式全屏并还原方向：用户已经在看别的界面（甚至别的应用），
    // 此时若仍隐藏系统栏、仍锁着横屏，会被当成系统级异常。
    this.exitFullscreen();
    this.flushStop();
  }

  /**
   * 恢复窗口级副作用（亮度、常亮）。
   *
   * 为什么不留在 `aboutToDisappear` 里做：投影/后台播放时页面只是 onPageHide，
   * 但用户已经在看别的界面（甚至别的应用），此时窗口亮度必须立刻还给系统，
   * 否则"整个屏幕偏暗"会被当成应用 bug。
   */
  private releaseWindowOverrides(): void {
    this.applyKeepScreenOn(false);
    if (this.windowRef !== null && this.windowBrightnessOk) {
      // 0 表示"跟随系统亮度"（窗口亮度 API 的约定），即把手动设置的亮度还回去。
      // 手势调节时下限被夹到 0.01，所以 0 只可能来自这里。
      this.windowRef.setWindowBrightness(0).catch((_err: Error) => {});
    }
  }

  aboutToDisappear(): void {
    // 页面销毁必须退出画中画：小窗与页面共用同一个 XComponent surface，
    // 页面没了小窗就成了孤儿（系统也会因此报错）
    this.stopPiP();
    // 离开播放页必须停掉软解会话（解码线程 + 取流都要释放）
    this.stopSoftPlay();
    if (this.timerId >= 0) {
      clearInterval(this.timerId);
      this.timerId = -1;
    }
    if (this.hideTimerId >= 0) {
      clearTimeout(this.hideTimerId);
      this.hideTimerId = -1;
    }
    if (this.feedbackTimerId >= 0) {
      clearTimeout(this.feedbackTimerId);
      this.feedbackTimerId = -1;
    }
    if (this.singleTapTimerId >= 0) {
      clearTimeout(this.singleTapTimerId);
      this.singleTapTimerId = -1;
    }
    if (this.rippleTimerId >= 0) {
      clearTimeout(this.rippleTimerId);
      this.rippleTimerId = -1;
    }
    this.stopTouchPollTimer();
    this.releaseWindowOverrides();
    // 离开播放页必须退出沉浸式全屏并还原方向：否则其它页面会顶着"没有系统栏 + 锁横屏"，
    // 用户只能靠杀进程恢复。与 onPageHide 的退出是幂等的（见 exitFullscreen 的状态判断）。
    this.exitFullscreen();
    this.flushStop();
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private scheduleHideControls(): void {
    if (this.hideTimerId >= 0) {
      clearTimeout(this.hideTimerId);
      this.hideTimerId = -1;
    }
    if (this.controlsLocked || !this.showControls) {
      return;
    }
    // 轨道面板展开时不自动隐藏控件：面板是挂在控制条之上的覆盖层，
    // 控制条一消失用户就会觉得"面板也跟着没了"，且面板需要持续可点。
    if (this.showTrackSheet) {
      return;
    }
    // 自动隐藏时间：3s → 5s。3 秒对"找到并点中某个控件"偏紧（用户与自动化都容易错过），
    // 5 秒是主流播放器的常见取值；播放中控件仍会自动让位给画面。
    this.hideTimerId = setTimeout(() => {
      if (this.isPlaying && !this.controlsLocked) {
        this.showControls = false;
      }
    }, kControlsAutoHideMs);
  }

  private revealControls(): void {
    this.showControls = true;
    this.scheduleHideControls();
  }

  // ─────────────────────────── 画中画 ───────────────────────────

  /**
   * 进入/退出画中画。
   *
   * 系统契约（`@ohos.PiPWindow`）：
   * 1. `isPiPEnabled()` 为 false 时**不要**尝试创建 —— 它表示系统里本应用的画中画开关没开
   *    （设置 → 应用 → 画中画），此时 `create()` 会直接失败。这里先判定并告诉用户去哪打开，
   *    而不是抛一个看不懂的错误码。
   * 2. `create()` 需要**视频画面所在的那个 `XComponentController`**：系统会把该 XComponent 的
   *    surface 搬进小窗继续渲染 —— 所以播放不会中断，也不需要重开播放器或重新取流。
   * 3. 退出走 `stopPiP()`；`stateChange` 回调同步本地状态，避免按钮态与真实窗口不一致。
   */
  private async togglePiP(): Promise<void> {
    if (this.pipActive) {
      await this.stopPiP();
      return;
    }
    if (!PiPWindow.isPiPEnabled()) {
      this.setSoftNotice('系统未开启画中画：请到「设置 → 应用 → 本应用 → 画中画」打开后重试', true);
      return;
    }
    if (this.surfaceId.length === 0) {
      this.setSoftNotice('视频画面尚未就绪，暂时无法进入画中画', false);
      return;
    }
    try {
      const config: PiPWindow.PiPConfiguration = {
        context: getContext(this) as common.UIAbilityContext,
        componentController: this.surfaceController,
        templateType: PiPWindow.PiPTemplateType.VIDEO_PLAY
      };
      this.pipController = await PiPWindow.create(config);
      this.pipController.on('stateChange', (state: PiPWindow.PiPState, reason: string) => {
        if (state === PiPWindow.PiPState.STARTED) {
          this.pipActive = true;
          this.syncPiPControls();
        } else if (state === PiPWindow.PiPState.STOPPED) {
          this.pipActive = false;
        } else if (state === PiPWindow.PiPState.ERROR) {
          this.pipActive = false;
          this.setSoftNotice(`画中画出错：${reason}`, false);
        }
      });
      await this.pipController.startPiP();
      this.pipActive = true;
      // 小窗里的系统控件要反映"当前在播还是暂停"，否则图标与实际状态相反
      this.syncPiPControls();
    } catch (err) {
      const e: BusinessError = err as BusinessError;
      this.pipActive = false;
      this.pipController = null;
      this.setSoftNotice(`进入画中画失败（code=${e.code}）`, false);
    }
  }

  /** 退出画中画：离开播放页/退出应用前也要调（避免留下一个孤儿小窗） */
  private async stopPiP(): Promise<void> {
    const controller: PiPWindow.PiPController | null = this.pipController;
    this.pipController = null;
    this.pipActive = false;
    if (controller === null) {
      return;
    }
    try {
      controller.off('stateChange');
      await controller.stopPiP();
    } catch (err) {
      // 小窗可能已被系统关闭：忽略
    }
  }

  /** 把播放/暂停状态同步给小窗控件 */
  private syncPiPControls(): void {
    if (this.pipController === null) {
      return;
    }
    try {
      this.pipController.updatePiPControlStatus(
        PiPWindow.PiPControlType.VIDEO_PLAY_PAUSE,
        this.isPlaying ? PiPWindow.PiPControlStatus.PLAY : PiPWindow.PiPControlStatus.PAUSE);
    } catch (err) {
      // 同步失败不影响播放
    }
  }

  /**
   * 控制面板里的"非功能区域"（顶栏 / 中央控制簇 / 底部控制条之间的空白）。
   *
   * 为什么单独做一个可点容器：面板是**整屏**覆盖层，用户点它的空白处时事件被面板吃掉、
   * 什么都不发生 —— 观感是"想收起面板却收不起来"。这里用 `layoutWeight(1)` 的透明容器
   * 占住空白，点它即撤下面板（与点画面一次等价），符合"控制面板可以点击非功能区域撤离"。
   */
  @Builder
  ControlDismissArea() {
    Column()
      .width('100%')
      .layoutWeight(1)
      .backgroundColor(Color.Transparent)
      .onClick(() => {
        this.hideControlsByUser();
      })
  }

  /** 用户主动撤下控制面板（与自动隐藏区分：这个不看是否正在播放） */
  private hideControlsByUser(): void {
    if (this.hideTimerId >= 0) {
      clearTimeout(this.hideTimerId);
      this.hideTimerId = -1;
    }
    this.showControls = false;
  }

  // ─────────────────────────── 画面比例 ───────────────────────────

  /** 屏幕像素密度（px / vp），「原始」比例的 1:1 换算需要它 */
  private density(): number {
    try {
      const d: number = display.getDefaultDisplaySync().densityPixels;
      return d > 0 ? d : 1;
    } catch (_e) {
      return 1;
    }
  }

  /** 播放区可用尺寸（vp）：优先用根容器实测值，没有时退回屏幕尺寸 */
  private areaWidth(): number {
    return this.areaWidthVp > 0 ? this.areaWidthVp : this.getScreenWidth();
  }

  private areaHeight(): number {
    if (this.areaHeightVp > 0) {
      return this.areaHeightVp;
    }
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const density: number = info.densityPixels > 0 ? info.densityPixels : 1;
      return Math.floor(info.height / density);
    } catch (_e) {
      return 640;
    }
  }

  /** 当前比例模式下的画面盒子（宽高 vp + 视频面缩放类型） */
  private aspectBox(): AspectBox {
    return PlayerAspect.box(this.aspectMode, this.videoWidthPx, this.videoHeightPx,
                            this.areaWidth(), this.areaHeight(), this.density());
  }

  /**
   * 用服务端元数据里的视频尺寸（`MediaStreams[].Width/Height`）预置画面比例。
   *
   * 为什么不用"等 AVPlayer prepared 后再取 `avPlayer.width/height`"：
   * 那时 surface 已经被 AVPlayer 绑定，此时再改 XComponent 尺寸会触发 surface 重建，
   * 实测导致硬解播放报错并回退软解。**先知道尺寸 → 一次就把视频面摆对**才是正解；
   * prepared 后读到的尺寸只在"和元数据不一致"时用于纠正（见 createAvPlayer）。
   */
  private applyVideoSizeFromStreams(): void {
    for (let i: number = 0; i < this.mediaStreams.length; i++) {
      const stream: ESObject = this.mediaStreams[i] as ESObject;
      const type: string = JsonUtil.getString(stream, 'Type', '').toLowerCase();
      if (type !== 'video') {
        continue;
      }
      const w: number = JsonUtil.getNumber(stream, 'Width', 0);
      const h: number = JsonUtil.getNumber(stream, 'Height', 0);
      if (w > 0 && h > 0) {
        this.videoWidthPx = w;
        this.videoHeightPx = h;

        return;
      }
    }
  }

  /** 视频面的宽度（vp）：按比例算出来，而不是永远铺满整屏 */
  private videoAreaWidth(): number {
    return this.aspectBox().width;
  }

  private videoAreaHeight(): number {
    return this.aspectBox().height;
  }

  /** 比例模式对应的软解渲染模式数字（与原生 ScaleMode 顺序一致） */
  private aspectModeIndex(): number {
    if (this.aspectMode === 'cover') {
      return 1;
    }
    if (this.aspectMode === 'stretch') {
      return 2;
    }
    if (this.aspectMode === 'original') {
      return 3;
    }
    return 0;
  }

  /**
   * 把比例应用到硬解播放器：`videoScaleType`（默认值是"拉伸铺满"，必须显式指定）。
   *
   * 注意："适应/原始"靠**视频面本身的宽高比**实现（见 aspectBox），
   * 这里只是让 AVPlayer 不要在视频面内部再做拉伸/裁剪。
   */
  private applyAspectToAvPlayer(): void {
    if (this.avPlayer === null) {
      return;
    }
    try {
      this.avPlayer.videoScaleType = this.aspectBox().scaleType === kScaleTypeFitCrop
        ? media.VideoScaleType.VIDEO_SCALE_TYPE_FIT_CROP
        : media.VideoScaleType.VIDEO_SCALE_TYPE_FIT;
    } catch (_e) {
      // 播放器状态不允许设置时忽略：比例会在下次 prepared 时重新应用
    }
  }

  /** 把比例应用到软解渲染器（EGL 侧按模式换算顶点缩放） */
  private applyAspectToSoftRenderer(): void {
    if (!this.softPlaying) {
      return;
    }
    JellyfinNative.softPlaySetScale(this.aspectModeIndex());
  }

  /**
   * 循环切换比例模式，并把结果反馈给用户。
   *
   * 反馈里带"源画面尺寸 · 画幅比"（如 `1920×1080 · 16:9`）：
   * 用户点「比例」时最需要知道的就是片子本身是什么比例，主流播放器都会标注。
   */
  private cycleAspect(): void {
    this.aspectMode = PlayerAspect.next(this.aspectMode);
    this.applyAspectToAvPlayer();
    this.applyAspectToSoftRenderer();
    const source: string = PlayerAspect.describe(this.videoWidthPx, this.videoHeightPx);
    this.gestureIcon = 'aspect';
    this.gestureFeedback = `${PlayerAspect.label(this.aspectMode)}`
      + (source.length > 0 ? ` · 源 ${source}` : '');
    this.gestureRatio = -1;
    this.showFeedback = true;
    this.dismissFeedback();
    this.revealControls();
  }

  // ─────────────────────── 窗口：亮度 / 常亮 ───────────────────────

  // ─────────────────────── 全屏观看：进入 / 退出 / 方向 ───────────────────────

  /**
   * 进入沉浸式全屏（隐藏系统状态栏与导航栏 + 布局铺满）并恢复播放页的方向选择。
   *
   * 时序要点：窗口实例是异步取回的（`window.getLastWindow`）。此前 `aboutToAppear` 里
   * 只是"顺手取一下"，取不到就永远没有窗口 —— 全屏会静默失效。
   * 因此这里以"取到窗口"为前置条件，取到后立刻继续走全屏流程，并在之后订阅
   * 尺寸变化（旋转会改窗口尺寸，控件避让区与视频面几何都要跟着重算）。
   */
  private enterFullscreen(): void {
    if (this.windowRef === null) {
      this.ensureWindow().then(() => {
        if (this.windowRef !== null) {
          this.enterFullscreen();
        }
      });
      return;
    }
    if (!this.immersive) {
      // 先记住进入前的方向设置，退出时原样还原
      this.savedOrientation = WindowFullscreen.currentOrientation(this.windowRef);
      this.immersive = true;
      WindowFullscreen.enter(this.windowRef).then((result) => {
        this.layoutFullscreenOk = result.layoutFullscreen;
        // 系统栏隐藏失败时布局仍可用，但控件必须继续避让系统栏，故在此刷新一次避让区
        this.refreshInsets();
      });
      this.subscribeWindowSizeChange();
    }
    this.applyOrientation();
    // 首次进入就把避让区取准（旋转/系统栏变化时由 windowSizeChange 与 avoidAreaChange 再刷新）
    this.refreshInsets();
  }

  /**
   * 退出沉浸式全屏并还原窗口方向。
   *
   * 与 `enterFullscreen` 成对出现，覆盖三条退出路径：
   * ① 返回上一页（`aboutToDisappear`）；② 切到后台（`onPageHide`）；
   * ③ 用户主动退出播放页时先 `flushStop()` 再 `router.back()` —— 三者都会走到这里。
   */
  private exitFullscreen(): void {
    this.unsubscribeWindowSizeChange();
    if (!this.immersive && this.savedOrientation < 0) {
      return;
    }
    this.immersive = false;
    const win: window.Window | null = this.windowRef;
    if (win !== null) {
      WindowFullscreen.exit(win).then(() => {
        // 系统栏重新出现后，其它页面需要按常规避让；这里只记录，播放页即将离开
      });
      WindowFullscreen.restoreOrientation(win, this.savedOrientation);
    }
    this.savedOrientation = -1;
  }

  /**
   * 应用当前方向选择，并把平台是否真的接受这个设置如实反馈给用户。
   *
   * 为什么必须反馈：官方文档明确 `setPreferredOrientation` 对
   * "不支持传感器旋转的设备、2in1 设备与子窗口"不生效。若静默失败，
   * 用户点「横屏」却什么都没发生，只能当成应用坏了（这正是"异常必须到达终态"的约定）。
   */
  private applyOrientation(): void {
    if (this.windowRef === null) {
      return;
    }
    const target: PlayerOrientation = this.orientation;
    WindowFullscreen.setOrientation(this.windowRef, target).then((ok) => {
      if (!ok && !this.orientationUnavailableNotified) {
        this.orientationUnavailableNotified = true;
        this.setSoftNotice('当前设备不支持旋转屏幕，将保持竖屏播放', false);
      }
    });
  }

  /**
   * 在全屏的三种方向选择之间切换：跟随系统 → 横屏 → 竖屏 → 跟随系统。
   *
   * 为什么要有"跟随系统"而不是只有强制横竖屏：用户把手机架在支架上看片时，
   * 横竖切换应当由机身姿态决定；而躺卧观看时又希望锁死横屏。两者都要给。
   */
  private cycleOrientation(): void {
    if (this.orientation === 'auto') {
      this.orientation = 'landscape';
    } else if (this.orientation === 'landscape') {
      this.orientation = 'portrait';
    } else {
      this.orientation = 'auto';
    }
    this.applyOrientation();
    this.gestureIcon = 'orientation';
    this.gestureFeedback = this.orientationLabel();
    this.gestureRatio = -1;
    this.showFeedback = true;
    this.dismissFeedback();
    this.revealControls();
  }

  /** 当前方向选择的用户可见文案 */
  private orientationLabel(): string {
    if (this.orientation === 'landscape') {
      return '横屏';
    }
    if (this.orientation === 'portrait') {
      return '竖屏';
    }
    return '跟随系统';
  }

  /**
   * 方向按钮的图标。
   *
   * 为什么按状态给不同图标：用户需要一眼看出"当前是锁定横屏还是跟随系统"。
   * 全部用同一个旋转图标时，按钮文案与图标都表示"旋转"，反而看不出当前处在哪种模式。
   *
   * 符号名取自本机 SDK 的系统符号清单（`ets-loader/sysResource.js` 的 `symbol` 段，
   * 行号 3246–7275）：`screen_rotation` / `rectangle_ratio_9_to_16` / `rectangle_ratio_16_to_9`。
   * 注意该文件里 `rotate` 位于 `media` 段（非符号），写成 `sys.symbol.rotate` 会构建失败
   * （实测报 `Unknown resource name 'rotate'`）。
   */
  private orientationIcon(): Resource {
    if (this.orientation === 'landscape') {
      return $r('sys.symbol.rectangle_ratio_16_to_9');
    }
    if (this.orientation === 'portrait') {
      return $r('sys.symbol.rectangle_ratio_9_to_16');
    }
    return $r('sys.symbol.screen_rotation');
  }

  /**
   * 订阅窗口尺寸变化。
   *
   * 为什么必须订阅：旋转屏幕会改变窗口尺寸，而视频面尺寸（`videoAreaWidth/Height`）
   * 与控件避让区都是从尺寸推导出来的。不订阅的话，横过来之后视频面仍是竖屏算出的几何，
   * 画面会缩在屏幕一角 —— 那等于"全屏"没做成。
   */
  private subscribeWindowSizeChange(): void {
    if (this.windowRef === null || this.windowSizeSubscribed) {
      return;
    }
    try {
      this.windowRef.on('windowSizeChange', () => {
        this.refreshInsets();
      });
      this.windowSizeSubscribed = true;
    } catch (_e) {
      // 订阅失败不影响播放：onAreaChange 仍会在布局变化时更新播放区实测尺寸
    }
  }

  private unsubscribeWindowSizeChange(): void {
    if (this.windowRef === null || !this.windowSizeSubscribed) {
      return;
    }
    try {
      this.windowRef.off('windowSizeChange');
    } catch (_e) {
      // 取消订阅是尽力而为
    }
    this.windowSizeSubscribed = false;
  }

  /**
   * 重新计算控件避让区。
   *
   * `includeSystemBars` 的取值是这里的关键：只有"系统栏确实还显示着"时才需要避让它。
   * 我们隐藏失败时必须避让（否则控件被状态栏压住），隐藏成功时不能避让
   * （否则屏幕上平白多一条空白带）。
   */
  private refreshInsets(): void {
    const includeSystemBars: boolean = !this.immersive || !this.layoutFullscreenOk;
    this.insets = WindowFullscreen.insets(this.windowRef, includeSystemBars);
    this.landscape = this.areaWidth() > this.areaHeight();
  }

  /**
   * 取当前窗口实例（亮度、常亮与全屏都要用它）。
   * 失败不抛异常：亮度手势会退化成画面调暗，"常亮"与全屏则只是不生效。
   */
  private async ensureWindow(): Promise<void> {
    if (this.windowRef !== null) {
      return;
    }
    try {
      const ctx: common.UIAbilityContext = getContext(this) as common.UIAbilityContext;
      this.windowRef = await window.getLastWindow(ctx);
    } catch (_e) {
      this.windowRef = null;
    }
  }

  /**
   * 设置窗口亮度（0–1）。
   *
   * 为什么用窗口亮度而不是"盖一层黑"：这是系统级真实亮度调节，调节效果与主流播放器一致
   * （退出播放页会恢复系统亮度）。若某个平台不支持，则 `windowBrightnessOk` 保持 false，
   * 画面调暗由 `brightnessSimOpacity()` 的遮罩兜底 —— 用户的手势不会"看起来没反应"。
   */
  private applyBrightness(value: number): void {
    const v: number = Math.max(0.01, Math.min(1, value));
    this.windowBrightness = v;
    if (this.windowRef === null) {
      this.ensureWindow().then(() => {
        this.applyBrightness(v);
      });
      return;
    }
    this.windowRef.setWindowBrightness(v).then(() => {
      // 首次成功即认为本平台支持窗口亮度（后续不再叠加模拟遮罩）
      this.windowBrightnessOk = true;
    }).catch((_err: Error) => {
      this.windowBrightnessOk = false;
    });
  }

  /** 不支持窗口亮度时的兜底遮罩透明度：亮度越低，黑遮罩越重（最高 0.7） */
  private brightnessSimOpacity(): number {
    if (this.windowBrightnessOk || this.windowBrightness >= 0.999) {
      return 0;
    }
    return Math.max(0, Math.min(0.7, (1 - this.windowBrightness) * 0.85));
  }

  /** 播放期间保持屏幕常亮（主流播放器的标配行为）；离开播放页恢复系统默认 */
  private applyKeepScreenOn(on: boolean): void {
    if (on === this.keepScreenOnApplied) {
      return;
    }
    if (this.windowRef === null) {
      this.ensureWindow().then(() => {
        this.applyKeepScreenOn(on);
      });
      return;
    }
    this.windowRef.setWindowKeepScreenOn(on).then(() => {
      this.keepScreenOnApplied = on;
    }).catch((_err: Error) => {
      // 常亮失败不影响播放，只是不生效
    });
  }

  // ─────────────────────── 点击 / 双击 / 快进 ───────────────────────

  /**
   * 一次"抬手"到达：判定单击（显隐控制条）还是双击（两侧快进/快退）。
   *
   * 主流播放器（Infuse/iina/B站）都是这套手势：单击唤出控件、双击左右两侧 ±10s。
   * 单击必须**延后**执行，否则双击时控制条会闪一下；双击会取消待执行的单击。
   */
  private handleTapUp(x: number): void {
    const now: number = Date.now();
    const isDoubleTap: boolean = (now - this.lastTapUpAt) < kDoubleTapMs
      && Math.abs(x - this.lastTapX) < this.gestureWidth() / 3;
    if (isDoubleTap) {
      if (this.singleTapTimerId >= 0) {
        clearTimeout(this.singleTapTimerId);
        this.singleTapTimerId = -1;
      }
      const forward: boolean = x >= this.gestureWidth() / 2;
      // 探针：把"被判成双击"这件事写下来 —— 单击/双击是同一块区域上的两个手势，
      // 只看位置变化无法区分"没识别成双击"与"识别了但跳转失败"。

      this.showSeekRipple(forward);
      this.skipBy(forward ? kSkipStepMs : -kSkipStepMs);
      // 双击后不再把第二次抬手当成新一轮单击的起点
      this.lastTapUpAt = 0;
      return;
    }
    this.lastTapUpAt = now;
    this.lastTapX = x;
    if (this.singleTapTimerId >= 0) {
      clearTimeout(this.singleTapTimerId);
    }
    this.singleTapTimerId = setTimeout(() => {
      this.singleTapTimerId = -1;
      this.onSingleTap();
    }, kSingleTapDelayMs);
  }

  /**
   * 单击：锁定态下**显示锁**（解锁只能点锁本身）；否则显隐控制条。
   *
   * 需求原话："屏幕锁定只能通过点击锁的位置来恢复，锁模式单击可以显示锁，
   * 再次点击锁可以取消锁定模式" —— 所以单击只把锁亮出来，不再顺手解锁
   * （此前点画面任意位置都会解锁，"想看一眼进度就把锁解掉了"）。
   */
  /**
   * 锁定态的单击：只做"显示/收起锁提示"，**不做**双击快进、不做拖动 seek。
   *
   * 复用与正常路径相同的单击延时（`kSingleTapDelayMs`），保证两条通道（ArkUI 手势层 /
   * 原生兜底轮询）的判定口径一致。
   */
  private handleLockedTap(x: number): void {
    this.lastTapUpAt = Date.now();
    this.lastTapX = x;
    if (this.singleTapTimerId >= 0) {
      clearTimeout(this.singleTapTimerId);
    }
    this.singleTapTimerId = setTimeout(() => {
      this.singleTapTimerId = -1;
      this.onSingleTap();
    }, kSingleTapDelayMs);
  }

  private onSingleTap(): void {
    // 刚切换过锁定状态的那一次单击不算"用户意图"，**两个方向都要挡**：
    // · 点"锁定"：同一次抬手的单击若被采纳，锁提示会当场弹出来；
    // · 点"解锁"（锁图标）：解锁已经唤出了控制面板，而这次抬手产生的单击
    //   又会把它再收起（实测：解锁后控制面板没留住）。
    if (Date.now() - this.lockChangedAt < kLockGraceMs) {
      return;
    }
    if (this.controlsLocked) {
      if (this.lockBadgeVisible) {
        this.hideLockBadge();
      } else {
        this.showLockBadge();
      }
      return;
    }
    if (this.showControls) {
      this.showControls = false;
    } else {
      this.revealControls();
    }
  }

  /**
   * 双击两侧的反馈浮层：半透明圆 + `±10 秒` 提示，620ms 内渐隐。
   *
   * 为什么要有动画：双击快进如果只有时间在跳，用户会怀疑"是不是点到了"；
   * 主流播放器都会给出一个短促的圆形反馈（Infuse 的左右圆形涟漪）。
   */
  private showSeekRipple(forward: boolean): void {
    this.rippleSide = forward ? 'forward' : 'backward';
    this.rippleOpacity = 1;
    this.rippleScale = 0.7;
    animateTo({ duration: kRippleMs, curve: Curve.EaseOut }, () => {
      this.rippleOpacity = 0;
      this.rippleScale = 1.15;
    });
    if (this.rippleTimerId >= 0) {
      clearTimeout(this.rippleTimerId);
    }
    this.rippleTimerId = setTimeout(() => {
      this.rippleSide = '';
      this.rippleTimerId = -1;
    }, kRippleMs);
  }

  /**
   * 相对跳转（±步长），硬解与软解两条路径都支持。
   *
   * 修复：此前所有 seek 都只操作 `avPlayer`，于是**软解播放时按 ±10s 没有任何反应**。
   */
  private skipBy(deltaMs: number): void {
    // 时长未知时（尚未 prepared）只保证不小于 0，不做上限裁剪
    let target: number = Math.max(0, this.positionMs + deltaMs);
    if (this.durationMs > 0) {
      target = Math.min(target, this.durationMs);
    }
    this.seekTo(target);
    this.gestureIcon = 'seek';
    this.lastSeekForward = deltaMs >= 0;
    this.gestureFeedback = `${deltaMs >= 0 ? '+' : '-'}${Math.round(Math.abs(deltaMs) / 1000)} 秒`;
    this.gestureRatio = this.durationMs > 0 ? target / this.durationMs : -1;
    this.showFeedback = true;
    this.dismissFeedback();
    this.revealControls();
  }

  private dismissFeedback(): void {
    if (this.feedbackTimerId >= 0) {
      clearTimeout(this.feedbackTimerId);
    }
    this.feedbackTimerId = setTimeout(() => {
      this.showFeedback = false;
      this.gestureFeedback = '';
      this.gestureIcon = '';
      this.gestureRatio = -1;
    }, 700);
    this.scheduleHideControls();
  }

  private formatTime(ms: number): string {
    return formatSeconds(Math.max(0, Math.floor(ms / 1000)));
  }

  /**
   * 启动 FFmpeg 软解回放：打开流式软解会话，然后由定时器逐帧拉取并用 PixelMap 渲染。
   *
   * 为什么需要：系统 AVPlayer 只走硬解，模拟器/部分设备解不了 HEVC 等编码；
   * 软解用 FFmpeg 在 CPU 上解码，虽然帧率有限，但能把这些内容放出来。
   */
  private async startSoftPlay(): Promise<void> {
    this.softRenderFailed = false;
    this.softRenderErrorStreak = 0;
    this.setSoftNotice('正在打开软解会话…', false);
    // 硬解失败后应停掉 AVPlayer，避免两路同时读流（同时把 surface 让给 EGL）
    this.softStopAvPlayer();
    const pxSize: number[] = this.surfacePixelSize();
    // ── 打开阶段的超时兜底 ────────────────────────────────────────────────
    // 打开会话里的 avformat/取流同样可能**永不返回**（设备实测 4K 8-bit HEVC
    // 「流浪地球2」卡在 openUrl 90 秒以上，界面一直停在"正在打开软解会话…"）。
    // 与拉帧看门狗同理：项目约定"异常与超时都必须到达终态"，
    // 所以这里也必须给出明确结果，而不是无限等待。
    // 注：原生侧那次调用无法真正取消（工作线程仍在跑），但**界面必须到达终态**，
    // 用户可以重试或换条目；重试会重建会话。
    this.softOpenTimedOut = false;
    const openTimerId: number = setTimeout(() => {
      if (!this.softPlaying) {
        this.softOpenTimedOut = true;
        this.setSoftNotice(`打开软解会话超时（${Math.round(kSoftOpenTimeoutMs / 1000)} 秒无响应），`
          + '已放弃；可点「软解」重试或改看其它条目', false);
      }
    }, kSoftOpenTimeoutMs);
    let raw: string = '';
    try {
      raw = await JellyfinNative.softPlayOpen(this.itemId, this.surfaceId, pxSize[0],
                                              pxSize[1], 'xcomponent', this.playbackOptions);
    } finally {
      clearTimeout(openTimerId);
    }
    if (this.softOpenTimedOut) {
      // 已按超时给出终态，不再继续后续流程（避免"超时提示"被随后的成功覆盖成正常播放）
      return;
    }
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.setSoftNotice(`软解打开失败：${result.message}`, false);
      return;
    }
    const data: ESObject = result.data as ESObject;
    if (!JsonUtil.getBoolean(data, 'ok', false)) {
      this.setSoftNotice(`软解打开失败：${JsonUtil.getString(data, 'error', '未知错误')}`, false);
      return;
    }
    this.softPlaying = true;
    this.softPaused = false;
    this.softLastFrameIndex = 0;
    this.softPullStartedAt = 0;
    this.softRenderErrorStreak = 0;

    // ── 在 UI 线程初始化 EGL 渲染器（"软解黑屏"的修复点）──────────────────
    // 为什么必须在这里、且必须是同步调用：
    // EGL/DGLES 把"当前上下文 / 当前 surface"记在**线程私有**状态里，初始化与逐帧渲染
    // 必须同线程。`softPlayOpen` 跑在原生的工作线程上（为了不阻塞 UI 做网络/解析），
    // 若让它在那边初始化 EGL，则 UI 线程帧循环里的每一次 `eglSwapBuffers` 都会失败：
    // 设备实测（模拟器，HEVC 源自动回退软解）驱动日志每 70ms 一条
    // `DGLES: EGL_BAD_SURFACE, g_handle is null`（0x300d），帧号正常增长、
    // **屏幕全黑、且没有任何上层错误提示** —— 就是用户看到的"软解黑屏"。
    // 现在初始化改到这里（UI 线程 = `softPlayRenderLast()` 所在线程），两者同线程。
    const renderInitRaw: string =
      JellyfinNative.softPlayInitRenderer(this.surfaceId, pxSize[0], pxSize[1], 'xcomponent');
    const renderInitResult: NativeResult = JellyfinNative.parseResult(renderInitRaw);
    let renderReady: boolean = false;
    let renderError: string = '';
    let renderW: number = 0;
    if (renderInitResult.ok && renderInitResult.data !== null) {
      const initData: ESObject = renderInitResult.data as ESObject;
      renderReady = JsonUtil.getBoolean(initData, 'renderReady', false);
      renderError = JsonUtil.getString(initData, 'renderError', '');
      renderW = JsonUtil.getNumber(initData, 'renderWidth', 0);
      // 渲染缓冲几何随协商结果变化（本设备能吃多大由 GL 决定）
      this.softDecodeMaxWidth = renderW > 0 ? renderW : 0;
    } else {
      renderError = renderInitResult.message.length > 0
        ? renderInitResult.message : '初始化 EGL 渲染器失败';
    }
    if (!renderReady) {
      // ── 渲染面不可用时必须给终态，不能"看着在播、屏幕全黑"──────────────
      // 软解会话只解码视频（无音频输出），渲染起不来 = 用户什么都得不到：
      // 与其让它继续偷偷解码、把画面丢进虚空，不如如实报错并释放会话。
      const reason: string = renderError.length > 0 ? renderError : 'EGL 渲染器未就绪';
      this.softRenderFailed = true;
      this.softPlaying = false;
      JellyfinNative.softPlayClose();
      // 提示 + 错误态：用户既能看到原因，也有「重试」入口（终态，不会静静黑着）
      this.setSoftNotice(`软解画面无法上屏：${reason}`, true);
      this.status = UiState.ERROR;
      this.errorMsg = `软解画面无法上屏：${reason}`;
      return;
    }
    // 画面尺寸/时长取自软解会话（"视频比例"与进度条在软解路径上同样要正确工作）
    const softW: number = JsonUtil.getNumber(data, 'width', 0);
    const softH: number = JsonUtil.getNumber(data, 'height', 0);
    const softDurationSec: number = JsonUtil.getNumber(data, 'durationSec', 0);
    if (softW > 0 && softH > 0) {
      this.videoWidthPx = softW;
      this.videoHeightPx = softH;
    }
    if (softDurationSec > 0) {
      this.durationMs = Math.round(softDurationSec * 1000);
    }
    // ── 解码尺寸对齐渲染缓冲（分辨率的关键）─────────────────────────────
    // 渲染缓冲能吃下多大由设备 GL 决定，原生侧已协商好并把结果回来（renderWidth/Height）。
    // 我们按它解码，做到两件事同时成立：
    //   1. 不欠采样 —— 4K/1080p 源在真机上按渲染缓冲的真实尺寸解码，画面不再被压到 640 宽；
    //   2. 不浪费 —— 解码超过缓冲尺寸的部分最终仍会被缩掉，那部分 CPU/swscale 开销是白花的。
    // renderWidth 为 0（未就绪）时传 0 = 原生分辨率，不做任何缩放。
    //
    // 注：renderWidth 已在上面由 `softPlayInitRenderer` 取回（渲染器初始化的真实结果），
    // 不再依赖 `softPlayOpen` 的返回值 —— 后者跑在工作线程上，本来就拿不到渲染器几何。
    if (this.softDecodeMaxWidth <= 0) {
      const fallbackW: number = JsonUtil.getNumber(data, 'renderWidth', 0);
      this.softDecodeMaxWidth = fallbackW > 0 ? fallbackW : 0;
    }
    // 画面比例：软解由 EglRenderer 按模式换算顶点缩放（硬解走 videoScaleType）
    this.applyAspectToSoftRenderer();
    // 定位目标：优先"硬解失败时所在的位置"（无感切换），否则用传入的续播位置。
    const seekTargetMs: number = this.softFallbackStartMs > 1000
      ? this.softFallbackStartMs : this.startPositionMs;
    if (seekTargetMs > 1000) {
      const seekSec: number = seekTargetMs / 1000;
      const seekRaw: string = JellyfinNative.softPlaySeek(seekSec);
      const seekResult: NativeResult = JellyfinNative.parseResult(seekRaw);
      if (seekResult.ok && seekResult.data !== null) {
        const seekQueued: boolean = JsonUtil.getBoolean(seekResult.data as ESObject, 'ok', false);
        if (seekQueued) {
          this.softPositionMs = seekTargetMs;
          this.softSeekTargetMs = seekTargetMs;
          this.softSeekHoldUntil = Date.now() + 4000;
        } else {
          this.setSoftNotice(`续播跳转失败：${JsonUtil.getString(seekResult.data as ESObject, 'error', '')}`,
            false);
        }
      }
    }
    this.startSoftTimer();
    // 软解播放期间同样保持屏幕常亮（与硬解路径一致）
    this.applyKeepScreenOn(true);
  }

  /** XComponent 的像素尺寸：优先用组件实测尺寸，未拿到时退化为整屏像素 */
  private surfacePixelSize(): number[] {
    if (this.surfaceWidthPx > 0 && this.surfaceHeightPx > 0) {
      return [this.surfaceWidthPx, this.surfaceHeightPx];
    }
    try {
      const d: display.Display = display.getDefaultDisplaySync();
      return [d.width, d.height];
    } catch (err) {
      return [0, 0];
    }
  }

  /**
   * 设置软解提示（用户可见），并让普通提示自行隐去。
   *
   * @param text    提示文案
   * @param sticky  true 表示需要用户长时间知情（如"已自动切换软解"）；false 表示瞬时提示
   *                （打开中/跳转失败等），若干秒后自动隐去，避免长期压在画面上。
   */
  private setSoftNotice(text: string, sticky: boolean): void {
    if (this.softNoticeTimerId >= 0) {
      clearTimeout(this.softNoticeTimerId);
      this.softNoticeTimerId = -1;
    }
    this.softStatus = text;
    if (!sticky) {
      this.softNoticeTimerId = setTimeout(() => {
        this.softNoticeTimerId = -1;
        this.softStatus = '';
      }, kSoftNoticeMs);
    }
  }

  private clearSoftNotice(): void {
    if (this.softNoticeTimerId >= 0) {
      clearTimeout(this.softNoticeTimerId);
      this.softNoticeTimerId = -1;
    }
    this.softStatus = '';
  }

  /** 逐帧拉取（约 70ms 一帧 ≈ 14fps；软解 + 纹理上传的开销决定上限） */
  private startSoftTimer(): void {
    this.stopSoftTimer();
    this.softTimerId = setInterval(() => {
      this.pullSoftFrame();
    }, 70);
  }

  private stopSoftTimer(): void {
    if (this.softTimerId !== -1) {
      clearInterval(this.softTimerId);
      this.softTimerId = -1;
    }
  }

  private async pullSoftFrame(): Promise<void> {
    if (!this.softPlaying) {
      return;
    }
    if (this.softPulling) {
      // ── 卡死看门狗 ─────────────────────────────────────────────────────────
      // 设备实测（4K 8-bit HEVC「流浪地球2」）：原生侧某次拉帧**永不返回**
      // （解码器卡在某一帧 / 取流挂起），此前 `softPulling` 会一直是 true，
      // 于是定时器每次都直接 return —— 界面永远停在最后一帧，既不报错也没有重试入口。
      // 项目约定是"异常与超时都必然到达终态"，这个永久挂起正好违反了它。
      // 这里补上终态：超时即判卡死 → 明确报错 + 停掉软解（用户可点「软解」重试）。
      if (this.softPullStartedAt > 0
        && Date.now() - this.softPullStartedAt > kSoftPullStallMs) {
        const stalledMs: number = Date.now() - this.softPullStartedAt;
        this.setSoftNotice(`软解无响应已 ${Math.round(stalledMs / 1000)} 秒（解到第 `
          + `${this.softLastFrameIndex} 帧），已停止；可点「软解」重试或改看其它条目`, true);
        this.softPulling = false;
        this.softPullStartedAt = 0;
        this.stopSoftPlay();
      }
      return;
    }
    this.softPulling = true;
    this.softPullStartedAt = Date.now();
    try {
      // 渲染由原生侧 EGL 完成，这里只取元数据（帧号/时间戳/取流字节/是否已渲染）。
      // 解码宽度取"渲染缓冲的实际宽度"（原生侧协商，见 startSoftPlay）：
      // 0 表示按源分辨率解码。这样 4K/1080p 源在真机上就是原样的清晰度，
      // 而不是此前写死的 640 宽（等于把所有内容都降到 640 再放大上屏）。
      //
      // 这一步**必须 await**：原生侧走工作线程执行（未命中缓存时是同步 HTTP），
      // 若在 UI 线程同步等待，会因一次网络往返阻塞主线程数秒 → 系统判 appfreeze。
      const raw: string = await JellyfinNative.softPlayNextFrame(this.softDecodeMaxWidth);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        return;
      }
      const frame: ESObject = result.data as ESObject;
      const ok: boolean = JsonUtil.getBoolean(frame, 'ok', false);
      if (!ok) {
        const reason: string = JsonUtil.getString(frame, 'error', '');
        if (reason === 'eof') {
          this.stopSoftPlay();
        } else if (reason.length > 0) {
          this.setSoftNotice(`软解失败：${reason}`, true);
          this.stopSoftPlay();
        }
        return;
      }
      const pts: number = JsonUtil.getNumber(frame, 'ptsSec', 0);
      const idx: number = JsonUtil.getNumber(frame, 'frameIndex', 0);
      // 渲染在 UI 线程做（原生侧只解码）：EGL 窗口 surface 不能在线程池线程上 swap
      const renderRaw: string = JellyfinNative.softPlayRenderLast();
      const renderResult: NativeResult = JellyfinNative.parseResult(renderRaw);
      const renderError: string = renderResult.ok && renderResult.data !== null
        ? JsonUtil.getString(renderResult.data as ESObject, 'renderError', '') : '';
      if (renderError.length > 0) {
        // ── 上屏失败必须到达终态 ────────────────────────────────────────────
        // 此前这里只在"没有别的提示"时才写一条提示，于是自动回退软解后那句
        // "已自动切换软解播放"会把上屏错误**永久盖住** —— 用户只看到一块黑屏，
        // 既不知道原因也没有重试入口。现在：先如实显示，连续失败即停止软解。
        this.softRenderErrorStreak++;
        if (this.softRenderErrorStreak === 1) {
          this.setSoftNotice(`软解画面无法上屏：${renderError}`, true);
        }
        if (this.softRenderErrorStreak >= kSoftRenderErrorLimit) {
          this.softRenderFailed = true;
          const failText: string =
            `软解画面无法上屏（连续 ${this.softRenderErrorStreak} 帧）：${renderError}`;
          this.setSoftNotice(failText, true);
          this.softPulling = false;
          this.softPullStartedAt = 0;
          this.stopSoftPlay();
          // 与打开阶段的上屏失败一致：给错误态（含「重试」入口），不留"黑着但看着像在播"
          this.status = UiState.ERROR;
          this.errorMsg = failText;
          return;
        }
      } else {
        this.softRenderErrorStreak = 0;
      }
      // ── 排队的 seek 结果 ────────────────────────────────────────────────
      // seek 在原生侧排队、由本帧的拉取顺带执行（避免 UI 线程做同步 HTTP），
      // 结果挂在这一帧上：跳转失败时必须让用户看到原因。
      const seekError: string = JsonUtil.getString(frame, 'seekError', '');
      if (seekError.length > 0) {
        this.setSoftNotice(`跳转失败：${seekError}`, false);
      }
      // 跳转保持窗口：seek 刚发出后的若干帧仍来自旧位置，若照单回写，进度条会先弹回原处
      // 再跳到目标（观感像"没跳成功"）。保持期内只显示目标位置，直到画面追上目标。
      const ptsMs: number = Math.floor(pts * 1000);
      const holding: boolean = this.softSeekTargetMs >= 0
        && Date.now() < this.softSeekHoldUntil
        && Math.abs(ptsMs - this.softSeekTargetMs) > 2000;
      if (!holding) {
        this.softPositionMs = ptsMs;
        this.softSeekTargetMs = -1;
      }
      this.softLastFrameIndex = idx;
      this.reportSoftProgressThrottled(pts);
    } catch (err) {
      this.setSoftNotice(`软解异常：${(err as Error).message}`, true);
    } finally {
      this.softPulling = false;
      this.softPullStartedAt = 0;
    }
  }

  /**
   * 创建 AVSession（官方"媒体会话"能力）：让播放进入系统媒体控制/后台播放体系。
   *
   * 官方文档路径：`avSession.createAVSession(context, tag, 'video')` → `setAVMetadata` → `activate`，
   * 并订阅 play/pause/stop/seek 回调，使系统媒体控件（通知栏/锁屏/耳机按键）能驱动本播放器。
   */
  private async initAvSession(): Promise<void> {
    try {
      if (this.avSessionRef !== null) {
        return;
      }
      const ctx = getContext(this) as common.UIAbilityContext;
      const session: avSession.AVSession = await avSession.createAVSession(ctx, 'jellyfin_player', 'video');
      await session.setAVMetadata({ assetId: this.itemId, title: this.title,
        artist: this.typeLabel.length > 0 ? this.typeLabel : 'Jellyfin' });
      session.on('play', () => {
        this.onPlayPause();
      });
      session.on('pause', () => {
        this.onPlayPause();
      });
      session.on('stop', () => {
        this.flushStop();
      });
      session.on('seek', (timeMs: number) => {
        // AVSession 的 seek 回调给的是**绝对时间**（毫秒），不是偏移量。
        // 之前写成 onSeek(timeMs - this.positionMs) 是错的：会把绝对位置当作增量再叠加一次。
        this.positionMs = timeMs;
        if (this.avPlayer !== null) {
          this.avPlayer.seek(timeMs);
        }

      });
      await session.activate();
      // 把播放状态同步进系统会话（通知栏/锁屏媒体控件据此显示播放/暂停与进度）
      await session.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        position: { elapsedTime: 0, updateTime: Date.now() }
      });
      this.avSessionRef = session;

    } catch (err) {

    }
  }

  // ---------------------------------------------------------------------------
  // 播放中切换音频 / 字幕
  //
  // 两条路径，"不打断播放"的优先：
  //
  // A. **播放器轨道切换（首选）**：AVPlayer 的 `getTrackDescription()` + `selectTrack()`。
  //    直连/直传时播放器拿到的是**原始文件**，音轨切换是解复用层面的操作：
  //    画面不中断、进度不跳、也不需要重新向服务端请求播放地址 —— 主流播放器都是这么做的。
  // B. **重新请求播放地址（兜底）**：转码等由服务端决定轨道的场景，
  //    只能把新的 `AudioStreamIndex`/`SubtitleStreamIndex` 带回 PlaybackInfo 重新取流，再 seek 回原位。
  //
  // 字幕额外说明：外挂字幕由播放器解析后通过 `subtitleUpdate` 回调交给应用渲染
  // （`SubtitleInfo { startTime, duration, text }`），所以页面自己画字幕文本。
  // ---------------------------------------------------------------------------

  /** Jellyfin MediaStreams 中指定类型的流；Type 取 "Audio" / "Subtitle" */
  private streamsOfType(type: string): Object[] {
    const out: Object[] = [];
    for (let i = 0; i < this.mediaStreams.length; i++) {
      const s: ESObject = this.mediaStreams[i] as ESObject;
      if (JsonUtil.getString(s, 'Type', '') === type) {
        out.push(this.mediaStreams[i]);
      }
    }
    return out;
  }

  /** 展开轨道面板：顺带刷新一次播放器轨道（重新打开播放后轨道会变） */
  private openTrackSheet(): void {
    this.trackNote = '';
    this.showTrackSheet = true;
    this.revealControls();
    if (this.avPlayer !== null && !this.softPlaying) {
      this.refreshAvTracks();
    }

  }

  private closeTrackSheet(): void {
    this.showTrackSheet = false;
    this.revealControls();
  }

  /**
   * 读取播放器的轨道列表（prepared 之后才可用），并写入探针。
   *
   * 探针 `player_tracks.txt` 是这条链路的设备验证依据：轨道总数、每轨的类型/语言/编码，
   * 以及当前被选中的轨道 index —— 这些都是"能不能切、切成功了没"的直接证据，
   * 比看画面可靠（模拟器上无法用读屏观察播放页）。
   */
  private async refreshAvTracks(): Promise<void> {
    if (this.avPlayer === null) {
      return;
    }
    try {
      const tracks: media.MediaDescription[] = await this.avPlayer.getTrackDescription();
      const audios: Object[] = [];
      const subs: Object[] = [];
      let line: string = `avTracks n=${tracks.length}`;
      for (let i = 0; i < tracks.length; i++) {
        const t: ESObject = tracks[i] as ESObject;
        const type: number = JsonUtil.getNumber(t, 'track_type', -1);
        const idx: number = JsonUtil.getNumber(t, 'track_index', -1);
        const lang: string = JsonUtil.getString(t, 'language', '');
        const name: string = JsonUtil.getString(t, 'track_name', '');
        const mime: string = JsonUtil.getString(t, 'mime_type', '');
        const ch: number = JsonUtil.getNumber(t, 'channel_count', 0);
        line += ` | idx=${idx} type=${type} lang=${lang} name=${name} mime=${mime} ch=${ch}`;
        if (type === kMediaTypeAudio) {
          const row: ESObject = {
            'idx': idx, 'lang': lang, 'name': name, 'mime': mime, 'ch': ch
          };
          audios.push(row as Object);
        } else if (type === kMediaTypeSubtitle) {
          // 内嵌字幕轨：直接 selectTrack 就能切，不需要再去服务端取字幕文件
          const row: ESObject = { 'idx': idx, 'lang': lang, 'name': name, 'mime': mime };
          subs.push(row as Object);
        }
      }
      this.avAudioTracks = audios;
      this.avSubtitleTracks = subs;
      let selected: number = -1;
      let selectedSub: number = -1;
      try {
        const sel: number[] = await this.avPlayer.getSelectedTracks();
        let selText: string = '';
        for (let i = 0; i < sel.length; i++) {
          selText += (i === 0 ? '' : ',') + sel[i];
          for (let j = 0; j < audios.length; j++) {
            if (JsonUtil.getNumber(audios[j] as ESObject, 'idx', -2) === sel[i]) {
              selected = sel[i];
            }
          }
          for (let j = 0; j < subs.length; j++) {
            if (JsonUtil.getNumber(subs[j] as ESObject, 'idx', -2) === sel[i]) {
              selectedSub = sel[i];
            }
          }
        }
        line += ` selected=[${selText}]`;
      } catch (selErr) {
        line += ` selected=err(${(selErr as Error).message})`;
      }
      this.avAudioIndex = selected;
      this.avSubtitleIndex = selectedSub;
      // 让面板/参数与播放器的真实选择一致：播放器默认选的轨道往往就是文件里的默认轨，
      // 只有把它映射回 Jellyfin 的流索引，面板的选中标记才不会"什么都没选"。
      const audioOrdinal: number = this.avOrdinalOf(selected);
      const jfAudios: Object[] = this.streamsOfType('Audio');
      if (audioOrdinal >= 0 && audioOrdinal < jfAudios.length && this.audioStreamIndex < 0) {
        this.audioStreamIndex = JsonUtil.getNumber(jfAudios[audioOrdinal] as ESObject, 'Index', -1);
      }
      const subOrdinal: number = this.avSubtitleOrdinalOf(selectedSub);
      const jfSubs: Object[] = this.streamsOfType('Subtitle');
      if (subOrdinal >= 0 && subOrdinal < jfSubs.length && this.subtitleStreamIndex < 0) {
        this.subtitleStreamIndex =
          JsonUtil.getNumber(jfSubs[subOrdinal] as ESObject, 'Index', -1);
      }

    } catch (err) {

    }
  }

  /** 播放器里已加载的字幕轨 index 列表 */
  private async subtitleTrackIndexes(): Promise<number[]> {
    const out: number[] = [];
    if (this.avPlayer === null) {
      return out;
    }
    try {
      const tracks: media.MediaDescription[] = await this.avPlayer.getTrackDescription();
      for (let i = 0; i < tracks.length; i++) {
        const t: ESObject = tracks[i] as ESObject;
        if (JsonUtil.getNumber(t, 'track_type', -1) === kMediaTypeSubtitle) {
          out.push(JsonUtil.getNumber(t, 'track_index', -1));
        }
      }
    } catch (err) {

    }
    return out;
  }

  /** 切换音轨：直接让播放器切（不打断播放） */
  private async selectAudioTrack(avIndex: number): Promise<void> {
    if (this.avPlayer === null) {
      this.trackNote = '播放器未就绪，无法切换音轨';
      return;
    }
    try {
      await this.avPlayer.selectTrack(avIndex);
      let confirm: string = '';
      try {
        const sel: number[] = await this.avPlayer.getSelectedTracks();
        for (let i = 0; i < sel.length; i++) {
          confirm += (i === 0 ? '' : ',') + sel[i];
        }
      } catch (selErr) {
        confirm = `err(${(selErr as Error).message})`;
      }
      this.avAudioIndex = avIndex;
      // 同步到播放参数：兜底重开（转码/软解）时保持同一选择
      const ordinal: number = this.avOrdinalOf(avIndex);
      const jfAudios: Object[] = this.streamsOfType('Audio');
      if (ordinal >= 0 && ordinal < jfAudios.length) {
        this.audioStreamIndex = JsonUtil.getNumber(jfAudios[ordinal] as ESObject, 'Index', -1);
      }
      this.persistTrackOptions();
      this.trackNote = '已切换音频';

    } catch (err) {
      this.trackNote = `切换音频失败：${(err as Error).message}`;

    }
  }

  /** 播放器音轨 index → 它在音轨列表中的序号（用于映射回 Jellyfin 的音轨顺序） */
  private avOrdinalOf(avIndex: number): number {
    for (let i = 0; i < this.avAudioTracks.length; i++) {
      if (JsonUtil.getNumber(this.avAudioTracks[i] as ESObject, 'idx', -2) === avIndex) {
        return i;
      }
    }
    return -1;
  }

  /** 播放器字幕轨 index → 它在字幕轨列表中的序号（与 Jellyfin 字幕流顺序一一对应） */
  private avSubtitleOrdinalOf(avIndex: number): number {
    for (let i = 0; i < this.avSubtitleTracks.length; i++) {
      if (JsonUtil.getNumber(this.avSubtitleTracks[i] as ESObject, 'idx', -2) === avIndex) {
        return i;
      }
    }
    return -1;
  }

  /** Jellyfin 字幕流索引 → 它在字幕流列表中的序号 */
  private jfSubtitleOrdinalOf(streamIndex: number): number {
    const subs: Object[] = this.streamsOfType('Subtitle');
    for (let i = 0; i < subs.length; i++) {
      if (JsonUtil.getNumber(subs[i] as ESObject, 'Index', -2) === streamIndex) {
        return i;
      }
    }
    return -1;
  }

  /** 把当前选择写回播放参数（供后续重开播放/软解使用） */
  private persistTrackOptions(): void {
    try {
      const opts: ESObject = JSON.parse(this.playbackOptions) as ESObject;
      opts['audioStreamIndex'] = this.audioStreamIndex;
      opts['subtitleStreamIndex'] = this.subtitleStreamIndex;
      this.playbackOptions = JSON.stringify(opts);
    } catch (err) {

    }
  }

  /**
   * 加载并显示某条 Jellyfin 字幕流。
   *
   * 两条路：
   * 1）**内嵌字幕（首选）**：文件里就有这条字幕轨（AVPlayer 的轨道列表里有 type=2 的轨），
   *    直接 `selectTrack`，不联网、不中断播放 —— 设备实测这样就够用。
   * 2）**外挂字幕（兜底）**：字幕是独立文件（Jellyfin 的 External 字幕），
   *    先用原生构造的字幕地址 `addSubtitleFromUrl` 加进来，再 selectTrack。
   */
  private async applySubtitleStream(streamIndex: number, codec: string): Promise<void> {
    if (this.avPlayer === null) {
      this.trackNote = '播放器未就绪，无法切换字幕';
      return;
    }
    // 1）内嵌字幕：按序号映射到播放器的字幕轨
    const ordinal: number = this.jfSubtitleOrdinalOf(streamIndex);
    if (this.avSubtitleTracks.length > 0 && ordinal >= 0
      && ordinal < this.avSubtitleTracks.length) {
      const avIdx: number = JsonUtil.getNumber(this.avSubtitleTracks[ordinal] as ESObject, 'idx', -1);

      await this.selectSubtitleTrack(avIdx, streamIndex);
      return;
    }
    // 2）外挂字幕
    const raw: string = JellyfinNative.subtitleUrl(this.itemId, this.mediaSourceId, streamIndex, codec);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.trackNote = result.message.length > 0 ? result.message : '无法构造字幕地址';
      return;
    }
    const url: string = JsonUtil.getString(result.data as ESObject, 'url', '');
    const format: string = JsonUtil.getString(result.data as ESObject, 'format', '');
    if (url.length === 0) {
      this.trackNote = '字幕地址为空';
      return;
    }
    try {
      const before: number[] = await this.subtitleTrackIndexes();

      await this.avPlayer.addSubtitleFromUrl(url);

      const after: number[] = await this.subtitleTrackIndexes();
      let target: number = -1;
      for (let i = 0; i < after.length; i++) {
        let known: boolean = false;
        for (let j = 0; j < before.length; j++) {
          if (before[j] === after[i]) {
            known = true;
          }
        }
        if (!known) {
          target = after[i];
        }
      }
      if (target < 0 && after.length > 0) {
        target = after[after.length - 1];
      }
      if (target < 0) {
        this.trackNote = '字幕已加载，但播放器未暴露该字幕轨';

        return;
      }
      await this.selectSubtitleTrack(target, streamIndex);
    } catch (err) {
      this.trackNote = `切换字幕失败：${(err as Error).message}`;

    }
  }

  /** 选中某条播放器字幕轨（先关掉上一条，避免多轨叠加） */
  private async selectSubtitleTrack(avIndex: number, streamIndex: number): Promise<void> {
    if (this.avPlayer === null) {
      return;
    }
    try {
      if (this.avSubtitleIndex >= 0 && this.avSubtitleIndex !== avIndex) {
        try {
          await this.avPlayer.deselectTrack(this.avSubtitleIndex);
        } catch (desErr) {

        }
      }
      await this.avPlayer.selectTrack(avIndex);
      this.avSubtitleIndex = avIndex;
      this.subtitleStreamIndex = streamIndex;
      this.persistTrackOptions();
      this.trackNote = '字幕已切换';

    } catch (err) {
      this.trackNote = `切换字幕失败：${(err as Error).message}`;

    }
  }

  /** 关闭字幕 */
  private async clearSubtitle(): Promise<void> {
    if (this.avPlayer !== null && this.avSubtitleIndex >= 0) {
      try {
        await this.avPlayer.deselectTrack(this.avSubtitleIndex);

      } catch (err) {

      }
    }
    this.avSubtitleIndex = -1;
    this.subtitleStreamIndex = -1;
    this.subtitleText = '';
    this.persistTrackOptions();
    this.trackNote = '字幕已关闭';
  }

  /**
   * 兜底路径：重新请求播放地址并 seek 回原位。
   *
   * 什么时候用：播放器没有暴露可切换的轨道（例如服务端转码，轨道由服务端决定）。
   * 代价是播放会重开一次（画面短暂黑一下、需要 seek 回原位），所以只作为次选。
   */
  private async reopenWithTrack(audioIndex: number, subtitleIndex: number): Promise<void> {
    const resumeMs: number = this.positionMs;
    this.audioStreamIndex = audioIndex;
    this.subtitleStreamIndex = subtitleIndex;
    this.persistTrackOptions();

    await this.openPlayer();
    // 回到切换前的位置（AVPlayer 在 prepared 后 seek 最稳妥，这里做一次兜底 seek）
    setTimeout(() => {
      if (this.avPlayer !== null && resumeMs > 1000) {
        this.avPlayer.seek(resumeMs);
        this.positionMs = resumeMs;
      }
    }, 1200);
  }

  /** 面板里点击某条音轨（播放器轨道，按 track index 切换） */
  private onPickAvAudio(avIndex: number): void {
    if (this.softPlaying) {
      this.trackNote = '软解模式暂不支持切换音轨（软解只解码视频）';
      return;
    }
    this.selectAudioTrack(avIndex);
  }

  /** 兜底：没有播放器轨道信息时，按 Jellyfin 音轨序号重新取流 */
  private onPickJfAudio(ordinal: number): void {
    if (this.softPlaying) {
      this.trackNote = '软解模式暂不支持切换音轨（软解只解码视频）';
      return;
    }
    const jfAudios: Object[] = this.streamsOfType('Audio');
    if (ordinal < 0 || ordinal >= jfAudios.length) {
      this.trackNote = '未找到对应的音轨';
      return;
    }
    this.reopenWithTrack(JsonUtil.getNumber(jfAudios[ordinal] as ESObject, 'Index', -1),
      this.subtitleStreamIndex);
  }

  /** 面板里点击某条字幕 */
  private onPickSubtitleStream(streamIndex: number, codec: string): void {
    if (this.softPlaying) {
      this.trackNote = '软解模式暂不支持外挂字幕（软解只渲染视频帧）';
      return;
    }
    if (this.avPlayer === null) {
      this.trackNote = '播放器未就绪，无法切换字幕';
      return;
    }
    this.applySubtitleStream(streamIndex, codec);
  }

  /** 流列表 → 选项文案：优先显示语言/标题，其次编码与声道 */
  private trackLabel(stream: ESObject): string {
    const type: string = JsonUtil.getString(stream, 'Type', '');
    const lang: string = JsonUtil.getString(stream, 'Language', '');
    const display: string = JsonUtil.getString(stream, 'DisplayTitle', '');
    const name: string = display.length > 0 ? display : JsonUtil.getString(stream, 'Title', '');
    const codec: string = JsonUtil.getString(stream, 'Codec', '');
    const channels: number = JsonUtil.getNumber(stream, 'Channels', 0);
    let text: string = name.length > 0 ? name : (lang.length > 0 ? lang : type);
    if (codec.length > 0) {
      text += ` · ${codec}`;
    }
    if (channels > 0) {
      text += ` · ${channels}ch`;
    }
    return text;
  }

  /** 播放器音轨 → 选项文案：以 Jellyfin 的语言/标题为准（播放器通常只有语言码） */
  private avAudioLabel(track: ESObject, ordinal: number): string {
    const jfAudios: Object[] = this.streamsOfType('Audio');
    const lang: string = JsonUtil.getString(track, 'lang', '');
    const name: string = JsonUtil.getString(track, 'name', '');
    const mime: string = JsonUtil.getString(track, 'mime', '');
    const ch: number = JsonUtil.getNumber(track, 'ch', 0);
    let text: string = '';
    if (ordinal >= 0 && ordinal < jfAudios.length) {
      text = this.trackLabel(jfAudios[ordinal] as ESObject);
    } else {
      text = name.length > 0 ? name : (lang.length > 0 ? lang : `音轨 ${ordinal + 1}`);
      if (mime.length > 0) {
        text += ` · ${mime}`;
      }
      if (ch > 0) {
        text += ` · ${ch}ch`;
      }
    }
    return text;
  }

  /**
   * 轨道面板里的一行（整行可点、选中态高亮 + ✓）。
   *
   * 为什么不用 ChipButton：一集剧常有几十条字幕，chip 流式排布既不好读也不好点，
   * 主流播放器的轨道菜单都是"整行列表 + 右侧选中标记"。
   *
   * 参数用 `kind + value` 而不是回调函数：@Builder 的参数由 ArkTS 统一转译，
   * 传函数类型参数在转译产物里不被接受（es2abc 语法错误），改为参数化事件再分发。
   */
  @Builder
  TrackRow(label: string, selected: boolean, kind: string, value: number) {
    Row() {
      Text(label)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontWeight(selected ? FontWeight.Medium : FontWeight.Regular)
        .fontColor(selected ? this.colors().brandPrimary : this.colors().textPrimary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
        .layoutWeight(1)
      if (selected) {
        Text('✓')
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().brandPrimary)
          .margin({ left: 8 })
      }
    }
    .width('100%')
    .height(48)
    .padding({ left: 12, right: 12 })
    .borderRadius(ThemeConstants.CHIP_RADIUS)
    .backgroundColor(selected ? this.colors().chipBackgroundPressed : '#00000000')
    .onClick(() => {
      this.onTrackRowTap(kind, value);
    })
  }

  /** 轨道行点击分发：kind 见 TrackSheet（av / jfaudio / sub / suboff / none） */
  private onTrackRowTap(kind: string, value: number): void {
    if (kind === 'av') {
      this.onPickAvAudio(value);
    } else if (kind === 'jfaudio') {
      this.onPickJfAudio(value);
    } else if (kind === 'sub') {
      this.onPickSubtitleStream(value, this.subtitleCodecAt(value));
    } else if (kind === 'suboff') {
      this.clearSubtitle();
    }
  }

  /** 某条字幕流的编码（用于决定请求格式与是否图形字幕） */
  private subtitleCodecAt(streamIndex: number): string {
    const subs: Object[] = this.streamsOfType('Subtitle');
    for (let i = 0; i < subs.length; i++) {
      if (JsonUtil.getNumber(subs[i] as ESObject, 'Index', -2) === streamIndex) {
        return JsonUtil.getString(subs[i] as ESObject, 'Codec', '');
      }
    }
    return '';
  }

  @Builder
  TrackSectionTitle(text: string) {
    Text(text)
      .fontSize(ThemeConstants.LABEL_SMALL)
      .fontColor(this.colors().textTertiary)
      .width('100%')
      .margin({ top: 6, bottom: 2 })
  }

  /** 音频/字幕选择面板内容 */
  @Builder
  TrackSheet() {
    Column() {
      this.TrackSectionTitle('音频')
      if (this.avAudioTracks.length > 0) {
        // ForEach 的 key 里带上"是否选中"：ArkUI 对 key 未变的项不会重建，
        // 若只用轨道 index 作 key，切换后选中标记不会移动（设备实测的缺陷）。
        ForEach(this.avAudioTracks, (item: Object, index: number) => {
          this.TrackRow(this.avAudioLabel(item as ESObject, index),
            this.avAudioIndex === JsonUtil.getNumber(item as ESObject, 'idx', -2),
            'av', JsonUtil.getNumber(item as ESObject, 'idx', -1))
        }, (item: Object) => `av${JsonUtil.getNumber(item as ESObject, 'idx', -1)}`
          + `-${this.avAudioIndex === JsonUtil.getNumber(item as ESObject, 'idx', -2) ? 1 : 0}`)
      } else {
        // 播放器没给出轨道列表（转码等）：按 Jellyfin 流列表走兜底重开
        ForEach(this.streamsOfType('Audio'), (item: Object, index: number) => {
          this.TrackRow(this.trackLabel(item as ESObject),
            this.audioStreamIndex === JsonUtil.getNumber(item as ESObject, 'Index', -2),
            'jfaudio', index)
        }, (item: Object) => `jfa${JsonUtil.getNumber(item as ESObject, 'Index', -1)}`
          + `-${this.audioStreamIndex === JsonUtil.getNumber(item as ESObject, 'Index', -2) ? 1 : 0}`)
        if (this.streamsOfType('Audio').length === 0) {
          this.TrackRow('无可切换的音轨', false, 'none', -1)
        }
      }

      this.TrackSectionTitle('字幕')
      this.TrackRow('关闭字幕',
        this.avSubtitleIndex < 0 && this.subtitleStreamIndex < 0, 'suboff', -1)
      ForEach(this.streamsOfType('Subtitle'), (item: Object) => {
        this.TrackRow(this.subtitleLabel(item as ESObject),
          this.subtitleStreamIndex === JsonUtil.getNumber(item as ESObject, 'Index', -2),
          'sub', JsonUtil.getNumber(item as ESObject, 'Index', -1))
      }, (item: Object) => `sub${JsonUtil.getNumber(item as ESObject, 'Index', -1)}`
        + `-${this.subtitleStreamIndex === JsonUtil.getNumber(item as ESObject, 'Index', -2) ? 1 : 0}`)
      if (this.streamsOfType('Subtitle').length === 0) {
        this.TrackRow('该视频没有字幕', false, 'none', -1)
      }

      if (this.trackNote.length > 0) {
        Text(this.trackNote)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().brandPrimary)
          .width('100%')
          .margin({ top: 8 })
      }
      Text(this.softPlaying
        ? '软解模式：轨道切换不可用（软解只解码视频帧）'
        : '切换即时生效，不中断播放')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textTertiary)
        .width('100%')
        .margin({ top: 8 })
    }
    .width('100%')
    .alignItems(HorizontalAlign.Start)
  }

  /** 字幕行文案：图形字幕标注"本机不支持" */
  private subtitleLabel(stream: ESObject): string {
    const codec: string = JsonUtil.getString(stream, 'Codec', '');
    const base: string = this.trackLabel(stream);
    if (isImageSubtitleCodec(codec)) {
      return `${base}（图形字幕，暂不支持）`;
    }
    return base;
  }

  private async reportSoftProgressThrottled(ptsSec: number): Promise<void> {
    if (this.itemId.length === 0) {
      return;
    }
    // 位置 0 不上报：上报会把服务端的观看进度写成 0，等于**抹掉用户的续播点**
    // （软解会话刚打开时会先报一次 pts=0.0，实测就在这个时机把进度清了）。
    if (ptsSec <= 0.5) {
      return;
    }
    const now: number = Date.now();
    if (this.lastProgressReportAt > 0 && now - this.lastProgressReportAt < 5000) {
      return;
    }
    this.lastProgressReportAt = now;
    // 记录"正在播放"，供 Ability.onDestroy 在应用退出时上报 stopped（会话卫生）
    PlaybackState.set(this.itemId, Math.floor(ptsSec * 10000000));
    await JellyfinNative.reportPlaybackProgress(this.itemId,
      Math.floor(ptsSec * 10000000), false);
    // 同步进系统媒体会话（通知栏/锁屏进度条随播放推进）；与进度上报同一节流节奏。
    if (this.avSessionRef !== null) {
      this.avSessionRef.setAVPlaybackState({
        state: avSession.PlaybackState.PLAYBACK_STATE_PLAY,
        position: { elapsedTime: Math.floor(ptsSec * 1000), updateTime: Date.now() }
      }).catch(() => {
        // 同步失败不影响播放
      });
    }
  }

  /**
   * 长按 2× 快进：按住 600ms 未松开即把播放速度临时设为 2×，松手恢复。
   * 这是主流播放器的标准手势；对硬解与软解都有效（AVPlayer 走 setSpeed，
   * 软解路径由帧循环的节流上报体现位置推进速度）。
   */
  private startLongPressBoost(): void {
    this.cancelLongPressTimer();
    this.longPressTimerId = setTimeout(() => {
      this.longPressTimerId = -1;
      if (this.controlsLocked || this.avPlayer === null) {
        return;
      }
      if (!this.isPlaying) {
        return;
      }
      this.longPressBoosting = true;
      this.avPlayer.setSpeed(2);
      this.gestureFeedback = '2× 快进';
      this.gestureIcon = 'seek';
      this.gestureRatio = -1;
      this.showFeedback = true;

    }, 600);
  }

  private cancelLongPressTimer(): void {
    if (this.longPressTimerId >= 0) {
      clearTimeout(this.longPressTimerId);
      this.longPressTimerId = -1;
    }
  }

  /**
   * 启动视频区触摸事件轮询：从原生侧 DispatchTouchEvent 捕获的触摸事件中读取并处理手势。
   *
   * **这是一个兜底通道，不是主通道。** 设备实测（hilog `XComponentBridge`）：
   * `OH_NativeXComponent_RegisterCallback rc=0`、`OnSurfaceCreated` 都正常，但
   * `DispatchTouchEvent` 从未被回调 —— 因为 XComponent 之上还有一层透明 ArkUI 手势层
   * （见 build() 里的 Column + onTouch），ArkUI 在应用层就把触摸消化了，
   * 原生回调因此不会触发（`player_gesture.txt` 里出现的是 `gesture seekDeltaMs=...`，
   * 即 ArkUI 层的记录）。真正的修复是"回调不能为 nullptr"（为 nullptr 时框架不向该区域派发触摸），
   * 那一点已经在 xcomponent_bridge.cpp 里落实。
   *
   * 既然如此，轮询就不该常驻 60fps 空转（每秒 60 次 NAPI 往返 + JSON 序列化，
   * 在软解播放这种 CPU 已经很紧的场景纯属浪费）。改为**自适应退避**：
   * 连续若干次读不到事件就降到低频；一旦真读到事件（说明原生通道确实在工作）
   * 立刻恢复高频，保证兜底通道可用时依然跟手。
   */
  private startTouchPollTimer(): void {
    this.stopTouchPollTimer();
    this.touchPollBackoff = 0;
    this.touchPollTimerId = setInterval(() => {
      this.pollNativeTouchEvent();
    }, kTouchPollFastMs);
  }

  private stopTouchPollTimer(): void {
    if (this.touchPollTimerId >= 0) {
      clearInterval(this.touchPollTimerId);
      this.touchPollTimerId = -1;
    }
    this.touchPollBackoff = 0;
  }

  /** 按当前退避档位重设定轮询间隔（16ms ↔ 250ms） */
  private retuneTouchPoll(hasEvent: boolean): void {
    if (hasEvent) {
      this.touchPollBackoff = 0;
      if (this.touchPollTimerId >= 0 && this.touchPollIntervalMs !== kTouchPollFastMs) {
        clearInterval(this.touchPollTimerId);
        this.touchPollIntervalMs = kTouchPollFastMs;
        this.touchPollTimerId = setInterval(() => {
          this.pollNativeTouchEvent();
        }, kTouchPollFastMs);
      }
      return;
    }
    if (this.touchPollBackoff < kTouchPollBackoffLimit) {
      this.touchPollBackoff++;
      if (this.touchPollBackoff === kTouchPollBackoffLimit && this.touchPollTimerId >= 0
        && this.touchPollIntervalMs !== kTouchPollSlowMs) {
        // 连续读不到 → 原生通道在本配置下不工作，降到低频（保留兜底能力，几乎不耗电）
        clearInterval(this.touchPollTimerId);
        this.touchPollIntervalMs = kTouchPollSlowMs;
        this.touchPollTimerId = setInterval(() => {
          this.pollNativeTouchEvent();
        }, kTouchPollSlowMs);
      }
    }
  }

  /**
   * 从原生侧读取并处理最新的触摸事件。
   * 事件类型映射：0=down 1=up 2=move 3=cancel
   */
  private pollNativeTouchEvent(): void {
    try {
      const raw: string = JellyfinNative.getXComponentTouchEvent();
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        this.retuneTouchPoll(false);
        return;
      }
      const data: ESObject = result.data as ESObject;
      const valid: boolean = JsonUtil.getBoolean(data, 'valid', false);
      if (!valid) {
        // 没读到事件 → 累计退避（原生通道在本配置下不工作，别空转 60fps）
        this.retuneTouchPoll(false);
        return;
      }
      const ts: number = JsonUtil.getNumber(data, 'timestamp', 0);
      // 避免重复处理同一事件
      if (ts === this.lastProcessedTouchTs || ts <= 0) {
        this.retuneTouchPoll(false);
        return;
      }
      // 原生通道确实在工作 → 恢复高频，保证跟手
      this.retuneTouchPoll(true);
      this.lastProcessedTouchTs = ts;
      const type: number = JsonUtil.getNumber(data, 'type', -1);
      const x: number = JsonUtil.getNumber(data, 'x', 0);
      const y: number = JsonUtil.getNumber(data, 'y', 0);
      // 按官方枚举分发：0=Down 1=Up 2=Move 3=Cancel
      // CANCEL 与 Up 同样处理：手势被打断（来电、系统手势抢占）时必须结束本次滑动，
      // 否则手势状态会卡在"拖拽中"，下一次按下被当成同一次滑动的延续。
      if (type === kTouchTypeDown) {
        this.handleNativeTouchDown(x, y);
      } else if (type === kTouchTypeMove) {
        this.handleNativeTouchMove(x, y);
      } else if (type === kTouchTypeUp || type === kTouchTypeCancel) {
        this.handleNativeTouchUp(x, y);
      }
    } catch (_err) {
      // 轮询失败静默忽略，但同样计入退避（避免持续失败时空转）
      this.retuneTouchPoll(false);
    }
  }

  private handleNativeTouchDown(x: number, y: number): void {
    if (this.controlsLocked) {
      return;
    }
    // 探针：记录原生触摸事件到达，便于设备验证

    this.onGestureDown(x, y);
  }

  private handleNativeTouchMove(x: number, y: number): void {
    if (this.controlsLocked) {
      return;
    }
    this.onGestureMove(x, y);
  }

  private handleNativeTouchUp(x: number, y: number): void {
    if (this.controlsLocked) {
      // 与 ArkUI 手势层同一口径：锁定态只保留"单击显示/收起锁提示"
      this.handleLockedTap(x);
      return;
    }

    this.onGestureUp(x, y);
  }

  // ─────────────── 手势状态机（两条输入通道共用） ───────────────
  //
  // 为什么合并：页面里同时存在两条触摸来源 —— ArkUI 手势层（透明覆盖层的 onTouch）
  // 与原生 XComponent 回调的兜底轮询（见 startTouchPollTimer）。两条通道各自实现一套手势，
  // 任何手势改动都得改两处，且两边行为很容易不一致（"单击/双击"这类新判定
  // 就只能挂在其中一条上）。现在两边都调用同一套 `onGesture*`，行为必然一致。

  /** 按下：记录基准位置，开始长按加速计时 */
  private onGestureDown(x: number, y: number): void {
    this.seekBaseMs = this.positionMs;
    this.seekDragMs = 0;
    this.seekLastX = x;
    this.brightnessBase = this.windowBrightness;
    this.brightnessLastY = y;
    this.volumeBase = this.volume;
    this.volumeLastY = y;
    // 手势方向判定用"相对按下点的累计位移"，不用单次 Move 的位移。
    //
    // 为什么必须这样（设备实测的缺陷）：注入/慢速滑动时每个 Move 事件的位移常常只有 1–5px，
    // 原来"单次位移 > 5px"的阈值会把整段慢速滑动全部过滤掉 —— 实测 500ms 滑完 500px
    // 时 seekDeltaMs 恒为 0（完全不响应），100ms 滑同样距离才识别。
    this.touchDownX = x;
    this.touchDownY = y;
    this.gestureAxis = '';
    // 长按 2× 快进：按住 600ms 未松开即临时加速，松手恢复原速
    this.startLongPressBoost();
  }

  /** 移动：先定方向（水平=seek，垂直=亮度/音量），再按累计位移换算幅度 */
  private onGestureMove(x: number, y: number): void {
    const totalX: number = x - this.touchDownX;
    const totalY: number = y - this.touchDownY;
    if (this.gestureAxis.length === 0) {
      if (Math.abs(totalX) > kTapSlopVp || Math.abs(totalY) > kTapSlopVp) {
        this.gestureAxis = Math.abs(totalX) >= Math.abs(totalY) ? 'seek' : 'level';
      }
    }
    // 左右半屏判定同样必须用随旋转更新的宽度（见 gestureWidth 的说明）：
    // 若用 display.width，横屏时屏幕右半部分会被判成「左侧」→ 横向滑动会去调亮度。
    const isLeftSide: boolean = x < this.gestureWidth() / 2;
    if (this.gestureAxis === 'seek') {
      // 水平滑动 → seek：幅度按"按下点起的累计位移"算，与事件密度无关
      this.seekLastX = x;
      this.seekDragMs = totalX * 2;
      const total: number = this.durationMs > 0 ? this.durationMs : 1;
      const clamped: number = Math.max(0, Math.min(total, this.seekBaseMs + this.seekDragMs));
      this.positionMs = clamped;
      this.lastSeekForward = totalX >= 0;
      this.gestureFeedback = this.lastSeekForward
        ? `+${this.formatTime(Math.abs(this.seekDragMs))}`
        : `-${this.formatTime(Math.abs(this.seekDragMs))}`;
      this.gestureIcon = 'seek';
      this.gestureRatio = total > 0 ? clamped / total : 0;
      this.showFeedback = true;
    } else if (this.gestureAxis === 'level' && Math.abs(totalY) > kTapSlopVp) {
      if (isLeftSide) {
        // 亮度：向上增加（窗口级真实亮度，见 applyBrightness）
        const newBrightness: number =
          Math.max(0.01, Math.min(1, this.brightnessBase - totalY / kLevelGestureRange));
        this.applyBrightness(newBrightness);
        this.gestureFeedback = `${Math.round(newBrightness * 100)}%`;
        this.gestureIcon = 'brightness';
        this.gestureRatio = newBrightness;
        this.showFeedback = true;
        this.brightnessLastY = y;
      } else {
        // 音量：向上增加
        const newVolume: number =
          Math.max(0, Math.min(1, this.volumeBase - totalY / kLevelGestureRange));
        this.volume = newVolume;
        if (this.avPlayer !== null) {
          this.avPlayer.setVolume(newVolume);
        }
        this.gestureFeedback = `${Math.round(newVolume * 100)}%`;
        this.gestureIcon = 'volume';
        this.gestureRatio = newVolume;
        this.showFeedback = true;
        this.volumeLastY = y;
      }
    }
  }

  /** 抬手：滑动落地（seek）+ 点击判定（单击显隐 / 双击 ±10s） */
  private onGestureUp(x: number, y: number): void {
    const moved: number = Math.max(Math.abs(x - this.touchDownX), Math.abs(y - this.touchDownY));
    const isTap: boolean = this.gestureAxis.length === 0 && moved < kTapSlopVp;
    if (this.gestureAxis === 'seek' && Math.abs(this.seekDragMs) > 100) {
      // 拖动进度：抬手才真正落地（拖动过程中只更新界面，避免每一帧都发 seek 请求）
      this.seekTo(this.positionMs);

    }
    // 松手结束长按加速（无论是否已进入加速态）
    this.stopLongPressBoost();
    this.seekDragMs = 0;
    this.gestureAxis = '';
    if (this.showFeedback) {
      this.dismissFeedback();
    }
    if (isTap) {
      this.handleTapUp(x);
    }
  }

  /**
   * 统一的定位入口（硬解 + 软解）。
   *
   * 为什么必须统一：此前所有 seek 都只调 `avPlayer.seek()`，而软解播放时 `avPlayer` 已经停掉，
   * 于是软解下"拖动进度条 / 点 ±10s"完全没有反应（画面不动、进度也不上报）。
   * 软解会话本身支持 `av_seek_frame`（见 softPlaySeek），这里接上即可。
   */
  private seekTo(ms: number): void {
    let target: number = Math.max(0, Math.round(ms));
    if (this.durationMs > 0) {
      target = Math.min(target, this.durationMs);
    }
    if (this.softPlaying) {
      // 软解的 seek 是**排队**的：原生侧只记录目标，真正的 av_seek_frame 由下一次拉帧
      // 在解码线程执行（UI 线程不做同步 HTTP；也避免与解码线程抢 AVFormatContext）。
      const raw: string = JellyfinNative.softPlaySeek(target / 1000);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      const queued: boolean = result.ok && result.data !== null
        && JsonUtil.getBoolean(result.data as ESObject, 'ok', false);
      if (queued) {
        this.softPositionMs = target;
        this.softSeekTargetMs = target;
        // 保持窗口：等画面追上目标（最多 4 秒），期间不做进度回写
        this.softSeekHoldUntil = Date.now() + 4000;
        // 暂停状态下拉帧定时器已停：补拉一帧，让排队的 seek 立刻执行并显示出目标画面
        if (this.softPaused) {
          this.pullSoftFrame();
        }
      }

    } else if (this.avPlayer !== null) {
      this.avPlayer.seek(target);

    }
    this.positionMs = target;
  }


  private stopLongPressBoost(): void {
    this.cancelLongPressTimer();
    if (!this.longPressBoosting) {
      return;
    }
    this.longPressBoosting = false;
    if (this.avPlayer !== null) {
      this.avPlayer.setSpeed(this.playbackSpeed);
    }

    this.dismissFeedback();
  }

  private softStopAvPlayer(): void {
    if (this.avPlayer !== null) {
      try {
        this.avPlayer.stop();
        this.avPlayer.release();
      } catch (err) {
        // 忽略：AVPlayer 已在错误态
      }
      this.avPlayer = null;
    }
  }

  private stopSoftPlay(): void {
    this.stopSoftTimer();
    JellyfinNative.softPlayClose();
    this.softPlaying = false;
    this.softPaused = false;
    // 清掉看门狗状态：否则上一次卡死的起始时刻会留到下一次播放，导致新的拉帧被立刻误判为卡死
    this.softPulling = false;
    this.softPullStartedAt = 0;
    this.softRenderErrorStreak = 0;
    // 停止/切换/退出时补发最终进度：只靠节流中的周期上报会丢失最后几秒位置
    // （与硬解路径的 flushStop 行为保持一致）
    if (this.itemId.length > 0 && this.lastProgressReportAt > 0) {
      JellyfinNative.reportPlaybackStopped(this.itemId, this.softPositionMs * 10000);
      this.lastProgressReportAt = 0;
    }
  }

  private async openPlayer(): Promise<void> {
    this.status = UiState.LOADING;
    const target: string = this.playUrl.length > 0 ? this.playUrl : this.itemId;
    const raw: string = await JellyfinNative.playerOpen(target, this.playbackOptions);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '打开播放器失败';
      this.refreshState();
      return;
    }
    // 从 C++ 后端获取实际播放 URL
    const resolvedUrl: string = JsonUtil.getString(result.data, 'playUrl', '');
    if (resolvedUrl.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '无法获取播放地址';
      return;
    }
    // MediaSourceId：Jellyfin 外挂字幕端点需要（字幕切换时用）
    this.mediaSourceId = JsonUtil.getString(result.data, 'mediaSourceId', '');
    // 创建 AVPlayer 进行实际视频渲染
    this.createAvPlayer(resolvedUrl);
    // 进入系统媒体会话体系（后台播放/媒体控件）；失败不影响播放
    this.initAvSession();
  }

  private async createAvPlayer(url: string): Promise<void> {
    // 先释放"上一个"播放器与软解会话，再创建新的。
    //
    // 为什么必须这样（服务端实证的缺陷）：`createAvPlayer` 原来直接覆盖 `this.avPlayer`，
    // 于是"重试"或再次进入播放页时会**同时存在两个活跃播放器**——服务端 `/Sessions`
    // 会看到同一客户端的两条播放会话都在推进（实测：`我爱体育 70s` 与 `说事儿 393s` 同时推进），
    // 观看记录与"继续观看"随之被污染。
    this.softStopAvPlayer();
    this.stopSoftPlay();
    this.preparePendingSurface = false;
    try {
      this.avPlayer = await media.createAVPlayer();
      this.avPlayer.on('stateChange', (state: string) => {
        this.stateText = state;
        if (state === 'initialized') {
          // ⚠️ 关键修复：AVPlayer 状态机为 idle →(设置 url)→ initialized →prepare()→ preparing → prepared。
          // 原实现只设置 url 就等待 'prepared'，从不调用 prepare()，播放器会永远停在 initialized，
          // 界面一直显示"加载播放器..."（设备实测：H.264/MP4 也一样起不来）。
          //
          // 另一个关键点：`surfaceId` 只能在 initialized 及之后设置。这里先绑视频面再 prepare；
          // 若此刻 surface 还没就绪（onLoad 未到），把 prepare 交给 onLoad 触发。
          this.bindSurfaceIfReady();
          if (this.surfaceId.length > 0) {
            this.avPlayer?.prepare();
          } else {
            this.preparePendingSurface = true;

          }
        } else if (state === 'prepared') {
          this.durationMs = (this.avPlayer?.duration ?? 0);
          // 视频真实尺寸：只在**与元数据不一致**时才改视频面尺寸（避免播放中重建 surface）。
          const vw: number = this.avPlayer?.width ?? 0;
          const vh: number = this.avPlayer?.height ?? 0;
          if (vw > 0 && vh > 0 && (vw !== this.videoWidthPx || vh !== this.videoHeightPx)) {

            this.videoWidthPx = vw;
            this.videoHeightPx = vh;
          }
          this.applyAspectToAvPlayer();

          // 播放期间保持屏幕常亮（看完一集不该因为息屏中断）
          this.applyKeepScreenOn(true);
          this.status = UiState.SUCCESS;
          this.avPlayer?.play();
          this.isPlaying = true;
          this.revealControls();
          // 续播：seek 到宿主传入的观看进度（只做一次；切轨道/重开播放不再回到这里）
          if (this.startPositionMs > 1000 && !this.resumeApplied) {
            this.resumeApplied = true;
            this.avPlayer?.seek(this.startPositionMs);
            this.positionMs = this.startPositionMs;
          }
          // 硬解已就绪：清掉软解可能留下的提示（上一段软解会话的信息不应继续挂在画面上）
          this.clearSoftNotice();
          // 轨道列表只有 prepared 之后才取得到（音轨/字幕切换的基础）
          this.refreshAvTracks();
        } else if (state === 'completed') {
          this.isPlaying = false;
          this.revealControls();
          if (this.itemId.length > 0) {
            JellyfinNative.reportPlaybackStopped(this.itemId, this.positionMs * 10000);
          }
        } else if (state === 'error') {
          this.handlePlaybackFailure('播放出错');
        }
      });
      this.avPlayer.on('error', (err: BusinessError) => {
        // 带错误码：只有文案时无法区分"编码不被支持"(801) 与"状态/参数不合法"(5400xxx)，
        // 也就无法判断是平台能力问题还是我们自己的调用问题。
        this.handlePlaybackFailure(`播放器错误(code=${err.code} ${err.message})`);
      });
      // 外挂字幕：播放器解析字幕文件后把"当前该显示哪句"推给应用，由应用渲染
      // （`SubtitleInfo { startTime, duration, text }`；文本型字幕才有内容）
      this.avPlayer.on('subtitleUpdate', (info: media.SubtitleInfo) => {
        const text: string = info.text !== undefined ? info.text : '';
        this.subtitleText = text;
      });
      // 视频面**不在 idle 设置**：AVPlayer 的状态机规定 `surfaceId` 只能在 `initialized`
      // 及之后设置，在 `idle` 里设置会直接报
      // `5400102 Operate Not Permit: the attribute(SurfaceID) can only be set in the initialized state`
      // → 播放器进入错误态 → 被"自动回退软解"接住（设备实测：H.264 High 8-bit 1080p MKV
      // 这种本该硬解的片子也只能走软解，帧率被压到 ~10fps）。
      // 现在的顺序是：先设 url（idle → initialized）→ 在 stateChange 里绑定 surface → prepare()。
      this.avPlayer.url = url;
    } catch (_err) {
      this.handlePlaybackFailure('初始化播放器失败');
    }
  }

  /**
   * 绑定视频面（只在合法的播放器状态下执行）。
   *
   * 为什么要这个守卫：`surfaceId` 的合法赋值时机是 `initialized` / `prepared` / `playing` /
   * `paused`；在 `idle` 赋值会抛 5400102 并把播放器打成错误态（见 createAvPlayer 的说明）。
   * XComponent 的 onLoad 与 AVPlayer 的 stateChange 谁先到并不确定，所以两边都调用它，
   * 由状态决定这一刻能不能绑。
   */
  private bindSurfaceIfReady(): void {
    if (this.avPlayer === null || this.surfaceId.length === 0) {
      return;
    }
    const st: string = this.avPlayer.state;
    if (st === 'initialized' || st === 'prepared' || st === 'playing' || st === 'paused'
      || st === 'completed') {
      try {
        this.avPlayer.surfaceId = this.surfaceId;
      } catch (_e) {
        // 状态恰好又变了：忽略，下一次事件会再试
      }
    }
  }

  /**
   * 播放失败统一入口：进入错误态，并尝试**自动回退到 FFmpeg 软解**。
   *
   * 这是"播放功能（硬解 + 软解）"的落地：系统硬解解不了的编码（如模拟器上的 HEVC、
   * 设备上不支持的 profile）不应直接把用户丢在错误页，而应自动改用 CPU 软解续播。
   * 只回退一次，避免与用户手动"重试"互相打架。
   */
  private handlePlaybackFailure(message: string): void {
    // ── 无感切换：别先闪一次"播放出错"整屏覆盖层 ──────────────────────────
    // 原来的顺序是"置 ERROR → 再尝试软解"，于是用户会看到：硬解报错 → 整屏红色错误页
    // → 半秒后被软解画面顶掉。这就是"有感"的来源。
    // 现在：只要还有软解可回退，就保持**加载态**（转圈 + 标题 + "正在切换软解…"），
    // 只有软解也起不来时才进错误态（那时错误页是必要的终态）。
    this.resumeApplied = false;
    const willFallback: boolean = !this.softFallbackTried && !this.softPlaying;
    if (!willFallback) {
      this.status = UiState.ERROR;
      this.errorMsg = message;
      return;
    }
    // 记录"失败发生时的播放位置"：软解要**接着这里**播，而不是回到进播放页时的续播点。
    // 否则出现"硬解播到 10 分钟报错 → 软解从 0 开始"的进度倒退（无感切换的另一半）。
    if (this.positionMs > 1000) {
      this.softFallbackStartMs = this.positionMs;
    }
    this.status = UiState.LOADING;
    this.stateText = '正在切换软解…';
    this.setSoftNotice(`硬解不可用（${message}）→ 正在切换 FFmpeg 软解…`, true);
    this.maybeFallbackToSoftDecode(message);
  }

  private async maybeFallbackToSoftDecode(reason: string): Promise<void> {
    if (this.softFallbackTried || this.softPlaying) {
      return;
    }
    this.softFallbackTried = true;
    this.softRenderFailed = false;
    this.setSoftNotice(`硬解不可用（${reason}）→ 正在切换 FFmpeg 软解…`, false);
    await this.startSoftPlay();
    if (!this.softPlaying) {
      // 软解也起不来时回到错误态，让用户看到原因并手动重试。
      //
      // 关键：**不要把具体原因覆盖掉**。此前这里只把 status 置为 ERROR，而
      // `startSoftPlay` 给出的原因（如"软解画面无法上屏：…"）随后会被下面那句
      // "已自动切换软解播放"盖掉 —— 于是渲染失败的场景下用户看到的是"一切正常"的提示
      // 配一块纯黑屏。现在把原因写进错误态文案，用户知道发生了什么、也知道可以重试。
      const reasonText: string = this.softStatus.length > 0
        ? this.softStatus
        : (this.softRenderFailed ? '软解画面无法上屏' : '软解启动失败');
      this.status = UiState.ERROR;
      this.errorMsg = reasonText;
      return;
    }
    // 软解已经跑起来了：必须离开错误态。
    //
    // 为什么：此前只在软解失败时改状态，成功回退时 status 仍是 ERROR，
    // 于是**整屏错误覆盖层盖在正在播放的软解画面上**（设备实测：页面显示"播放器错误 + 重试"，
    // 而底下软解帧号一直在涨）。用户看到的是错误页，等于自动回退这个功能白做。
    this.status = UiState.SUCCESS;
    this.errorMsg = '';
    this.isPlaying = true;
    // 软解会话已支持 seek 续播（av_seek_frame + avcodec_flush_buffers），
    // 这里如实提示用户当前状态。这条是"用户需要知情"的，不自动隐去。
    this.setSoftNotice(this.startPositionMs > 1000
      ? `已自动切换软解（将从 ${this.formatTime(this.startPositionMs)} 续播）`
      : '已自动切换软解播放', true);
  }

  private refreshState(): void {
    if (this.softPlaying) {
      // 软解路径的进度来自解码帧的时间戳（见 pullSoftFrame），
      // 此前这里只读 avPlayer（软解时它已停掉），于是**软解播放时进度条一直不走**。
      this.positionMs = this.softPositionMs;
      return;
    }
    if (this.avPlayer !== null) {
      this.positionMs = this.avPlayer.currentTime;
      this.durationMs = this.avPlayer.duration;
      this.isPlaying = this.avPlayer.state === 'playing';
    }
  }

  /**
   * 播放/暂停。
   *
   * 覆盖三条路径：软解播放（暂停=停止拉帧）、播放结束（重播要先回到起点）、硬解播放。
   * 暂停/恢复都补报一次播放进度，保证服务端的"继续观看"与多端同步不掉队。
   */
  private onPlayPause(): void {
    if (this.softPlaying) {
      if (this.softPaused) {
        this.softPaused = false;
        this.isPlaying = true;
        this.startSoftTimer();
        if (this.itemId.length > 0) {
          JellyfinNative.reportPlaybackProgress(this.itemId, this.softPositionMs * 10000, false);
        }
        this.scheduleHideControls();
      } else {
        this.softPaused = true;
        this.isPlaying = false;
        this.stopSoftTimer();
        if (this.itemId.length > 0) {
          JellyfinNative.reportPlaybackProgress(this.itemId, this.softPositionMs * 10000, true);
        }
        this.showControls = true;
      }
      return;
    }
    if (this.avPlayer === null) {
      return;
    }
    if (this.isPlaying) {
      this.avPlayer.pause();
      this.isPlaying = false;
      if (this.itemId.length > 0) {
        JellyfinNative.reportPlaybackProgress(this.itemId, this.positionMs * 10000, true);
      }
      this.showControls = true;
    } else {
      // 播放结束后再点播放键：先回到起点，否则会立刻又"结束"一次
      if (this.isCompleted()) {
        this.seekTo(0);
      }
      this.avPlayer.play();
      this.isPlaying = true;
      if (this.itemId.length > 0) {
        JellyfinNative.reportPlaybackProgress(this.itemId, this.positionMs * 10000, false);
      }
      this.scheduleHideControls();
    }
    this.refreshState();
  }

  private cycleSpeed(): void {
    const speeds: number[] = PlayerPage.SPEEDS;
    const currentIdx: number = speeds.indexOf(this.playbackSpeed);
    const nextIdx: number = (currentIdx + 1) % speeds.length;
    this.playbackSpeed = speeds[nextIdx];
    if (this.avPlayer !== null) {
      this.avPlayer.setPlaybackRate(this.playbackSpeed);
    }
    this.revealControls();
  }

  private flushStop(): void {
    if (this.stopped) {
      return;
    }
    this.stopped = true;
    // 只有"真的播过"才上报停止位置。
    //
    // 为什么：上报停止会把服务端的观看进度写成这个位置；如果播放器根本没起来
    // （拉流失败、或用户刚进来就退出），位置是 0，于是**用户原有的观看进度被清成 0**，
    // 「继续观看」条目随之消失 —— 设备实测踩到过：一次失败的打开把 9 分多钟的进度抹平了。
    // 位置为 0 时直接不上报，让服务端保留原进度。
    const hasProgress: boolean = this.positionMs > 1000 || this.isPlaying || this.isCompleted();
    if (this.itemId.length > 0 && hasProgress) {
      JellyfinNative.reportPlaybackStopped(this.itemId, this.positionMs * 10000);
    }
    if (this.avPlayer !== null) {
      this.avPlayer.stop();
      this.avPlayer.release();
      this.avPlayer = null;
    }
    JellyfinNative.playerStop();
  }

  private sliderMax(): number {
    return this.durationMs > 0 ? this.durationMs : Math.max(this.positionMs + 1, 1);
  }

  private isCompleted(): boolean {
    return this.durationMs > 0 && this.positionMs >= this.durationMs * 0.98;
  }

  private getScreenWidth(): number {
    return WindowLayout.screenWidth();
  }

  /**
   * 手势分区/双击判定所用的「屏宽」（vp）。
   *
   * 为什么不能直接用 `getScreenWidth()`（= `display.width / density`）：
   * 设备实测确认 `display.width` **不随窗口旋转变化** —— 横屏时它仍返回竖屏宽度（1260px / 3.39 ≈ 371vp），
   * 而横屏下触摸坐标 x 最大到约 2844px / 3.39 ≈ 839vp。
   * 后果（设备实测）：
   * ① 双击左右分区判定恒为「左侧」→ 横屏双击右半屏被判成快退（或位置被夹到 0）；
   * ② 「两次抬手位置相差 < 屏宽/3」的阈值只有约 124vp，横屏下正常的双击很容易被判成两次单击。
   * 根的修复是改用**根容器实测宽度**（`areaWidthVp`，由 onAreaChange 随旋转更新），
   * 它在竖屏等于屏宽、在横屏等于屏高换算后的宽度，两个方向都与实际触摸坐标系一致。
   */
  private gestureWidth(): number {
    const w: number = this.areaWidth();
    if (w > 0) {
      return w;
    }
    return this.getScreenWidth();
  }

  /**
   * 计算集数/季信息文案。
   *
   * 稳定性修复（设备实测发现的崩溃）：原实现是 `private get itemTypeLabel()`，
   * 里面直接 `const album: string = opts['album']; ... album.length > 0`，
   * 当 DetailPage 未传 album 时 `opts['album']` 为 undefined，`album.length` 抛
   * `TypeError: Cannot read property length of undefined`；而 ArkTS 会把 getter 内联进
   * build，getter 里的 try/catch 拦不住，导致**进入播放页即崩溃**（jscrash 日志
   * PlayerPage.ets:320）。现在改为：字段值先做类型判断 + 结果缓存到 @State，build 里只读状态。
   */
  private computeTypeLabel(): string {
    try {
      const opts: ESObject = JSON.parse(this.playbackOptions) as ESObject;
      const seasonNum: number = typeof opts['seasonNumber'] === 'number' ? opts['seasonNumber'] as number : 0;
      const episodeNum: number = typeof opts['episodeNumber'] === 'number' ? opts['episodeNumber'] as number : 0;
      const albumRaw: string = typeof opts['album'] === 'string' ? opts['album'] as string : '';
      if (seasonNum > 0 && episodeNum > 0) {
        return `第${seasonNum}季 第${episodeNum}集`;
      }
      if (albumRaw.length > 0) {
        return albumRaw;
      }
    } catch (_e) {
      // 参数不是合法 JSON 时忽略
    }
    return '';
  }

  @Builder
  TopBar() {
    Column() {
      Row() {
        AppIconButton({
          icon: $r('sys.symbol.chevron_left'),
          variant: 'ghost',
          iconSize: 22,
          // 触达区对齐 48vp 标准（默认 40vp；设备实测顶部栏按钮曾为 45vp，偏小）
          buttonSize: 48,
          backgroundOverride: this.colors().overlayControlStrong,
          iconColorOverride: this.colors().onOverlay,
          onTap: () => {
            this.flushStop();
            router.back();
          }
        })
        Column({ space: 3 }) {
          Text(this.title)
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onOverlay)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.typeLabel.length > 0) {
            Text(this.typeLabel)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onOverlayMuted)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .layoutWeight(1)
        .alignItems(HorizontalAlign.Start)
        .margin({ left: 8 })
        AppIconButton({
          icon: $r('sys.symbol.lock'),
          variant: 'ghost',
          iconSize: 20,
          // 与返回按钮一致：48vp 触达区（锁定按钮此前实测 45vp，且是唯一"点不中"的控件）
          buttonSize: 48,
          backgroundOverride: this.colors().overlayControlStrong,
          // 锁定态用品牌色高亮（原来用 🔒/🔓 两个 emoji 区分）
          iconColorOverride: this.controlsLocked ? this.colors().brandPrimary : this.colors().onOverlay,
          onTap: () => {
            this.controlsLocked = !this.controlsLocked;
            if (this.controlsLocked) {
              this.showControls = false;
              // 锁定瞬间不显示锁提示：先给一个干净的画面，用户点一下再看锁
              this.hideLockBadge();
            } else {
              this.revealControls();
            }
            // 记录切换时刻：锁定覆盖层会盖满整屏，若无此时间戳，
            // 同一次点击的抬手事件会"穿透"到刚出现的覆盖层上把它立刻解锁
            // （实测表现为"点了锁定却没锁上"）。
            this.lockChangedAt = Date.now();
          }
        })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)
      .padding({ left: 12, right: 12, top: 12, bottom: 4 })
    }
    .width('100%')
    // 顶部渐变遮罩：视频画面明暗不定，纯文字/图标容易在浅色画面上"消失"；
    // 与底部控制条同款 scrim 保证标题与按钮始终可读（主流播放器的通用做法）。
    .padding({ top: 8, bottom: 16 })
    .linearGradient({
      angle: 180,
      colors: [[this.colors().scrimHeavy, 0.0], ['#00000000', 1.0]]
    })
  }

  @Builder
  BottomControls() {
    Column({ space: 10 }) {
      if (this.status === UiState.ERROR) {
        Text(this.errorMsg)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().error)
          .width('100%')
          .textAlign(TextAlign.Center)
      }

      // 进度条 + 时间：已播时间在左、右侧可在"总时长 / 剩余时长"之间切换（点一下切换）。
      // 主流播放器（Infuse/iina）都是这个形态：时间紧贴进度条两端，视觉上一一对应。
      Row({ space: 10 }) {
        Text(this.formatTime(this.positionMs))
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlay)
          .fontWeight(FontWeight.Medium)
          .width(58)
          .textAlign(TextAlign.Start)
        Slider({
          value: this.positionMs,
          min: 0,
          max: this.sliderMax(),
          step: 100,
          style: SliderStyle.OutSet
        })
          .layoutWeight(1)
          .selectedColor(this.colors().brandPrimary)
          // 轨道用半透明白：视频画面明暗不定，纯灰轨道在亮画面上会"看不见"
          .trackColor(this.colors().overlayControl)
          .trackThickness(5)
          .blockSize({ width: 16, height: 16 })
          .blockColor(this.colors().onOverlay)
          .onChange((value: number) => {
            // 统一走 seekTo：硬解与软解（软解此前拖动进度条完全没有反应）都能定位
            this.seekTo(Math.floor(value));
            this.revealControls();
          })
        Text(this.rightTimeLabel())
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlayMuted)
          .width(64)
          .textAlign(TextAlign.End)
          .onClick(() => {
            this.showRemaining = !this.showRemaining;
            this.revealControls();
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      // 工具行：图标 + 文字（Infuse 底部工具行的形态）。
      // 主操作（播放/暂停、±10s）已经搬到画面正中的中央控制簇，这里只放"非播放性质"的开关，
      // 主次分明。
      //
      // 布局为什么改成"居中 + 自动换行"（本轮优化）：
      // 竖屏可用宽度只有约 340vp（屏宽 371vp − 左右各 16vp 内边距），而这 5 个按钮横排
      // 实测约需 390vp。原来放在 `Scroll` 里，结果是「倍速」被裁掉一半、「软解」整块落到
      // 屏幕外 —— 用户既看不出还有按钮，也无法手动切软解（排查软解黑屏时正是被这一点卡住）。
      // 现在用 `Flex` 自动换行：一行放不下就换到第二行（仍然居中），按钮**始终完整可见**；
      // 横屏宽度足够时自然仍是一行。
      Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Center, alignItems: ItemAlign.Center }) {
        // 画面比例：适应 / 填充 / 拉伸 / 原始（见 common/PlayerAspect.ets）
        PlayerToolButton({
          icon: $r('sys.symbol.aspectratio'),
          label: PlayerAspect.label(this.aspectMode),
          selected: this.aspectMode !== 'contain',
          onTap: () => {
            this.cycleAspect();
          }
        })
          .margin({ left: 4, right: 4, top: 4 })
        // 屏幕方向：跟随系统 / 横屏 / 竖屏 —— 全屏观看的方向控制入口。
        // 光靠传感器自动旋转不够：躺卧观看时需要锁死横屏，否则机身一偏画面就转回竖屏。
        PlayerToolButton({
          icon: this.orientationIcon(),
          label: this.orientationLabel(),
          selected: this.orientation !== 'auto',
          onTap: () => {
            this.cycleOrientation();
          }
        })
          .margin({ left: 4, right: 4, top: 4 })
        // 播放中切换音频/字幕：播放页自己的覆盖层面板（不依赖详情页的 bindSheet）
        PlayerToolButton({
          icon: $r('sys.symbol.speaker_wave_2'),
          label: '音频/字幕',
          selected: this.showTrackSheet,
          onTap: () => {
            this.openTrackSheet();
          }
        })
          .margin({ left: 4, right: 4, top: 4 })
        PlayerToolButton({
          icon: $r('sys.symbol.video_speed'),
          label: `${this.playbackSpeed}x`,
          selected: this.playbackSpeed !== 1,
          onTap: () => {
            this.cycleSpeed();
          }
        })
          .margin({ left: 4, right: 4, top: 4 })
        // 画中画：退到桌面/切应用后继续看（系统小窗 + 系统播放控件）
        PlayerToolButton({
          icon: $r('sys.symbol.circle_grid_2x2'),
          label: this.pipActive ? '退出小窗' : '画中画',
          selected: this.pipActive,
          onTap: () => {
            this.togglePiP();
          }
        })
          .margin({ left: 4, right: 4, top: 4 })
        // 软解开关：硬解解不了的编码（如模拟器上的 HEVC）可切到 FFmpeg 软解回放
        PlayerToolButton({
          showIcon: false,
          label: '软解',
          selected: this.softPlaying,
          onTap: () => {
            if (this.softPlaying) {
              this.stopSoftPlay();
              this.setSoftNotice('已停止软解', false);
            } else {
              this.startSoftPlay();
            }
          }
        })
          .margin({ left: 4, right: 4, top: 4 })
      }
      .width('100%')
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 16, bottom: 24 })
    // 底部渐变遮罩：角度 180 表示"自上而下"，colors[0] 落在**顶部**，
    // 因此这里要把透明色放在 0、重色放在 1 —— 画面一侧透明、屏幕底边最重。
    // （此前 angle 是 0（自下而上）却把透明放在 0，等于把遮罩画反了：底部反而最亮。）
    .linearGradient({
      angle: 180,
      colors: [['#00000000', 0.0], [this.colors().scrimHeavy, 1.0]]
    })
  }

  /**
   * 右侧时间文案：总时长 / 剩余时长（点一下切换）。
   *
   * 为什么值得做：看电视剧时用户真正关心的是"还剩多久"，而总时长对进度条本身没有增量信息；
   * 主流播放器（含 Infuse）都提供这个切换。
   */
  private rightTimeLabel(): string {
    if (this.durationMs <= 0) {
      return '--:--';
    }
    if (this.showRemaining) {
      return `-${this.formatTime(Math.max(0, this.durationMs - this.positionMs))}`;
    }
    return this.formatTime(this.durationMs);
  }

  /**
   * 中央控制簇：快退 10 秒 / 播放暂停 / 快进 10 秒，居中悬浮在画面上。
   *
   * 为什么把播放主操作放画面正中（Infuse/iina/YouTube 全屏的形态）：
   * 1. 单手竖屏握持时，屏幕中部是最容易够到、最不容易误触的位置，
   *    而底部还要放进度条与工具行，主操作挤在底部既拥挤又容易点错；
   * 2. 主操作（播放/暂停）与次级开关（比例/字幕/倍速）在位置与体量上分开后，
   *    一眼就能分清"哪个是播放"。
   */
  @Builder
  CenterControls() {
    Row({ space: 30 }) {
      AppIconButton({
        icon: $r('sys.symbol.gobackward_10'),
        iconSize: 30,
        buttonSize: 60,
        backgroundOverride: this.colors().overlayControl,
        iconColorOverride: this.colors().onOverlay,
        onTap: () => {
          this.skipBy(-kSkipStepMs);
        }
      })
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph(this.isPlaying ? $r('sys.symbol.pause_fill') : $r('sys.symbol.play_fill'))
          .fontSize(34)
          .fontColor([this.colors().onBrand])
      }
      .width(76)
      .height(76)
      .backgroundColor(this.colors().brandPrimary)
      .shadow({
        radius: 16,
        color: this.colors().buttonShadow,
        offsetX: 0,
        offsetY: 6
      })
      .stateStyles({
        pressed: {
          .backgroundColor(this.colors().brandPrimaryPressed)
        }
      })
      .onClick(() => {
        this.onPlayPause();
      })
      AppIconButton({
        icon: $r('sys.symbol.goforward_10'),
        iconSize: 30,
        buttonSize: 60,
        backgroundOverride: this.colors().overlayControl,
        iconColorOverride: this.colors().onOverlay,
        onTap: () => {
          this.skipBy(kSkipStepMs);
        }
      })
    }
    .width('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 双击两侧的快进/快退反馈：半透明圆形涟漪 + `±10 秒`，600ms 渐隐。
   *
   * 为什么要有：双击是"盲操作"，如果没有即时反馈，用户无法确认这一下有没有生效
   * （尤其是快退时画面变化不明显）。
   */
  @Builder
  DoubleTapRipple() {
    // 左右各占一半：双击左侧的涟漪出现在左半屏中央，右侧同理
    Row() {
      Column() {
        if (this.rippleSide === 'backward') {
          this.RippleCircle(true)
        }
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)

      Column() {
        if (this.rippleSide === 'forward') {
          this.RippleCircle(false)
        }
      }
      .layoutWeight(1)
      .height('100%')
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
    }
    .width('100%')
    .height('100%')
    .hitTestBehavior(HitTestMode.None)
  }

  @Builder
  RippleCircle(backward: boolean) {
    Column({ space: 6 }) {
      SymbolGlyph(backward ? $r('sys.symbol.gobackward_10') : $r('sys.symbol.goforward_10'))
        .fontSize(30)
        .fontColor([this.colors().onOverlay])
      Text(backward ? '-10 秒' : '+10 秒')
        .fontSize(ThemeConstants.META_MEDIUM)
        .fontColor(this.colors().onOverlay)
    }
    .width(96)
    .height(96)
    .justifyContent(FlexAlign.Center)
    .backgroundColor(this.colors().overlayControlStrong)
    .border({ width: 1, color: this.colors().overlayControl, radius: 48 })
    .opacity(this.rippleOpacity)
    .scale({ x: this.rippleScale, y: this.rippleScale })
  }

  @Builder
  CompletedOverlay() {
    Column() {
      Text('播放结束')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().onOverlayMuted)
      Button({ type: ButtonType.Circle, stateEffect: false }) {
        SymbolGlyph($r('sys.symbol.arrow_2_circlepath'))
          .fontSize(ThemeConstants.ICON_XXL)
          .fontColor([this.colors().onBrand])
      }
        .width(72)
        .height(72)
        .backgroundColor(this.colors().brandPrimary)
        .shadow({
          radius: 12,
          color: this.colors().buttonShadow,
          offsetX: 0,
          offsetY: 4
        })
        .stateStyles({
          pressed: {
            .backgroundColor(this.colors().brandPrimaryPressed)
          }
        })
        .margin({ top: 8 })
        .onClick(() => {
          this.onPlayPause();
        })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }

  @Builder
  LockBadge() {
    // 锁定态**不再是整屏遮罩**（原来是 85% 不透明的黑幕 + 文案，点哪里都解锁）：
    // 需求是"锁模式单击可以显示锁，再次点击锁才可以取消锁定"，也就是
    // ① 锁定时画面应当干净（不挡画面、不挡进度）；
    // ② 单击只**显示**锁，只有点锁本身才解锁 —— 避免"想看看进度却把锁解掉了"。
    Column({ space: 10 }) {
      // 解锁按钮：锁图标 + 品牌色描边，让"下一步该点哪里"一目了然
      Column() {
        SymbolGlyph($r('sys.symbol.lock'))
          .fontSize(30)
          .fontColor([this.colors().onOverlay])
      }
      .width(72)
      .height(72)
      .justifyContent(FlexAlign.Center)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(this.colors().overlayControlStrong)
      .border({
        width: 1.5,
        color: this.colors().brandPrimary,
        radius: 36
      })
      .onClick(() => {
        this.unlockByUser();
      })

      Text('已锁定 · 点锁图标解锁')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().onOverlay)
        .backgroundColor(this.colors().overlayControlStrong)
        .padding({ left: 14, right: 14, top: 6, bottom: 6 })
        .borderRadius(ThemeConstants.BADGE_RADIUS)
    }
    // 只占内容大小、**不铺满整屏**：锁之外的位置不归它处理，落回视频区手势状态机
    // （`onSingleTap` 里"再点一下收起锁提示"）。此前铺满整屏并挂 onClick，
    // 会与手势状态机对同一次点击各处理一遍，效果互相抵消（实测：点别处锁提示不消失）。
    .alignItems(HorizontalAlign.Center)
    .justifyContent(FlexAlign.Center)
    .hitTestBehavior(HitTestMode.Transparent)
  }

  /**
   * 显示锁提示（锁定态单击触发），3.5 秒后自动收起。
   *
   * 为什么要自动收起：提示的目的是"告诉用户锁在哪、怎么解"，
   * 一直挂着又变成了遮挡画面的浮层 —— 与"锁定时画面干净"的诉求冲突。
   */
  private showLockBadge(): void {
    if (this.lockBadgeTimerId >= 0) {
      clearTimeout(this.lockBadgeTimerId);
      this.lockBadgeTimerId = -1;
    }
    this.lockBadgeVisible = true;
    this.lockBadgeTimerId = setTimeout(() => {
      this.lockBadgeTimerId = -1;
      this.lockBadgeVisible = false;
    }, kLockBadgeMs);
  }

  private hideLockBadge(): void {
    if (this.lockBadgeTimerId >= 0) {
      clearTimeout(this.lockBadgeTimerId);
      this.lockBadgeTimerId = -1;
    }
    this.lockBadgeVisible = false;
  }

  /**
   * 解锁：忽略"刚锁定后极短时间内的点击"。
   *
   * 为什么需要：锁定覆盖层是整屏的，点锁定按钮的同一次抬手事件会穿透到刚出现的覆盖层，
   * 导致"点了锁定立刻又被解锁"。
   */
  private unlockByUser(): void {
    if (Date.now() - this.lockChangedAt < 400) {
      return;
    }
    this.controlsLocked = false;
    this.lockChangedAt = Date.now();
    this.hideLockBadge();
    this.revealControls();
  }

  /** 手势/比例反馈图标 —— 用系统符号替代 emoji（⏩ ⏪ 🔆 🔊） */
  private gestureSymbol(): Resource {
    if (this.gestureIcon === 'seek') {
      return this.lastSeekForward ? $r('sys.symbol.chevron_right') : $r('sys.symbol.chevron_left');
    }
    if (this.gestureIcon === 'brightness') {
      return $r('sys.symbol.sun_max');
    }
    if (this.gestureIcon === 'aspect') {
      return $r('sys.symbol.aspectratio');
    }
    if (this.gestureIcon === 'orientation') {
      return this.orientationIcon();
    }
    return $r('sys.symbol.speaker_wave_2');
  }

  @Builder
  GestureFeedback() {
    // 横向 HUD：图标在左、数值与进度在右。
    // 原来是纵向堆叠且无形状边界，在明暗画面之间观感松散；改成胶囊状 HUD 更聚焦、
    // 也更符合主流播放器"手势反馈是瞬时浮层"的定位。
    Row({ space: 12 }) {
      SymbolGlyph(this.gestureSymbol())
        .fontSize(ThemeConstants.ICON_HERO)
        .fontColor([this.colors().onOverlay])
      Column({ space: 6 }) {
        Text(this.gestureFeedback)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().onOverlay)
        if (this.gestureRatio >= 0) {
          Progress({ value: this.gestureRatio * 100, total: 100, type: ProgressType.Linear })
            .width(140)
            .height(4)
            .color(this.colors().brandPrimary)
            .backgroundColor(this.colors().onOverlayMuted)
        }
      }
      .alignItems(HorizontalAlign.Start)
    }
    .padding({ left: 18, right: 20, top: 14, bottom: 14 })
    .backgroundColor(this.colors().overlayControlStrong)
    .borderRadius(28)
    .alignItems(VerticalAlign.Center)
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      // XComponent 始终存在：软解时 EGL 直接渲染到它的 surface（不再走 PixelMap 逐帧刷新）
      // 官方 XComponent 原生渲染用法：type=SURFACE + libraryname 指向原生模块，
      // ArkUI 会在 surface 就绪时回调 OH_NativeXComponent_Callback.OnSurfaceCreated(component, window)，
      // 原生侧据此直接拿到 framework 的 window 做 EGL/GLES 渲染（见 native/feature/player/xcomponent_bridge.h）。
      //
      // 尺寸由「视频比例」决定（见 common/PlayerAspect.ets）而不是永远铺满：
      // 系统 AVPlayer 默认的 FIT 是**拉伸铺满**，把 16:9 的片子铺到 20:9 的手机上画面会被拉长；
      // 把视频面的宽高比算成与画面一致后，视频面之外自然留出黑边，Centered 在 Stack 正中。
      XComponent({ id: 'jellyfin_player', type: XComponentType.SURFACE,
        libraryname: 'jellyfin_native', controller: this.surfaceController })
        .width(this.videoAreaWidth())
        .height(this.videoAreaHeight())
        .backgroundColor(this.colors().videoBackground)
        .onAreaChange((_oldArea: Area, newArea: Area) => {
          const density: number = display.getDefaultDisplaySync().densityPixels;
          this.surfaceWidthPx = Math.round(Number(newArea.width) * density);
          this.surfaceHeightPx = Math.round(Number(newArea.height) * density);
        })
        .onLoad(() => {
          // 关键：surfaceId 必须由 controller 取回；否则 AVPlayer 与软解 EGL 都拿不到视频面
          this.surfaceId = this.surfaceController.getXComponentSurfaceId();
          // 绑定必须走状态守卫：AVPlayer 在 idle 状态不接受 surfaceId（5400102）
          this.bindSurfaceIfReady();
          // surface 比 url 晚到：此刻播放器已到 initialized，补一次 prepare
          if (this.preparePendingSurface && this.avPlayer !== null
            && this.avPlayer.state === 'initialized') {
            this.preparePendingSurface = false;
            this.avPlayer.prepare();
          }
        })
      // 手势与"点击唤出控制条"的透明承载层。
      // 为什么需要它：官方 NativeXComponent 模式（XComponent 指定 libraryname）下，
      // ArkUI 会把该组件的输入交给原生侧（见 OH_NativeXComponent_Callback.DispatchTouchEvent），
      // 挂在 XComponent 自身上的 onTouch/onClick 不再触发。因此把原有手势逻辑原样挂到这一层，
      // 位置在视频面之上、控件之下，既不影响原生渲染，也保留全部交互。
      //
      // 注意：这里不再挂 onClick —— 单击/双击都统一在手势状态机里判定（见 onGestureUp），
      // 否则 onClick 与 onTouch 会各触发一次，"双击快进"必然顺手把控制条也切一次。
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor(Color.Transparent)
        .onTouch((event: TouchEvent) => {
          const touches: TouchObject[] = event.touches;
          if (touches.length !== 1) {
            return;
          }
          if (this.controlsLocked) {
            // 锁定态**只保留"单击"这一条路径**（显示/收起锁提示），其余手势一律忽略。
            //
            // 为什么不能直接 return（原实现如此）：那样锁定后画面收不到任何触摸，
            // 「单击显示锁」就永远不可能发生 —— 设备实测：锁定后单击，锁提示不出现，
            // 用户也就没有任何"点锁解锁"的入口（等于把自己锁死）。
            if (event.type === TouchType.Up) {
              this.handleLockedTap(touches[0].x);
            }
            return;
          }
          const touch: TouchObject = touches[0];
          // 两条输入通道（ArkUI 手势层 / 原生兜底轮询）共用同一套手势状态机
          if (event.type === TouchType.Down) {
            this.onGestureDown(touch.x, touch.y);
          } else if (event.type === TouchType.Move) {
            this.onGestureMove(touch.x, touch.y);
          } else if (event.type === TouchType.Up) {
            // 文件探针：手势结束时记录一次结果，便于设备验证直接确认"手势确实被识别"
            // （进度条/浮层这类瞬时 UI 无法用读屏稳定观察）

            this.onGestureUp(touch.x, touch.y);
          } else if (event.type === TouchType.Cancel) {
            // 手势被打断（来电、系统手势抢占）：同样要结束本次滑动，
            // 否则状态会卡在"拖拽中"，下一次按下被当成同一次滑动的延续。
            this.stopLongPressBoost();
            this.seekDragMs = 0;
            this.gestureAxis = '';
          }
        })

      // 亮度模拟遮罩：仅在平台不支持窗口亮度（setWindowBrightness 失败）时生效，
      // 保证左侧上下滑动"一定看得见效果"，而不是用户以为手势坏了。
      if (this.brightnessSimOpacity() > 0) {
        Column()
          .width('100%')
          .height('100%')
          .backgroundColor('#000000')
          .opacity(this.brightnessSimOpacity())
          .hitTestBehavior(HitTestMode.None)
      }

      // 手势反馈浮层
      if (this.showFeedback && this.gestureFeedback.length > 0) {
        this.GestureFeedback()
      }

      // 双击两侧的快进/快退反馈
      if (this.rippleSide.length > 0) {
        this.DoubleTapRipple()
      }

      // 字幕：外挂字幕由播放器推文本、应用绘制（原生 SURFACE 上画不了文本）
      // hitTestBehavior(None)：字幕只是显示，不能挡住手势层与控制条
      if (this.subtitleText.length > 0 && !this.controlsLocked) {
        Column() {
          Text(this.subtitleText)
            .fontSize(20)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .backgroundColor('#99000000')
            .padding({ left: 12, right: 12, top: 6, bottom: 6 })
            .borderRadius(6)
            .constraintSize({ maxWidth: '88%' })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.End)
        .alignItems(HorizontalAlign.Center)
        .padding({ bottom: 150 })
        .hitTestBehavior(HitTestMode.None)
      }

      // 播放结束覆盖层
      if (this.isCompleted() && !this.controlsLocked) {
        this.CompletedOverlay()
      }

      // 锁提示：**锁定后默认不显示**，单击画面才亮出来（见 onSingleTap / showLockBadge）。
      // 这里必须同时判 `lockBadgeVisible`：只判 `controlsLocked` 的话，锁一按下提示就挂在
      // 画面上了（设备实测踩到），与"锁模式单击可以显示锁"的诉求相反。
      if (this.controlsLocked && this.lockBadgeVisible) {
        this.LockBadge()
      }

      // 控制面板
      if (this.showControls && !this.controlsLocked) {
        Column() {
          this.TopBar()

          // 空白区（顶栏与中央控制簇之间）：点击即撤下控制面板
          this.ControlDismissArea()

          // 主操作居中（Infuse/iina 全屏的布局）：播放/暂停与 ±10s 在画面正中，
          // 顶部只放标题/返回，底部只放进度与工具开关，三者互不挤压
          this.CenterControls()

          this.ControlDismissArea()

          this.BottomControls()
        }
        .width('100%')
        .height('100%')
        // 控件层按安全区内缩：沉浸式全屏之后系统不再替我们避让，
        // 不内缩的话返回按钮会被状态栏/挖孔压住（视频层则保持铺满，这正是全屏的目的）。
        .padding({
          top: this.insets.top,
          bottom: this.insets.bottom,
          left: this.insets.left,
          right: this.insets.right
        })
      }

      // 音频/字幕面板：播放页自有的覆盖层（详情页那套 bindSheet 在播放页不可用）
      if (this.showTrackSheet && !this.controlsLocked) {
        Column() {
          Column({ space: 2 }) {
            Row() {
              Text('音频 / 字幕')
                .fontSize(ThemeConstants.TITLE_MEDIUM)
                .fontWeight(FontWeight.Medium)
                .fontColor(this.colors().textPrimary)
              Blank()
              Text('关闭')
                .fontSize(ThemeConstants.META_MEDIUM)
                .fontColor(this.colors().brandPrimary)
                .padding({ left: 12, right: 12, top: 8, bottom: 8 })
                .onClick(() => {
                  this.closeTrackSheet();
                })
            }
            .width('100%')
            .margin({ bottom: 4 })

            Scroll() {
              this.TrackSheet()
            }
            .width('100%')
            .constraintSize({ maxHeight: 560 })
            .scrollBar(BarState.Off)
          }
          .width('88%')
          .padding({ left: 16, right: 16, top: 14, bottom: 14 })
          .backgroundColor(this.colors().cardBackground)
          .borderRadius(ThemeConstants.CARD_RADIUS)
          .shadow({ radius: 16, color: this.colors().buttonShadow, offsetX: 0, offsetY: 6 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.colors().overlayControlStrong)
      }

      // 加载状态：不只是转圈，同时给出"在播什么"与"在做什么"，
      // 避免打开播放器时只看到一块空白黑背景（观感与信息量都更接近成熟播放器）。
      if (this.status === UiState.LOADING) {
        Column({ space: 4 }) {
          Text(this.title.length > 0 ? this.title : '正在准备播放')
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontWeight(FontWeight.Medium)
            .fontColor(this.colors().onOverlay)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
            .padding({ left: 32, right: 32 })
          if (this.typeLabel.length > 0) {
            Text(this.typeLabel)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onOverlayMuted)
          }
          LoadingProgress()
            .width(40)
            .height(40)
            .color(this.colors().brandPrimary)
            .margin({ top: 20 })
          Text(this.stateText.length > 0 ? `正在加载 · ${this.stateText}` : '正在加载…')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().onOverlayMuted)
            .margin({ top: 10 })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.colors().videoBackground)
      }

      if (this.status === UiState.ERROR) {
        Column({ space: 16 }) {
          // 错误态复用 EmptyState（参考项目约定：错误不另造组件，配"重试"动作）
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '播放出错',
            actionLabel: '重试',
            onAction: () => {
              this.stopped = false;
              this.openPlayer();
            }
          })
          // 硬解不支持该编码（如 HEVC）时，提供 FFmpeg 软解回放
          if (this.softStatus.length > 0) {
            Text(this.softStatus)
              .fontSize(ThemeConstants.META_MEDIUM)
              .fontColor(this.colors().onOverlayMuted)
              .textAlign(TextAlign.Center)
          }
          Button(this.softPlaying ? '停止软解' : '用 FFmpeg 软解播放',
            { type: ButtonType.Normal, stateEffect: false })
            .height(ThemeConstants.BUTTON_HEIGHT)
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().onBrand)
            .backgroundColor(this.colors().brandPrimary)
            .borderRadius(ThemeConstants.BUTTON_RADIUS)
            .stateStyles({
              pressed: {
                .backgroundColor(this.colors().brandPrimaryPressed)
              }
            })
            .onClick(() => {
              if (this.softPlaying) {
                this.stopSoftPlay();
              } else {
                this.startSoftPlay();
              }
            })
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
        .backgroundColor(this.colors().videoBackground)
      }

      // 软解提示：只在需要用户知情/操作时出现（正在打开、超时、失败、已自动切换软解）。
      //
      // 为什么不再常驻：原来的诊断行会把"第 N 帧 / 抓了多少 MB / EGL 是否已渲染 /
      // 锁定与控制条状态"永久压在画面上 —— 那是开发期的调试显示，不属于播放界面。
      // 现在普通提示会自动隐去，只有"已自动切换软解"这类需要用户知情的会保留。
      // 错误态自己已经在整屏覆盖层里展示文案，这里不重复。
      if (this.softStatus.length > 0 && this.status !== UiState.ERROR) {
        Text(this.softStatus)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onOverlay)
          .backgroundColor(this.colors().badgeScrim)
          .padding({ left: 12, right: 12, top: 6, bottom: 6 })
          .borderRadius(ThemeConstants.BADGE_RADIUS)
          .constraintSize({ maxWidth: '86%' })
          .textAlign(TextAlign.Center)
          .margin({ top: 72 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().videoBackground)
    // 播放区实测尺寸：按比例算视频面尺寸时用实测值而不是屏幕尺寸
    //（分屏/悬浮窗/系统栏占位时两者并不相等，用屏幕尺寸会把画面算大导致被裁）
    .onAreaChange((_oldArea: Area, newArea: Area) => {
      this.areaWidthVp = Number(newArea.width);
      this.areaHeightVp = Number(newArea.height);
      // 播放区尺寸变化即意味着旋转/分屏/系统栏显隐发生了变化：
      // 横竖屏判定与控件避让区都要跟着重算，否则横过来之后控件仍按竖屏内缩。
      this.landscape = this.areaWidth() > this.areaHeight();
      this.refreshInsets();
    })
  }
}
