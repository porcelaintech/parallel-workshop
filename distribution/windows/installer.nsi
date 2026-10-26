Unicode true
!include "MUI2.nsh"

!ifndef VERSION
  !define VERSION "0.6.0"
!endif
!ifndef NUMERIC_VERSION
  !define NUMERIC_VERSION "0.6.0.0"
!endif

!define APP_NAME "智囊"
!define APP_ID "Braintrust"
!define APP_PUBLISHER "Braintrust"
!define SHORTCUT_NAME "Braintrust"

Name "${APP_NAME}"
OutFile "Braintrust-Setup-${VERSION}.exe"
InstallDir "$LOCALAPPDATA\Braintrust"
InstallDirRegKey HKCU "Software\Braintrust" "InstallDir"
RequestExecutionLevel user
SetCompressor /SOLID lzma
SetCompressorDictSize 32
XPStyle on
ManifestDPIAware true
Icon "assets\AppIcon.ico"
UninstallIcon "assets\AppIcon.ico"
BrandingText "${APP_NAME} · Braintrust"
VIProductVersion "${NUMERIC_VERSION}"
VIAddVersionKey "ProductName" "${APP_NAME}"
VIAddVersionKey "CompanyName" "${APP_PUBLISHER}"
VIAddVersionKey "FileDescription" "${APP_NAME} 安装程序"
VIAddVersionKey "FileVersion" "${VERSION}"
VIAddVersionKey "ProductVersion" "${VERSION}"

!define MUI_ABORTWARNING
!define MUI_ICON "assets\AppIcon.ico"
!define MUI_UNICON "assets\AppIcon.ico"
!insertmacro MUI_PAGE_WELCOME
!insertmacro MUI_PAGE_INSTFILES
!insertmacro MUI_PAGE_FINISH

!insertmacro MUI_LANGUAGE "SimpChinese"
!insertmacro MUI_LANGUAGE "English"

Function .onInstSuccess
  IfSilent done
  Exec '"$WINDIR\System32\wscript.exe" "$INSTDIR\service\launcher.vbs"'
  done:
FunctionEnd

; Use the stop helper carried by this installer, including when upgrading an old release.
; Its ServiceRoot argument also supports an existing custom installation directory.
!macro StopInstalledService FUNCTION_NAME
Function ${FUNCTION_NAME}
  InitPluginsDir
  SetOutPath "$PLUGINSDIR"
  File /oname=braintrust-stop.ps1 "payload\stop.ps1"
  nsExec::ExecToStack /TIMEOUT=30000 '"$SYSDIR\WindowsPowerShell\v1.0\powershell.exe" -NoLogo -NoProfile -NonInteractive -ExecutionPolicy Bypass -File "$PLUGINSDIR\braintrust-stop.ps1" -ServiceRoot "$INSTDIR\service"'
  Pop $0
  Pop $1
  StrCmp $0 "0" stopped
    DetailPrint "$1"
    MessageBox MB_ICONSTOP|MB_OK "无法停止正在运行的智囊。请关闭智囊后重试。" /SD IDOK
    SetErrorLevel 1
    Abort
  stopped:
FunctionEnd
!macroend
!insertmacro StopInstalledService StopInstalledService
!insertmacro StopInstalledService un.StopInstalledService

Section "Install"
  SetShellVarContext current
  Call StopInstalledService
  SetOutPath "$INSTDIR"

  WriteUninstaller "$INSTDIR\Uninstall.exe"

  SetOutPath "$INSTDIR\service"
  File /r "payload\service\*.*"
  File "payload\launcher.ps1"
  File "payload\stop.ps1"

  SetOutPath "$INSTDIR\service\assets"
  File "payload\assets\AppIcon.ico"

  ; 无控制台启动入口
  SetOutPath "$INSTDIR\service"
  File "payload\launcher.vbs"

  SetOutPath "$INSTDIR"
  CreateDirectory "$SMPROGRAMS\${SHORTCUT_NAME}"
  CreateShortcut "$SMPROGRAMS\${SHORTCUT_NAME}\${SHORTCUT_NAME}.lnk" "$WINDIR\System32\wscript.exe" '"$INSTDIR\service\launcher.vbs"' "$INSTDIR\service\assets\AppIcon.ico" 0 SW_SHOWNORMAL
  CreateShortcut "$DESKTOP\${SHORTCUT_NAME}.lnk" "$WINDIR\System32\wscript.exe" '"$INSTDIR\service\launcher.vbs"' "$INSTDIR\service\assets\AppIcon.ico" 0 SW_SHOWNORMAL

  WriteRegStr HKCU "Software\Braintrust" "InstallDir" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust" "DisplayName" "${APP_NAME}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust" "DisplayIcon" "$INSTDIR\service\assets\AppIcon.ico"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust" "DisplayVersion" "${VERSION}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust" "Publisher" "${APP_PUBLISHER}"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust" "InstallLocation" "$INSTDIR"
  WriteRegStr HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust" "UninstallString" '"$INSTDIR\Uninstall.exe"'
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust" "NoModify" 1
  WriteRegDWORD HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust" "NoRepair" 1
SectionEnd

Section "Uninstall"
  SetShellVarContext current
  Call un.StopInstalledService

  Delete "$DESKTOP\${SHORTCUT_NAME}.lnk"
  Delete "$SMPROGRAMS\${SHORTCUT_NAME}\${SHORTCUT_NAME}.lnk"
  RMDir "$SMPROGRAMS\${SHORTCUT_NAME}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust"
  DeleteRegKey HKCU "Software\Braintrust"
  ; Browser profiles, login state, data and logs survive uninstall/reinstall.
  SetOutPath "$TEMP"
  RMDir /r "$INSTDIR\service"
  Delete "$INSTDIR\Uninstall.exe"
  RMDir "$INSTDIR"
SectionEnd
