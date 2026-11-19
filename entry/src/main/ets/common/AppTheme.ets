export class AppTheme {
  static background: string = '#000000';
  static surface: string = '#1F1F1F';
  static primary: string = '#00B4D8';
  static text: string = '#FFFFFF';
  static textDim: string = '#B0B0B0';
  static divider: string = '#33FFFFFF';
  static buttonBg: string = '#333333';
  static cardBg: string = '#222222';
  static readonly pcIconSize: number = 125;
  static readonly appPosterWidth: number = 150;
  static readonly appPosterHeight: number = 200;

  static apply(light: boolean): void {
    // Colors are resource-based now; kept for compatibility.
  }
}

export class RouteParams {
  address: string = '';
  appId: number = 0;
  appTitle: string = '';
}
