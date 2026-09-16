import { JellyfinNative } from '../../plugins/JellyfinNative';
import { AdminLoader, AdminLoadOutcome } from '../../common/AdminLoader';
import { UiState } from '../../common/UiState';
import { AdminPageShell } from '../../components/AdminPageShell';
import { KeyValueRow } from '../../components/AdminListViews';

@Entry
@Component
struct UsersMetadataPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private lines: string[] = [];
  @State private rows: KeyValueRow[] = [];

  aboutToAppear(): void {
    this.reload();
  }

  private async reload(): Promise<void> {
    this.status = UiState.LOADING;
    const out: AdminLoadOutcome = await AdminLoader.loadList(() => JellyfinNative.adminGenericGet('/System/Configuration/metadata'));
    this.status = out.status;
    this.errorMsg = out.errorMsg;
    this.lines = out.lines;
    this.rows = out.rows;
  }

  build() {
    Column() {
      AdminPageShell({
        title: '用户元数据',
        status: this.status,
        errorMsg: this.errorMsg,
        lines: this.lines,
        rows: this.rows,
        onRetry: () => {
          this.reload();
        }
      })
    }
    .width('100%')
    .height('100%')
  }
}
