import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { AppViewModel } from '../viewmodel/AppViewModel';
import display from '@ohos.display';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';

/**
 * HeroBanner — 首页顶部推荐海报横幅，对齐 Jellyfin Web 首页视觉层级。
 * 数据来源：/Users/{userId}/Items?IncludeItemTypes=Movie,Series&Limit=1&SortBy=Random
 */
@Component
export struct HeroBanner {
  @Prop bannerItem: MediaItem = new MediaItem();
  @Prop status: string = UiState.LOADING;
  @Prop errorMsg: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  /** 根据屏幕宽度计算 banner 高度（约 38% 屏幕高度，最大 360dp） */
  private bannerHeight(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const density: number = info.densityPixels > 0 ? info.densityPixels / 160 : 1;
      const screenHeightDp: number = info.height / density;
      return Math.min(360, Math.floor(screenHeightDp * 0.38));
    } catch (_) {
      return 280;
    }
  }

  build() {
    if (this.status === UiState.LOADING) {
      Stack() {
        Column()
          .width('100%')
          .height(this.bannerHeight())
          .backgroundColor(this.colors().surfaceElevated)
        LoadingProgress()
          .width(32)
          .height(32)
          .color(this.colors().primary)
          .position({ x: '50%', y: this.bannerHeight() / 2 })
      }
      .width('100%')
      .height(this.bannerHeight())
    } else {
      // Banner 内容（加载中失败时也渲染空占位）
      if (this.bannerItem.id.length === 0 || this.bannerItem.backdropTag.length === 0) {
        Column()
          .width('100%')
          .height(this.bannerHeight())
          .backgroundColor(this.colors().surfaceElevated)
      } else {
        this.BannerContent()
      }
    }
  }

  @Builder
  BannerContent() {
    Stack({ alignContent: Alignment.BottomStart }) {
      // 背景图
      Image(this.bannerItem.imageUrl(1200, 'Backdrop'))
        .width('100%')
        .height(this.bannerHeight())
        .objectFit(ImageFit.Cover)
        .onError(() => {
          // 背景图加载失败不影响页面
        })

      // 渐变遮罩：底部加深 → 顶部透明
      Column()
        .width('100%')
        .height(this.bannerHeight())
        .linearGradient({
          angle: 180,
          colors: [
            [this.colors().background, 1.0],
            ['#00000000', 0.5],
            ['#000000CC', 1.0]
          ]
        })

      // 底部信息区
      Row() {
        Column({ space: 4 }) {
          Text(this.bannerItem.name)
            .fontSize(ThemeConstants.TITLE_LARGE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().onOverlay)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.bannerItem.metaLine().length > 0) {
            Text(this.bannerItem.metaLine())
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onOverlayMuted)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        .margin({ left: 20, bottom: 16 })

        // 播放按钮
        Button() {
          SymbolGlyph($r('sys.symbol.play'))
            .fontSize(24)
            .fontColor([this.colors().onPrimary])
        }
          .width(52)
          .height(52)
          .backgroundColor(this.colors().primary)
          .borderRadius(26)
          .margin({ right: 16, bottom: 16 })
          .onClick(() => {
            router.pushUrl({
              url: 'pages/DetailPage',
              params: { itemId: this.bannerItem.id }
            });
          })
      }
      .width('100%')
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .height(this.bannerHeight())
    .onClick(() => {
      if (this.bannerItem.id.length > 0) {
        router.pushUrl({
          url: 'pages/DetailPage',
          params: { itemId: this.bannerItem.id }
        });
      }
    })
  }
}

/** 异步加载 HeroBanner 数据的状态容器 */
@Component
export struct HeroBannerLoader {
  onBannerTap: () => void = () => {};

  @State private bannerItem: MediaItem = new MediaItem();
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';

  aboutToAppear(): void {
    this.loadBanner();
  }

  private async loadBanner(): Promise<void> {
    this.status = UiState.LOADING;
    const query: ItemsQueryOptions = new ItemsQueryOptions();
    query.includeItemTypes = 'Movie,Series';
    query.limit = 1;
    query.sortBy = 'Random';
    query.fields = 'Overview,CommunityRating,RunTimeTicks,ProductionYear,Genres,BackdropImageTags';
    const raw: string = await JellyfinNative.queryItems(query.toJson());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '加载失败';
      return;
    }
    const items: Object[] = JsonUtil.extractItems(result.data);
    if (items.length > 0) {
      const item: MediaItem = MediaItem.fromJson(items[0]);
      if (item.id.length > 0 && item.backdropTag.length > 0) {
        this.bannerItem = item;
        this.status = UiState.SUCCESS;
        return;
      }
    }
    this.status = UiState.ERROR;
    this.errorMsg = '暂无推荐内容';
  }

  build() {
    HeroBanner({
      bannerItem: this.bannerItem,
      status: this.status,
      errorMsg: this.errorMsg
    })
  }
}
