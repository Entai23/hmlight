import { router, promptAction } from '@kit.ArkUI';
import { AppTheme } from '../common/AppTheme';
import { common, ConfigurationConstant } from '@kit.AbilityKit';
import { window } from '@kit.ArkUI';
import { fileIo as fs } from '@kit.CoreFileKit';
import { HostEntry, HostStore } from '../services/HostStore';
import { MoonBridgeService, MoonHostInfo } from '../services/MoonBridgeService';

@Entry
@Component
struct Index {
  @StorageLink('lightTheme') lightTheme: boolean = true;
  @State hostGridTemplate: string = '1fr 1fr 1fr 1fr';
  @State hosts: HostEntry[] = [];
  @State browsing: boolean = false;
  @State overlayMode: string = 'none';
  @State manualAddress: string = '';
  @State pairPin: string = '';
  @State pairStatus: string = '';
  @State helpVisible: boolean = false;
  private bridge: MoonBridgeService = MoonBridgeService.get();

  @StorageLink('devMode') devMode: boolean = false;
  @StorageLink('diagLogging') diagLogging: boolean = false;

  private applyBars(): void {
    const light: boolean = this.lightTheme;
    const bg: string = light ? '#F5F7FA' : '#000000';
    const fg: string = light ? '#000000' : '#FFFFFF';
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      win.setWindowBackgroundColor(bg);
      win.setWindowSystemBarProperties({
        statusBarColor: bg,
        navigationBarColor: bg,
        statusBarContentColor: fg,
        navigationBarContentColor: fg
      }).catch(() => {});
    }).catch(() => {});
  }

  aboutToAppear(): void {
    const context = getContext(this);
    this.bridge.ensureInit(context.filesDir);
    try {
      (getContext(this) as common.UIAbilityContext).getApplicationContext().setColorMode(this.lightTheme
        ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
        : ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
    } catch (error) {
    }
    try {
      const f = fs.openSync(context.filesDir + '/theme_light', fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY);
      const b = new ArrayBuffer(1);
      new Uint8Array(b)[0] = this.lightTheme ? 1 : 0;
      fs.writeSync(f.fd, b);
      fs.closeSync(f);
    } catch (error) {
    }
    this.applyBars();
    this.bridge.setDiagEnabled(this.diagLogging && this.devMode);
    this.bridge.setEventCallback((type: string, payload: string) => {
      if (type === 'terminated') {
        this.refreshHosts();
      }
    });
    this.hosts = HostStore.load();
    this.refreshHosts();
  }

  onPageShow(): void {
    this.applyBars();
    this.refreshHosts();
  }

  async refreshHosts(): Promise<void> {
    let list: HostEntry[] = HostStore.load();
    if (list.length === 0) {
      const last: string = HostStore.lastAddress();
      if (last.length > 0) {
        list = [new HostEntry('电脑', last, false, false)];
      }
    }
    this.browsing = true;
    const updated: HostEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      const host: HostEntry = list[i];
      try {
        const text: string = await this.bridge.getHostInfo(host.address);
        const info = JSON.parse(text) as MoonHostInfo;
        host.online = info.online;
        if (info.hostname.length > 0) {
          host.name = info.hostname;
        }
        if (info.pairStatus === 1) {
          host.paired = true;
        }
      } catch (error) {
        host.online = false;
      }
      updated.push(host);
    }
    this.hosts = updated;
    HostStore.save(updated);
    this.browsing = false;
  }

  generatePin(): string {
    let pin: string = '';
    for (let i = 0; i < 4; i++) {
      pin = pin + Math.floor(Math.random() * 10).toString();
    }
    return pin;
  }

  async startPairing(host: HostEntry): Promise<void> {
    this.pairPin = this.generatePin();
    this.pairStatus = '等待 PC 端输入 PIN...';
    this.overlayMode = 'pair';
    try {
      const begin: string = await this.bridge.pairBegin(host.address);
      if (begin === 'READY') {
        this.pairStatus = '正在完成配对校验...';
        const done: string = await this.bridge.pairComplete(host.address, this.pairPin);
        if (done === 'PAIRED') {
          host.paired = true;
          HostStore.upsert(host);
          HostStore.rememberAddress(host.address);
          this.overlayMode = 'none';
          promptAction.showToast({ message: '配对成功' });
          this.refreshHosts();
          return;
        }
        this.pairStatus = '配对失败: ' + done;
      } else if (begin === 'ALREADY_PAIRED') {
        host.paired = true;
        HostStore.upsert(host);
        this.overlayMode = 'none';
        this.refreshHosts();
      } else {
        this.pairStatus = '配对失败: ' + begin;
      }
    } catch (error) {
      this.pairStatus = '配对异常: ' + JSON.stringify(error);
    }
  }

  onHostClick(host: HostEntry): void {
    if (!host.online) {
      promptAction.showToast({ message: '电脑离线' });
      return;
    }
    HostStore.rememberAddress(host.address);
    if (!host.paired) {
      this.startPairing(host);
      return;
    }
    router.pushUrl({ url: 'pages/AppListPage', params: { address: host.address } });
  }

  addManualHost(): void {
    const address: string = this.manualAddress.trim();
    if (address.length === 0) {
      return;
    }
    const entry = new HostEntry(address, address, false, false);
    HostStore.upsert(entry);
    HostStore.rememberAddress(address);
    this.overlayMode = 'none';
    this.manualAddress = '';
    this.refreshHosts();
  }

  pageTransition() {
    PageTransitionEnter({ duration: 0, curve: Curve.Linear })
    PageTransitionExit({ duration: 0, curve: Curve.Linear })
  }

  build() {
    Stack() {
      Column() {
        Row() {
          Image($r('app.media.ic_settings'))
            .width(34)
            .height(34)
            .margin({ left: 18 })
            .fillColor($r('app.color.app_text'))
            .onClick(() => {
              router.pushUrl({ url: 'pages/SettingsPage' });
            })
          Image($r('app.media.ic_help'))
            .width(34)
            .height(34)
            .margin({ left: 22 })
            .fillColor($r('app.color.app_text'))
            .onClick(() => {
              router.pushUrl({ url: 'pages/HelpPage' });
            })
          Blank()
          Image($r('app.media.ic_add'))
            .width(34)
            .height(34)
            .margin({ right: 18 })
            .fillColor($r('app.color.app_text'))
            .onClick(() => {
              this.overlayMode = 'add';
            })
        }
        .width('100%')
        .height(65)

        if (this.hosts.length === 0 || this.browsing) {
          Column({ space: 12 }) {
            LoadingProgress().width(60).height(60).color($r('app.color.app_text'))
            Text('正在搜索电脑...').fontSize(20).fontColor($r('app.color.app_text'))
          }
          .width('100%')
          .layoutWeight(1)
          .justifyContent(FlexAlign.Center)
        } else {
          Grid() {
            ForEach(this.hosts, (host: HostEntry) => {
              GridItem() {
                Column() {
                  Stack() {
                    Image($r('app.media.ic_computer'))
                      .width(AppTheme.pcIconSize)
                      .height(AppTheme.pcIconSize)
                      .opacity(host.online ? 1.0 : 0.4)
                      .fillColor($r('app.color.app_text'))
                    if (host.online && !host.paired) {
                      Image($r('app.media.ic_lock'))
                        .width(50)
                        .height(50)
                        .margin({ top: 28 })
                        .fillColor($r('app.color.app_text'))
                    }
                    if (!host.online) {
                      Image($r('app.media.ic_pc_offline'))
                        .width(50)
                        .height(50)
                        .margin({ top: 28 })
                        .fillColor($r('app.color.app_text'))
                        .opacity(0.4)
                    }
                  }
                  .width(AppTheme.pcIconSize)
                  .height(AppTheme.pcIconSize)

                  Text(host.name)
                    .fontSize(18)
                    .fontColor($r('app.color.app_text'))
                    .maxLines(1)
                    .textOverflow({ overflow: TextOverflow.Ellipsis })
                    .opacity(host.online ? 1.0 : 0.4)
                    .margin({ top: 10 })
                    .width(AppTheme.pcIconSize)
                    .textAlign(TextAlign.Center)
                }
                .width('100%')
                .alignItems(HorizontalAlign.Center)
                .padding(20)
              }
              .onClick(() => {
                this.onHostClick(host);
              })
              .gesture(
                LongPressGesture().onAction(() => {
                  HostStore.remove(host.address);
                  this.refreshHosts();
                })
              )
            }, (host: HostEntry) => host.address)
          }
          .columnsTemplate(this.hostGridTemplate)
          .onAreaChange((oldValue: Area, newValue: Area) => {
            const w: number = parseFloat(newValue.width.toString());
            let cols: number = Math.floor(w / 150);
            if (cols < 2) { cols = 2; }
            if (cols > 8) { cols = 8; }
            let tpl: string = '';
            for (let i = 0; i < cols; i++) {
              tpl += (i === 0 ? '' : ' ') + '1fr';
            }
            this.hostGridTemplate = tpl;
          })
          .width('100%')
          .layoutWeight(1)
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor($r('app.color.app_background'))

      if (this.overlayMode === 'add') {
        Column() {
          Column({ space: 14 }) {
            Text('手动添加电脑').fontSize(20).fontColor($r('app.color.app_text'))
            TextInput({ text: this.manualAddress, placeholder: '电脑 IP 地址' })
              .type(InputType.Normal)
              .onChange((value: string) => {
                this.manualAddress = value;
              })
            Row({ space: 12 }) {
              Button('取消')
                .layoutWeight(1)
                .backgroundColor($r('app.color.app_button_bg'))
                .onClick(() => {
                  this.overlayMode = 'none';
                })
              Button('确定')
                .layoutWeight(1)
                .backgroundColor($r('app.color.app_primary'))
                .onClick(() => {
                  this.addManualHost();
                })
            }
            .width('100%')
          }
          .padding(24)
          .width(420)
          .backgroundColor($r('app.color.app_surface'))
          .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      if (this.overlayMode === 'pair') {
        Column() {
          Column({ space: 16 }) {
            Text('配对电脑').fontSize(20).fontColor($r('app.color.app_text'))
            Text(this.pairPin)
              .fontSize(48)
              .fontWeight(FontWeight.Bold)
              .fontColor($r('app.color.app_primary'))
            Text('请在上方电脑的 Apollo 配对框中输入此 PIN')
              .fontSize(15)
              .fontColor($r('app.color.app_text_dim'))
            Text(this.pairStatus).fontSize(13).fontColor($r('app.color.app_text_dim'))
            Button('取消')
              .backgroundColor($r('app.color.app_button_bg'))
              .onClick(() => {
                this.overlayMode = 'none';
                this.bridge.stopConnection();
              })
          }
          .padding(24)
          .width(460)
          .backgroundColor($r('app.color.app_surface'))
          .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }

      if (this.helpVisible) {
        Column() {
          Column({ space: 14 }) {
            Text('帮助').fontSize(20).fontColor($r('app.color.app_text'))
            Text('• 点击右上角 + 手动添加电脑 IP\n• 未配对的电脑会显示锁图标，点击完成配对\n• 长按电脑卡片可删除\n• 配对时 PIN 显示在此页面，需要输入到 PC 端')
              .fontSize(15)
              .fontColor($r('app.color.app_text_dim'))
            Button('知道了')
              .backgroundColor($r('app.color.app_primary'))
              .onClick(() => {
                this.helpVisible = false;
              })
          }
          .padding(24)
          .width(520)
          .backgroundColor($r('app.color.app_surface'))
          .borderRadius(12)
        }
        .width('100%')
        .height('100%')
        .backgroundColor('#99000000')
        .justifyContent(FlexAlign.Center)
        .alignItems(HorizontalAlign.Center)
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor($r('app.color.app_background'))
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
