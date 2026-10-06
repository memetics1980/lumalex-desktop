import 'dart:io';

/// Shared desktop behavior; native channels remain separate for each host.
bool get isLumaLexDesktop => Platform.isWindows || Platform.isMacOS;
String get desktopPlatformName => Platform.isMacOS ? 'macOS' : 'Windows';
String get desktopCredentialStore =>
    Platform.isMacOS ? 'macOS 钥匙串' : 'Windows 安全凭据';
String get desktopBackgroundLocation => Platform.isMacOS ? '菜单栏' : '托盘';
String get desktopEditionLabel =>
    Platform.isMacOS ? 'macOS 桌面版' : 'Windows 便携版';
