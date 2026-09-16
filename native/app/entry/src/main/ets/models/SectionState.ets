import { UiState } from '../common/UiState';
import { MediaItem } from '../models/MediaItem';

/**
 * Independent load state for a home shelf section.
 */
export class SectionState {
  status: string = UiState.LOADING;
  items: MediaItem[] = [];
  errorMsg: string = '';

  static loading(): SectionState {
    const s: SectionState = new SectionState();
    s.status = UiState.LOADING;
    return s;
  }

  static data(items: MediaItem[]): SectionState {
    const s: SectionState = new SectionState();
    s.status = items.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
    s.items = items;
    return s;
  }

  static error(message: string): SectionState {
    const s: SectionState = new SectionState();
    s.status = UiState.ERROR;
    s.errorMsg = message;
    return s;
  }
}
