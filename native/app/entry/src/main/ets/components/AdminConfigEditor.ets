import { ThemeColors, ThemeConstants } from '../common/ThemeConstants';
import { AppViewModel } from '../viewmodel/AppViewModel';
import { JsonUtil } from '../common/JsonUtil';

export type AdminConfigFieldType = 'text' | 'number' | 'toggle';
export type AdminConfigValue = string | number | boolean;

export class AdminConfigField {
  key: string = '';
  label: string = '';
  description: string = '';
  type: AdminConfigFieldType = 'text';

  constructor(key: string, label: string, type: AdminConfigFieldType,
    description: string = '') {
    this.key = key;
    this.label = label;
    this.type = type;
    this.description = description;
  }
}

/**
 * Generic editor for a small, explicitly allow-listed subset of server config.
 * The page owns the complete JSON draft; this component never renders unknown fields.
 */
@Component
export struct AdminConfigEditor {
  @Prop draft: ESObject | null = null;
  @Prop fields: AdminConfigField[] = [];
  @Prop saving: boolean = false;
  @Prop message: string = '';
  @Prop messageError: boolean = false;
  onChange: (key: string, value: AdminConfigValue) => void = (_key: string, _value: AdminConfigValue) => {};
  onSave: () => void = () => {};

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private textValue(key: string): string {
    return JsonUtil.getString(this.draft, key, '');
  }

  private numberValue(key: string): number {
    return JsonUtil.getNumber(this.draft, key, 0);
  }

  private booleanValue(key: string): boolean {
    return JsonUtil.getBoolean(this.draft, key, false);
  }

  @Builder
  FieldRow(field: AdminConfigField) {
    Column({ space: 6 }) {
      Row() {
        Column({ space: 2 }) {
          Text(field.label)
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontColor(this.colors().onSurface)
          if (field.description.length > 0) {
            Text(field.description)
              .fontSize(ThemeConstants.LABEL_SMALL)
              .fontColor(this.colors().onSurfaceVariant)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)

        if (field.type === 'toggle') {
          Toggle({ type: ToggleType.Switch, isOn: this.booleanValue(field.key) })
            .selectedColor(this.colors().primary)
            .enabled(!this.saving)
            .onChange((value: boolean) => {
              this.onChange(field.key, value);
            })
        }
      }
      .width('100%')
      .alignItems(VerticalAlign.Center)

      if (field.type === 'text') {
        TextInput({ text: this.textValue(field.key), placeholder: field.label })
          .width('100%')
          .enabled(!this.saving)
          .fontColor(this.colors().onSurface)
          .backgroundColor(this.colors().surfaceElevated)
          .onChange((value: string) => {
            this.onChange(field.key, value);
          })
      } else if (field.type === 'number') {
        TextInput({ text: `${this.numberValue(field.key)}`, placeholder: field.label })
          .width('100%')
          .enabled(!this.saving)
          .type(InputType.Number)
          .fontColor(this.colors().onSurface)
          .backgroundColor(this.colors().surfaceElevated)
          .onChange((value: string) => {
            const parsed: number = Number(value);
            if (!Number.isNaN(parsed)) {
              this.onChange(field.key, parsed);
            }
          })
      }
    }
    .width('100%')
    .padding({ left: 16, right: 16, top: 12, bottom: 12 })
  }

  build() {
    Column({ space: 8 }) {
      Column() {
        ForEach(this.fields, (field: AdminConfigField) => {
          this.FieldRow(field)
        }, (field: AdminConfigField) => field.key)

        Button() {
          Row({ space: 8 }) {
            if (this.saving) {
              LoadingProgress()
                .width(18)
                .height(18)
                .color(this.colors().onPrimary)
            }
            Text(this.saving ? '保存中...' : '保存')
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().onPrimary)
          }
        }
        .width('100%')
        .height(42)
        .margin({ left: 16, right: 16, top: 8, bottom: 8 })
        .backgroundColor(this.saving ? this.colors().onSurfaceVariant : this.colors().primary)
        .enabled(!this.saving)
        .onClick(() => {
          this.onSave();
        })
      }
      .width('100%')
      .backgroundColor(this.colors().surface)
      .borderRadius(12)
      .clip(true)

      if (this.message.length > 0) {
        Text(this.message)
          .fontSize(ThemeConstants.LABEL_SMALL)
          .fontColor(this.messageError ? this.colors().error : this.colors().success)
          .width('100%')
          .padding({ left: 16, right: 16, bottom: 8 })
      }
    }
    .width('100%')
  }
}
