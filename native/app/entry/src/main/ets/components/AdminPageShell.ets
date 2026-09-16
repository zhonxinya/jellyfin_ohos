import router from '@ohos.router';
import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { UiState } from '../common/UiState';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { PageHeader } from './PageHeader';
import { EmptyState } from './EmptyState';
import { LoadingState } from './LoadingState';
import { AdminEntityList, AdminKeyValueList, KeyValueRow } from './AdminListViews';

/**
 * Shared themed shell for admin pages.
 */
@Component
export struct AdminPageShell {
  @Prop title: string = '管理';
  @Prop status: string = UiState.LOADING;
  @Prop errorMsg: string = '';
  @Prop lines: string[] = [];
  @Prop rows: KeyValueRow[] = [];
  onRetry: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Column() {
      PageHeader({
        title: this.title,
        onBack: () => {
          router.back();
        }
      })

      if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
        LoadingState({})
      } else if (this.status === UiState.ERROR || this.status === UiState.EMPTY) {
        Column() {
          EmptyState({
            message: this.status === UiState.EMPTY
              ? '暂无数据'
              : (this.errorMsg.length > 0 ? this.errorMsg : '加载失败'),
            actionLabel: this.status === UiState.ERROR ? '重试' : '',
            onAction: () => {
              this.onRetry();
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Scroll() {
          Column() {
            if (this.rows.length > 0) {
              AdminKeyValueList({ rows: this.rows })
            } else {
              AdminEntityList({ lines: this.lines })
            }
          }
          .width('100%')
          .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
          .padding({ bottom: 24 })
        }
        .layoutWeight(1)
        .width('100%')
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().background)
  }
}
