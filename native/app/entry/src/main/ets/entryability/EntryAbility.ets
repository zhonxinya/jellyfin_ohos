import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import fs from '@ohos.file.fs';
import { SessionStore } from '../services/SessionStore';
import { JellyfinNative } from '../plugins/JellyfinNative';
import { PlaybackState } from '../common/PlaybackState';
import { MusicPlayback } from '../common/MusicPlayback';
import { AppViewModel } from '../viewmodel/AppViewModel';

const DOMAIN: number = 0x0000;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  /**
   * 把随包内置的 Mozilla CA 根证书（resources/rawfile/cacert.pem）释放到沙箱，
   * 再交给原生层用于 HTTPS 证书校验。放在 onCreate 里先于任何网络请求执行。
   */
  private prepareCaBundle(): void {
    try {
      const target: string = this.context.cacheDir + '/cacert.pem';
      const data: Uint8Array = this.context.resourceManager.getRawFileContentSync('cacert.pem');
      const file = fs.openSync(target, fs.OpenMode.CREATE | fs.OpenMode.READ_WRITE | fs.OpenMode.TRUNC);
      fs.writeSync(file.fd, data.buffer);
      fs.closeSync(file);
      const result: string = JellyfinNative.setCaBundlePath(target);
      hilog.info(DOMAIN, TAG, 'CA bundle ready (%{public}d bytes): %{public}s',
        data.byteLength, result);
    } catch (error) {
      hilog.error(DOMAIN, TAG, 'CA bundle 释放失败：%{public}s', JSON.stringify(error));
    }
  }

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    this.prepareCaBundle();
    SessionStore.init(this.context).then(() => {
      const cacheDir: string = this.context.cacheDir + '/jellyfin_images';
      JellyfinNative.setImageCacheDir(cacheDir);
      // 供「清除全部本地数据」清理系统图片管线在沙箱内的预加载缓存。
      // 注意必须用 **application** 级 cacheDir：`context.cacheDir` 是模块级
      // （.../haps/entry/cache），而 preload_caches 在 bundle 级
      // （.../base/cache）。设备探针实测：app.cacheDir 下 preload_caches = 283 个文件。
      SessionStore.setAppCacheDir(this.context.getApplicationContext().cacheDir);
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
    // 退出/被回收时结束播放会话：否则服务端会留下"看起来还在播"的会话，
    // 污染观看记录、继续观看与设备列表（实测 /Sessions 曾堆积到 60 条）。
    const itemId: string = PlaybackState.take();
    if (itemId.length > 0) {
      hilog.info(DOMAIN, TAG, 'onDestroy: report playback stopped for %{public}s', itemId);
      JellyfinNative.reportPlaybackStopped(itemId, PlaybackState.positionTicks());
    }
    // 音乐播放与页面解耦后（见 common/MusicPlayback），长时任务/AVSession 可能仍在运行：
    // 退出时必须显式收尾 —— 上报已停止、结束长时任务、销毁会话，
    // 否则下一次启动申请长时任务会被系统拒绝（#73 设备实测过的坑）。
    MusicPlayback.getInstance().shutdown();
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageCreate');
    try {
      const colorMode = this.context.config.colorMode;
      AppViewModel.getInstance().systemDark =
        colorMode !== ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT;
      AppViewModel.getInstance().notifyThemeChanged();
    } catch (_e) {
      AppViewModel.getInstance().systemDark = true;
    }
    windowStage.loadContent('pages/SplashPage', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Succeeded in loading content.');
    });
  }

  onWindowStageDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }
}
