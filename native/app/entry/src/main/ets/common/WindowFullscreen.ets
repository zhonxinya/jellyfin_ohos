import window from '@ohos.window';
import display from '@ohos.display';

/**
 * 窗口四周需要避让的安全区（vp，已从像素换算）。
 *
 * 为什么播放页要自己算：窗口一旦进入「沉浸式布局」（`setWindowLayoutFullScreen(true)`），
 * 系统就不再替应用避让，视频面可以铺满整屏（这正是全屏观看的目的），
 * 但**控件**也会跟着铺进去 —— 于是返回按钮会被状态栏/挖孔压住。
 * 所以视频层铺满、控件层按本结构内缩。
 */
export interface WindowInsets {
  top: number;
  bottom: number;
  left: number;
  right: number;
}

/** 播放页可选的屏幕方向：跟随传感器 / 强制横屏 / 强制竖屏 */
export type PlayerOrientation = 'auto' | 'landscape' | 'portrait';

/** 进入沉浸式全屏的结果（两个平台调用各自可能失败，必须分别如实反馈） */
export interface FullscreenResult {
  /** 系统状态栏与导航栏是否已隐藏 —— 这是"真全屏"的关键 */
  barsHidden: boolean;
  /** 窗口布局是否已铺满整屏（`setWindowLayoutFullScreen(true)` 是否成功） */
  layoutFullscreen: boolean;
}

/**
 * 播放页的「沉浸式全屏」窗口控制。
 *
 * 为什么单独成模块而不写在 PlayerPage 里：
 * 1. 窗口级副作用（系统栏显隐、沉浸式布局、屏幕方向）是**成对**的进入/退出操作，
 *    集中在一处才能保证"进来设置、出去还原"永远配对，不会出现某条退出路径漏还原；
 * 2. 避让区的像素→vp 换算、`visible` 判定、方向枚举取值都属平台细节，与播放器 UI 无关；
 * 3. 这是可被单独推演与验证的纯窗口层，不掺播放状态，避免与 AVPlayer/软解的状态机互相干扰。
 *
 * 平台事实（本机 SDK `@ohos.window.d.ts` 实测确认，本工程 compatibleSdkVersion 18）：
 * - `setWindowLayoutFullScreen(boolean): Promise<void>` —— Promise 重载 since 9（第 4564 行，未废弃）。
 *   语义是"主窗口布局是否沉浸式"。注意带 callback 的重载自 12 起已废弃，本文件只用 Promise 版。
 * - `setWindowSystemBarEnable(names: Array<'status'|'navigation'>): Promise<void>` —— since 9（第 4670 行）。
 *   **传空数组即隐藏状态栏与导航栏**；传 `['status','navigation']` 即还原。这是真全屏的开关。
 * - `setPreferredOrientation(Orientation): Promise<void>` —— since 9（第 4933 行）；
 *   官方注明对"不支持传感器旋转的设备、2in1 设备与子窗口"不生效，因此调用结果必须如实反馈给用户。
 * - `getPreferredOrientation(): Orientation` —— 同步（第 4988 行），用于保存/还原进入播放页前的方向设置。
 * - `getWindowAvoidArea(AvoidAreaType): AvoidArea` —— 同步（第 4414 行）；`AvoidArea.visible`
 *   表示该避让区当前是否真的显示在屏幕上，`visible=false` 时其 rect 不应计入（否则会平白留白）。
 * - `setWindowSystemBarProperties(SystemBarProperties): Promise<void>` —— since 9（第 4798 行，未废弃；
 *   带 callback 的 `setSystemBarProperties` 已废弃）。字段实测存在：`statusBarColor` / `isStatusBarLightIcon` /
 *   `statusBarContentColor` / `navigationBarColor` / `isNavigationBarLightIcon` / `navigationBarContentColor`。
 *   注意：**应用不设置时系统导航条的底色由系统决定**（浅色模式下是纯白），
 *   与应用的深色底形成一条突兀的白色横带 —— 见 `styleNavigationBarWith` 的说明。
 */
export class WindowFullscreen {
  /**
   * 进入沉浸式全屏：隐藏系统状态栏与导航栏 + 布局铺满整屏。
   *
   * 两个调用分开 try/catch：部分平台/窗口模式下只支持其中之一，
   * 若合并成一次失败就整段放弃，会出现"栏隐藏了但布局没铺满"时误判为完全失败。
   */
  static async enter(win: window.Window | null): Promise<FullscreenResult> {
    const result: FullscreenResult = { barsHidden: false, layoutFullscreen: false };
    if (win === null) {
      return result;
    }
    try {
      await win.setWindowSystemBarEnable([]);
      result.barsHidden = true;
    } catch (_e) {
      result.barsHidden = false;
    }
    try {
      await win.setWindowLayoutFullScreen(true);
      result.layoutFullscreen = true;
    } catch (_e) {
      result.layoutFullscreen = false;
    }
    return result;
  }

  /**
   * 进入「保留状态栏」的全屏：**只显示系统状态栏**（导航栏仍隐藏）+ 布局铺满整屏。
   *
   * 为什么「视频」页用这一档（用户口径："短视频顶部避免侵占系统空间"）：
   * 全沉浸时应用连窗口安全区一起铺，页面顶部是浮层工具行，它就压在系统状态栏区域里 ——
   * 模拟器实测：系统状态栏窗口 rect = `[0,0,1260,131]`（顶部 131px = 38.8vp），
   * 而工具行从屏幕 y=33px 起、标题「短视频」在 y=33..96px，整条都在里面。
   * 保留状态栏后平台把顶部 131px 让给系统，画面与控件都从状态栏下方开始。
   *
   * 导航栏仍然隐藏：底部页签行照旧贴屏幕最底边，PR #54/#56 的结论不受影响
   * （那条结论只与"窗口内容框底部有没有被系统栏内缩"有关）。
   */
  static async enterWithStatusBar(win: window.Window | null): Promise<FullscreenResult> {
    const result: FullscreenResult = { barsHidden: false, layoutFullscreen: false };
    if (win === null) {
      return result;
    }
    try {
      // 只留状态栏：导航栏继续隐藏，底部页签行才不会被系统栏顶上来
      await win.setWindowSystemBarEnable(['status']);
      result.barsHidden = true;
    } catch (_e) {
      result.barsHidden = false;
    }
    try {
      await win.setWindowLayoutFullScreen(true);
      result.layoutFullscreen = true;
    } catch (_e) {
      result.layoutFullscreen = false;
    }
    return result;
  }

  /**
   * 退出沉浸式全屏：还原系统状态栏与导航栏，并取消沉浸式布局。
   *
   * 不向上抛异常：退出路径上还要释放播放器与软解会话，
   * 不能因为"还原系统栏"这一步在某个机型上失败就中断后续资源释放。
   *
   * `navigationBarColor` 传应用底部页签行的底色：系统栏还原后必须**同时**是应用的颜色，
   * 否则退出沉浸式就会露出系统默认底色（浅色模式下为纯白），底部又多出一条白带。
   */
  static async exit(win: window.Window | null, navigationBarColor?: string): Promise<void> {
    if (win === null) {
      return;
    }
    try {
      await win.setWindowSystemBarEnable(['status', 'navigation']);
    } catch (_e) {
      // 还原系统栏失败：系统在应用退到后台时会自行恢复，不阻塞其它退出动作
    }
    try {
      await win.setWindowLayoutFullScreen(false);
    } catch (_e) {
      // 同上
    }
    // 系统栏底色与图标明暗必须跟着应用走（不传颜色时也用系统深色兜底，避免出现白带）
    await WindowFullscreen.styleNavigationBarWith(win, navigationBarColor);
  }

  /**
   * 让系统底部导航条与应用的底部页签行看起来是同一块底。
   *
   * 排查结论（模拟器 127.0.0.1:5555 实测，两条证据）：
   * 1. `setWindowSystemBarProperties({navigationBarColor})` **调用成功且属性真的被写入**
   *    （`getWindowSystemBarProperties()` 回读为设置值），但系统那条 94px 的
   *    `SCBGestureNavBar` 仍然照原色绘制 —— 说明该窗口模式下系统导航条的底色不接受应用指定；
   * 2. 系统导航条自带的底色本来就是 `#00FFFFFF`（全透明），应用窗口也确实是整屏
   *    （`WindowManagerService` 里 `WindowRect = [0,0,1260,2844]`），
   *    那一条之所以是白的，是因为**应用没有往窗口安全区以外的底部区域画东西**，
   *    露出的正是系统底（浅色模式下为纯白）。
   *
   * 因此正确的修法是让应用自己把底色铺到屏幕底边（`MainShell.build` 里对外壳根容器
   * `expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])` + 页签行同色底），
   * 而不是去改系统栏颜色。本方法只作为兜底：在系统导航条**不透明**的机型/窗口模式下，
   * 至少让它的颜色跟着应用走，避免底部再出现一条异色横带。
   *
   * 失败不抛：部分窗口模式/机型不支持改系统栏属性，此时保持系统默认（不做静默假设，只是不阻塞调用方）。
   */
  static async styleNavigationBarWith(win: window.Window | null, color?: string): Promise<void> {
    if (win === null) {
      return;
    }
    const barColor: string = (color !== undefined && color.length > 0) ? color : '#1C1F24';
    try {
      await win.setWindowSystemBarProperties({
        navigationBarColor: barColor,
        navigationBarContentColor: '#E8EAED',
        isNavigationBarLightIcon: true
      });
    } catch (_e) {
      // 当前窗口模式不支持改系统栏属性：保持系统默认底色
    }
  }

  /** 把播放页的方向选择映射为平台枚举 */
  static orientationValue(orientation: PlayerOrientation): window.Orientation {
    if (orientation === 'landscape') {
      return window.Orientation.LANDSCAPE;
    }
    if (orientation === 'portrait') {
      return window.Orientation.PORTRAIT;
    }
    // auto：跟随传感器且**忽略系统方向锁** —— 播放器旋转到横屏是用户在看视频时的明确意图，
    // 与主流播放器（横屏全屏）一致。AUTO_ROTATION_RESTRICTED 会受系统方向锁限制，故不用它。
    return window.Orientation.AUTO_ROTATION;
  }

  /** 设置窗口首选方向；返回是否成功（平台不支持旋转时会拒绝） */
  static async setOrientation(win: window.Window | null, orientation: PlayerOrientation): Promise<boolean> {
    if (win === null) {
      return false;
    }
    try {
      await win.setPreferredOrientation(WindowFullscreen.orientationValue(orientation));
      return true;
    } catch (_e) {
      return false;
    }
  }

  /** 读取当前窗口首选方向（退出播放页时还原用）；失败返回 -1 */
  static currentOrientation(win: window.Window | null): number {
    if (win === null) {
      return -1;
    }
    try {
      return win.getPreferredOrientation() as number;
    } catch (_e) {
      return -1;
    }
  }

  /** 还原到进入播放页之前记录的方向值；`value < 0` 表示当时没读到，不做还原 */
  static async restoreOrientation(win: window.Window | null, value: number): Promise<void> {
    if (win === null || value < 0) {
      return;
    }
    try {
      await win.setPreferredOrientation(value as window.Orientation);
    } catch (_e) {
      // 还原失败不阻塞退出流程
    }
  }

  /**
   * 计算需要避让的安全区（vp）：挖孔 + （可选）系统栏与导航条。
   *
   * @param includeSystemBars 系统栏当前是否可见。我们已经把系统栏隐藏掉时传 false ——
   *        因为部分实现在隐藏后仍会把系统栏区域报成 `visible=true`，
   *        那一份高度如果计进来，画面上就会平白多出一条空白带（用户会当成布局 bug）。
   *        隐藏失败（`barsHidden=false`）时传 true，此时必须老老实实避让。
   */
  static insets(win: window.Window | null, includeSystemBars: boolean): WindowInsets {
    const zero: WindowInsets = { top: 0, bottom: 0, left: 0, right: 0 };
    if (win === null) {
      return zero;
    }
    const density: number = WindowFullscreen.density();
    let top: number = 0;
    let bottom: number = 0;
    let left: number = 0;
    let right: number = 0;

    // 挖孔（刘海/胶囊）永远要避让：它就在屏幕里，不会因为我们隐藏系统栏而消失。
    // 横屏时它出现在侧边，所以四个方向都要取。
    const cutout: window.AvoidArea | null =
      WindowFullscreen.avoidArea(win, window.AvoidAreaType.TYPE_CUTOUT);
    if (cutout !== null && cutout.visible) {
      top = Math.max(top, cutout.topRect.height);
      bottom = Math.max(bottom, cutout.bottomRect.height);
      left = Math.max(left, cutout.leftRect.width);
      right = Math.max(right, cutout.rightRect.width);
    }

    if (includeSystemBars) {
      const barTypes: number[] = [window.AvoidAreaType.TYPE_SYSTEM,
                                  window.AvoidAreaType.TYPE_NAVIGATION_INDICATOR];
      for (let i: number = 0; i < barTypes.length; i++) {
        const area: window.AvoidArea | null = WindowFullscreen.avoidArea(win, barTypes[i]);
        if (area === null || !area.visible) {
          continue;
        }
        top = Math.max(top, area.topRect.height);
        bottom = Math.max(bottom, area.bottomRect.height);
        left = Math.max(left, area.leftRect.width);
        right = Math.max(right, area.rightRect.width);
      }
    }

    return {
      top: Math.max(0, Math.round(top / density)),
      bottom: Math.max(0, Math.round(bottom / density)),
      left: Math.max(0, Math.round(left / density)),
      right: Math.max(0, Math.round(right / density))
    };
  }

  /**
   * 系统状态栏自身的高度（vp）；不可用或当前不显示时返回 0。
   *
   * 用途：「视频」页**保留状态栏**时，平台已经把这条高度让给系统了，
   * 页面自己不必再为挖孔内缩（挖孔就落在状态栏里）—— 除去这一份，否则会重复避让。
   */
  static statusBarTopVp(win: window.Window | null): number {
    if (win === null) {
      return 0;
    }
    const area: window.AvoidArea | null =
      WindowFullscreen.avoidArea(win, window.AvoidAreaType.TYPE_SYSTEM);
    if (area === null || !area.visible) {
      return 0;
    }
    return Math.max(0, Math.round(area.topRect.height / WindowFullscreen.density()));
  }

  /** 读取单个避让区；失败返回 null（该类型在当前窗口上不可用时不能影响其它类型的计算） */
  private static avoidArea(win: window.Window, type: number): window.AvoidArea | null {
    try {
      return win.getWindowAvoidArea(type as window.AvoidAreaType);
    } catch (_e) {
      return null;
    }
  }

  /** 屏幕像素密度（px/vp）；避让区给的是 px，控件布局用 vp */
  private static density(): number {
    try {
      const d: number = display.getDefaultDisplaySync().densityPixels;
      return d > 0 ? d : 1;
    } catch (_e) {
      return 1;
    }
  }
}
