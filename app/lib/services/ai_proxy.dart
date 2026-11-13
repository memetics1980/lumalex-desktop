import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';

enum AiProxyMode { system, manual, direct }

AiProxyMode aiProxyModeFromStorage(String? value) =>
    AiProxyMode.values.firstWhere(
      (mode) => mode.name == value,
      orElse: () => AiProxyMode.system,
    );

final class AiProxyException implements Exception {
  const AiProxyException(this.message);
  final String message;
}

bool isLocalAiHost(String host) {
  final normalized = host.toLowerCase().replaceAll(RegExp(r'^\[|\]$'), '');
  return normalized == 'localhost' ||
      normalized.endsWith('.localhost') ||
      normalized == '::1' ||
      (InternetAddress.tryParse(normalized)?.type == InternetAddressType.IPv4 &&
          normalized.startsWith('127.'));
}

/// Only HTTP proxies are understood by dart:io's PROXY directive. HTTPS API
/// traffic uses CONNECT and retains end-to-end certificate verification.
String httpAiProxyDirective(String address) {
  final value = address.trim();
  final uri = Uri.tryParse(value.contains('://') ? value : 'http://$value');
  if (uri == null ||
      uri.scheme != 'http' ||
      uri.host.isEmpty ||
      !RegExp(r':\d+/?$').hasMatch(value) ||
      uri.port < 1 ||
      uri.port > 65535 ||
      uri.userInfo.isNotEmpty ||
      (uri.path.isNotEmpty && uri.path != '/') ||
      uri.hasQuery ||
      uri.hasFragment ||
      RegExp(r'[\s;]').hasMatch(uri.host)) {
    throw const AiProxyException(
      '请填写 HTTP／混合代理地址和端口，例如 http://127.0.0.1:7890；'
      '暂不支持 SOCKS、HTTPS 代理或需要账号密码的代理。',
    );
  }
  final host = uri.host.contains(':') ? '[${uri.host}]' : uri.host;
  return 'PROXY $host:${uri.port}';
}

bool _matchesBypass(Uri url, String pattern) {
  final rule = pattern.trim().toLowerCase();
  if (rule.isEmpty) return false;
  final host = url.host.toLowerCase();
  if (rule == '<local>') return !host.contains('.') && !host.contains(':');
  final expression =
      RegExp('^${RegExp.escape(rule).replaceAll(r'\*', '.*')}\$');
  return expression.hasMatch(host) || expression.hasMatch('$host:${url.port}');
}

/// Windows exposes a single proxy or a per-protocol list, plus bypass rules.
String windowsAiProxyDirective(Uri url, Map<Object?, Object?> config) {
  final bypass = config['bypass'] as String? ?? '';
  if (bypass.split(RegExp(r'[;,]')).any((rule) => _matchesBypass(url, rule))) {
    return 'DIRECT';
  }
  final server = (config['server'] as String? ?? '').trim();
  if (server.isNotEmpty) {
    if (!server.contains('=')) return httpAiProxyDirective(server);
    final entries = <String, String>{};
    for (final item in server.split(';')) {
      final separator = item.indexOf('=');
      if (separator > 0) {
        entries[item.substring(0, separator).trim().toLowerCase()] =
            item.substring(separator + 1).trim();
      }
    }
    final address = entries[url.scheme];
    if (address != null && address.isNotEmpty) {
      return httpAiProxyDirective(address);
    }
    if (entries.containsKey('socks')) {
      throw const AiProxyException('系统仅配置了 SOCKS 代理，请改用手动代理并填写 HTTP／混合端口。');
    }
  }
  if (config['autoConfig'] == true) {
    throw const AiProxyException('系统使用 PAC 自动代理，请改用手动代理并填写代理软件的 HTTP／混合端口。');
  }
  return 'DIRECT';
}

Future<Map<Object?, Object?>> _loadSystemProxy(Uri url) async {
  if (!Platform.isWindows && !Platform.isMacOS) return const {};
  final channel = MethodChannel(Platform.isMacOS
      ? 'local_dictionary/macos_screen_lookup'
      : 'local_dictionary/windows_screen_lookup');
  try {
    final config = await channel.invokeMapMethod<Object?, Object?>(
      'getAiProxySettings',
      <String, Object>{'url': url.toString()},
    ).timeout(const Duration(seconds: 3));
    if (config == null) throw const AiProxyException('无法读取系统代理，请改用手动代理。');
    return config;
  } on MissingPluginException {
    throw const AiProxyException('当前版本无法读取系统代理，请改用手动代理或更新应用。');
  } on PlatformException {
    throw const AiProxyException('无法读取系统代理，请改用手动代理并填写 HTTP／混合端口。');
  } on TimeoutException {
    throw const AiProxyException('读取系统代理超时，请改用手动代理。');
  }
}

final class AiProxyResolver {
  AiProxyResolver({
    Future<Map<Object?, Object?>> Function(Uri)? loadSystemProxy,
    Map<String, String>? environment,
  })  : _load = loadSystemProxy ?? _loadSystemProxy,
        _environment = environment ?? Platform.environment;

  final Future<Map<Object?, Object?>> Function(Uri) _load;
  final Map<String, String> _environment;

  Future<String> resolve(Uri url, AiProxyMode mode, String address) async {
    if (isLocalAiHost(url.host) || mode == AiProxyMode.direct) return 'DIRECT';
    if (mode == AiProxyMode.manual) return httpAiProxyDirective(address);

    // GUI launches usually have no proxy environment variables. Consult the
    // native desktop settings too; do not assume shell settings reach the app.
    final envAddress = _environment['${url.scheme}_proxy'] ??
        _environment['${url.scheme.toUpperCase()}_PROXY'] ??
        _environment['all_proxy'] ??
        _environment['ALL_PROXY'];
    if (envAddress != null && envAddress.trim().isNotEmpty) {
      final bypass = _environment['no_proxy'] ?? _environment['NO_PROXY'] ?? '';
      if (bypass.split(',').any((rule) {
        final value = rule.trim().toLowerCase();
        if (value == '*') return true;
        if (value.isEmpty) return false;
        final host = url.host.toLowerCase();
        final suffix = value.startsWith('.') ? value.substring(1) : value;
        return host == suffix || host.endsWith('.$suffix');
      })) {
        return 'DIRECT';
      }
      return httpAiProxyDirective(envAddress);
    }

    final config = await _load(url);
    final unsupported = config['unsupported'];
    if (unsupported != null) {
      throw AiProxyException(
        '系统使用 $unsupported 代理，请改用手动代理并填写代理软件的 HTTP／混合端口。',
      );
    }
    if (config['direct'] == true) return 'DIRECT';
    return windowsAiProxyDirective(url, config);
  }
}
