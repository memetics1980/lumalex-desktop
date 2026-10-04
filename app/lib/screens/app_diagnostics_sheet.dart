import 'package:flutter/material.dart';

import '../services/app_diagnostics.dart';

Future<void> showAppDiagnosticsSheet(
  BuildContext context, {
  required Future<AppDiagnosticsReport> Function() loadReport,
  required Future<void> Function(AppDiagnosticsReport report) saveDiagnostics,
  required Future<void> Function() clearDiagnostics,
  required Future<void> Function() exportLearningData,
  required Future<void> Function() importLearningData,
}) =>
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => _AppDiagnosticsSheet(
        loadReport: loadReport,
        saveDiagnostics: saveDiagnostics,
        clearDiagnostics: clearDiagnostics,
        exportLearningData: exportLearningData,
        importLearningData: importLearningData,
      ),
    );

class _AppDiagnosticsSheet extends StatefulWidget {
  const _AppDiagnosticsSheet({
    required this.loadReport,
    required this.saveDiagnostics,
    required this.clearDiagnostics,
    required this.exportLearningData,
    required this.importLearningData,
  });

  final Future<AppDiagnosticsReport> Function() loadReport;
  final Future<void> Function(AppDiagnosticsReport report) saveDiagnostics;
  final Future<void> Function() clearDiagnostics;
  final Future<void> Function() exportLearningData;
  final Future<void> Function() importLearningData;

  @override
  State<_AppDiagnosticsSheet> createState() => _AppDiagnosticsSheetState();
}

class _AppDiagnosticsSheetState extends State<_AppDiagnosticsSheet> {
  late Future<AppDiagnosticsReport> _report = widget.loadReport();
  bool _actionRunning = false;

  void _reload() => setState(() => _report = widget.loadReport());

  Future<void> _run(Future<void> Function() action) async {
    if (_actionRunning) return;
    setState(() => _actionRunning = true);
    try {
      await action();
    } catch (error) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('操作失败：$error')),
        );
      }
    } finally {
      if (mounted) setState(() => _actionRunning = false);
    }
  }

  @override
  Widget build(BuildContext context) => SafeArea(
        child: DraggableScrollableSheet(
          expand: false,
          initialChildSize: 0.84,
          minChildSize: 0.55,
          maxChildSize: 0.96,
          builder: (context, controller) => FutureBuilder<AppDiagnosticsReport>(
            future: _report,
            builder: (context, snapshot) {
              if (snapshot.connectionState != ConnectionState.done) {
                return const Center(child: CircularProgressIndicator());
              }
              if (snapshot.hasError || snapshot.data == null) {
                return _buildError(context, snapshot.error, controller);
              }
              return _buildReport(context, snapshot.data!, controller);
            },
          ),
        ),
      );

  Widget _buildError(
    BuildContext context,
    Object? error,
    ScrollController controller,
  ) =>
      ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(24, 8, 24, 28),
        children: [
          const Icon(Icons.error_outline_rounded, size: 44),
          const SizedBox(height: 14),
          Text(
            '无法读取诊断信息',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.titleLarge,
          ),
          const SizedBox(height: 8),
          Text(
            '$error',
            textAlign: TextAlign.center,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
          const SizedBox(height: 20),
          FilledButton.icon(
            onPressed: _reload,
            icon: const Icon(Icons.refresh_rounded),
            label: const Text('重试'),
          ),
        ],
      );

  Widget _buildReport(
    BuildContext context,
    AppDiagnosticsReport report,
    ScrollController controller,
  ) {
    final runtime = report.runtime;
    return ListView(
      controller: controller,
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 28),
      children: [
        Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: Image.asset(
                'assets/branding/lumalex-icon-ui.png',
                width: 42,
                height: 42,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'LumaLex',
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w700,
                        ),
                  ),
                  Text(
                      '版本 ${runtime.versionName} · build ${runtime.versionCode}'),
                ],
              ),
            ),
            IconButton(
              tooltip: '刷新诊断信息',
              onPressed: _actionRunning ? null : _reload,
              icon: const Icon(Icons.refresh_rounded),
            ),
          ],
        ),
        const SizedBox(height: 20),
        _sectionTitle(context, '运行环境'),
        _fact('设备', runtime.device),
        _fact('Android', 'API ${runtime.sdkInt}'),
        _fact('CPU', runtime.supportedAbis.join(', ')),
        _fact('System WebView', runtime.webViewVersion),
        _fact(
          '内存档位',
          '${runtime.memoryClassMb} MB${runtime.isLowRamDevice ? ' · 低内存设备' : ''}',
        ),
        const SizedBox(height: 18),
        _sectionTitle(context, '本地数据'),
        _fact(
          '词典',
          '${report.availableDictionaryCount} 本可用 / '
              '${report.enabledDictionaryCount} 本启用 / '
              '${report.dictionaryCount} 本管理中',
        ),
        _fact('MDX 高速副本', formatByteCount(runtime.stagedDictionaryBytes)),
        _fact('持久索引', formatByteCount(runtime.indexBytes)),
        _fact(
          '学习记录',
          '${report.historyCount} 条历史 / ${report.favoriteCount} 个收藏 / '
              '${report.reviewCardCount} 张卡片',
        ),
        const SizedBox(height: 18),
        _sectionTitle(context, '数据迁移'),
        Text(
          '学习数据文件只包含历史、收藏、复习进度和阅读字号，不包含任何 MDX/MDD 词典内容。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            OutlinedButton.icon(
              onPressed:
                  _actionRunning ? null : () => _run(widget.exportLearningData),
              icon: const Icon(Icons.file_upload_outlined),
              label: const Text('导出学习数据'),
            ),
            OutlinedButton.icon(
              onPressed:
                  _actionRunning ? null : () => _run(widget.importLearningData),
              icon: const Icon(Icons.file_download_outlined),
              label: const Text('恢复学习数据'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _sectionTitle(context, '故障诊断'),
        Text(
          report.readerEvents.isEmpty
              ? '目前没有记录到阅读器恢复事件。'
              : '本机保存了最近 ${report.readerEvents.length} 条阅读器事件。报告不会自动上传。',
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            FilledButton.icon(
              onPressed: _actionRunning
                  ? null
                  : () => _run(() => widget.saveDiagnostics(report)),
              icon: const Icon(Icons.save_alt_rounded),
              label: const Text('保存诊断报告'),
            ),
            TextButton.icon(
              onPressed: _actionRunning || report.readerEvents.isEmpty
                  ? null
                  : () => _run(() async {
                        await widget.clearDiagnostics();
                        _reload();
                      }),
              icon: const Icon(Icons.delete_outline_rounded),
              label: const Text('清除事件记录'),
            ),
          ],
        ),
        const SizedBox(height: 18),
        _sectionTitle(context, 'Android 选词查词'),
        const Text(
          '在支持系统文本选择菜单的应用里选中单词，点击“更多”，然后选择“LumaLex 查词”。'
          '悬浮查词窗口不需要“显示在其他应用上层”权限。',
        ),
        if (_actionRunning) ...[
          const SizedBox(height: 18),
          const LinearProgressIndicator(),
        ],
      ],
    );
  }

  Widget _sectionTitle(BuildContext context, String title) => Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text(
          title,
          style: Theme.of(context).textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w700,
              ),
        ),
      );

  Widget _fact(String label, String value) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 94,
              child: Text(label,
                  style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
            Expanded(child: SelectableText(value.isEmpty ? '—' : value)),
          ],
        ),
      );
}
