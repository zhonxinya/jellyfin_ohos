import router from '@ohos.router';
import { JellyfinNative } from '../../plugins/JellyfinNative';
import { AdminLoader, AdminLoadOutcome } from '../../common/AdminLoader';
import { UiState } from '../../common/UiState';
import { AdminPageShell } from '../../components/AdminPageShell';
import { KeyValueRow } from '../../components/AdminListViews';

@Entry
@Component
struct AdminGenericPage {
  @State private title: string = '管理';
  @State private apiPath: string = '/System/Info';
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private lines: string[] = [];
  @State private rows: KeyValueRow[] = [];

  aboutToAppear(): void {
    const params: Object | undefined = router.getParams();
    if (params !== undefined && params !== null) {
      const bag: ESObject = params as ESObject;
      const t: string | undefined = bag['title'] as string | undefined;
      const p: string | undefined = bag['path'] as string | undefined;
      if (t !== undefined && t.length > 0) {
        this.title = t;
      }
      if (p !== undefined && p.length > 0) {
        this.apiPath = this.normalizePath(p);
      }
    }
    this.reload();
  }

  private normalizePath(path: string): string {
    if (path === '/System/Configuration/Branding') return '/System/Configuration/branding';
    if (path === '/System/Configuration/Network') return '/System/Configuration/network';
    if (path === '/System/Configuration/Library') return '/System/Configuration/library';
    if (path === '/System/Configuration/Nfo') return '/System/Configuration/nfo';
    if (path === '/System/Configuration/Trickplay') return '/System/Configuration/trickplay';
    return path;
  }

  private isAllowedReadPath(path: string): boolean {
    const allowed: string[] = [
      '/System/Info',
      '/System/Configuration',
      '/System/Configuration/branding',
      '/System/Configuration/network',
      '/System/Configuration/library',
      '/System/Configuration/metadata',
      '/System/Configuration/nfo',
      '/System/Configuration/trickplay',
      '/Library/VirtualFolders'
    ];
    return allowed.indexOf(path) >= 0;
  }

  private async reload(): Promise<void> {
    if (!this.isAllowedReadPath(this.apiPath)) {
      this.status = UiState.ERROR;
      this.errorMsg = '此管理页面未开放该配置路径';
      this.lines = [];
      this.rows = [];
      return;
    }
    this.status = UiState.LOADING;
    const path: string = this.apiPath;
    const out: AdminLoadOutcome = await AdminLoader.loadList(() => JellyfinNative.adminGenericGet(path));
    this.status = out.status;
    this.errorMsg = out.errorMsg;
    this.lines = out.lines;
    this.rows = out.rows;
  }

  build() {
    Column() {
      AdminPageShell({
        title: this.title,
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
