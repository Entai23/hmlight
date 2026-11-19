import { AbilityConstant, ConfigurationConstant, UIAbility, Want, bundleManager } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { HostStore } from '../services/HostStore';
import { fileIo as fs } from '@kit.CoreFileKit';

const DOMAIN = 0x0000;

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onCreate');
    const light: boolean = this.readThemeFile();
    bundleManager.setAlternateIcon(light ? 'light' : 'dark').catch(() => {});
    try {
      this.context.getApplicationContext().setColorMode(light
        ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'setColorMode failed: %{public}s', JSON.stringify(err));
    }
  }

  onDestroy(): void {
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    // Main window is created, set main page for this ability
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageCreate');

    this.applySystemBars(windowStage);

    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, 'testTag', 'Failed to load the content. Cause: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, 'testTag', 'Succeeded in loading the content.');
      this.applySystemBars(windowStage);
    });

    const light: boolean = AppStorage.get<boolean>('lightTheme') === true;
    try {
      this.context.getApplicationContext().setColorMode(light
        ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (err) {
      hilog.error(DOMAIN, 'testTag', 'Failed to set colorMode. Cause: %{public}s', JSON.stringify(err));
    }
  }

  private readThemeFile(): boolean {
    try {
      const f = fs.openSync(this.context.filesDir + '/theme_light', fs.OpenMode.READ_ONLY);
      const buf: ArrayBuffer = new ArrayBuffer(1);
      fs.readSync(f.fd, buf);
      fs.closeSync(f);
      return new Uint8Array(buf)[0] === 1;
    } catch (error) {
      return AppStorage.get<boolean>('lightTheme') !== false;
    }
  }

  private applySystemBars(windowStage: window.WindowStage): void {
    windowStage.getMainWindow().then((win: window.Window) => {
      const light: boolean = this.readThemeFile();
      const bg: string = light ? '#F5F7FA' : '#000000';
      const fg: string = light ? '#000000' : '#FFFFFF';
      win.setWindowLayoutFullScreen(false).catch(() => {});
      win.setWindowBackgroundColor(bg);
      win.setWindowSystemBarProperties({
        statusBarColor: bg,
        navigationBarColor: bg,
        statusBarContentColor: fg,
        navigationBarContentColor: fg
      });
    }).catch(() => {
    });
  }

  onWindowStageDestroy(): void {
    // Main window is destroyed, release UI related resources
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    // Ability has brought to foreground
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onForeground');
    try {
      this.applySystemBars(this.context.windowStage);
    } catch (err) {
    }
  }

  onBackground(): void {
    // Ability has back to background
    hilog.info(DOMAIN, 'testTag', '%{public}s', 'Ability onBackground');
  }
}