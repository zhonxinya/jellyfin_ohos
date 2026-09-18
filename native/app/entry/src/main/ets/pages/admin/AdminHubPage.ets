import router from '@ohos.router';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { SectionHeader } from '../../components/SectionHeader';

interface AdminLink {
  title: string;
  subtitle: string;
  icon: string;
  url: string;
  path?: string;
  titleParam?: string;
}

interface AdminGroup {
  title: string;
  icon: string;
  links: AdminLink[];
}

@Entry
@Component
struct AdminHubPage {
  private groups: AdminGroup[] = [

    {
      title: '用户与设备',
      icon: 'person_2',
      links: [
        { title: '用户', subtitle: '管理用户、权限和登录状态', icon: 'person_2', url: 'pages/admin/UsersPage' },
        { title: '设备', subtitle: '查看已连接的客户端设备', icon: 'display', url: 'pages/admin/DevicesPage' },
        { title: 'API 密钥', subtitle: '管理服务器 API 访问密钥', icon: 'key', url: 'pages/admin/ApiKeysPage' }
      ]
    },
    {
      title: '服务器',
      icon: 'gearshape',
      links: [
        { title: '系统信息', subtitle: '查看服务器版本和运行环境', icon: 'info_circle', url: 'pages/admin/SystemInfoPage' },
        { title: '计划任务', subtitle: '查看和管理后台任务', icon: 'timer', url: 'pages/admin/TasksPage' },
        { title: '日志', subtitle: '查看服务器运行日志', icon: 'doc_text', url: 'pages/admin/LogsPage' },
        { title: '活动', subtitle: '查看服务器活动记录', icon: 'clock', url: 'pages/admin/ActivityPage' },
        { title: '常规设置', subtitle: '配置服务器基础选项', icon: 'gearshape', url: 'pages/admin/GeneralSettingsPage' },
        { title: '网络', subtitle: '远程访问、端口、HTTPS、局域网与代理', icon: 'wifi', url: 'pages/admin/NetworkSettingsPage' },
        { title: '品牌', subtitle: '启动画面、登录免责声明与自定义 CSS', icon: 'paintpalette', url: 'pages/admin/BrandingSettingsPage' }
      ]
    },
    {
      title: '媒体库',
      icon: 'video',
      links: [
        { title: '媒体库管理', subtitle: '新建/重命名/删除媒体库，管理媒体路径、扫描与选项', icon: 'folder', url: 'pages/admin/LibrariesAdminPage' },
        { title: '媒体库显示', subtitle: '服务器级：显示方式、图片落盘约定、扫描并发与监控', icon: 'display', url: 'pages/admin/LibraryDisplaySettingsPage' },
        { title: '媒体库原始配置', subtitle: '查看 /Library/VirtualFolders 的原始返回（排障用）', icon: 'folder', url: 'pages/admin/AdminGenericPage', path: '/Library/VirtualFolders', titleParam: '媒体库原始配置' },
        { title: '媒体库元数据', subtitle: '服务器默认用哪些元数据/图片抓取器与顺序', icon: 'doc_text', url: 'pages/admin/MetadataSettingsPage' },
        { title: '本地媒体文件夹', subtitle: '查看服务器上有哪些本地媒体目录', icon: 'folder', url: 'pages/admin/LibrariesMetadataPage' },
        { title: '元数据原始配置', subtitle: '查看 /System/Configuration/metadata 的原始返回（排障用）', icon: 'doc_text', url: 'pages/admin/AdminGenericPage', path: '/System/Configuration/metadata', titleParam: '元数据原始配置' },
        // key 是 `xbmcmetadata`：`/System/Configuration/nfo` 实测 404（曾经写错，点进去只有报错）
        { title: 'NFO 设置', subtitle: 'nfo 的日期格式、图片路径与路径替换', icon: 'doc_text', url: 'pages/admin/NfoSettingsPage' }
      ]
    },
    {
      title: '播放与转码',
      icon: 'play_circle',
      links: [
        /*
         * 原来这里有一条「流媒体」指向 `StreamingPage`，而那个页面读的其实是
         * `/System/Configuration/network`，字段名还有四个是错的（`EnableRemoteControl` /
         * `PublicHttpPort` / `InternalHttpPort` / `InternalHttpsPort` —— 10.8 的真实字段是
         * `PublicPort` / `HttpServerPortNumber` / `HttpsPortNumber`，另外没有 EnableRemoteControl）。
         * 错的字段名会被服务端静默忽略，等于界面上改了没效果；这些内容现在都在「网络」页里，
         * 所以那条入口连同页面一起去掉了。
         */
        { title: '转码', subtitle: '硬件加速、编码质量、限速、HDR→SDR 与转码路径', icon: 'video', url: 'pages/admin/TranscodingSettingsPage' },
        { title: '播放设置', subtitle: '服务器级播放：远程码率上限与相关设置入口', icon: 'play_circle', url: 'pages/admin/PlaybackSettingsPage' },
        // 原来指向 `/System/Configuration`：标题写着"继续观看"，内容却是整份服务器配置的键值表
        { title: '继续观看', subtitle: '续播/已看的百分比与时长阈值、有声书续播', icon: 'arrow_2_circlepath', url: 'pages/admin/ResumeSettingsPage' }
        /*
         * 原来还有一条「Trickplay」指向 `/System/Configuration/trickplay` —— 实测那个 key
         * 不存在（`trickplay` / `trickplayoptions` 都是 404），点进去只有一句报错；
         * 而 Trickplay（拖动预览缩略图）是 Web 客户端的特性，本应用的播放器不使用它。
         * 与其留一条打不开的入口，不如去掉；需要改的话在 Web 控制台的「播放」页里配。
         */
      ]
    },
    {
      title: '扩展',
      icon: 'puzzle',
      links: [
        { title: '插件', subtitle: '管理 Jellyfin 插件', icon: 'puzzle', url: 'pages/admin/PluginsPage' }
      ]
    }
  ];

  aboutToAppear(): void {
    if (!AppViewModel.getInstance().isAdmin) {
      router.replaceUrl({ url: 'pages/MainShell' });
    }
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private openLink(link: AdminLink): void {
    if (link.path !== undefined && link.path.length > 0) {
      const titleParam: string = link.titleParam !== undefined ? link.titleParam : link.title;
      router.pushUrl({
        url: link.url,
        params: { title: titleParam, path: link.path }
      });
    } else {
      router.pushUrl({ url: link.url });
    }
  }

  /** 管理项图标 —— 系统符号（原来用 emoji 文本当图标） */
  private iconResource(name: string): Resource {
    if (name === 'person_2') {
      return $r('sys.symbol.person_2');
    }
    if (name === 'display') {
      return $r('sys.symbol.display');
    }
    if (name === 'key') {
      return $r('sys.symbol.key');
    }
    if (name === 'gearshape') {
      return $r('sys.symbol.gearshape');
    }
    if (name === 'info_circle') {
      return $r('sys.symbol.info_circle');
    }
    if (name === 'timer') {
      return $r('sys.symbol.timer');
    }
    if (name === 'clock') {
      return $r('sys.symbol.clock');
    }
    if (name === 'doc_text') {
      return $r('sys.symbol.doc_text');
    }
    if (name === 'wifi') {
      return $r('sys.symbol.wifi');
    }
    if (name === 'paintpalette') {
      return $r('sys.symbol.paintpalette');
    }
    if (name === 'folder') {
      return $r('sys.symbol.folder');
    }
    if (name === 'play_circle') {
      return $r('sys.symbol.play_circle');
    }
    if (name === 'arrow_2_circlepath') {
      return $r('sys.symbol.arrow_2_circlepath');
    }
    if (name === 'puzzle') {
      return $r('sys.symbol.puzzle');
    }
    return $r('sys.symbol.video');
  }

  /**
   * 管理项行 —— 对齐 mybooks_ohos 的 `SettingCell`：
   * 标题 16fp `text_primary`、副标题 12fp `text_secondary`、尾部 chevron 16fp `text_tertiary`、
   * 四边 16vp 内边距、按下态 `surface_pressed`（原来用 › 字符 + 14/11fp 文案）。
   */
  @Builder
  AdminLinkTile(link: AdminLink) {
    Row({ space: 12 }) {
      SymbolGlyph(this.iconResource(link.icon))
        .fontSize(ThemeConstants.ICON_LARGE)
        .fontColor([this.colors().brandPrimary])
        .width(28)
      Column({ space: 4 }) {
        Text(link.title)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(link.subtitle)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      SymbolGlyph($r('sys.symbol.chevron_right'))
        .fontSize(ThemeConstants.ICON_SMALL)
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
      this.openLink(link);
    })
  }

  @Builder
  AdminGroupCard(group: AdminGroup) {
    Column() {
      SectionHeader({ title: group.title, icon: group.icon })
      Column() {
        ForEach(group.links, (link: AdminLink, index: number) => {
          if (index > 0) {
            Divider()
              .color(this.colors().divider)
              .strokeWidth(0.5)
          }
          this.AdminLinkTile(link)
        }, (link: AdminLink) => `${group.title}_${link.title}`)
      }
      .width('100%')
      .borderRadius(12)
      .clip(true)
    }
    .width('100%')
  }

  build() {
    Column() {
      PageHeader({
        title: '管理',
        onBack: () => {
          router.back();
        }
      })

      Scroll() {
        Column({ space: 8 }) {
          ForEach(this.groups, (group: AdminGroup) => {
            this.AdminGroupCard(group)
          }, (group: AdminGroup) => group.title)
        }
        .width('100%')
        .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
        .padding({ left: 16, right: 16, bottom: 24 })
      }
      .layoutWeight(1)
      .width('100%')
      .scrollBar(BarState.Off)
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
