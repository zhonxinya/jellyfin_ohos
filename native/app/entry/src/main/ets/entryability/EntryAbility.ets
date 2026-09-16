import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import fs from '@ohos.file.fs';
import { SessionStore } from '../services/SessionStore';
import { JellyfinNative } from '../plugins/JellyfinNative';
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
    });
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
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
