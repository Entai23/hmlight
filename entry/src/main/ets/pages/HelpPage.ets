import { router } from '@kit.ArkUI';
import { AppTheme } from '../common/AppTheme';

@Entry
@Component
struct HelpPage {

  aboutToAppear(): void {
  }
  @StorageLink('lightTheme') lightTheme: boolean = true;
  pageTransition() {
    PageTransitionEnter({ duration: 0, curve: Curve.Linear })
    PageTransitionExit({ duration: 0, curve: Curve.Linear })
  }

  build() {
    Column() {
      Row() {
        Text('←')
          .fontSize(30)
          .fontColor($r('app.color.app_text'))
          .padding({ left: 16, right: 16 })
          .onClick(() => {
            router.back();
          })
        Text('帮助').fontSize(20).fontColor($r('app.color.app_text')).layoutWeight(1)
      }
      .width('100%')
      .height(65)

      Scroll() {
        Column({ space: 16 }) {
          Text('快速开始').fontSize(17).fontColor($r('app.color.app_primary')).width('100%')
          Text('1. 在电脑上安装并启动 Apollo / Sunshine 串流服务端\n' +
            '2. 确保平板与电脑连接到同一个局域网\n' +
            '3. 点击首页右上角 + 添加电脑 IP（或等待自动发现）\n' +
            '4. 点击电脑卡片完成配对：客户端显示 4 位 PIN，在电脑端输入\n' +
            '5. 进入应用列表，点击应用开始串流').fontSize(14).fontColor($r('app.color.app_text')).width('100%')

          Text('串流操作').fontSize(17).fontColor($r('app.color.app_primary')).width('100%')
          Text('• 单指移动：控制鼠标\n' +
            '• 单指点击：鼠标左键\n' +
            '• 双指上下滑动：滚轮\n' +
            '• 长按屏幕：显示退出按钮\n' +
            '• 返回手势：断开串流').fontSize(14).fontColor($r('app.color.app_text')).width('100%')

          Text('常见问题').fontSize(17).fontColor($r('app.color.app_primary')).width('100%')
          Text('• 配对失败：确认 PIN 输入正确，且电脑上允许了配对请求\n' +
            '• 连接中断：检查 Wi-Fi 是否稳定；串流会自动重连\n' +
            '• 画面卡顿：降低分辨率/帧率或码率\n' +
            '• 没有声音：音频功能将在下一版本接入').fontSize(14).fontColor($r('app.color.app_text_dim')).width('100%')
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
    .expandSafeArea([SafeAreaType.SYSTEM], [SafeAreaEdge.BOTTOM])
  }
}
