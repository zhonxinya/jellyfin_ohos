import { JsonUtil } from './JsonUtil';

/**
 * 条目元数据管理页的 UI 模型与草稿合并。
 *
 * 分层（见 AGENTS.md）：请求形状与"整体替换"的语义都在 core
 * （`native/core/api/item_metadata_api.*`，含主机单测）。这里只做界面侧的两件事：
 *
 * 1. 把 core 归一化后的选项 / 候选条目转成能直接画的模型；
 * 2. 把用户改动**合并进服务端条目原文** —— `POST /Items/{itemId}` 是整体替换
 *    （没带的字段会被写空，`LockData` 缺失还会静默解锁），所以必须以原文为底整体回传，
 *    而不是只提交被改的字段。core 侧还会对 `ProviderIds` / `Studios` 做兜底。
 */

/** 下拉项 —— core 把 `MetadataEditorInfo` 里各类选项统一收敛成 `{name,displayName,value}` */
export class MetadataOption {
  name: string = '';
  displayName: string = '';
  /** 提交给服务端的取值（分级 = 名称；国家 = 两字母码；语言 = 三字母码） */
  value: string = '';
  /** 仅外部 ID 有：提供方网站的链接模板（含 `{0}`），用来拼「去提供方网站看看」 */
  urlFormatString: string = '';

  static fromArray(items: Object[]): MetadataOption[] {
    const out: MetadataOption[] = [];
    for (let i = 0; i < items.length; i++) {
      const src: ESObject = items[i] as ESObject;
      const option: MetadataOption = new MetadataOption();
      option.name = JsonUtil.getString(src, 'name', '');
      option.displayName = JsonUtil.getString(src, 'displayName', option.name);
      option.value = JsonUtil.getString(src, 'value', '');
      option.urlFormatString = JsonUtil.getString(src, 'urlFormatString', '');
      out.push(option);
    }
    return out;
  }
}

/**
 * 一个可编辑的外部 ID 行（提供方定义 × 条目当前取值）。
 *
 * 为什么要有"补漏"逻辑：`ExternalIdInfos` 是**当前服务器配置的抓取器**给出的定义，
 * 而条目原文里的 `ProviderIds` 可能含定义外的键（换过抓取器、手动写过）。
 * 整体替换下漏掉任何一个键都会把它从条目上抹掉，所以定义外的键也要列出来让用户看见。
 *
 * 另外，服务端的 `ExternalIdInfo` 里 **Name 也不唯一**（模型注释明说 Key 不保证跨类型唯一）：
 * 电影会同时拿到 `TmdbMovieExternalId`（Name=`TheMovieDb`/Key=`Tmdb`）和
 * `TmdbBoxSetExternalId`（Name=`TheMovieDb`/Key=`TmdbCollection`）两条定义，两行同名。
 * 所以重名的定义要补上 Key 才分得清。
 */
export class ProviderIdEntry {
  key: string = '';
  label: string = '';
  value: string = '';

  static build(options: MetadataOption[], providerIds: ESObject | null): ProviderIdEntry[] {
    const out: ProviderIdEntry[] = [];
    const seen: string[] = [];
    const uniqueOptions: MetadataOption[] = [];
    const labels: string[] = [];
    for (let i = 0; i < options.length; i++) {
      const option: MetadataOption = options[i];
      if (option.value.length === 0 || seen.indexOf(option.value) >= 0) {
        continue;
      }
      seen.push(option.value);
      uniqueOptions.push(option);
      labels.push(option.displayName.length > 0 ? option.displayName : option.value);
    }
    const duplicated: string[] = [];
    for (let i = 0; i < labels.length; i++) {
      if (labels.indexOf(labels[i]) !== labels.lastIndexOf(labels[i]) && duplicated.indexOf(labels[i]) < 0) {
        duplicated.push(labels[i]);
      }
    }
    for (let i = 0; i < uniqueOptions.length; i++) {
      const option: MetadataOption = uniqueOptions[i];
      const label: string = option.displayName.length > 0 ? option.displayName : option.value;
      const entry: ProviderIdEntry = new ProviderIdEntry();
      entry.key = option.value;
      entry.label = duplicated.indexOf(label) >= 0 ? `${label}（${option.value}）` : label;
      entry.value = JsonUtil.getString(providerIds, option.value, '');
      out.push(entry);
    }
    const keys: string[] = JsonUtil.keysOf(providerIds);
    for (let i = 0; i < keys.length; i++) {
      if (seen.indexOf(keys[i]) >= 0) {
        continue;
      }
      const entry: ProviderIdEntry = new ProviderIdEntry();
      entry.key = keys[i];
      entry.label = `${keys[i]}（未配置的提供方）`;
      entry.value = JsonUtil.getString(providerIds, keys[i], '');
      out.push(entry);
    }
    return out;
  }
}

/** 远程搜索候选（core `normalizeRemoteSearchResults` 的形状） */
export class RemoteSearchCandidate {
  name: string = '';
  overview: string = '';
  imageUrl: string = '';
  premiereDate: string = '';
  searchProviderName: string = '';
  /** 服务端原文 —— 「应用识别结果」必须回传它（服务端只认 `RemoteSearchResult`） */
  raw: string = '';
  year: number = 0;
  /** 「没有年份」与「年份是 0」是两件事，所以单独记一个标志 */
  hasYear: boolean = false;

  static fromArray(items: Object[]): RemoteSearchCandidate[] {
    const out: RemoteSearchCandidate[] = [];
    for (let i = 0; i < items.length; i++) {
      const src: ESObject = items[i] as ESObject;
      const candidate: RemoteSearchCandidate = new RemoteSearchCandidate();
      candidate.name = JsonUtil.getString(src, 'name', '');
      candidate.overview = JsonUtil.getString(src, 'overview', '');
      candidate.imageUrl = JsonUtil.getString(src, 'imageUrl', '');
      candidate.premiereDate = JsonUtil.getString(src, 'premiereDate', '');
      candidate.searchProviderName = JsonUtil.getString(src, 'searchProviderName', '');
      candidate.raw = JsonUtil.toPretty(JsonUtil.getObject(src, 'raw'));
      const yearText: string = JsonUtil.valueText(src, 'year');
      if (yearText.length > 0) {
        candidate.hasYear = true;
        candidate.year = JsonUtil.getNumber(src, 'year', 0);
      }
      out.push(candidate);
    }
    return out;
  }

  /** 副标题：提供方 + 年份 + 外部 ID（有什么显示什么） */
  subtitle(): string {
    const parts: string[] = [];
    if (this.searchProviderName.length > 0) {
      parts.push(this.searchProviderName);
    }
    if (this.hasYear && this.year > 0) {
      parts.push(`${this.year}`);
    } else if (this.premiereDate.length > 0) {
      parts.push(this.premiereDate);
    }
    const ids: ESObject | null = JsonUtil.parseObject(this.raw);
    const providerIds: ESObject | null = JsonUtil.getObject(ids, 'ProviderIds');
    const keys: string[] = JsonUtil.keysOf(providerIds);
    for (let i = 0; i < keys.length && i < 3; i++) {
      const value: string = JsonUtil.getString(providerIds, keys[i], '');
      if (value.length > 0) {
        parts.push(`${keys[i]} ${value}`);
      }
    }
    return parts.join(' · ');
  }
}

/** 「锁定字段」多选项 —— 服务端 `MetadataField` 枚举的中文名 */
export interface LockedFieldOption {
  label: string;
  value: string;
}

/**
 * 可锁定字段的中文名。
 *
 * **取值以服务端为准**：可选字段清单由 core 的 `metadataFieldNames()` 给出（跟着
 * `MetadataField` 枚举走），这里只负责配中文名 —— 枚举变了不会出现"界面能选但服务端不认"的项。
 */
const LOCKED_FIELD_LABELS: LockedFieldOption[] = [
  { label: '名称', value: 'Name' },
  { label: '简介', value: 'Overview' },
  { label: '类型', value: 'Genres' },
  { label: '标签', value: 'Tags' },
  { label: '制片公司', value: 'Studios' },
  { label: '拍摄地点', value: 'ProductionLocations' },
  { label: '演员', value: 'Cast' },
  { label: '分级', value: 'OfficialRating' },
  { label: '时长', value: 'Runtime' }
];

/** 按服务端给出的枚举顺序生成「锁定字段」选项；没配中文名的用原值兜底 */
export function lockedFieldOptions(serverFields: string[]): LockedFieldOption[] {
  const out: LockedFieldOption[] = [];
  for (let i = 0; i < serverFields.length; i++) {
    const value: string = serverFields[i];
    let label: string = value;
    for (let j = 0; j < LOCKED_FIELD_LABELS.length; j++) {
      if (LOCKED_FIELD_LABELS[j].value === value) {
        label = LOCKED_FIELD_LABELS[j].label;
        break;
      }
    }
    out.push({ label: label, value: value });
  }
  return out;
}

/** 刷新模式（服务端 `MetadataRefreshMode`） */
export interface RefreshModeOption {
  label: string;
  value: string;
}

export const REFRESH_MODE_OPTIONS: RefreshModeOption[] = [
  { label: '仅补缺失', value: 'ValidationOnly' },
  { label: '完全刷新', value: 'FullRefresh' }
];

/**
 * 「条目元数据改过」信号 —— 元数据页与详情页之间的单向通知。
 *
 * 为什么不让详情页"返回时无条件重载"：`DetailPage.loadDetail()` 会把季标签重置回第 1 季，
 * 而用户从播放页返回详情页时，已选中的季不该被清掉。所以只在元数据页真的改过东西时，
 * 让详情页按 itemId 精确重载一次（`consume` 取走即清，避免影响别的条目/重复重载）。
 */
export class ItemMetadataRefreshSignal {
  private static changedId: string = '';

  /** 元数据页在返回前调用（仅在真的改过数据时） */
  static markChanged(itemId: string): void {
    ItemMetadataRefreshSignal.changedId = itemId;
  }

  /** 详情页 `onPageShow` 调用：返回 true 表示该条目改过，应重载一次 */
  static consume(itemId: string): boolean {
    if (ItemMetadataRefreshSignal.changedId.length > 0 &&
      ItemMetadataRefreshSignal.changedId === itemId) {
      ItemMetadataRefreshSignal.changedId = '';
      return true;
    }
    return false;
  }
}

/**
 * 可管理的图片类型（服务端 `ImageType` 枚举的常用项）。
 *
 * 为什么是硬编码列表而不是从服务端取：`ImageType` 是编译期枚举，没有对应的"可选值"端点；
 * 这里只列影视条目常见的几种，服务端不支持的组合会在提交时报错并如实提示。
 */
export const ITEM_IMAGE_TYPES: string[] = [
  'Primary', 'Backdrop', 'Logo', 'Thumb', 'Banner', 'Art', 'Disc'
];

/** 条目已有的一张图片（`GET /Items/{itemId}/Images` 的 `ImageInfo`） */
export class ItemImage {
  type: string = '';
  index: number = 0;
  width: number = 0;
  height: number = 0;
  /** 带 `ImageTag` 的取图地址（tag 变了地址就变，避免拿到旧缓存） */
  url: string = '';

  static fromArray(items: Object[], buildUrl: (type: string, tag: string) => string): ItemImage[] {
    const out: ItemImage[] = [];
    for (let i = 0; i < items.length; i++) {
      const src: ESObject = items[i] as ESObject;
      const image: ItemImage = new ItemImage();
      image.type = JsonUtil.getString(src, 'ImageType', '');
      image.index = JsonUtil.getNumber(src, 'ImageIndex', 0);
      image.width = JsonUtil.getNumber(src, 'Width', 0);
      image.height = JsonUtil.getNumber(src, 'Height', 0);
      image.url = buildUrl(image.type, JsonUtil.getString(src, 'ImageTag', ''));
      out.push(image);
    }
    return out;
  }

  /** 图片类型的中文名（`Primary` 就是影视条目里的"海报"） */
  typeLabel(): string {
    if (this.type === 'Primary') {
      return '海报';
    }
    if (this.type === 'Backdrop') {
      return '背景图';
    }
    if (this.type === 'Logo') {
      return 'Logo';
    }
    if (this.type === 'Thumb') {
      return '缩略图';
    }
    if (this.type === 'Banner') {
      return '横幅';
    }
    if (this.type === 'Art') {
      return '艺术图';
    }
    if (this.type === 'Disc') {
      return '光盘图';
    }
    return this.type;
  }

  sizeLabel(): string {
    return this.width > 0 && this.height > 0 ? `${this.width}×${this.height}` : '尺寸未知';
  }
}

/**
 * 页面上的可编辑字段集合（就是 `ItemMetadataEdits` 的输入）。
 *
 * 数组类字段（类型/标签/制片公司/拍摄地点/宣传语）在页面上是多行文本（每行一项）。
 * 可空字段（年份/首播日期/评分）用字符串承载，空串 = 清除 —— 服务端是整体替换，
 * 「清空」必须显式发 `null`/省略，不能靠"不发这个字段"。
 */
export interface ItemMetadataEdits {
  name: string;
  originalTitle: string;
  forcedSortName: string;
  overview: string;
  productionYear: string;
  premiereDate: string;
  officialRating: string;
  customRating: string;
  communityRating: string;
  criticRating: string;
  preferredMetadataLanguage: string;
  preferredMetadataCountryCode: string;
  lockData: boolean;
  lockedFields: string[];
  genres: string[];
  tags: string[];
  studios: string[];
  productionLocations: string[];
  taglines: string[];
  providerIds: ProviderIdEntry[];
}

export class MetadataDraft {
  /** 多行文本 ← 字符串数组（每行一项，去空去空白） */
  static toLines(values: string[]): string {
    return values.join('\n');
  }

  /** 多行文本 → 字符串数组（每行一项，去空去空白） */
  static fromLines(text: string): string[] {
    const out: string[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const value: string = lines[i].trim();
      if (value.length > 0) {
        out.push(value);
      }
    }
    return out;
  }

  /** 文本框 → 可空数字（空 / 非数字 = 清除） */
  static nullableNumber(text: string): number | null {
    const value: string = text.trim();
    if (value.length === 0) {
      return null;
    }
    const parsed: number = Number(value);
    return Number.isNaN(parsed) ? null : parsed;
  }

  /** 文本框 → 可空文本（空 = 清除） */
  static nullableText(text: string): string | null {
    const value: string = text.trim();
    return value.length === 0 ? null : value;
  }

  /**
   * 服务端的日期是完整 ISO（`1992-07-02T00:00:00.0000000Z`），表单只显示/编辑日期部分。
   *
   * 只截到日期是安全的：服务端把日期存为 UTC 午夜，回传 `YYYY-MM-DD` 会得到同一个时刻
   * （而把 `...T00:00:00.0000000Z` 原样显示在输入框里，既难读也容易改坏）。
   */
  static dateOnly(value: string): string {
    const text: string = value.trim();
    const index: number = text.indexOf('T');
    return index > 0 ? text.substring(0, index) : text;
  }

  /**
   * 把用户改动合并进**服务端条目原文**，得到整体替换的请求体。
   *
   * 以原文为底是关键：原文里带着本页不编辑的字段（`People` / `Path` / `MediaSources` /
   * `UserData` …），漏掉它们就等于让服务端把条目清空。合并只覆盖本页负责的字段。
   *
   * 返回空串表示原文不可解析（调用方应中止保存并提示，而不是发一个空 body 出去）。
   */
  static buildBody(rawItem: string, edits: ItemMetadataEdits): string {
    const parsed: ESObject | null = JsonUtil.parseObject(rawItem);
    if (parsed === null) {
      return '';
    }
    const map: Record<string, Object | null> = parsed as Record<string, Object | null>;

    map['Name'] = edits.name;
    map['OriginalTitle'] = edits.originalTitle;
    map['ForcedSortName'] = edits.forcedSortName;
    map['Overview'] = edits.overview;
    map['ProductionYear'] = MetadataDraft.nullableNumber(edits.productionYear);
    map['PremiereDate'] = MetadataDraft.nullableText(edits.premiereDate);
    map['OfficialRating'] = edits.officialRating;
    map['CustomRating'] = edits.customRating;
    map['CommunityRating'] = MetadataDraft.nullableNumber(edits.communityRating);
    map['CriticRating'] = MetadataDraft.nullableNumber(edits.criticRating);
    map['PreferredMetadataLanguage'] = edits.preferredMetadataLanguage;
    map['PreferredMetadataCountryCode'] = edits.preferredMetadataCountryCode;
    map['LockData'] = edits.lockData;
    map['LockedFields'] = edits.lockedFields;
    map['Genres'] = edits.genres;
    map['Tags'] = edits.tags;
    // core 会把字符串数组转成服务端要的 `[{ "Name": ... }]`
    map['Studios'] = edits.studios;
    map['ProductionLocations'] = edits.productionLocations;
    map['Taglines'] = edits.taglines;
    map['ProviderIds'] = MetadataDraft.providerIdsOf(edits.providerIds);

    return JSON.stringify(map);
  }

  /** 外部 ID 行 → `{ Tmdb: "4176" }`（空值不发：服务端也会把空值删掉） */
  static providerIdsOf(entries: ProviderIdEntry[]): Record<string, string> {
    const out: Record<string, string> = {} as Record<string, string>;
    for (let i = 0; i < entries.length; i++) {
      const entry: ProviderIdEntry = entries[i];
      const value: string = entry.value.trim();
      if (entry.key.length > 0 && value.length > 0) {
        out[entry.key] = value;
      }
    }
    return out;
  }
}
