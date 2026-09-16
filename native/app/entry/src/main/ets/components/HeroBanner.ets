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
 * HeroBanner —— 首页顶部推荐横幅，视觉规则已按 mybooks_ohos 重做。
 *
 * 与参考项目一致的要点：
 * - 遮罩只用令牌，不再写死 `#000000CC`，也修掉了原实现"两个 1.0 停靠点 + `background` 放错位置"的渐变 bug；
 * - 叠加在图片上的文字硬编码白色系（`onOverlay` / `onOverlayMuted`）——参考项目的明确约定：
 *   `on_brand` 在深色主题会翻成近黑，不能用在图片上；
 * - 主操作由 52vp 圆形 FAB 改为参考项目按钮规格：**48vp 高、12vp 圆角（不是胶囊）、品牌色实底 + `onBrand` 文字**；
 * - 加载态用 48vp 品牌色 `LoadingProgress`（参考项目 LoadingState 尺寸），占位底色用卡片色。
 *
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

  /** banner 高度：约 34% 屏幕高，最大 320vp（原实现因密率换算错误恒为 360vp） */
  private bannerHeight(): number {
    try {
      const info: display.Display = display.getDefaultDisplaySync();
      const density: number = info.densityPixels > 0 ? info.densityPixels : 1;
      const screenHeightVp: number = info.height / density;
      return Math.min(320, Math.floor(screenHeightVp * 0.34));
    } catch (_) {
      return 260;
    }
  }

  private hasContent(): boolean {
    return this.bannerItem.id.length > 0 && this.bannerItem.backdropTag.length > 0;
  }

  private openDetail(): void {
    if (this.bannerItem.id.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/DetailPage',
      params: { itemId: this.bannerItem.id }
    });
  }

  build() {
    if (this.status === UiState.LOADING) {
      Stack() {
        Column()
          .width('100%')
          .height(this.bannerHeight())
          .backgroundColor(this.colors().cardBackground)
        LoadingProgress()
          .width(48)
          .height(48)
          .color(this.colors().brandPrimary)
      }
      .width('100%')
      .height(this.bannerHeight())
    } else if (!this.hasContent()) {
      Column()
        .width('100%')
        .height(this.bannerHeight())
        .backgroundColor(this.colors().cardBackground)
    } else {
      this.BannerContent()
    }
  }

  @Builder
  BannerContent() {
    Stack({ alignContent: Alignment.BottomStart }) {
      Image(this.bannerItem.imageUrl(1200, 'Backdrop'))
        .width('100%')
        .height(this.bannerHeight())
        .objectFit(ImageFit.Cover)
        .onError(() => {
          // 背景图加载失败不影响其余内容
        })

      // 顶部透明 → 底部压暗 → 收进页面底色，避免与下方内容出现硬边
      Column()
        .width('100%')
        .height(this.bannerHeight())
        .linearGradient({
          angle: 180,
          colors: [
            ['#00000000', 0.0],
            ['#00000000', 0.45],
            [this.colors().posterScrim, 0.82],
            [this.colors().pageBackground, 1.0]
          ]
        })

      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text(this.bannerItem.name)
            .fontSize(ThemeConstants.TITLE_XLARGE)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.colors().onOverlay)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
          if (this.bannerItem.metaLine().length > 0) {
            Text(this.bannerItem.metaLine())
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onOverlayMuted)
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        Button({ type: ButtonType.Normal, stateEffect: false }) {
          Row({ space: 6 }) {
            SymbolGlyph($r('sys.symbol.play'))
              .fontSize(ThemeConstants.ICON_MEDIUM)
              .fontColor([this.colors().onBrand])
            Text('播放')
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontWeight(FontWeight.Medium)
              .fontColor(this.colors().onBrand)
          }
          .alignItems(VerticalAlign.Center)
        }
        .height(ThemeConstants.BUTTON_HEIGHT)
        .padding({ left: 18, right: 18 })
        .backgroundColor(this.colors().brandPrimary)
        .borderRadius(ThemeConstants.BUTTON_RADIUS)
        .stateStyles({
          pressed: {
            .backgroundColor(this.colors().brandPrimaryPressed)
          }
        })
        .onClick(() => {
          this.openDetail();
        })
      }
      .width('100%')
      .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 20 })
      .alignItems(VerticalAlign.Bottom)
    }
    .width('100%')
    .height(this.bannerHeight())
    .onClick(() => {
      this.openDetail();
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
