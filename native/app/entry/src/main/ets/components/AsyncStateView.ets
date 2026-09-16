import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { UiState } from '../common/UiState';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { EmptyState } from './EmptyState';
import { LoadingState } from './LoadingState';

/**
 * 异步状态视图（兼容壳）—— 内部实现已换成 mybooks_ohos 的 `LoadingState` / `EmptyState`。
 *
 * 参考项目的约定：加载态是「48vp 品牌色转圈 + 14fp 提示」，**错误态复用空态**（配"重试"），
 * 不额外造错误组件。本组件保留 `status` / `message` / `emptyHint` / `minHeight` / `onRetry`
 * 原 API，因此 22 个既有调用点无需改动即切换到参考项目视觉。
 *
 * @deprecated 新代码建议直接用 `LoadingState` / `EmptyState`。
 */
@Component
export struct AsyncStateView {
  @Prop status: string = UiState.LOADING;
  @Prop message: string = '';
  @Prop emptyHint: string = '暂无数据';
  @Prop minHeight: number = 120;
  onRetry: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Column() {
      if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
        LoadingState({})
      } else if (this.status === UiState.ERROR) {
        Column() {
          EmptyState({
            message: this.message.length > 0 ? this.message : '加载失败',
            actionLabel: '重试',
            onAction: () => {
              this.onRetry();
            }
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.status === UiState.EMPTY) {
        Column() {
          EmptyState({ message: this.emptyHint })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        // SUCCESS / INITIAL 时不占位（由调用方决定后续内容）
        Column()
          .width('100%')
          .height(0)
      }
    }
    .width('100%')
    .constraintSize({ minHeight: this.minHeight })
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
  }
}
