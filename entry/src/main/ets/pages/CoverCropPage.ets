import { router } from '@kit.ArkUI';
import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import { AppTheme } from '../common/AppTheme';
import { promptAction } from '@kit.ArkUI';
import { MoonBridgeService } from '../services/MoonBridgeService';

class CoverCropParams {
  address: string = '';
  appId: number = 0;
  uri: string = '';
}

@Entry
@Component
struct CoverCropPage {
  @State lightTheme: boolean = false;
  @State zoom: number = 1.0;
  @State panX: number = 0;
  @State panY: number = 0;
  @State ready: boolean = false;
  private srcW: number = 0;
  private srcH: number = 0;
  private baseW: number = 0;
  private baseH: number = 0;
  private pixelMap: image.PixelMap | undefined = undefined;
  private source: image.ImageSource | undefined = undefined;
  private address: string = '';
  private appId: number = 0;
  private readonly frameW: number = 300;
  private readonly frameH: number = 400;
  private bridge: MoonBridgeService = MoonBridgeService.get();
  private panStartX: number = 0;
  private panStartY: number = 0;
  private pinchStart: number = 1;

  aboutToAppear(): void {
    const p = router.getParams() as CoverCropParams;
    if (p !== undefined) {
      this.address = p.address;
      this.appId = p.appId;
      this.load(p.uri);
    }
  }

  private load(uri: string): void {
    this.bridge.logUi('crop load uri=' + uri);
    try {
      const file = fs.openSync(uri, fs.OpenMode.READ_ONLY);
      const stat = fs.statSync(file.fd);
      const buf: ArrayBuffer = new ArrayBuffer(stat.size);
      fs.readSync(file.fd, buf);
      fs.closeSync(file);
      this.source = image.createImageSource(buf);
      this.source.createPixelMap().then((pm: image.PixelMap) => {
        pm.getImageInfo().then((info: image.ImageInfo) => {
          this.srcW = info.size.width;
          this.srcH = info.size.height;
          const fit: number = Math.min(this.frameW / this.srcW, this.frameH / this.srcH);
          this.baseW = this.srcW * fit;
          this.baseH = this.srcH * fit;
          this.bridge.logUi('crop src=' + this.srcW.toString() + 'x' + this.srcH.toString() +
            ' base=' + this.baseW.toFixed(1) + 'x' + this.baseH.toFixed(1));
          this.pixelMap = pm;
          this.ready = true;
        });
      });
    } catch (error) {
      this.bridge.logUi('crop load failed: ' + JSON.stringify(error));
      promptAction.showToast({ message: '无法读取所选图片' });
    }
  }

  private clampPan(): void {
    const w: number = this.baseW * this.zoom;
    const h: number = this.baseH * this.zoom;
    const maxX: number = Math.max(0, (w - this.frameW) / 2);
    const maxY: number = Math.max(0, (h - this.frameH) / 2);
    if (this.panX > maxX) { this.panX = maxX; }
    if (this.panX < -maxX) { this.panX = -maxX; }
    if (this.panY > maxY) { this.panY = maxY; }
    if (this.panY < -maxY) { this.panY = -maxY; }
  }

  private async save(): Promise<void> {
    if (this.source === undefined) {
      this.bridge.logUi('crop save aborted: no image source');
      router.back();
      return;
    }
    try {
      const totalScale: number = (this.baseW / this.srcW) * this.zoom;
      let cropW: number = this.frameW / totalScale;
      let cropH: number = this.frameH / totalScale;
      let x: number = (this.srcW - cropW) / 2 - this.panX / totalScale;
      let y: number = (this.srcH - cropH) / 2 - this.panY / totalScale;
      if (x < 0) { x = 0; }
      if (y < 0) { y = 0; }
      if (x + cropW > this.srcW) { x = this.srcW - cropW; }
      if (y + cropH > this.srcH) { y = this.srcH - cropH; }
      this.bridge.logUi('crop save region x=' + x.toFixed(1) + ' y=' + y.toFixed(1) +
        ' w=' + cropW.toFixed(1) + ' h=' + cropH.toFixed(1) +
        ' zoom=' + this.zoom.toFixed(3) + ' pan=' + this.panX.toFixed(1) + ',' + this.panY.toFixed(1));
      if (this.pixelMap === undefined) {
        throw new Error('no pixelmap');
      }
      const pm: image.PixelMap = this.pixelMap;
      await pm.crop({
        x: Math.round(x),
        y: Math.round(y),
        size: { width: Math.round(cropW), height: Math.round(cropH) }
      });
      const croppedInfo: image.ImageInfo = pm.getImageInfoSync();
      await pm.scale(450 / croppedInfo.size.width, 600 / croppedInfo.size.height);
      const packer: image.ImagePacker = image.createImagePacker();
      const jpeg: ArrayBuffer = await packer.packing(pm, { format: 'image/jpeg', quality: 92 });
      const dir: string = getContext(this).filesDir + '/covers';
      try {
        if (!fs.accessSync(dir)) {
          fs.mkdirSync(dir);
        }
      } catch (error) {
      }
      const path: string = dir + '/' + this.address + '_' + this.appId.toString() + '.jpg';
      const out = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
      fs.writeSync(out.fd, jpeg);
      fs.closeSync(out);
      this.bridge.logUi('crop saved file=' + path + ' bytes=' + jpeg.byteLength.toString());
      promptAction.showToast({ message: '封面已更新' });
      router.back();
    } catch (error) {
      this.bridge.logUi('crop save failed: ' + JSON.stringify(error));
      promptAction.showToast({ message: '保存封面失败' });
    }
  }

  build() {
    Stack() {
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#000000')

      if (this.ready && this.pixelMap !== undefined) {
        Image(this.pixelMap)
          .width(this.baseW * this.zoom)
          .height(this.baseH * this.zoom)
          .offset({ x: this.panX, y: this.panY })
          .draggable(false)
          .interpolation(ImageInterpolation.Medium)
      }

      Column() {
        Column()
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#99000000')
          .hitTestBehavior(HitTestMode.None)
        Row() {
          Column()
            .layoutWeight(1)
            .height('100%')
            .backgroundColor('#99000000')
            .hitTestBehavior(HitTestMode.None)
          Row()
            .width(this.frameW)
            .height(this.frameH)
            .border({ width: 1.5, color: '#FFFFFF' })
            .hitTestBehavior(HitTestMode.None)
          Column()
            .layoutWeight(1)
            .height('100%')
            .backgroundColor('#99000000')
            .hitTestBehavior(HitTestMode.None)
        }
        .width('100%')
        .height(this.frameH)
        .hitTestBehavior(HitTestMode.None)
        Column()
          .width('100%')
          .layoutWeight(1)
          .backgroundColor('#99000000')
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)

      Column() {
        Blank()
        Text('拖动调整位置，双指缩放')
          .fontSize(12)
          .fontColor('#BBBBBB')
          .padding({ bottom: 20 })
          .hitTestBehavior(HitTestMode.None)
      }
      .width('100%')
      .height('100%')
      .hitTestBehavior(HitTestMode.None)
      Column()
        .width('100%')
        .height('100%')
        .backgroundColor('#00000000')
        .gesture(
          GestureGroup(GestureMode.Parallel,
            PanGesture({ fingers: 1, distance: 1 })
              .onActionStart(() => {
                this.panStartX = this.panX;
                this.panStartY = this.panY;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.panX = this.panStartX + event.offsetX;
                this.panY = this.panStartY + event.offsetY;
                this.clampPan();
              }),
            PinchGesture({ fingers: 2 })
              .onActionStart(() => {
                this.pinchStart = this.zoom;
              })
              .onActionUpdate((event: GestureEvent) => {
                this.zoom = this.pinchStart * event.scale;
                if (this.zoom < 1) { this.zoom = 1; }
                if (this.zoom > 4) { this.zoom = 4; }
                this.clampPan();
              })
          )
        )
        .zIndex(5)

      Row() {
        Text('取消')
          .fontSize(16)
          .fontColor(Color.White)
          .padding(12)
          .onClick(() => {
            router.back();
          })
        Text('裁剪封面')
          .fontSize(18)
          .fontColor(Color.White)
          .layoutWeight(1)
          .textAlign(TextAlign.Center)
        Text('完成')
          .fontSize(16)
          .fontColor('#66CCFF')
          .padding(12)
          .onClick(() => {
            this.save();
          })
      }
      .width('100%')
      .height(56)
      .backgroundColor('#000000')
      .position({ x: 0, y: 0 })
      .zIndex(20)
    }
    .width('100%')
    .height('100%')
    .backgroundColor('#000000')
  }
}
