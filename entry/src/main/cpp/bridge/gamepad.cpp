#include "gamepad.h"

#include <GameControllerKit/game_pad.h>
#include <GameControllerKit/game_pad_event.h>

#include <atomic>
#include <cmath>

#include "Limelight.h"
#include "diag.h"

namespace {

std::atomic<int> g_flags{0};
std::atomic<int> g_lt{0};
std::atomic<int> g_rt{0};
std::atomic<int> g_lx{0};
std::atomic<int> g_ly{0};
std::atomic<int> g_rx{0};
std::atomic<int> g_ry{0};
std::atomic<bool> g_active{false};
std::atomic<int> g_deadzone{7};
std::atomic<bool> g_flip{false};

void Send(void) {
    if (!g_active.load()) {
        return;
    }
    LiSendControllerEvent(g_flags.load(), static_cast<unsigned char>(g_lt.load()),
                          static_cast<unsigned char>(g_rt.load()),
                          static_cast<short>(g_lx.load()), static_cast<short>(g_ly.load()),
                          static_cast<short>(g_rx.load()), static_cast<short>(g_ry.load()));
}

void SetFlag(int flag, bool down) {
    int cur = g_flags.load();
    int next = down ? (cur | flag) : (cur & ~flag);
    g_flags.store(next);
    Send();
}

int AxisTo16(double v) {
    if (v > 1.0) v = 1.0;
    if (v < -1.0) v = -1.0;
    const int raw = static_cast<int>(v * 32767.0);
    const int dz = 32767 * g_deadzone.load() / 100;
    if (std::abs(raw) <= dz) {
        return 0;
    }
    const int sign = raw < 0 ? -1 : 1;
    const int scaled = (std::abs(raw) - dz) * 32767 / (32767 - dz);
    return sign * scaled;
}

int TriggerTo8(double v) {
    if (v < 0.0) v = 0.0;
    if (v > 1.0) v = 1.0;
    return static_cast<int>(v * 255.0);
}

bool IsDown(const GamePad_ButtonEvent* e) {
    GamePad_Button_ActionType action = UP;
    if (e == nullptr || OH_GamePad_ButtonEvent_GetButtonAction(e, &action) != GAME_CONTROLLER_SUCCESS) {
        return false;
    }
    return action == DOWN;
}

void OnA(const GamePad_ButtonEvent* e) { SetFlag(g_flip.load() ? B_FLAG : A_FLAG, IsDown(e)); }
void OnB(const GamePad_ButtonEvent* e) { SetFlag(g_flip.load() ? A_FLAG : B_FLAG, IsDown(e)); }
void OnX(const GamePad_ButtonEvent* e) { SetFlag(g_flip.load() ? Y_FLAG : X_FLAG, IsDown(e)); }
void OnY(const GamePad_ButtonEvent* e) { SetFlag(g_flip.load() ? X_FLAG : Y_FLAG, IsDown(e)); }
void OnLB(const GamePad_ButtonEvent* e) { SetFlag(LB_FLAG, IsDown(e)); }
void OnRB(const GamePad_ButtonEvent* e) { SetFlag(RB_FLAG, IsDown(e)); }
void OnLS(const GamePad_ButtonEvent* e) { SetFlag(LS_CLK_FLAG, IsDown(e)); }
void OnRS(const GamePad_ButtonEvent* e) { SetFlag(RS_CLK_FLAG, IsDown(e)); }
void OnMenu(const GamePad_ButtonEvent* e) { SetFlag(PLAY_FLAG, IsDown(e)); }
void OnHome(const GamePad_ButtonEvent* e) { SetFlag(SPECIAL_FLAG, IsDown(e)); }
void OnC(const GamePad_ButtonEvent* e) { SetFlag(BACK_FLAG, IsDown(e)); }
void OnDpadUp(const GamePad_ButtonEvent* e) { SetFlag(UP_FLAG, IsDown(e)); }
void OnDpadDown(const GamePad_ButtonEvent* e) { SetFlag(DOWN_FLAG, IsDown(e)); }
void OnDpadLeft(const GamePad_ButtonEvent* e) { SetFlag(LEFT_FLAG, IsDown(e)); }
void OnDpadRight(const GamePad_ButtonEvent* e) { SetFlag(RIGHT_FLAG, IsDown(e)); }

void OnLeftStick(const GamePad_AxisEvent* e) {
    double x = 0.0;
    double y = 0.0;
    if (e != nullptr) {
        OH_GamePad_AxisEvent_GetXAxisValue(e, &x);
        OH_GamePad_AxisEvent_GetYAxisValue(e, &y);
    }
    g_lx.store(AxisTo16(x));
    g_ly.store(AxisTo16(-y));
    Send();
}

void OnRightStick(const GamePad_AxisEvent* e) {
    double x = 0.0;
    double y = 0.0;
    if (e != nullptr) {
        OH_GamePad_AxisEvent_GetZAxisValue(e, &x);
        OH_GamePad_AxisEvent_GetRZAxisValue(e, &y);
    }
    g_rx.store(AxisTo16(x));
    g_ry.store(AxisTo16(-y));
    Send();
}

void OnLeftTrigger(const GamePad_AxisEvent* e) {
    double v = 0.0;
    if (e != nullptr) {
        OH_GamePad_AxisEvent_GetBrakeAxisValue(e, &v);
    }
    g_lt.store(TriggerTo8(v));
    Send();
}

void OnRightTrigger(const GamePad_AxisEvent* e) {
    double v = 0.0;
    if (e != nullptr) {
        OH_GamePad_AxisEvent_GetGasAxisValue(e, &v);
    }
    g_rt.store(TriggerTo8(v));
    Send();
}

} // namespace

namespace gamepad {

void Start(int deadzonePercent, bool flipFaceButtons) {
    if (g_active.load()) {
        Stop();
    }
    g_deadzone.store(deadzonePercent < 0 ? 0 : (deadzonePercent > 20 ? 20 : deadzonePercent));
    g_flip.store(flipFaceButtons);
    g_flags.store(0);
    g_lt.store(0);
    g_rt.store(0);
    g_lx.store(0);
    g_ly.store(0);
    g_rx.store(0);
    g_ry.store(0);
    g_active.store(true);

    OH_GamePad_ButtonA_RegisterButtonInputMonitor(OnA);
    OH_GamePad_ButtonB_RegisterButtonInputMonitor(OnB);
    OH_GamePad_ButtonX_RegisterButtonInputMonitor(OnX);
    OH_GamePad_ButtonY_RegisterButtonInputMonitor(OnY);
    OH_GamePad_LeftShoulder_RegisterButtonInputMonitor(OnLB);
    OH_GamePad_RightShoulder_RegisterButtonInputMonitor(OnRB);
    OH_GamePad_LeftThumbstick_RegisterButtonInputMonitor(OnLS);
    OH_GamePad_RightThumbstick_RegisterButtonInputMonitor(OnRS);
    OH_GamePad_ButtonMenu_RegisterButtonInputMonitor(OnMenu);
    OH_GamePad_ButtonHome_RegisterButtonInputMonitor(OnHome);
    OH_GamePad_ButtonC_RegisterButtonInputMonitor(OnC);
    OH_GamePad_Dpad_UpButton_RegisterButtonInputMonitor(OnDpadUp);
    OH_GamePad_Dpad_DownButton_RegisterButtonInputMonitor(OnDpadDown);
    OH_GamePad_Dpad_LeftButton_RegisterButtonInputMonitor(OnDpadLeft);
    OH_GamePad_Dpad_RightButton_RegisterButtonInputMonitor(OnDpadRight);
    OH_GamePad_LeftThumbstick_RegisterAxisInputMonitor(OnLeftStick);
    OH_GamePad_RightThumbstick_RegisterAxisInputMonitor(OnRightStick);
    OH_GamePad_LeftTrigger_RegisterAxisInputMonitor(OnLeftTrigger);
    OH_GamePad_RightTrigger_RegisterAxisInputMonitor(OnRightTrigger);

    mdiag::Log("pad", "gamepad monitors registered (deadzone=%d flip=%d)",
               g_deadzone.load(), g_flip.load() ? 1 : 0);
}

void Stop(void) {
    if (!g_active.exchange(false)) {
        return;
    }
    OH_GamePad_ButtonA_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonB_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonX_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonY_UnregisterButtonInputMonitor();
    OH_GamePad_LeftShoulder_UnregisterButtonInputMonitor();
    OH_GamePad_RightShoulder_UnregisterButtonInputMonitor();
    OH_GamePad_LeftThumbstick_UnregisterButtonInputMonitor();
    OH_GamePad_RightThumbstick_UnregisterButtonInputMonitor();
    OH_GamePad_RightThumbstick_UnregisterAxisInputMonitor();
    OH_GamePad_ButtonMenu_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonHome_UnregisterButtonInputMonitor();
    OH_GamePad_ButtonC_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_UpButton_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_DownButton_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_LeftButton_UnregisterButtonInputMonitor();
    OH_GamePad_Dpad_RightButton_UnregisterButtonInputMonitor();
    OH_GamePad_LeftThumbstick_UnregisterAxisInputMonitor();
    OH_GamePad_LeftTrigger_UnregisterAxisInputMonitor();
    OH_GamePad_RightTrigger_UnregisterAxisInputMonitor();
    mdiag::Log("pad", "gamepad monitors unregistered");
}

} // namespace gamepad
