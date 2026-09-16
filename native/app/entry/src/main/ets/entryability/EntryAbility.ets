import AbilityConstant from '@ohos.app.ability.AbilityConstant';
import UIAbility from '@ohos.app.ability.UIAbility';
import Want from '@ohos.app.ability.Want';
import ConfigurationConstant from '@ohos.app.ability.ConfigurationConstant';
import window from '@ohos.window';
import hilog from '@ohos.hilog';
import { SessionStore } from '../services/SessionStore';
import { JellyfinNative } from '../plugins/JellyfinNative';
import { AppViewModel } from '../viewmodel/AppViewModel';

const DOMAIN: number = 0x0000;
const TAG: string = 'EntryAbility';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
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
