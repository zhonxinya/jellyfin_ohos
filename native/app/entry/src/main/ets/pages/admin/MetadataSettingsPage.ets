import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { ChipButton } from '../../components/ChipButton';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 一个"条目类型"（Movie / Series / …）的抓取器开关 */
class ItemTypeState {
  type: string = '';
  /** 服务端配置里是否已经有这个类型的条目（没有就用 AvailableOptions 的默认值） */
  configured: boolean = false;
  metadataFetchers: CheckItem[] = [];
  imageFetchers: CheckItem[] = [];
}

/** 一个可勾选项 */
class CheckItem {
  name: string = '';
  enabled: boolean = false;

  constructor(name: string, enabled: boolean) {
    this.name = name;
    this.enabled = enabled;
  }
}

/** 保存器（全局一份，但服务端是按条目类型存的，所以会有"部分启用"） */
class SaverItem {
  name: string = '';
  enabled: boolean = false;
  partial: boolean = false;
}

/** 条目类型的展示名 */
function itemTypeLabel(type: string): string {
  if (type === 'Movie') return '电影';
  if (type === 'Series') return '剧集';
  if (type === 'Season') return '季';
  if (type === 'Episode') return '集';
  if (type === 'Video') return '视频';
  if (type === 'MusicVideo') return '音乐视频';
  if (type === 'MusicArtist') return '音乐艺术家';
  if (type === 'MusicAlbum') return '音乐专辑';
  if (type === 'Audio') return '音频';
  if (type === 'Photo') return '照片';
  if (type === 'BoxSet') return '合集';
  if (type === 'Book') return '书籍';
  if (type === 'Playlist') return '播放列表';
  return type;
}

/**
 * 设置 → 媒体库元数据（服务器级元数据设置）。
 *
 * 对应 jellyfin-web 的 Dashboard → Metadata：决定**服务器默认**用哪些抓取器，
 * 以及它们的优先顺序。单个媒体库可以在自己的「媒体库选项」里覆盖这些默认值；
 * 那个覆盖用的就是这一页的默认值（服务端 `IsMetadataFetcherEnabled` 在库里没有
 * `TypeOptions` 条目时回落到这里）。
 *
 * 服务端语义（`MetadataOptions` + `ProviderManager`）：
 * - 每个条目类型一条记录，字段是**禁用列表**（`DisabledMetadataFetchers` /
 *   `DisabledImageFetchers` / `DisabledMetadataSavers`）+ **顺序列表**；
 * - 保存器是"按条目类型禁用"的，所以可能出现"某些类型禁了、某些没禁"的中间状态，
 *   界面用「部分类型已禁用」如实标出，而不是假装只有开/关两态；
 * - 读写走**整份** ServerConfiguration（`GET/POST /System/Configuration`）：
 *   keyed 路由 `/System/Configuration/metadataoptions` 实测 404 —— `metadata` 这个键
 *   返回的是只有 `UseFileCreationTimeForDateAdded` 的 `MetadataConfiguration`。
 *   整份 GET → 原样 POST 的往返实测逐字节相同，所以只改 `MetadataOptions` 一段是安全的。
 */
@Entry
@Component
struct MetadataSettingsPage {
  /** 可原样回传的整份 ServerConfiguration（服务端下发 + 本页改动） */
  private config: ESObject = {} as ESObject;
  private originalConfigJson: string = '';

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  @State private savers: SaverItem[] = [];
  @State private itemTypes: ItemTypeState[] = [];
  @State private selectedTypeIndex: number = 0;
  /** 用户改过的条目类型（只回传这些，避免把没碰过的类型也重写一遍） */
  @State private editedTypes: string[] = [];
  @State private saversEdited: boolean = false;
  @State private revision: number = 0;

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.libraryMetadataSettings();
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取元数据设置失败';
      return;
    }
    const configJson: string = JsonUtil.toPretty(JsonUtil.getObject(result.data, 'config'));
    this.originalConfigJson = configJson;
    this.config = MetadataSettingsPage.parseConfig(configJson);
    const savers: SaverItem[] = [];
    const saverItems: Object[] = JsonUtil.getArray(result.data, 'savers');
    for (let i = 0; i < saverItems.length; i++) {
      const src: ESObject = saverItems[i] as ESObject;
      const item: SaverItem = new SaverItem();
      item.name = JsonUtil.getString(src, 'name', '');
      item.enabled = JsonUtil.getBoolean(src, 'enabled', false);
      item.partial = JsonUtil.getBoolean(src, 'partial', false);
      if (item.name.length > 0) {
        savers.push(item);
      }
    }
    this.savers = savers;

    const types: ItemTypeState[] = [];
    const typeItems: Object[] = JsonUtil.getArray(result.data, 'itemTypes');
    for (let i = 0; i < typeItems.length; i++) {
      const src: ESObject = typeItems[i] as ESObject;
      const state: ItemTypeState = new ItemTypeState();
      state.type = JsonUtil.getString(src, 'type', '');
      state.configured = JsonUtil.getBoolean(src, 'configured', false);
      state.metadataFetchers = MetadataSettingsPage.parseCheckItems(src, 'metadataFetchers');
      state.imageFetchers = MetadataSettingsPage.parseCheckItems(src, 'imageFetchers');
      if (state.type.length > 0) {
        types.push(state);
      }
    }
    this.itemTypes = types;
    this.selectedTypeIndex = 0;
    this.editedTypes = [];
    this.saversEdited = false;
    this.revision = this.revision + 1;
    this.status = types.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private static parseConfig(jsonText: string): ESObject {
    const parsed: ESObject | null = JsonUtil.parseObject(jsonText);
    if (parsed === null || Array.isArray(parsed)) {
      return {} as ESObject;
    }
    return parsed;
  }

  /** `config.MetadataOptions`（缺了就补成空数组并写回去，回传时不能丢别的字段） */
  private metadataOptions(): ESObject[] {
    const bag: Record<string, Object> = this.config as Record<string, Object>;
    const existing: Object | undefined = bag['MetadataOptions'];
    if (Array.isArray(existing)) {
      const out: ESObject[] = [];
      const arr: Object[] = existing as Object[];
      for (let i = 0; i < arr.length; i++) {
        out.push(arr[i] as ESObject);
      }
      return out;
    }
    const empty: Object[] = [];
    bag['MetadataOptions'] = empty;
    return [];
  }

  private setMetadataOptions(entries: ESObject[]): void {
    (this.config as Record<string, Object>)['MetadataOptions'] = entries;
  }

  private static parseCheckItems(obj: ESObject, key: string): CheckItem[] {
    const out: CheckItem[] = [];
    const items: Object[] = JsonUtil.getArray(obj, key);
    for (let i = 0; i < items.length; i++) {
      const src: ESObject = items[i] as ESObject;
      const name: string = JsonUtil.getString(src, 'name', '');
      if (name.length > 0) {
        out.push(new CheckItem(name, JsonUtil.getBoolean(src, 'enabled', false)));
      }
    }
    return out;
  }

  private selected(): ItemTypeState | null {
    if (this.selectedTypeIndex < 0 || this.selectedTypeIndex >= this.itemTypes.length) {
      return null;
    }
    return this.itemTypes[this.selectedTypeIndex];
  }

  private isDirty(): boolean {
    return this.editedTypes.length > 0 || this.saversEdited;
  }

  private markEdited(type: string): void {
    if (this.editedTypes.indexOf(type) < 0) {
      this.editedTypes = this.editedTypes.concat([type]);
    }
    this.actionMessage = '';
  }

  /** 在 `config.MetadataOptions` 里找到某类型的条目，没有就新建一条 */
  private entryFor(type: string): ESObject {
    const entries: ESObject[] = this.metadataOptions();
    for (let i = 0; i < entries.length; i++) {
      if (JsonUtil.getString(entries[i], 'ItemType', '') === type) {
        return entries[i];
      }
    }
    // 六个数组字段都要有：服务端把这一段当整体替换，缺字段的条目会退化成默认值
    const entry: ESObject = {
      'ItemType': type,
      'DisabledMetadataSavers': [] as string[],
      'LocalMetadataReaderOrder': [] as string[],
      'DisabledMetadataFetchers': [] as string[],
      'MetadataFetcherOrder': [] as string[],
      'DisabledImageFetchers': [] as string[],
      'ImageFetcherOrder': [] as string[]
    } as ESObject;
    this.setMetadataOptions(entries.concat([entry]));
    return entry;
  }

  /** 把勾选状态写回条目：禁用列表 + 顺序列表（顺序 = 界面上启用的那几项的显示顺序） */
  private writeEntry(type: string, metadata: CheckItem[], images: CheckItem[]): void {
    const entry: ESObject = this.entryFor(type);
    const bag: Record<string, Object> = entry as Record<string, Object>;
    const metaOn: string[] = [];
    const metaOff: string[] = [];
    for (let i = 0; i < metadata.length; i++) {
      if (metadata[i].enabled) {
        metaOn.push(metadata[i].name);
      } else {
        metaOff.push(metadata[i].name);
      }
    }
    const imgOn: string[] = [];
    const imgOff: string[] = [];
    for (let i = 0; i < images.length; i++) {
      if (images[i].enabled) {
        imgOn.push(images[i].name);
      } else {
        imgOff.push(images[i].name);
      }
    }
    bag['DisabledMetadataFetchers'] = metaOff;
    bag['MetadataFetcherOrder'] = metaOn;
    bag['DisabledImageFetchers'] = imgOff;
    bag['ImageFetcherOrder'] = imgOn;
  }

  private toggleMetadata(index: number, on: boolean): void {
    const state: ItemTypeState | null = this.selected();
    if (state === null) {
      return;
    }
    const next: CheckItem[] = [];
    for (let i = 0; i < state.metadataFetchers.length; i++) {
      next.push(new CheckItem(state.metadataFetchers[i].name,
        i === index ? on : state.metadataFetchers[i].enabled));
    }
    state.metadataFetchers = next;
    this.writeEntry(state.type, state.metadataFetchers, state.imageFetchers);
    this.markEdited(state.type);
    this.revision = this.revision + 1;
  }

  private toggleImage(index: number, on: boolean): void {
    const state: ItemTypeState | null = this.selected();
    if (state === null) {
      return;
    }
    const next: CheckItem[] = [];
    for (let i = 0; i < state.imageFetchers.length; i++) {
      next.push(new CheckItem(state.imageFetchers[i].name,
        i === index ? on : state.imageFetchers[i].enabled));
    }
    state.imageFetchers = next;
    this.writeEntry(state.type, state.metadataFetchers, state.imageFetchers);
    this.markEdited(state.type);
    this.revision = this.revision + 1;
  }

  private toggleSaver(index: number, on: boolean): void {
    const next: SaverItem[] = [];
    for (let i = 0; i < this.savers.length; i++) {
      const item: SaverItem = new SaverItem();
      item.name = this.savers[i].name;
      item.enabled = i === index ? on : this.savers[i].enabled;
      item.partial = i === index ? false : this.savers[i].partial;
      next.push(item);
    }
    this.savers = next;
    this.saversEdited = true;
    this.actionMessage = '';
  }

  /** 把保存器的勾选状态写进所有类型的条目（服务端是按类型存的） */
  private applySaversToConfig(): void {
    for (let i = 0; i < this.itemTypes.length; i++) {
      const type: string = this.itemTypes[i].type;
      const entry: ESObject = this.entryFor(type);
      const disabled: string[] = [];
      for (let j = 0; j < this.savers.length; j++) {
        if (!this.savers[j].enabled) {
          disabled.push(this.savers[j].name);
        }
      }
      (entry as Record<string, Object>)['DisabledMetadataSavers'] = disabled;
    }
  }

  private async save(): Promise<void> {
    if (this.saving || !this.isDirty()) {
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    if (this.saversEdited) {
      this.applySaversToConfig();
    }
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.libraryUpdateServerConfig(JSON.stringify(this.config)));
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = '元数据设置已保存';
    this.load();
  }

  private resetForm(): void {
    this.config = MetadataSettingsPage.parseConfig(this.originalConfigJson);
    this.editedTypes = [];
    this.saversEdited = false;
    this.actionOk = true;
    this.actionMessage = '已恢复为上次从服务器读取的设置（尚未提交）';
    // 表单里的勾选状态也要跟着回退，直接重新拉一次最稳
    this.load();
  }

  @Builder
  CheckRow(item: CheckItem, isImage: boolean, index: number) {
    Row({ space: 8 }) {
      Column({ space: 2 }) {
        Text(item.name)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textPrimary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Checkbox()
        .select(item.enabled)
        .selectedColor(this.colors().brandPrimary)
        .onChange((value: boolean) => {
          if (isImage) {
            this.toggleImage(index, value);
          } else {
            this.toggleMetadata(index, value);
          }
        })
    }
    .width('100%')
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 10, bottom: 10 })
  }

  @Builder
  Body() {
    Scroll() {
      Column() {
        if (this.savers.length > 0) {
          SectionCard({ title: '元数据保存器', icon: $r('sys.symbol.save'), showHeaderIcon: true }) {
            Column() {
              Text('决定抓到的元数据写不写成 nfo；取消勾选会对所有条目类型生效。')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textSecondary)
                .width('100%')
                .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                  top: 10 })
              ForEach(this.savers, (item: SaverItem, index: number) => {
                Row({ space: 8 }) {
                  Column({ space: 2 }) {
                    Text(item.name)
                      .fontSize(ThemeConstants.BODY_MEDIUM)
                      .fontColor(this.colors().textPrimary)
                    if (item.partial) {
                      Text('当前只有部分条目类型禁用了它（在别处改过）')
                        .fontSize(ThemeConstants.META_SMALL)
                        .fontColor(this.colors().warning)
                    }
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Checkbox()
                    .select(item.enabled)
                    .selectedColor(this.colors().brandPrimary)
                    .onChange((value: boolean) => {
                      this.toggleSaver(index, value);
                    })
                }
                .width('100%')
                .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                  top: 10, bottom: 10 })
              }, (item: SaverItem) => `${item.name}-${item.enabled}-${item.partial}`)
            }
            .width('100%')
          }
        }

        SectionCard({ title: '按条目类型', icon: $r('sys.symbol.rectangle_stack'),
          showHeaderIcon: true }) {
          Column() {
            Text('这里的勾选是服务器默认：单个媒体库没在自己选项里覆盖时就用它。')
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.colors().textSecondary)
              .width('100%')
              .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                top: 10, bottom: 6 })
            Flex({ wrap: FlexWrap.Wrap, justifyContent: FlexAlign.Start }) {
              ForEach(this.itemTypes, (state: ItemTypeState, index: number) => {
                Column() {
                  ChipButton({
                    label: itemTypeLabel(state.type),
                    selected: index === this.selectedTypeIndex,
                    onTap: () => {
                      this.selectedTypeIndex = index;
                    }
                  })
                }
                .margin({ right: 8, bottom: 8 })
              }, (state: ItemTypeState) => `${state.type}-${this.selectedTypeIndex === this.itemTypes.indexOf(state) ? 1 : 0}`)
            }
            .width('100%')
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })

            if (this.selected() !== null) {
              Text(this.selected()!.configured
                ? `${itemTypeLabel(this.selected()!.type)}：服务器已有该类型的配置`
                : `${itemTypeLabel(this.selected()!.type)}：服务器还没有该类型的配置，显示的是服务端给的默认值`)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.selected()!.configured
                  ? this.colors().textTertiary : this.colors().warning)
                .width('100%')
                .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                  bottom: 4 })

              Text('元数据下载器')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textSecondary)
                .width('100%')
                .padding({ left: ThemeConstants.PAGE_PADDING, top: 6, bottom: 2 })
              ForEach(this.selected()!.metadataFetchers, (item: CheckItem, index: number) => {
                this.CheckRow(item, false, index)
              }, (item: CheckItem) => `${item.name}-${item.enabled}`)

              Divider().color(this.colors().divider).strokeWidth(0.5)
              Text('图片获取器')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textSecondary)
                .width('100%')
                .padding({ left: ThemeConstants.PAGE_PADDING, top: 6, bottom: 2 })
              ForEach(this.selected()!.imageFetchers, (item: CheckItem, index: number) => {
                this.CheckRow(item, true, index)
              }, (item: CheckItem) => `${item.name}-${item.enabled}`)
            }
          }
          .width('100%')
        }

        Text('顺序：勾选的抓取器按列表顺序作为优先级；取消勾选后服务端就不再用它。'
          + '改动只影响之后新抓取的元数据，已有条目要等下次刷新才会重抓。')
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
          title: '媒体库元数据',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('服务器级默认（单个媒体库可在「媒体库选项」里覆盖）')
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
        } else if (this.status === UiState.ERROR || this.status === UiState.EMPTY) {
          EmptyState({
            message: this.status === UiState.EMPTY
              ? '服务器没有返回任何可配置的条目类型。'
              : (this.errorMsg.length > 0 ? this.errorMsg : '加载失败'),
            actionLabel: '重试',
            onAction: () => {
              this.load();
            }
          })
        } else {
          this.Body()
          Row({ space: 10 }) {
            Button('恢复')
              .layoutWeight(1)
              .height(44)
              .backgroundColor(this.colors().surfacePressed)
              .fontColor(this.colors().textPrimary)
              .enabled(!this.saving && this.isDirty())
              .onClick(() => {
                this.resetForm();
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
