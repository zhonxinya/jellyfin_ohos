import { ThemeConstants } from '../common/ThemeConstants';
import { ChipButton } from './ChipButton';

/** 筛选项：`value` 用于回写 `@Link selected` */
export interface FilterChipItem {
  label: string;
  value: number;
}

/**
 * 横向筛选条 —— 对齐 mybooks_ohos 的 FilterChips。
 *
 * 规格：`Row({ space: 8 })` + 末尾 `Blank()`；容器左右各 16vp、底部 8vp；
 * 选中值通过 `@Link` 双向绑定，切换后回调 `onChange`。
 */
@Component
export struct FilterChips {
  @Prop items: FilterChipItem[] = [];
  @Link selected: number;
  onChange: (value: number) => void = () => {};

  build() {
    Row({ space: 8 }) {
      ForEach(this.items, (item: FilterChipItem) => {
        ChipButton({
          label: item.label,
          selected: this.selected === item.value,
          onTap: () => {
            this.selected = item.value;
            this.onChange(item.value);
          }
        })
      }, (item: FilterChipItem) => `${item.value}`)
      Blank()
        .layoutWeight(1)
    }
    .width('100%')
    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 8 })
  }
}
