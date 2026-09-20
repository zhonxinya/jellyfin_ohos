import router from '@ohos.router';
import hilog from '@ohos.hilog';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { MediaItem } from '../models/MediaItem';
import { AppViewModel } from '../viewmodel/AppViewModel';
import display from '@ohos.display';
import { ItemsQueryOptions } from '../common/ItemsQueryOptions';

const HERO_DOMAIN: number = 0x0000;
const HERO_TAG: string = 'JellyfinHero';

/**
 * HeroBanner —— 首页顶部推荐横幅。
 *
 * 视觉规则对齐 mybooks_ohos：
 * - 遮罩只用令牌，不写死 `#000000CC`，也修掉过原实现"两个 1.0 停靠点 + `background` 放错位置"的渐变 bug；
 * - 叠加在图片上的文字硬编码白色系（`onOverlay` / `onOverlayMuted`）——`on_brand` 在深色主题
 *   会翻成近黑，不能用在图片上；
 * - 加载态用 48vp 品牌色 `LoadingProgress`，占位底色用卡片色。
 *
 * 本轮改动（需求：**移除明显的播放按钮**、**可以滑动切换推荐作品**）：
 * 1. **不再放 48vp 品牌色按钮**。原来那个按钮写的是「播放」、点击却是跳详情页
 *    （文案与行为不符），而且它是整块横幅里最抢眼的元素 —— 推荐位的任务是"吸引点进去看"，
 *    不是让人在首页直接起播。现在**整块横幅可点**（进该条详情），动作与视觉一致；
 * 2. **横向滑动切换**：数据从 1 条改成一批（`limit=6`），用 `Swiper` 一屏一条，
 *    右下角给分页圆点（正好落在原按钮的位置，不与左侧标题抢空间）。
 *    首页外层是纵向 `Scroll`，横滑与之不冲突。
 *
 * 数据来源：/Users/{userId}/Items?IncludeItemTypes=Movie,Series&Limit=6&SortBy=Random
 */
@Component
export struct HeroBanner {
  /** 推荐条目（多条时可横向滑动切换） */
  @Prop items: MediaItem[] = [];
  @Prop status: string = UiState.LOADING;
  @Prop errorMsg: string = '';
  /** 当前显示第几条（分页圆点与"点开的是哪一条"都按它走） */
  @State private currentIndex: number = 0;

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
    return this.items.length > 0 && this.items[0].id.length > 0;
  }

  private openDetail(item: MediaItem): void {
    if (item.id.length === 0) {
      return;
    }
    router.pushUrl({
      url: 'pages/DetailPage',
      params: { itemId: item.id }
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
    Swiper() {
      ForEach(this.items, (item: MediaItem) => {
        this.BannerSlide(item)
      }, (item: MediaItem) => item.id)
    }
    .autoPlay(false)
    .loop(false)
    .index(this.currentIndex)
    .onChange((index: number) => {
      this.currentIndex = index;
    })
    // 分页圆点：有圆点用户才知道这里可以滑；放右下角（原按钮的位置）
    .indicator(Indicator.dot()
      .itemWidth(6)
      .itemHeight(6)
      .selectedItemWidth(16)
      .selectedItemHeight(6)
      .color(this.colors().onOverlayMuted)
      .selectedColor(this.colors().onOverlay)
      .right(ThemeConstants.PAGE_PADDING)
      .bottom(12))
    .width('100%')
    .height(this.bannerHeight())
  }

  /**
   * 单条推荐：背景图 + 渐变遮罩 + 标题/元信息。
   *
   * **没有播放按钮**（见文件头说明）：整块区域可点，进入该条详情页。
   */
  @Builder
  BannerSlide(item: MediaItem) {
    Stack({ alignContent: Alignment.BottomStart }) {
      Image(item.imageUrl(1200, 'Backdrop'))
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

      Column({ space: 4 }) {
        Text(item.name)
          .fontSize(ThemeConstants.TITLE_XLARGE)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.colors().onOverlay)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        if (item.metaLine().length > 0) {
          Text(item.metaLine())
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().onOverlayMuted)
            .maxLines(1)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      // 右侧让出分页圆点的位置（圆点在右下角，标题不该压上去）
      .padding({ left: ThemeConstants.PAGE_PADDING, right: 64, bottom: 20 })
      .width('100%')
    }
    .width('100%')
    .height(this.bannerHeight())
    .onClick(() => {
      this.openDetail(item);
    })
  }
}

/** 异步加载 HeroBanner 数据的状态容器 */
@Component
export struct HeroBannerLoader {
  onBannerTap: () => void = () => {};

  /**
   * 展示几条推荐。
   *
   * 为什么是 6 条而不是 1 条：需求要"滑动切换推荐作品"，至少得够滑几下；
   * 也不宜太多 —— 每条背景图都要下载，而这是首页首屏最贵的一批图。
   */
  private static readonly SLIDE_COUNT: number = 6;

  @State private items: MediaItem[] = [];
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';

  aboutToAppear(): void {
    this.loadBanner();
  }

  private async loadBanner(): Promise<void> {
    this.status = UiState.LOADING;
    const query: ItemsQueryOptions = new ItemsQueryOptions();
    query.includeItemTypes = 'Movie,Series';
    query.limit = HeroBannerLoader.SLIDE_COUNT;
    query.sortBy = 'Random';
    query.fields = 'Overview,CommunityRating,RunTimeTicks,ProductionYear,Genres,BackdropImageTags';
    // 本地随机抽样：不让服务端执行 SortBy=Random。
    // 原因见 `ItemsQueryOptions.randomSamplePoolSize` —— 服务端那个比较器不自洽，
    // 会随机抛 400，表现就是"首页推荐偶尔整个消失"。
    query.randomSamplePoolSize = 60;
    const raw: string = await JellyfinNative.queryItems(query.toJson());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      // 走到这里已经是异常路径（没了服务端 Random 排序，理论上不该再有 400）。
      // 仍然保留一次同参数重试：网络抖动、服务端重启之类的瞬时失败也能自愈，
      // 不必等用户下拉刷新 —— 推荐位消失一整轮是很显眼的回归。
      const retryRaw: string = await JellyfinNative.queryItems(query.toJson());
      const retry: NativeResult = JellyfinNative.parseResult(retryRaw);
      if (!retry.ok) {
        hilog.warn(HERO_DOMAIN, HERO_TAG,
          'loadBanner failed twice: code=%{public}d msg=%{public}s', retry.code, retry.message);
        this.status = UiState.ERROR;
        this.errorMsg = retry.message.length > 0 ? retry.message : '加载失败';
        return;
      }
      this.applyItems(retry);
      return;
    }
    this.applyItems(result);
  }

  /**
   * 把查询结果落成横幅数据。
   *
   * 只保留**有横图（Backdrop）**的条目 —— 否则滑到那一条是纯色块，观感很差。
   * 注意：本地抽样池（60 条）里可能含少量无横图条目，抽样后剩几条就展示几条，
   * 不再回补 —— 回补需要再发请求，而"少一条"远好过"多一次网络往返"。
   */
  private applyItems(result: NativeResult): void {
    const rawItems: Object[] = JsonUtil.extractItems(result.data);
    const keep: MediaItem[] = [];
    for (let i = 0; i < rawItems.length; i++) {
      const item: MediaItem = MediaItem.fromJson(rawItems[i]);
      if (item.id.length > 0 && item.backdropTag.length > 0) {
        keep.push(item);
      }
    }
    if (keep.length === 0) {
      hilog.warn(HERO_DOMAIN, HERO_TAG, 'no items with backdrop in %{public}d candidates',
        rawItems.length);
      this.items = [];
      this.status = UiState.ERROR;
      this.errorMsg = '暂无推荐内容';
      return;
    }
    this.items = keep;
    this.status = UiState.SUCCESS;
  }

  build() {
    HeroBanner({
      items: this.items,
      status: this.status,
      errorMsg: this.errorMsg
    })
  }
}
