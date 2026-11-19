import { image } from '@kit.ImageKit';
import { fileIo as fs } from '@kit.CoreFileKit';
import moonbridge from 'libmoonbridge.so';

export class AssetLoader {
  private static cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();
  private static cacheDir: string = '';

  static setCacheDir(dir: string): void {
    AssetLoader.cacheDir = dir;
    try {
      if (!fs.accessSync(dir)) {
        fs.mkdirSync(dir);
      }
    } catch (error) {
    }
  }

  static async load(host: string, appId: number): Promise<image.PixelMap | undefined> {
    const key: string = host + '#' + appId.toString();
    const cached = AssetLoader.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    const path: string = AssetLoader.cacheDir.length > 0
      ? AssetLoader.cacheDir + '/' + key.replace(/[^A-Za-z0-9]/g, '_') + '.img'
      : '';
    if (path.length > 0) {
      try {
        if (fs.accessSync(path)) {
          moonbridge.logUi('asset disk hit ' + appId.toString());
          const stat = fs.statSync(path);
          const buf: ArrayBuffer = new ArrayBuffer(stat.size);
          const file = fs.openSync(path, fs.OpenMode.READ_ONLY);
          fs.readSync(file.fd, buf);
          fs.closeSync(file);
          const source: image.ImageSource = image.createImageSource(buf);
          const pixelMap: image.PixelMap = source.createPixelMapSync();
          AssetLoader.cache.set(key, pixelMap);
          moonbridge.logUi('asset disk decode ok ' + appId.toString());
          return pixelMap;
        }
      } catch (error) {
        moonbridge.logUi('asset disk decode failed ' + appId.toString() + ': ' + JSON.stringify(error));
      }
    }
    try {
      moonbridge.logUi('asset network fetch ' + appId.toString());
      const buffer: ArrayBuffer = await moonbridge.fetchAsset(host, appId);
      const source: image.ImageSource = image.createImageSource(buffer);
      const pixelMap: image.PixelMap = await source.createPixelMap();
      AssetLoader.cache.set(key, pixelMap);
      if (path.length > 0 && buffer.byteLength > 0) {
        try {
          const out = fs.openSync(path, fs.OpenMode.CREATE | fs.OpenMode.WRITE_ONLY | fs.OpenMode.TRUNC);
          fs.writeSync(out.fd, buffer);
          fs.closeSync(out);
        } catch (error) {
        }
      }
      return pixelMap;
    } catch (error) {
      moonbridge.logUi('asset network failed ' + appId.toString() + ': ' + JSON.stringify(error));
      return undefined;
    }
  }
}
