import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { WindowLayout } from '../common/WindowLayout';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { MediaItem } from '../models/MediaItem';
import { PageHeader } from '../components/PageHeader';
import { AsyncStateView } from '../components/AsyncStateView';
import { JellyfinImage } from '../components/JellyfinImage';
import { MediaCollectionView } from '../components/MediaCollectionView';
import { SectionHeader } from '../components/SectionHeader';
import { EmptyState } from '../components/EmptyState';

@Entry
@Component
struct PersonPage {
  @State private personId: string = '';
  /** 由详情页传入的姓名：有它就能立即渲染头部，不必请求会在部分服务器上挂起的人物详情端点 */
  @State private personNameFromParams: string = '';
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private person: MediaItem = new MediaItem();
  @State private works: MediaItem[] = [];
  @State private worksStatus: string = UiState.LOADING;
  @State private worksError: string = '';

  aboutToAppear(): void {
    const params: Object | undefined = router.getParams();
    if (params !== undefined && params !== null) {
      const bag: ESObject = params as ESObject;
      const idVal: string | undefined = bag['personId'] as string | undefined;
      if (idVal !== undefined && idVal.length > 0) {
        this.personId = idVal;
      }
      const nameVal: string | undefined = bag['personName'] as string | undefined;
      if (nameVal !== undefined && nameVal.length > 0) {
        this.personNameFromParams = nameVal;
        // 先用传入的姓名把页面渲染出来，避免头部空着等接口
        this.person.name = nameVal;
      }
    }
    // 必须捕获异常：原来直接 `this.load()`，任何异常都会让页面永远停在"加载中…"，
    // 既看不到错误也没有重试入口（设备实测：人物页一直显示加载中的根因）
    this.load().catch((err: Error) => {
      const msg: string = err.message.length > 0 ? err.message : '未知错误';
      this.status = UiState.ERROR;
      this.errorMsg = `加载人物信息失败：${msg}`;
      this.worksStatus = UiState.ERROR;
      this.worksError = msg;
    });
  }

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private async load(): Promise<void> {
    if (this.personId.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '缺少人物 ID';
      return;
    }
    this.status = UiState.LOADING;
    this.worksStatus = UiState.LOADING;
    this.worksError = '';
    // 有传入姓名时不再请求人物详情：实测部分 Jellyfin 版本对
    // `/Users/{uid}/Items/{personId}` 会**挂起不响应**（curl 12s 无响应，同一服务器取影片详情仅 47ms），
    // 请求它只会让页面卡在加载态；姓名与头像已能从详情页的演职人员数据里带过来。
    if (this.personNameFromParams.length === 0) {
      const raw: string = await JellyfinNative.getItemDetail(this.personId);
      const result: NativeResult = JellyfinNative.parseResult(raw);
      if (!result.ok || result.data === null) {
        this.status = UiState.ERROR;
        this.errorMsg = result.message.length > 0 ? result.message : '加载人物信息失败';
        return;
      }
      this.person = MediaItem.fromJson(result.data);
    }
    const query: ItemsQueryOptions = new ItemsQueryOptions();
    query.personIds = this.personId;
    query.includeItemTypes = 'Movie,Series,Episode,Audio';
    query.recursive = true;
    query.limit = 100;
    query.sortBy = 'PremiereDate';
    query.sortOrder = 'Descending';
    const queryRaw: string = await JellyfinNative.queryItems(query.toJson());
    const worksResult: NativeResult = JellyfinNative.parseResult(queryRaw);
    if (worksResult.ok) {
      const mapped: MediaItem[] = MediaItem.fromArray(JsonUtil.extractItems(worksResult.data));
      const filtered: MediaItem[] = [];
      for (let i = 0; i < mapped.length; i++) {
        if (mapped[i].id !== this.personId) {
          filtered.push(mapped[i]);
        }
      }
      this.works = filtered;
      this.worksStatus = filtered.length > 0 ? UiState.SUCCESS : UiState.EMPTY;
    } else {
      this.works = [];
      this.worksStatus = UiState.ERROR;
      this.worksError = worksResult.message.length > 0 ? worksResult.message : '加载作品失败';
    }
    this.status = UiState.SUCCESS;
  }

  @Builder
  PersonHeader() {
    Row({ space: 16 }) {
      JellyfinImage({
        url: this.person.imageUrl(400, 'Primary'),
        imgWidth: 100,
        imgHeight: 140,
        cornerRadius: ThemeConstants.POSTER_RADIUS,
        placeholderIcon: 'person'
      })
      Column({ space: 6 }) {
        Text(this.person.name)
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (this.person.year.length > 0) {
          Text(`出生年份：${this.person.year}`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
        }
        if (this.person.overview.length > 0) {
          Text(this.person.overview)
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontColor(this.colors().textSecondary)
            .lineHeight(21)
            .maxLines(5)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .width('100%')
    .padding(16)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  WorksContent() {
    Column() {
      SectionHeader({ title: $r('app.string.person_works'), icon: '' })
      if (this.worksStatus === UiState.LOADING) {
        AsyncStateView({ status: UiState.LOADING, minHeight: 120 })
      } else if (this.worksStatus === UiState.ERROR) {
        AsyncStateView({
          status: UiState.ERROR,
          message: this.worksError,
          minHeight: 120,
          onRetry: () => {
            this.load();
          }
        })
      } else if (this.worksStatus === UiState.EMPTY) {
        // 空数据走参考项目 EmptyState（原来是一行手写提示文字）
        Column() {
          EmptyState({
            message: $r('app.string.person_no_works'),
            icon: $r('sys.symbol.video')
          })
        }
        .width('100%')
        .padding({ bottom: 24 })
      } else {
        MediaCollectionView({
          items: $works,
          viewMode: 'grid',
          hasMore: false,
          columns: WindowLayout.gridColumns(),
          onItemTap: (item: MediaItem) => {
            router.pushUrl({ url: 'pages/DetailPage', params: { itemId: item.id } });
          }
        })
        .height(Math.max(260, Math.ceil(this.works.length / WindowLayout.gridColumns()) * 230 + 24))
      }
    }
    .width('100%')
  }

  build() {
    Column() {
      PageHeader({
        title: this.person.name.length > 0 ? this.person.name : $r('app.string.person_title'),
        onBack: () => {
          router.back();
        }
      })

      if (this.status !== UiState.SUCCESS) {
        AsyncStateView({
          status: this.status,
          message: this.errorMsg,
          minHeight: 240,
          onRetry: () => {
            this.load();
          }
        })
      } else {
        Scroll() {
          Column() {
            this.PersonHeader()
            this.WorksContent()
          }
          .width('100%')
          .padding({ bottom: 32 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Off)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().background)
  }
}
