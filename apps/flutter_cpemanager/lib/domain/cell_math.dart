int? parseFlexibleInt(String? value) {
  if (value == null) {
    return null;
  }
  final trimmed = value.trim();
  if (trimmed.isEmpty || trimmed == '--') {
    return null;
  }
  final cleaned = trimmed
      .replaceAll(RegExp(r'[^0-9A-Fa-fxX-]'), '')
      .replaceFirst(RegExp(r'^0+(?=\d)'), '');
  if (cleaned.isEmpty || cleaned == '-') {
    return null;
  }
  final looksHex = cleaned.startsWith('0x') ||
      cleaned.startsWith('0X') ||
      RegExp(r'[A-Fa-f]').hasMatch(cleaned);
  return int.tryParse(
    cleaned.replaceFirst(RegExp(r'^0[xX]'), ''),
    radix: looksHex ? 16 : 10,
  );
}

int? parseTacDecimal(String? value) {
  return parseFlexibleInt(value);
}

int? computeEci({String? enbId, String? cellId}) {
  final enb = parseFlexibleInt(enbId);
  final cell = parseFlexibleInt(cellId);
  if (enb == null || cell == null) {
    return null;
  }
  return enb * 256 + cell;
}

int? computeGci({String? gnbId, String? cellId}) {
  final gnb = parseFlexibleInt(gnbId);
  final cell = parseFlexibleInt(cellId);
  if (gnb == null || cell == null) {
    return null;
  }
  return gnb * 4096 + cell;
}

({int baseId, int localCellId})? splitEci(String? eci) {
  final value = parseFlexibleInt(eci);
  if (value == null) {
    return null;
  }
  return (baseId: value ~/ 256, localCellId: value % 256);
}

({int baseId, int localCellId})? splitGci(String? gci) {
  final value = parseFlexibleInt(gci);
  if (value == null) {
    return null;
  }
  return (baseId: value ~/ 4096, localCellId: value % 4096);
}

String decimalText(int? value) {
  return value == null ? '--' : value.toString();
}

String compoundCellText({String? baseId, String? localCellId}) {
  final base = parseFlexibleInt(baseId);
  final cell = parseFlexibleInt(localCellId);
  if (base == null || cell == null) {
    return '--';
  }
  return '$base-$cell';
}

/// 从格式化 NCGI/ECGI 字符串中提取纯 hex 小区 ID
/// "CELL ID:82c509108 PLMN:46001" → "82c509108"
/// "82c509108" → "82c509108"
String extractCellHexFromNcgi(String? formatted) {
  if (formatted == null || formatted.isEmpty) return '';
  // 匹配 "CELL ID:XXXXXXXX" 模式
  final match =
      RegExp(r'CELL\s*ID[:：]\s*([0-9A-Fa-f]+)').firstMatch(formatted);
  if (match != null) return match.group(1)!;
  // 兜底: 提取最长 hex 数字串
  final hexMatch = RegExp(r'[0-9A-Fa-f]{6,}').firstMatch(formatted);
  if (hexMatch != null) return hexMatch.group(0)!;
  return formatted;
}

String deriveNrGnbCell({
  String? gnbId,
  String? localCellId,
  String? gci,
}) {
  final direct = compoundCellText(baseId: gnbId, localCellId: localCellId);
  if (direct != '--') {
    return direct;
  }
  final split = splitGci(gci);
  if (split == null) {
    return '--';
  }
  return '${split.baseId}-${split.localCellId}';
}

String deriveLteEnbCell({
  String? enbId,
  String? localCellId,
  String? eci,
}) {
  final direct = compoundCellText(baseId: enbId, localCellId: localCellId);
  if (direct != '--') {
    return direct;
  }
  final split = splitEci(eci);
  if (split == null) {
    return '--';
  }
  return '${split.baseId}-${split.localCellId}';
}
