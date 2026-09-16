/**
 * Build JSON string for native queryItems NAPI.
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
      'enableUserData': this.enableUserData
    };
    return JSON.stringify(obj);
  }
}
