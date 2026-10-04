import 'package:flutter/material.dart';

import '../app_version.dart';
import '../platform/windows_screen_lookup.dart';
import '../services/windows_app_settings.dart';

class AppSettingsPage extends StatelessWidget {
  const AppSettingsPage({
    required this.closeBehavior,
    required this.closeBehaviorSaving,
    required this.onCloseBehaviorChanged,
    required this.screenLookupEnabled,
    required this.screenLookupSaving,
    required this.screenLookupShortcut,
    required this.onScreenLookupEnabledChanged,
    required this.onScreenLookupShortcutChanged,
    required this.screenLookupAiEnabled,
    required this.screenLookupAiSaving,
    required this.screenLookupAiKeyStored,
    required this.screenLookupAiBaseUrlController,
    required this.screenLookupAiModelController,
    required this.screenLookupAiApiKeyController,
    required this.onScreenLookupAiEnabledChanged,
    required this.onSaveScreenLookupAiSettings,
    required this.onTestScreenLookupAiSettings,
    required this.onDeleteScreenLookupAiApiKey,
    required this.textScale,
    required this.onTextScaleChanged,
    required this.onExportLearningData,
    required this.onImportLearningData,
    required this.onSaveDiagnostics,
    super.key,
  });

  final WindowsCloseBehavior closeBehavior;
  final bool closeBehaviorSaving;
  final ValueChanged<WindowsCloseBehavior> onCloseBehaviorChanged;
  final bool screenLookupEnabled;
  final bool screenLookupSaving;
  final WindowsScreenLookupShortcut screenLookupShortcut;
  final ValueChanged<bool> onScreenLookupEnabledChanged;
  final ValueChanged<WindowsScreenLookupShortcut> onScreenLookupShortcutChanged;
  final bool screenLookupAiEnabled;
  final bool screenLookupAiSaving;
  final bool screenLookupAiKeyStored;
  final TextEditingController screenLookupAiBaseUrlController;
  final TextEditingController screenLookupAiModelController;
  final TextEditingController screenLookupAiApiKeyController;
  final ValueChanged<bool> onScreenLookupAiEnabledChanged;
  final VoidCallback onSaveScreenLookupAiSettings;
  final VoidCallback onTestScreenLookupAiSettings;
  final VoidCallback onDeleteScreenLookupAiApiKey;
  final double textScale;
  final ValueChanged<double> onTextScaleChanged;
  final VoidCallback onExportLearningData;
  final VoidCallback onImportLearningData;
  final VoidCallback onSaveDiagnostics;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return ColoredBox(
      color: Theme.of(context).scaffoldBackgroundColor,
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 1120),
          child: ListView(
            key: const PageStorageKey<String>('settings-page'),
            padding: const EdgeInsets.fromLTRB(28, 26, 28, 36),
            children: [
              Text(
                '设置',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
              ),
              const SizedBox(height: 20),
              _SettingsSection(
                icon: Icons.tune_rounded,
                title: '通用',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '关闭主窗口时',
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                            fontWeight: FontWeight.w700,
                          ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      closeBehavior == WindowsCloseBehavior.hideToTray
                          ? '点击关闭按钮后，LumaLex 继续在后台运行，可从系统托盘恢复。'
                          : '点击关闭按钮后，立即退出 LumaLex 并释放内存。',
                      style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                            color: colors.onSurfaceVariant,
                            height: 1.45,
                          ),
                    ),
                    const SizedBox(height: 14),
                    SegmentedButton<WindowsCloseBehavior>(
                      key: const ValueKey('windows-close-behavior-control'),
                      segments: const [
                        ButtonSegment(
                          value: WindowsCloseBehavior.exitApp,
                          icon: Icon(Icons.power_settings_new_rounded),
                          label: Text('直接退出'),
                        ),
                        ButtonSegment(
                          value: WindowsCloseBehavior.hideToTray,
                          icon: Icon(Icons.move_to_inbox_rounded),
                          label: Text('隐藏到托盘'),
                        ),
                      ],
                      selected: {closeBehavior},
                      onSelectionChanged: closeBehaviorSaving
                          ? null
                          : (selection) =>
                              onCloseBehaviorChanged(selection.single),
                      style: const ButtonStyle(
                        minimumSize: WidgetStatePropertyAll(Size(168, 50)),
                      ),
                    ),
                    if (closeBehavior == WindowsCloseBehavior.hideToTray) ...[
                      const SizedBox(height: 12),
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            Icons.info_outline_rounded,
                            size: 19,
                            color: colors.primary,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              '首次隐藏时会显示一次系统提示。右键托盘图标可彻底退出。',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(
                                    color: colors.onSurfaceVariant,
                                  ),
                            ),
                          ),
                        ],
                      ),
                    ],
                    if (closeBehaviorSaving) ...[
                      const SizedBox(height: 14),
                      const LinearProgressIndicator(),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _SettingsSection(
                icon: Icons.auto_awesome_rounded,
                title: 'AI 语境释义',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey('windows-screen-lookup-ai-toggle'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '在取词浮窗中显示 AI 按钮',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text(
                        '适合网页等能够读取上下文的应用：点击 AI 后发送选中词及附近语境，帮助判断当前句义。复制兼容模式没有语境，因此只查词典。',
                      ),
                      value: screenLookupAiEnabled,
                      onChanged: screenLookupAiSaving
                          ? null
                          : onScreenLookupAiEnabledChanged,
                    ),
                    const SizedBox(height: 12),
                    LayoutBuilder(
                      builder: (context, constraints) {
                        final fieldWidth = constraints.maxWidth >= 760
                            ? (constraints.maxWidth - 12) / 2
                            : constraints.maxWidth;
                        return Wrap(
                          spacing: 12,
                          runSpacing: 12,
                          children: [
                            SizedBox(
                              width: fieldWidth,
                              child: TextField(
                                key: const ValueKey(
                                  'windows-screen-lookup-ai-base-url',
                                ),
                                controller: screenLookupAiBaseUrlController,
                                keyboardType: TextInputType.url,
                                decoration: const InputDecoration(
                                  labelText: 'OpenAI 兼容 API 地址',
                                  hintText: 'https://example.com/v1',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: fieldWidth,
                              child: TextField(
                                key: const ValueKey(
                                  'windows-screen-lookup-ai-model',
                                ),
                                controller: screenLookupAiModelController,
                                decoration: const InputDecoration(
                                  labelText: '模型名称',
                                  hintText: '填写服务商提供的模型 ID',
                                  border: OutlineInputBorder(),
                                ),
                              ),
                            ),
                            SizedBox(
                              width: fieldWidth,
                              child: TextField(
                                key: const ValueKey(
                                  'windows-screen-lookup-ai-api-key',
                                ),
                                controller: screenLookupAiApiKeyController,
                                obscureText: true,
                                enableSuggestions: false,
                                autocorrect: false,
                                decoration: InputDecoration(
                                  labelText: 'API Key',
                                  hintText: screenLookupAiKeyStored
                                      ? '已安全保存；留空表示不修改'
                                      : '输入 API Key',
                                  border: const OutlineInputBorder(),
                                  suffixIcon: Icon(
                                    screenLookupAiKeyStored
                                        ? Icons.verified_user_rounded
                                        : Icons.key_rounded,
                                  ),
                                ),
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: [
                        FilledButton.icon(
                          key: const ValueKey(
                            'windows-screen-lookup-ai-save',
                          ),
                          onPressed: screenLookupAiSaving
                              ? null
                              : onSaveScreenLookupAiSettings,
                          icon: const Icon(Icons.save_outlined),
                          label: const Text('保存配置'),
                        ),
                        OutlinedButton.icon(
                          onPressed: screenLookupAiSaving
                              ? null
                              : onTestScreenLookupAiSettings,
                          icon: const Icon(Icons.network_check_rounded),
                          label: const Text('测试连接'),
                        ),
                        if (screenLookupAiKeyStored)
                          TextButton.icon(
                            onPressed: screenLookupAiSaving
                                ? null
                                : onDeleteScreenLookupAiApiKey,
                            icon: const Icon(Icons.key_off_rounded),
                            label: const Text('删除 API Key'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.privacy_tip_outlined,
                          size: 19,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'API Key 保存在当前 Windows 用户的安全凭据中。LumaLex 不会自动调用 AI；点击浮窗 AI 按钮时，最多发送约 500 个字符的附近语境。支持 OpenAI chat/completions 兼容接口。',
                            style: Theme.of(context)
                                .textTheme
                                .bodySmall
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ),
                      ],
                    ),
                    if (screenLookupAiSaving) ...[
                      const SizedBox(height: 14),
                      const LinearProgressIndicator(),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _SettingsSection(
                icon: Icons.select_all_rounded,
                title: '屏幕取词',
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    SwitchListTile.adaptive(
                      key: const ValueKey('windows-screen-lookup-toggle'),
                      contentPadding: EdgeInsets.zero,
                      title: const Text(
                        '启用全局快捷键取词',
                        style: TextStyle(fontWeight: FontWeight.w700),
                      ),
                      subtitle: const Text(
                        '在其他应用中选中文字后按下快捷键，LumaLex 会在光标附近显示查词浮窗；按住浮窗顶部空白处可用鼠标或触摸拖动。',
                      ),
                      value: screenLookupEnabled,
                      onChanged: screenLookupSaving
                          ? null
                          : onScreenLookupEnabledChanged,
                    ),
                    const SizedBox(height: 12),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child:
                          DropdownButtonFormField<WindowsScreenLookupShortcut>(
                        key: const ValueKey(
                          'windows-screen-lookup-shortcut',
                        ),
                        initialValue: screenLookupShortcut,
                        decoration: const InputDecoration(
                          labelText: '取词快捷键',
                          border: OutlineInputBorder(),
                        ),
                        items: WindowsScreenLookupShortcut.values
                            .map(
                              (shortcut) => DropdownMenuItem(
                                value: shortcut,
                                child: Text(shortcut.label),
                              ),
                            )
                            .toList(growable: false),
                        onChanged: screenLookupSaving
                            ? null
                            : (shortcut) {
                                if (shortcut != null) {
                                  onScreenLookupShortcutChanged(shortcut);
                                }
                              },
                      ),
                    ),
                    if (!screenLookupEnabled) ...[
                      const SizedBox(height: 8),
                      Text(
                        '可以先选择一个未被占用的快捷键，再开启屏幕取词。',
                        style: Theme.of(context).textTheme.bodySmall?.copyWith(
                              color: colors.onSurfaceVariant,
                            ),
                      ),
                    ],
                    const SizedBox(height: 10),
                    Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Icon(
                          Icons.shield_outlined,
                          size: 19,
                          color: colors.primary,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                '网页及支持 Windows 文本接口的应用：可读取选词和附近语境，并可使用 AI 本句释义。',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                'PDF 阅读器等不兼容应用会改用复制模式：只复制并查询选中文字（会更新剪贴板），没有上下文，不能使用 AI。扫描版或禁止复制的 PDF 可能无法取词；密码框不会读取。',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                              const SizedBox(height: 4),
                              Text(
                                '自动关闭时，光标停在浮窗内不会关闭；移出浮窗 5 秒后自动消失。',
                                style: Theme.of(context)
                                    .textTheme
                                    .bodySmall
                                    ?.copyWith(color: colors.onSurfaceVariant),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    if (screenLookupSaving) ...[
                      const SizedBox(height: 14),
                      const LinearProgressIndicator(),
                    ],
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _SettingsSection(
                icon: Icons.text_fields_rounded,
                title: '阅读',
                child: Row(
                  children: [
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '默认词条字号',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const SizedBox(height: 4),
                          Text(
                            '所有词典共用同一个阅读字号。',
                            style: Theme.of(context)
                                .textTheme
                                .bodyMedium
                                ?.copyWith(color: colors.onSurfaceVariant),
                          ),
                        ],
                      ),
                    ),
                    IconButton.outlined(
                      tooltip: '缩小字号',
                      onPressed: textScale <= 0.6
                          ? null
                          : () => onTextScaleChanged(textScale - 0.1),
                      icon: const Icon(Icons.remove_rounded),
                    ),
                    SizedBox(
                      width: 78,
                      child: Text(
                        '${(textScale * 100).round()}%',
                        textAlign: TextAlign.center,
                        style:
                            Theme.of(context).textTheme.titleMedium?.copyWith(
                                  fontWeight: FontWeight.w700,
                                ),
                      ),
                    ),
                    IconButton.outlined(
                      tooltip: '放大字号',
                      onPressed: textScale >= 2
                          ? null
                          : () => onTextScaleChanged(textScale + 0.1),
                      icon: const Icon(Icons.add_rounded),
                    ),
                    const SizedBox(width: 8),
                    TextButton(
                      onPressed:
                          textScale == 1 ? null : () => onTextScaleChanged(1),
                      child: const Text('恢复默认'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _SettingsSection(
                icon: Icons.storage_rounded,
                title: '数据与诊断',
                child: Wrap(
                  spacing: 10,
                  runSpacing: 10,
                  children: [
                    OutlinedButton.icon(
                      onPressed: onExportLearningData,
                      icon: const Icon(Icons.file_upload_outlined),
                      label: const Text('导出学习数据'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onImportLearningData,
                      icon: const Icon(Icons.file_download_outlined),
                      label: const Text('恢复学习数据'),
                    ),
                    OutlinedButton.icon(
                      onPressed: onSaveDiagnostics,
                      icon: const Icon(Icons.save_alt_rounded),
                      label: const Text('保存诊断报告'),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 18),
              _SettingsSection(
                icon: Icons.info_outline_rounded,
                title: '关于',
                child: Row(
                  children: [
                    ClipRRect(
                      borderRadius: BorderRadius.circular(13),
                      child: Image.asset(
                        'assets/branding/lumalex-icon-ui.png',
                        width: 48,
                        height: 48,
                      ),
                    ),
                    const SizedBox(width: 14),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            'LumaLex',
                            style: Theme.of(context)
                                .textTheme
                                .titleMedium
                                ?.copyWith(fontWeight: FontWeight.w700),
                          ),
                          const Text('$lumalexDisplayVersion · Windows 便携版'),
                        ],
                      ),
                    ),
                    OutlinedButton(
                      onPressed: () => showLicensePage(
                        context: context,
                        applicationName: 'LumaLex',
                        applicationVersion: lumalexDisplayVersion,
                        applicationIcon: ClipRRect(
                          borderRadius: BorderRadius.circular(13),
                          child: Image.asset(
                            'assets/branding/lumalex-icon-ui.png',
                            width: 52,
                            height: 52,
                          ),
                        ),
                      ),
                      child: const Text('查看许可证'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsSection extends StatelessWidget {
  const _SettingsSection({
    required this.icon,
    required this.title,
    required this.child,
  });

  final IconData icon;
  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      elevation: 0,
      color: colors.surfaceContainerLowest,
      shape: RoundedRectangleBorder(
        side: BorderSide(color: colors.outlineVariant),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, color: colors.primary, size: 22),
                const SizedBox(width: 9),
                Text(
                  title,
                  style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.w700,
                      ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );
  }
}
