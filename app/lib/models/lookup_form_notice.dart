import 'dart:convert';

import 'search_fallback.dart';

String buildLookupFormChoicesHtml(
    String original, List<LookupFormCandidate> forms,
    {String? selectedQuery}) {
  if (forms.isEmpty) return '';
  const escape = HtmlEscape(HtmlEscapeMode.element);
  String choice(String text, int index, bool selected) =>
      '''<button type="button"
    aria-pressed="$selected" style="all:initial !important;display:inline-block !important;cursor:pointer !important;padding:8px 10px !important;border:1px solid #afd5d9 !important;border-radius:9px !important;background:${selected ? '#d8eef0' : '#fff'} !important;color:#24494c !important;font:600 13px/1.4 'Segoe UI','Microsoft YaHei UI',sans-serif !important;"
    onclick="chrome.webview.postMessage('lookupForm:$index')">${escape.convert(text)}</button>''';
  return '''<div id="lumalex-lookup-form-choices" role="group" aria-label="原词与相关原形"
    style="all:initial !important;display:flex !important;flex-wrap:wrap !important;gap:6px !important;margin-top:8px !important;">
    ${choice('原词 $original', -1, selectedQuery == null)}
    ${[
    for (var index = 0; index < forms.length; index++)
      choice(
          '${forms[index].offerOnly ? '查看主词' : '相关原形'} ${forms[index].query}',
          index,
          forms[index].query == selectedQuery)
  ].join('')}
    </div><div id="lumalex-lookup-form-hint" role="note"
      style="all:initial !important;display:block !important;margin-top:4px !important;color:#657474 !important;font:500 11px/1.4 'Segoe UI','Microsoft YaHei UI',sans-serif !important;">词形并存，不代表本句词性；点击切换，或使用 AI 判断语境。</div>''';
}
