import { image } from '@kit.ImageKit';
import moonbridge from 'libmoonbridge.so';

export class AssetLoader {
  private static cache: Map<string, image.PixelMap> = new Map<string, image.PixelMap>();

  static async load(host: string, appId: number): Promise<image.PixelMap | undefined> {
    const key: string = host + '#' + appId.toString();
    const cached = AssetLoader.cache.get(key);
    if (cached !== undefined) {
      return cached;
    }
    try {
      const buffer: ArrayBuffer = await moonbridge.fetchAsset(host, appId);
      const source: image.ImageSource = image.createImageSource(buffer);
      const pixelMap: image.PixelMap = await source.createPixelMap();
      AssetLoader.cache.set(key, pixelMap);
      return pixelMap;
    } catch (error) {
      return undefined;
    }
  }
}
