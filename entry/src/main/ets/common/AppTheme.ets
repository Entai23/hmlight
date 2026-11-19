export class AppTheme {
  static background: string = '#36393F';
  static surface: string = '#3F434A';
  static primary: string = '#00B4D8';
  static text: string = '#FFFFFF';
  static textDim: string = '#B4B8C0';
  static divider: string = '#33FFFFFF';
  static buttonBg: string = '#4A4E56';
  static cardBg: string = '#42464D';
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
