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

/**
 * 常见服务端字段 → 中文标签。
 *
 * 通用管理页拿到的是原样的 JSON 键（`ServerName` / `ProgramDataPath`…），
 * 直接把英文键摆给用户看不好读；这里只映射**确定含义**的那些，
 * 没列到的原样显示（宁可显示英文键，也不要瞎翻译）。
 */
export function labelForKey(key: string): string {
  const tail: string = key.includes('.') ? key.substring(key.lastIndexOf('.') + 1) : key;
  const map: Record<string, string> = {
    'ServerName': '服务器名称',
    'Version': '版本',
    'Id': '标识',
    'OperatingSystem': '操作系统',
    'OperatingSystemDisplayName': '操作系统',
    'ProductName': '产品名称',
    'SystemArchitecture': '系统架构',
    'LocalAddress': '本地地址',
    'HasPendingRestart': '待重启',
    'CanSelfRestart': '可自我重启',
    'SupportsLibraryMonitor': '支持媒体库监控',
    'WebSocketPortNumber': 'WebSocket 端口',
    'ProgramDataPath': '数据目录',
    'CachePath': '缓存目录',
    'LogPath': '日志目录',
    'InternalMetadataPath': '元数据目录',
    'TranscodingTempPath': '转码临时目录',
    'EncoderLocation': '编码器位置',
    'Encodings': '编码器',
    'Name': '名称',
    'AppName': '应用',
    'DeviceName': '设备',
    'UserName': '用户名',
    'Client': '客户端',
    'ApplicationVersion': '应用版本',
    'State': '状态',
    'LastActivityDate': '最后活动',
    'DateCreated': '创建时间',
    'DateModified': '修改时间',
    'Severity': '级别',
    'Type': '类型',
    'Path': '路径',
    'Locations': '路径',
    'CollectionType': '集合类型',
    'ItemId': '条目 ID',
    'Size': '大小',
    'TotalRecordCount': '总条数',
    'Idle': '空闲'
  };
  const hit: string | undefined = map[tail];
  return hit !== undefined ? hit : key;
}

/** 短值并列显示、长值上下排列的分界（超过就换行，避免把值挤成一列） */
const INLINE_VALUE_MAX = 24;

/**
 * 通用「键 → 值」列表。
 *
 * 原来是**一行一张卡**、标签固定 120vp、值最多 4 行：一页几十行就是几十张卡片，
 * 长值（路径、ID）还会被截断。现在整页一张卡、行间用 0.5vp 分隔线；
 * 短值左侧标签 + 右侧值并列，长值标签在上、值在下（并允许折行）。
 */
@Component
export struct AdminKeyValueList {
  @Prop rows: KeyValueRow[] = [];

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  build() {
    Column() {
      ForEach(this.rows, (row: KeyValueRow, index: number) => {
        Column() {
          if (row.value.length <= INLINE_VALUE_MAX) {
            Row({ space: 12 }) {
              Text(labelForKey(row.key))
                .fontSize(ThemeConstants.BODY_MEDIUM)
                .fontColor(this.colors().textPrimary)
                .layoutWeight(1)
              Text(row.value)
                .fontSize(ThemeConstants.BODY_MEDIUM)
                .fontColor(this.colors().textSecondary)
                .maxLines(1)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .width('100%')
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
              top: 12, bottom: 12 })
          } else {
            Column({ space: 4 }) {
              Text(labelForKey(row.key))
                .fontSize(ThemeConstants.LABEL_SMALL)
                .fontColor(this.colors().textSecondary)
                .width('100%')
              Text(row.value)
                .fontSize(ThemeConstants.META_MEDIUM)
                .fontColor(this.colors().textPrimary)
                .width('100%')
                .maxLines(6)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
            .alignItems(HorizontalAlign.Start)
            .width('100%')
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
              top: 10, bottom: 10 })
          }
          if (index < this.rows.length - 1) {
            Divider().color(this.colors().divider).strokeWidth(0.5)
          }
        }
        .width('100%')
      }, (row: KeyValueRow, index: number) => `${row.key}_${index}_${row.value.length}`)
    }
    .width('100%')
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(ThemeConstants.CARD_RADIUS)
  }
}

/**
 * 通用条目列表：把 `AdminLoader.formatItem` 的「名称 · 补充」拆成两行显示
 * （标题 + 次要信息），比塞进一个多行文本块清楚。
 */
@Component
export struct AdminEntityList {
  @Prop lines: string[] = [];
  @Prop titleKey: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  private static split(line: string): string[] {
    const at: number = line.indexOf(' · ');
    if (at < 0) {
      return [line, ''];
    }
    return [line.substring(0, at), line.substring(at + 3)];
  }

  build() {
    Column() {
      ForEach(this.lines, (line: string, index: number) => {
        Column() {
          Column({ space: 4 }) {
            Text(AdminEntityList.split(line)[0])
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
              .width('100%')
              .maxLines(3)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
            if (AdminEntityList.split(line)[1].length > 0) {
              Text(AdminEntityList.split(line)[1])
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textSecondary)
                .width('100%')
                .maxLines(2)
                .textOverflow({ overflow: TextOverflow.Ellipsis })
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
            top: 12, bottom: 12 })
          if (index < this.lines.length - 1) {
            Divider().color(this.colors().divider).strokeWidth(0.5)
          }
        }
        .width('100%')
      }, (line: string, index: number) => `${index}_${line.substring(0, 24)}`)
    }
    .width('100%')
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(ThemeConstants.CARD_RADIUS)
  }
}
