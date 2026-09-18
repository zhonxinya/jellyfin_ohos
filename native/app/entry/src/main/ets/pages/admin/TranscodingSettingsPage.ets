import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { ChipButton } from '../../components/ChipButton';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 这一段配置的 key（`GET /System/Configuration/encoding`） */
const ENCODING_CONFIG_KEY = 'encoding';

/** 下拉项 */
class Choice {
  value: string;
  label: string;

  constructor(value: string, label: string) {
    this.value = value;
    this.label = label;
  }
}

/**
 * 硬件加速类型。
 * 服务端把它当**字符串**用 `Enum.TryParse<HardwareEncodingType>` 解析
 * （`MediaBrowser.Model/Session/HardwareEncodingType.cs` 里是 AMF/QSV/NVENC/V4L2M2M/VAAPI），
 * 空串 = 不启用硬件加速。
 */
const ACCEL_TYPES: Choice[] = [
  new Choice('', '不启用（全部软编）'),
  new Choice('nvenc', 'NVIDIA NVENC'),
  new Choice('qsv', 'Intel Quick Sync'),
  new Choice('vaapi', 'VAAPI（Linux）'),
  new Choice('amf', 'AMD AMF'),
  new Choice('v4l2m2m', 'V4L2 M2M（树莓派等）')
];

/**
 * 编码预设（ffmpeg 的 preset）。这一项会**原样传给 ffmpeg**，所以这里只列常用值，
 * 当前值不在列表里时界面会把当前值补在最前面。
 */
const PRESETS: Choice[] = [
  new Choice('', '不设置（由服务器决定）'),
  new Choice('ultrafast', 'ultrafast（最快，体积最大）'),
  new Choice('superfast', 'superfast'),
  new Choice('veryfast', 'veryfast'),
  new Choice('faster', 'faster'),
  new Choice('fast', 'fast'),
  new Choice('medium', 'medium（默认）'),
  new Choice('slow', 'slow'),
  new Choice('slower', 'slower'),
  new Choice('veryslow', 'veryslow（最慢，体积最小）')
];

/** 色调映射算法：直接交给 ffmpeg 的 tonemap 滤镜，值取常用集合 */
const TONEMAP_ALGOS: Choice[] = [
  new Choice('none', 'none'),
  new Choice('clip', 'clip'),
  new Choice('linear', 'linear'),
  new Choice('gamma', 'gamma'),
  new Choice('reinhard', 'reinhard'),
  new Choice('hable', 'hable'),
  new Choice('mobius', 'mobius'),
  new Choice('bt2390', 'bt2390（推荐）')
];

const TONEMAP_MODES: Choice[] = [
  new Choice('auto', 'auto'),
  new Choice('max', 'max'),
  new Choice('rgb', 'rgb')
];

const TONEMAP_RANGES: Choice[] = [
  new Choice('auto', 'auto'),
  new Choice('tv', 'tv（有限范围）'),
  new Choice('pc', 'pc（全范围）')
];

function labelOf(choices: Choice[], value: string): string {
  for (let i = 0; i < choices.length; i++) {
    if (choices[i].value === value) {
      return choices[i].label;
    }
  }
  return value.length > 0 ? `${value}（自定义）` : '未设置';
}

/**
 * 设置 → 转码。
 *
 * 对应 jellyfin-web 的 Dashboard → Playback → Transcoding，落到服务端的 `EncodingOptions`
 * （key = `encoding`，37 个字段；这里覆盖硬件加速、编码质量、转码行为、HDR→SDR、路径这五组）。
 *
 * 两个工程上的注意点：
 * - 所有写回的字段都只在**服务端确实下发过**时才写（`setIfPresent`）：
 *   这样即使某个字段在旧/新版本里不存在，也不会被我们凭空补一个默认值写回去；
 * - 这一段的字段都是非空标量/数组，原样写回是恒等操作，所以"打开页面什么都不改直接保存"
 *   不会改动服务器（设备实测逐字节相同）。
 */
@Entry
@Component
struct TranscodingSettingsPage {
  private base: ESObject = {} as ESObject;
  private originalJson: string = '';

  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;

  // 硬件加速
  @State private accelType: string = '';
  @State private hwEncoding: boolean = true;
  @State private preferNativeHw: boolean = true;
  @State private depth10Hevc: boolean = true;
  @State private depth10Vp9: boolean = true;
  @State private intelH264: boolean = false;
  @State private intelHevc: boolean = false;
  @State private decodingCodecs: string = '';
  @State private vaapiDevice: string = '';
  // 编码质量
  @State private h264Crf: number = 23;
  @State private h265Crf: number = 28;
  @State private preset: string = '';
  @State private threadCount: number = -1;
  @State private allowHevc: boolean = true;
  // 转码行为
  @State private throttling: boolean = false;
  @State private throttleDelay: number = 180;
  @State private downMixBoost: number = 2;
  @State private subtitleExtraction: boolean = true;
  @State private muxingQueue: number = 2048;
  // 色调映射
  @State private tonemapping: boolean = false;
  @State private tonemapAlgo: string = 'bt2390';
  @State private tonemapMode: string = 'auto';
  @State private tonemapRange: string = 'auto';
  @State private tonemapPeak: number = 100;
  @State private tonemapDesat: number = 0;
  @State private tonemapParam: number = 0;
  @State private vppTonemapping: boolean = false;
  @State private vppBrightness: number = 16;
  @State private vppContrast: number = 1;
  // 路径与字体
  @State private tempPath: string = '';
  @State private fallbackFont: boolean = false;
  @State private fallbackFontPath: string = '';

  @State private sheet: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.load();
  }

  private async load(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const raw: string = await JellyfinNative.libraryNamedConfig(ENCODING_CONFIG_KEY);
    const result: NativeResult = JellyfinNative.parseResult(raw);
    if (!result.ok || result.data === null) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取转码设置失败';
      return;
    }
    this.originalJson = JsonUtil.toPretty(result.data);
    this.base = result.data;

    this.accelType = JsonUtil.getString(this.base, 'HardwareAccelerationType', '');
    this.hwEncoding = JsonUtil.getBoolean(this.base, 'EnableHardwareEncoding', true);
    this.preferNativeHw = JsonUtil.getBoolean(this.base, 'PreferSystemNativeHwDecoder', true);
    this.depth10Hevc = JsonUtil.getBoolean(this.base, 'EnableDecodingColorDepth10Hevc', true);
    this.depth10Vp9 = JsonUtil.getBoolean(this.base, 'EnableDecodingColorDepth10Vp9', true);
    this.intelH264 = JsonUtil.getBoolean(this.base, 'EnableIntelLowPowerH264HwEncoder', false);
    this.intelHevc = JsonUtil.getBoolean(this.base, 'EnableIntelLowPowerHevcHwEncoder', false);
    this.decodingCodecs = TranscodingSettingsPage.joinList(this.base, 'HardwareDecodingCodecs');
    this.vaapiDevice = JsonUtil.getString(this.base, 'VaapiDevice', '');

    this.h264Crf = JsonUtil.getNumber(this.base, 'H264Crf', 23);
    this.h265Crf = JsonUtil.getNumber(this.base, 'H265Crf', 28);
    this.preset = JsonUtil.getString(this.base, 'EncoderPreset', '');
    this.threadCount = JsonUtil.getNumber(this.base, 'EncodingThreadCount', -1);
    this.allowHevc = JsonUtil.getBoolean(this.base, 'AllowHevcEncoding', true);

    this.throttling = JsonUtil.getBoolean(this.base, 'EnableThrottling', false);
    this.throttleDelay = JsonUtil.getNumber(this.base, 'ThrottleDelaySeconds', 180);
    this.downMixBoost = JsonUtil.getNumber(this.base, 'DownMixAudioBoost', 2);
    this.subtitleExtraction = JsonUtil.getBoolean(this.base, 'EnableSubtitleExtraction', true);
    this.muxingQueue = JsonUtil.getNumber(this.base, 'MaxMuxingQueueSize', 2048);

    this.tonemapping = JsonUtil.getBoolean(this.base, 'EnableTonemapping', false);
    this.tonemapAlgo = JsonUtil.getString(this.base, 'TonemappingAlgorithm', 'bt2390');
    this.tonemapMode = JsonUtil.getString(this.base, 'TonemappingMode', 'auto');
    this.tonemapRange = JsonUtil.getString(this.base, 'TonemappingRange', 'auto');
    this.tonemapPeak = JsonUtil.getNumber(this.base, 'TonemappingPeak', 100);
    this.tonemapDesat = JsonUtil.getNumber(this.base, 'TonemappingDesat', 0);
    this.tonemapParam = JsonUtil.getNumber(this.base, 'TonemappingParam', 0);
    this.vppTonemapping = JsonUtil.getBoolean(this.base, 'EnableVppTonemapping', false);
    this.vppBrightness = JsonUtil.getNumber(this.base, 'VppTonemappingBrightness', 16);
    this.vppContrast = JsonUtil.getNumber(this.base, 'VppTonemappingContrast', 1);

    this.tempPath = JsonUtil.getString(this.base, 'TranscodingTempPath', '');
    this.fallbackFont = JsonUtil.getBoolean(this.base, 'EnableFallbackFont', false);
    this.fallbackFontPath = JsonUtil.getString(this.base, 'FallbackFontPath', '');
    this.status = UiState.SUCCESS;
  }

  private static joinList(obj: ESObject, key: string): string {
    const out: string[] = [];
    const items: Object[] = JsonUtil.getArray(obj, key);
    for (let i = 0; i < items.length; i++) {
      if (typeof items[i] === 'string') {
        out.push(items[i] as string);
      }
    }
    return out.join('\n');
  }

  private static splitList(text: string): string[] {
    const out: string[] = [];
    const lines: string[] = text.split('\n');
    for (let i = 0; i < lines.length; i++) {
      const trimmed: string = lines[i].trim();
      if (trimmed.length > 0) {
        out.push(trimmed);
      }
    }
    return out;
  }

  /** 只在服务端确实下发过这个字段时才写回（见类注释） */
  private static setIfPresent(bag: Record<string, Object>, source: ESObject,
                             key: string, value: Object): void {
    const src: Record<string, Object> = source as Record<string, Object>;
    if (src[key] !== undefined && src[key] !== null) {
      bag[key] = value;
    }
  }

  private buildPayload(): string {
    const draft: ESObject = JSON.parse(JSON.stringify(this.base)) as ESObject;
    const bag: Record<string, Object> = draft as Record<string, Object>;
    const src: ESObject = this.base;
    const set = (key: string, value: Object): void => {
      TranscodingSettingsPage.setIfPresent(bag, src, key, value);
    };

    set('HardwareAccelerationType', this.accelType);
    set('EnableHardwareEncoding', this.hwEncoding);
    set('PreferSystemNativeHwDecoder', this.preferNativeHw);
    set('EnableDecodingColorDepth10Hevc', this.depth10Hevc);
    set('EnableDecodingColorDepth10Vp9', this.depth10Vp9);
    set('EnableIntelLowPowerH264HwEncoder', this.intelH264);
    set('EnableIntelLowPowerHevcHwEncoder', this.intelHevc);
    set('HardwareDecodingCodecs', TranscodingSettingsPage.splitList(this.decodingCodecs));
    set('VaapiDevice', this.vaapiDevice.trim());

    set('H264Crf', this.h264Crf);
    set('H265Crf', this.h265Crf);
    set('EncoderPreset', this.preset);
    set('EncodingThreadCount', this.threadCount);
    set('AllowHevcEncoding', this.allowHevc);

    set('EnableThrottling', this.throttling);
    set('ThrottleDelaySeconds', this.throttleDelay);
    set('DownMixAudioBoost', this.downMixBoost);
    set('EnableSubtitleExtraction', this.subtitleExtraction);
    set('MaxMuxingQueueSize', this.muxingQueue);

    set('EnableTonemapping', this.tonemapping);
    set('TonemappingAlgorithm', this.tonemapAlgo);
    set('TonemappingMode', this.tonemapMode);
    set('TonemappingRange', this.tonemapRange);
    set('TonemappingPeak', this.tonemapPeak);
    set('TonemappingDesat', this.tonemapDesat);
    set('TonemappingParam', this.tonemapParam);
    set('EnableVppTonemapping', this.vppTonemapping);
    set('VppTonemappingBrightness', this.vppBrightness);
    set('VppTonemappingContrast', this.vppContrast);

    set('TranscodingTempPath', this.tempPath.trim());
    set('EnableFallbackFont', this.fallbackFont);
    set('FallbackFontPath', this.fallbackFontPath.trim());
    return JsonUtil.toPretty(draft);
  }

  private isDirty(): boolean {
    return this.buildPayload() !== this.originalJson;
  }

  private touch(): void {
    this.actionMessage = '';
  }

  private validationError(): string {
    if (this.h264Crf < 0 || this.h264Crf > 51 || this.h265Crf < 0 || this.h265Crf > 51) {
      return 'CRF 取值范围是 0–51（越小越清晰、体积越大）';
    }
    if (this.threadCount < -1 || this.threadCount > 64) {
      return '编码线程数用 -1 表示自动，或填 1–64';
    }
    if (this.throttleDelay < 0) {
      return '限速延迟不能是负数';
    }
    return '';
  }

  private async save(): Promise<void> {
    if (this.saving || !this.isDirty()) {
      return;
    }
    const invalid: string = this.validationError();
    if (invalid.length > 0) {
      this.actionOk = false;
      this.actionMessage = invalid;
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.libraryUpdateNamedConfig(ENCODING_CONFIG_KEY, this.buildPayload()));
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = '已保存；改动会用于之后新建的转码任务';
    this.load();
  }

  private choicesFor(kind: string): Choice[] {
    if (kind === 'accel') {
      return TranscodingSettingsPage.withCurrent(ACCEL_TYPES, this.accelType);
    }
    if (kind === 'preset') {
      return TranscodingSettingsPage.withCurrent(PRESETS, this.preset);
    }
    if (kind === 'algo') {
      return TranscodingSettingsPage.withCurrent(TONEMAP_ALGOS, this.tonemapAlgo);
    }
    if (kind === 'mode') {
      return TranscodingSettingsPage.withCurrent(TONEMAP_MODES, this.tonemapMode);
    }
    return TranscodingSettingsPage.withCurrent(TONEMAP_RANGES, this.tonemapRange);
  }

  /** 当前值不在常用集合里时补一条，避免界面显示不出真实值 */
  private static withCurrent(choices: Choice[], current: string): Choice[] {
    for (let i = 0; i < choices.length; i++) {
      if (choices[i].value === current) {
        return choices;
      }
    }
    return [new Choice(current, `${current}（当前值）`)].concat(choices);
  }

  private sheetTitle(): string {
    if (this.sheet === 'accel') return '硬件加速类型';
    if (this.sheet === 'preset') return '编码预设';
    if (this.sheet === 'algo') return '色调映射算法';
    if (this.sheet === 'mode') return '色调映射模式';
    return '色调映射范围';
  }

  private sheetHint(): string {
    if (this.sheet === 'accel') return '要与服务器上的显卡/驱动匹配；选错会导致转码失败（服务端会回落到软编）。';
    if (this.sheet === 'preset') return '越慢的预设压缩率越高、CPU 占用越大；这一项会原样传给 ffmpeg。';
    if (this.sheet === 'algo') return 'HDR 转 SDR 时使用的曲线，bt2390 通常效果最好。';
    if (this.sheet === 'mode') return 'auto 由 ffmpeg 决定；max/rgb 分别按最大分量与 RGB 计算。';
    return 'auto 由 ffmpeg 决定；tv = 有限范围（16–235），pc = 全范围（0–255）。';
  }

  private applyChoice(value: string): void {
    if (this.sheet === 'accel') {
      this.accelType = value;
    } else if (this.sheet === 'preset') {
      this.preset = value;
    } else if (this.sheet === 'algo') {
      this.tonemapAlgo = value;
    } else if (this.sheet === 'mode') {
      this.tonemapMode = value;
    } else {
      this.tonemapRange = value;
    }
    this.sheet = '';
    this.touch();
  }

  @Builder
  ChoiceSheet() {
    Column({ space: 10 }) {
      Text(this.sheetTitle())
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(this.sheetHint())
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      List({ space: 2 }) {
        ForEach(this.choicesFor(this.sheet), (choice: Choice) => {
          ListItem() {
            Row() {
              Text(choice.label)
                .fontSize(ThemeConstants.BODY_MEDIUM)
                .fontColor(this.colors().textPrimary)
                .layoutWeight(1)
              if (choice.value === this.currentValueOf(this.sheet)) {
                SymbolGlyph($r('sys.symbol.checkmark'))
                  .fontSize(ThemeConstants.ICON_SMALL)
                  .fontColor([this.colors().brandPrimary])
              }
            }
            .width('100%')
            .padding({ top: 10, bottom: 10 })
            .onClick(() => {
              this.applyChoice(choice.value);
            })
          }
        }, (choice: Choice) => choice.value)
      }
      .width('100%')
      .height(320)
      .scrollBar(BarState.Auto)
      Button('取消')
        .width('100%')
        .height(44)
        .backgroundColor(this.colors().surfacePressed)
        .fontColor(this.colors().textSecondary)
        .onClick(() => {
          this.sheet = '';
        })
    }
    .padding(20)
    .backgroundColor(this.colors().cardBackground)
    .borderRadius(12)
    .width('88%')
    .onClick(() => {
    })
  }

  private currentValueOf(kind: string): string {
    if (kind === 'accel') return this.accelType;
    if (kind === 'preset') return this.preset;
    if (kind === 'algo') return this.tonemapAlgo;
    if (kind === 'mode') return this.tonemapMode;
    return this.tonemapRange;
  }

  /**
   * 数字行。
   *
   * `signed=true` 时必须用 `InputType.Normal`：`InputType.Number` 会把负号过滤掉 ——
   * 设备实测把「编码线程数」的 -1（= 自动）显示/回写成 1，保存后服务端就从 -1 变成了 1。
   * 需要负数或小数的字段（线程数、立体声增益、色调映射的几个 double）都走 signed。
   */
  @Builder
  NumberRow(title: string, hint: string, value: number, signed: boolean,
            onChange: (value: number) => void) {
    Row({ space: 8 }) {
      Column({ space: 4 }) {
        Text(title)
          .fontSize(ThemeConstants.TITLE_MEDIUM)
          .fontColor(this.colors().textPrimary)
        Text(hint)
          .fontSize(ThemeConstants.META_SMALL)
          .fontColor(this.colors().textSecondary)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      TextInput({ text: `${value}` })
        .type(signed ? InputType.Normal : InputType.Number)
        .width(100)
        .textAlign(TextAlign.End)
        .onChange((text: string) => {
          const raw: number = Number(text);
          const parsed: number = Number.isNaN(raw) ? 0 : (signed ? raw : Math.floor(raw));
          onChange(parsed);
          this.touch();
        })
    }
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  @Builder
  TextRow(title: string, hint: string, value: string, placeholder: string,
          onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(hint)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      TextInput({ text: value, placeholder: placeholder })
        .width('100%')
        .onChange((text: string) => {
          onChange(text);
          this.touch();
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  @Builder
  ListRow(title: string, hint: string, value: string, placeholder: string,
          onChange: (value: string) => void) {
    Column({ space: 6 }) {
      Text(title)
        .fontSize(ThemeConstants.TITLE_MEDIUM)
        .fontColor(this.colors().textPrimary)
        .width('100%')
      Text(hint)
        .fontSize(ThemeConstants.META_SMALL)
        .fontColor(this.colors().textSecondary)
        .width('100%')
      TextArea({ text: value, placeholder: placeholder })
        .width('100%')
        .height(96)
        .onChange((text: string) => {
          onChange(text);
          this.touch();
        })
    }
    .alignItems(HorizontalAlign.Start)
    .width('100%')
    .padding(ThemeConstants.PAGE_PADDING)
  }

  @Builder
  ToggleRow(title: string, hint: string, on: boolean, onChange: (value: boolean) => void) {
    SettingCell({
      title: title,
      subtitle: hint,
      showToggle: true,
      toggleOn: on,
      onToggle: (value: boolean) => {
        onChange(value);
        this.touch();
      }
    })
  }

  build() {
    Stack() {
      Column() {
        PageHeader({
          title: '转码',
          onBack: () => {
            router.back();
          }
        })

        if (this.status === UiState.SUCCESS) {
          Column({ space: 2 }) {
            Text('服务器级设置（决定什么时候转码、怎么转）')
              .fontSize(ThemeConstants.BODY_MEDIUM)
              .fontColor(this.colors().textPrimary)
            if (this.actionMessage.length > 0) {
              Text(this.actionMessage)
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.actionOk ? this.colors().success : this.colors().error)
                .maxLines(2)
            } else {
              Text(this.isDirty() ? '有未保存的修改' : '与服务器一致')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.isDirty() ? this.colors().warning : this.colors().textSecondary)
            }
          }
          .alignItems(HorizontalAlign.Start)
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 4 })
        }

        if (this.status === UiState.LOADING || this.status === UiState.REFRESHING) {
          LoadingState()
        } else if (this.status === UiState.ERROR) {
          EmptyState({
            message: this.errorMsg.length > 0 ? this.errorMsg : '加载失败',
            actionLabel: '重试',
            onAction: () => {
              this.load();
            }
          })
        } else {
          Scroll() {
            Column() {
              SectionCard({ title: '硬件加速', icon: $r('sys.symbol.video_speed'),
                showHeaderIcon: true }) {
                Column() {
                  SettingCell({
                    title: '硬件加速类型',
                    subtitle: '要与服务器的显卡/驱动匹配；不匹配会回落到软编',
                    valueText: labelOf(ACCEL_TYPES, this.accelType),
                    showIcon: true,
                    icon: $r('sys.symbol.display'),
                    showChevron: true,
                    onTap: () => {
                      this.sheet = 'accel';
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('启用硬件编码', '用显卡编码（需要上面的类型可用）',
                    this.hwEncoding, (value: boolean) => {
                      this.hwEncoding = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('优先系统原生硬解', '解码时优先用系统接口而不是 ffmpeg 的 hwaccel',
                    this.preferNativeHw, (value: boolean) => {
                      this.preferNativeHw = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('10bit HEVC 硬解', '允许硬件解码 10bit HEVC',
                    this.depth10Hevc, (value: boolean) => {
                      this.depth10Hevc = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('10bit VP9 硬解', '允许硬件解码 10bit VP9',
                    this.depth10Vp9, (value: boolean) => {
                      this.depth10Vp9 = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('Intel 低功耗 H.264 编码', '仅 Intel 核显；可能牺牲一点质量换功耗',
                    this.intelH264, (value: boolean) => {
                      this.intelH264 = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('Intel 低功耗 HEVC 编码', '仅 Intel 核显',
                    this.intelHevc, (value: boolean) => {
                      this.intelHevc = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ListRow('硬件解码编码器', '允许硬解的编码格式，每行一个（例如 h264）',
                    this.decodingCodecs, 'h264\nhevc',
                    (value: string) => {
                      this.decodingCodecs = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.TextRow('VAAPI 设备', '仅 VAAPI 用得到（例如 /dev/dri/renderD128）',
                    this.vaapiDevice, '/dev/dri/renderD128',
                    (value: string) => {
                      this.vaapiDevice = value;
                    })
                }
                .width('100%')
              }

              SectionCard({ title: '编码质量', icon: $r('sys.symbol.aspectratio'),
                showHeaderIcon: true }) {
                Column() {
                  this.NumberRow('H.264 CRF', '画质/体积权衡，0–51，越小越清晰（默认 23）',
                    this.h264Crf, false,
                  (value: number) => {
                      this.h264Crf = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('H.265 CRF', '0–51，越小越清晰（默认 28）',
                    this.h265Crf, false,
                  (value: number) => {
                      this.h265Crf = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '编码预设',
                    subtitle: '越慢压缩率越高、CPU 占用越大',
                    valueText: labelOf(PRESETS, this.preset),
                    showIcon: true,
                    icon: $r('sys.symbol.video_speed'),
                    showChevron: true,
                    onTap: () => {
                      this.sheet = 'preset';
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('编码线程数', '用 -1 表示自动（按 CPU 核数决定）',
                    this.threadCount, true,
                  (value: number) => {
                      this.threadCount = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('允许 HEVC 编码', '关闭后客户端要 HEVC 时也会用 H.264',
                    this.allowHevc, (value: boolean) => {
                      this.allowHevc = value;
                    })
                }
                .width('100%')
              }

              SectionCard({ title: '转码行为', icon: $r('sys.symbol.timer'), showHeaderIcon: true }) {
                Column() {
                  this.ToggleRow('启用限速', '转码进度追上播放进度后暂停编码，省 CPU',
                    this.throttling, (value: boolean) => {
                      this.throttling = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('限速延迟（秒）', '落后这么多秒之后才开始限速',
                    this.throttleDelay, false,
                  (value: number) => {
                      this.throttleDelay = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('立体声增益', '多声道降到立体声时的音量倍数',
                    this.downMixBoost, true,
                  (value: number) => {
                      this.downMixBoost = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('提取字幕', '把内嵌字幕抽出来单独传送（否则只能烧录进画面）',
                    this.subtitleExtraction, (value: boolean) => {
                      this.subtitleExtraction = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('复用队列上限', '网络慢时可适当调大；过大更吃内存',
                    this.muxingQueue, false,
                  (value: number) => {
                      this.muxingQueue = value;
                    })
                }
                .width('100%')
              }

              SectionCard({ title: 'HDR 转 SDR（色调映射）', icon: $r('sys.symbol.sun_max'),
                showHeaderIcon: true }) {
                Column() {
                  this.ToggleRow('启用色调映射', '把 HDR 片源转成 SDR 时不至于发灰/过曝',
                    this.tonemapping, (value: boolean) => {
                      this.tonemapping = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '算法',
                    subtitle: 'HDR→SDR 的曲线',
                    valueText: labelOf(TONEMAP_ALGOS, this.tonemapAlgo),
                    showIcon: true,
                    icon: $r('sys.symbol.sun_max'),
                    showChevron: true,
                    onTap: () => {
                      this.sheet = 'algo';
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '模式',
                    subtitle: 'ffmpeg 的 tonemap 模式',
                    valueText: labelOf(TONEMAP_MODES, this.tonemapMode),
                    showIcon: true,
                    icon: $r('sys.symbol.textformat'),
                    showChevron: true,
                    onTap: () => {
                      this.sheet = 'mode';
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  SettingCell({
                    title: '范围',
                    subtitle: '输出范围：tv = 有限范围，pc = 全范围',
                    valueText: labelOf(TONEMAP_RANGES, this.tonemapRange),
                    showIcon: true,
                    icon: $r('sys.symbol.aspectratio'),
                    showChevron: true,
                    onTap: () => {
                      this.sheet = 'range';
                    }
                  })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('峰值亮度', '参考白点（nits）',
                    this.tonemapPeak, false,
                  (value: number) => {
                      this.tonemapPeak = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('饱和度', '0 表示不调整',
                    this.tonemapDesat, true,
                  (value: number) => {
                      this.tonemapDesat = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('色调映射参数', '0 表示不传该参数',
                    this.tonemapParam, true,
                  (value: number) => {
                      this.tonemapParam = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('VPP 色调映射', 'Intel VAAPI 的 VPP 色调映射（仅部分硬件支持）',
                    this.vppTonemapping, (value: boolean) => {
                      this.vppTonemapping = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('VPP 亮度', '仅 VPP 色调映射生效',
                    this.vppBrightness, false,
                  (value: number) => {
                      this.vppBrightness = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.NumberRow('VPP 对比度', '仅 VPP 色调映射生效',
                    this.vppContrast, true,
                  (value: number) => {
                      this.vppContrast = value;
                    })
                }
                .width('100%')
              }

              SectionCard({ title: '路径与字体', icon: $r('sys.symbol.folder'), showHeaderIcon: true }) {
                Column() {
                  this.TextRow('转码临时目录', '服务器上存放转码分片的目录（改错会让转码失败）',
                    this.tempPath, '/var/lib/jellyfin/transcodes',
                    (value: string) => {
                      this.tempPath = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.ToggleRow('启用回退字体', 'ASS/SSA 字幕缺字体时用回退字体渲染',
                    this.fallbackFont, (value: boolean) => {
                      this.fallbackFont = value;
                    })
                  Divider().color(this.colors().divider).strokeWidth(0.5)
                  this.TextRow('回退字体路径', '留空则用服务器默认',
                    this.fallbackFontPath, '/usr/share/fonts/truetype/noto',
                    (value: string) => {
                      this.fallbackFontPath = value;
                    })
                }
                .width('100%')
              }

              Text('改动只影响之后新建的转码任务；已经在播放的会话要重新开始播放才会用新设置。')
                .fontSize(ThemeConstants.META_SMALL)
                .fontColor(this.colors().textTertiary)
                .width('100%')
                .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, top: 4 })

              Blank().height(60)
            }
            .width('100%')
            .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
          }
          .width('100%')
          .layoutWeight(1)
          .scrollBar(BarState.Auto)

          Row({ space: 10 }) {
            Button('恢复')
              .layoutWeight(1)
              .height(44)
              .backgroundColor(this.colors().surfacePressed)
              .fontColor(this.colors().textPrimary)
              .enabled(!this.saving && this.isDirty())
              .onClick(() => {
                this.load();
                this.actionOk = true;
                this.actionMessage = '已恢复为服务器上的当前设置';
              })
            Button(this.saving ? '保存中...' : '保存')
              .layoutWeight(2)
              .height(44)
              .backgroundColor(this.colors().brandPrimary)
              .fontColor(this.colors().onBrand)
              .enabled(!this.saving && this.isDirty())
              .onClick(() => {
                this.save();
              })
          }
          .width('100%')
          .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
            top: 8, bottom: 8 })
          .backgroundColor(this.colors().cardBackground)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(this.colors().pageBackground)

      if (this.sheet.length > 0) {
        Column() {
          this.ChoiceSheet()
        }
        .width('100%')
        .height('100%')
        .justifyContent(FlexAlign.Center)
        .backgroundColor(this.colors().scrim)
        .onClick(() => {
          this.sheet = '';
        })
      }
    }
    .width('100%')
    .height('100%')
  }
}
