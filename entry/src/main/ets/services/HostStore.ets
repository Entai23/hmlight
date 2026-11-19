export class HostEntry {
  name: string = '';
  address: string = '';
  paired: boolean = false;
  online: boolean = false;

  constructor(name: string, address: string, paired: boolean, online: boolean) {
    this.name = name;
    this.address = address;
    this.paired = paired;
    this.online = online;
  }
}

PersistentStorage.persistProp('moonHostList', '[]');
PersistentStorage.persistProp('moonHost', '');
PersistentStorage.persistProp('streamWidth', 1280);
PersistentStorage.persistProp('streamHeight', 720);
PersistentStorage.persistProp('streamFps', 60);
PersistentStorage.persistProp('streamBitrate', 10000);
PersistentStorage.persistProp('videoCodec', 0);
PersistentStorage.persistProp('showPerf', true);
PersistentStorage.persistProp('settingsDialogMode', false);
PersistentStorage.persistProp('streamPaused', false);
PersistentStorage.persistProp('devMode', false);
PersistentStorage.persistProp('diagLogging', false);
PersistentStorage.persistProp('resPreset', '');
PersistentStorage.persistProp('nativeScale', 100);
PersistentStorage.persistProp('lightIcon', true);
PersistentStorage.persistProp('lightTheme', true);
PersistentStorage.persistProp('confirmLaunch', true);

export class HostStore {
  static load(): HostEntry[] {
    const raw: string = AppStorage.get<string>('moonHostList') ?? '[]';
    try {
      return JSON.parse(raw) as HostEntry[];
    } catch (e) {
      return [];
    }
  }

  static save(list: HostEntry[]): void {
    AppStorage.setOrCreate('moonHostList', JSON.stringify(list));
  }

  static lastAddress(): string {
    return AppStorage.get<string>('moonHost') ?? '';
  }

  static rememberAddress(address: string): void {
    AppStorage.setOrCreate('moonHost', address);
  }

  static upsert(entry: HostEntry): void {
    const list: HostEntry[] = HostStore.load();
    let found: boolean = false;
    for (let i = 0; i < list.length; i++) {
      if (list[i].address === entry.address) {
        list[i] = entry;
        found = true;
      }
    }
    if (!found) {
      list.push(entry);
    }
    HostStore.save(list);
  }

  static remove(address: string): void {
    const list: HostEntry[] = HostStore.load();
    const kept: HostEntry[] = [];
    for (let i = 0; i < list.length; i++) {
      if (list[i].address !== address) {
        kept.push(list[i]);
      }
    }
    HostStore.save(kept);
  }
}
