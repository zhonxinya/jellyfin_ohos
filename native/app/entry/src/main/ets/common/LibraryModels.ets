import { JsonUtil } from './JsonUtil';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';

/**
 * 媒体库管理（设置 → 媒体库）的 UI 模型。
 *
 * 数据来源是 C++ `native/core/api/library_admin_api.cpp` 归一化后的 JSON：
 * - **外层字段**是 camelCase 的 UI 模型（`name` / `locations` / `pathInfos` …）；
 * - `options` 是**原样可回传**的服务端 `LibraryOptions` 对象（PascalCase，键名就是服务端字段名）。
 *   必须整体回传：服务端 `CollectionFolder.UpdateLibraryOptions` 是**替换**语义
 *   （见 `docs/jellyfin-10.8.12/MediaBrowser.Controller/Entities/CollectionFolder.cs`），
 *   只传改动字段会把其余选项悄悄重置成 C# 默认值。
 *
 * 因此 `LibraryOptionSet` 的职责是：把 `options` 当成唯一事实来源持有，
 * 读写都落在它身上，`toJson()` 直接交给 NAPI 回传。
 */

/** 集合类型（服务端 `CollectionTypeOptions`，序列化为小写） */
export class LibraryCollectionType {
  value: string;
  label: string;
  /** 该类型是否有"元数据抓取器"可配置（照片/合集/播放列表没有） */
  hasMetadataProviders: boolean;

  constructor(value: string, label: string, hasMetadataProviders: boolean) {
    this.value = value;
    this.label = label;
    this.hasMetadataProviders = hasMetadataProviders;
  }
}

/**
 * 与 jellyfin-web 的"添加媒体库"下拉一致。
 * `hasMetadataProviders` 对应服务端 `GetRepresentativeItemTypes`
 * （`Jellyfin.Api/Controllers/LibraryController.cs`）：照片/合集/播放列表没有元数据抓取器。
 */
export const LIBRARY_COLLECTION_TYPES: LibraryCollectionType[] = [
  new LibraryCollectionType('movies', '电影', true),
  new LibraryCollectionType('tvshows', '剧集', true),
  new LibraryCollectionType('music', '音乐', true),
  new LibraryCollectionType('musicvideos', '音乐视频', true),
  new LibraryCollectionType('homevideos', '家庭视频', true),
  new LibraryCollectionType('boxsets', '合集', false),
  new LibraryCollectionType('books', '书籍', true),
  new LibraryCollectionType('mixed', '混合内容', true)
];

export function collectionTypeLabel(value: string): string {
  for (let i = 0; i < LIBRARY_COLLECTION_TYPES.length; i++) {
    if (LIBRARY_COLLECTION_TYPES[i].value === value) {
      return LIBRARY_COLLECTION_TYPES[i].label;
    }
  }
  return value.length > 0 ? value : '媒体库';
}

/** 与 `LibrariesAdminPage` 的旧徽章口径保持一致，避免同一类型在两个页面颜色不同 */
export function collectionTypeColor(value: string, primary: string, neutral: string): string {
  if (value === 'movies') return primary;
  if (value === 'tvshows') return '#A855F7';
  if (value === 'music') return '#F59E0B';
  if (value === 'musicvideos') return '#F97316';
  if (value === 'photos') return '#10B981';
  if (value === 'books') return '#EC4899';
  return neutral;
}

/** 服务端 `EmbeddedSubtitleOptions` */
export class EmbeddedSubtitleChoice {
  value: string;
  label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

export const EMBEDDED_SUBTITLE_CHOICES: EmbeddedSubtitleChoice[] = [
  new EmbeddedSubtitleChoice('AllowAll', '允许全部'),
  new EmbeddedSubtitleChoice('AllowText', '仅文本字幕'),
  new EmbeddedSubtitleChoice('AllowImage', '仅图形字幕'),
  new EmbeddedSubtitleChoice('AllowNone', '全部禁止')
];

export function embeddedSubtitleLabel(value: string): string {
  for (let i = 0; i < EMBEDDED_SUBTITLE_CHOICES.length; i++) {
    if (EMBEDDED_SUBTITLE_CHOICES[i].value === value) {
      return EMBEDDED_SUBTITLE_CHOICES[i].label;
    }
  }
  return value;
}

/** 一个媒体路径（`MediaPathInfo`：本机路径 + 可选的网络路径映射） */
export class LibraryPathInfo {
  path: string;
  networkPath: string;

  constructor(path: string, networkPath: string) {
    this.path = path;
    this.networkPath = networkPath;
  }
}

/** 可选抓取项（`LibraryOptionInfoDto`） */
export class LibraryOptionInfo {
  name: string;
  defaultEnabled: boolean;

  constructor(name: string, defaultEnabled: boolean) {
    this.name = name;
    this.defaultEnabled = defaultEnabled;
  }
}

export class LibraryImageOption {
  imageType: string;
  limit: number;
  minWidth: number;

  constructor(imageType: string, limit: number, minWidth: number) {
    this.imageType = imageType;
    this.limit = limit;
    this.minWidth = minWidth;
  }
}

/** 按条目类型分组的一组抓取器（`LibraryTypeOptionsDto`） */
export class LibraryTypeOptionsInfo {
  type: string = '';
  metadataFetchers: LibraryOptionInfo[] = [];
  imageFetchers: LibraryOptionInfo[] = [];
  supportedImageTypes: string[] = [];
  defaultImageOptions: LibraryImageOption[] = [];
}

export class AvailableLibraryOptions {
  metadataSavers: LibraryOptionInfo[] = [];
  metadataReaders: LibraryOptionInfo[] = [];
  subtitleFetchers: LibraryOptionInfo[] = [];
  typeOptions: LibraryTypeOptionsInfo[] = [];
}

/** 语言 / 国家（`CountryInfo` / `LocalizationOption`：`{ Name, DisplayName }`） */
export class LocalizationChoice {
  name: string;
  displayName: string;

  constructor(name: string, displayName: string) {
    this.name = name;
    this.displayName = displayName.length > 0 ? displayName : name;
  }
}

/**
 * 服务端 `LibraryOptions` 的持有者：唯一的读写入口，`toJson()` 直接回传。
 *
 * 为什么不用一堆 `@State` 字段：选项对象有 25+ 个字段，而且必须**整体**回传，
 * 拆成状态字段后回传时要重新拼装，漏一个就是"静默重置服务端配置"。
 * 这里让页面只改自己关心的键，其余键原样保留（包括本客户端还不认识的未来字段）。
 */
export class LibraryOptionSet {
  private raw: ESObject;

  constructor(raw: ESObject | null) {
    this.raw = raw !== null && raw !== undefined ? raw : {} as ESObject;
  }

  /** 从归一化 JSON 文本构造；解析失败时退化成空对象（服务端会按默认值补全） */
  static fromJson(jsonText: string): LibraryOptionSet {
    const parsed: ESObject | null = JsonUtil.parseObject(jsonText);
    return new LibraryOptionSet(parsed);
  }

  /** 深拷贝：编辑页用来实现"取消 = 丢弃草稿" */
  clone(): LibraryOptionSet {
    try {
      return new LibraryOptionSet(JSON.parse(JSON.stringify(this.raw)) as ESObject);
    } catch (_e) {
      return new LibraryOptionSet(null);
    }
  }

  toJson(): string {
    return JsonUtil.toPretty(this.raw);
  }

  rawObject(): ESObject {
    return this.raw;
  }

  has(key: string): boolean {
    const map: Record<string, Object> = this.raw as Record<string, Object>;
    return map[key] !== undefined && map[key] !== null;
  }

  getBool(key: string, fallback: boolean): boolean {
    return JsonUtil.getBoolean(this.raw, key, fallback);
  }

  setBool(key: string, value: boolean): void {
    (this.raw as Record<string, Object>)[key] = value;
  }

  getString(key: string, fallback: string): string {
    return JsonUtil.getString(this.raw, key, fallback);
  }

  setString(key: string, value: string): void {
    (this.raw as Record<string, Object>)[key] = value;
  }

  getNumber(key: string, fallback: number): number {
    return JsonUtil.getNumber(this.raw, key, fallback);
  }

  setNumber(key: string, value: number): void {
    (this.raw as Record<string, Object>)[key] = value;
  }

  /** 字符串数组字段（大小写敏感的原始值，用于回传） */
  getStringArray(key: string): string[] {
    const out: string[] = [];
    const items: Object[] = JsonUtil.getArray(this.raw, key);
    for (let i = 0; i < items.length; i++) {
      if (typeof items[i] === 'string') {
        out.push(items[i] as string);
      }
    }
    return out;
  }

  setStringArray(key: string, values: string[]): void {
    (this.raw as Record<string, Object>)[key] = values;
  }

  /**
   * 该字段是否被**显式配置**过。
   *
   * 服务端把 `MetadataSavers` / `SubtitleDownloadLanguages` / `LocalMetadataReaderOrder`
   * 的 null 解释为"沿用服务器全局配置"（`MediaBrowser.Providers/Manager/ProviderManager.cs`），
   * 与"显式空列表"语义不同，所以归一化时不补空数组，这里也就能区分出来。
   */
  isExplicit(key: string): boolean {
    const map: Record<string, Object> = this.raw as Record<string, Object>;
    const value: Object | undefined = map[key];
    return value !== undefined && value !== null;
  }

  /**
   * 从可空数组字段里清空（回到"沿用服务器全局配置"）。
   * 写 `null` 而不是删键：服务端反序列化时 null 与"字段缺失"等价，
   * 但显式写 null 在抓包/排障时更容易看出这是客户端有意为之。
   */
  clearKey(key: string): void {
    (this.raw as Record<string, Object | null>)[key] = null;
  }

  /** 大小写不敏感地判断列表里有没有某一项（服务端比较用的是 OrdinalIgnoreCase） */
  static contains(list: string[], value: string): boolean {
    const needle: string = value.toLowerCase();
    for (let i = 0; i < list.length; i++) {
      if (list[i].toLowerCase() === needle) {
        return true;
      }
    }
    return false;
  }

  /** 在列表里加入/移除某一项，保持原有顺序（新项追加到末尾） */
  static toggle(list: string[], value: string, on: boolean): string[] {
    const out: string[] = [];
    let found = false;
    const needle: string = value.toLowerCase();
    for (let i = 0; i < list.length; i++) {
      if (list[i].toLowerCase() === needle) {
        found = true;
        if (on) {
          out.push(list[i]);
        }
      } else {
        out.push(list[i]);
      }
    }
    if (on && !found) {
      out.push(value);
    }
    return out;
  }

  /** 找到某个条目类型的 TypeOptions 条目（没有则返回 null，表示"沿用服务器全局配置"） */
  typeOption(type: string): ESObject | null {
    const items: Object[] = JsonUtil.getArray(this.raw, 'TypeOptions');
    for (let i = 0; i < items.length; i++) {
      const entry: ESObject = items[i] as ESObject;
      if (JsonUtil.getString(entry, 'Type', '') === type) {
        return entry;
      }
    }
    return null;
  }

  hasTypeOption(type: string): boolean {
    return this.typeOption(type) !== null;
  }

  /** 读取某类型的已启用元数据抓取器（无条目时返回 null，调用方回落到 `DefaultEnabled`） */
  metadataFetchers(type: string): string[] | null {
    const entry: ESObject | null = this.typeOption(type);
    if (entry === null) {
      return null;
    }
    return LibraryOptionSet.readStrings(entry, 'MetadataFetchers');
  }

  imageFetchers(type: string): string[] | null {
    const entry: ESObject | null = this.typeOption(type);
    if (entry === null) {
      return null;
    }
    return LibraryOptionSet.readStrings(entry, 'ImageFetchers');
  }

  /**
   * 写入某类型的已启用抓取器。
   * `MetadataFetcherOrder` / `ImageFetcherOrder` 同步成同一个列表：
   * 服务端用它决定抓取器的优先顺序（`ProviderManager.GetConfiguredOrder`），
   * 只写 enabled 列表而让 order 留空会让顺序退回服务器默认值。
   */
  setMetadataFetchers(type: string, enabled: string[]): void {
    const entry: ESObject = this.ensureTypeOption(type);
    (entry as Record<string, Object>)['MetadataFetchers'] = enabled;
    (entry as Record<string, Object>)['MetadataFetcherOrder'] = enabled;
  }

  setImageFetchers(type: string, enabled: string[]): void {
    const entry: ESObject = this.ensureTypeOption(type);
    (entry as Record<string, Object>)['ImageFetchers'] = enabled;
    (entry as Record<string, Object>)['ImageFetcherOrder'] = enabled;
  }

  /** 没有该类型的条目时新建一个（写操作前调用），字段与 C# 构造函数默认值一致 */
  private ensureTypeOption(type: string): ESObject {
    const existing: ESObject | null = this.typeOption(type);
    if (existing !== null) {
      return existing;
    }
    const entry: ESObject = {
      'Type': type,
      'MetadataFetchers': [] as string[],
      'MetadataFetcherOrder': [] as string[],
      'ImageFetchers': [] as string[],
      'ImageFetcherOrder': [] as string[],
      'ImageOptions': [] as Object[]
    } as ESObject;
    const items: Object[] = JsonUtil.getArray(this.raw, 'TypeOptions');
    items.push(entry);
    (this.raw as Record<string, Object>)['TypeOptions'] = items;
    return entry;
  }

  private static readStrings(obj: ESObject, key: string): string[] {
    const out: string[] = [];
    const items: Object[] = JsonUtil.getArray(obj, key);
    for (let i = 0; i < items.length; i++) {
      if (typeof items[i] === 'string') {
        out.push(items[i] as string);
      }
    }
    return out;
  }
}

/** 列表页用的媒体库条目 */
export class LibraryEntry {
  name: string = '';
  itemId: string = '';
  collectionType: string = '';
  locations: string[] = [];
  pathInfos: LibraryPathInfo[] = [];
  refreshStatus: string = '';
  refreshing: boolean = false;
  refreshProgress: number = 0;
  hasPrimaryImage: boolean = false;
  primaryImageItemId: string = '';
  /** 封面图地址（解析时算一次；拿不到就是空串，卡片退回字母占位块） */
  coverUrl: string = '';
  options: LibraryOptionSet = new LibraryOptionSet(null);

  /** 列表 key：优先 ItemId，缺失时退回库名（虚拟文件夹名在服务器上唯一） */
  key(): string {
    return this.itemId.length > 0 ? this.itemId : this.name;
  }
}

/**
 * 媒体库封面地址。
 *
 * 服务端的 `VirtualFolderInfo.PrimaryImageItemId` 只在**该媒体库自己设置过图片**时才有值，
 * 所以这里用它而不用 `ItemId`：没有封面时返回空串，卡片渲染字母占位块，
 * 而不是发一个必然 404 的请求（JellyfinImage 对失败会显示占位图标，但白跑一次网络不好）。
 *
 * 返回的 `getImageUrl` 是 JSON（`{ ok, data: { url } }`），必须解出来 ——
 * 直接把 JSON 串当 URL 传下去会让取图失败（`DetailPage.personImageUrl` 就是这个问题，另案处理）。
 */
function buildCoverUrl(primaryImageItemId: string): string {
  if (primaryImageItemId.length === 0) {
    return '';
  }
  const raw: string = JellyfinNative.getImageUrl(primaryImageItemId, 'Primary', 160, '');
  const result: NativeResult = JellyfinNative.parseResult(raw);
  if (!result.ok || result.data === null) {
    return '';
  }
  return JsonUtil.getString(result.data, 'url', '');
}

function readStringArray(obj: ESObject, key: string): string[] {
  const out: string[] = [];
  const items: Object[] = JsonUtil.getArray(obj, key);
  for (let i = 0; i < items.length; i++) {
    if (typeof items[i] === 'string') {
      out.push(items[i] as string);
    }
  }
  return out;
}

export function parseLibraryEntry(obj: Object): LibraryEntry {
  const src: ESObject = obj as ESObject;
  const entry: LibraryEntry = new LibraryEntry();
  entry.name = JsonUtil.getString(src, 'name', '未命名媒体库');
  entry.itemId = JsonUtil.getString(src, 'itemId', '');
  entry.collectionType = JsonUtil.getString(src, 'collectionType', '');
  entry.locations = readStringArray(src, 'locations');
  entry.refreshStatus = JsonUtil.getString(src, 'refreshStatus', '');
  entry.refreshing = JsonUtil.getBoolean(src, 'refreshing', false);
  entry.refreshProgress = JsonUtil.getNumber(src, 'refreshProgress', 0);
  entry.hasPrimaryImage = JsonUtil.getBoolean(src, 'hasPrimaryImage', false);
  entry.primaryImageItemId = JsonUtil.getString(src, 'primaryImageItemId', '');
  entry.coverUrl = buildCoverUrl(entry.primaryImageItemId);

  const infos: Object[] = JsonUtil.getArray(src, 'pathInfos');
  for (let i = 0; i < infos.length; i++) {
    const info: ESObject = infos[i] as ESObject;
    entry.pathInfos.push(new LibraryPathInfo(
      JsonUtil.getString(info, 'path', ''),
      JsonUtil.getString(info, 'networkPath', '')));
  }

  const options: ESObject | null = JsonUtil.getObject(src, 'options');
  entry.options = new LibraryOptionSet(options);
  return entry;
}

export function parseLibraryEntries(data: ESObject | null): LibraryEntry[] {
  const out: LibraryEntry[] = [];
  if (data === null) {
    return out;
  }
  const list: Object[] = JsonUtil.extractItems(data);
  for (let i = 0; i < list.length; i++) {
    out.push(parseLibraryEntry(list[i]));
  }
  return out;
}

function parseOptionInfoList(obj: ESObject, key: string): LibraryOptionInfo[] {
  const out: LibraryOptionInfo[] = [];
  const items: Object[] = JsonUtil.getArray(obj, key);
  for (let i = 0; i < items.length; i++) {
    const info: ESObject = items[i] as ESObject;
    const name: string = JsonUtil.getString(info, 'name', '');
    if (name.length > 0) {
      out.push(new LibraryOptionInfo(name, JsonUtil.getBoolean(info, 'defaultEnabled', false)));
    }
  }
  return out;
}

export function parseAvailableOptions(data: ESObject | null): AvailableLibraryOptions {
  const out: AvailableLibraryOptions = new AvailableLibraryOptions();
  if (data === null) {
    return out;
  }
  out.metadataSavers = parseOptionInfoList(data, 'metadataSavers');
  out.metadataReaders = parseOptionInfoList(data, 'metadataReaders');
  out.subtitleFetchers = parseOptionInfoList(data, 'subtitleFetchers');

  const types: Object[] = JsonUtil.getArray(data, 'typeOptions');
  for (let i = 0; i < types.length; i++) {
    const src: ESObject = types[i] as ESObject;
    const info: LibraryTypeOptionsInfo = new LibraryTypeOptionsInfo();
    info.type = JsonUtil.getString(src, 'type', '');
    info.metadataFetchers = parseOptionInfoList(src, 'metadataFetchers');
    info.imageFetchers = parseOptionInfoList(src, 'imageFetchers');
    info.supportedImageTypes = readStringArray(src, 'supportedImageTypes');
    const images: Object[] = JsonUtil.getArray(src, 'defaultImageOptions');
    for (let j = 0; j < images.length; j++) {
      const image: ESObject = images[j] as ESObject;
      info.defaultImageOptions.push(new LibraryImageOption(
        JsonUtil.getString(image, 'imageType', ''),
        JsonUtil.getNumber(image, 'limit', 0),
        JsonUtil.getNumber(image, 'minWidth', 0)));
    }
    out.typeOptions.push(info);
  }
  return out;
}

/**
 * 解析一组"值 + 展示名"的选项。
 *
 * `valueKey` 是取值的字段名：
 * - 语言（`/Localization/Cultures` → `CultureDto`）：**`ThreeLetterISOLanguageName`**，
 *   例如中文是 `chi`。不能取 `Name`（那里是 `Chinese`）也不能取两字母码 ——
 *   服务端 `LocalizationManager` 是按三字母码匹配 `PreferredMetadataLanguage` 的。
 * - 国家（`/Localization/Countries` → `CountryInfo`）：`TwoLetterISORegionName`（例如 `CN`），
 *   缺失时退回 `Name`（两者实测量值相同）。
 */
function parseLocalizationList(data: ESObject | null, key: string,
                               valueKey: string): LocalizationChoice[] {
  const out: LocalizationChoice[] = [];
  if (data === null) {
    return out;
  }
  const items: Object[] = JsonUtil.getArray(data, key);
  for (let i = 0; i < items.length; i++) {
    const src: ESObject = items[i] as ESObject;
    let value: string = JsonUtil.getString(src, valueKey, '');
    if (value.length === 0) {
      value = JsonUtil.getString(src, 'Name', '');
    }
    if (value.length === 0) {
      continue;
    }
    out.push(new LocalizationChoice(value, JsonUtil.getString(src, 'DisplayName', '')));
  }
  return out;
}

export class LibraryLocalization {
  /** 语言下拉（值 = 三字母 ISO 语言码） */
  languages: LocalizationChoice[] = [];
  /** 国家/地区下拉（值 = 两字母 ISO 地区码） */
  countries: LocalizationChoice[] = [];
}

export function parseLocalization(data: ESObject | null): LibraryLocalization {
  const out: LibraryLocalization = new LibraryLocalization();
  // 注意字段名是 cultures：接口是 /Localization/Cultures
  out.languages = parseLocalizationList(data, 'cultures', 'ThreeLetterISOLanguageName');
  out.countries = parseLocalizationList(data, 'countries', 'TwoLetterISORegionName');
  return out;
}

/** 首选元数据语言的展示名（空 = 沿用服务器默认） */
export function languageDisplayName(localization: LibraryLocalization, code: string): string {
  if (code.length === 0) {
    return '服务器默认';
  }
  for (let i = 0; i < localization.languages.length; i++) {
    if (localization.languages[i].name === code) {
      return localization.languages[i].displayName;
    }
  }
  return code;
}

export function countryDisplayName(localization: LibraryLocalization, code: string): string {
  if (code.length === 0) {
    return '服务器默认';
  }
  for (let i = 0; i < localization.countries.length; i++) {
    if (localization.countries[i].name === code) {
      return localization.countries[i].displayName;
    }
  }
  return code;
}
