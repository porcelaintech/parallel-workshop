Unicode true
!include "MUI2.nsh"

!ifndef VERSION
  !define VERSION "0.6.0"
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
VIProductVersion "${VERSION}.0"
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

Section "Install"
  SetShellVarContext current
  SetOutPath "$INSTDIR"

  ; 先停掉旧服务，避免覆盖正在运行的 server.mjs。
  IfFileExists "$INSTDIR\stop.ps1" 0 +2
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\stop.ps1"'

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
  IfFileExists "$INSTDIR\stop.ps1" 0 +2
    nsExec::ExecToLog 'powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$INSTDIR\stop.ps1"'

  Delete "$DESKTOP\${SHORTCUT_NAME}.lnk"
  Delete "$SMPROGRAMS\${SHORTCUT_NAME}\${SHORTCUT_NAME}.lnk"
  RMDir "$SMPROGRAMS\${SHORTCUT_NAME}"
  DeleteRegKey HKCU "Software\Microsoft\Windows\CurrentVersion\Uninstall\Braintrust"
  DeleteRegKey HKCU "Software\Braintrust"
  RMDir /r "$INSTDIR"
SectionEnd
