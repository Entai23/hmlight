export interface MoonBridgeHostProbe {
  host: string;
  tcp47984Ms: number;
  tcp47989Ms: number;
  tcp48010Ms: number;
  tlsMs: number;
  httpOk: boolean;
  serverinfo: string;
}

export interface MoonBridgePortTest {
  result: number;
}

export interface MoonBridgeModule {
  init(): number;
  setEventCallback(callback: (type: string, payload: string) => void): number;
  clearEventCallback(): number;
  setLogDir(dir: string): string;
  getLogPath(): string;
  setSurfaceId(surfaceId: string): number;
  markStreamPaused(paused: number): void;
  isStreamPaused(): number;
  getVersion(): string;
  getBuildInfo(): string;
  probeHost(host: string, timeoutMs: number): Promise<string>;
  testConnectivity(host: string, timeoutMs: number): Promise<number>;
  startConnection(address: string, appVersion: string, gfeVersion: string, rtspSessionUrl: string,
    serverCodecModeSupport: number, width: number, height: number, fps: number, bitrate: number,
    packetSize: number, streamingRemotely: number, audioConfiguration: number, supportedVideoFormats: number,
    clientRefreshRateX100: number, riAesKeyHex: string, riAesIvHex: string, videoCapabilities: number,
    colorSpace: number, colorRange: number): Promise<number>;
  stopConnection(): Promise<void>;
  interruptConnection(): number;
  getStageName(stage: number): string;
  getStats(): string;
  getStreamRxBytes(): number;
  logUi(message: string): void;
  setDiagEnabled(on: boolean): void;
  setVideoRange(full: number): void;
  sendControllerEvent(flags: number, lt: number, rt: number, lx: number, ly: number, rx: number, ry: number): void;
  getEstimatedRtt(): string;
  sendMouseMove(deltaX: number, deltaY: number): number;
  sendMousePosition(x: number, y: number, referenceWidth: number, referenceHeight: number): number;
  sendMouseButton(buttonEvent: number, mouseButton: number): number;
  sendMouseScroll(amount: number): number;
  sendKeyboard(keyMap: number, keyDirection: number, modifier: number, flags: number): number;
  sendTouch(eventType: number, pointerId: number, x: number, y: number, pressure: number,
    contactAreaMajor: number, contactAreaMinor: number, rotation: number): number;
  sendUtf8Text(text: string): number;
  getPending(): string;
  stringifyPortFlags(portFlags: number, separator: string): string;
  getPortFlagsFromStage(stage: number): number;
  getPortFlagsFromTerminationError(errorCode: number): number;
  findExternalAddressIP4(stunHostName: string, stunPort: number): string;
  getLaunchUrlQueryParameters(): string;
  emitTestEvent(message: string): number;
  pairBegin(host: string): Promise<string>;
  pairComplete(host: string, pin: string): Promise<string>;
  getHostInfo(host: string): Promise<string>;
  getAppList(host: string): Promise<string>;
  launchApp(host: string, appId: number, width: number, height: number, fps: number,
    bitrate: number, riKeyHex: string, riKeyId: number, virtualDisplay: number,
    audioConfiguration: number, sops: number, hostAudio: number): Promise<string>;
  quitApp(host: string): Promise<number>;
  generateRiKey(): string;
  fetchAsset(host: string, appId: number): Promise<ArrayBuffer>;
}

declare const moonbridge: MoonBridgeModule;
export default moonbridge;
