import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { EmptyState } from '../../components/EmptyState';
import { LoadingState } from '../../components/LoadingState';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ShortVideoPrefs } from '../../common/ShortVideoPrefs';

/** 媒体库集合类型 → 展示文案（与 `LibrariesAdminPage` 的口径一致） */
function libraryTypeLabel(collectionType: string, type: string): string {
  if (collectionType === 'movies') return '电影';
  if (collectionType === 'tvshows') return '剧集';
  if (collectionType === 'music') return '音乐';
  if (collectionType === 'photos') return '照片';
  if (collectionType === 'homevideos' || collectionType === 'videos') return '视频';
  if (collectionType === 'boxsets') return '合集';
  if (collectionType === 'books') return '书籍';
  if (collectionType === 'playlists') return '播放列表';
  if (collectionType === 'mixed') return '混合内容';
  return type.length > 0 ? type : '媒体库';
}

/**
 * 只有这些类型的媒体库里才可能有"能刷的短视频"；
 * 音乐/照片/书籍库勾选了也只会是空流，因此在这一行里如实说明。
 */
function libraryHasVideo(collectionType: string): boolean {
  return collectionType === 'movies' || collectionType === 'tvshows' ||
    collectionType === 'homevideos' || collectionType === 'videos' ||
    collectionType === 'mixed' || collectionType === 'boxsets' ||
    collectionType.length === 0;
}

interface LibraryRow {
  id: string;
  name: string;
  collectionType: string;
  type: string;
  /** 该库里是否可能有视频内容（决定副标题是否给出"可能没有短视频"的提醒） */
  hasVideo: boolean;
}

/**
 * 「短视频模式」设置页：选择哪些**媒体库**纳入「视频」页的短视频流。
 *
 * 为什么要有这一页（功能定位）：
 * 用户想"刷"的通常只是某几个库（例如「B站」「短视频」这类库），而不是整个服务器；
 * 把"哪些库属于短视频"做成客户端偏好后，「视频」页就能只在这几个库里随机抽取、
 * 竖屏连播，而不必每次进库、筛选、再点播。
 *
 * 交互：勾选即保存（无"保存"按钮）—— 开关类设置的期望是"立刻生效"，
 * 多一个保存按钮只会带来"我改了但没生效"的困惑；保存走本地偏好（见 `ShortVideoPrefs`）。
 */
@Entry
@Component
export struct ShortVideoSettingsPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private libraries: LibraryRow[] = [];
  @State private selectedIds: string[] = [];
  @State private toast: string = '';
  private toastTimerId: number = -1;

  aboutToAppear(): void {
    this.selectedIds = ShortVideoPrefs.loadLibraryIds();
    this.loadLibraries();
  }

  aboutToDisappear(): void {
    if (this.toastTimerId >= 0) {
      clearTimeout(this.toastTimerId);
      this.toastTimerId = -1;
    }
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /** 拉取服务器上的媒体库列表（`views` 段即 `/Users/{userId}/Views`） */
  private async loadLibraries(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.getHomeSection('views', 60);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取媒体库失败';
      return;
    }
    // `getHomeSection('views')` 返回的是 `/Users/{userId}/Views` 的**原始响应**
    // （顶层就是 `Items`），不是 `{views: {...}}` 包装 —— 用统一的 extractItems 取才拿得到。
    const arr: Object[] = JsonUtil.extractItems(result.data as ESObject);
    const rows: LibraryRow[] = [];
    for (let i = 0; i < arr.length; i++) {
      const view: ESObject = arr[i] as ESObject;
      const id: string = JsonUtil.getString(view, 'Id', '');
      if (id.length === 0) {
        continue;
      }
      const collectionType: string = JsonUtil.getString(view, 'CollectionType', '');
      const type: string = JsonUtil.getString(view, 'Type', '');
      rows.push({
        id: id,
        name: JsonUtil.getString(view, 'Name', '未命名媒体库'),
        collectionType: collectionType,
        type: type,
        hasVideo: libraryHasVideo(collectionType)
      });
    }
    this.libraries = rows;
    this.status = UiState.SUCCESS;
    // 服务器上已删除的库不该继续留在偏好里（否则「视频」页会拉到一个不存在的库）
    const alive: string[] = [];
    for (let i = 0; i < this.selectedIds.length; i++) {
      for (let j = 0; j < rows.length; j++) {
        if (rows[j].id === this.selectedIds[i]) {
          alive.push(this.selectedIds[i]);
          break;
        }
      }
    }
    if (alive.length !== this.selectedIds.length) {
      this.selectedIds = alive;
      ShortVideoPrefs.saveLibraryIds(alive);
    }
  }

  private isSelected(id: string): boolean {
    return this.selectedIds.indexOf(id) >= 0;
  }

  private onToggle(row: LibraryRow, on: boolean): void {
    this.selectedIds = ShortVideoPrefs.withToggled(this.selectedIds, row.id, on);
    ShortVideoPrefs.saveLibraryIds(this.selectedIds);
    this.showToast(on ? `已加入短视频：${row.name}` : `已移出短视频：${row.name}`);
  }

  private showToast(text: string): void {
    if (this.toastTimerId >= 0) {
      clearTimeout(this.toastTimerId);
    }
    this.toast = text;
    this.toastTimerId = setTimeout(() => {
      this.toastTimerId = -1;
      this.toast = '';
    }, 2400);
  }

  private subtitleOf(row: LibraryRow): string {
    const label: string = libraryTypeLabel(row.collectionType, row.type);
    if (!row.hasVideo) {
      return `${label} · 该库通常不含视频，可能刷不到内容`;
    }
    return `${label} · 随机抽取库内影片 / 剧集 / 视频`;
  }

  build() {
    Column() {
      PageHeader({
        title: '短视频模式',
        onBack: () => { router.back(); }
      })

      if (this.status === UiState.LOADING) {
        LoadingState()
      } else if (this.status === UiState.ERROR) {
        EmptyState({
          message: this.errorMsg.length > 0 ? this.errorMsg : '读取媒体库失败',
          actionLabel: '重试',
          onAction: () => { this.loadLibraries(); }
        })
      } else if (this.libraries.length === 0) {
        EmptyState({
          message: '这台服务器上还没有可用的媒体库',
          actionLabel: '',
          onAction: () => {}
        })
      } else {
        Scroll() {
          Column({ space: 14 }) {
            // 说明卡：把"这个设置会改变什么"讲清楚，避免用户不知道勾了会发生什么
            SectionCard({ title: '怎么用', showHeaderIcon: true,
              icon: $r('sys.symbol.play_circle') }) {
              Column({ space: 8 }) {
                Text('勾选后，底部「视频」页会只从这些媒体库里**随机**抽取影片 / 剧集 / 视频，'
                  + '竖屏满屏连播，上下滑动切换。')
                  .fontSize(ThemeConstants.META_MEDIUM)
                  .fontColor(this.colors().textSecondary)
                  .width('100%')
                Text(`已选 ${this.selectedIds.length} 个媒体库`)
                  .fontSize(ThemeConstants.META_SMALL)
                  .fontColor(this.selectedIds.length > 0
                    ? this.colors().brandPrimary : this.colors().textTertiary)
                  .width('100%')
              }
              .width('100%')
              .padding({ left: 16, right: 16, top: 4, bottom: 12 })
            }

            SectionCard({ title: '媒体库', showHeaderIcon: true,
              icon: $r('sys.symbol.rectangle_stack') }) {
              Column() {
                ForEach(this.libraries, (row: LibraryRow, index: number) => {
                  Column() {
                    if (index > 0) {
                      Divider()
                        .color(this.colors().divider)
                        .strokeWidth(0.5)
                        .margin({ left: 16, right: 16 })
                    }
                    SettingCell({
                      title: row.name,
                      subtitle: this.subtitleOf(row),
                      showToggle: true,
                      toggleOn: this.isSelected(row.id),
                      onToggle: (value: boolean) => { this.onToggle(row, value); }
                    })
                  }
                  .width('100%')
                }, (row: LibraryRow) => `${row.id}-${this.isSelected(row.id)}`)
              }
              .width('100%')
            }

            if (this.selectedIds.length === 0) {
              Text('还没有选择任何媒体库 ——「视频」页会显示引导，点「去设置」回到这里。')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textTertiary)
                .width('100%')
                .textAlign(TextAlign.Center)
                .padding({ left: 16, right: 16, bottom: 24 })
            }
          }
          .width('100%')
          .padding({
            left: ThemeConstants.PAGE_PADDING,
            right: ThemeConstants.PAGE_PADDING,
            bottom: 32
          })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }

      // 保存反馈：勾选即保存，这里只做一次轻提示（不阻塞、不需要用户确认）
      if (this.toast.length > 0) {
        Text(this.toast)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().onBrand)
          .backgroundColor(this.colors().brandPrimary)
          .padding({ left: 14, right: 14, top: 8, bottom: 8 })
          .borderRadius(ThemeConstants.BADGE_RADIUS)
          .margin({ bottom: 24 })
          .hitTestBehavior(HitTestMode.None)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
