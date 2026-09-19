import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { SessionStore } from '../services/SessionStore';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { PageHeader } from '../components/PageHeader';
import { SettingCell } from '../components/SettingCell';
import { JsonUtil } from '../common/JsonUtil';
import { SessionUtil } from '../services/SessionUtil';
import { ShortVideoPrefs } from '../common/ShortVideoPrefs';

interface SettingsItem {
  /** 系统符号名，映射见 iconResource()；info 行忽略 */
  icon: string;
  title: string;
  subtitle: string;
  /** info=true 时渲染为无图标、值右对齐的 InfoTile（对应 Flutter _InfoTile） */
  info?: boolean;
  route?: string;
  action?: string;
  titleParam?: string;
  pathParam?: string;
}

interface PlayerOption {
  value: string;
  label: string;
  description: string;
}

const PLAYER_OPTIONS: PlayerOption[] = [
  { value: 'native', label: '\u539f\u751f\u64ad\u653e\u5668', description: '\u539f\u751f ArkTS \u64ad\u653e\u5668\uff08XComponent \u786c\u89e3\uff09' },
  { value: 'external', label: '\u5916\u90e8\u64ad\u653e\u5668', description: '\u8c03\u8d77\u7cfb\u7edf\u5916\u90e8\u64ad\u653e\u5668\u6253\u5f00' }
];

/** 持久化偏好并落盘 session（session JSON 携带 preferences） */
function persistPreference(key: string, value: string): void {
  JellyfinNative.setPreference(key, JSON.stringify(value));
  SessionStore.saveSession(JellyfinNative.getSession());
}


@Component
export struct SettingsPage {
  @State private themeMode: string = 'dark';
  @State private accent: string = 'ocean';
  @State private message: string = '';
  @State private status: string = UiState.INITIAL;
  @State private serverVersion: string = '';
  /** 服务器名称与地址：来自活跃会话（权威来源），避免显示陈旧的持久化值 */
  @State private serverName: string = '';
  @State private serverAddress: string = '';
  @State private showLogoutConfirm: boolean = false;
  @State private showChangeServerConfirm: boolean = false;
  @State private showClearDataConfirm: boolean = false;
  @State private showPlayerPicker: boolean = false;
  @State private defaultPlayer: string = 'native';
  // 服务器用户配置开关
  @State private hidePlayedInLatest: boolean = false;
  @State private enableNextEpisodeAutoPlay: boolean = false;
  @State private rememberAudioSelections: boolean = false;
  @State private displayMissingEpisodes: boolean = false;
  /** 服务端当前值（`loadUserConfig` 里填）：用来跳过与服务器相同的写入 */
  private serverValues: Record<string, Object> = {};

  @Link themeTick: number;
  @Prop embedded: boolean = false;

  async aboutToAppear(): Promise<void> {
    const vm: AppViewModel = AppViewModel.getInstance();
    this.themeMode = vm.themeMode;
    this.accent = vm.accent;
    const sysRaw: string = await JellyfinNative.adminGetSystemInfo();
    const sys: NativeResult = JellyfinNative.parseResult(sysRaw);
    if (sys.ok && sys.data !== null) {
      this.serverVersion = JsonUtil.getString(sys.data, 'Version', '');
      // 服务器名称取自服务端信息（会话里的 serverName 可能为空，此前该行错误地显示成地址）
      const nameFromServer: string = JsonUtil.getString(sys.data, 'ServerName', '');
      if (nameFromServer.length > 0) {
        this.serverName = nameFromServer;
      }
    }
    // 会话中的 baseUrl / serverName 是权威值（API 客户端实际使用）
    const sessionRaw: string = SessionUtil.exportSessionJson();
    const sessionObj: ESObject | null = JsonUtil.parseObject(sessionRaw);
    if (sessionObj !== null) {
      this.serverAddress = JsonUtil.getString(sessionObj, 'baseUrl', '');
      this.serverName = JsonUtil.getString(sessionObj, 'serverName', '');
    }
    const prefsRaw: string = JellyfinNative.getPreferences();
    const prefs: NativeResult = JellyfinNative.parseResult(prefsRaw);
    if (prefs.ok && prefs.data !== null) {
      this.defaultPlayer = JsonUtil.getString(prefs.data as ESObject, 'defaultPlayer', 'native');
    }
    this.loadUserConfig();
  }

  /** 读取当前用户服务器配置（含所有开关字段） */
  private async loadUserConfig(): Promise<void> {
    const raw: string = await JellyfinNative.getUserById(this.getUserId());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      return;
    }
    const cfg: ESObject | null = JsonUtil.getObject(result.data, 'Configuration');
    if (cfg === null) {
      return;
    }
    // 记下"服务端当前值"：用来跳过与服务器相同的写入（见 saveUserField）
    const values: Record<string, Object> = {};
    values['HidePlayedInLatest'] = JsonUtil.getBoolean(cfg, 'HidePlayedInLatest', false);
    values['EnableNextEpisodeAutoPlay'] = JsonUtil.getBoolean(cfg, 'EnableNextEpisodeAutoPlay', false);
    values['RememberAudioSelections'] = JsonUtil.getBoolean(cfg, 'RememberAudioSelections', false);
    values['DisplayMissingEpisodes'] = JsonUtil.getBoolean(cfg, 'DisplayMissingEpisodes', false);
    this.serverValues = values;

    this.hidePlayedInLatest = values['HidePlayedInLatest'] as boolean;
    this.enableNextEpisodeAutoPlay = values['EnableNextEpisodeAutoPlay'] as boolean;
    this.rememberAudioSelections = values['RememberAudioSelections'] as boolean;
    this.displayMissingEpisodes = values['DisplayMissingEpisodes'] as boolean;
  }

  private getUserId(): string {
    const raw: string = JellyfinNative.getSession();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok && result.data !== null) {
      return JsonUtil.getString(result.data as ESObject, 'userId',
        JsonUtil.getString(result.data as ESObject, 'UserId', ''));
    }
    return '';
  }

  /**
   * 保存单个用户配置字段。
   *
   * 传增量对象即可：原生侧负责 GET 当前配置、合并、整体提交。
   * （旧实现直接把 `{field: value}` 当完整配置 POST 到 `/Users/Configuration?userId=`，
   * 那个路由在 10.8.12 上不存在 —— userId 被当成字面量 "Configuration"，服务端直接 400，
   * 所以这些开关以前根本没能保存到服务器。）
   *
   * 两个"别白写请求"的细节：
   * - 值与服务端当前值相同就直接返回 —— `Toggle` 在**创建时**就会用它拿到的值回调一次
   *   （实测每次进设置页都会给两个"开着"的开关各触发一次 `onChange`），
   *   那不是用户操作，照发就是每次进页面白写几个 PATCH（每个还是 GET+POST）；
   * - 保存成功后把"已知的服务端值"更新掉，避免同一次会话里重复提交同一个值。
   */
  private async saveUserField(field: string, value: boolean | string | number): Promise<void> {
    const known: Object | undefined = this.serverValues[field];
    if (known !== undefined && `${known}` === `${value}`) {
      // 与服务器相同：不发请求（开关在创建时回调一次，那不是用户操作）
      return;
    }
    const patch: Record<string, Object> = {};
    patch[field] = value;
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.patchUserConfiguration(JSON.stringify(patch)));
    if (!result.ok) {
      if (result.message.length > 0) {
        this.message = result.message;
      }
      // 失败时不更新已知值，用户再点一次仍会发请求
      return;
    }
    this.serverValues[field] = value;
  }

  private colors(): ThemeColors {
    this.themeTick;
    return AppViewModel.getInstance().colors();
  }

  private themeSubtitle(): string {
    const modeLabel: string =
      this.themeMode === 'light' ? '\u6d45\u8272' : (this.themeMode === 'dark' ? '\u6df1\u8272' : '\u8ddf\u968f\u7cfb\u7edf');
    const accentLabel: string =
      this.accent === 'jade' ? '\u7fe1\u7fe0\u7eff'
        : (this.accent === 'amber' ? '\u7425\u73c0' : (this.accent === 'coral' ? '\u73ca\u7469' : '\u6d77\u6d0b\u84dd'));
    return `${modeLabel} \u00b7 ${accentLabel}`;
  }

  private playerLabel(): string {
    for (let i = 0; i < PLAYER_OPTIONS.length; i++) {
      if (PLAYER_OPTIONS[i].value === this.defaultPlayer) {
        return PLAYER_OPTIONS[i].label;
      }
    }
    return '\u539f\u751f\u64ad\u653e\u5668';
  }

  /**
   * 「短视频模式」这一行的副标题：直接说清"当前选了几个库"。
   *
   * 为什么读偏好而不是用 @State：这一行只是入口，勾选发生在子页里、返回时本页不会重建；
   * 每次渲染都从偏好现读（本地读，无网络）才能保证返回后看到的数字是新的。
   */
  private shortVideoSubtitle(): string {
    const count: number = ShortVideoPrefs.loadLibraryIds().length;
    if (count === 0) {
      return '选择进入短视频模式的媒体库（当前未设置）';
    }
    return `已选 ${count} 个媒体库，「视频」页按随机顺序连播`;
  }

  private selectDefaultPlayer(value: string): void {
    this.defaultPlayer = value;
    persistPreference('defaultPlayer', value);
    this.showPlayerPicker = false;
    this.message = `\u9ed8\u8ba4\u64ad\u653e\u5668\u5df2\u8bbe\u7f6e\u4e3a${this.playerLabel()}`;
  }

  private async onLogout(): Promise<void> {
    this.showLogoutConfirm = false;
    this.status = UiState.LOADING;
    JellyfinNative.logout();
    await SessionStore.clearSession();
    AppViewModel.getInstance().resetAuth();
    this.status = UiState.SUCCESS;
    router.replaceUrl({ url: 'pages/LoginPage' });
  }

  private async onChangeServer(): Promise<void> {
    this.showChangeServerConfirm = false;
    JellyfinNative.logout();
    await SessionStore.clearSession();
    AppViewModel.getInstance().resetAuth();
    router.replaceUrl({ url: 'pages/ServerPage' });
  }

  /** emoji 输入 → 系统符号资源；全部名称已在本机 SDK sysResource 核验 */
  private iconResource(name: string): Resource {
    if (name === 'externaldrive') {
      return $r('sys.symbol.externaldrive');
    }
    if (name === 'clock') {
      return $r('sys.symbol.clock');
    }
    if (name === 'folder') {
      return $r('sys.symbol.folder');
    }
    if (name === 'display') {
      return $r('sys.symbol.display');
    }
    if (name === 'timer') {
      return $r('sys.symbol.timer');
    }
    if (name === 'paintpalette') {
      return $r('sys.symbol.paintpalette');
    }
    if (name === 'person_2') {
      return $r('sys.symbol.person_2');
    }
    if (name === 'play_circle') {
      return $r('sys.symbol.play_circle');
    }
    if (name === 'gearshape') {
      return $r('sys.symbol.gearshape');
    }
    if (name === 'wifi') {
      return $r('sys.symbol.wifi');
    }
    if (name === 'puzzle') {
      return $r('sys.symbol.puzzle');
    }
    if (name === 'key') {
      return $r('sys.symbol.key');
    }
    if (name === 'doc_text') {
      return $r('sys.symbol.doc_text');
    }
    if (name === 'message') {
      return $r('sys.symbol.message');
    }
    if (name === 'gamecontroller') {
      return $r('sys.symbol.gamecontroller');
    }
    if (name === 'video') {
      return $r('sys.symbol.video');
    }
    if (name === 'info_circle') {
      return $r('sys.symbol.info_circle');
    }
    if (name === 'list_bullet') {
      return $r('sys.symbol.list_bullet');
    }
    if (name === 'speaker_wave_2') {
      return $r('sys.symbol.speaker_wave_2');
    }
    if (name === 'rectangle_stack') {
      return $r('sys.symbol.rectangle_stack');
    }
    return $r('sys.symbol.square_grid_2x2');
  }

  /** M3 AlertDialog 语义：标题 + 正文 + 右对齐动作（取消文本按钮 / 确认实心按钮） */
  @Builder
  ConfirmDialog(title: string, body: string, confirmLabel: string,
    onConfirm: () => void, onCancel: () => void) {
    Column() {
      Column({ space: 16 }) {
        Text(title)
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .width('100%')
        Text(body)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textSecondary)
          .width('100%')
        Row({ space: 8 }) {
          Blank()
          Button(cancelLabel())
            .height(40)
            .padding({ left: 12, right: 12 })
            .backgroundColor(Color.Transparent)
            .fontColor(this.colors().brandPrimary)
            .onClick(() => {
              onCancel();
            })
          Button(confirmLabel)
            .height(40)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.colors().brandPrimary)
            .fontColor(this.colors().onBrand)
            .onClick(() => {
              onConfirm();
            })
        }
        .width('100%')
      }
      .padding(24)
      .backgroundColor(this.colors().cardBackground)
      .borderRadius(28)
      .width('80%')
      .onClick(() => {
        // 阻断点击冒泡到遮罩层，避免误关闭
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors().scrim)
    .onClick(() => {
      onCancel();
    })
  }

  /** M3 SimpleDialog 语义：标题 + 单选列表（radio 圆点 + 名称 + 描述） */
  @Builder
  PlayerPickerDialog(onCancel: () => void) {
    Column() {
      Column({ space: 12 }) {
        Text('\u9009\u62e9\u9ed8\u8ba4\u64ad\u653e\u5668')
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .width('100%')
        ForEach(PLAYER_OPTIONS, (player: PlayerOption) => {
          Row({ space: 16 }) {
            Stack({ alignContent: Alignment.Center }) {
              Circle()
                .width(20)
                .height(20)
                .fill(Color.Transparent)
                .stroke(this.defaultPlayer === player.value ? this.colors().brandPrimary : this.colors().textSecondary)
                .strokeWidth(2)
              if (this.defaultPlayer === player.value) {
                Circle()
                  .width(10)
                  .height(10)
                  .fill(this.colors().brandPrimary)
              }
            }
            .width(40)
            .height(40)
            Column({ space: 2 }) {
              Text(player.label)
                .fontSize(ThemeConstants.BODY_MEDIUM)
                .fontColor(this.colors().textPrimary)
              Text(player.description)
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().textSecondary)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
          }
          .width('100%')
          .padding({ top: 4, bottom: 4 })
          .onClick(() => {
            this.selectDefaultPlayer(player.value);
          })
        }, (player: PlayerOption) => player.value)
      }
      .padding(24)
      .backgroundColor(this.colors().cardBackground)
      .borderRadius(28)
      .width('80%')
      .onClick(() => {
        // 阻断点击冒泡到遮罩层
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors().scrim)
    .onClick(() => {
      onCancel();
    })
  }

  /** Flutter 用户信息卡：52 圆头像 + 22 Medium 首字母 + 16 名称 + 12 副标题 */
  @Builder
  UserCard() {
    Row({ space: 12 }) {
      Stack({ alignContent: Alignment.Center }) {
        Circle()
          .width(52)
          .height(52)
          .fill(this.colors().surfacePressed)
        Text(AppViewModel.getInstance().userName.length > 0 ?
          AppViewModel.getInstance().userName.substring(0, 1).toUpperCase() : '?')
          .fontSize(ThemeConstants.TITLE_XLARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
      }
      Column({ space: 4 }) {
        Text(AppViewModel.getInstance().userName.length > 0 ?
          AppViewModel.getInstance().userName : '\u672a\u767b\u5f55')
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(AppViewModel.getInstance().serverUrl.length > 0 ?
          AppViewModel.getInstance().serverUrl + (AppViewModel.getInstance().isAdmin ? ' \u00b7 \u7ba1\u7406\u5458' : '')
          : '\u672a\u77e5\u670d\u52a1\u5668')
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .margin({ top: 16, bottom: 8 })
    .alignItems(VerticalAlign.Center)
  }

  /**
   * 设置行（菜单型）—— 对齐 mybooks_ohos 的 `SettingCell`：
   * 标题 16fp `text_primary`、副标题 12fp `text_secondary`、尾部 chevron 16fp `text_tertiary`、
   * 四边 16vp 内边距、按下态 `surface_pressed`。
   */
  @Builder
  MenuTile(icon: string, title: string, subtitle: string, onTap: () => void) {
    Row({ space: 12 }) {
      SymbolGlyph(this.iconResource(icon))
        .fontSize(ThemeConstants.TITLE_LARGE)
        .fontColor([this.colors().brandPrimary])
        .width(28)
      Column({ space: 4 }) {
        Text(title)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
        if (subtitle.length > 0) {
          Text(subtitle)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor([this.colors().textTertiary])
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
    .stateStyles({
      pressed: {
        .backgroundColor(this.colors().surfacePressed)
      }
    })
    .onClick(() => {
      onTap();
    })
  }

  /** 信息行 —— 对齐参考项目 `SettingCell` 的 valueText 分支（label 16fp 主色、值 14fp 次级） */
  @Builder
  InfoTile(label: string, value: string) {
    Row() {
      Text(label)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .layoutWeight(1)
      Text(value)
        .fontSize(ThemeConstants.BODY_MEDIUM)
        .fontColor(this.colors().textSecondary)
        .maxLines(1)
        .textOverflow({ overflow: TextOverflow.Ellipsis })
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  /** 清除全部本地数据并回到服务器配置页（上架合规入口） */
  private async clearLocalData(): Promise<void> {
    this.showClearDataConfirm = false;
    await SessionStore.clearAll();
    // 同时清掉内存中的会话与服务器地址，避免刚清除后界面仍显示上一次的配置
    AppViewModel.getInstance().resetAuth();
    AppViewModel.getInstance().setServer('');
    router.replaceUrl({ url: 'pages/ServerPage' });
  }

  private serverNameText(): string {
    // 优先用 configureServer 返回的权威名称，其次会话 JSON，最后才回落到地址
    const fromVm: string = AppViewModel.getInstance().serverName;
    if (fromVm.length > 0) {
      return fromVm;
    }
    if (this.serverName.length > 0) {
      return this.serverName;
    }
    return AppViewModel.getInstance().serverUrl.length > 0 ? AppViewModel.getInstance().serverUrl : '未知';
  }

  private serverAddressText(): string {
    if (this.serverAddress.length > 0) {
      return this.serverAddress;
    }
    return AppViewModel.getInstance().serverUrl.length > 0 ? AppViewModel.getInstance().serverUrl : '未配置';
  }

  private onSectionItemTap(child: SettingsItem): void {
    const route: string = child.route === undefined ? '' : child.route;
    const action: string = child.action === undefined ? '' : child.action;
    if (action === 'logout') {
      this.showLogoutConfirm = true;
    } else if (action === 'changeServer') {
      this.showChangeServerConfirm = true;
    } else if (action === 'defaultPlayer') {
      this.showPlayerPicker = true;
    } else if (action === 'clearLocalData') {
      this.showClearDataConfirm = true;
    } else if (route.length > 0) {
      const titleParam: string = child.titleParam === undefined ? '' : child.titleParam;
      const pathParam: string = child.pathParam === undefined ? '' : child.pathParam;
      if (titleParam.length > 0 || pathParam.length > 0) {
        router.pushUrl({
          url: route,
          params: { title: titleParam, path: pathParam }
        });
      } else {
        router.pushUrl({ url: route });
      }
    } else {
      this.message = '\u8be5\u8bbe\u7f6e\u5c06\u5728\u540e\u7eed\u7248\u672c\u63d0\u4f9b';
    }
  }

  /**
   * 设置分组卡片 —— 对齐参考项目：头部「图标 + 标题 16fp Medium」，
   * 组内行为 `SettingCell` 风格、条目间一律 **0.5vp `divider`**（参考项目全站只有这一种分隔线）。
   */
  @Builder
  SectionCard(title: string, icon: string, children: SettingsItem[]) {
    Column() {
      Row({ space: 8 }) {
        SymbolGlyph(this.iconResource(icon))
          .fontSize(ThemeConstants.ICON_MEDIUM)
          .fontColor([this.colors().brandPrimary])
        Text(title)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .layoutWeight(1)
      }
      .width('100%')
      .padding({
        left: ThemeConstants.PAGE_PADDING,
        right: ThemeConstants.PAGE_PADDING,
        top: 14,
        bottom: 10
      })
      ForEach(children, (child: SettingsItem, index: number) => {
        if (index > 0) {
          Divider()
            .color(this.colors().divider)
            .strokeWidth(0.5)
        }
        if (child.info === true) {
          this.InfoTile(child.title, child.subtitle)
        } else {
          this.MenuTile(child.icon, child.title, child.subtitle, () => {
            this.onSectionItemTap(child);
          })
        }
      }, (_child: SettingsItem, index: number) => `${title}_${index}`)
    }
    .width('100%')
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(ThemeConstants.CARD_RADIUS)
    .clip(true)
    .margin({
      left: ThemeConstants.PAGE_PADDING,
      right: ThemeConstants.PAGE_PADDING,
      bottom: ThemeConstants.CARD_STACK_SPACE
    })
  }

  /**
   * 开关行**不再**用 `@Builder` 包一层，直接在 `build()` 里用 `SettingCell`（`@Component`）。
   *
   * 原因：`@Builder` 的按值参数不会随状态刷新。用户点开关 → 状态改掉 → 页面重建时
   * 组件又被塞回**旧值**，开关被"弹回去"，并且还会再回调一次旧值 ——
   * 设备实测点「自动播放下一集」（原本开）时回调拿到 `true`，于是又把 `true` 写回服务器，
   * 表现就是"点了没反应"（probe 日志：`saveUserField EnableNextEpisodeAutoPlay=true`）。
   * 其它设置页（网络 / 转码 / 品牌 / 音频…）一直是直接放 `SettingCell`，都是好的。
   */

  build() {
    Stack() {
      Scroll() {
        Column() {
          if (!this.embedded) {
            PageHeader({
              title: $r('app.string.settings_title'),
              onBack: () => {
                router.back();
              }
            })
          } else {
            // M3 AppBar 语义：56 高，titleLarge(22) 左对齐
            Text($r('app.string.settings_title'))
              .fontSize(ThemeConstants.TITLE_XLARGE)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().textPrimary)
              .width('100%')
              .height(56)
              .padding({ left: 16, right: 16 })
              .backgroundColor(this.colors().cardBackground)
          }

          this.UserCard()

          /*
           * 服务器管理：仅向管理员显示，避免普通用户进入服务器管理页面。
           *
           * 以前 13 条入口塞在一张卡里，从上往下要滑很久才找得到想改的那一项；
           * 按「内容 / 服务器 / 运行状态」拆成三张卡后，每张都在一屏内可读完。
           */
          if (AppViewModel.getInstance().isAdmin) {
            this.SectionCard('内容管理', 'folder', [
            { icon: 'folder', title: '媒体库', subtitle: '媒体库管理、显示、元数据与 NFO 设置', route: 'pages/admin/LibrariesAdminPage' },
            { icon: 'person_2', title: '用户', subtitle: '添加和管理服务器用户', route: 'pages/admin/UsersPage' },
            { icon: 'play_circle', title: '播放', subtitle: '服务器级播放：远程码率上限与相关设置入口', route: 'pages/admin/PlaybackSettingsPage' },
            { icon: 'puzzle', title: '插件', subtitle: '已安装的服务器插件', route: 'pages/admin/PluginsPage' },
            ])
            this.SectionCard('服务器设置', 'gearshape', [
            { icon: 'display', title: '控制台', subtitle: '服务器信息、数据统计与操作', route: 'pages/admin/AdminHubPage' },
            { icon: 'gearshape', title: '常规', subtitle: '服务器名称、语言、路径与性能限制', route: 'pages/admin/GeneralSettingsPage' },
            { icon: 'wifi', title: '网络', subtitle: '远程访问、端口、HTTPS、局域网与代理', route: 'pages/admin/NetworkSettingsPage' },
            { icon: 'paintpalette', title: '品牌', subtitle: '启动画面、登录免责声明与自定义 CSS', route: 'pages/admin/BrandingSettingsPage' },
            { icon: 'key', title: 'API 密钥', subtitle: '管理 API 访问密钥', route: 'pages/admin/ApiKeysPage' },
            ])
            this.SectionCard('运行状态', 'timer', [
            { icon: 'timer', title: '计划任务', subtitle: '查看并管理服务器计划任务', route: 'pages/admin/TasksPage' },
            { icon: 'clock', title: '活动', subtitle: '查看服务器活动日志', route: 'pages/admin/ActivityPage' },
            { icon: 'externaldrive', title: '设备', subtitle: '管理连接到服务器的设备', route: 'pages/admin/DevicesPage' },
            { icon: 'doc_text', title: '日志', subtitle: '服务器日志文件', route: 'pages/admin/LogsPage' },
            ])
          }

          /*
           * 界面语言：本应用目前只有中文界面，这里如实说明，而不是摆一个点了没用的选择器。
           * （原来还有一行「时区：自动」，但应用并不消费时区设置、日期都按设备本地格式化，
           *   留着只会让人以为可以配，所以去掉。）
           */
          this.SectionCard('界面', 'message', [
            { icon: '', title: '界面语言', subtitle: '简体中文（本应用目前只提供中文界面）', info: true },
          ])

          // 显示（含服务器开关）
          Column() {
            this.SectionCard('\u663e\u793a', 'display', [
              { icon: 'paintpalette', title: '\u4e3b\u9898\u4e0e\u663e\u793a', subtitle: this.themeSubtitle(),
                route: 'pages/settings/ThemeSettingsPage' },
            ])
            Column() {
              SettingCell({
                title: '\u9690\u85cf\u5df2\u64ad\u653e\u7684\u6700\u65b0\u9879',
                subtitle: '\u5728\u201c\u6700\u65b0\u6dfb\u52a0\u201d\u4e2d\u9690\u85cf\u5df2\u770b\u5b8c\u7684\u5185\u5bb9',
                showToggle: true,
                toggleOn: this.hidePlayedInLatest,
                onToggle: (v: boolean) => {
                  this.hidePlayedInLatest = v;
                  this.saveUserField('HidePlayedInLatest', v);
                }
              })
            }
            .width('100%')
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(ThemeConstants.CARD_RADIUS)
            .clip(true)
            .margin({ left: 16, right: 16, bottom: 8 })
          }

          // 字幕
          this.SectionCard('\u5b57\u5e55', 'doc_text', [
            { icon: 'doc_text', title: '\u5b57\u5e55\u504f\u597d', subtitle: '\u5b57\u5e55\u6a21\u5f0f\u3001\u8bb0\u4f4f\u5b57\u5e55\u9009\u62e9\u4e0e\u5b57\u5e55\u5916\u89c2',
              route: 'pages/settings/SubtitleSettingsPage' },
          ])

          // 操控
          this.SectionCard('\u64cd\u63a7', 'gamecontroller', [
            { icon: 'gamecontroller', title: '\u64cd\u63a7\u504f\u597d', subtitle: '\u6e38\u620f\u624b\u67c4\u4e0e\u5e73\u6ed1\u6eda\u52a8\u63a7\u5236',
              route: 'pages/settings/ControlsSettingsPage' },
          ])

          // 首页与音频：账号级偏好（UserConfiguration），与"服务器管理"分开
          this.SectionCard('\u9996\u9875\u4e0e\u97f3\u9891', 'rectangle_stack', [
            { icon: 'list_bullet', title: '首页与媒体库', subtitle: '媒体库顺序、首页隐藏与合并显示',
              route: 'pages/settings/HomeSettingsPage' },
            { icon: 'speaker_wave_2', title: '音频', subtitle: '优先音轨语言、默认音轨与记住音频选择',
              route: 'pages/settings/AudioSettingsPage' },
          ])

          // 播放（含服务器开关）
          Column() {
            this.SectionCard('\u64ad\u653e', 'play_circle', [
              { icon: 'video', title: '\u9ed8\u8ba4\u64ad\u653e\u5668', subtitle: `\u65b0\u6253\u5f00\u7684\u5a92\u4f53\u5c06\u4f7f\u7528${this.playerLabel()}`, action: 'defaultPlayer' },
              // 短视频模式：选择哪些媒体库进入「视频」页的短视频流（承载页见 pages/ShortVideoPage）
              { icon: 'play_circle', title: '短视频模式', subtitle: this.shortVideoSubtitle(),
                route: 'pages/settings/ShortVideoSettingsPage' },
            ])
            Column() {
              SettingCell({
                title: '\u81ea\u52a8\u64ad\u653e\u4e0b\u4e00\u96c6',
                subtitle: '\u64ad\u653e\u5b8c\u4e00\u96c6\u540e\u81ea\u52a8\u64ad\u653e\u4e0b\u4e00\u96c6',
                showToggle: true,
                toggleOn: this.enableNextEpisodeAutoPlay,
                onToggle: (v: boolean) => {
                  this.enableNextEpisodeAutoPlay = v;
                  this.saveUserField('EnableNextEpisodeAutoPlay', v);
                }
              })
            }
            .width('100%')
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(ThemeConstants.CARD_RADIUS)
            .clip(true)
            .margin({ left: 16, right: 16, bottom: 8 })
          }

          // 我的媒体（含服务器开关）
          Column() {
            this.SectionCard('\u6211\u7684\u5a92\u4f53', 'video', [
              { icon: 'video', title: '\u663e\u793a\u7f3a\u5931\u7684\u5267\u96c6', subtitle: '\u5728\u5267\u96c6\u5217\u8868\u4e2d\u663e\u793a\u5c1a\u672a\u83b7\u53d6\u7684\u5267\u96c6' },
            ])
            Column() {
              SettingCell({
                title: '\u663e\u793a\u7f3a\u5931\u7684\u5267\u96c6',
                subtitle: '\u5728\u5267\u96c6\u5217\u8868\u4e2d\u663e\u793a\u5c1a\u672a\u83b7\u53d6\u7684\u5267\u96c6',
                showToggle: true,
                toggleOn: this.displayMissingEpisodes,
                onToggle: (v: boolean) => {
                  this.displayMissingEpisodes = v;
                  this.saveUserField('DisplayMissingEpisodes', v);
                }
              })
            }
            .width('100%')
            .backgroundColor(this.colors().cardBackground)
            .borderRadius(ThemeConstants.CARD_RADIUS)
            .clip(true)
            .margin({ left: 16, right: 16, bottom: 8 })
          }

          // 服务器（Flutter：名称 InfoTile + 地址 + 版本）
          this.SectionCard('\u670d\u52a1\u5668', 'externaldrive', [
            // 名称行原来错误地显示了地址；地址行改用会话权威值（原为可能陈旧的 VM 值）
            { icon: '', title: '\u670d\u52a1\u5668\u540d\u79f0', subtitle: this.serverNameText(), info: true },
            { icon: '', title: '\u670d\u52a1\u5668\u5730\u5740', subtitle: this.serverAddressText(), info: true },
            // 取不到版本时显示"未知"（原来永远停在"加载中..."）
            { icon: '', title: '\u670d\u52a1\u5668\u7248\u672c', subtitle: this.serverVersion.length > 0 ? this.serverVersion : '\u672a\u77e5', info: true },
          ])

          // 账号
          this.SectionCard('\u8d26\u53f7', 'person_2', [
            { icon: 'power', title: '\u9000\u51fa\u767b\u5f55', subtitle: '\u6e05\u9664\u672c\u5730\u8d26\u53f7\u4fe1\u606f\uff0c\u4fdd\u7559\u670d\u52a1\u5668\u5730\u5740', action: 'logout' },
            { icon: 'arrow_2_circlepath', title: '\u66f4\u6362\u670d\u52a1\u5668', subtitle: '\u6e05\u9664\u5168\u90e8\u914d\u7f6e\u5e76\u91cd\u65b0\u8fde\u63a5', action: 'changeServer' },
            // 上架合规：提供明确的"清除全部本地数据"入口（会话、服务器地址、偏好、隐私同意记录）
            { icon: 'trash', title: '\u6e05\u9664\u5168\u90e8\u672c\u5730\u6570\u636e', subtitle: '\u5220\u9664\u672c\u673a\u4f1a\u8bdd\u3001\u670d\u52a1\u5668\u5730\u5740\u4e0e\u504f\u597d\uff08\u4e0d\u5f71\u54cd\u670d\u52a1\u5668\u4e0a\u7684\u6570\u636e\uff09', action: 'clearLocalData' },
          ])

          // 关于
          this.SectionCard('\u5173\u4e8e', 'info_circle', [
            { icon: 'doc_text', title: '\u9690\u79c1\u653f\u7b56', subtitle: '\u6211\u4eec\u5982\u4f55\u5904\u7406\u4e0e\u4fdd\u62a4\u4f60\u7684\u4fe1\u606f', route: 'pages/LegalPage', titleParam: 'privacy' },
            { icon: 'doc_text', title: '\u7528\u6237\u534f\u8bae', subtitle: '\u4f7f\u7528\u672c\u5e94\u7528\u7684\u6761\u6b3e\u4e0e\u514d\u8d23\u8bf4\u660e', route: 'pages/LegalPage', titleParam: 'terms' },
            { icon: '', title: '\u5ba2\u6237\u7aef', subtitle: 'Jellyfin \u975e\u5b98\u65b9\u7b2c\u4e09\u65b9\u5ba2\u6237\u7aef', info: true },
            { icon: '', title: '\u7248\u672c', subtitle: JellyfinNative.getVersion(), info: true },
            { icon: '', title: '\u6784\u5efa\u73af\u5883', subtitle: 'Native ArkTS 5.1.0(18)', info: true },
          ])
        }
        .width('100%')
        .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
        .padding({ bottom: 32 })
        .alignItems(HorizontalAlign.Center)
      }
      .width('100%')
      .height('100%')
      .align(Alignment.Top)
      .scrollBar(BarState.Off)

      if (this.showClearDataConfirm) {
        this.ConfirmDialog('\u6e05\u9664\u5168\u90e8\u672c\u5730\u6570\u636e',
          '\u5c06\u5220\u9664\u672c\u673a\u4fdd\u5b58\u7684\u4f1a\u8bdd\u3001\u670d\u52a1\u5668\u5730\u5740\u3001\u504f\u597d\u4e0e\u9690\u79c1\u540c\u610f\u8bb0\u5f55\uff0c\u670d\u52a1\u5668\u4e0a\u7684\u6570\u636e\u4e0d\u53d7\u5f71\u54cd\u3002\u786e\u5b9a\u7ee7\u7eed\uff1f',
          '\u6e05\u9664', () => {
            this.clearLocalData();
          }, () => {
            this.showClearDataConfirm = false;
          });
      }
      if (this.showLogoutConfirm) {
        this.ConfirmDialog('\u9000\u51fa\u767b\u5f55', '\u786e\u5b9a\u8981\u9000\u51fa\u5f53\u524d\u8d26\u53f7\u5417\uff1f', '\u9000\u51fa', () => {
          this.onLogout();
        }, () => {
          this.showLogoutConfirm = false;
        })
      }

      if (this.showChangeServerConfirm) {
        this.ConfirmDialog('\u66f4\u6362\u670d\u52a1\u5668',
          '\u5c06\u6e05\u9664\u5f53\u524d\u670d\u52a1\u5668\u914d\u7f6e\u5e76\u8fd4\u56de\u8fde\u63a5\u9875\u9762\uff0c\u786e\u5b9a\u7ee7\u7eed\u5417\uff1f',
          '\u6e05\u9664', () => {
            this.onChangeServer();
          }, () => {
            this.showChangeServerConfirm = false;
          })
      }

      if (this.showPlayerPicker) {
        this.PlayerPickerDialog(() => {
          this.showPlayerPicker = false;
        })
      }

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().success)
          .width('80%')
          .padding({ left: 16, right: 16, top: 8, bottom: 8 })
          .backgroundColor(this.colors().cardBackground)
          .borderRadius(8)
          .position({ x: '10%', y: 56 })
          .onClick(() => {
            this.message = '';
          })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}

/** 取消按钮文案由资源提供，避免遗漏本地化 */
function cancelLabel(): string {
  return '\u53d6\u6d88';
}
