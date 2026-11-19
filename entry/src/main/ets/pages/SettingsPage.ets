import { router, promptAction, window } from '@kit.ArkUI';
import display from '@ohos.display';
import { bundleManager, common, ConfigurationConstant } from '@kit.AbilityKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppTheme } from '../common/AppTheme';
import { MoonBridgeService } from '../services/MoonBridgeService';

@Component
struct SnapSlider {
  @StorageLink('lightTheme') lightTheme: boolean = true;
  @Prop value: number = 0;
  min: number = 0;
  max: number = 4;
  step: number = 1;
  onChanged: (v: number) => void = () => {};
  onLive: (v: number) => void = () => {};
  @State trackW: number = 240;
  @State dragging: boolean = false;
  @State dragX: number = 0;
  private dragStartX: number = 0;
  private readonly thumbSize: number = 22;
  private readonly trackHeight: number = 8;
  private readonly hitSize: number = 44;

  private usable(): number {
    return this.trackW - this.thumbSize;
  }

  private fraction(): number {
    if (this.max <= this.min) {
      return 0;
    }
    const f: number = (this.value - this.min) / (this.max - this.min);
    return f < 0 ? 0 : (f > 1 ? 1 : f);
  }

  private thumbX(): number {
    if (this.dragging) {
      return this.dragX;
    }
    return this.usable() * this.fraction();
  }

  private valueFromX(x: number): number {
    const u: number = this.usable();
    if (u <= 0) {
      return this.min;
    }
    return this.min + (x / u) * (this.max - this.min);
  }

  private snapValue(raw: number): number {
    if (this.step <= 0) {
      return raw;
    }
    let stepped: number = Math.round((raw - this.min) / this.step);
    const maxSteps: number = Math.round((this.max - this.min) / this.step);
    if (stepped < 0) { stepped = 0; }
    if (stepped > maxSteps) { stepped = maxSteps; }
    return this.min + stepped * this.step;
  }

  build() {
    Stack({ alignContent: Alignment.Start }) {
      Row()
        .width('100%')
        .height(this.trackHeight)
        .backgroundColor('#3A3A3C')
        .borderRadius(this.trackHeight / 2)
        .position({ x: 0, y: (this.hitSize - this.trackHeight) / 2 })
      Row()
        .width(this.thumbX() + this.thumbSize / 2)
        .height(this.trackHeight)
        .backgroundColor($r('app.color.app_primary'))
        .borderRadius(this.trackHeight / 2)
        .position({ x: 0, y: (this.hitSize - this.trackHeight) / 2 })
      Stack() {
        Row()
          .width(this.thumbSize)
          .height(this.thumbSize)
          .borderRadius(this.thumbSize / 2)
          .backgroundColor(Color.White)
          .border({ width: 2, color: $r('app.color.app_primary') })
      }
      .width(this.hitSize)
      .height(this.hitSize)
      .position({ x: this.thumbX() - (this.hitSize - this.thumbSize) / 2, y: 0 })
      .gesture(
        PanGesture({ fingers: 1, distance: 0.5 })
          .onActionStart(() => {
            this.dragStartX = this.thumbX();
            this.dragX = this.dragStartX;
            this.dragging = true;
          })
          .onActionUpdate((event: GestureEvent) => {
            const u: number = this.usable();
            if (u <= 0) {
              return;
            }
            let next: number = this.dragStartX + event.offsetX;
            if (next < 0) { next = 0; }
            if (next > u) { next = u; }
            this.dragX = next;
            this.onLive(this.snapValue(this.valueFromX(next)));
          })
          .onActionEnd(() => {
            const v: number = this.snapValue(this.valueFromX(this.dragX));
            this.onChanged(v);
            animateTo({ duration: 180, curve: Curve.EaseOut }, () => {
              this.dragging = false;
            });
            setTimeout(() => {
              this.onLive(-1);
            }, 200);
          })
          .onActionCancel(() => {
            this.dragging = false;
            this.onLive(-1);
          })
      )
    }
    .width('100%')
    .height(this.hitSize)
    .onAreaChange((oldValue: Area, newValue: Area) => {
      this.trackW = parseFloat(newValue.width.toString());
    })
  }
}

@CustomDialog
struct NativeScaleDialog {
  controller?: CustomDialogController;
  nativeText: string = '';
  currentScale: number = 100;
  onPick: (scale: number) => void = () => {};
  @State selected: number = 100;

  aboutToAppear(): void {
    this.selected = this.currentScale;
  }

  private pick(scale: number): void {
    this.selected = scale;
    setTimeout(() => {
      this.onPick(scale);
      if (this.controller !== undefined) {
        this.controller.close();
      }
    }, 220);
  }

  build() {
    Column({ space: 2 }) {
      Text('原生分辨率调节')
        .fontSize(17)
        .fontColor($r('app.color.dialog_text'))
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 4 })
      Text(this.nativeText)
        .fontSize(12)
        .fontColor($r('app.color.app_text_dim'))
        .margin({ bottom: 8 })
      Row() {
        Text('原生 100%').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .backgroundColor(this.selected === 100 ? '#2E6BE6' : '#00000000')
      .onClick(() => {
        this.pick(100);
      })
      Row() {
        Text('1/2 像素（宽高 ×0.71）').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .backgroundColor(this.selected === 50 ? '#2E6BE6' : '#00000000')
      .onClick(() => {
        this.pick(50);
      })
      Row() {
        Text('1/4 像素（宽高 ×0.5）').fontSize(16).fontColor($r('app.color.dialog_text'))
      }
      .width('100%').height(46).justifyContent(FlexAlign.Center).borderRadius(10)
      .backgroundColor(this.selected === 25 ? '#2E6BE6' : '#00000000')
      .onClick(() => {
        this.pick(25);
      })
      Button('取消')
        .width('100%').height(44).backgroundColor($r('app.color.dialog_btn')).fontColor($r('app.color.dialog_text'))
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
struct SensitivityDialog {
  controller?: CustomDialogController;
  initialLevel: number = 2;
  onSave: (level: number) => void = () => {};
  @State level: number = 2;

  aboutToAppear(): void {
    this.level = this.initialLevel;
  }

  private levelText(): string {
    const sens: number[] = [0.5, 0.75, 1.0, 1.5, 2.0];
    const l: number = this.level < 0 ? 0 : (this.level > 4 ? 4 : this.level);
    return '×' + sens[l].toFixed(l === 1 || l === 2 ? 0 : 2).replace(/0+$/, '').replace(/\.$/, '');
  }

  build() {
    Column({ space: 12 }) {
      Text('触控板灵敏度')
        .fontSize(17)
        .fontColor($r('app.color.dialog_text'))
        .fontWeight(FontWeight.Medium)
      Text(this.levelText())
        .fontSize(20)
        .fontColor('#FFB74D')
      Slider({
        value: this.level,
        min: 0,
        max: 4,
        step: 1,
        style: SliderStyle.OutSet
      })
        .width(260)
        .trackThickness(10)
        .blockSize({ width: 24, height: 24 })
        .selectedColor('#FFB74D')
        .onChange((value: number) => {
          this.level = Math.round(value);
        })
      Row({ space: 10 }) {
        Button('取消')
          .layoutWeight(1)
          .height(44)
          .backgroundColor($r('app.color.dialog_btn'))
          .fontColor($r('app.color.dialog_text'))
          .onClick(() => {
            if (this.controller !== undefined) { this.controller.close(); }
          })
        Button('保存')
          .layoutWeight(1)
          .height(44)
          .backgroundColor('#E58A2B')
          .fontColor($r('app.color.dialog_text'))
          .onClick(() => {
            this.onSave(this.level);
            if (this.controller !== undefined) { this.controller.close(); }
          })
      }
      .width('100%')
      .margin({ top: 4 })
    }
    .padding(18)
    .width(340)
    .backgroundColor($r('app.color.dialog_bg'))
    .borderRadius(16)
  }
}

@CustomDialog
struct PickerDialog {
  controller?: CustomDialogController;
  dialogTitle: string = '';
  dialogOptions: string[] = [];
  onPick: (value: string) => void = () => {};

  build() {
    Column({ space: 2 }) {
      Text(this.dialogTitle)
        .fontSize(17)
        .fontColor($r('app.color.dialog_text'))
        .fontWeight(FontWeight.Medium)
        .margin({ bottom: 10 })
      ForEach(this.dialogOptions, (option: string) => {
        Row() {
          Text(option)
            .fontSize(16)
            .fontColor($r('app.color.dialog_text'))
        }
        .width('100%')
        .height(46)
        .justifyContent(FlexAlign.Center)
        .borderRadius(10)
        .onClick(() => {
          this.onPick(option);
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
      }, (option: string) => option)
      Button('取消')
        .width('100%')
        .height(44)
        .backgroundColor($r('app.color.dialog_btn'))
        .fontColor($r('app.color.dialog_text'))
        .margin({ top: 10 })
        .onClick(() => {
          if (this.controller !== undefined) {
            this.controller.close();
          }
        })
    }
    .padding(16)
    .width(360)
    .backgroundColor($r('app.color.dialog_bg'))
    .borderRadius(16)
  }
}

@Entry
@Component
struct SettingsPage {
  @StorageLink('lightTheme') lightTheme: boolean = true;
  @StorageLink('streamWidth') streamWidth: number = 1280;
  @StorageLink('streamHeight') streamHeight: number = 720;
  @StorageLink('streamFps') streamFps: number = 60;
  @StorageLink('streamBitrate') streamBitrate: number = 10000;
  @StorageLink('videoCodec') videoCodec: number = 0;
  @StorageLink('showPerf') showPerf: boolean = true;
  @StorageLink('settingsDialogMode') settingsDialogMode: boolean = false;
  @StorageLink('useVirtualDisplay') useVirtualDisplay: boolean = false;
  @StorageLink('adaptiveBitrate') adaptiveBitrate: boolean = true;
  @StorageLink('audioConfig') audioConfig: number = 0x302CA;
  @StorageLink('gamepadEnabled') gamepadEnabled: boolean = false;
  @StorageLink('gamepadMode') gamepadMode: number = 0;
  @StorageLink('touchpadMode') touchpadMode: boolean = false;
  @StorageLink('touchpadSensitivity') touchpadSensitivity: number = 2;
  @StorageLink('stretchVideo') stretchVideo: boolean = false;
  @StorageLink('fullRange') fullRange: boolean = false;
  @StorageLink('smartMouse') smartMouse: boolean = true;
  @StorageLink('longPressMs') longPressMs: number = 700;
  @StorageLink('scrollInvert') scrollInvert: boolean = false;
  @StorageLink('tpLongPressMs') tpLongPressMs: number = 700;
  @StorageLink('tpScrollInvert') tpScrollInvert: boolean = false;
  @StorageLink('immersiveMode') immersiveMode: boolean = false;
  @StorageLink('escOnSwipe') escOnSwipe: boolean = false;
  @State sensLive: number = -1;
  @State bitrateLive: number = -1;
  @StorageLink('resPreset') resPreset: string = '';
  @StorageLink('nativeScale') nativeScale: number = 100;
  @StorageLink('lightIcon') lightIcon: boolean = true;
  @StorageLink('confirmLaunch') confirmLaunch: boolean = true;
  private nativeDialog: CustomDialogController | undefined = undefined;
  @State nativeW: number = 0;
  @State nativeH: number = 0;
  @StorageLink('devMode') devMode: boolean = false;
  @StorageLink('diagLogging') diagLogging: boolean = false;
  private devTapCount: number = 0;
  private devTapLastMs: number = 0;
  @StorageLink('gamepadDeadzone') gamepadDeadzone: number = 7;
  @StorageLink('gamepadFlipFace') gamepadFlipFace: boolean = false;
  @StorageLink('enableSops') enableSops: boolean = true;
  @StorageLink('hostAudio') hostAudio: boolean = false;
  @State pickerKind: string = '';
  @State pickerTitle: string = '';
  @State pickerOptions: string[] = [];
  private bridge: MoonBridgeService = MoonBridgeService.get();
  private pickerDialog: CustomDialogController | undefined = undefined;
  private sensitivityDialog: CustomDialogController | undefined = undefined;

  private showTouchpadHelp(): void {
    AlertDialog.show({
      title: '触控板模式',
      message: '开启后，屏幕变成一块触控板：\n\n' +
        '• 单指拖动：移动鼠标\n' +
        '• 单指轻点：左键单击\n' +
        '• 长按不放：在鼠标当前位置触发右键\n' +
        '• 双指上下滑动：滚轮滚动（方向可在下方调整）\n' +
        '• 三指轻点：显示或隐藏串流控制栏\n\n' +
        '灵敏度可在下方滑条中调整。',
      confirm: { value: '我知道了', action: () => {} }
    });
  }

  private openSensitivityDialog(): void {
    this.sensitivityDialog = new CustomDialogController({
      builder: SensitivityDialog({
        initialLevel: this.touchpadSensitivity,
        onSave: (level: number) => {
          this.touchpadSensitivity = level;
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.sensitivityDialog.open();
  }

  private ratioText(level: number): string {
    const ratios: string[] = ['0.50', '0.75', '1.00', '1.50', '2.00'];
    const l: number = level < 0 ? 0 : (level > 4 ? 4 : level);
    return '×' + ratios[l];
  }

  private liveSensitivityText(): string {
    if (this.sensLive >= 0) {
      return this.ratioText(Math.round(this.sensLive));
    }
    return this.ratioText(this.touchpadSensitivity);
  }

  private sensitivityText(): string {
    const sens: number[] = [0.5, 0.75, 1.0, 1.5, 2.0];
    const l: number = this.touchpadSensitivity < 0 ? 0 : (this.touchpadSensitivity > 4 ? 4 : this.touchpadSensitivity);
    return '×' + sens[l].toString();
  }

  aboutToAppear(): void {
    try {
      const d = display.getDefaultDisplaySync();
      this.nativeW = d.width - (d.width % 2);
      this.nativeH = d.height - (d.height % 2);
    } catch (error) {
      this.nativeW = 0;
      this.nativeH = 0;
    }
    bundleManager.setAlternateIcon(this.lightIcon ? 'light' : 'dark').catch(() => {});
    if (this.resPreset.length === 0) {
      if (this.streamWidth === 1280) { this.resPreset = '720'; }
      else if (this.streamWidth === 1920) { this.resPreset = '1080'; }
      else if (this.streamWidth === 2560) { this.resPreset = '1440'; }
      else if (this.streamWidth === 3840) { this.resPreset = '4k'; }
      else if (this.nativeW > 0 && this.streamWidth === this.nativeW) { this.resPreset = 'native'; }
    }
  }

  private applyNativeScale(scale: number): void {
    this.nativeScale = scale;
    const factor: number = scale === 25 ? 0.5 : (scale === 50 ? 0.7071 : 1.0);
    let w: number = Math.round(this.nativeW * factor);
    let h: number = Math.round(this.nativeH * factor);
    w = w - (w % 2);
    h = h - (h % 2);
    this.resPreset = 'native';
    this.setResolution(w, h);
  }

  private onNativeTap(): void {
    if (this.nativeW <= 0) {
      return;
    }
    if (this.resPreset === 'native') {
      this.nativeDialog = new CustomDialogController({
        builder: NativeScaleDialog({
          nativeText: '设备原生 ' + this.nativeW.toString() + 'x' + this.nativeH.toString(),
          currentScale: this.nativeScale,
          onPick: (scale: number) => {
            this.applyNativeScale(scale);
          }
        }),
        autoCancel: true,
        customStyle: true,
        alignment: DialogAlignment.Center
      });
      this.nativeDialog.open();
    } else {
      this.applyNativeScale(this.nativeScale);
    }
  }

  private nativeEffectiveText(): string {
    const factor: string = this.nativeScale === 25 ? '1/4' : (this.nativeScale === 50 ? '1/2' : '100%');
    return '原生分辨率：' + this.nativeW.toString() + 'x' + this.nativeH.toString() +
      '（当前 ' + factor + ' 像素，再次点击可调整）';
  }

  private setResolution(width: number, height: number): void {
    this.streamWidth = width;
    this.streamHeight = height;
  }

  @Builder
  sectionTitle(title: string) {
    Text(title)
      .fontSize(15)
      .fontColor($r('app.color.app_primary'))
      .width('100%')
      .margin({ top: 8 })
  }

  openPicker(kind: string): void {
    this.pickerKind = kind;
    if (kind === 'res') {
      this.pickerTitle = '视频分辨率';
      this.pickerOptions = this.nativeW > 0 ?
        [this.nativeW.toString() + 'x' + this.nativeH.toString(), '1280x720', '1920x1080', '2560x1440', '3840x2160'] :
        ['1280x720', '1920x1080', '2560x1440', '3840x2160'];
    } else if (kind === 'fps') {
      this.pickerTitle = '视频帧数';
      this.pickerOptions = ['30', '60', '90', '120', '144'];
    } else if (kind === 'codec') {
      this.pickerTitle = '视频编码';
      this.pickerOptions = ['自动', 'H.264', 'HEVC'];
    } else if (kind === 'bitrate') {
      this.pickerTitle = '视频码率 (kbps)';
      this.pickerOptions = ['10000', '20000', '30000', '50000', '75000', '100000', '150000'];
    } else if (kind === 'audio') {
      this.pickerTitle = '音频配置';
      this.pickerOptions = ['立体声', '5.1 环绕声', '7.1 环绕声'];
    }
    this.showPickerDialog();
  }

  private showPickerDialog(): void {
    this.pickerDialog = new CustomDialogController({
      builder: PickerDialog({
        dialogTitle: this.pickerTitle,
        dialogOptions: this.pickerOptions,
        onPick: (value: string) => {
          this.selectPicker(value);
        }
      }),
      autoCancel: true,
      customStyle: true,
      alignment: DialogAlignment.Center
    });
    this.pickerDialog.open();
  }

  selectPicker(option: string): void {
    if (this.pickerKind === 'res') {
      const parts: string[] = option.split('x');
      this.setResolution(Number.parseInt(parts[0]), Number.parseInt(parts[1]));
    } else if (this.pickerKind === 'fps') {
      this.streamFps = Number.parseInt(option);
    } else if (this.pickerKind === 'codec') {
      this.videoCodec = option === 'H.264' ? 1 : (option === 'HEVC' ? 2 : 0);
    } else if (this.pickerKind === 'bitrate') {
      this.streamBitrate = Number.parseInt(option);
    } else if (this.pickerKind === 'audio') {
      this.audioConfig = option === '5.1 环绕声' ? 0x3F06CA :
        (option === '7.1 环绕声' ? 0x63F08CA : 0x302CA);
    }
    this.pickerKind = '';
  }

  pageTransition() {
    PageTransitionEnter({ duration: 0, curve: Curve.Linear })
    PageTransitionExit({ duration: 0, curve: Curve.Linear })
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
        Text('设置').fontSize(20).fontColor($r('app.color.app_text')).layoutWeight(1)
      }
      .width('100%')
      .height(65)

      Scroll() {
        Column({ space: 14 }) {
          this.sectionTitle('视频')
          Row() {
            Text('官方二级弹窗样式').fontSize(14).fontColor($r('app.color.app_text')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.settingsDialogMode })
              .onChange((isOn: boolean) => {
                this.settingsDialogMode = isOn;
              })
          }
          .width('100%')

          Row() {
            Text('强制虚拟显示器（Apollo）').fontSize(14).fontColor($r('app.color.app_text')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.useVirtualDisplay })
              .onChange((isOn: boolean) => {
                this.useVirtualDisplay = isOn;
              })
          }
          .width('100%')

          if (this.settingsDialogMode) {
            Column() {
              Row() {
                Text('视频分辨率').fontSize(15).fontColor($r('app.color.app_text')).layoutWeight(1)
                Text(this.streamWidth.toString() + 'x' + this.streamHeight.toString())
                  .fontSize(14).fontColor($r('app.color.app_text_dim')).margin({ right: 8 })
                Text('>').fontSize(16).fontColor($r('app.color.app_text_dim'))
              }
              .width('100%')
              .height(52)
              .onClick(() => {
                this.openPicker('res');
              })
              Divider().color($r('app.color.app_divider'))
              Row() {
                Text('视频帧数').fontSize(15).fontColor($r('app.color.app_text')).layoutWeight(1)
                Text(this.streamFps.toString()).fontSize(14).fontColor($r('app.color.app_text_dim')).margin({ right: 8 })
                Text('>').fontSize(16).fontColor($r('app.color.app_text_dim'))
              }
              .width('100%')
              .height(52)
              .onClick(() => {
                this.openPicker('fps');
              })
              Divider().color($r('app.color.app_divider'))
              Row() {
                Text('视频编码').fontSize(15).fontColor($r('app.color.app_text')).layoutWeight(1)
                Text(this.videoCodec === 1 ? 'H.264' : (this.videoCodec === 2 ? 'HEVC' : '自动'))
                  .fontSize(14).fontColor($r('app.color.app_text_dim')).margin({ right: 8 })
                Text('>').fontSize(16).fontColor($r('app.color.app_text_dim'))
              }
              .width('100%')
              .height(52)
              .onClick(() => {
                this.openPicker('codec');
              })
              Divider().color($r('app.color.app_divider'))
              Row() {
                Text('视频码率').fontSize(15).fontColor($r('app.color.app_text')).layoutWeight(1)
                Text(this.streamBitrate.toString() + ' kbps').fontSize(14).fontColor($r('app.color.app_text_dim')).margin({ right: 8 })
                Text('>').fontSize(16).fontColor($r('app.color.app_text_dim'))
              }
              .width('100%')
              .height(52)
              .onClick(() => {
                this.openPicker('bitrate');
              })
            }
            .width('100%')
          } else {
          Text('分辨率').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
          Row({ space: 8 }) {
            Button('720p').layoutWeight(1).backgroundColor(this.resPreset === '720' ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.resPreset = '720';
              this.setResolution(1280, 720);
            })
            Button('1080p').layoutWeight(1).backgroundColor(this.resPreset === '1080' ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.resPreset = '1080';
              this.setResolution(1920, 1080);
            })
            Button('1440p').layoutWeight(1).backgroundColor(this.resPreset === '1440' ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.resPreset = '1440';
              this.setResolution(2560, 1440);
            })
            Button('4K').layoutWeight(1).backgroundColor(this.resPreset === '4k' ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.resPreset = '4k';
              this.setResolution(3840, 2160);
            })
            Button('原生(' + (this.nativeScale === 25 ? '25%' : (this.nativeScale === 50 ? '50%' : '100%')) + ')')
              .layoutWeight(1)
              .backgroundColor(this.resPreset === 'native' ? $r('app.color.app_primary') : $r('app.color.app_button_bg'))
              .onClick(() => {
                this.onNativeTap();
              })
          }
          .width('100%')
          Text('当前分辨率：' + this.streamWidth.toString() + '×' + this.streamHeight.toString() +
            (this.resPreset === 'native' ? ('（原生屏 ' + this.nativeW.toString() + '×' + this.nativeH.toString() + '，点击原生可调整比例）') : ''))
            .fontSize(11).fontColor($r('app.color.app_text_dim')).width('100%')

          Text('帧率').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
          Row({ space: 8 }) {
            Button('30').layoutWeight(1).backgroundColor(this.streamFps === 30 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.streamFps = 30;
            })
            Button('60').layoutWeight(1).backgroundColor(this.streamFps === 60 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.streamFps = 60;
            })
            Button('90').layoutWeight(1).backgroundColor(this.streamFps === 90 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.streamFps = 90;
            })
            Button('120').layoutWeight(1).backgroundColor(this.streamFps === 120 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.streamFps = 120;
            })
            Button('144').layoutWeight(1).backgroundColor(this.streamFps === 144 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.streamFps = 144;
            })
          }
          .width('100%')
          Row() {
            Text('拉伸画面铺满屏幕').fontSize(14).fontColor($r('app.color.app_text')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.stretchVideo })
              .onChange((isOn: boolean) => {
                this.stretchVideo = isOn;
              })
          }
          .width('100%')
          Row() {
            Text('全范围色彩（Full Range）').fontSize(14).fontColor($r('app.color.app_text')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.fullRange })
              .onChange((isOn: boolean) => {
                this.fullRange = isOn;
              })
          }
          .width('100%')

          Text('视频编码').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
          Row({ space: 8 }) {
            Button('自动').layoutWeight(1).backgroundColor(this.videoCodec === 0 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.videoCodec = 0;
            })
            Button('H.264').layoutWeight(1).backgroundColor(this.videoCodec === 1 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.videoCodec = 1;
            })
            Button('HEVC').layoutWeight(1).backgroundColor(this.videoCodec === 2 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.videoCodec = 2;
            })
          }
          .width('100%')

          Text('码率：' + (this.bitrateLive >= 0 ? this.bitrateLive : this.streamBitrate).toString() + ' kbps')
            .fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
          SnapSlider({
            value: this.streamBitrate,
            min: 5000,
            max: 150000,
            step: 5000,
            onChanged: (v: number) => {
              this.streamBitrate = v;
            },
            onLive: (v: number) => {
              this.bitrateLive = v;
            }
          })
            .width('100%')

          }

          this.sectionTitle('网络')
          Row() {
            Column({ space: 2 }) {
              Text('码率过高提醒').fontSize(15).fontColor($r('app.color.app_text'))
              Text('检测到持续丢包时提示降低码率（不自动改动，需重新连接生效）')
                .fontSize(11).fontColor($r('app.color.app_text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.adaptiveBitrate })
              .onChange((isOn: boolean) => {
                this.adaptiveBitrate = isOn;
              })
          }
          .width('100%')
          Text(this.adaptiveBitrate ? '当前：丢包提醒已开启' : '当前：仅按上方码率设置')
            .fontSize(12).fontColor(this.adaptiveBitrate ? $r('app.color.app_primary') : $r('app.color.app_text_dim'))
            .width('100%')

          this.sectionTitle('音频')
          Text('音频配置').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
          Row({ space: 8 }) {
            Button('立体声').layoutWeight(1).backgroundColor(this.audioConfig === 0x302CA ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.audioConfig = 0x302CA;
            })
            Button('5.1').layoutWeight(1).backgroundColor(this.audioConfig === 0x3F06CA ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.audioConfig = 0x3F06CA;
            })
            Button('7.1').layoutWeight(1).backgroundColor(this.audioConfig === 0x63F08CA ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.audioConfig = 0x63F08CA;
            })
          }
          .width('100%')

          this.sectionTitle('手柄')
          Row() {
            Column({ space: 2 }) {
              Text('启用手柄（实验性）').fontSize(15).fontColor($r('app.color.app_text'))
              Text('仅支持实体按键；摇杆和线性扳机不可用').fontSize(11).fontColor($r('app.color.app_text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text('?')
              .fontSize(13)
              .fontColor($r('app.color.app_text_dim'))
              .backgroundColor('#00000000')
              .border({ width: 1.2, color: '#888888' })
              .width(22)
              .height(22)
              .borderRadius(11)
              .textAlign(TextAlign.Center)
              .margin({ right: 8 })
              .onClick(() => {
                AlertDialog.show({
                  title: '手柄支持说明',
                  message: '当前为实验性功能，默认关闭。\n\n' +
                    '受 HarmonyOS 限制，手柄只能以实体按键形式上报：\n' +
                    '• 支持：A/B/X/Y、十字键、LB/RB、L3/R3、Start/Back/Guide\n' +
                    '• PS 模式下扳机以数字量上报（2309/2310），可用\n' +
                    '• 不支持：左右摇杆、Xbox 模式的线性扳机（系统不上报轴事件）\n\n' +
                    '请在下方选择手柄模式（Xbox / PlayStation）。',
                  confirm: { value: '我知道了', action: () => {} }
                });
              })
            Toggle({ type: ToggleType.Switch, isOn: this.gamepadEnabled })
              .onChange((isOn: boolean) => {
                animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
                  this.gamepadEnabled = isOn;
                });
              })
          }
          .width('100%')
          if (this.gamepadEnabled) {
          Column({ space: 8 }) {
          Text('手柄模式').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
          Row({ space: 8 }) {
            Button('Xbox').layoutWeight(1).backgroundColor(this.gamepadMode === 0 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.gamepadMode = 0;
            })
            Button('PlayStation').layoutWeight(1).backgroundColor(this.gamepadMode === 1 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
              this.gamepadMode = 1;
            })
          }
          .width('100%')
          Text('摇杆死区：' + this.gamepadDeadzone.toString() + '%（当前版本无摇杆，保留设置）').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
          Slider({
            value: this.gamepadDeadzone,
            min: 0,
            max: 20,
            step: 1,
            style: SliderStyle.OutSet
          })
            .width('100%')
            .onChange((value: number) => {
              this.gamepadDeadzone = Math.round(value);
            })
          Row() {
            Text('交换 AB / XY 键位').fontSize(14).fontColor($r('app.color.app_text')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.gamepadFlipFace })
              .onChange((isOn: boolean) => {
                this.gamepadFlipFace = isOn;
              })
          }
          .width('100%')
          }
          .width('100%')
          .alignItems(HorizontalAlign.Start)
          .transition(TransitionEffect.OPACITY.combine(
            TransitionEffect.translate({ y: -12 })))
          }

          this.sectionTitle('输入')
          Row() {
            Column({ space: 2 }) {
              Text('拟人化鼠标操作').fontSize(15).fontColor($r('app.color.app_text'))
              Text('双击容错 · 长按右键 · 三指轻点呼出控制栏').fontSize(11).fontColor($r('app.color.app_text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text('?')
              .fontSize(13)
              .fontColor($r('app.color.app_text_dim'))
              .backgroundColor('#00000000')
              .border({ width: 1.2, color: '#888888' })
              .width(22)
              .height(22)
              .borderRadius(11)
              .textAlign(TextAlign.Center)
              .margin({ right: 8 })
              .onClick(() => {
                AlertDialog.show({
                  title: '拟人化鼠标操作',
                  message: '为手指操作优化的鼠标辅助，默认开启：\n\n' +
                    '1. 双击容错：两次轻点落点相近（14vp 以内）时，自动回到第一下位置完成双击。\n\n' +
                    '2. 长按右键：手指按住设定时长不动，松开后触发右键菜单。\n\n' +
                    '3. 双指上下滑动：滚轮滚动，方向可在下方切换正/反向。\n\n' +
                    '4. 三指轻点：显示或隐藏串流控制栏。\n\n' +
                    '关闭后将恢复严格单击与长按呼出控制栏的旧行为。',
                  confirm: { value: '我知道了', action: () => {} }
                });
              })
            Toggle({ type: ToggleType.Switch, isOn: this.smartMouse })
              .onChange((isOn: boolean) => {
                animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
                  this.smartMouse = isOn;
                  if (isOn) {
                    this.touchpadMode = false;
                  }
                });
              })
          }
          .width('100%')
          if (this.smartMouse) {
            Column({ space: 6 }) {
              Text('长按右键时长').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
              Row({ space: 8 }) {
                Button('0.5 秒').layoutWeight(1).backgroundColor(this.longPressMs === 500 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.longPressMs = 500;
                })
                Button('0.7 秒').layoutWeight(1).backgroundColor(this.longPressMs === 700 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.longPressMs = 700;
                })
                Button('1.0 秒').layoutWeight(1).backgroundColor(this.longPressMs === 1000 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.longPressMs = 1000;
                })
              }
              .width('100%')
              Text('滚轮方向').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
              Row({ space: 8 }) {
                Button('正向（默认）').layoutWeight(1).backgroundColor(!this.scrollInvert ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.scrollInvert = false;
                })
                Button('反向').layoutWeight(1).backgroundColor(this.scrollInvert ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.scrollInvert = true;
                })
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .transition(TransitionEffect.OPACITY.combine(
              TransitionEffect.translate({ y: -10 })))
          }
          Row() {
            Column({ space: 2 }) {
              Text('将触控屏作为触控板使用').fontSize(15).fontColor($r('app.color.app_text'))
              Text('单指拖动移动鼠标、轻点左键；双指滑动滚动、轻点右键').fontSize(11).fontColor($r('app.color.app_text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            .onClick(() => {
              this.showTouchpadHelp();
            })
            Text('?')
              .fontSize(13)
              .fontColor($r('app.color.app_text_dim'))
              .backgroundColor('#00000000')
              .border({ width: 1.2, color: '#888888' })
              .width(22)
              .height(22)
              .borderRadius(11)
              .textAlign(TextAlign.Center)
              .margin({ right: 8 })
              .onClick(() => {
                this.showTouchpadHelp();
              })
            Toggle({ type: ToggleType.Switch, isOn: this.touchpadMode })
              .onChange((isOn: boolean) => {
                animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
                  this.touchpadMode = isOn;
                  if (isOn) {
                    this.smartMouse = false;
                  }
                });
              })
          }
          .width('100%')
          Text(this.touchpadMode ? ('当前：触控板模式（相对移动）· 灵敏度 ' + this.sensitivityText()) : (this.smartMouse ? '当前：直接触摸（绝对定位）' : '当前：触摸输入已关闭'))
            .fontSize(12).fontColor(this.touchpadMode ? $r('app.color.app_primary') : $r('app.color.app_text_dim'))
            .width('100%')
          if (this.touchpadMode) {
            Column({ space: 6 }) {
              Text('触控板灵敏度：' + this.liveSensitivityText()).fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
              SnapSlider({
                value: this.touchpadSensitivity,
                min: 0,
                max: 4,
                step: 1,
                onChanged: (v: number) => {
                  this.touchpadSensitivity = Math.round(v);
                },
                onLive: (v: number) => {
                  this.sensLive = v;
                }
              })
                .width('100%')
              Text('长按右键时长').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
              Row({ space: 8 }) {
                Button('0.5 秒').layoutWeight(1).backgroundColor(this.tpLongPressMs === 500 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.tpLongPressMs = 500;
                })
                Button('0.7 秒').layoutWeight(1).backgroundColor(this.tpLongPressMs === 700 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.tpLongPressMs = 700;
                })
                Button('1.0 秒').layoutWeight(1).backgroundColor(this.tpLongPressMs === 1000 ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.tpLongPressMs = 1000;
                })
              }
              .width('100%')
              Text('滚轮方向').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
              Row({ space: 8 }) {
                Button('正向').layoutWeight(1).backgroundColor(!this.tpScrollInvert ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.tpScrollInvert = false;
                })
                Button('反向').layoutWeight(1).backgroundColor(this.tpScrollInvert ? $r('app.color.app_primary') : $r('app.color.app_button_bg')).onClick(() => {
                  this.tpScrollInvert = true;
                })
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .transition(TransitionEffect.OPACITY.combine(
              TransitionEffect.translate({ y: -10 })))
          }

          this.sectionTitle('主机')
          Row() {
            Column({ space: 2 }) {
              Text('启动应用前确认').fontSize(15).fontColor($r('app.color.app_text'))
              Text('没有应用运行时，点应用会先弹出确认窗口，避免误触').fontSize(11).fontColor($r('app.color.app_text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.confirmLaunch })
              .onChange((isOn: boolean) => {
                this.confirmLaunch = isOn;
              })
          }
          .width('100%')
          Row() {
            Column({ space: 2 }) {
              Text('优化游戏设置').fontSize(15).fontColor($r('app.color.app_text'))
              Text('允许 GFE/Apollo 为最佳串流效果自动更改游戏设置').fontSize(11).fontColor($r('app.color.app_text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.enableSops })
              .onChange((isOn: boolean) => {
                this.enableSops = isOn;
              })
          }
          .width('100%')
          Row() {
            Column({ space: 2 }) {
              Text('主机端播放音频').fontSize(15).fontColor($r('app.color.app_text'))
              Text('声音同时从主机音箱和本机输出').fontSize(11).fontColor($r('app.color.app_text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.hostAudio })
              .onChange((isOn: boolean) => {
                this.hostAudio = isOn;
              })
          }
          .width('100%')

          this.sectionTitle('界面')
          Row() {
            Column({ space: 2 }) {
              Text('浅色主题（亮面）').fontSize(15).fontColor($r('app.color.app_text'))
              Text('应用整体切换为浅色配色').fontSize(11).fontColor($r('app.color.app_text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Text('?')
              .fontSize(13)
              .fontColor('#BBBBBB')
              .border({ width: 1.2, color: '#888888' })
              .width(22)
              .height(22)
              .borderRadius(11)
              .textAlign(TextAlign.Center)
              .margin({ right: 8 })
              .onClick(() => {
                AlertDialog.show({
                  title: '关于启动闪屏',
                  message: '启动瞬间的闪屏颜色由系统的深浅色模式决定。\n\n' +
                    '此时应用进程尚未启动，本应用的深浅色开关无法影响那一帧。\n\n' +
                    '如果希望启动闪屏与主题一致，请把系统的深色/浅色模式也设置为相同模式。',
                  confirm: { value: '我知道了', action: () => {} }
                });
              })
            Toggle({ type: ToggleType.Switch, isOn: this.lightTheme })
              .onChange((isOn: boolean) => {
                this.lightTheme = isOn;
                this.lightIcon = isOn;
                try {
                  const f = fs.openSync(getContext(this).filesDir + '/theme_light',
                    fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
                  const b = new ArrayBuffer(1);
                  new Uint8Array(b)[0] = isOn ? 1 : 0;
                  fs.writeSync(f.fd, b);
                  fs.closeSync(f);
                } catch (error) {
                }
                try {
                  (getContext(this) as common.UIAbilityContext).getApplicationContext().setColorMode(
                    isOn ? ConfigurationConstant.ColorMode.COLOR_MODE_LIGHT
                      : ConfigurationConstant.ColorMode.COLOR_MODE_DARK);
                } catch (error) {
                }
                bundleManager.setAlternateIcon(isOn ? 'light' : 'dark').catch(() => {});
                const bg: string = isOn ? '#F5F7FA' : '#000000';
                const fg: string = isOn ? '#000000' : '#FFFFFF';
                window.getLastWindow(getContext(this)).then((win: window.Window) => {
                  win.setWindowBackgroundColor(bg);
                  win.setSystemBarProperties({
                    statusBarColor: bg,
                    navigationBarColor: bg,
                    statusBarContentColor: fg,
                    navigationBarContentColor: fg
                  }).catch(() => {});
                }).catch(() => {});
              })
          }
          .width('100%')

          Row() {
            Column({ space: 2 }) {
              Text('沉浸式防误退').fontSize(15).fontColor($r('app.color.app_text'))
              Text('开启后左右侧滑返回不会退出串流').fontSize(11).fontColor($r('app.color.app_text_dim'))
            }
            .layoutWeight(1)
            .alignItems(HorizontalAlign.Start)
            Toggle({ type: ToggleType.Switch, isOn: this.immersiveMode })
              .onChange((isOn: boolean) => {
                animateTo({ duration: 260, curve: Curve.EaseInOut }, () => {
                  this.immersiveMode = isOn;
                });
                if (isOn) {
                  AlertDialog.show({
                    title: '如何退出串流',
                    message: '已开启沉浸式防误退：左右侧滑不会再退出串流。\n\n' +
                      '如需退出，请用三根手指轻点屏幕，左上角会出现「退出串流」按钮。\n\n' +
                      '（部分游戏可在下方开启“侧滑时发送 ESC”模拟返回）',
                    confirm: { value: '我知道了', action: () => {} }
                  });
                }
              })
          }
          .width('100%')
          if (this.immersiveMode) {
            Column({ space: 6 }) {
              Row() {
                Column({ space: 2 }) {
                  Text('侧滑时发送 ESC').fontSize(14).fontColor($r('app.color.app_text'))
                  Text('模拟部分游戏中的返回效果').fontSize(11).fontColor($r('app.color.app_text_dim'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Toggle({ type: ToggleType.Switch, isOn: this.escOnSwipe })
                  .onChange((isOn: boolean) => {
                    this.escOnSwipe = isOn;
                  })
              }
              .width('100%')
            }
            .width('100%')
            .alignItems(HorizontalAlign.Start)
            .transition(TransitionEffect.OPACITY.combine(
              TransitionEffect.translate({ y: -10 })))
          }
          Row() {
            Text('显示性能信息（FPS / RTT）').fontSize(14).fontColor($r('app.color.app_text')).layoutWeight(1)
            Toggle({ type: ToggleType.Switch, isOn: this.showPerf })
              .onChange((isOn: boolean) => {
                this.showPerf = isOn;
              })
          }
          .width('100%')

          this.sectionTitle('关于')
          Text('Moonlight HarmonyOS 移植版')
            .fontSize(14)
            .fontColor($r('app.color.app_text'))
            .width('100%')
            .onClick(() => {
              const now: number = Date.now();
              if (now - this.devTapLastMs > 1500) {
                this.devTapCount = 0;
              }
              this.devTapLastMs = now;
              this.devTapCount++;
              if (this.devTapCount >= 5) {
                this.devTapCount = 0;
                this.devMode = true;
                promptAction.showToast({ message: '开发者模式已开启' });
              }
            })
          Text(this.bridge.getVersion()).fontSize(12).fontColor($r('app.color.app_text_dim')).width('100%')
          Text(this.bridge.getBuildInfo()).fontSize(11).fontColor($r('app.color.app_text_dim')).width('100%')
          Text('基于 Moonlight 开源项目（GPLv3）修改的 HarmonyOS 串流客户端，非官方版本。')
            .fontSize(11).fontColor($r('app.color.app_text_dim')).width('100%').margin({ top: 4 })
          Text('源码：https://github.com/Entai23')
            .fontSize(11).fontColor($r('app.color.app_primary')).width('100%')
            .copyOption(CopyOptions.LocalDevice)
          Text('本应用整体按 GNU GPLv3 授权发布，修改部分同样开源。')
            .fontSize(11).fontColor($r('app.color.app_text_dim')).width('100%')
          if (this.devMode) {
            Column({ space: 8 }) {
              Divider().color($r('app.color.app_divider'))
              Row() {
                Column({ space: 2 }) {
                  Text('记录诊断日志').fontSize(15).fontColor($r('app.color.app_text'))
                  Text('写入 JSONL 诊断文件，排查问题用').fontSize(11).fontColor($r('app.color.app_text_dim'))
                }
                .layoutWeight(1)
                .alignItems(HorizontalAlign.Start)
                Toggle({ type: ToggleType.Switch, isOn: this.diagLogging })
                  .onChange((isOn: boolean) => {
                    this.diagLogging = isOn;
                    this.bridge.setDiagEnabled(isOn && this.devMode);
                  })
              }
              .width('100%')
              Text('诊断日志：' + this.bridge.getLogPath())
                .fontSize(11)
                .fontColor($r('app.color.app_text_dim'))
                .copyOption(CopyOptions.LocalDevice)
                .width('100%')
              Button('关闭开发者模式')
                .width('100%')
                .height(42)
                .backgroundColor($r('app.color.app_button_bg'))
                .fontColor($r('app.color.dialog_text'))
                .onClick(() => {
                  this.devMode = false;
                  this.diagLogging = false;
                  this.bridge.setDiagEnabled(false);
                  promptAction.showToast({ message: '开发者模式已关闭，日志已停止写入' });
                })
            }
            .width('100%')
            .transition(TransitionEffect.OPACITY.combine(
              TransitionEffect.translate({ y: -10 })))
          }
        }
        .width('100%')
        .padding(20)
      }
      .layoutWeight(1)
      .width('100%')
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
