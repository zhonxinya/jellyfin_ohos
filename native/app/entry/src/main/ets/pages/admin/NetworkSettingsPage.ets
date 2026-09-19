import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 这一段配置的 key（`GET /System/Configuration/network`） */
const NETWORK_CONFIG_KEY = 'network';

/**
 * 设置 → 网络。
 *
 * 对应 jellyfin-web 的 Dashboard → Networking，落到服务端的 `NetworkConfiguration`
 * （34 个字段，这里挑出手机端真正会改的那些，其余原样回传）：
 *
 * - 远程访问：`EnableRemoteAccess` / `EnableUPnP` / `UPnPCreateHttpPortMap` /
 *   `PublicPort` / `PublicHttpsPort`
 * - 服务器端口：`HttpServerPortNumber` / `HttpsPortNumber` / `EnableHttps` / `RequireHttps` / `BaseUrl`
 * - 协议与发现：`EnableIPV4` / `EnableIPV6` / `AutoDiscovery`
 * - 本地网络与代理：`LocalNetworkSubnets` / `KnownProxies` / `RemoteIPFilter` +
 *   `IsRemoteIPFilterBlacklist` / `IgnoreVirtualInterfaces` + `VirtualInterfaceNames`
 *
 * ⚠️ 端口类改动**要重启服务器才生效**，而且改错会让你连不上这台服务器 ——
 * 页面上有明确提示；本页只负责写配置，不替用户重启。
 */
@Entry
@Component
struct NetworkSettingsPage {
  /** 这一段配置的底本（未在界面上暴露的字段靠它原样回传） */
  private base: ESObject = {} as ESObject;
  private originalJson: string = '';

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  // 远程访问
  @State private remoteAccess: boolean = true;
  @State private enableUpnp: boolean = true;
  @State private upnpPortMap: boolean = false;
  @State private publicPort: number = 8096;
  @State private publicHttpsPort: number = 8920;
  // 服务器端口
  @State private httpPort: number = 8096;
  @State private httpsPort: number = 8920;
  @State private enableHttps: boolean = false;
  @State private requireHttps: boolean = false;
  @State private baseUrl: string = '';
  @State private certificatePath: string = '';
  @State private certificatePassword: string = '';
  // 协议与发现
  @State private enableIpv4: boolean = true;
  @State private enableIpv6: boolean = false;
  @State private autoDiscovery: boolean = true;
  @State private udpPortRange: string = '';
  // 本地网络与代理
  @State private localSubnets: string = '';
  @State private localAddresses: string = '';
  @State private knownProxies: string = '';
  @State private remoteIpFilter: string = '';
  @State private filterIsBlacklist: boolean = false;
  @State private ignoreVirtualInterfaces: boolean = true;
  @State private virtualInterfaceNames: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.libraryNamedConfig(NETWORK_CONFIG_KEY);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取网络设置失败';
      return;
    }
    this.originalJson = JsonUtil.toPretty(result.data);
    this.base = result.data;

    this.remoteAccess = JsonUtil.getBoolean(this.base, 'EnableRemoteAccess', true);
    this.enableUpnp = JsonUtil.getBoolean(this.base, 'EnableUPnP', true);
    this.upnpPortMap = JsonUtil.getBoolean(this.base, 'UPnPCreateHttpPortMap', false);
    this.publicPort = JsonUtil.getNumber(this.base, 'PublicPort', 8096);
    this.publicHttpsPort = JsonUtil.getNumber(this.base, 'PublicHttpsPort', 8920);
    this.httpPort = JsonUtil.getNumber(this.base, 'HttpServerPortNumber', 8096);
    this.httpsPort = JsonUtil.getNumber(this.base, 'HttpsPortNumber', 8920);
    this.enableHttps = JsonUtil.getBoolean(this.base, 'EnableHttps', false);
    this.requireHttps = JsonUtil.getBoolean(this.base, 'RequireHttps', false);
    this.baseUrl = JsonUtil.getString(this.base, 'BaseUrl', '');
    this.certificatePath = JsonUtil.getString(this.base, 'CertificatePath', '');
    this.certificatePassword = JsonUtil.getString(this.base, 'CertificatePassword', '');
    this.enableIpv4 = JsonUtil.getBoolean(this.base, 'EnableIPV4', true);
    this.enableIpv6 = JsonUtil.getBoolean(this.base, 'EnableIPV6', false);
    this.autoDiscovery = JsonUtil.getBoolean(this.base, 'AutoDiscovery', true);
    this.localSubnets = NetworkSettingsPage.joinList(this.base, 'LocalNetworkSubnets');
    this.localAddresses = NetworkSettingsPage.joinList(this.base, 'LocalNetworkAddresses');
    this.udpPortRange = JsonUtil.getString(this.base, 'UDPPortRange', '');
    this.knownProxies = NetworkSettingsPage.joinList(this.base, 'KnownProxies');
    this.remoteIpFilter = NetworkSettingsPage.joinList(this.base, 'RemoteIPFilter');
    this.filterIsBlacklist = JsonUtil.getBoolean(this.base, 'IsRemoteIPFilterBlacklist', false);
    this.ignoreVirtualInterfaces = JsonUtil.getBoolean(this.base, 'IgnoreVirtualInterfaces', true);
    this.virtualInterfaceNames = JsonUtil.getString(this.base, 'VirtualInterfaceNames', '');
    this.status = UiState.SUCCESS;
  }

  /** 字符串数组在界面里按"一行一条"编辑 */
  private static joinList(obj: ESObject, key: string): string {
    const out: string[] = [];
    const items: Object[] = JsonUtil.getArray(obj, key);
    for (let i = 0; i < items.length; i++) {
      if (typeof items[i] === 'string') {
        out.push(items[i] as string);
      }
    }
    return out.join('\n');
  }

  private static splitList(text: string): string[] {
    const out: string[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const trimmed: string = lines[i].trim();
      if (trimmed.length > 0) {
        out.push(trimmed);
      }
    }
    return out;
  }

  private buildPayload(): string {
    const draft: ESObject = JSON.parse(JSON.stringify(this.base)) as ESObject;
    const bag: Record<string, Object> = draft as Record<string, Object>;
    bag['EnableRemoteAccess'] = this.remoteAccess;
    bag['EnableUPnP'] = this.enableUpnp;
    bag['UPnPCreateHttpPortMap'] = this.upnpPortMap;
    bag['PublicPort'] = this.publicPort;
    bag['PublicHttpsPort'] = this.publicHttpsPort;
    bag['HttpServerPortNumber'] = this.httpPort;
    bag['HttpsPortNumber'] = this.httpsPort;
    bag['EnableHttps'] = this.enableHttps;
    bag['RequireHttps'] = this.requireHttps;
    bag['BaseUrl'] = this.baseUrl.trim();
    bag['CertificatePath'] = this.certificatePath.trim();
    bag['CertificatePassword'] = this.certificatePassword;
    bag['EnableIPV4'] = this.enableIpv4;
    bag['EnableIPV6'] = this.enableIpv6;
    bag['AutoDiscovery'] = this.autoDiscovery;
    bag['UDPPortRange'] = this.udpPortRange.trim();
    bag['LocalNetworkSubnets'] = NetworkSettingsPage.splitList(this.localSubnets);
    bag['LocalNetworkAddresses'] = NetworkSettingsPage.splitList(this.localAddresses);
    bag['KnownProxies'] = NetworkSettingsPage.splitList(this.knownProxies);
    bag['RemoteIPFilter'] = NetworkSettingsPage.splitList(this.remoteIpFilter);
    bag['IsRemoteIPFilterBlacklist'] = this.filterIsBlacklist;
    bag['IgnoreVirtualInterfaces'] = this.ignoreVirtualInterfaces;
    bag['VirtualInterfaceNames'] = this.virtualInterfaceNames.trim();
    return JsonUtil.toPretty(draft);
  }

  private isDirty(): boolean {
    return this.buildPayload() !== this.originalJson;
  }

  private touch(): void {
    this.actionMessage = '';
  }

  /** 端口必须是 1..65535；Base URL 必须为空或以 / 开头（服务端也是这么要求的） */
  private validationError(): string {
    const ports: number[] = [this.publicPort, this.publicHttpsPort, this.httpPort, this.httpsPort];
    for (let i = 0; i < ports.length; i++) {
      if (ports[i] < 1 || ports[i] > 65535) {
        return '端口必须在 1–65535 之间';
      }
    }
    const url: string = this.baseUrl.trim();
    if (url.length > 0 && url.charAt(0) !== '/') {
      return 'Base URL 必须以 / 开头（例如 /jellyfin），或用反向代理的完整路径';
    }
    return '';
  }

  private async save(): Promise<void> {
    if (this.saving || !this.isDirty()) {
      return;
    }
    const invalid: string = this.validationError();
    if (invalid.length > 0) {
      this.actionOk = false;
      this.actionMessage = invalid;
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.libraryUpdateNamedConfig(NETWORK_CONFIG_KEY, this.buildPayload()));
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = '已保存；端口类改动需要重启服务器才生效';
    this.load();
  }

  @Builder
  NumberRow(title: string, hint: string, value: number, onChange: (value: number) => void) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
        Text(hint)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      TextInput({ text: `${value}` })
        .type(InputType.Number)
        .width(110)
        .textAlign(TextAlign.End)
        .onChange((text: string) => {
          const parsed: number = Math.floor(Number(text));
          onChange(Number.isNaN(parsed) ? 0 : parsed);
          this.touch();
        })
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  @Builder
  TextRow(title: string, hint: string, value: string, placeholder: string,
          onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(hint)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      TextInput({ text: value, placeholder: placeholder })
        .width('100%')
        .onChange((text: string) => {
          onChange(text);
          this.touch();
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  @Builder
  ListRow(title: string, hint: string, value: string, placeholder: string,
          onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(hint)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      TextArea({ text: value, placeholder: placeholder })
        .width('100%')
        .height(84)
        .onChange((text: string) => {
          onChange(text);
          this.touch();
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  @Builder
  ToggleRow(title: string, hint: string, on: boolean, onChange: (value: boolean) => void) {
    SettingCell({
      title: title,
      subtitle: hint,
      showToggle: true,
      toggleOn: on,
      onToggle: (value: boolean) => {
        onChange(value);
        this.touch();
      }
    })
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '网络',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('服务器级设置（影响所有客户端如何连上这台服务器）')
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
            if (this.actionMessage.length > 0) {
              Text(this.actionMessage)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.actionOk ? this.colors().success : this.colors().error)
                .maxLines(2)
            } else {
              Text(this.isDirty() ? '有未保存的修改' : '与服务器一致')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.isDirty() ? this.colors().warning : this.colors().textSecondary)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 4 })
        }

        if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState()
        } else if (this.status === UiState.ERROR) {
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
            actionLabel: '重试',
            onAction: () => {
              this.load();
            }
          })
        } else {
          Scroll() {
            Column() {
              SectionCard({ title: '远程访问', icon: $r('sys.symbol.wifi'), showHeaderIcon: true }) {
                Column() {
                  this.ToggleRow('允许远程连接', '关闭后只有同一局域网能连上（服务端会拒绝公网来源）',
                    this.remoteAccess, (value: boolean) => {
                      this.remoteAccess = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('启用 UPnP', '让路由器自动把端口开放到公网',
                    this.enableUpnp, (value: boolean) => {
                      this.enableUpnp = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('自动创建端口映射', '通过 UPnP 请求路由器建立映射（要求路由器支持）',
                    this.upnpPortMap, (value: boolean) => {
                      this.upnpPortMap = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('公网 HTTP 端口', '路由器上对外开放的 HTTP 端口',
                    this.publicPort, (value: number) => {
                      this.publicPort = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('公网 HTTPS 端口', '路由器上对外开放的 HTTPS 端口',
                    this.publicHttpsPort, (value: number) => {
                      this.publicHttpsPort = value;
                    })
                }
                .width('100%')
              }

              SectionCard({ title: '服务器端口', icon: $r('sys.symbol.externaldrive'),
                showHeaderIcon: true }) {
                Column() {
                  Text('端口改动要重启 Jellyfin 服务器才生效；改错了会导致所有客户端都连不上，'
                    + '请确认你能在服务器本机修改配置。')
                    .fontSize(ThemeConstants.META_SMALL)
                    .fontColor(this.colors().warning)
                    .width('100%')
                    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                      top: 10 })
                  this.NumberRow('本地 HTTP 端口', '服务器实际监听的 HTTP 端口',
                    this.httpPort, (value: number) => {
                      this.httpPort = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('本地 HTTPS 端口', '服务器实际监听的 HTTPS 端口',
                    this.httpsPort, (value: number) => {
                      this.httpsPort = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('启用 HTTPS', '监听 HTTPS 端口（需要在下面配置证书）',
                    this.enableHttps, (value: boolean) => {
                      this.enableHttps = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('强制 HTTPS', 'HTTP 请求一律重定向到 HTTPS',
                    this.requireHttps, (value: boolean) => {
                      this.requireHttps = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.TextRow('Base URL', '反向代理下的子路径（例如 /jellyfin）；留空表示根路径',
                    this.baseUrl, '/jellyfin',
                    (value: string) => {
                      this.baseUrl = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.TextRow('证书路径', 'HTTPS 用的 PKCS#12 证书在服务器上的路径（不是手机上的路径）',
                    this.certificatePath, '/etc/jellyfin/cert.pfx',
                    (value: string) => {
                      this.certificatePath = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.TextRow('证书密码', '证书文件的口令；没有口令就留空',
                    this.certificatePassword, '（可选）',
                    (value: string) => {
                      this.certificatePassword = value;
                    })
                }
                .width('100%')
              }

              SectionCard({ title: '协议与发现', icon: $r('sys.symbol.square_grid_2x2'),
                showHeaderIcon: true }) {
                Column() {
                  this.ToggleRow('启用 IPv4', '监听 IPv4 地址',
                    this.enableIpv4, (value: boolean) => {
                      this.enableIpv4 = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('启用 IPv6', '监听 IPv6 地址（局域网没有 IPv6 时可以关掉）',
                    this.enableIpv6, (value: boolean) => {
                      this.enableIpv6 = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('自动发现', '允许局域网内的客户端通过 UDP 广播发现这台服务器',
                    this.autoDiscovery, (value: boolean) => {
                      this.autoDiscovery = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.TextRow('UDP 端口范围', '自动发现用的 UDP 端口范围；留空用系统默认（例如 5000-5020）',
                    this.udpPortRange, '5000-5020',
                    (value: string) => {
                      this.udpPortRange = value;
                    })
                }
                .width('100%')
              }

              SectionCard({ title: '本地网络与代理（高级）', icon: $r('sys.symbol.key'),
                showHeaderIcon: true }) {
                Column() {
                  this.ListRow('局域网子网', '判断"来自局域网"的网段，每行一条（例如 192.168.1.0/24）',
                    this.localSubnets, '192.168.1.0/24',
                    (value: string) => {
                      this.localSubnets = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ListRow('局域网地址', '直接把某些地址当作局域网，每行一条（子网之外的单个地址）',
                    this.localAddresses, '192.168.1.5',
                    (value: string) => {
                      this.localAddresses = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ListRow('已知代理', '反向代理的地址，每行一条；来自这些地址的请求按真实来源判断',
                    this.knownProxies, '192.168.1.10',
                    (value: string) => {
                      this.knownProxies = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ListRow('IP 过滤列表',
                    '配合下面的开关使用：写成黑名单则拒绝这些地址，写成白名单则只允许这些地址',
                    this.remoteIpFilter, '10.0.0.0/8',
                    (value: string) => {
                      this.remoteIpFilter = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('上面的列表是黑名单', '打开 = 拒绝列表中的地址；关闭 = 只允许列表中的地址',
                    this.filterIsBlacklist, (value: boolean) => {
                      this.filterIsBlacklist = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('忽略虚拟网卡', '绑定地址时跳过 Docker/虚拟机的虚拟接口',
                    this.ignoreVirtualInterfaces, (value: boolean) => {
                      this.ignoreVirtualInterfaces = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.TextRow('虚拟网卡名匹配', '按通配符匹配要忽略的接口名（分号分隔）',
                    this.virtualInterfaceNames, 'vEthernet*',
                    (value: string) => {
                      this.virtualInterfaceNames = value;
                    })
                }
                .width('100%')
              }

              Blank().height(60)
            }
            .width('100%')
            .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)

          Row({ space: 10 }) {
            Button('恢复')
              .layoutWeight(1)
              .height(44)
              .backgroundColor(this.colors().surfacePressed)
              .fontColor(this.colors().textPrimary)
              .enabled(!this.saving && this.isDirty())
              .onClick(() => {
                this.load();
                this.actionOk = true;
                this.actionMessage = '已恢复为服务器上的当前设置';
              })
            Button(this.saving ? '保存中...' : '保存')
              .layoutWeight(2)
              .height(44)
              .backgroundColor(this.colors().brandPrimary)
              .fontColor(this.colors().onBrand)
              .enabled(!this.saving && this.isDirty())
              .onClick(() => {
                this.save();
              })
          }
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
            top: 8, bottom: 8 })
          .backgroundColor(this.colors().cardBackground)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)
    }
    .width('100%')
    .height('100%')
  }
}
