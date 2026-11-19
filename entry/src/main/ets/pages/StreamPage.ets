import { router, window } from '@kit.ArkUI';
import { AppTheme, RouteParams } from '../common/AppTheme';
import { promptAction } from '@kit.ArkUI';
import { MoonBridgeService, MoonHostInfo, MoonLaunchResult } from '../services/MoonBridgeService';

class VideoSetupInfo {
  width: number = 0;
  height: number = 0;
}

class StreamStats {
  fps: number = 0;
  hostLatencyMs: number = 0;
  rttUs: number = 0;
  pendingVideoFrames: number = 0;
  framesSubmitted: number = 0;
  bytesSubmitted: number = 0;
  lastFrameAgeMs: number = 0;
}

@Entry
@Component
struct StreamPage {
  @StorageLink('lightTheme') lightTheme: boolean = true;
  @StorageLink('streamWidth') streamWidth: number = 1280;
  @StorageLink('streamHeight') streamHeight: number = 720;
  @StorageLink('streamFps') streamFps: number = 60;
  @StorageLink('streamBitrate') streamBitrate: number = 10000;
  @StorageLink('videoCodec') videoCodec: number = 0;
  @StorageLink('audioConfig') audioConfig: number = 0x302CA;
  @StorageLink('enableSops') enableSops: boolean = true;
  @StorageLink('hostAudio') hostAudio: boolean = false;
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
  @StorageLink('gamepadDeadzone') gamepadDeadzone: number = 7;
  @StorageLink('gamepadFlipFace') gamepadFlipFace: boolean = false;
  @StorageLink('showPerf') showPerf: boolean = true;
  @StorageLink('useVirtualDisplay') useVirtualDisplay: boolean = false;
  @StorageLink('adaptiveBitrate') adaptiveBitrate: boolean = true;
  @State statusText: string = '准备串流...';
  @State connected: boolean = false;
  @State showControls: boolean = true;
  @State statsText: string = '';
  @State netText: string = '';
  @State warningText: string = '';
  private lastStatsBytes: number = 0;
  private lastStatsMs: number = 0;
  private lastSysBytes: number = 0;
  private lastSysMs: number = 0;
  @State sysNetText: string = '';
  private lastSysMBs: number = 0;
  private sessionBitrate: number = 0;
  private restarting: boolean = false;
  private starting: boolean = false;
  private windowSamples: number = 0;
  private windowLatencyHigh: number = 0;
  private windowLossBad: number = 0;
  private warnCooldownMs: number = 0;
  private warnCount: number = 0;
  private padFlags: number = 0;
  private padLt: number = 0;
  private padRt: number = 0;
  private padLx: number = 0;
  private padLy: number = 0;
  private padRx: number = 0;
  private padRy: number = 0;
  @State videoAspect: number = 1.7778;
  private bridge: MoonBridgeService = MoonBridgeService.get();
  private xController: XComponentController = new XComponentController();
  private address: string = '';
  private appId: number = 0;
  private appTitle: string = '';
  private started: boolean = false;
  private statsTimer: number = -1;
  private controlsTimer: number = -1;
  private videoWidthVp: number = 1;
  private videoHeightVp: number = 1;
  private lastScrollY: number = 0;
  private singleFingerDown: boolean = false;
  private tpLastX: number = 0;
  private tpLastY: number = 0;
  private tpStartMs: number = 0;
  private tpMoved: boolean = false;
  private tpTwoFinger: boolean = false;
  private tpTwoMoved: boolean = false;
  private tpSuppressSingle: boolean = false;
  private tpTwoStartMs: number = 0;
  private tpTwoStartX: number = 0;
  private tpTwoStartY: number = 0;
  private tpLastTapMs: number = 0;
  private tpLastTapX: number = 0;
  private tpLastTapY: number = 0;
  private tpTapIsDouble: boolean = false;
  private absLastTapMs: number = 0;
  private absLastTapX: number = 0;
  private absLastTapY: number = 0;
  private absTapIsDouble: boolean = false;
  private absDownX: number = 0;
  private absDownY: number = 0;
  private absDragging: boolean = false;
  private touchStartMs: number = 0;
  private exiting: boolean = false;
  private stopRequested: boolean = false;
  private leftToBackground: boolean = false;
  private retryCount: number = 0;

  aboutToAppear(): void {
    this.bridge.ensureInit(getContext(this).filesDir);
    if (this.bridge.isStreamPaused()) {
      // App was killed/suspended while streaming; go back to the app list
      // instead of reconnecting automatically.
      this.exiting = true;
      setTimeout(() => {
        router.back();
      }, 100);
      return;
    }
    const params = router.getParams() as RouteParams;
    if (params !== undefined && params.address !== undefined) {
      this.address = params.address;
      this.appId = params.appId ?? 0;
      this.appTitle = params.appTitle ?? '';
    }
    this.enterFullscreen();
    this.bridge.setEventCallback((type: string, payload: string) => {
      if (type === 'connected') {
        this.connected = true;
        this.retryCount = 0;
        this.statusText = '';
        this.startStatsPolling();
      } else if (type === 'terminated') {
        this.connected = false;
        this.stopStatsPolling();
        if (this.starting || this.restarting) {
          return;
        }
        if (!this.exiting && this.retryCount < 2) {
          this.retryCount = this.retryCount + 1;
          this.statusText = '连接中断，正在重连（' + this.retryCount.toString() + '/2）...';
          const delay: number = 3000 + this.retryCount * 2000;
          setTimeout(() => {
            if (!this.exiting) {
              this.startStream();
            }
          }, delay);
        } else if (!this.exiting) {
          this.statusText = '串流已断开';
        }
      } else if (type === 'videoSetup') {
        this.statusText = '';
        const setup = JSON.parse(payload) as VideoSetupInfo;
        if (setup.width > 0 && setup.height > 0) {
          this.videoAspect = setup.width / setup.height;
        }
      }
    });
    this.scheduleHideControls();
  }

  onPageHide(): void {
    // Android behavior: leaving the app ends the stream. Never navigate while
    // in background (doing so can block the UI thread and freeze the app).
    this.bridge.markStreamPaused(true);
    if (!this.exiting) {
      this.exiting = true;
      this.leftToBackground = true;
      this.requestStop();
      this.exitFullscreen();
    }
  }

  onPageShow(): void {
    if (this.exiting && this.bridge.isStreamPaused() && !this.leftToBackground) {
      setTimeout(() => {
        router.back();
      }, 80);
      return;
    }
    if (this.leftToBackground) {
      this.leftToBackground = false;
      this.exiting = true;
      this.requestStop();
      setTimeout(() => {
        router.back();
      }, 120);
    }
  }

  requestStop(): void {
    if (!this.stopRequested) {
      this.stopRequested = true;
      this.bridge.stopConnection();
      this.bridge.clearEventCallback();
    }
  }

  onBackPress(): boolean {
    if (this.exiting) {
      return false;
    }
    if (this.immersiveMode) {
      if (this.escOnSwipe && this.connected) {
        this.bridge.sendKeyboard(0x1B, 0x03, 0, 0);
        setTimeout(() => {
          this.bridge.sendKeyboard(0x1B, 0x04, 0, 0);
        }, 40);
      }
      return true;
    }
    this.exiting = true;
    this.exitFullscreen();
    this.requestStop();
    setTimeout(() => {
      router.back();
    }, 180);
    return true;
  }

  aboutToDisappear(): void {
    this.exiting = true;
    this.requestStop();
    this.stopStatsPolling();
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer);
    }
    this.exitFullscreen();
  }

  enterFullscreen(): void {
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      win.setWindowSystemBarEnable([]);
      win.setWindowKeepScreenOn(true);
    }).catch(() => {
    });
  }

  exitFullscreen(): void {
    window.getLastWindow(getContext(this)).then((win: window.Window) => {
      win.setWindowSystemBarEnable(['status', 'navigation']);
      win.setWindowKeepScreenOn(false);
    }).catch(() => {
    });
  }

  startStatsPolling(): void {
    if (this.statsTimer >= 0) {
      return;
    }
    this.statsTimer = setInterval(() => {
      const raw: string = this.bridge.getStats();
      try {
        const stats = JSON.parse(raw) as StreamStats;
        const nowMs: number = Date.now();
        let netMBs: number = 0;
        if (this.lastStatsMs > 0 && nowMs > this.lastStatsMs &&
            stats.bytesSubmitted >= this.lastStatsBytes) {
          netMBs = (stats.bytesSubmitted - this.lastStatsBytes) / 1048576.0 /
            ((nowMs - this.lastStatsMs) / 1000.0);
        }
        this.lastStatsBytes = stats.bytesSubmitted;
        this.lastStatsMs = nowMs;
        this.netText = 'VIDEO ' + netMBs.toFixed(1) + ' MB/s (成帧)';
        const totalRx: number = this.bridge.getStreamRxBytes();
        if (this.lastSysMs > 0 && nowMs > this.lastSysMs && totalRx >= this.lastSysBytes) {
          const mbps: number = (totalRx - this.lastSysBytes) / 1048576.0 /
            ((nowMs - this.lastSysMs) / 1000.0);
          this.sysNetText = 'NET ' + mbps.toFixed(1) + ' MB/s (网络)';
          this.lastSysMBs = mbps;
        }
        this.lastSysBytes = totalRx;
        this.lastSysMs = nowMs;
        this.statsText = 'FPS ' + stats.fps.toFixed(1) +
          '  RTT ' + (stats.rttUs / 1000).toFixed(1) + 'ms' +
          '  HOST ' + stats.hostLatencyMs.toFixed(1) + 'ms' +
          '  queue ' + stats.pendingVideoFrames.toString();
        if (stats.fps < 10 && netMBs > 2.0) {
          this.warningText = '检测到严重丢包：带宽不足，请降低码率/分辨率';
        } else if (stats.fps > 30) {
          this.warningText = '';
        }
        this.evaluateAdaptiveBitrate(stats, netMBs);
      } catch (e) {
        this.statsText = '';
      }
    }, 1000);
  }

  stopStatsPolling(): void {
    if (this.statsTimer >= 0) {
      clearInterval(this.statsTimer);
      this.statsTimer = -1;
    }
  }

  scheduleHideControls(): void {
    if (this.controlsTimer >= 0) {
      clearTimeout(this.controlsTimer);
    }
    this.controlsTimer = setTimeout(() => {
      this.showControls = false;
    }, 4000);
  }

  toggleControls(): void {
    this.showControls = !this.showControls;
    if (this.showControls) {
      this.scheduleHideControls();
    }
  }

  async startStream(): Promise<void> {
    if (this.connected || this.exiting || this.starting) {
      return;
    }
    this.starting = true;
    try {
      const infoText: string = await this.bridge.getHostInfo(this.address);
      const info = JSON.parse(infoText) as MoonHostInfo;
      if (this.sessionBitrate === 0) {
        this.sessionBitrate = this.streamBitrate;
      }
      const effectiveBitrate: number = this.sessionBitrate;
      this.windowSamples = 0;
      this.windowLatencyHigh = 0;
      this.windowLossBad = 0;
      this.bridge.setVideoRange(this.fullRange);
      const riParts: string[] = this.bridge.generateRiKey().split(':');
      const riKeyHex: string = riParts[0];
      const riKeyId: number = Number.parseInt(riParts[1]);
      const titleLower: string = this.appTitle.toLowerCase();
      const wantVirtualDisplay: boolean = this.useVirtualDisplay ||
        titleLower.indexOf('virtual display') >= 0 || this.appTitle.indexOf('虚拟') >= 0;
      const launchText: string = await this.bridge.launchApp(this.address, this.appId,
        this.streamWidth, this.streamHeight, this.streamFps, effectiveBitrate, riKeyHex, riKeyId,
        wantVirtualDisplay, this.audioConfig, this.enableSops, this.hostAudio);
      const launch = JSON.parse(launchText) as MoonLaunchResult;
      if (!launch.ok) {
        const message: string = launch.error === 'gamesession0'
          ? '主机上已有应用在运行' : ('启动应用失败: ' + launch.error);
        promptAction.showToast({ message: message });
        this.statusText = message;
        setTimeout(() => {
          this.exiting = true;
          this.exitFullscreen();
          router.back();
        }, 1200);
        return;
      }
      const unsignedId: number = riKeyId >>> 0;
      let ivHex: string = unsignedId.toString(16).toUpperCase();
      while (ivHex.length < 8) {
        ivHex = '0' + ivHex;
      }
      while (ivHex.length < 32) {
        ivHex = ivHex + '0';
      }
      this.statusText = '正在建立连接...';
      let supportedFormats: number = 0x0101;
      if (this.videoCodec === 1) {
        supportedFormats = 0x0001;
      } else if (this.videoCodec === 2) {
        supportedFormats = 0x0100;
      }
      const ret: number = await this.bridge.startConnection(this.address, info.appVersion, '',
        launch.sessionUrl, info.serverCodecModeSupport, this.streamWidth, this.streamHeight,
        this.streamFps, effectiveBitrate, 1024, 0, this.audioConfig, supportedFormats, 0, riKeyHex, ivHex, 0, 0, 0);
      if (ret !== 0 && !this.connected) {
        const message: string = '连接失败: ' + ret.toString();
        this.statusText = message;
        promptAction.showToast({ message: message });
        setTimeout(() => {
          this.exiting = true;
          this.exitFullscreen();
          router.back();
        }, 1500);
      } else if (ret === 0) {
        this.statusText = '';
      }
    } catch (error) {
      this.statusText = '串流异常: ' + JSON.stringify(error);
    } finally {
      this.starting = false;
    }
  }

  handleTouch(event: TouchEvent): void {
    if (this.touchpadMode) {
      this.handleTouchpad(event);
      return;
    }
    if (!this.smartMouse) {
      if (event.touches.length >= 3 && event.type === TouchType.Down) {
        this.toggleControls();
      }
      return;
    }
    if (event.touches.length >= 3) {
      if (event.type === TouchType.Down) {
        this.toggleControls();
      }
      this.singleFingerDown = false;
      return;
    }
    if (event.touches.length >= 2) {
      const y: number = (event.touches[0].y + event.touches[1].y) / 2;
      if (this.lastScrollY > 0) {
        const dy: number = y - this.lastScrollY;
        if (Math.abs(dy) > 3) {
          const dir: number = this.scrollInvert ? 1 : -1;
          this.bridge.sendMouseScroll(dir * Math.round(dy * 4));
        }
      }
      this.lastScrollY = y;
      this.singleFingerDown = false;
      return;
    }
    this.lastScrollY = 0;
    if (event.type === TouchType.Down) {
      if (!this.connected) {
        this.toggleControls();
        return;
      }
      const touch = event.touches[0];
      const nowMs: number = Date.now();
      const near: boolean = this.smartMouse &&
        nowMs - this.absLastTapMs < 350 &&
        Math.abs(touch.x - this.absLastTapX) < 14 &&
        Math.abs(touch.y - this.absLastTapY) < 14;
      this.absTapIsDouble = near && this.absLastTapMs > 0;
      this.absDownX = touch.x;
      this.absDownY = touch.y;
      this.absDragging = false;
      this.singleFingerDown = true;
      this.touchStartMs = nowMs;
    } else if (event.type === TouchType.Move) {
      if (event.touches.length === 1 && this.singleFingerDown) {
        const touch = event.touches[0];
        if (!this.absDragging) {
          const moved: number = Math.max(Math.abs(touch.x - this.absDownX),
            Math.abs(touch.y - this.absDownY));
          if (moved > 6) {
            this.absDragging = true;
            this.bridge.sendMousePosition(this.absDownX, this.absDownY,
              this.videoWidthVp, this.videoHeightVp);
            this.bridge.sendMouseButton(0x07, 0x01);
          }
        }
        if (this.absDragging) {
          this.bridge.sendMousePosition(touch.x, touch.y, this.videoWidthVp, this.videoHeightVp);
        }
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      if (this.singleFingerDown) {
        this.singleFingerDown = false;
        const touch: TouchObject = event.touches.length > 0 ? event.touches[0] : event.changedTouches[0];
        const held: number = Date.now() - this.touchStartMs;
        if (this.absDragging) {
          this.bridge.sendMouseButton(0x08, 0x01);
          this.absDragging = false;
          this.absLastTapMs = 0;
        } else if (this.smartMouse && held >= this.longPressMs) {
          this.bridge.sendMousePosition(touch.x, touch.y, this.videoWidthVp, this.videoHeightVp);
          this.bridge.sendMouseButton(0x07, 0x03);
          this.bridge.sendMouseButton(0x08, 0x03);
          this.absLastTapMs = 0;
        } else {
          if (this.absTapIsDouble) {
            this.bridge.sendMousePosition(this.absLastTapX, this.absLastTapY,
              this.videoWidthVp, this.videoHeightVp);
          } else {
            this.bridge.sendMousePosition(touch.x, touch.y, this.videoWidthVp, this.videoHeightVp);
            this.absLastTapX = touch.x;
            this.absLastTapY = touch.y;
          }
          this.bridge.sendMouseButton(0x07, 0x01);
          this.bridge.sendMouseButton(0x08, 0x01);
          this.absLastTapMs = this.absTapIsDouble ? 0 : Date.now();
        }
        if (!this.smartMouse && held > 600) {
          this.showControls = true;
          this.scheduleHideControls();
        }
      }
    }
  }

  handleTouchpad(event: TouchEvent): void {
    if (event.touches.length >= 3) {
      if (event.type === TouchType.Down) {
        this.toggleControls();
      }
      return;
    }
    if (!this.connected) {
      if (event.type === TouchType.Down) {
        this.toggleControls();
      }
      return;
    }
    if (event.touches.length >= 2) {
      const avgX: number = (event.touches[0].x + event.touches[1].x) / 2;
      const avgY: number = (event.touches[0].y + event.touches[1].y) / 2;
      if (!this.tpTwoFinger) {
        this.tpTwoFinger = true;
        this.tpTwoMoved = false;
        this.tpTwoStartMs = Date.now();
        this.tpTwoStartX = avgX;
        this.tpTwoStartY = avgY;
        this.tpLastY = avgY;
      } else if (event.type === TouchType.Move) {
        if (Math.abs(avgX - this.tpTwoStartX) > 6 ||
            Math.abs(avgY - this.tpTwoStartY) > 6) {
          this.tpTwoMoved = true;
        }
        const dy: number = avgY - this.tpLastY;
        if (Math.abs(dy) > 2) {
          const dir: number = this.tpScrollInvert ? 1 : -1;
          this.bridge.sendMouseScroll(dir * Math.round(dy * 3));
        }
        this.tpLastY = avgY;
      } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
        if (!this.tpTwoMoved && Date.now() - this.tpTwoStartMs < 300) {
          this.bridge.sendMouseButton(0x07, 0x03);
          this.bridge.sendMouseButton(0x08, 0x03);
        }
        this.tpTwoFinger = false;
        this.tpSuppressSingle = true;
      }
      return;
    }
    if (this.tpTwoFinger) {
      this.tpTwoFinger = false;
      this.tpSuppressSingle = true;
    }
    if (event.type === TouchType.Down) {
      const touch = event.touches[0];
      const nowMs: number = Date.now();
      const near: boolean = nowMs - this.tpLastTapMs < 350 &&
        Math.abs(touch.x - this.tpLastTapX) < 14 &&
        Math.abs(touch.y - this.tpLastTapY) < 14;
      this.tpTapIsDouble = near && this.tpLastTapMs > 0;
      this.tpLastX = touch.x;
      this.tpLastY = touch.y;
      this.tpStartMs = nowMs;
      this.tpMoved = false;
      this.tpSuppressSingle = false;
    } else if (this.tpSuppressSingle) {
      return;
    } else if (event.type === TouchType.Move) {
      if (event.touches.length === 1) {
        const touch = event.touches[0];
        const dx: number = touch.x - this.tpLastX;
        const dy: number = touch.y - this.tpLastY;
        const jitterLimit: number = this.tpTapIsDouble ? 8 : 0.5;
        if (Math.abs(dx) > jitterLimit || Math.abs(dy) > jitterLimit) {
          this.tpMoved = true;
          const sens: number[] = [0.5, 0.75, 1.0, 1.5, 2.0];
          const level: number = this.touchpadSensitivity < 0 ? 0 :
            (this.touchpadSensitivity > 4 ? 4 : this.touchpadSensitivity);
          const scale: number = 1.8 * sens[level];
          this.bridge.sendMouseMove(Math.round(dx * scale), Math.round(dy * scale));
        }
        this.tpLastX = touch.x;
        this.tpLastY = touch.y;
      }
    } else if (event.type === TouchType.Up || event.type === TouchType.Cancel) {
      const heldMs: number = Date.now() - this.tpStartMs;
      if (!this.tpMoved && heldMs >= this.tpLongPressMs) {
        this.bridge.sendMouseButton(0x07, 0x03);
        this.bridge.sendMouseButton(0x08, 0x03);
        this.tpLastTapMs = 0;
      } else if (!this.tpMoved && heldMs < 300) {
        this.bridge.sendMouseButton(0x07, 0x01);
        this.bridge.sendMouseButton(0x08, 0x01);
        if (this.tpTapIsDouble) {
          this.tpLastTapMs = 0;
        } else {
          this.tpLastTapMs = Date.now();
          this.tpLastTapX = this.tpLastX;
          this.tpLastTapY = this.tpLastY;
        }
      } else {
        this.tpLastTapMs = 0;
      }
      if (!this.smartMouse && this.tpMoved && heldMs > 600) {
        this.showControls = true;
        this.scheduleHideControls();
      }
    }
  }

  pageTransition() {
    PageTransitionEnter({ duration: 0, curve: Curve.Linear })
    PageTransitionExit({ duration: 0, curve: Curve.Linear })
  }

  private sendPadState(): void {
    this.bridge.sendControllerEvent(this.padFlags, this.padLt, this.padRt,
      this.padLx, this.padLy, this.padRx, this.padRy);
  }

  private setPadFlag(flag: number, down: boolean): void {
    this.padFlags = down ? (this.padFlags | flag) : (this.padFlags & ~flag);
    this.sendPadState();
  }

  handleGamepadKey(code: number, down: boolean): boolean {
    if (!this.connected || !this.gamepadEnabled) {
      return false;
    }
    const flip: boolean = this.gamepadFlipFace;
    if (code === 2301) { this.setPadFlag(flip ? 0x2000 : 0x1000, down); return true; }
    if (code === 2302) { this.setPadFlag(flip ? 0x1000 : 0x2000, down); return true; }
    if (code === 2303) { this.setPadFlag(flip ? 0x8000 : 0x4000, down); return true; }
    if (code === 2304) { this.setPadFlag(flip ? 0x8000 : 0x4000, down); return true; }
    if (code === 2305) { this.setPadFlag(flip ? 0x4000 : 0x8000, down); return true; }
    if (code === 2307) { this.setPadFlag(0x0100, down); return true; }
    if (code === 2308) { this.setPadFlag(0x0200, down); return true; }
    if (code === 2309) { this.padLt = down ? 255 : 0; this.sendPadState(); return true; }
    if (code === 2310) { this.padRt = down ? 255 : 0; this.sendPadState(); return true; }
    if (code === 2311) { this.setPadFlag(0x0020, down); return true; }
    if (code === 2312) { this.setPadFlag(0x0010, down); return true; }
    if (code === 2313) { this.setPadFlag(0x0400, down); return true; }
    if (code === 2314) { this.setPadFlag(0x0040, down); return true; }
    if (code === 2315) { this.setPadFlag(0x0080, down); return true; }
    if (code === 2012) { this.setPadFlag(0x0001, down); return true; }
    if (code === 2013) { this.setPadFlag(0x0002, down); return true; }
    if (code === 2014) { this.setPadFlag(0x0004, down); return true; }
    if (code === 2015) { this.setPadFlag(0x0008, down); return true; }
    return false;
  }

  private resetPadState(): void {
    this.padFlags = 0;
    this.padLt = 0;
    this.padRt = 0;
    this.padLx = 0;
    this.padLy = 0;
    this.padRx = 0;
    this.padRy = 0;
  }

  evaluateAdaptiveBitrate(stats: StreamStats, videoMBs: number): void {
    if (!this.adaptiveBitrate || this.lastSysMs === 0) {
      return;
    }
    const now: number = Date.now();
    const sysMBs: number = this.lastSysMBs;
    const lossRatio: number = sysMBs > 0.3 ? (1.0 - videoMBs / sysMBs) : 0;
    const lossy: boolean = (sysMBs > 1.0 && lossRatio > 0.75) ||
      (sysMBs > 1.5 && stats.fps < 5);
    if (lossy) {
      this.windowLossBad++;
    }
    if (stats.hostLatencyMs > 100) {
      this.windowLatencyHigh++;
    }
    this.windowSamples++;
    if (this.windowSamples < 5) {
      return;
    }
    const latencyBad: boolean = this.windowLatencyHigh * 5 >= this.windowSamples * 4;
    const lossBad: boolean = this.windowLossBad * 5 >= this.windowSamples * 4;
    this.windowSamples = 0;
    this.windowLatencyHigh = 0;
    this.windowLossBad = 0;
    if ((!lossBad && !latencyBad) || now < this.warnCooldownMs || this.warnCount >= 2) {
      return;
    }
    if (this.warnCount === 0) {
      this.warnCount = 1;
      this.warnCooldownMs = now + 20000;
      promptAction.showToast({ message: '码率过高，推荐降低码率，否则会非常卡顿', duration: 4500 });
    } else if (this.warnCount === 1 && now - (this.warnCooldownMs - 20000) >= 20000) {
      this.warnCount = 2;
      promptAction.showToast({
        message: '码率过高，推荐降低码率，否则会非常卡顿\n　　　（可在设置中关闭此提醒）',
        duration: 10000
      });
    }
  }

  build() {
    Stack() {
      if (this.stretchVideo) {
        XComponent({ id: 'streamSurface', type: XComponentType.SURFACE, controller: this.xController })
          .width('100%')
          .height('100%')
          .backgroundColor(Color.Black)
          .onLoad(() => {
            const surfaceId: string = this.xController.getXComponentSurfaceId();
            this.bridge.setSurfaceId(surfaceId);
            if (!this.started && !this.exiting) {
              this.started = true;
              this.startStream();
            }
          })
          .onTouch((event: TouchEvent) => {
            this.handleTouch(event);
          })
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.videoWidthVp = parseFloat(newValue.width.toString());
            this.videoHeightVp = parseFloat(newValue.height.toString());
          })
      } else {
        XComponent({ id: 'streamSurface', type: XComponentType.SURFACE, controller: this.xController })
          .width('100%')
          .aspectRatio(this.videoAspect)
          .backgroundColor(Color.Black)
          .onLoad(() => {
            const surfaceId: string = this.xController.getXComponentSurfaceId();
            this.bridge.setSurfaceId(surfaceId);
            if (!this.started && !this.exiting) {
              this.started = true;
              this.startStream();
            }
          })
          .onTouch((event: TouchEvent) => {
            this.handleTouch(event);
          })
          .onAreaChange((oldValue: Area, newValue: Area) => {
            this.videoWidthVp = parseFloat(newValue.width.toString());
            this.videoHeightVp = parseFloat(newValue.height.toString());
          })
      }

      if (this.statusText.length > 0) {
        Text(this.statusText)
          .hitTestBehavior(HitTestMode.None)
          .fontSize(16)
          .fontColor(Color.White)
          .backgroundColor('#80000000')
          .padding(10)
          .borderRadius(8)
      }

      if (this.showPerf && this.statsText.length > 0) {
        Column({ space: 4 }) {
          Text(this.statsText)
            .fontSize(12)
            .fontColor(Color.White)
          Text(this.netText)
            .fontSize(12)
            .fontColor(Color.White)
          if (this.sysNetText.length > 0) {
            Text(this.sysNetText)
              .fontSize(12)
              .fontColor(Color.White)
          }
        }
        .hitTestBehavior(HitTestMode.None)
        .alignItems(HorizontalAlign.Start)
        .backgroundColor('#80000000')
        .padding(6)
        .position({ x: 10, y: 10 })
      }

      if (this.warningText.length > 0) {
        Text(this.warningText)
          .hitTestBehavior(HitTestMode.None)
          .fontSize(16)
          .fontColor('#FFD166')
          .backgroundColor('#CC000000')
          .padding(10)
          .borderRadius(8)
      }

      if (this.showControls) {
        Column() {
          Row() {
            Button('退出串流')
              .backgroundColor('#CC000000')
              .fontColor(Color.White)
              .onClick(() => {
                this.exiting = true;
                this.requestStop();
                this.exitFullscreen();
                setTimeout(() => {
                  router.back();
                }, 180);
              })
            Text(this.appTitle).fontSize(15).fontColor(Color.White)
              .margin({ left: 12 })
              .maxLines(1)
              .textOverflow({ overflow: TextOverflow.Ellipsis })
              .layoutWeight(1)
          }
          .width('100%')
          .padding(12)
        }
        .width('100%')
        .alignItems(HorizontalAlign.Start)
        .position({ x: 0, y: 0 })
      }
    }
    .width('100%')
    .height('100%')
    .backgroundColor(Color.Black)
    .alignContent(Alignment.Center)
    .focusable(true)
    .defaultFocus(true)
    .onKeyEvent((event: KeyEvent) => {
      this.handleGamepadKey(event.keyCode, event.type === KeyType.Down);
    })
  }
}
