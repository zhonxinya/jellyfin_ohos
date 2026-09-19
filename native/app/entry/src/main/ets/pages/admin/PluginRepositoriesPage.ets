import router from '@ohos.router';
import { JellyfinNative, NativeResult } from '../../plugins/JellyfinNative';
import { JsonUtil } from '../../common/JsonUtil';
import { UiState } from '../../common/UiState';
import { ThemeColors, ThemeConstants } from '../../common/ThemeConstants';
import { AppViewModel } from '../../viewmodel/AppViewModel';
import { PageHeader } from '../../components/PageHeader';
import { SectionCard } from '../../components/SectionCard';
import { SettingCell } from '../../components/SettingCell';
import { LoadingState } from '../../components/LoadingState';
import { EmptyState } from '../../components/EmptyState';

/** 一个插件仓库（`RepositoryInfo`：Name / Url / Enabled） */
class RepoEntry {
  name: string = '';
  url: string = '';
  enabled: boolean = false;

  constructor(name: string, url: string, enabled: boolean) {
    this.name = name;
    this.url = url;
    this.enabled = enabled;
  }
}

/**
 * 设置 → 控制台 → 插件 → 插件仓库。
 *
 * 对应服务端 `PackageController` 的两个端点：
 * - `GET  /Repositories` 读当前仓库列表；
 * - `POST /Repositories` **整体替换**列表（`PluginRepositories` 是 `ServerConfiguration` 的字段，
 *   这个端点直接把它换掉并保存）。
 *
 * 为什么需要这一页：应用里能装插件，但**只能从已经配好的仓库里装** ——
 * 想加第三方仓库（很多插件不在官方仓库里）原本必须去 Web 控制台。
 *
 * 两个刻意的设计：
 * - 新增仓库默认**不启用**：URL 填错时服务端不会立刻去拉目录、也不会刷一屏错误日志，
 *   用户确认无误后再打开开关；
 * - 保存是整体替换，所以按"整份列表"提交（与服务端语义一致），删除就是把条目从列表里去掉。
 */
@Entry
@Component
struct PluginRepositoriesPage {
  @State private status: string = UiState.LOADING;
  @State private errorMsg: string = '';
  @State private actionMessage: string = '';
  @State private actionOk: boolean = false;
  @State private saving: boolean = false;
  @State private repos: RepoEntry[] = [];
  /** 保存时的底本：用来判断有没有改动、以及"恢复"回到哪一份 */
  private original: string = '';
  @State private newName: string = '';
  @State private newUrl: string = '';

  private colors(): ThemeColors {
    return AppViewModel.getInstance().colors();
  }

  aboutToAppear(): void {
    this.load();
  }

  private payload(): string {
    const out: Object[] = [];
    for (let i = 0; i < this.repos.length; i++) {
      out.push({
        'Name': this.repos[i].name,
        'Url': this.repos[i].url,
        'Enabled': this.repos[i].enabled
      } as ESObject);
    }
    return JSON.stringify(out);
  }

  private isDirty(): boolean {
    return this.payload() !== this.original;
  }

  private async load(): Promise<void> {
    this.status = UiState.LOADING;
    this.errorMsg = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGenericGet('/Repositories'));
    if (!result.ok) {
      this.status = UiState.ERROR;
      this.errorMsg = result.message.length > 0 ? result.message : '读取插件仓库失败';
      return;
    }
    const items: Object[] = Array.isArray(result.data) ? result.data as Object[] : [];
    const parsed: RepoEntry[] = [];
    for (let i = 0; i < items.length; i++) {
      const src: ESObject = items[i] as ESObject;
      const url: string = JsonUtil.getString(src, 'Url', '');
      if (url.length === 0) {
        continue;
      }
      parsed.push(new RepoEntry(
        JsonUtil.getString(src, 'Name', url),
        url,
        JsonUtil.getBoolean(src, 'Enabled', false)));
    }
    this.repos = parsed;
    // 底本用**重新序列化**的结果：服务端可能省略 Enabled 之类的默认字段，
    // 直接比原始字符串会把"没改"误判成"改过"
    this.original = this.payload();
    this.newName = '';
    this.newUrl = '';
    this.actionMessage = '';
    this.status = parsed.length === 0 ? UiState.EMPTY : UiState.SUCCESS;
  }

  private addRepo(): void {
    const name: string = this.newName.trim();
    const url: string = this.newUrl.trim();
    if (name.length === 0) {
      this.actionOk = false;
      this.actionMessage = '请填写仓库名称';
      return;
    }
    if (!url.startsWith('http://') && !url.startsWith('https://')) {
      this.actionOk = false;
      this.actionMessage = '仓库地址要以 http:// 或 https:// 开头';
      return;
    }
    for (let i = 0; i < this.repos.length; i++) {
      if (this.repos[i].url === url) {
        this.actionOk = false;
        this.actionMessage = '这个地址已经在列表里了';
        return;
      }
    }
    // 新加的仓库默认不启用：地址填错也不会让服务端立刻去拉目录
    this.repos = this.repos.concat([new RepoEntry(name, url, false)]);
    this.newName = '';
    this.newUrl = '';
    this.actionOk = true;
    this.actionMessage = `已加入列表（未启用）：${name}，记得点保存`;
  }

  private removeRepo(index: number): void {
    const next: RepoEntry[] = [];
    for (let i = 0; i < this.repos.length; i++) {
      if (i !== index) {
        next.push(this.repos[i]);
      }
    }
    this.repos = next;
    this.actionMessage = '';
    if (next.length === 0) {
      this.status = UiState.SUCCESS;
    }
  }

  private toggleRepo(index: number, enabled: boolean): void {
    const next: RepoEntry[] = [];
    for (let i = 0; i < this.repos.length; i++) {
      const item: RepoEntry = this.repos[i];
      next.push(i === index ? new RepoEntry(item.name, item.url, enabled) : item);
    }
    this.repos = next;
    this.actionMessage = '';
  }

  private async save(): Promise<void> {
    if (this.saving || !this.isDirty()) {
      return;
    }
    this.saving = true;
    this.actionMessage = '';
    const result: NativeResult = JellyfinNative.parseResult(
      await JellyfinNative.adminGenericPost('/Repositories', this.payload()));
    this.saving = false;
    if (!result.ok) {
      this.actionOk = false;
      this.actionMessage = result.message.length > 0 ? result.message : '保存失败';
      return;
    }
    this.actionOk = true;
    this.actionMessage = '仓库列表已保存';
    this.load();
  }

  build() {
    Column() {
      PageHeader({
        title: '插件仓库',
        onBack: () => {
          router.back();
        }
      })

      if (this.status === UiState.SUCCESS || this.status === UiState.EMPTY) {
        Column({ space: 2 }) {
          Text('插件从这些仓库里获取；启用后服务端会定期拉取它的插件目录')
            .fontSize(ThemeConstants.BODY_MEDIUM)
            .fontColor(this.colors().textPrimary)
          if (this.actionMessage.length > 0) {
            Text(this.actionMessage)
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.actionOk ? this.colors().success : this.colors().error)
              .maxLines(3)
          } else {
            Text(this.isDirty() ? '有未保存的修改' : '与服务器一致')
              .fontSize(ThemeConstants.META_SMALL)
              .fontColor(this.isDirty() ? this.colors().warning : this.colors().textSecondary)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .width('100%')
        .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING, bottom: 6 })
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
            SectionCard({ title: `已配置的仓库（${this.repos.length}）`,
              icon: $r('sys.symbol.puzzle'), showHeaderIcon: true }) {
              Column() {
                if (this.repos.length === 0) {
                  Text('还没有配置任何仓库。下面添加一个（例如官方仓库）后再去「插件」页安装。')
                    .fontSize(ThemeConstants.META_SMALL)
                    .fontColor(this.colors().textSecondary)
                    .width('100%')
                    .padding(ThemeConstants.PAGE_PADDING)
                }
                ForEach(this.repos, (repo: RepoEntry, index: number) => {
                  Column() {
                    Row({ space: 8 }) {
                      Column({ space: 4 }) {
                        Text(repo.name)
                          .fontSize(ThemeConstants.TITLE_MEDIUM)
                          .fontColor(this.colors().textPrimary)
                          .width('100%')
                        Text(repo.url)
                          .fontSize(ThemeConstants.META_SMALL)
                          .fontColor(this.colors().textSecondary)
                          .width('100%')
                          .maxLines(2)
                          .textOverflow({ overflow: TextOverflow.Ellipsis })
                      }
                      .alignItems(HorizontalAlign.Start)
                      .layoutWeight(1)
                      Toggle({ type: ToggleType.Switch, isOn: repo.enabled })
                        .selectedColor(this.colors().brandPrimary)
                        .onChange((value: boolean) => {
                          this.toggleRepo(index, value);
                        })
                    }
                    .width('100%')
                    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                      top: 12, bottom: 8 })
                    Row({ space: 8 }) {
                      Button('删除')
                        .height(32)
                        .fontSize(ThemeConstants.META_SMALL)
                        .padding({ left: 12, right: 12 })
                        .backgroundColor(this.colors().errorLight)
                        .fontColor(this.colors().onBrand)
                        .onClick(() => {
                          this.removeRepo(index);
                        })
                      Blank()
                    }
                    .width('100%')
                    .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING,
                      bottom: 10 })
                    if (index < this.repos.length - 1) {
                      Divider().color(this.colors().divider).strokeWidth(0.5)
                    }
                  }
                  .width('100%')
                }, (repo: RepoEntry) => `${repo.url}_${repo.enabled}`)
              }
              .width('100%')
            }

            SectionCard({ title: '添加仓库', icon: $r('sys.symbol.plus_circle'),
              showHeaderIcon: true }) {
              Column({ space: 10 }) {
                TextInput({ text: this.newName, placeholder: '仓库名称（随便起，例如 我的插件仓库）' })
                  .width('100%')
                  .onChange((value: string) => {
                    this.newName = value;
                  })
                TextInput({ text: this.newUrl,
                  placeholder: '仓库地址（https://…/manifest.json）' })
                  .width('100%')
                  .onChange((value: string) => {
                    this.newUrl = value;
                  })
                Row({ space: 8 }) {
                  Button('加入列表')
                    .height(40)
                    .layoutWeight(1)
                    .backgroundColor(this.colors().surfacePressed)
                    .fontColor(this.colors().textPrimary)
                    .onClick(() => {
                      this.addRepo();
                    })
                  Button('保存')
                    .height(40)
                    .layoutWeight(1)
                    .backgroundColor(this.colors().brandPrimary)
                    .fontColor(this.colors().onBrand)
                    .enabled(!this.saving && this.isDirty())
                    .onClick(() => {
                      this.save();
                    })
                }
                .width('100%')
                Text('新加的仓库默认**不启用**，确认地址没问题后再打开开关；')
                  .fontSize(ThemeConstants.META_SMALL)
                  .fontColor(this.colors().textTertiary)
                  .width('100%')
              }
              .width('100%')
              .padding(ThemeConstants.PAGE_PADDING)
            }

            Row({ space: 8 }) {
              Button('恢复')
                .height(40)
                .layoutWeight(1)
                .backgroundColor(this.colors().surfacePressed)
                .fontColor(this.colors().textPrimary)
                .enabled(!this.saving && this.isDirty())
                .onClick(() => {
                  this.load();
                })
            }
            .width('100%')
            .padding({ left: ThemeConstants.PAGE_PADDING, right: ThemeConstants.PAGE_PADDING })

            Blank().height(24)
          }
          .width('100%')
          .constraintSize({ maxWidth: ThemeConstants.SETTINGS_MAX_WIDTH })
        }
        .width('100%')
        .layoutWeight(1)
        .scrollBar(BarState.Auto)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(this.colors().pageBackground)
  }
}
