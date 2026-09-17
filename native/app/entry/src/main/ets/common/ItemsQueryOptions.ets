/**
 * Build JSON string for native queryItems NAPI.
 *
 * 字段与 Jellyfin `/Users/{userId}/Items` 的查询参数一一对应（命名刻意保持一致），
 * 原生侧 `BuildItemsQueryPath()` 会把它们拼进 query string。
 */
export class ItemsQueryOptions {
  parentId: string = '';
  startIndex: number = 0;
  limit: number = 40;
  searchTerm: string = '';
  includeItemTypes: string = '';
  sortBy: string = '';
  sortOrder: string = '';
  favoriteOnly: boolean = false;
  recursive: boolean = true;
  genreIds: string = '';
  studioIds: string = '';
  personIds: string = '';
  fields: string = '';
  mediaTypes: string = '';
  excludeItemTypes: string = '';
  enableUserData: boolean = true;
  /**
   * 观看状态筛选（Jellyfin `Filters`，逗号分隔）：
   * `IsUnplayed` 未观看 / `IsPlayed` 已观看 / `IsResumable` 播放中 / `IsFavorite` 收藏。
   * 与 `favoriteOnly` 叠加（原生侧会合并成一个 Filters 参数）。
   */
  filters: string = '';
  /** 年份筛选（`Years`，逗号分隔，如 `2019,2020`） */
  years: string = '';
  /** 官方分级（`OfficialRatings`，逗号分隔） */
  officialRatings: string = '';
  /** 最低官方分级（`MinOfficialRating`） */
  minOfficialRating: string = '';
  /** 标签（`Tags`，逗号分隔） */
  tags: string = '';
  /** 视频介质类型（`VideoTypes`，如 BluRay/Dvd/Web） */
  videoTypes: string = '';
  /** 只看高清（`IsHD=true`） */
  isHd: boolean = false;
  /** 只看 4K（`Is4K=true`） */
  is4k: boolean = false;
  /** 只看带字幕（`HasSubtitles=true`） */
  hasSubtitles: boolean = false;
  /** 请求总数（`EnableTotalRecordCount`）：界面要显示"共 N 项"而不是"已加载 N 项" */
  enableTotalRecordCount: boolean = true;

  toJson(): string {
    const obj: Record<string, Object> = {
      'parentId': this.parentId,
      'startIndex': this.startIndex,
      'limit': this.limit,
      'searchTerm': this.searchTerm,
      'includeItemTypes': this.includeItemTypes,
      'sortBy': this.sortBy,
      'sortOrder': this.sortOrder,
      'favoriteOnly': this.favoriteOnly,
      'recursive': this.recursive,
      'genreIds': this.genreIds,
      'studioIds': this.studioIds,
      'personIds': this.personIds,
      'fields': this.fields,
      'mediaTypes': this.mediaTypes,
      'excludeItemTypes': this.excludeItemTypes,
      'enableUserData': this.enableUserData,
      'filters': this.filters,
      'years': this.years,
      'officialRatings': this.officialRatings,
      'minOfficialRating': this.minOfficialRating,
      'tags': this.tags,
      'videoTypes': this.videoTypes,
      'isHd': this.isHd,
      'is4k': this.is4k,
      'hasSubtitles': this.hasSubtitles,
      'enableTotalRecordCount': this.enableTotalRecordCount
    };
    return JSON.stringify(obj);
  }
}
