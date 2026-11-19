import moonbridge from 'libmoonbridge.so';

export class BridgeEventItem {
  id: number;
  type: string;
  payload: string;
  time: string;

  constructor(id: number, type: string, payload: string) {
    this.id = id;
    this.type = type;
    this.payload = payload;
    const now = new Date();
    this.time = now.toTimeString().substring(0, 8);
  }
}

export interface MoonBridgeHostProbe {
  host: string;
  tcp47984Ms: number;
  tcp47989Ms: number;
  tcp48010Ms: number;
  tlsMs: number;
  httpOk: boolean;
  serverinfo: string;
}

export class MoonBridgeService {
  private static instance: MoonBridgeService | null = null;
  private initialized: boolean = false;
  private logDir: string = '';

  static get(): MoonBridgeService {
    if (MoonBridgeService.instance === null) {
      MoonBridgeService.instance = new MoonBridgeService();
    }
    return MoonBridgeService.instance;
  }

  ensureInit(filesDir: string): void {
    if (this.initialized) {
      return;
    }
    this.logDir = filesDir + '/diag';
    moonbridge.init();
    moonbridge.setLogDir(this.logDir);
    this.initialized = true;
  }

  getLogPath(): string {
    return moonbridge.getLogPath();
  }

  setSurfaceId(surfaceId: string): void {
    moonbridge.setSurfaceId(surfaceId);
  }

  markStreamPaused(paused: boolean): void {
    moonbridge.markStreamPaused(paused ? 1 : 0);
  }

  isStreamPaused(): boolean {
    return moonbridge.isStreamPaused() === 1;
  }

  getVersion(): string {
    return moonbridge.getVersion();
  }

  getBuildInfo(): string {
    return moonbridge.getBuildInfo();
  }

  setEventCallback(callback: (type: string, payload: string) => void): void {
    moonbridge.setEventCallback(callback);
  }

  clearEventCallback(): void {
    moonbridge.clearEventCallback();
  }

  async probeHost(host: string, timeoutMs: number): Promise<string> {
    return moonbridge.probeHost(host, timeoutMs);
  }

  async testConnectivity(host: string, timeoutMs: number): Promise<number> {
    return moonbridge.testConnectivity(host, timeoutMs);
  }

  getStats(): string {
    return moonbridge.getStats();
  }

  getStreamRxBytes(): number {
    return moonbridge.getStreamRxBytes();
  }

  logUi(message: string): void {
    moonbridge.logUi(message);
  }

  setDiagEnabled(on: boolean): void {
    moonbridge.setDiagEnabled(on);
  }

  setVideoRange(full: boolean): void {
    moonbridge.setVideoRange(full ? 1 : 0);
  }

  sendControllerEvent(flags: number, lt: number, rt: number, lx: number, ly: number,
    rx: number, ry: number): void {
    moonbridge.sendControllerEvent(flags, lt, rt, lx, ly, rx, ry);
  }



  emitTestEvent(message: string): void {
    moonbridge.emitTestEvent(message);
  }

  async pairBegin(host: string): Promise<string> {
    return moonbridge.pairBegin(host);
  }

  async pairComplete(host: string, pin: string): Promise<string> {
    return moonbridge.pairComplete(host, pin);
  }

  async getHostInfo(host: string): Promise<string> {
    return moonbridge.getHostInfo(host);
  }

  async getAppList(host: string): Promise<string> {
    return moonbridge.getAppList(host);
  }

  async launchApp(host: string, appId: number, width: number, height: number, fps: number,
    bitrate: number, riKeyHex: string, riKeyId: number, virtualDisplay: boolean,
    audioConfiguration: number, sops: boolean, hostAudio: boolean): Promise<string> {
    return moonbridge.launchApp(host, appId, width, height, fps, bitrate, riKeyHex, riKeyId,
      virtualDisplay ? 1 : 0, audioConfiguration, sops ? 1 : 0, hostAudio ? 1 : 0);
  }

  async quitApp(host: string): Promise<number> {
    return moonbridge.quitApp(host);
  }

  generateRiKey(): string {
    return moonbridge.generateRiKey();
  }

  sendMouseMove(deltaX: number, deltaY: number): void {
    moonbridge.sendMouseMove(deltaX, deltaY);
  }

  sendMousePosition(x: number, y: number, refWidth: number, refHeight: number): void {
    moonbridge.sendMousePosition(x, y, refWidth, refHeight);
  }

  sendMouseButton(buttonEvent: number, mouseButton: number): void {
    moonbridge.sendMouseButton(buttonEvent, mouseButton);
  }

  sendMouseScroll(amount: number): void {
    moonbridge.sendMouseScroll(amount);
  }

  sendKeyboard(keyMap: number, keyDirection: number, modifier: number, flags: number): void {
    moonbridge.sendKeyboard(keyMap, keyDirection, modifier, flags);
  }

  async startConnection(address: string, appVersion: string, gfeVersion: string, rtspSessionUrl: string,
    serverCodecModeSupport: number, width: number, height: number, fps: number, bitrate: number,
    packetSize: number, streamingRemotely: number, audioConfiguration: number, supportedVideoFormats: number,
    clientRefreshRateX100: number, riKeyHex: string, riKeyIvHex: string, videoCapabilities: number,
    colorSpace: number, colorRange: number): Promise<number> {
    return moonbridge.startConnection(address, appVersion, gfeVersion, rtspSessionUrl,
      serverCodecModeSupport, width, height, fps, bitrate, packetSize, streamingRemotely,
      audioConfiguration, supportedVideoFormats, clientRefreshRateX100, riKeyHex, riKeyIvHex,
      videoCapabilities, colorSpace, colorRange);
  }

  stopConnection(): Promise<void> {
    return moonbridge.stopConnection();
  }
}

export class MoonHostInfo {
  online: boolean = false;
  hostname: string = '';
  appVersion: string = '';
  pairStatus: number = 0;
  httpsPort: number = 47984;
  serverCodecModeSupport: number = 0;
  runningGameId: number = 0;
  state: string = '';
  error: string = '';
}

export class MoonApp {
  id: number = 0;
  title: string = '';
  hdr: boolean = false;
}

export class MoonAppList {
  error: string = '';
  apps: MoonApp[] = [];
}

export class MoonLaunchResult {
  ok: boolean = false;
  sessionUrl: string = '';
  error: string = '';
}
