import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { LibraryOptionSet } from '../../common/LibraryModels';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 一个用户可见的媒体库视图（`GET /Users/{id}/Views` 的一项） */
class ViewEntry {
  id: string = '';
  name: string = '';
  collectionType: string = '';
}

/** 多选浮层的作用对象 */
const SHEET_LATEST = 'latest';
const SHEET_MYMEDIA = 'mymedia';
const SHEET_GROUPED = 'grouped';

/**
 * 设置 → 首页与媒体库。
 *
 * 这些都是**用户级**配置（`UserConfiguration`，经 `POST /Users/{userId}/Configuration` 保存），
 * 对应 jellyfin-web 用户设置里的 Home 一栏：
 * - `OrderedViews`          媒体库在首页/媒体库列表里的顺序
 * - `LatestItemsExcludes`   「最新添加」里不出现的媒体库
 * - `MyMediaExcludes`       「我的媒体」里不出现的媒体库
 * - `GroupedFolders`        合并成一个入口显示的媒体库
 * - `DisplayCollectionsView` 是否把合集作为独立入口显示
 *
 * 保存走 `patchUserConfiguration`（原生侧 GET → 合并 → POST 完整配置）：
 * 服务端是整体替换语义，少带字段就会把那些字段重置成默认值。
 */
@Entry
@Component
struct HomeSettingsPage {
  private base: LibraryOptionSet = new LibraryOptionSet(null);

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  @State private views: ViewEntry[] = [];
  @State private ordered: string[] = [];
  /**
   * 载入时的顺序基线（对齐过的完整顺序）。
   *
   * 为什么要单独存一份：服务端的 `OrderedViews` 允许只列一部分视图（没列到的按默认顺序排在后面），
   * 而界面必须拿一条完整顺序才能做"上移/下移"。如果直接拿原始 `OrderedViews` 当基线比较，
   * 一进页面就会显示"有未保存的修改"。用对齐后的顺序当基线，才是"用户真的动过"。
   */
  @State private orderBaseline: string[] = [];
  @State private latestExcludes: string[] = [];
  @State private myMediaExcludes: string[] = [];
  @State private groupedFolders: string[] = [];
  @State private collectionsView: boolean = false;

  @State private sheet: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';

    const viewsRaw: string = await JellyfinNative.getUserViews();
    const viewsResult: NativeResult = JellyfinNative.parseResult(viewsRaw);
    if (!viewsResult.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = viewsResult.message.length > 0 ? viewsResult.message : '读取媒体库列表失败';
      return;
    }
    this.views = HomeSettingsPage.parseViews(viewsResult.data);

    const userRaw: string = await JellyfinNative.getUserById(this.userId());
    const userResult: NativeResult = JellyfinNative.parseResult(userRaw);
    if (!userResult.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = userResult.message.length > 0 ? userResult.message : '读取用户配置失败';
      return;
    }
    const config: ESObject | null = JsonUtil.getObject(userResult.data, 'Configuration');
    this.base = new LibraryOptionSet(config);
    this.ordered = this.base.getStringArray('OrderedViews');
    this.latestExcludes = this.base.getStringArray('LatestItemsExcludes');
    this.myMediaExcludes = this.base.getStringArray('MyMediaExcludes');
    this.groupedFolders = this.base.getStringArray('GroupedFolders');
    this.collectionsView = this.base.getBool('DisplayCollectionsView', false);
    this.reconcileOrder();
    this.orderBaseline = this.ordered.slice();
    this.status = UiState.SUCCESS;
  }

  private userId(): string {
    const raw: string = JellyfinNative.getSession();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (result.ok && result.data !== null) {
      return JsonUtil.getString(result.data as ESObject, 'userId',
        JsonUtil.getString(result.data as ESObject, 'UserId', ''));
    }
    return '';
  }

  private static parseViews(data: ESObject | null): ViewEntry[] {
    const out: ViewEntry[] = [];
    const items: Object[] = JsonUtil.extractItems(data);
    for (let i = 0; i < items.length; i++) {
      const src: ESObject = items[i] as ESObject;
      const id: string = JsonUtil.getString(src, 'Id', '');
      if (id.length === 0) {
        continue;
      }
      const entry: ViewEntry = new ViewEntry();
      entry.id = id;
      entry.name = JsonUtil.getString(src, 'Name', '未命名媒体库');
      entry.collectionType = JsonUtil.getString(src, 'CollectionType', '');
      out.push(entry);
    }
    return out;
  }

  /**
   * 把 `OrderedViews` 与当前视图列表对齐：
   * 服务端允许这个列表**只包含部分视图**（没列到的按默认顺序排在后面），
   * 但界面要做"上移/下移"，必须拿到一条包含全部视图的完整顺序，
   * 所以这里把缺失的视图按服务器返回的顺序补到末尾。
   */
  private reconcileOrder(): void {
    const next: string[] = [];
    for (let i = 0; i < this.ordered.length; i++) {
      if (this.findView(this.ordered[i]) !== null && next.indexOf(this.ordered[i]) < 0) {
        next.push(this.ordered[i]);
      }
    }
    for (let i = 0; i < this.views.length; i++) {
      if (next.indexOf(this.views[i].id) < 0) {
        next.push(this.views[i].id);
      }
    }
    this.ordered = next;
  }

  private findView(id: string): ViewEntry | null {
    for (let i = 0; i < this.views.length; i++) {
      if (this.views[i].id === id) {
        return this.views[i];
      }
    }
    return null;
  }

  private viewName(id: string): string {
    const view: ViewEntry | null = this.findView(id);
    return view !== null ? view.name : id;
  }

  private viewSubtitle(id: string): string {
    const view: ViewEntry | null = this.findView(id);
    return view !== null ? view.collectionType : '';
  }

  private isOrderChanged(): boolean {
    return !HomeSettingsPage.sameList(this.orderBaseline, this.ordered);
  }

  private isDirty(): boolean {
    return this.isOrderChanged()
      || !HomeSettingsPage.sameList(this.base.getStringArray('LatestItemsExcludes'), this.latestExcludes)
      || !HomeSettingsPage.sameList(this.base.getStringArray('MyMediaExcludes'), this.myMediaExcludes)
      || !HomeSettingsPage.sameList(this.base.getStringArray('GroupedFolders'), this.groupedFolders)
      || this.base.getBool('DisplayCollectionsView', false) !== this.collectionsView;
  }

  private static sameList(a: string[], b: string[]): boolean {
    if (a.length !== b.length) {
      return false;
    }
    for (let i = 0; i < a.length; i++) {
      if (a[i] !== b[i]) {
        return false;
      }
    }
    return true;
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    const patch: Record<string, Object> = {};
    patch['OrderedViews'] = this.ordered;
    patch['LatestItemsExcludes'] = this.latestExcludes;
    patch['MyMediaExcludes'] = this.myMediaExcludes;
    patch['GroupedFolders'] = this.groupedFolders;
    patch['DisplayCollectionsView'] = this.collectionsView;
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.patchUserConfiguration(JSON.stringify(patch)));
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = '已保存';
    this.load();
  }

  private move(index: number, delta: number): void {
    const target: number = index + delta;
    if (target < 0 || target >= this.ordered.length) {
      return;
    }
    const next: string[] = this.ordered.slice();
    const tmp: string = next[index];
    next[index] = next[target];
    next[target] = tmp;
    this.ordered = next;
    this.actionMessage = '';
  }

  private contains(list: string[], id: string): boolean {
    return list.indexOf(id) >= 0;
  }

  private toggleIn(list: string[], id: string, on: boolean): string[] {
    const next: string[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i] !== id) {
        next.push(list[i]);
      }
    }
    if (on) {
      next.push(id);
    }
    return next;
  }

  private sheetTitle(): string {
    if (this.sheet === SHEET_LATEST) {
      return '「最新添加」里隐藏哪些媒体库';
    }
    if (this.sheet === SHEET_MYMEDIA) {
      return '「我的媒体」里隐藏哪些媒体库';
    }
    return '哪些媒体库合并成一个入口';
  }

  private sheetHint(): string {
    if (this.sheet === SHEET_LATEST) {
      return '勾选后，这些媒体库的新内容不会出现在首页的「最新添加」里。';
    }
    if (this.sheet === SHEET_MYMEDIA) {
      return '勾选后，这些媒体库不会出现在「我的媒体」区域。';
    }
    return '勾选后，这些媒体库会合并显示成一个入口（适合"电影 + 4K 电影"这类拆分存放的库）。';
  }

  private sheetSelected(): string[] {
    if (this.sheet === SHEET_LATEST) {
      return this.latestExcludes;
    }
    if (this.sheet === SHEET_MYMEDIA) {
      return this.myMediaExcludes;
    }
    return this.groupedFolders;
  }

  private applySheetSelection(id: string, on: boolean): void {
    if (this.sheet === SHEET_LATEST) {
      this.latestExcludes = this.toggleIn(this.latestExcludes, id, on);
    } else if (this.sheet === SHEET_MYMEDIA) {
      this.myMediaExcludes = this.toggleIn(this.myMediaExcludes, id, on);
    } else {
      this.groupedFolders = this.toggleIn(this.groupedFolders, id, on);
    }
    this.actionMessage = '';
  }

  private selectionSummary(list: string[], allLabel: string): string {
    if (list.length === 0) {
      return allLabel;
    }
    const names: string[] = [];
    for (let i = 0; i < list.length; i++) {
      names.push(this.viewName(list[i]));
    }
    return names.join('、');
  }

  @Builder
  OrderRow(id: string, index: number) {
    Row({ space: 8 }) {
      Text(`${index + 1}`)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().onBrand)
        .width(24)
        .height(24)
        .textAlign(TextAlign.Center)
        .backgroundColor(this.colors().brandPrimary)
        .borderRadius(12)
      Column({ space: 2 }) {
        Text(this.viewName(id))
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textPrimary)
        if (this.viewSubtitle(id).length > 0) {
          Text(this.viewSubtitle(id))
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textTertiary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)

      // 上移/下移：系统符号里没有 chevron_up（只有 chevron_down），这里直接用箭头字形，
      // 并用透明度表达"已经在头/尾，不能再移"
      Text('▲')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(index === 0 ? this.colors().textTertiary : this.colors().brandPrimary)
        .padding(8)
        .onClick(() => {
          this.move(index, -1);
        })
      Text('▼')
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(index === this.ordered.length - 1
          ? this.colors().textTertiary : this.colors().brandPrimary)
        .padding(8)
        .margin({ left: 4 })
        .onClick(() => {
          this.move(index, 1);
        })
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  @Builder
  MultiSelectSheet() {
    Column({ space: 10 }) {
      Text(this.sheetTitle())
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(this.sheetHint())
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      List({ space: 2 }) {
        ForEach(this.views, (view: ViewEntry) => {
          ListItem() {
            Row({ space: 8 }) {
              Column({ space: 2 }) {
                Text(view.name)
                  .fontSize(ThemeConstants.BODY_MEDIUM)
                  .fontColor(this.colors().textPrimary)
                if (view.collectionType.length > 0) {
                  Text(view.collectionType)
                    .fontSize(ThemeConstants.META_SMALL)
                    .fontColor(this.colors().textTertiary)
                }
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              Checkbox()
                .select(this.contains(this.sheetSelected(), view.id))
                .selectedColor(this.colors().brandPrimary)
                .onChange((value: boolean) => {
                  this.applySheetSelection(view.id, value);
                })
            }
            .width('100%')
            .padding({ top: 8, bottom: 8 })
          }
        }, (view: ViewEntry) => `${view.id}-${this.contains(this.sheetSelected(), view.id) ? 1 : 0}`)
      }
      .width('100%')
      .height(300)
      .scrollBar(BarState.Auto)
      Button('完成')
        .width('100%')
        .height(44)
        .backgroundColor(this.colors().brandPrimary)
        .fontColor(this.colors().onBrand)
        .onClick(() => {
          this.sheet = '';
        })
    }
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .width('88%')
    .onClick(() => {
    })
  }

  @Builder
  Body() {
    Scroll() {
      Column() {
        SectionCard({ title: '媒体库顺序', icon: $r('sys.symbol.list_bullet'),
          showHeaderIcon: true }) {
          Column() {
            if (this.views.length === 0) {
              Text('这台服务器上还没有任何媒体库。')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textSecondary)
                .width('100%')
                .padding(ThemeConstants.PAGE_PADDING)
            } else {
              ForEach(this.ordered, (id: string, index: number) => {
                this.OrderRow(id, index)
              }, (id: string) => `${id}-${this.ordered.indexOf(id)}`)
            }
          }
          .width('100%')
        }

        SectionCard({ title: '首页', icon: $r('sys.symbol.rectangle_stack'), showHeaderIcon: true }) {
          Column() {
            SettingCell({
              title: '显示合集入口',
              subtitle: '把合集作为一个独立的媒体库入口显示',
              showToggle: true,
              toggleOn: this.collectionsView,
              onToggle: (value: boolean) => {
                this.collectionsView = value;
                this.actionMessage = '';
              }
            })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            SettingCell({
              title: '「最新添加」里隐藏',
              subtitle: '这些媒体库的新内容不出现在首页「最新添加」',
              valueText: this.selectionSummary(this.latestExcludes, '全部显示'),
              showIcon: true,
              icon: $r('sys.symbol.doc_text'),
              showChevron: true,
              onTap: () => {
                this.sheet = SHEET_LATEST;
              }
            })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            SettingCell({
              title: '「我的媒体」里隐藏',
              subtitle: '这些媒体库不出现在「我的媒体」区域',
              valueText: this.selectionSummary(this.myMediaExcludes, '全部显示'),
              showIcon: true,
              icon: $r('sys.symbol.square_grid_2x2'),
              showChevron: true,
              onTap: () => {
                this.sheet = SHEET_MYMEDIA;
              }
            })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            SettingCell({
              title: '合并显示的媒体库',
              subtitle: '把多个媒体库合并成一个入口（如"电影"与"4K 电影"）',
              valueText: this.selectionSummary(this.groupedFolders, '不合并'),
              showIcon: true,
              icon: $r('sys.symbol.circle_grid_2x2'),
              showChevron: true,
              onTap: () => {
                this.sheet = SHEET_GROUPED;
              }
            })
          }
          .width('100%')
        }

        Text('这些是你账号在服务器上的偏好，换个客户端登录同一个账号也会生效；'
          + '它不影响服务器上媒体库本身的配置。')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textTertiary)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 4 })

        Blank().height(80)
      }
      .width('100%')
      .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '首页与媒体库',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('账号级偏好（跟随账号同步到其它客户端）')
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
          this.Body()
          Row({ space: 10 }) {
            Button('保存')
              .layoutWeight(1)
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

      if (this.sheet.length > 0) {
        Column() {
          this.MultiSelectSheet()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.sheet = '';
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
