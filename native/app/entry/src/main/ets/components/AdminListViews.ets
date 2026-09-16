import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';

export class KeyValueRow {
  key: string = '';
  value: string = '';

  constructor(key: string = '', value: string = '') {
    this.key = key;
    this.value = value;
  }
}

@Component
export struct AdminKeyValueList {
  @Prop rows: KeyValueRow[] = [];

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    List({ space: 8 }) {
      ForEach(this.rows, (row: KeyValueRow, index: number) => {
        ListItem() {
          Row() {
            Text(row.key)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onSurfaceVariant)
              .width(120)
            Text(row.value)
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().onSurface)
              .layoutWeight(1)
              .maxLines(4)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
          }
          .width('100%')
          .padding({ left: 14, right: 14, top: 12, bottom: 12 })
          .backgroundColor(this.colors().surface)
          .borderRadius(10)
        }
      }, (row: KeyValueRow, index: number) => `${row.key}_${index}`)
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
  }
}

@Component
export struct AdminEntityList {
  @Prop lines: string[] = [];
  @Prop titleKey: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    List({ space: 8 }) {
      ForEach(this.lines, (line: string, index: number) => {
        ListItem() {
          Text(line)
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontColor(this.colors().onSurface)
            .width('100%')
            .padding({ left: 14, right: 14, top: 12, bottom: 12 })
            .backgroundColor(this.colors().surface)
            .borderRadius(10)
            .maxLines(6)
            .textOverflow({ overflow: TextOverflow.Ellipsis })
        }
      }, (line: string, index: number) => `${index}_${line.substring(0, 24)}`)
    }
    .width('100%')
    .padding({ left: 16, right: 16, bottom: 16 })
    .cachedCount(8)
  }
}
