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
      icon: '\u{1F465}',
      links: [
        { title: '用户', subtitle: '管理用户、权限和登录状态', icon: '\u{1F464}', url: 'pages/admin/UsersPage' },
        { title: '设备', subtitle: '查看已连接的客户端设备', icon: '\u{1F4F1}', url: 'pages/admin/DevicesPage' },
        { title: 'API 密钥', subtitle: '管理服务器 API 访问密钥', icon: '\u{1F511}', url: 'pages/admin/ApiKeysPage' }
      ]
    },
    {
      title: '服务器',
      icon: '\u{2699}\uFE0F',
      links: [
        { title: '系统信息', subtitle: '查看服务器版本和运行环境', icon: '\u{2139}\uFE0F', url: 'pages/admin/SystemInfoPage' },
        { title: '计划任务', subtitle: '查看和管理后台任务', icon: '\u{1F4C5}', url: 'pages/admin/TasksPage' },
        { title: '日志', subtitle: '查看服务器运行日志', icon: '\u{1F4DC}', url: 'pages/admin/LogsPage' },
        { title: '活动', subtitle: '查看服务器活动记录', icon: '\u{1F4CA}', url: 'pages/admin/ActivityPage' },
        { title: '常规设置', subtitle: '配置服务器基础选项', icon: '\u{1F527}', url: 'pages/admin/GeneralSettingsPage' },
        { title: '网络', subtitle: '配置网络和连接选项', icon: '\u{1F310}', url: 'pages/admin/AdminGenericPage', path: '/System/Configuration/network', titleParam: '网络' },
        { title: '品牌', subtitle: '配置服务器品牌信息', icon: '\u{1F3A8}', url: 'pages/admin/AdminGenericPage', path: '/System/Configuration/branding', titleParam: '品牌' }
      ]
    },
    {
      title: '媒体库',
      icon: '\u{1F4DA}',
      links: [
        { title: '媒体库管理', subtitle: '管理虚拟文件夹和媒体路径', icon: '\u{1F4C1}', url: 'pages/admin/LibrariesAdminPage' },
        { title: '媒体库显示', subtitle: '设置媒体库显示方式', icon: '\u{1F441}\uFE0F', url: 'pages/admin/AdminGenericPage', path: '/System/Configuration/library', titleParam: '媒体库显示' },
        { title: '媒体库设置', subtitle: '配置虚拟媒体库', icon: '\u{1F5C2}\uFE0F', url: 'pages/admin/AdminGenericPage', path: '/Library/VirtualFolders', titleParam: '媒体库设置' },
        { title: '用户元数据', subtitle: '管理用户媒体元数据', icon: '\u{1F4DD}', url: 'pages/admin/UsersMetadataPage' },
        { title: '媒体库元数据', subtitle: '管理媒体库元数据', icon: '\u{1F4D6}', url: 'pages/admin/LibrariesMetadataPage' },
        { title: 'NFO 设置', subtitle: '配置 NFO 元数据选项', icon: '\u{1F4C4}', url: 'pages/admin/AdminGenericPage', path: '/System/Configuration/nfo', titleParam: 'NFO 设置' }
      ]
    },
    {
      title: '播放与转码',
      icon: '\u{25B6}\uFE0F',
      links: [
        { title: '流媒体', subtitle: '查看流媒体和连接状态', icon: '\u{1F4FA}', url: 'pages/admin/StreamingPage' },
        { title: '转码', subtitle: '配置视频转码参数', icon: '\u{1F3AC}', url: 'pages/admin/TranscodingPage' },
        { title: '播放设置', subtitle: '配置播放和媒体能力', icon: '\u{25B6}\uFE0F', url: 'pages/admin/PlaybackSettingsPage' },
        { title: '继续观看', subtitle: '配置继续观看行为', icon: '\u{1F501}', url: 'pages/admin/AdminGenericPage', path: '/System/Configuration', titleParam: '继续观看' },
        { title: 'Trickplay', subtitle: '配置预览缩略图选项', icon: '\u{1F39E}\uFE0F', url: 'pages/admin/AdminGenericPage', path: '/System/Configuration/trickplay', titleParam: 'Trickplay' }
      ]
    },
    {
      title: '扩展',
      icon: '\u{1F9E9}',
      links: [
        { title: '插件', subtitle: '管理 Jellyfin 插件', icon: '\u{1F50C}', url: 'pages/admin/PluginsPage' }
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

  @Builder
  AdminLinkTile(link: AdminLink) {
    Row({ space: 12 }) {
      Text(link.icon)
        .fontSize(21)
        .width(28)
        .textAlign(TextAlign.Center)
      Column({ space: 3 }) {
        Text(link.title)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().onSurface)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(link.subtitle)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().onSurfaceVariant)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Text('\u203A')
        .fontSize(22)
        .fontColor(this.colors().onSurfaceVariant)
    }
    .width('100%')
    .padding({ left: 16, right: 12, top: 12, bottom: 12 })
    .backgroundColor(this.colors().surface)
    .onClick(() => {
      this.openLink(link);
    })
  }

  @Builder
  AdminGroupCard(group: AdminGroup) {
    Column() {
      SectionHeader({ title: group.title, icon: group.icon })
      Column() {
        ForEach(group.links, (link: AdminLink) => {
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
    .backgroundColor(this.colors().background)
  }
}
