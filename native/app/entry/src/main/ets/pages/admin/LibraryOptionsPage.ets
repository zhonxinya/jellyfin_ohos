import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import {
  AvailableLibraryOptions,
  EMBEDDED_SUBTITLE_CHOICES,
  EmbeddedSubtitleChoice,
  LibraryLocalization,
  LibraryOptionInfo,
  LibraryOptionSet,
  LibraryTypeOptionsInfo,
  LocalizationChoice,
  collectionTypeLabel,
  embeddedSubtitleLabel,
  countryDisplayName,
  languageDisplayName,
  parseAvailableOptions,
  parseLocalization
} from '../../common/LibraryModels';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 一个"外部条目类型"的抓取器启用状态（对应服务端 `TypeOptions[]`） */
class TypeFetcherState {
  type: string = '';
  metadataFetchers: string[] = [];
  imageFetchers: string[] = [];
}

/** 一个可勾选项：名字 + 是否勾上 + 该勾选项对应的"默认值"提示 */
class CheckItem {
  name: string = '';
  checked: boolean = false;
  defaultEnabled: boolean = false;

  constructor(name: string, checked: boolean, defaultEnabled: boolean) {
    this.name = name;
    this.checked = checked;
    this.defaultEnabled = defaultEnabled;
  }
}

/**
 * 媒体库选项（媒体库卡片 → 「媒体库选项」）。
 *
 * 服务端 `POST /Library/VirtualFolders/LibraryOptions` 是**整体替换**
 * （`CollectionFolder.UpdateLibraryOptions` → `SaveLibraryOptions`），所以：
 * - 打开时以服务端下发的完整 `LibraryOptions` 为底（`baseOptions`）；
 * - 保存时在底上写入本页改动的字段，**其余字段原样回传**（含本客户端还不认识的未来字段）；
 * - `MetadataSavers` / `SubtitleDownloadLanguages` 的 null 表示"沿用服务器全局配置"，
 *   与"显式空列表"语义不同，所以本页把"是否显式配置"单独做成开关（见 `LibraryOptionSet.isExplicit`）。
 *
 * 可选项（语言、国家、抓取器、支持的图片类型）来自
 * `GET /Libraries/AvailableOptions?libraryContentType=…&isNewLibrary=false`，
 * 其中的 `defaultEnabled` 是服务端按**全局配置**算出来的当前有效值
 * （`LibraryController.IsMetadataFetcherEnabledByDefault`），
 * 因此"本库没有 TypeOptions 条目"时用它作为勾选状态，与服务器实际行为一致。
 */
@Entry
@Component
struct LibraryOptionsPage {
  /** 服务端下发的原始选项对象：保存时的底本，保证未改动字段（含未知字段）原样回传 */
  private baseOptions: LibraryOptionSet = new LibraryOptionSet(null);
  private originalJson: string = '';

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private libraryName: string = '';
  @State private itemId: string = '';
  @State private collectionType: string = '';
  @State private available: AvailableLibraryOptions = new AvailableLibraryOptions();
  @State private localization: LibraryLocalization = new LibraryLocalization();
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  // ── 表单字段（每一项对应 `LibraryOptions` 的一个键）──
  @State private languageCode: string = '';
  @State private countryCode: string = '';
  @State private seasonZeroName: string = 'Specials';
  @State private refreshIntervalDays: number = 0;
  @State private embeddedSubtitles: string = 'AllowAll';

  @State private savers: CheckItem[] = [];
  @State private saversExplicit: boolean = false;
  @State private readers: CheckItem[] = [];
  @State private subtitleFetchers: CheckItem[] = [];
  @State private subtitleLanguages: CheckItem[] = [];
  @State private subtitleLanguagesExplicit: boolean = false;
  @State private typeStates: TypeFetcherState[] = [];
  /** 按类型抓取器的版本号：外层 ForEach 的 key 里带上它，否则内层勾选状态不会重绘 */
  @State private typeRev: number = 0;

  @State private realtimeMonitor: boolean = true;
  @State private chapterImageExtraction: boolean = false;
  @State private chapterImagesDuringScan: boolean = false;
  @State private saveLocalMetadata: boolean = false;
  @State private seriesGrouping: boolean = true;
  @State private embeddedTitles: boolean = false;
  @State private embeddedEpisodeInfos: boolean = false;
  @State private enablePhotos: boolean = true;
  @State private addToCollection: boolean = false;
  @State private skipIfEmbeddedSubtitles: boolean = false;
  @State private skipIfAudioMatches: boolean = true;
  @State private requirePerfectSubtitleMatch: boolean = true;
  @State private saveSubtitlesWithMedia: boolean = true;

  // ── 选择器浮层 ──
  @State private sheet: string = '';
  @State private sheetFilter: string = '';

  /**
   * 用户**实际改过**的"可空/列表型"字段。
   *
   * 这些字段回传时才算改动，没碰过的靠 `baseOptions` 的深拷贝原样带回：
   * - `MetadataSavers` / `SubtitleDownloadLanguages` / `LocalMetadataReaderOrder` 的 null
   *   表示"沿用服务器全局配置"，写不写不是无所谓的；
   * - `TypeOptions` 只写用户点过的条目类型，避免把"库里没有该类型条目 = 沿用全局"变成显式列表。
   *
   * 目标：**打开选项页什么都不改直接保存，服务端 JSON 必须一字不变**（设备实测验收项）。
   */
  @State private editedKeys: string[] = [];

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    const params: Object | undefined = router.getParams();
    if (params !== undefined && params !== null) {
      const bag: ESObject = params as ESObject;
      const name: string | undefined = bag['name'] as string | undefined;
      const id: string | undefined = bag['itemId'] as string | undefined;
      const type: string | undefined = bag['collectionType'] as string | undefined;
      const options: string | undefined = bag['options'] as string | undefined;
      if (name !== undefined) {
        this.libraryName = name;
      }
      if (id !== undefined) {
        this.itemId = id;
      }
      if (type !== undefined) {
        this.collectionType = type;
      }
      if (options !== undefined) {
        this.originalJson = options;
        this.baseOptions = LibraryOptionSet.fromJson(options);
      }
    }
    this.load();
  }

  /** 载入可选项 + 语言/国家，并把服务端选项摊到表单字段上 */
  private async load(): Promise<void> {
    if (this.itemId.length === 0) {
      this.status = UiState.ERROR;
      this.errorMsg = '缺少媒体库 ItemId，无法保存选项（旧版本服务端可能不返回 ItemId）。';
      return;
    }
    this.status = UiState.LOADING;
    this.errorMsg = '';

    const availableRaw: string = await JellyfinNative.libraryAvailableOptions(this.collectionType, false);
    const availableResult: NativeResult = JellyfinNative.parseResult(availableRaw);
    if (!availableResult.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = availableResult.message.length > 0 ? availableResult.message : '读取可选项失败';
      return;
    }
    this.available = parseAvailableOptions(availableResult.data);

    // 语言/国家是"锦上添花"：拿不到也让用户能改其它选项，只是选择器里只有当前值
    const localizationRaw: string = await JellyfinNative.libraryLocalization();
    const localizationResult: NativeResult = JellyfinNative.parseResult(localizationRaw);
    if (localizationResult.ok) {
      this.localization = parseLocalization(localizationResult.data);
    }

    this.applyOptionsToForm();
    this.status = UiState.SUCCESS;
  }

  private applyOptionsToForm(): void {
    const options: LibraryOptionSet = this.baseOptions;
    this.editedKeys = [];

    this.languageCode = options.getString('PreferredMetadataLanguage', '');
    this.countryCode = options.getString('MetadataCountryCode', '');
    this.seasonZeroName = options.getString('SeasonZeroDisplayName', 'Specials');
    this.refreshIntervalDays = options.getNumber('AutomaticRefreshIntervalDays', 0);
    this.embeddedSubtitles = options.getString('AllowEmbeddedSubtitles', 'AllowAll');

    this.realtimeMonitor = options.getBool('EnableRealtimeMonitor', true);
    this.chapterImageExtraction = options.getBool('EnableChapterImageExtraction', false);
    this.chapterImagesDuringScan = options.getBool('ExtractChapterImagesDuringLibraryScan', false);
    this.saveLocalMetadata = options.getBool('SaveLocalMetadata', false);
    this.seriesGrouping = options.getBool('EnableAutomaticSeriesGrouping', true);
    this.embeddedTitles = options.getBool('EnableEmbeddedTitles', false);
    this.embeddedEpisodeInfos = options.getBool('EnableEmbeddedEpisodeInfos', false);
    this.enablePhotos = options.getBool('EnablePhotos', true);
    this.addToCollection = options.getBool('AutomaticallyAddToCollection', false);
    this.skipIfEmbeddedSubtitles = options.getBool('SkipSubtitlesIfEmbeddedSubtitlesPresent', false);
    this.skipIfAudioMatches = options.getBool('SkipSubtitlesIfAudioTrackMatches', true);
    this.requirePerfectSubtitleMatch = options.getBool('RequirePerfectSubtitleMatch', true);
    this.saveSubtitlesWithMedia = options.getBool('SaveSubtitlesWithMedia', true);

    // 元数据保存器：null = 沿用全局（按 defaultEnabled 显示）
    this.saversExplicit = options.isExplicit('MetadataSavers');
    // 必须传 null（不是空数组）才能走到"用 defaultEnabled"的分支：
    // 服务端没下发这个字段时，界面要显示"服务器默认是否启用"，而不是一律不勾选
    const savers: string[] | null = this.saversExplicit
      ? options.getStringArray('MetadataSavers') : null;
    this.savers = LibraryOptionsPage.buildCheckItems(
      this.available.metadataSavers, savers, this.saversExplicit, []);

    // 本地元数据读取器 / 字幕下载器：服务端存的是"禁用列表"，界面按"启用"呈现
    this.readers = LibraryOptionsPage.buildCheckItems(
      this.available.metadataReaders, null,
      true, options.getStringArray('DisabledLocalMetadataReaders'));
    this.subtitleFetchers = LibraryOptionsPage.buildCheckItems(
      this.available.subtitleFetchers, null,
      true, options.getStringArray('DisabledSubtitleFetchers'));

    // 字幕下载语言：null = 沿用全局（表示不限制语言）
    this.subtitleLanguagesExplicit = options.isExplicit('SubtitleDownloadLanguages');
    const wanted: string[] = this.subtitleLanguagesExplicit
      ? options.getStringArray('SubtitleDownloadLanguages') : [];
    const langItems: CheckItem[] = [];
    for (let i = 0; i < this.localization.languages.length; i++) {
      const choice: LocalizationChoice = this.localization.languages[i];
      langItems.push(new CheckItem(choice.name,
        !this.subtitleLanguagesExplicit || LibraryOptionSet.contains(wanted, choice.name), true));
    }
    this.subtitleLanguages = langItems;

    // 按类型：库里有条目就用它，没有就用服务端的 defaultEnabled（= 全局配置的当前有效值）
    const states: TypeFetcherState[] = [];
    for (let i = 0; i < this.available.typeOptions.length; i++) {
      const info: LibraryTypeOptionsInfo = this.available.typeOptions[i];
      const state: TypeFetcherState = new TypeFetcherState();
      state.type = info.type;
      const metadata: string[] | null = options.metadataFetchers(info.type);
      const images: string[] | null = options.imageFetchers(info.type);
      state.metadataFetchers = LibraryOptionsPage.effectiveNames(info.metadataFetchers, metadata);
      state.imageFetchers = LibraryOptionsPage.effectiveNames(info.imageFetchers, images);
      states.push(state);
    }
    this.typeStates = states;
  }

  /**
   * 是否有未保存的改动 —— **直接比较待提交的 payload 与载入时的 JSON**，
   * 不维护布尔标记。
   *
   * 原因：ArkUI 里 `TextInput` / `Toggle` 被程序化回填时也会触发 `onChange`，
   * "用户是否改过"用事件标记根本判不准（实测进页面就显示"有未保存的修改"）。
   * 而 `buildPayload()` 是恒等的（没编辑过时 clone 出来的 JSON 与载入时逐字节相同），
   * 所以字符串比较既准又不需要额外的抑制逻辑。
   */
  private isDirty(): boolean {
    return this.buildPayload() !== this.originalJson;
  }

  /**
   * 计算某个类型下"当前启用"的抓取器名字。
   * `configured` 为 null 表示库里没有该类型的条目 → 回落到服务端给的 `defaultEnabled`
   * （它由全局 `MetadataOptions` 算出，与服务器实际生效的行为一致）。
   */
  private static effectiveNames(options: LibraryOptionInfo[], configured: string[] | null): string[] {
    const out: string[] = [];
    for (let i = 0; i < options.length; i++) {
      const name: string = options[i].name;
      const on: boolean = configured === null
        ? options[i].defaultEnabled
        : LibraryOptionSet.contains(configured, name);
      if (on) {
        out.push(name);
      }
    }
    return out;
  }

  /** 勾选项列表；`configured` 非 null 时用它判定勾选，否则用 `defaultEnabled`（并排除禁用列表里的项） */
  private static buildCheckItems(options: LibraryOptionInfo[], configured: string[] | null,
                                 useDefault: boolean, disabled: string[]): CheckItem[] {
    const out: CheckItem[] = [];
    for (let i = 0; i < options.length; i++) {
      const name: string = options[i].name;
      let checked: boolean;
      if (configured !== null) {
        checked = LibraryOptionSet.contains(configured, name);
      } else if (useDefault) {
        checked = !LibraryOptionSet.contains(disabled, name);
      } else {
        checked = options[i].defaultEnabled;
      }
      out.push(new CheckItem(name, checked, options[i].defaultEnabled));
    }
    return out;
  }

  private touch(key: string = ''): void {
    if (key.length > 0 && this.editedKeys.indexOf(key) < 0) {
      this.editedKeys = this.editedKeys.concat([key]);
    }
    this.actionMessage = '';
  }

  private toggleCheck(items: CheckItem[], index: number, on: boolean): CheckItem[] {
    const next: CheckItem[] = [];
    for (let i = 0; i < items.length; i++) {
      next.push(new CheckItem(items[i].name, i === index ? on : items[i].checked,
        items[i].defaultEnabled));
    }
    return next;
  }

  /** 按勾选事件的值**直接赋值**（而不是取反）：程序化重设 `select` 若再次触发 onChange，状态也不会来回翻转 */
  private applyCheck(kind: string, index: number, on: boolean): void {
    if (kind === 'savers') {
      this.savers = this.toggleCheck(this.savers, index, on);
      // 取消勾选同样意味着"用户显式接管了这个列表"：只在勾选时置 true，
      // 会让"先取消一个"被当成"沿用全局"而在保存时丢掉
      this.saversExplicit = true;
      this.touch('MetadataSavers');
      return;
    }
    if (kind === 'readers') {
      this.readers = this.toggleCheck(this.readers, index, on);
      this.touch('DisabledLocalMetadataReaders');
      return;
    }
    if (kind === 'fetchers') {
      this.subtitleFetchers = this.toggleCheck(this.subtitleFetchers, index, on);
      this.touch('DisabledSubtitleFetchers');
      return;
    }
    if (kind === 'languages') {
      this.subtitleLanguages = this.toggleCheck(this.subtitleLanguages, index, on);
      // 同上：取消勾选也要落到"显式列表"，否则改动不生效
      this.subtitleLanguagesExplicit = true;
      this.touch('SubtitleDownloadLanguages');
      return;
    }
    this.touch();
  }

  private selectedNames(items: CheckItem[]): string[] {
    const out: string[] = [];
    for (let i = 0; i < items.length; i++) {
      if (items[i].checked) {
        out.push(items[i].name);
      }
    }
    return out;
  }

  private setTypeFetcher(typeIndex: number, fetcherIndex: number, isImage: boolean,
                        on: boolean): void {
    const next: TypeFetcherState[] = [];
    for (let i = 0; i < this.typeStates.length; i++) {
      const state: TypeFetcherState = new TypeFetcherState();
      state.type = this.typeStates[i].type;
      state.metadataFetchers = this.typeStates[i].metadataFetchers.slice();
      state.imageFetchers = this.typeStates[i].imageFetchers.slice();
      if (i === typeIndex) {
        const info: LibraryTypeOptionsInfo = this.available.typeOptions[i];
        const pool: LibraryOptionInfo[] = isImage ? info.imageFetchers : info.metadataFetchers;
        const current: string[] = isImage ? state.imageFetchers : state.metadataFetchers;
        const updated: string[] = LibraryOptionSet.toggle(current, pool[fetcherIndex].name, on);
        if (isImage) {
          state.imageFetchers = updated;
        } else {
          state.metadataFetchers = updated;
        }
      }
      next.push(state);
    }
    this.typeStates = next;
    // 外层 ForEach 的 key 里带了这一版号：不然内层勾选状态因为 key 未变而不会重绘
    this.typeRev = this.typeRev + 1;
    this.touch(`TypeOptions:${this.typeStates[typeIndex].type}`);
  }

  /**
   * 把表单写回 `baseOptions` 的副本并提交。
   *
   * 两类字段的处理不同：
   * - **不可空字段**（开关、字符串、数字）：`baseOptions` 已经由 C++ 归一化补齐了与 C# 构造函数
   *   一致的默认值，本页读到的就是服务端的值，原样写回是恒等操作；
   * - **可空/列表型字段**：只在 `editedKeys` 里出现过才写，否则靠 `clone()` 原样带回。
   *   这样"打开页面什么都不改直接保存"就是一次恒等提交（设备实测验收项）。
   */
  private buildPayload(): string {
    const draft: LibraryOptionSet = this.baseOptions.clone();
    const edited = (key: string): boolean => this.editedKeys.indexOf(key) >= 0;

    draft.setString('PreferredMetadataLanguage', this.languageCode);
    draft.setString('MetadataCountryCode', this.countryCode);
    draft.setString('SeasonZeroDisplayName', this.seasonZeroName.length > 0
      ? this.seasonZeroName : 'Specials');
    draft.setNumber('AutomaticRefreshIntervalDays',
      this.refreshIntervalDays > 0 ? Math.floor(this.refreshIntervalDays) : 0);
    draft.setString('AllowEmbeddedSubtitles', this.embeddedSubtitles);

    draft.setBool('EnableRealtimeMonitor', this.realtimeMonitor);
    draft.setBool('EnableChapterImageExtraction', this.chapterImageExtraction);
    draft.setBool('ExtractChapterImagesDuringLibraryScan', this.chapterImagesDuringScan);
    draft.setBool('SaveLocalMetadata', this.saveLocalMetadata);
    draft.setBool('EnableAutomaticSeriesGrouping', this.seriesGrouping);
    draft.setBool('EnableEmbeddedTitles', this.embeddedTitles);
    draft.setBool('EnableEmbeddedEpisodeInfos', this.embeddedEpisodeInfos);
    draft.setBool('EnablePhotos', this.enablePhotos);
    draft.setBool('AutomaticallyAddToCollection', this.addToCollection);
    draft.setBool('SkipSubtitlesIfEmbeddedSubtitlesPresent', this.skipIfEmbeddedSubtitles);
    draft.setBool('SkipSubtitlesIfAudioTrackMatches', this.skipIfAudioMatches);
    draft.setBool('RequirePerfectSubtitleMatch', this.requirePerfectSubtitleMatch);
    draft.setBool('SaveSubtitlesWithMedia', this.saveSubtitlesWithMedia);

    // 元数据保存器：null = 沿用服务器全局配置（与空数组语义不同）
    if (edited('MetadataSavers')) {
      if (this.saversExplicit) {
        draft.setStringArray('MetadataSavers', this.selectedNames(this.savers));
      } else {
        draft.clearKey('MetadataSavers');
      }
    }

    // 本地元数据读取器：服务端存的是"禁用列表"，顺序用启用顺序
    if (edited('DisabledLocalMetadataReaders')) {
      const readersOn: string[] = this.selectedNames(this.readers);
      const readersOff: string[] = [];
      for (let i = 0; i < this.readers.length; i++) {
        if (!this.readers[i].checked) {
          readersOff.push(this.readers[i].name);
        }
      }
      draft.setStringArray('DisabledLocalMetadataReaders', readersOff);
      draft.setStringArray('LocalMetadataReaderOrder', readersOn);
    }

    // 字幕下载器：同上（禁用列表 + 启用顺序）
    if (edited('DisabledSubtitleFetchers')) {
      const fetchersOn: string[] = this.selectedNames(this.subtitleFetchers);
      const fetchersOff: string[] = [];
      for (let i = 0; i < this.subtitleFetchers.length; i++) {
        if (!this.subtitleFetchers[i].checked) {
          fetchersOff.push(this.subtitleFetchers[i].name);
        }
      }
      draft.setStringArray('DisabledSubtitleFetchers', fetchersOff);
      draft.setStringArray('SubtitleFetcherOrder', fetchersOn);
    }

    if (edited('SubtitleDownloadLanguages')) {
      if (this.subtitleLanguagesExplicit) {
        draft.setStringArray('SubtitleDownloadLanguages',
          this.selectedNames(this.subtitleLanguages));
      } else {
        draft.clearKey('SubtitleDownloadLanguages');
      }
    }

    // 按条目类型的抓取器：只写用户点过的类型，避免把"沿用全局"变成显式列表
    for (let i = 0; i < this.typeStates.length; i++) {
      const type: string = this.typeStates[i].type;
      if (!edited(`TypeOptions:${type}`)) {
        continue;
      }
      draft.setMetadataFetchers(type, this.typeStates[i].metadataFetchers);
      draft.setImageFetchers(type, this.typeStates[i].imageFetchers);
    }

    return draft.toJson();
  }

  private async save(): Promise<void> {
    if (this.saving) {
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    const raw: string = await JellyfinNative.libraryUpdateOptions(this.itemId, this.buildPayload());
    const result: NativeResult = JellyfinNative.parseResult(raw);
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = '媒体库选项已保存';
    router.back();
  }

  private resetForm(): void {
    this.baseOptions = LibraryOptionSet.fromJson(this.originalJson);
    this.applyOptionsToForm();
    this.actionMessage = '已恢复为上次从服务器读取的选项（尚未提交）';
    this.actionOk = true;
  }

  // ── 视图 ────────────────────────────────────────────────────────────────

  /**
   * 勾选列表。
   *
   * `kind` 决定回写哪个表单字段（`savers` / `readers` / `fetchers` / `languages` / `type`），
   * `typeIndex >= 0` 表示这是"某个条目类型的抓取器"（写进 `TypeOptions`）。
   *
   * 两点 ArkUI 细节：
   * - `ForEach` 的 key 里带上 `checked`：key 不变时 ForEach 不会重建条目，
   *   勾选框就会停留在旧状态；
   * - `Checkbox.onChange` 给的是**事件后的值**，直接赋值而不是取反，
   *   这样即使程序化重设 `select` 又触发一次回调，状态也只会收敛不会翻转。
   */
  @Builder
  CheckList(title: string, items: CheckItem[], kind: string, isImage: boolean, typeIndex: number) {
    Column() {
      ForEach(items, (item: CheckItem, index: number) => {
        Row({ space: 8 }) {
          Column({ space: 2 }) {
            Text(item.name)
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
            Text(item.defaultEnabled ? '服务器默认为启用' : '服务器默认为关闭')
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.colors().textTertiary)
          }
          .alignItems(HorizontalAlign.Start)
          .layoutWeight(1)

          Checkbox()
            .select(item.checked)
            .selectedColor(this.colors().brandPrimary)
            .onChange((value: boolean) => {
              if (typeIndex >= 0) {
                this.setTypeFetcher(typeIndex, index, isImage, value);
              } else {
                this.applyCheck(kind, index, value);
              }
            })
        }
        .width('100%')
        .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 10, bottom: 10 })
      }, (item: CheckItem) => `${title}-${item.name}-${item.checked ? 1 : 0}`)
    }
    .width('100%')
  }

  @Builder
  ToggleCell(title: string, subtitle: string, on: boolean, onToggle: (value: boolean) => void) {
    SettingCell({
      title: title,
      subtitle: subtitle,
      showToggle: true,
      toggleOn: on,
      onToggle: (value: boolean) => {
        onToggle(value);
        this.touch();
      }
    })
  }

  @Builder
  SectionHeaderText(text: string) {
    Text(text)
      .fontSize(ThemeConstants.META_SMALL)
      .fontColor(this.colors().textSecondary)
      .width('100%')
      .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 10, bottom: 4 })
  }

  @Builder
  SingleChoiceSheet(title: string, items: LocalizationChoice[], selected: string, kind: string) {
    Column({ space: 10 }) {
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      TextInput({ text: this.sheetFilter, placeholder: '筛选' })
        .width('100%')
        .onChange((value: string) => {
          this.sheetFilter = value;
        })
      List({ space: 2 }) {
        ListItem() {
          Row() {
            Text('服务器默认')
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .layoutWeight(1)
            if (selected.length === 0) {
              SymbolGlyph($r('sys.symbol.checkmark'))
                .fontSize(ThemeConstants.ICON_SMALL)
                .fontColor([this.colors().brandPrimary])
            }
          }
          .width('100%')
          .padding({ top: 10, bottom: 10 })
          .onClick(() => {
            if (kind === 'language') {
              this.languageCode = '';
            } else {
              this.countryCode = '';
            }
            this.sheet = '';
            this.sheetFilter = '';
            this.touch();
          })
        }
        ForEach(LibraryOptionsPage.filterChoices(items, this.sheetFilter),
          (choice: LocalizationChoice) => {
            ListItem() {
              Row() {
                Text(choice.displayName)
                  .fontSize(ThemeConstants.BODY_MEDIUM)
                  .fontColor(this.colors().textPrimary)
                  .layoutWeight(1)
                  .maxLines(1)
                  .textOverflow({ overflow: TextOverflow.Ellipsis })
                Text(choice.name)
                  .fontSize(ThemeConstants.META_SMALL)
                  .fontColor(this.colors().textTertiary)
                if (choice.name === selected) {
                  SymbolGlyph($r('sys.symbol.checkmark'))
                    .fontSize(ThemeConstants.ICON_SMALL)
                    .fontColor([this.colors().brandPrimary])
                    .margin({ left: 8 })
                }
              }
              .width('100%')
              .padding({ top: 10, bottom: 10 })
              .onClick(() => {
                if (kind === 'language') {
                  this.languageCode = choice.name;
                } else {
                  this.countryCode = choice.name;
                }
                this.sheet = '';
                this.sheetFilter = '';
                this.touch();
              })
            }
          }, (choice: LocalizationChoice) => choice.name)
      }
      .width('100%')
      .height(320)
      .scrollBar(BarState.Auto)
      Button('关闭')
        .width('100%')
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
        .onClick(() => {
          this.sheet = '';
          this.sheetFilter = '';
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
  EmbeddedSubtitleSheet() {
    Column({ space: 10 }) {
      Text('内嵌字幕')
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      ForEach(EMBEDDED_SUBTITLE_CHOICES, (choice: EmbeddedSubtitleChoice) => {
        Row() {
          Text(choice.label)
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontColor(this.colors().textPrimary)
            .layoutWeight(1)
          if (choice.value === this.embeddedSubtitles) {
            SymbolGlyph($r('sys.symbol.checkmark'))
              .fontSize(ThemeConstants.ICON_SMALL)
              .fontColor([this.colors().brandPrimary])
          }
        }
        .width('100%')
        .padding({ top: 12, bottom: 12 })
        .onClick(() => {
          this.embeddedSubtitles = choice.value;
          this.sheet = '';
          this.touch();
        })
      }, (choice: EmbeddedSubtitleChoice) => choice.value)
      Button('关闭')
        .width('100%')
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textPrimary)
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

  private static filterChoices(items: LocalizationChoice[], filter: string): LocalizationChoice[] {
    const needle: string = filter.trim().toLowerCase();
    if (needle.length === 0) {
      return items;
    }
    const out: LocalizationChoice[] = [];
    for (let i = 0; i < items.length; i++) {
      const choice: LocalizationChoice = items[i];
      if (choice.name.toLowerCase().indexOf(needle) >= 0
        || choice.displayName.toLowerCase().indexOf(needle) >= 0) {
        out.push(choice);
      }
    }
    return out;
  }

  @Builder
  Body() {
    Scroll() {
      Column() {
        // ── 常规 ─────────────────────────────────────────────
        SectionCard({ title: '常规', icon: $r('sys.symbol.gearshape'), showHeaderIcon: true }) {
          Column() {
            SettingCell({
              title: '首选元数据语言',
              subtitle: '抓取元数据时优先使用的语言；留空表示沿用服务器默认',
              valueText: languageDisplayName(this.localization, this.languageCode),
              showIcon: true,
              icon: $r('sys.symbol.message'),
              showChevron: true,
              onTap: () => {
                this.sheetFilter = '';
                this.sheet = 'language';
              }
            })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            SettingCell({
              title: '元数据国家/地区',
              subtitle: '影响分级、发行日期等地区相关字段',
              valueText: countryDisplayName(this.localization, this.countryCode),
              showIcon: true,
              icon: $r('sys.symbol.rectangle_stack'),
              showChevron: true,
              onTap: () => {
                this.sheetFilter = '';
                this.sheet = 'country';
              }
            })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            SettingCell({
              title: '内嵌字幕',
              subtitle: '允许使用文件里内嵌的字幕类型',
              valueText: embeddedSubtitleLabel(this.embeddedSubtitles),
              showIcon: true,
              icon: $r('sys.symbol.textformat'),
              showChevron: true,
              onTap: () => {
                this.sheet = 'embeddedSubs';
              }
            })
          }
          .width('100%')
        }

        SectionCard({ title: '季与剧集', icon: $r('sys.symbol.rectangle_stack'), showHeaderIcon: true }) {
          Column() {
            Row({ space: 8 }) {
              Column({ space: 4 }) {
                Text('第 0 季显示名称')
                  .fontSize(ThemeConstants.TITLE_MEDIUM)
                  .fontColor(this.colors().textPrimary)
                Text('特别篇所在的季在界面上显示成什么名字')
                  .fontSize(ThemeConstants.META_SMALL)
                  .fontColor(this.colors().textSecondary)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              TextInput({ text: this.seasonZeroName, placeholder: 'Specials' })
                .width(140)
                .onChange((value: string) => {
                  this.seasonZeroName = value;
                  this.touch();
                })
            }
            .width('100%')
            .padding(ThemeConstants.PAGE_PADDING)

            Divider().color(this.colors().divider).strokeWidth(0.5)

            Row({ space: 8 }) {
              Column({ space: 4 }) {
                Text('自动刷新间隔（天）')
                  .fontSize(ThemeConstants.TITLE_MEDIUM)
                  .fontColor(this.colors().textPrimary)
                Text('0 表示不按固定周期自动刷新（仍可在卡片上手动扫描）')
                  .fontSize(ThemeConstants.META_SMALL)
                  .fontColor(this.colors().textSecondary)
              }
              .alignItems(HorizontalAlign.Start)
              .layoutWeight(1)
              TextInput({ text: `${this.refreshIntervalDays}`, placeholder: '0' })
                .type(InputType.Number)
                .width(100)
                .onChange((value: string) => {
                  const parsed: number = Number(value);
                  this.refreshIntervalDays = Number.isNaN(parsed) ? 0 : parsed;
                  this.touch();
                })
            }
            .width('100%')
            .padding(ThemeConstants.PAGE_PADDING)
          }
          .width('100%')
        }

        // ── 行为开关 ─────────────────────────────────────────
        SectionCard({ title: '媒体库行为', icon: $r('sys.symbol.list_bullet'),
          showHeaderIcon: true }) {
          Column() {
            this.ToggleCell('实时监控', '文件变化后自动更新媒体库（服务器需支持目录监控）',
              this.realtimeMonitor, (value: boolean) => {
                this.realtimeMonitor = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('提取章节图片', '为每个章节生成预览图（占用磁盘与 CPU）',
              this.chapterImageExtraction, (value: boolean) => {
                this.chapterImageExtraction = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('扫描时提取章节图片', '关闭则只在后台任务里做',
              this.chapterImagesDuringScan, (value: boolean) => {
                this.chapterImagesDuringScan = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('图片保存到媒体文件夹', '把抓到的图片写回媒体目录，而不是只放在服务器元数据目录',
              this.saveLocalMetadata, (value: boolean) => {
                this.saveLocalMetadata = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('自动剧集分组', '按文件名自动把视频归到剧集下',
              this.seriesGrouping, (value: boolean) => {
                this.seriesGrouping = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('使用内嵌标题', '优先使用文件内嵌的标题',
              this.embeddedTitles, (value: boolean) => {
                this.embeddedTitles = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('使用内嵌剧集信息', '优先使用文件内嵌的季/集号',
              this.embeddedEpisodeInfos, (value: boolean) => {
                this.embeddedEpisodeInfos = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('显示照片', '把图片文件也作为媒体条目',
              this.enablePhotos, (value: boolean) => {
                this.enablePhotos = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('自动加入合集', '属于同一合集时自动建立合集条目',
              this.addToCollection, (value: boolean) => {
                this.addToCollection = value;
              })
          }
          .width('100%')
        }

        // ── 字幕 ─────────────────────────────────────────────
        SectionCard({ title: '字幕', icon: $r('sys.symbol.message'), showHeaderIcon: true }) {
          Column() {
            this.ToggleCell('有内嵌字幕时跳过下载', '已经内嵌了字幕就不再下载外挂字幕',
              this.skipIfEmbeddedSubtitles, (value: boolean) => {
                this.skipIfEmbeddedSubtitles = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('音轨匹配时跳过下载', '按音频语言判断是否还需要字幕',
              this.skipIfAudioMatches, (value: boolean) => {
                this.skipIfAudioMatches = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('只下载完美匹配的字幕', '关闭后允许下载相似匹配的字幕',
              this.requirePerfectSubtitleMatch, (value: boolean) => {
                this.requirePerfectSubtitleMatch = value;
              })
            Divider().color(this.colors().divider).strokeWidth(0.5)
            this.ToggleCell('字幕保存到媒体文件夹', '把字幕文件写回媒体目录',
              this.saveSubtitlesWithMedia, (value: boolean) => {
                this.saveSubtitlesWithMedia = value;
              })

            if (this.subtitleFetchers.length > 0) {
              Divider().color(this.colors().divider).strokeWidth(0.5)
              this.SectionHeaderText('字幕下载器')
              this.CheckList('字幕下载器', this.subtitleFetchers, 'fetchers', false, -1)
            }

            if (this.subtitleLanguages.length > 0) {
              Divider().color(this.colors().divider).strokeWidth(0.5)
              Row() {
                Column({ space: 2 }) {
                  Text('限制字幕下载语言')
                    .fontSize(ThemeConstants.TITLE_MEDIUM)
                    .fontColor(this.colors().textPrimary)
                  Text(this.subtitleLanguagesExplicit
                    ? '已按下面勾选的语言下载'
                    : '未限制：沿用服务器全局字幕语言设置')
                    .fontSize(ThemeConstants.META_SMALL)
                    .fontColor(this.colors().textSecondary)
                }
                .alignItems(HorizontalAlign.Start)
                .layoutWeight(1)
                Toggle({ type: ToggleType.Switch, isOn: this.subtitleLanguagesExplicit })
                  .selectedColor(this.colors().brandPrimary)
                  .onChange((value: boolean) => {
                    this.subtitleLanguagesExplicit = value;
                    this.touch('SubtitleDownloadLanguages');
                  })
              }
              .width('100%')
              .padding(ThemeConstants.PAGE_PADDING)

              if (this.subtitleLanguagesExplicit) {
                this.CheckList('字幕下载语言', this.subtitleLanguages, 'languages', false, -1)
              }
            }
          }
          .width('100%')
        }

        // ── 元数据保存器 / 读取器 ─────────────────────────────
        if (this.savers.length > 0 || this.readers.length > 0) {
          SectionCard({ title: '元数据读写', icon: $r('sys.symbol.doc_text'), showHeaderIcon: true }) {
            Column() {
              if (this.savers.length > 0) {
                Row() {
                  Column({ space: 2 }) {
                    Text('元数据保存器')
                      .fontSize(ThemeConstants.TITLE_MEDIUM)
                      .fontColor(this.colors().textPrimary)
                    Text(this.saversExplicit
                      ? '已按下面勾选的结果保存元数据'
                      : '未显式配置：沿用服务器全局的元数据保存设置')
                      .fontSize(ThemeConstants.META_SMALL)
                      .fontColor(this.colors().textSecondary)
                  }
                  .alignItems(HorizontalAlign.Start)
                  .layoutWeight(1)
                  Toggle({ type: ToggleType.Switch, isOn: this.saversExplicit })
                    .selectedColor(this.colors().brandPrimary)
                    .onChange((value: boolean) => {
                      this.saversExplicit = value;
                      this.touch('MetadataSavers');
                    })
                }
                .width('100%')
                .padding(ThemeConstants.PAGE_PADDING)

                if (this.saversExplicit) {
                  this.CheckList('元数据保存器', this.savers, 'savers', false, -1)
                }
              }

              if (this.savers.length > 0 && this.readers.length > 0) {
                Divider().color(this.colors().divider).strokeWidth(0.5)
              }

              if (this.readers.length > 0) {
                this.SectionHeaderText('本地元数据读取器（nfo / xml 等本地文件）')
                this.CheckList('本地元数据读取器', this.readers, 'readers', false, -1)
              }
            }
            .width('100%')
          }
        }

        // ── 按条目类型的抓取器 ────────────────────────────────
        ForEach(this.typeStates, (state: TypeFetcherState, typeIndex: number) => {
          SectionCard({ title: LibraryOptionsPage.typeLabel(state.type), withMargin: true }) {
            Column() {
              if (LibraryOptionsPage.typeMetadata(this.available, state.type).length > 0) {
                this.SectionHeaderText('元数据抓取器')
                this.CheckList(`元数据-${state.type}`,
                  LibraryOptionsPage.checkItemsFor(
                    LibraryOptionsPage.typeMetadata(this.available, state.type),
                    state.metadataFetchers), 'type', false, typeIndex)
              }
              if (LibraryOptionsPage.typeImages(this.available, state.type).length > 0) {
                Divider().color(this.colors().divider).strokeWidth(0.5)
                this.SectionHeaderText('图片获取器')
                this.CheckList(`图片-${state.type}`,
                  LibraryOptionsPage.checkItemsFor(
                    LibraryOptionsPage.typeImages(this.available, state.type),
                    state.imageFetchers), 'type', true, typeIndex)
              }
            }
            .width('100%')
          }
        }, (state: TypeFetcherState) => `${state.type}#${this.typeRev}`)

        Text('说明：这些设置会写入服务器的媒体库配置。取消勾选一个抓取器后，'
          + '已有条目不会被重新抓取，直到下一次刷新。')
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textTertiary)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 8 })

        Blank().height(80)
      }
      .width('100%')
      .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
    }
    .width('100%')
    .layoutWeight(1)
    .scrollBar(BarState.Auto)
  }

  private static typeLabel(type: string): string {
    if (type === 'Movie') return '电影';
    if (type === 'Series') return '剧集（剧集）';
    if (type === 'Season') return '剧集（季）';
    if (type === 'Episode') return '剧集（集）';
    if (type === 'MusicAlbum') return '音乐（专辑）';
    if (type === 'MusicArtist') return '音乐（艺术家）';
    if (type === 'MusicVideo') return '音乐视频';
    if (type === 'BoxSet') return '合集';
    if (type === 'Book') return '书籍';
    if (type === 'Video') return '视频';
    if (type === 'Photo') return '照片';
    return type;
  }

  private static typeMetadata(available: AvailableLibraryOptions, type: string): LibraryOptionInfo[] {
    for (let i = 0; i < available.typeOptions.length; i++) {
      if (available.typeOptions[i].type === type) {
        return available.typeOptions[i].metadataFetchers;
      }
    }
    return [];
  }

  private static typeImages(available: AvailableLibraryOptions, type: string): LibraryOptionInfo[] {
    for (let i = 0; i < available.typeOptions.length; i++) {
      if (available.typeOptions[i].type === type) {
        return available.typeOptions[i].imageFetchers;
      }
    }
    return [];
  }

  /** 用"已启用名字集合"渲染勾选状态（`enabled` 里没有的就是未勾选） */
  private static checkItemsFor(options: LibraryOptionInfo[], enabled: string[]): CheckItem[] {
    const out: CheckItem[] = [];
    for (let i = 0; i < options.length; i++) {
      out.push(new CheckItem(options[i].name, LibraryOptionSet.contains(enabled, options[i].name),
        options[i].defaultEnabled));
    }
    return out;
  }

  @Builder
  Footer() {
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
      Button(this.saving ? '保存中...' : (this.actionMessage.length > 0 && this.actionOk
        ? '已保存' : '保存'))
        .layoutWeight(2)
        .height(44)
        .backgroundColor(this.colors().brandPrimary)
        .fontColor(this.colors().onBrand)
        .enabled(!this.saving)
        .onClick(() => {
          this.save();
        })
    }
    .width('100%')
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
      top: 8, bottom: 8 })
    .backgroundColor(this.colors().cardBackground)
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '媒体库选项',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text(`${this.libraryName} · ${collectionTypeLabel(this.collectionType)}`)
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
            if (this.actionMessage.length > 0) {
              Text(this.actionMessage)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.actionOk ? this.colors().success : this.colors().error)
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
          this.Footer()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.sheet.length > 0) {
        Column() {
          if (this.sheet === 'language') {
            this.SingleChoiceSheet('首选元数据语言', this.localization.languages, this.languageCode, 'language')
          } else if (this.sheet === 'country') {
            this.SingleChoiceSheet('元数据国家/地区', this.localization.countries, this.countryCode, 'country')
          } else {
            this.EmbeddedSubtitleSheet()
          }
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.sheet = '';
          this.sheetFilter = '';
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
