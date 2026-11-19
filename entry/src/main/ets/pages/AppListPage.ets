import { router, promptAction } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { photoAccessHelper } from '@kit.MediaLibraryKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppTheme, RouteParams } from '../common/AppTheme';
import { AssetLoader } from '../services/AssetLoader';
import { HostStore } from '../services/HostStore';
import { MoonApp, MoonAppList, MoonBridgeService, MoonHostInfo } from '../services/MoonBridgeService';

class CoverCropRouteParams {
  address: string = '';
  appId: number = 0;
  uri: string = '';
}

@Observed
class AppItem {
  id: number = 0;
  title: string = '';
  hdr: boolean = false;
  running: boolean = false;
  image: image.PixelMap | undefined = undefined;

  constructor(id: number, title: string, hdr: boolean) {
    this.id = id;
    this.title = title;
    this.hdr = hdr;
  }
}

@Component
struct AppCard {
  @StorageLink('lightTheme') lightTheme: boolean = true;
  @ObjectLink item: AppItem;

  pageTransition() {
    PageTransitionEnter({ duration: 0, curve: Curve.Linear })
    PageTransitionExit({ duration: 0, curve: Curve.Linear })
  }

  build() {
    Column() {
      Stack({ alignContent: Alignment.Bottom }) {
        if (this.item.image !== undefined) {
          Image(this.item.image)
            .draggable(false)
            .width('100%')
            .height('100%')
            .objectFit(ImageFit.Cover)
            .borderRadius(6)
        } else {
          Column() {
            LoadingProgress().width(28).height(28).color($r('app.color.app_text_dim'))
          }
          .width('100%')
          .height('100%')
          .justifyContent(FlexAlign.Center)
          .backgroundColor($r('app.color.app_card_bg'))
          .borderRadius(6)
        }
        if (this.item.running) {
          Column() {
            Image($r('app.media.ic_play'))
              .draggable(false)
              .width(40)
              .height(40)
              .fillColor(Color.White)
              .opacity(0.9)
            Blank()
          }
          .width('100%')
          .height('100%')
          .padding({ left: 8, top: 8 })
          .alignItems(HorizontalAlign.Start)
        }
        Text(this.item.title)
          .fontSize(14)
          .fontColor(Color.White)
          .maxLines(2)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .width('100%')
          .padding(6)
          .backgroundColor('#99000000')
      }
      .width('100%')
      .height(200)
    }
    .width(150)
    .height(200)
    .margin(6)
  }
}

@CustomDialog
struct AppMenuDialog {
  controller?: CustomDialogController;
  appTitle: string = '';
  onCover: () => void = () => {};
  onDetails: () => void = () => {};
  showReset: boolean = false;
  onReset: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      Text(this.appTitle)
        .fontSize(17)
        .fontColor($r('app.color.dialog_text'))
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 10 })
      Row() {
        Text('更换封面').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onCover();
      })
      Row() {
        Text('查看详情').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onDetails();
      })
      if (this.showReset) {
        Row() {
          Text('还原封面').fontSize(16).fontColor('#FF6B6B')
        }
        .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
        .onClick(() => {
          if (this.controller !== undefined) { this.controller.close(); }
          this.onReset();
        })
      }
      Button('取消')
        .width('100%').height(44).backgroundColor($r('app.color.dialog_btn'))
        .fontColor($r('app.color.dialog_text'))
        .margin({ top: 8 })
        .onClick(() => {
          if (this.controller !== undefined) { this.controller.close(); }
        })
    }
    .padding(16)
    .width(360)
    .backgroundColor($r('app.color.dialog_bg'))
    .borderRadius(16)
  }
}

@CustomDialog
struct QuitConfirmDialog {
  controller?: CustomDialogController;
  message: string = '';
  onConfirm: () => void = () => {};

  build() {
    Column({ space: 12 }) {
      Text('退出应用')
        .fontSize(17)
        .fontColor($r('app.color.dialog_text'))
        .fontWeight(FontWeight.Medium)
      Text(this.message)
        .fontSize(14)
        .fontColor($r('app.color.app_text_dim'))
        .textAlign(TextAlign.Center)
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor($r('app.color.dialog_btn'))
          .fontColor($r('app.color.dialog_text'))
          .onClick(() => {
            if (this.controller !== undefined) { this.controller.close(); }
          })
        Button('确定')
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#E5484D')
          .fontColor($r('app.color.dialog_text'))
          .onClick(() => {
            if (this.controller !== undefined) { this.controller.close(); }
            this.onConfirm();
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .padding(18)
    .width(360)
    .backgroundColor($r('app.color.dialog_bg'))
    .borderRadius(16)
  }
}

@CustomDialog
struct RunningMenuDialog {
  controller?: CustomDialogController;
  appTitle: string = '';
  onResume: () => void = () => {};
  onQuit: () => void = () => {};
  onDetails: () => void = () => {};
  onShortcut: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      Text(this.appTitle)
        .fontSize(17)
        .fontColor($r('app.color.dialog_text'))
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 10 })
      Row() {
        Text('恢复串流').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onResume();
      })
      Row() {
        Text('退出串流').fontSize(16).fontColor('#FF6B6B')
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onQuit();
      })
      Row() {
        Text('查看详情').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onDetails();
      })
      Row() {
        Text('创建快捷方式').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onShortcut();
      })
      Button('取消')
        .width('100%').height(44).backgroundColor($r('app.color.dialog_btn')).fontColor($r('app.color.dialog_text'))
        .margin({ top: 10 })
        .onClick(() => {
          if (this.controller !== undefined) { this.controller.close(); }
        })
    }
    .padding(16)
    .width(380)
    .backgroundColor($r('app.color.dialog_bg'))
    .borderRadius(16)
  }
}

@CustomDialog
struct BusyMenuDialog {
  controller?: CustomDialogController;
  appTitle: string = '';
  onQuitAndStart: () => void = () => {};
  onHide: () => void = () => {};
  onDetails: () => void = () => {};
  onShortcut: () => void = () => {};

  build() {
    Column({ space: 2 }) {
      Text(this.appTitle)
        .fontSize(17)
        .fontColor($r('app.color.dialog_text'))
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 10 })
      Row() {
        Text('退出当前应用并开始这个应用').fontSize(16).fontColor('#FFB74D')
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onQuitAndStart();
      })
      Row() {
        Text('隐藏应用').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onHide();
      })
      Row() {
        Text('查看详情').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onDetails();
      })
      Row() {
        Text('创建快捷方式').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .onClick(() => {
        if (this.controller !== undefined) { this.controller.close(); }
        this.onShortcut();
      })
    }
    .padding(16)
    .width(380)
    .backgroundColor($r('app.color.dialog_bg'))
    .borderRadius(16)
  }
}

@Entry
@Component
struct AppListPage {
  @StorageLink('lightTheme') lightTheme: boolean = true;
  @State apps: AppItem[] = [];
  @State hostAddress: string = '';
  @State hostName: string = '';
  @State loading: boolean = true;
  @State errorText: string = '';
  @State runningGameId: number = 0;
  @StorageLink('confirmLaunch') confirmLaunch: boolean = true;
  @State gridTemplate: string = '1fr 1fr 1fr 1fr 1fr 1fr';
  @State menuTitle: string = '';
  @State menuAppId: number = 0;
  private runningDialog: CustomDialogController | undefined = undefined;
  private busyDialog: CustomDialogController | undefined = undefined;
  private confirmDialog: CustomDialogController | undefined = undefined;
  private bridge: MoonBridgeService = MoonBridgeService.get();
  private menuDialog: CustomDialogController | undefined = undefined;

  aboutToAppear(): void {
    this.bridge.ensureInit(getContext(this).filesDir);
    const params = router.getParams() as RouteParams;
    if (params !== undefined && params.address !== undefined && params.address.length > 0) {
      this.hostAddress = params.address;
    }
    this.hostName = this.hostAddress;
    this.loadApps();
  }

  onPageShow(): void {
    this.refreshRunning();
    this.reloadCustomCovers();
  }

  private reloadCustomCovers(): void {
    for (let i = 0; i < this.apps.length; i++) {
      const item: AppItem = this.apps[i];
      const custom = this.loadCustomCover(item.id);
      if (custom !== undefined) {
        item.image = custom;
      }
    }
  }

  async refreshRunning(): Promise<void> {
    try {
      const text: string = await this.bridge.getHostInfo(this.hostAddress);
      const info = JSON.parse(text) as MoonHostInfo;
      this.runningGameId = info.runningGameId;
      for (let i = 0; i < this.apps.length; i++) {
        this.apps[i].running = this.apps[i].id === this.runningGameId;
      }
    } catch (error) {
    }
  }

  openStream(item: AppItem): void {
    HostStore.rememberAddress(this.hostAddress);
    this.bridge.markStreamPaused(false);
    const params = new RouteParams();
    params.address = this.hostAddress;
    params.appId = item.id;
    params.appTitle = item.title;
    router.pushUrl({ url: 'pages/StreamPage', params: params });
  }

  openQuitConfirm(onConfirm: () => void): void {
    this.confirmDialog = new CustomDialogController({
      builder: QuitConfirmDialog({
        message: '您确定要退出当前应用吗？所有未保存的数据将丢失。',
        onConfirm: onConfirm
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.confirmDialog.open();
  }

  async doQuitRunning(): Promise<void> {
    await this.bridge.quitApp(this.hostAddress);
    setTimeout(() => {
      this.refreshRunning();
    }, 1500);
  }

  quitRunning(): void {
    this.openQuitConfirm(() => {
      this.doQuitRunning();
    });
  }

  async loadApps(): Promise<void> {
    this.loading = true;
    this.errorText = '';
    try {
      const text: string = await this.bridge.getHostInfo(this.hostAddress);
      const info = JSON.parse(text) as MoonHostInfo;
      if (info.hostname.length > 0) {
        this.hostName = info.hostname;
      }
      const listText: string = await this.bridge.getAppList(this.hostAddress);
      const list = JSON.parse(listText) as MoonAppList;
      if (list.error.length > 0) {
        this.errorText = list.error;
      }
      this.runningGameId = info.runningGameId;
      const items: AppItem[] = [];
      for (let i = 0; i < list.apps.length; i++) {
        const app: MoonApp = list.apps[i];
        const item = new AppItem(app.id, app.title, app.hdr);
        item.running = app.id === this.runningGameId;
        items.push(item);
      }
      this.apps = items;
      for (let i = 0; i < items.length; i++) {
        const item: AppItem = items[i];
        const custom = this.loadCustomCover(item.id);
        if (custom !== undefined) {
          item.image = custom;
        } else {
          const pm = await AssetLoader.load(this.hostAddress, item.id);
          if (pm !== undefined) {
            item.image = pm;
          }
        }
      }
    } catch (error) {
      this.errorText = JSON.stringify(error);
    }
    this.loading = false;
  }

  showDetails(appId: number, title: string): void {
    AlertDialog.show({
      title: '应用详情',
      message: '应用：' + title + '\n应用 ID：' + appId.toString() +
        '\n主机：' + this.hostName + ' (' + this.hostAddress + ')',
      confirm: { value: '关闭', action: () => {} }
    });
  }

  openRunningMenu(item: AppItem): void {
    this.runningDialog = new CustomDialogController({
      builder: RunningMenuDialog({
        appTitle: item.title,
        onResume: () => {
          const target = this.apps.find((app: AppItem) => app.id === item.id);
          if (target !== undefined) {
            this.openStream(target);
          }
        },
        onQuit: () => {
          this.quitRunning();
        },
        onDetails: () => {
          this.showDetails(item.id, item.title);
        },
        onShortcut: () => {
          promptAction.showToast({ message: '当前版本暂不支持创建快捷方式' });
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.runningDialog.open();
  }

  openBusyMenu(item: AppItem): void {
    this.busyDialog = new CustomDialogController({
      builder: BusyMenuDialog({
        appTitle: item.title,
        onQuitAndStart: () => {
          this.openQuitConfirm(() => {
            this.quitAndStart(item);
          });
        },
        onHide: () => {
          this.apps = this.apps.filter((app: AppItem) => app.id !== item.id);
          promptAction.showToast({ message: '已隐藏 ' + item.title });
        },
        onDetails: () => {
          this.showDetails(item.id, item.title);
        },
        onShortcut: () => {
          promptAction.showToast({ message: '当前版本暂不支持创建快捷方式' });
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.busyDialog.open();
  }

  private requestLaunch(item: AppItem): void {
    if (!this.confirmLaunch) {
      this.openStream(item);
      return;
    }
    AlertDialog.show({
      title: item.title,
      message: '确定要启动这个应用吗？',
      primaryButton: {
        value: '启动',
        action: () => {
          this.openStream(item);
        }
      },
      secondaryButton: {
        value: '取消',
        action: () => {
        }
      }
    });
  }

  async quitAndStart(item: AppItem): Promise<void> {
    promptAction.showToast({ message: '正在退出当前应用...' });
    await this.bridge.quitApp(this.hostAddress);
    setTimeout(() => {
      this.openStream(item);
    }, 1500);
  }

  private coverDir(): string {
    const dir: string = getContext(this).filesDir + '/covers';
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (error) {
    }
    return dir;
  }

  private coverPath(appId: number): string {
    return this.coverDir() + '/' + this.hostAddress + '_' + appId.toString() + '.jpg';
  }

  private loadCustomCover(appId: number): image.PixelMap | undefined {
    try {
      const path: string = this.coverPath(appId);
      if (!fs.accessSync(path)) {
        return undefined;
      }
      const stat = fs.statSync(path);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      const source: image.ImageSource = image.createImageSource(buf);
      return source.createPixelMapSync();
    } catch (error) {
      this.bridge.logUi('cover load failed appid=' + appId.toString() + ': ' + JSON.stringify(error));
      return undefined;
    }
  }

  private async pickCover(item: AppItem): Promise<void> {
    try {
      const picker = new photoAccessHelper.PhotoViewPicker();
      const options: photoAccessHelper.PhotoSelectOptions = {
        MIMEType: photoAccessHelper.PhotoViewMIMETypes.IMAGE_TYPE,
        maxSelectNumber: 1
      };
      const result = await picker.select(options);
      this.bridge.logUi('cover pick count=' + result.photoUris.length.toString());
      if (result.photoUris.length === 0) {
        return;
      }
      this.bridge.logUi('cover pick uri=' + result.photoUris[0]);
      const params = new CoverCropRouteParams();
      params.address = this.hostAddress;
      params.appId = item.id;
      params.uri = result.photoUris[0];
      router.pushUrl({ url: 'pages/CoverCropPage', params: params });
    } catch (error) {
      this.bridge.logUi('cover pick failed: ' + JSON.stringify(error));
      promptAction.showToast({ message: '打开图片选择器失败' });
    }
  }

  private resetCover(item: AppItem): void {
    this.bridge.logUi('cover reset appid=' + item.id.toString());
    try {
      const path: string = this.coverPath(item.id);
      if (fs.accessSync(path)) {
        fs.unlinkSync(path);
      }
    } catch (error) {
    }
    AssetLoader.load(this.hostAddress, item.id).then((pm: image.PixelMap | undefined) => {
      if (pm !== undefined) {
        item.image = pm;
      }
    });
  }

  private showCoverMenu(item: AppItem): void {
    let hasCustom: boolean = false;
    try {
      hasCustom = fs.accessSync(this.coverPath(item.id));
    } catch (error) {
      hasCustom = false;
    }
    const dlg = new CustomDialogController({
      builder: AppMenuDialog({
        appTitle: item.title,
        showReset: hasCustom,
        onCover: () => {
          if (this.menuDialog !== undefined) {
            this.menuDialog.close();
          }
          setTimeout(() => {
            this.pickCover(item);
          }, 320);
        },
        onDetails: () => {
          this.showAppDetails(item);
        },
        onReset: () => {
          this.resetCover(item);
          promptAction.showToast({ message: '封面已还原' });
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.menuDialog = dlg;
    dlg.open();
  }

  private showAppDetails(item: AppItem): void {
    AlertDialog.show({
      title: '应用详情',
      message: '名称：' + item.title +
        '\nHDR 支持：' + (item.hdr ? '是' : '未知') +
        '\n应用 ID：' + item.id.toString(),
      confirm: { value: '关闭', action: () => {} }
    });
  }

  build() {
    Stack() {
    Column() {
      Row() {
        Text('←')
          .fontSize(30)
          .fontColor($r('app.color.app_text'))
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            router.back();
          })
        Text(this.hostName)
          .fontSize(20)
          .fontColor($r('app.color.app_text'))
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
          .layoutWeight(1)
        Text('⟳')
          .fontSize(26)
          .fontColor($r('app.color.app_text'))
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            this.loadApps();
          })
      }
      .width('100%')
      .height(65)

      if (this.loading) {
        Column({ space: 12 }) {
          LoadingProgress().width(60).height(60).color($r('app.color.app_text'))
          Text('正在加载应用...').fontSize(18).fontColor($r('app.color.app_text'))
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else if (this.apps.length === 0) {
        Column({ space: 12 }) {
          Text(this.errorText.length > 0 ? this.errorText : '没有可用的应用').fontSize(18).fontColor($r('app.color.app_text_dim'))
          Button('刷新').backgroundColor($r('app.color.app_primary')).onClick(() => {
            this.loadApps();
          })
        }
        .width('100%')
        .layoutWeight(1)
        .justifyContent(FlexAlign.Center)
      } else {
        Grid() {
          ForEach(this.apps, (item: AppItem) => {
            GridItem() {
              AppCard({ item: item })
            }
            .gesture(LongPressGesture({ repeat: false, duration: 500 })
              .onAction(() => {
                this.showCoverMenu(item);
              }))
            .onClick(() => {
              if (item.id === this.runningGameId) {
                this.openRunningMenu(item);
              } else if (this.runningGameId !== 0) {
                this.openBusyMenu(item);
              } else {
                this.requestLaunch(item);
              }
            })
          }, (item: AppItem) => item.id.toString())
        }
        .columnsTemplate(this.gridTemplate)
        .columnsGap(4)
        .rowsGap(4)
        .width('100%')
        .layoutWeight(1)
        .onAreaChange((oldValue: Area, newValue: Area) => {
          const w: number = parseFloat(newValue.width.toString());
          let cols: number = Math.floor(w / 162);
          if (cols < 2) { cols = 2; }
          if (cols > 10) { cols = 10; }
          let tpl: string = '';
          for (let i = 0; i < cols; i++) {
            tpl += (i === 0 ? '' : ' ') + '1fr';
          }
          this.gridTemplate = tpl;
        })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))

    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
