import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../plugins/JellyfinNative';
import { JsonUtil } from '../common/JsonUtil';
import { UiState } from '../common/UiState';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import {
  ItemImage,
  ItemMetadataEdits,
  ItemMetadataRefreshSignal,
  ITEM_IMAGE_TYPES,
  LockedFieldOption,
  lockedFieldOptions,
  MetadataDraft,
  MetadataOption,
  ProviderIdEntry,
  RefreshModeOption,
  REFRESH_MODE_OPTIONS,
  RemoteSearchCandidate
} from '../common/ItemMetadataModels';
import { PageHeader } from '../components/PageHeader';
import { SectionCard } from '../components/SectionCard';
import { ChipButton } from '../components/ChipButton';
import { PrimaryButton } from '../components/PrimaryButton';
import { SecondaryButton } from '../components/SecondaryButton';
import { TextButton } from '../components/TextButton';
import { LoadingState } from '../components/LoadingState';
import { EmptyState } from '../components/EmptyState';
import { JellyfinImage } from '../components/JellyfinImage';

/** 下拉里"不设置"那一项的文案（`Select` 必须至少有一个选项，所以用首项承载"清空"） */
const UNSET_LABEL: string = '不设置';

/**
 * 影视条目元数据管理页（电影 / 剧集 / 分集…）。
 *
 * 服务端三个控制器（`ItemUpdateController` / `ItemLookupController` / `ItemRefreshController`）
 * 都是 `RequiresElevation`，所以入口只在管理员可见（详情页门禁），本页再兜一道
 * `isAdmin` 检查；NAPI 侧还有 `RequireAdmin()`。
 *
 * **保存是"整体替换"**（`POST /Items/{itemId}`）：请求体必须以服务端条目原文为底，
 * 由 `MetadataDraft.buildBody` 把用户改动合并进去 —— 只提交被改的字段会让服务端
 * 把其它字段写空（`LockData` 缺失还会静默解锁）。请求形状与兜底都在 core，
 * 见 `native/core/api/item_metadata_api.*` 与 `docs/item-metadata-management.md`。
 */
@Entry
@Component
struct ItemMetadataPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;

  @State private itemId: string = '';
  @State private itemType: string = '';
  /** 服务端条目**原文**（JSON 文本）：表单回填与整体回传的唯一依据 */
  @State private rawItem: string = '';
  /** 可用的 `RemoteSearch` 端点类型；空串 = 该类型不支持识别（10.8 没有 Episode） */
  @State private remoteSearchType: string = '';
  @State private editorError: string = '';
  @State private metadataTitle: string = '';

  // 编辑器下拉数据源（core `normalizeMetadataEditorInfo` 的形状）
  @State private parentalRatings: MetadataOption[] = [];
  @State private countries: MetadataOption[] = [];
  @State private cultures: MetadataOption[] = [];
  @State private contentTypeOptions: MetadataOption[] = [];
  @State private externalIdInfos: MetadataOption[] = [];
  @State private lockedFieldChoices: LockedFieldOption[] = [];

  // ── 表单字段 ──────────────────────────────────────────────────────────
  @State private name: string = '';
  @State private originalTitle: string = '';
  @State private forcedSortName: string = '';
  @State private overview: string = '';
  @State private productionYear: string = '';
  @State private premiereDate: string = '';
  @State private officialRating: string = '';
  @State private customRating: string = '';
  @State private communityRating: string = '';
  @State private criticRating: string = '';
  @State private preferredMetadataLanguage: string = '';
  @State private preferredMetadataCountryCode: string = '';
  @State private contentType: string = '';
  @State private lockData: boolean = false;
  @State private lockedFields: string[] = [];
  @State private genresText: string = '';
  @State private tagsText: string = '';
  @State private studiosText: string = '';
  @State private locationsText: string = '';
  @State private taglinesText: string = '';
  @State private providerEntries: ProviderIdEntry[] = [];

  @State private saving: boolean = false;
  @State private refreshing: boolean = false;

  // ── 识别（远程搜索）────────────────────────────────────────────────────
  @State private searchTerm: string = '';
  @State private searchYear: string = '';
  /** 用条目当前的外部 ID 精确搜索（改错 ID 后纠正时用） */
  @State private searchByIdentifier: boolean = false;
  @State private searching: boolean = false;
  @State private candidates: RemoteSearchCandidate[] = [];
  @State private searched: boolean = false;
  @State private replaceImagesOnApply: boolean = false;

  // ── 刷新 ─────────────────────────────────────────────────────────────
  @State private refreshMode: string = 'ValidationOnly';
  @State private replaceAllMetadata: boolean = false;
  @State private replaceAllImages: boolean = false;

  // ── 封面 ─────────────────────────────────────────────────────────────
  @State private coverImages: ItemImage[] = [];
  @State private coverType: string = 'Primary';
  @State private coverUrl: string = '';
  @State private coverBusy: boolean = false;

  // ── 二次确认弹层 ──────────────────────────────────────────────────────
  @State private confirmKind: string = '';
  @State private pendingCandidate: RemoteSearchCandidate | null = null;
  @State private pendingDeleteType: string = '';
  @State private pendingDeleteIndex: number = 0;

  /** 本次进入页面是否真的改过数据（决定返回时要不要让详情页重载一次） */
  private mutated: boolean = false;
  /** 载入时的内容类型：内容类型走单独端点，只有用户改过才提交 */
  private loadedContentType: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    const params: Record<string, Object> = router.getParams() as Record<string, Object>;
    if (params !== undefined && params !== null) {
      const idVal: Object | undefined = params['itemId'];
      if (typeof idVal === 'string') {
        this.itemId = idVal;
      }
      const typeVal: Object | undefined = params['itemType'];
      if (typeof typeVal === 'string') {
        this.itemType = typeVal;
      }
      const titleVal: Object | undefined = params['title'];
      if (typeof titleVal === 'string') {
        this.metadataTitle = titleVal;
      }
    }
    this.load();
  }

  private goBack(): void {
    if (this.mutated) {
      ItemMetadataRefreshSignal.markChanged(this.itemId);
    }
    router.back();
  }

  // ── 读取 ────────────────────────────────────────────────────────────────

  private async load(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.itemMetadata(this.itemId);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取条目元数据失败';
      return;
    }
    const data: ESObject = result.data as ESObject;
    const item: ESObject | null = JsonUtil.getObject(data, 'item');
    if (item === null) {
      this.status = UiState.ERROR;
      this.errorMsg = '服务端没有返回条目内容';
      return;
    }
    this.rawItem = JsonUtil.toPretty(item);
    this.remoteSearchType = JsonUtil.getString(data, 'remoteSearchType', '');
    this.editorError = JsonUtil.getString(data, 'editorError', '');
    const serverFields: string[] = [];
    const fieldValues: Object[] = JsonUtil.getArray(data, 'metadataFields');
    for (let i = 0; i < fieldValues.length; i++) {
      serverFields.push(`${fieldValues[i]}`);
    }
    this.lockedFieldChoices = lockedFieldOptions(serverFields);

    const editor: ESObject | null = JsonUtil.getObject(data, 'editor');
    this.parentalRatings = MetadataOption.fromArray(JsonUtil.getArray(editor, 'parentalRatings'));
    this.countries = MetadataOption.fromArray(JsonUtil.getArray(editor, 'countries'));
    this.cultures = MetadataOption.fromArray(JsonUtil.getArray(editor, 'cultures'));
    this.externalIdInfos = MetadataOption.fromArray(JsonUtil.getArray(editor, 'externalIdInfos'));
    this.contentTypeOptions = MetadataOption.fromArray(
      JsonUtil.getArray(editor, 'contentTypeOptions'));
    // 内容类型不在条目 DTO 上，只在编辑器信息里（`MetadataEditorInfo.ContentType`）
    this.contentType = JsonUtil.getString(editor, 'contentType', '');
    this.loadedContentType = this.contentType;

    this.applyItemToForm(item);
    this.status = UiState.SUCCESS;
    await this.loadCoverImages();
  }

  /** 把条目原文摊到表单字段上（没请求到的字段按"空"处理，与服务端行为一致） */
  private applyItemToForm(item: ESObject): void {
    if (this.metadataTitle.length === 0) {
      this.metadataTitle = JsonUtil.getString(item, 'Name', '');
    }
    if (this.itemType.length === 0) {
      this.itemType = JsonUtil.getString(item, 'Type', '');
    }
    this.name = JsonUtil.getString(item, 'Name', '');
    this.originalTitle = JsonUtil.getString(item, 'OriginalTitle', '');
    this.forcedSortName = JsonUtil.getString(item, 'ForcedSortName', '');
    this.overview = JsonUtil.getString(item, 'Overview', '');
    this.productionYear = this.numberText(item, 'ProductionYear');
    this.premiereDate = MetadataDraft.dateOnly(JsonUtil.getString(item, 'PremiereDate', ''));
    this.officialRating = JsonUtil.getString(item, 'OfficialRating', '');
    this.customRating = JsonUtil.getString(item, 'CustomRating', '');
    this.communityRating = this.numberText(item, 'CommunityRating');
    this.criticRating = this.numberText(item, 'CriticRating');
    this.preferredMetadataLanguage = JsonUtil.getString(item, 'PreferredMetadataLanguage', '');
    this.preferredMetadataCountryCode =
      JsonUtil.getString(item, 'PreferredMetadataCountryCode', '');
    this.lockData = JsonUtil.getBoolean(item, 'LockData', false);
    this.lockedFields = this.stringList(item, 'LockedFields');
    this.genresText = MetadataDraft.toLines(this.stringList(item, 'Genres'));
    this.tagsText = MetadataDraft.toLines(this.stringList(item, 'Tags'));
    this.studiosText = MetadataDraft.toLines(this.studioNames(item));
    this.locationsText = MetadataDraft.toLines(this.stringList(item, 'ProductionLocations'));
    this.taglinesText = MetadataDraft.toLines(this.stringList(item, 'Taglines'));
    this.providerEntries = ProviderIdEntry.build(this.externalIdOptions(),
      JsonUtil.getObject(item, 'ProviderIds'));
    // 识别默认值：搜索词 = 条目名，年份 = 条目年份（Jellyfin 各客户端的惯例）
    this.searchTerm = this.name;
    this.searchYear = this.productionYear;
    this.candidates = [];
    this.searched = false;
  }

  /**
   * 外部 ID 的提供方定义。
   *
   * 编辑器信息读不到时退化成"只用条目已有的外部 ID"（`ProviderIdEntry.build` 会补上定义外的键），
   * 这样至少不会因为一个下拉数据源失败就让外部 ID 没法看、没法改。
   */
  private externalIdOptions(): MetadataOption[] {
    return this.externalIdInfos;
  }

  private stringList(item: ESObject, key: string): string[] {
    const out: string[] = [];
    const values: Object[] = JsonUtil.getArray(item, key);
    for (let i = 0; i < values.length; i++) {
      const value: string = `${values[i]}`;
      if (value.length > 0) {
        out.push(value);
      }
    }
    return out;
  }

  /** `Studios` 在条目里是 `[{ Name }]`，表单按字符串列表编辑 */
  private studioNames(item: ESObject): string[] {
    const out: string[] = [];
    const studios: Object[] = JsonUtil.getArray(item, 'Studios');
    for (let i = 0; i < studios.length; i++) {
      const src: ESObject = studios[i] as ESObject;
      const name: string = JsonUtil.getString(src, 'Name', '');
      if (name.length > 0) {
        out.push(name);
      }
    }
    return out;
  }

  private numberText(item: ESObject, key: string): string {
    const text: string = JsonUtil.valueText(item, key);
    return text;
  }

  // ── 保存 ────────────────────────────────────────────────────────────────

  private currentEdits(): ItemMetadataEdits {
    return {
      name: this.name,
      originalTitle: this.originalTitle,
      forcedSortName: this.forcedSortName,
      overview: this.overview,
      productionYear: this.productionYear,
      premiereDate: this.premiereDate,
      officialRating: this.officialRating,
      customRating: this.customRating,
      communityRating: this.communityRating,
      criticRating: this.criticRating,
      preferredMetadataLanguage: this.preferredMetadataLanguage,
      preferredMetadataCountryCode: this.preferredMetadataCountryCode,
      lockData: this.lockData,
      lockedFields: this.lockedFields,
      genres: MetadataDraft.fromLines(this.genresText),
      tags: MetadataDraft.fromLines(this.tagsText),
      studios: MetadataDraft.fromLines(this.studiosText),
      productionLocations: MetadataDraft.fromLines(this.locationsText),
      taglines: MetadataDraft.fromLines(this.taglinesText),
      providerIds: this.providerEntries
    } as ItemMetadataEdits;
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    if (this.name.trim().length === 0) {
      this.notice('名称不能为空（服务端会把它写成 null）', false);
      return;
    }
    const body: string = MetadataDraft.buildBody(this.rawItem, this.currentEdits());
    if (body.length === 0) {
      this.notice('条目原文不可解析，已中止保存（避免发一个空请求体把条目清空）', false);
      return;
    }
    this.saving = true;
    this.notice('', true);
    const raw: string = await JellyfinNative.itemUpdateMetadata(this.itemId, body);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.saving = false;
      this.notice(result.message.length > 0 ? `保存失败：${result.message}` : '保存失败', false);
      return;
    }
    // 内容类型走单独端点（不在整体替换里）：先记下旧值，保存成功后再提交
    if (this.loadedContentType !== this.contentType) {
      const typeRaw: string =
        await JellyfinNative.itemUpdateContentType(this.itemId, this.contentType);
      const typeResult: NativeResult = JellyfinNative.parseResult(typeRaw);
      if (!typeResult.ok) {
        this.saving = false;
        this.mutated = true;
        this.notice('字段已保存，但内容类型设置失败（服务端按路径写入，需管理员权限）', false);
        return;
      }
    }
    this.saving = false;
    this.mutated = true;
    this.notice('元数据已保存（服务端为整体替换，本次提交了完整条目）', true);
    await this.load();
  }

  // ── 刷新元数据 ──────────────────────────────────────────────────────────

  private async refresh(): Promise<void> {
    if (this.refreshing) {
      return;
    }
    this.refreshing = true;
    this.notice('', true);
    const raw: string = await JellyfinNative.itemRefreshMetadata(this.itemId, this.refreshMode,
      this.refreshMode, this.replaceAllMetadata, this.replaceAllImages);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.refreshing = false;
    if (!result.ok) {
      this.notice(result.message.length > 0 ? `刷新失败：${result.message}` : '刷新失败', false);
      return;
    }
    this.mutated = true;
    this.notice('已请求服务端刷新（异步执行，稍后重新进入本页可看到结果）', true);
    await this.load();
  }

  // ── 识别（远程搜索）────────────────────────────────────────────────────

  private async search(): Promise<void> {
    if (this.searching || this.remoteSearchType.length === 0) {
      return;
    }
    this.searching = true;
    this.searched = false;
    this.notice('', true);
    const providerIds: string = this.searchByIdentifier
      ? JsonUtil.toPretty(JsonUtil.getObject(JsonUtil.parseObject(this.rawItem), 'ProviderIds'))
      : '';
    const year: number | null = MetadataDraft.nullableNumber(this.searchYear);
    const raw: string = await JellyfinNative.itemRemoteSearch(this.remoteSearchType,
      this.searchTerm, providerIds, year === null ? 0 : year,
      this.preferredMetadataLanguage, this.preferredMetadataCountryCode, this.itemId);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.searching = false;
    this.searched = true;
    if (!result.ok || result.data === null) {
      this.notice(result.message.length > 0 ? `搜索失败：${result.message}` : '搜索失败', false);
      return;
    }
    this.candidates = RemoteSearchCandidate.fromArray(JsonUtil.extractItems(result.data));
    if (this.candidates.length === 0) {
      this.notice('没有找到候选条目：可以换个名字或填上发行年再试', false);
    }
  }

  private askApply(candidate: RemoteSearchCandidate): void {
    this.pendingCandidate = candidate;
    this.confirmKind = 'apply';
  }

  /** 「应用识别结果」确认文案（`@Builder` 里不好做可空收窄，文案在这里拼好） */
  private applyConfirmBody(): string {
    const candidate: RemoteSearchCandidate | null = this.pendingCandidate;
    if (candidate === null) {
      return '';
    }
    return `将用「${candidate.name}」的元数据覆盖当前条目`
      + (this.replaceImagesOnApply ? '，并替换图片' : '')
      + '。服务端会执行完整刷新（FullRefresh + ReplaceAllMetadata），你手改过的字段会被覆盖。';
  }

  private async applyCandidate(): Promise<void> {
    const candidate: RemoteSearchCandidate | null = this.pendingCandidate;
    this.confirmKind = '';
    this.pendingCandidate = null;
    if (candidate === null) {
      return;
    }
    this.notice('', true);
    const raw: string = await JellyfinNative.itemApplyRemoteSearch(this.itemId, candidate.raw,
      this.replaceImagesOnApply);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok) {
      this.notice(result.message.length > 0 ? `应用失败：${result.message}` : '应用失败', false);
      return;
    }
    this.mutated = true;
    this.candidates = [];
    this.searched = false;
    this.notice(`已应用「${candidate.name}」的元数据（原有字段已被覆盖）`, true);
    await this.load();
  }

  // ── 封面 ────────────────────────────────────────────────────────────────

  private async loadCoverImages(): Promise<void> {
    const raw: string = await JellyfinNative.libraryCoverInfo(this.itemId);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.coverImages = [];
      return;
    }
    this.coverImages = ItemImage.fromArray(JsonUtil.extractItems(result.data),
      (type: string, tag: string) => this.imageUrlOf(type, tag));
  }

  private imageUrlOf(type: string, tag: string): string {
    const raw: string = JellyfinNative.getImageUrl(this.itemId, type, 320, tag);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      return '';
    }
    return JsonUtil.getString(result.data as ESObject, 'url', '');
  }

  private async setCoverFromUrl(): Promise<void> {
    if (this.coverBusy) {
      return;
    }
    const url: string = this.coverUrl.trim();
    if (url.indexOf('http://') !== 0 && url.indexOf('https://') !== 0) {
      this.notice('图片地址必须以 http:// 或 https:// 开头', false);
      return;
    }
    this.coverBusy = true;
    this.notice('', true);
    const raw: string =
      await JellyfinNative.librarySetCoverFromUrl(this.itemId, this.coverType, url);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.coverBusy = false;
    if (!result.ok) {
      this.notice(result.message.length > 0
        ? `设置封面失败（服务器可能抓不到这个地址）：${result.message}` : '设置封面失败', false);
      return;
    }
    this.coverUrl = '';
    this.mutated = true;
    this.notice('封面已更新（由服务器抓取该地址）', true);
    await this.loadCoverImages();
  }

  private askDeleteImage(image: ItemImage): void {
    this.pendingDeleteType = image.type;
    this.pendingDeleteIndex = image.index;
    this.confirmKind = 'deleteImage';
  }

  private async deleteImage(): Promise<void> {
    const type: string = this.pendingDeleteType;
    const index: number = this.pendingDeleteIndex;
    this.confirmKind = '';
    if (type.length === 0) {
      return;
    }
    this.coverBusy = true;
    this.notice('', true);
    const raw: string = await JellyfinNative.libraryDeleteCover(this.itemId, type, index);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.coverBusy = false;
    if (!result.ok) {
      this.notice(result.message.length > 0 ? `删除失败：${result.message}` : '删除失败', false);
      return;
    }
    this.mutated = true;
    this.notice('图片已删除', true);
    await this.loadCoverImages();
  }

  // ── 小工具 ──────────────────────────────────────────────────────────────

  private notice(message: string, ok: boolean): void {
    this.actionMessage = message;
    this.actionOk = ok;
  }

  private toggleLockedField(value: string): void {
    const next: string[] = [];
    let removed: boolean = false;
    for (let i = 0; i < this.lockedFields.length; i++) {
      if (this.lockedFields[i] === value) {
        removed = true;
      } else {
        next.push(this.lockedFields[i]);
      }
    }
    if (!removed) {
      next.push(value);
    }
    this.lockedFields = next;
    this.notice('', true);
  }

  private imageTypeOptions(): MetadataOption[] {
    const out: MetadataOption[] = [];
    for (let i = 0; i < ITEM_IMAGE_TYPES.length; i++) {
      const option: MetadataOption = new MetadataOption();
      option.name = ITEM_IMAGE_TYPES[i];
      option.displayName = ITEM_IMAGE_TYPES[i];
      option.value = ITEM_IMAGE_TYPES[i];
      out.push(option);
    }
    return out;
  }

  private selectOptions(options: MetadataOption[], unsetLabel: string): SelectOption[] {
    const out: SelectOption[] = [];
    out.push({ value: unsetLabel });
    for (let i = 0; i < options.length; i++) {
      out.push({ value: options[i].displayName });
    }
    return out;
  }

  /** 当前值在 `Select` 选项里的下标（0 = "不设置"；-1 表示值不在选项里） */
  private selectIndex(options: MetadataOption[], current: string): number {
    for (let i = 0; i < options.length; i++) {
      if (options[i].value === current) {
        return i + 1;
      }
    }
    return 0;
  }

  private selectLabel(options: MetadataOption[], current: string, unsetLabel: string): string {
    const index: number = this.selectIndex(options, current);
    return index === 0 ? unsetLabel : options[index - 1].displayName;
  }

  // ── 视图 ────────────────────────────────────────────────────────────────

  /**
   * 文本输入行。
   *
   * `inputKind` 决定键盘类型：`text` / `number`（整数）/ `decimal`（带小数点）。
   * 社区评分是小数，用 `number` 会把 `6.2` 过滤成 `62`（设备实测），所以必须区分。
   */
  @Builder
  TextRow(title: string, hint: string, value: string, placeholder: string, inputKind: string,
          onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      if (hint.length > 0) {
        Text(hint)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .width('100%')
      }
      TextInput({ text: value, placeholder: placeholder })
        .width('100%')
        .height(ThemeConstants.INPUT_HEIGHT)
        .type(inputKind === 'number'
          ? InputType.Number
          : (inputKind === 'decimal' ? InputType.NUMBER_DECIMAL : InputType.Normal))
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
        .borderRadius(8)
        .onChange((text: string) => {
          onChange(text);
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 8,
      bottom: 8 })
  }

  @Builder
  TextAreaRow(title: string, hint: string, value: string, placeholder: string,
              onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      if (hint.length > 0) {
        Text(hint)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .width('100%')
      }
      TextArea({ text: value, placeholder: placeholder })
        .width('100%')
        .height(ThemeConstants.TEXTAREA_HEIGHT)
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
        .borderRadius(8)
        .onChange((text: string) => {
          onChange(text);
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 8,
      bottom: 8 })
  }

  @Builder
  SelectRow(title: string, hint: string, options: MetadataOption[], current: string,
            onPick: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      if (hint.length > 0) {
        Text(hint)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
          .width('100%')
      }
      Select(this.selectOptions(options, UNSET_LABEL))
        .value(this.selectLabel(options, current, UNSET_LABEL))
        .selected(this.selectIndex(options, current))
        .width('100%')
        .height(ThemeConstants.INPUT_HEIGHT)
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
        .border({ width: 1, color: this.colors().divider, radius: 8 })
        .onSelect((index: number, _value: string) => {
          onPick(index === 0 ? '' : options[index - 1].value);
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 8,
      bottom: 8 })
  }

  @Builder
  ToggleRow(title: string, hint: string, value: boolean, onToggle: (value: boolean) => void) {
    Row({ space: 12 }) {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
        if (hint.length > 0) {
          Text(hint)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Toggle({ type: ToggleType.Switch, isOn: value })
        .selectedColor(this.colors().brandPrimary)
        .onChange((isOn: boolean) => {
          onToggle(isOn);
        })
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
    .alignItems(VerticalAlign.Center)
  }

  @Builder
  BasicSection() {
    SectionCard({ title: '基本信息', icon: $r('sys.symbol.info_circle'), showHeaderIcon: true }) {
      Column() {
        this.TextRow('名称', '条目显示名；不能为空', this.name, '影片名', 'text',
          (value: string) => {
            this.name = value;
          })
        this.TextRow('原始标题', '外文原名（`OriginalTitle`）', this.originalTitle, '可选', 'text',
          (value: string) => {
            this.originalTitle = value;
          })
        this.TextRow('排序标题', '强制用于排序的标题（`ForcedSortName`）', this.forcedSortName,
          '留空 = 按名称排序', 'text', (value: string) => {
            this.forcedSortName = value;
          })
        this.TextAreaRow('简介', '展示在详情页的剧情简介', this.overview, '可选',
          (value: string) => {
            this.overview = value;
          })
        this.TextRow('发行年', '清空 = 从条目上移除年份', this.productionYear, '例如 2017', 'number',
          (value: string) => {
            this.productionYear = value;
          })
        this.TextRow('首播日期', 'ISO 日期，例如 2017-11-10；清空 = 移除',
          this.premiereDate, 'YYYY-MM-DD', 'text', (value: string) => {
            this.premiereDate = value;
          })
        if (this.contentTypeOptions.length > 0) {
          this.SelectRow('内容类型', '覆盖从媒体库继承的类型（服务端单独一个端点保存）',
            this.contentTypeOptions, this.contentType, (value: string) => {
              this.contentType = value;
            })
        }
      }
      .width('100%')
    }
  }

  @Builder
  CategorySection() {
    SectionCard({ title: '分类', icon: $r('sys.symbol.list_bullet'), showHeaderIcon: true }) {
      Column() {
        this.TextAreaRow('类型', '每行一项，例如：悬疑 / 犯罪', this.genresText, '每行一项',
          (value: string) => {
            this.genresText = value;
          })
        this.TextAreaRow('标签', '每行一项，用于筛选与分类', this.tagsText, '每行一项',
          (value: string) => {
            this.tagsText = value;
          })
        this.TextAreaRow('制片公司', '每行一家（服务端存为名称）', this.studiosText, '每行一家',
          (value: string) => {
            this.studiosText = value;
          })
        this.TextAreaRow('拍摄地点', '每行一个', this.locationsText, '每行一个',
          (value: string) => {
            this.locationsText = value;
          })
        this.TextAreaRow('宣传语', '服务端只保留第一行（`Taglines.FirstOrDefault()`）',
          this.taglinesText, '每行一句', (value: string) => {
            this.taglinesText = value;
          })
      }
      .width('100%')
    }
  }

  @Builder
  RatingSection() {
    SectionCard({ title: '分级与评分', icon: $r('sys.symbol.star'), showHeaderIcon: true }) {
      Column() {
        this.SelectRow('官方分级', this.parentalRatings.length > 0
          ? '来自服务端的家长分级表' : '服务端没有下发分级表，可改用下面的自定义分级',
          this.parentalRatings, this.officialRating, (value: string) => {
            this.officialRating = value;
          })
        this.TextRow('自定义分级', '服务端按字符串存（`CustomRating`）', this.customRating, '可选',
          'text', (value: string) => {
            this.customRating = value;
          })
        this.TextRow('社区评分', '0~10 的分数；清空 = 移除', this.communityRating, '例如 7.8',
          'decimal', (value: string) => {
            this.communityRating = value;
          })
        this.TextRow('影评人评分', '0~100 的分数；清空 = 移除', this.criticRating, '例如 60',
          'number', (value: string) => {
            this.criticRating = value;
          })
      }
      .width('100%')
    }
  }

  @Builder
  ExternalIdSection() {
    SectionCard({ title: '外部 ID', icon: $r('sys.symbol.key'), showHeaderIcon: true }) {
      Column() {
        if (this.providerEntries.length === 0) {
          Text('服务端没有为这个条目提供任何外部 ID 定义。')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
            .padding(ThemeConstants.PAGE_PADDING)
        }
        ForEach(this.providerEntries, (entry: ProviderIdEntry, index: number) => {
          Column({ space: 6 }) {
            Text(entry.label)
              .fontSize(ThemeConstants.TITLE_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .width('100%')
            TextInput({ text: entry.value, placeholder: `例如 ${entry.key} 的 ID` })
              .width('100%')
              .height(ThemeConstants.INPUT_HEIGHT)
              .backgroundColor(this.colors().surfacePressed)
              .fontColor(this.colors().textPrimary)
              .borderRadius(8)
              .onChange((text: string) => {
                // 直接改实例字段：`providerEntries` 本身不参与渲染，保存时读的是同一批对象
                entry.value = text;
              })
            if (index < this.providerEntries.length - 1) {
              Divider().color(this.colors().divider).strokeWidth(0.5)
            }
          }
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
            top: 8, bottom: 8 })
        }, (entry: ProviderIdEntry) => entry.key)
        Text('外部 ID 是「识别」按 ID 精确匹配的依据；清空某一项 = 从条目上移除它。')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textTertiary)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
            bottom: 12 })
      }
      .width('100%')
    }
  }

  @Builder
  LanguageSection() {
    SectionCard({ title: '语言与锁定', icon: $r('sys.symbol.lock'), showHeaderIcon: true }) {
      Column() {
        this.SelectRow('元数据语言', '抓取元数据时优先使用的语言（三字母码）',
          this.cultures, this.preferredMetadataLanguage, (value: string) => {
            this.preferredMetadataLanguage = value;
          })
        this.SelectRow('元数据国家/地区', '影响分级与首播信息（两字母码）',
          this.countries, this.preferredMetadataCountryCode, (value: string) => {
            this.preferredMetadataCountryCode = value;
          })
        this.ToggleRow('锁定条目', '锁定后服务端不再用抓取结果覆盖它（`LockData`）', this.lockData,
          (value: boolean) => {
            this.lockData = value;
          })
        Column({ space: 8 }) {
          Text('锁定的字段')
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().textPrimary)
            .width('100%')
          Text('选中的字段在刷新时不会被覆盖；取值来自服务端的 MetadataField 枚举。')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
          Flex({ wrap: FlexWrap.Wrap }) {
            ForEach(this.lockedFieldChoices, (option: LockedFieldOption) => {
              ChipButton({
                label: option.label,
                selected: this.lockedFields.indexOf(option.value) >= 0,
                onTap: () => {
                  this.toggleLockedField(option.value);
                }
              })
                .margin({ right: 8, bottom: 8 })
            }, (option: LockedFieldOption) => option.value)
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(ThemeConstants.PAGE_PADDING)
      }
      .width('100%')
    }
  }

  @Builder
  IdentifySection() {
    SectionCard({ title: '识别（远程搜索）', icon: $r('sys.symbol.magnifyingglass'),
      showHeaderIcon: true }) {
      Column() {
        this.TextRow('搜索名称', '去外部提供方（TMDb / TVDB…）搜候选条目', this.searchTerm,
          this.name, 'text', (value: string) => {
            this.searchTerm = value;
          })
        this.TextRow('发行年', '填了更准；留空 = 不限', this.searchYear, '可选', 'number',
          (value: string) => {
            this.searchYear = value;
          })
        this.ToggleRow('用当前外部 ID 精确搜索',
          '按 ID 查比按名字查准得多（改错 ID 后纠正时用）', this.searchByIdentifier,
          (value: boolean) => {
            this.searchByIdentifier = value;
          })
        Row({ space: 12 }) {
          SecondaryButton({
            label: this.searching ? '搜索中…' : '开始搜索',
            fullWidth: false,
            buttonEnabled: !this.searching,
            onTap: () => {
              this.search();
            }
          })
          Blank()
        }
        .width('100%')
        .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
          bottom: 8 })

        if (this.candidates.length > 0) {
          Text(`候选（${this.candidates.length}）—— 「应用」会用该结果覆盖当前元数据`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
              bottom: 4 })
          this.ToggleRow('同时替换图片', '把候选条目的图片一并抓取覆盖（`replaceAllImages`）',
            this.replaceImagesOnApply, (value: boolean) => {
              this.replaceImagesOnApply = value;
            })
          ForEach(this.candidates, (candidate: RemoteSearchCandidate) => {
            this.CandidateRow(candidate)
          }, (candidate: RemoteSearchCandidate) => `${candidate.name}-${candidate.raw.length}`)
        } else if (this.searched && !this.searching) {
          Text('没有候选条目。')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
            .padding(ThemeConstants.PAGE_PADDING)
        }
      }
      .width('100%')
    }
  }

  @Builder
  CandidateRow(candidate: RemoteSearchCandidate) {
    Row({ space: 12 }) {
      JellyfinImage({
        url: candidate.imageUrl,
        imgWidth: 60,
        imgHeight: 90,
        cornerRadius: 8
      })
      Column({ space: 4 }) {
        Text(candidate.name)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
        Text(candidate.subtitle())
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.colors().textSecondary)
          .maxLines(2)
        if (candidate.overview.length > 0) {
          Text(candidate.overview)
            .fontSize(ThemeConstants.LABEL_SMALL)
            .fontColor(this.colors().textTertiary)
            .maxLines(2)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      TextButton({
        label: '应用',
        onTap: () => {
          this.askApply(candidate);
        }
      })
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
    .alignItems(VerticalAlign.Top)
  }

  @Builder
  RefreshSection() {
    SectionCard({ title: '刷新元数据', icon: $r('sys.symbol.arrow_2_circlepath'),
      showHeaderIcon: true }) {
      Column() {
        Column({ space: 8 }) {
          Text('刷新模式')
            .fontSize(ThemeConstants.TITLE_MEDIUM)
            .fontColor(this.colors().textPrimary)
            .width('100%')
          Text('「仅补缺失」只填服务端认为缺的字段；「完全刷新」重新抓取并按下面两项决定是否覆盖。')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
          Row({ space: 8 }) {
            ForEach(REFRESH_MODE_OPTIONS, (option: RefreshModeOption) => {
              ChipButton({
                label: option.label,
                selected: this.refreshMode === option.value,
                onTap: () => {
                  this.refreshMode = option.value;
                  this.notice('', true);
                }
              })
            }, (option: RefreshModeOption) => option.value)
            Blank()
          }
          .width('100%')
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding(ThemeConstants.PAGE_PADDING)

        this.ToggleRow('替换全部元数据', '仅在「完全刷新」下生效：会覆盖你手改过的字段',
          this.replaceAllMetadata, (value: boolean) => {
            this.replaceAllMetadata = value;
          })
        this.ToggleRow('替换全部图片', '仅在「完全刷新」下生效：会删除并重新抓取图片',
          this.replaceAllImages, (value: boolean) => {
            this.replaceAllImages = value;
          })
        Row({ space: 12 }) {
          SecondaryButton({
            label: this.refreshing ? '已请求…' : '刷新这个条目',
            fullWidth: false,
            buttonEnabled: !this.refreshing,
            onTap: () => {
              if (this.refreshMode === 'FullRefresh' && this.replaceAllMetadata) {
                this.confirmKind = 'refreshFull';
              } else {
                this.refresh();
              }
            }
          })
          Blank()
        }
        .width('100%')
        .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
          bottom: 8 })
      }
      .width('100%')
    }
  }

  @Builder
  CoverSection() {
    SectionCard({ title: '封面与图片', icon: $r('sys.symbol.display'), showHeaderIcon: true }) {
      Column() {
        if (this.coverImages.length === 0) {
          Text('这个条目当前没有图片。')
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().textSecondary)
            .width('100%')
            .padding(ThemeConstants.PAGE_PADDING)
        }
        ForEach(this.coverImages, (image: ItemImage) => {
          Row({ space: 12 }) {
            JellyfinImage({
              url: image.url,
              imgWidth: 80,
              imgHeight: 120,
              cornerRadius: 8
            })
            Column({ space: 4 }) {
              Text(image.typeLabel())
                .fontSize(ThemeConstants.TITLE_MEDIUM)
                .fontColor(this.colors().textPrimary)
              Text(`${image.type} · ${image.sizeLabel()}`)
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().textSecondary)
            }
            .alignItems(HorizontalAlign.Start)
            .layoutWeight(1)
            TextButton({
              label: '删除',
              tone: 'danger',
              onTap: () => {
                this.askDeleteImage(image);
              }
            })
          }
          .width('100%')
          .padding(ThemeConstants.PAGE_PADDING)
          .alignItems(VerticalAlign.Top)
        }, (image: ItemImage) => `${image.type}-${image.index}-${image.url}`)

        Divider().color(this.colors().divider).strokeWidth(0.5)
        this.SelectRow('图片类型', '「海报」就是 Primary', this.imageTypeOptions(), this.coverType,
          (value: string) => {
            this.coverType = value.length > 0 ? value : 'Primary';
          })
        this.TextRow('从地址添加', '由**服务器**去抓取这个地址的图片并保存', this.coverUrl,
          'https://…', 'text', (value: string) => {
            this.coverUrl = value;
          })
        Row({ space: 12 }) {
          SecondaryButton({
            label: this.coverBusy ? '处理中…' : '抓取并设为封面',
            fullWidth: false,
            buttonEnabled: !this.coverBusy,
            onTap: () => {
              this.setCoverFromUrl();
            }
          })
          Blank()
        }
        .width('100%')
        .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
          bottom: 8 })
        Text('本地上传（`POST /Items/{itemId}/Images/{type}`，二进制体）暂未实现：'
          + '模拟器上没有可验证的图片来源。')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textTertiary)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
            bottom: 12 })
      }
      .width('100%')
    }
  }

  @Builder
  ConfirmOverlay(title: string, body: string, confirmLabel: string,
                 onConfirm: () => void) {
    Column() {
      Column({ space: 16 }) {
        Text(title)
          .fontSize(ThemeConstants.TITLE_LARGE)
          .fontWeight(FontWeight.Medium)
          .fontColor(this.colors().textPrimary)
          .width('100%')
        Text(body)
          .fontSize(ThemeConstants.BODY_MEDIUM)
          .fontColor(this.colors().textSecondary)
          .width('100%')
        Row({ space: 8 }) {
          Blank()
          TextButton({
            label: '取消',
            onTap: () => {
              this.confirmKind = '';
              this.pendingCandidate = null;
            }
          })
          Button(confirmLabel)
            .height(40)
            .padding({ left: 16, right: 16 })
            .backgroundColor(this.colors().brandPrimary)
            .fontColor(this.colors().onBrand)
            .onClick(() => {
              onConfirm();
            })
        }
        .width('100%')
      }
      .padding(24)
      .backgroundColor(this.colors().cardBackground)
      .borderRadius(28)
      .width('80%')
      .onClick(() => {
        // 阻断冒泡到遮罩，避免点卡片误关闭
      })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor(this.colors().scrim)
    .onClick(() => {
      this.confirmKind = '';
      this.pendingCandidate = null;
    })
  }

  @Builder
  Content() {
    Scroll() {
      Column() {
        if (this.editorError.length > 0) {
          Text(`编辑器信息读取失败：${this.editorError}（分级/语言下拉退化为不可选，字段仍可编辑）`)
            .fontSize(ThemeConstants.META_SMALL)
            .fontColor(this.colors().error)
            .width('100%')
            .padding(ThemeConstants.PAGE_PADDING)
        }
        this.BasicSection()
        this.CategorySection()
        this.RatingSection()
        this.ExternalIdSection()
        this.LanguageSection()
        if (this.remoteSearchType.length > 0) {
          this.IdentifySection()
        } else {
          SectionCard({ title: '识别（远程搜索）', icon: $r('sys.symbol.magnifyingglass'),
            showHeaderIcon: true }) {
            Text(`服务端没有为「${this.itemType.length > 0 ? this.itemType : '该类型'}」提供远程搜索端点`
              + '（10.8 的 ItemLookupController 不含 Episode/Season），因此本页不提供识别。'
              + '分集的元数据跟着剧走，可在剧集详情页操作。')
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.colors().textSecondary)
              .width('100%')
              .padding(ThemeConstants.PAGE_PADDING)
          }
        }
        this.RefreshSection()
        this.CoverSection()
        Blank().height(24)
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
          title: this.metadataTitle.length > 0 ? `编辑元数据 · ${this.metadataTitle}` : '编辑元数据',
          onBack: () => {
            this.goBack();
          }
        })

        if (!AppViewModel.getInstance().isAdmin) {
          EmptyState({
            message: '需要管理员权限',
            detail: '编辑元数据、识别与刷新在服务端都是 RequiresElevation 操作。',
            icon: $r('sys.symbol.lock')
          })
        } else if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState({ hint: '读取条目元数据…' })
        } else if (this.status === UiState.ERROR) {
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
            actionLabel: '重试',
            onAction: () => {
              this.load();
            }
          })
        } else {
          if (this.actionMessage.length > 0) {
            Text(this.actionMessage)
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.actionOk ? this.colors().success : this.colors().error)
              .width('100%')
              .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                top: 8, bottom: 8 })
          }
          this.Content()
          Row() {
            PrimaryButton({
              label: this.saving ? '保存中…' : '保存',
              buttonEnabled: !this.saving,
              onTap: () => {
                this.save();
              }
            })
          }
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
            top: 8, bottom: 12 })
          .backgroundColor(this.colors().cardBackground)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.confirmKind === 'apply') {
        this.ConfirmOverlay('应用识别结果', this.applyConfirmBody(), '覆盖', () => {
          this.applyCandidate();
        })
      } else if (this.confirmKind === 'deleteImage') {
        this.ConfirmOverlay('删除图片',
          `确定删除 ${this.pendingDeleteType} 吗？该操作不可撤销（服务端会删掉图片文件）。`,
          '删除', () => {
            this.deleteImage();
          })
      } else if (this.confirmKind === 'refreshFull') {
        this.ConfirmOverlay('完全刷新并替换元数据',
          '「完全刷新」+「替换全部元数据」会重新抓取并覆盖当前所有字段，包括你手改过的内容。',
          '继续', () => {
            this.confirmKind = '';
            this.refresh();
          })
      }
    }
    .width('100%')
    .height('100%')
  }
}
