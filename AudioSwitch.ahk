;==================================================================================
;  AUDIO SWITCH  —  swap your Windows output device with one hotkey
;  by Mickey Perry  ·  https://mickeyperry.github.io/
;  AutoHotkey v1.1 (Unicode).  Compile with Ahk2Exe for a standalone .exe.
;==================================================================================

#NoEnv
#SingleInstance, Force
SetBatchLines, -1
SetWorkingDir, %A_ScriptDir%

; ---- Compiled .exe version info (so Windows shows "Audio Switch", not "AutoHotkey") ----
;@Ahk2Exe-SetName        Audio Switch
;@Ahk2Exe-SetDescription Audio Switch
;@Ahk2Exe-SetProductName Audio Switch
;@Ahk2Exe-SetCompanyName Mickey Perry
;@Ahk2Exe-SetVersion     1.1.0
;@Ahk2Exe-SetCopyright   Mickey Perry

;--- Branding ---------------------------------------------------------------------
global APP_NAME    := "Audio Switch"
global APP_SITE    := "https://mickeyperry.github.io/"
global COL_BG      := "0d0d14"   ; window background
global COL_CARD    := "1b1b2e"   ; device card
global COL_CARDHOV := "2a2a44"   ; device card hover
global COL_PINK    := "ff2d87"   ; accent pink
global COL_PURPLE  := "b46bff"   ; accent purple
global COL_TEXT    := "f4f3f8"   ; primary text
global COL_SUB     := "a0a0b2"   ; secondary text

;--- Paths ------------------------------------------------------------------------
global CfgDir  := A_AppData . "\AudioSwitch"
global CfgFile := CfgDir . "\settings.ini"
; When compiled, the icon is embedded in the .exe (use it directly so we ship one file).
; When running as a .ahk, use the loose AudioSwitch.ico next to the script.
global IconFile := A_IsCompiled ? A_ScriptFullPath : (A_ScriptDir . "\AudioSwitch.ico")

global COL_GLOW    := "ff7bd0"   ; bright pink for hover/press glow

;--- State ------------------------------------------------------------------------
global DeviceList  := []
global DeviceMap   := {}
global CurrentHotkey := ""

; Picker runtime state
global PickerHwnd  := 0
global CtrlAction  := {}   ; control hwnd -> "card:N" | "title" | "cancel" | "close"
global CardPic     := {}   ; index -> Picture control hwnd
global CardBmpN    := {}   ; index -> normal bitmap handle
global CardBmpG    := {}   ; index -> hover/glow bitmap handle
global CardBmps    := []   ; all bitmap handles (for cleanup)
global CardCount   := 0
global HoverIdx    := 0
global PickerOpen  := false
global TitleBarH   := 46
global PickerW     := 420

;==================================================================================
;  STARTUP
;==================================================================================
if !FileExist(CfgDir)
    FileCreateDir, %CfgDir%

LoadSettings()
BuildTray()
RegisterHotkey(CurrentHotkey)

; Mouse hooks for the picker (hover glow + reliable clicks + window drag)
OnMessage(0x200, "Picker_MouseMove")   ; WM_MOUSEMOVE
OnMessage(0x201, "Picker_LButtonDown") ; WM_LBUTTONDOWN

if (A_Args.Length() = 0)
{
    IniRead, seen, %CfgFile%, App, FirstRunDone, 0
    if (seen != 1)
    {
        TrayTip, %APP_NAME%, % "Press " . PrettyHotkey(CurrentHotkey) . " to switch audio output.`nRight-click the tray icon for settings.", 5
        IniWrite, 1, %CfgFile%, App, FirstRunDone
    }
    else
        TrayTip, %APP_NAME%, % "Running. Press " . PrettyHotkey(CurrentHotkey) . " to switch output.", 2
}
return

;==================================================================================
;  TRAY
;==================================================================================
BuildTray() {
    global
    Menu, Tray, NoStandard
    Menu, Tray, Add, % "Switch Audio Output`t" . PrettyHotkey(CurrentHotkey), TrayOpen
    Menu, Tray, Add
    Menu, Tray, Add, Settings…, TraySettings
    Menu, Tray, Add, About, TrayAbout
    Menu, Tray, Add
    Menu, Tray, Add, Exit, TrayExit
    Menu, Tray, Default, % "Switch Audio Output`t" . PrettyHotkey(CurrentHotkey)
    if FileExist(IconFile)
        Menu, Tray, Icon, %IconFile%
    Menu, Tray, Tip, %APP_NAME%
}

RefreshTray() {
    ; rebuild so the hotkey shown in the menu stays in sync
    Menu, Tray, DeleteAll
    BuildTray()
}

TrayOpen:
    ShowDevicePicker()
return

TraySettings:
    ShowSettings()
return

TrayAbout:
    ShowAbout()
return

TrayExit:
    ExitApp
return

HotkeyHandler:
    ShowDevicePicker()
return

;==================================================================================
;  SETTINGS  (read / write / hotkey registration)
;==================================================================================
LoadSettings() {
    global CfgFile, CurrentHotkey
    IniRead, hk, %CfgFile%, Hotkey, Combo, F12
    if (hk = "" or hk = "ERROR")
        hk := "F12"
    CurrentHotkey := hk
}

RegisterHotkey(hk) {
    global CurrentHotkey
    ; turn off the previously bound key
    if (CurrentHotkey != "") {
        try {
            Hotkey, %CurrentHotkey%, HotkeyHandler, Off
        }
    }
    CurrentHotkey := hk
    try {
        Hotkey, %hk%, HotkeyHandler, On
    } catch e {
        MsgBox, 48, %APP_NAME%, % "Couldn't register the shortcut '" . PrettyHotkey(hk) . "'.`nFalling back to F12."
        CurrentHotkey := "F12"
        Hotkey, F12, HotkeyHandler, On
    }
}

; Build an AHK hotkey string from modifier flags + a key token
MakeHotkey(ctrl, alt, shift, win, key) {
    mods := ""
    if (ctrl)
        mods .= "^"
    if (alt)
        mods .= "!"
    if (shift)
        mods .= "+"
    if (win)
        mods .= "#"
    return mods . key
}

; Human-readable shortcut for menus / tooltips:  ^!F12 -> "Ctrl+Alt+F12"
PrettyHotkey(hk) {
    out := ""
    i := 1
    Loop {
        c := SubStr(hk, i, 1)
        if (c = "^")
            out .= "Ctrl+"
        else if (c = "!")
            out .= "Alt+"
        else if (c = "+")
            out .= "Shift+"
        else if (c = "#")
            out .= "Win+"
        else
            break
        i++
    }
    return out . SubStr(hk, i)
}

;==================================================================================
;  DEVICE PICKER GUI
;==================================================================================
ShowDevicePicker() {
    global DeviceList, DeviceMap, APP_NAME, PickerHwnd, PickerW, TitleBarH
    global CtrlAction, CardPic, CardBmpN, CardBmpG, CardBmps, CardCount, HoverIdx, PickerOpen
    global COL_BG, COL_CARD, COL_CARDHOV, COL_PINK, COL_PURPLE, COL_TEXT, COL_SUB, COL_GLOW

    if (PickerOpen) {
        ClosePicker()
        return
    }

    DeviceList := []
    DeviceMap  := {}

    psFile  := A_Temp . "\as_get.ps1"
    outFile := A_Temp . "\as_devices.txt"
    FileDelete, %psFile%
    FileDelete, %outFile%

    FileAppend,
(
param([string]$OutPath)
$r = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\MMDevices\Audio\Render'
$rows = @()
Get-ChildItem $r | ForEach-Object {
    $state = (Get-ItemProperty $_.PSPath -EA SilentlyContinue).DeviceState
    $props = Get-ItemProperty "$($_.PSPath)\Properties" -EA SilentlyContinue
    $n = $props.'{a45c254e-df1c-4efd-8020-67d146a850e0},2'
    $g = $_.PSChildName
    if ($n -and $state -eq 1) { $rows += "$n|$g" }
}
$rows | Out-File -FilePath $OutPath -Encoding UTF8
), %psFile%

    RunWait, powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%psFile%" -OutPath "%outFile%",, Hide
    Sleep, 80
    FileRead, content, %outFile%
    FileDelete, %psFile%
    FileDelete, %outFile%

    if (content = "") {
        MsgBox, 48, %APP_NAME%, No active audio devices found.`nMake sure at least one output device is enabled.
        return
    }

    Loop, Parse, content, `n, `r
    {
        line := Trim(A_LoopField)
        if (line = "")
            continue
        StringSplit, p, line, |
        if (p0 < 2)
            continue
        devName := p1
        devGuid := p2
        if DeviceMap.HasKey(devName)
            continue
        DeviceList.Push({name: devName, guid: devGuid})
        DeviceMap[devName] := devGuid
    }

    ; reset picker state
    CtrlAction := {}
    CardFrame  := {}
    CardBg     := {}
    HoverIdx   := 0
    W := PickerW

    Gui, Picker:Destroy
    Gui, Picker:New, +AlwaysOnTop +ToolWindow -Caption +Border +HwndPickerHwnd
    Gui, Picker:Margin, 0, 0
    Gui, Picker:Color, %COL_BG%

    ; ---- top section (draggable header) ----
    Gui, Picker:Add, Progress, % "x0 y0 w" W " h" TitleBarH " Background" COL_CARD " c" COL_CARD " hwndhTitle", 0
    Gui, Picker:Add, Progress, % "x0 y0 w" W " h3 Background" COL_PINK " c" COL_PINK " hwndhStrip", 0
    CtrlAction[hTitle] := "title"
    CtrlAction[hStrip] := "title"

    Gui, Picker:Font, s12 w700, Segoe UI
    Gui, Picker:Add, Text, % "x18 y13 w300 BackgroundTrans c" COL_PINK " hwndhTitleTx", AUDIO SWITCH
    CtrlAction[hTitleTx] := "title"

    ; close (X) hit area + glyph
    Gui, Picker:Add, Progress, % "x" (W-42) " y8 w32 h30 Background" COL_CARD " c" COL_CARD " hwndhClose", 0
    CtrlAction[hClose] := "close"
    Gui, Picker:Font, s13 w400, Segoe UI
    Gui, Picker:Add, Text, % "x" (W-40) " y9 w28 h28 +0x200 Center BackgroundTrans c" COL_SUB " hwndhXg", ✕
    CtrlAction[hXg] := "close"

    Gui, Picker:Font, s9 w400, Segoe UI
    Gui, Picker:Add, Text, % "x18 y" (TitleBarH+10) " w372 BackgroundTrans c" COL_SUB, Pick your output device

    yPos  := TitleBarH + 40
    count := DeviceList.Length()
    CardCount := count

    ; each card is a single Picture with a baked bitmap (no overlapping controls -> no repaint bugs).
    ; bitmaps are rendered at physical pixel size so they stay crisp on high-DPI displays.
    scale := A_ScreenDPI / 96.0
    cwP := Round(384 * scale)
    chP := Round(46 * scale)

    Loop % count
    {
        dev := DeviceList[A_Index]
        i := A_Index
        bmpN := MakeCardBmp(cwP, chP, COL_CARD, COL_PINK, "",       COL_TEXT, dev.name, scale)
        bmpG := MakeCardBmp(cwP, chP, COL_CARD, COL_PINK, COL_GLOW, COL_TEXT, dev.name, scale)
        ; +0x100 = SS_NOTIFY so the static Picture receives hover/click messages
        Gui, Picker:Add, Picture, % "x18 y" yPos " w384 h46 +0x100 hwndhCard", % "HBITMAP:*" bmpN
        CtrlAction[hCard] := "card:" . i
        CardPic[i]  := hCard
        CardBmpN[i] := bmpN
        CardBmpG[i] := bmpG
        CardBmps.Push(bmpN)
        CardBmps.Push(bmpG)
        yPos += 56
    }

    yPos += 6
    ; ---- cancel row ----
    Gui, Picker:Add, Progress, % "x18 y" yPos " w384 h38 Background" COL_BG " c" COL_BG " hwndhCancel", 0
    CtrlAction[hCancel] := "cancel"
    Gui, Picker:Font, s10 w600, Segoe UI
    Gui, Picker:Add, Text, % "x40 y" yPos " w356 h38 +0x200 BackgroundTrans c" COL_SUB " hwndhCanLbl", ✕   Cancel
    CtrlAction[hCanLbl] := "cancel"
    yPos += 48

    H := yPos

    ; ---- show off-screen to measure, place near cursor (clamped to monitor), then scale-pop in ----
    Gui, Picker:+LastFound
    Gui, Picker:Show, % "NA x-6000 y0 w" W " h" H, %APP_NAME%
    WinGetPos, , , pW, pH, ahk_id %PickerHwnd%

    CoordMode, Mouse, Screen
    MouseGetPos, mx, my
    GetWorkAreaAt(mx, my, waL, waT, waR, waB)
    tx := mx - 46
    ty := my - 18
    if (tx + pW > waR)
        tx := waR - pW - 6
    if (tx < waL)
        tx := waL + 6
    if (ty + pH > waB)
        ty := waB - pH - 6
    if (ty < waT)
        ty := waT + 6

    ; snap it onto the cursor, fully painted (reliable pop — no alpha, no blank frames)
    WinMove, ahk_id %PickerHwnd%, , tx, ty
    WinActivate, ahk_id %PickerHwnd%
    PickerOpen := true
    return
}

; --- mouse hooks (only act on the picker's controls) ---
Picker_MouseMove(wParam, lParam, msg, hwnd) {
    global PickerOpen, CtrlAction, CardPic, CardBmpN, CardBmpG, HoverIdx
    if (!PickerOpen)
        return
    idx := 0
    if (CtrlAction.HasKey(hwnd)) {
        act := CtrlAction[hwnd]
        if (SubStr(act, 1, 5) = "card:")
            idx := SubStr(act, 6) + 0
    }
    if (idx = HoverIdx)
        return
    ; swap the whole card bitmap (one control, no overlap -> always repaints cleanly)
    if (HoverIdx)
        GuiControl, Picker:, % CardPic[HoverIdx], % "HBITMAP:*" CardBmpN[HoverIdx]
    HoverIdx := idx
    if (idx)
        GuiControl, Picker:, % CardPic[idx], % "HBITMAP:*" CardBmpG[idx]
}

Picker_LButtonDown(wParam, lParam, msg, hwnd) {
    global PickerOpen, CtrlAction, DeviceList, PickerHwnd
    if (!PickerOpen)
        return
    if (!CtrlAction.HasKey(hwnd))
        return
    act := CtrlAction[hwnd]
    if (act = "title") {
        DllCall("ReleaseCapture")
        PostMessage, 0xA1, 2, 0, , ahk_id %PickerHwnd%   ; WM_NCLBUTTONDOWN / HTCAPTION -> drag
        return
    }
    if (act = "close" || act = "cancel") {
        ClosePicker()
        return
    }
    if (SubStr(act, 1, 5) = "card:") {
        idx := SubStr(act, 6) + 0
        dev := DeviceList[idx]
        PressPulse(idx)
        ClosePicker()
        SwitchTo(dev.name)
    }
}

PressPulse(idx) {
    global CardPic, CardBmpN, CardBmpG
    pic := CardPic[idx]
    Loop, 2 {
        GuiControl, Picker:, %pic%, % "HBITMAP:*" CardBmpG[idx]
        Sleep, 55
        GuiControl, Picker:, %pic%, % "HBITMAP:*" CardBmpN[idx]
        Sleep, 45
    }
    GuiControl, Picker:, %pic%, % "HBITMAP:*" CardBmpG[idx]
    Sleep, 60
}

ClosePicker() {
    global PickerOpen, HoverIdx, CardBmps
    PickerOpen := false
    HoverIdx   := 0
    Gui, Picker:Destroy
    ; free the baked card bitmaps
    for k, b in CardBmps
        DllCall("DeleteObject", "ptr", b)
    CardBmps := []
}

; ---- GDI helpers: render a device card to a bitmap ----
GdiRGB(hex) {
    r := "0x" . SubStr(hex, 1, 2)
    g := "0x" . SubStr(hex, 3, 2)
    b := "0x" . SubStr(hex, 5, 2)
    return ((b + 0) << 16) | ((g + 0) << 8) | (r + 0)
}

GdiFill(dc, x, y, w, h, hex) {
    br := DllCall("CreateSolidBrush", "uint", GdiRGB(hex), "ptr")
    VarSetCapacity(rc, 16, 0)
    NumPut(x, rc, 0, "int"), NumPut(y, rc, 4, "int"), NumPut(x + w, rc, 8, "int"), NumPut(y + h, rc, 12, "int")
    DllCall("FillRect", "ptr", dc, "ptr", &rc, "ptr", br)
    DllCall("DeleteObject", "ptr", br)
}

MakeCardBmp(w, h, bgHex, accentHex, glowHex, txtHex, txt, scale) {
    hdc := DllCall("GetDC", "ptr", 0, "ptr")
    mdc := DllCall("CreateCompatibleDC", "ptr", hdc, "ptr")
    hbm := DllCall("CreateCompatibleBitmap", "ptr", hdc, "int", w, "int", h, "ptr")
    obm := DllCall("SelectObject", "ptr", mdc, "ptr", hbm, "ptr")

    GdiFill(mdc, 0, 0, w, h, bgHex)
    inset := 0
    if (glowHex != "") {
        b := Round(3 * scale)
        GdiFill(mdc, 0, 0, w, h, glowHex)       ; glow ring
        GdiFill(mdc, b, b, w - 2 * b, h - 2 * b, bgHex)
        inset := b
    }
    aw := Round(5 * scale)
    GdiFill(mdc, inset, inset, aw, h - 2 * inset, accentHex)   ; pink accent bar

    fh := -Round(19 * scale)
    hFont := DllCall("CreateFont", "int", fh, "int", 0, "int", 0, "int", 0, "int", 600
        , "uint", 0, "uint", 0, "uint", 0, "uint", 1, "uint", 0, "uint", 0, "uint", 4, "uint", 0
        , "str", "Segoe UI", "ptr")
    ofont := DllCall("SelectObject", "ptr", mdc, "ptr", hFont, "ptr")
    DllCall("SetBkMode", "ptr", mdc, "int", 1)                 ; TRANSPARENT
    DllCall("SetTextColor", "ptr", mdc, "uint", GdiRGB(txtHex))
    VarSetCapacity(trc, 16, 0)
    pad := Round(22 * scale)
    NumPut(pad, trc, 0, "int"), NumPut(0, trc, 4, "int"), NumPut(w, trc, 8, "int"), NumPut(h, trc, 12, "int")
    DllCall("DrawText", "ptr", mdc, "str", txt, "int", -1, "ptr", &trc, "uint", 0x24)  ; DT_LEFT|DT_VCENTER|DT_SINGLELINE
    DllCall("SelectObject", "ptr", mdc, "ptr", ofont)
    DllCall("DeleteObject", "ptr", hFont)

    DllCall("SelectObject", "ptr", mdc, "ptr", obm)
    DllCall("DeleteDC", "ptr", mdc)
    DllCall("ReleaseDC", "ptr", 0, "ptr", hdc)
    return hbm
}

; Work area of the monitor under the given screen point (clamps the popup on-screen)
GetWorkAreaAt(mx, my, ByRef L, ByRef T, ByRef R, ByRef B) {
    SysGet, cnt, MonitorCount
    Loop, %cnt% {
        SysGet, m, MonitorWorkArea, %A_Index%
        if (mx >= mLeft && mx < mRight && my >= mTop && my < mBottom) {
            L := mLeft, T := mTop, R := mRight, B := mBottom
            return
        }
    }
    SysGet, m, MonitorWorkArea
    L := mLeft, T := mTop, R := mRight, B := mBottom
}

PickerGuiClose:
PickerGuiEscape:
    ClosePicker()
return

SwitchTo(devName) {
    global DeviceMap, APP_NAME
    if !DeviceMap.HasKey(devName)
        return
    devGuid := DeviceMap[devName]

    psSwitch := A_Temp . "\as_set.ps1"
    FileDelete, %psSwitch%
    FileAppend,
(
param([string]$g)
Add-Type @'
using System;
using System.Runtime.InteropServices;
[ComImport, Guid("568b9108-44bf-40b4-9006-86afe5b5a620"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
interface IPolicyConfigVista {
    void a(); void b(); void c(); void d(); void e();
    void f(); void g(); void h(); void i();
    int SetDefaultEndpoint([MarshalAs(UnmanagedType.LPWStr)] string id, uint role);
    void k();
}
[ComImport, Guid("294935CE-F637-4E7C-A41B-AB255460B862")]
class CPolicyConfigVistaClient {}
public static class AudioSwitch {
    public static void SetDefault(string guid) {
        string id = "{0.0.0.00000000}." + guid.ToLower();
        IPolicyConfigVista cfg = (IPolicyConfigVista)(new CPolicyConfigVistaClient());
        cfg.SetDefaultEndpoint(id, 0);
        cfg.SetDefaultEndpoint(id, 1);
        cfg.SetDefaultEndpoint(id, 2);
    }
}
'@
[AudioSwitch]::SetDefault($g)
), %psSwitch%

    RunWait, powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%psSwitch%" -g "%devGuid%",, Hide
    FileDelete, %psSwitch%
    TrayTip, % APP_NAME . " — switched", %devName%, 1
}

;==================================================================================
;  SETTINGS GUI
;==================================================================================
ShowSettings() {
    global CurrentHotkey, COL_BG, COL_CARD, COL_PINK, COL_TEXT, COL_SUB, APP_NAME, CfgFile

    ; parse current hotkey into pieces
    ctrl := alt := shift := win := 0
    i := 1
    Loop {
        c := SubStr(CurrentHotkey, i, 1)
        if (c = "^")
            ctrl := 1
        else if (c = "!")
            alt := 1
        else if (c = "+")
            shift := 1
        else if (c = "#")
            win := 1
        else
            break
        i++
    }
    curKey := SubStr(CurrentHotkey, i)

    keyList := "F1|F2|F3|F4|F5|F6|F7|F8|F9|F10|F11|F12|Insert|Home|End|PgUp|PgDn|Space|Esc|Enter|Tab|Delete|"
             . "A|B|C|D|E|F|G|H|I|J|K|L|M|N|O|P|Q|R|S|T|U|V|W|X|Y|Z|0|1|2|3|4|5|6|7|8|9"
    keyOpts := ""
    Loop, Parse, keyList, |
    {
        if (A_LoopField = curKey)
            keyOpts .= A_LoopField . "||"
        else
            keyOpts .= A_LoopField . "|"
    }
    if !InStr("|" . keyList . "|", "|" . curKey . "|")  ; current key not in list -> default select
        StringReplace, keyOpts, keyOpts, F12|, F12||

    IniRead, startup, %CfgFile%, App, RunAtStartup, 0

    Gui, Settings:Destroy
    Gui, Settings:New, +AlwaysOnTop +ToolWindow
    Gui, Settings:Color, %COL_BG%

    ; top accent strip
    Gui, Settings:Add, Progress, x0 y0 w430 h4 Background%COL_PINK% c%COL_PINK%, 0

    Gui, Settings:Font, s14 w700, Segoe UI
    Gui, Settings:Add, Text, x26 y22 c%COL_PINK%, Settings

    Gui, Settings:Font, s10 w400, Segoe UI
    Gui, Settings:Add, Text, x26 y58 c%COL_SUB%, Shortcut to open the switcher:

    Gui, Settings:Font, s10 w500, Segoe UI
    Gui, Settings:Add, Checkbox, x26  y92 w62 c%COL_TEXT% vS_Ctrl  Checked%ctrl%,  Ctrl
    Gui, Settings:Add, Checkbox, x94  y92 w58 c%COL_TEXT% vS_Alt   Checked%alt%,   Alt
    Gui, Settings:Add, Checkbox, x156 y92 w70 c%COL_TEXT% vS_Shift Checked%shift%, Shift
    Gui, Settings:Add, Checkbox, x230 y92 w62 c%COL_TEXT% vS_Win   Checked%win%,   Win

    Gui, Settings:Add, Text, x26 y132 w34 h26 +0x200 c%COL_SUB%, Key
    Gui, Settings:Add, DropDownList, x64 y128 w130 vS_Key, %keyOpts%

    Gui, Settings:Add, Checkbox, x26 y176 w380 c%COL_TEXT% vS_Startup Checked%startup%, Start automatically with Windows

    Gui, Settings:Font, s10 w600, Segoe UI
    Gui, Settings:Add, Button, x26  y218 w130 h36 gSettingsSave Default, Save
    Gui, Settings:Add, Button, x166 y218 w130 h36 gSettingsCancel, Cancel

    Gui, Settings:Show, w430 h280, %APP_NAME% — Settings
}

SettingsSave:
    Gui, Settings:Submit, NoHide
    newHk := MakeHotkey(S_Ctrl, S_Alt, S_Shift, S_Win, S_Key)
    if (S_Key = "") {
        MsgBox, 48, %APP_NAME%, Please choose a key.
        return
    }
    IniWrite, %newHk%, %CfgFile%, Hotkey, Combo
    IniWrite, %S_Startup%, %CfgFile%, App, RunAtStartup
    SetStartup(S_Startup)
    RegisterHotkey(newHk)
    RefreshTray()
    Gui, Settings:Destroy
    TrayTip, %APP_NAME%, % "Shortcut set to " . PrettyHotkey(newHk), 2
return

SettingsCancel:
SettingsGuiClose:
SettingsGuiEscape:
    Gui, Settings:Destroy
return

SetStartup(enable) {
    global APP_NAME
    lnk := A_Startup . "\AudioSwitch.lnk"
    if (enable) {
        FileCreateShortcut, %A_ScriptFullPath%, %lnk%, %A_ScriptDir%, , Audio Switch — switch output device
    } else {
        FileDelete, %lnk%
    }
}

;==================================================================================
;  ABOUT GUI
;==================================================================================
ShowAbout() {
    global COL_BG, COL_PINK, COL_PURPLE, COL_TEXT, COL_SUB, APP_NAME, APP_SITE, IconFile, CurrentHotkey

    Gui, About:Destroy
    Gui, About:New, +AlwaysOnTop +ToolWindow
    Gui, About:Color, %COL_BG%

    ; top accent strip
    Gui, About:Add, Progress, x0 y0 w430 h4 Background%COL_PINK% c%COL_PINK%, 0

    if FileExist(IconFile)
        Gui, About:Add, Picture, x28 y28 w64 h64, %IconFile%

    Gui, About:Font, s16 w700, Segoe UI
    Gui, About:Add, Text, x108 y36 w300 c%COL_PINK%, AUDIO SWITCH
    Gui, About:Font, norm italic s9 w400, Segoe UI
    Gui, About:Add, Text, x108 y68 w300 c%COL_SUB%, swap your sound device with one hotkey

    Gui, About:Font, norm s10 w400, Segoe UI
    Gui, About:Add, Text, x28 y112 w374 h66 c%COL_TEXT%, % "Press " . PrettyHotkey(CurrentHotkey) . " anywhere to pop up the device picker, then click an output. Change the shortcut any time from the tray menu › Settings."

    Gui, About:Font, norm s9 w400, Segoe UI
    Gui, About:Add, Text, x28 y188 w374 c%COL_SUB%, Made by Mickey Perry
    Gui, About:Font, norm s9 w600 underline, Segoe UI
    Gui, About:Add, Text, x28 y208 w200 c%COL_PURPLE% gAboutSite, mickeyperry.github.io

    Gui, About:Font, s10 w600, Segoe UI
    Gui, About:Add, Button, x28 y242 w130 h36 gAboutClose Default, Close

    Gui, About:Show, w430 h300, %APP_NAME% — About
}

AboutSite:
    Run, %APP_SITE%
return

AboutClose:
AboutGuiClose:
AboutGuiEscape:
    Gui, About:Destroy
return
