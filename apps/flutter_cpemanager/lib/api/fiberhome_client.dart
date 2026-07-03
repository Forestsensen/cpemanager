import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:pointycastle/export.dart';

// ─── AES-CBC 加密工具 ────────────────────────────────────────────
//
// 烈焰 LG6121F 的 FHAPIS 端点使用 AES-128-CBC 加密。
// 密钥 = sessionid 前 16 字节
// IV   = 固定值 0x70..0x7f

class _FiberhomeAes {
  _FiberhomeAes._();

  static final Uint8List _iv = Uint8List.fromList(
    List<int>.generate(16, (i) => i + 112),
  );

  /// 用 sessionid 前 16 字节派生 AES 密钥。
  static Uint8List _deriveKey(String sessionId) {
    final raw = utf8.encode(sessionId);
    final key = Uint8List(16);
    key.setRange(0, min(raw.length, 16), raw);
    return key;
  }

  /// AES-CBC 加密，PKCS7 填充，返回 HEX 字符串。
  static String encrypt(String plaintext, String sessionId) {
    final key = _deriveKey(sessionId);
    final cipher = CBCBlockCipher(AESEngine())
      ..init(true, ParametersWithIV(KeyParameter(key), _iv));

    final input = Uint8List.fromList(utf8.encode(plaintext));
    final padded = _pkcs7Pad(input);
    final output = Uint8List(padded.length);
    for (var i = 0; i < padded.length; i += 16) {
      cipher.processBlock(padded, i, output, i);
    }
    return _bytesToHex(output);
  }

  /// AES-CBC 解密，HEX 输入 → UTF-8 明文。
  static String decrypt(String hexStr, String sessionId) {
    final key = _deriveKey(sessionId);
    final cipher = CBCBlockCipher(AESEngine())
      ..init(false, ParametersWithIV(KeyParameter(key), _iv));

    final input = _hexToBytes(hexStr);
    final output = Uint8List(input.length);
    for (var i = 0; i < input.length; i += 16) {
      cipher.processBlock(input, i, output, i);
    }
    return utf8.decode(_pkcs7Unpad(output));
  }

  static String _bytesToHex(Uint8List bytes) {
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  static Uint8List _hexToBytes(String hex) {
    final len = hex.length ~/ 2;
    final result = Uint8List(len);
    for (var i = 0; i < len; i++) {
      result[i] = int.parse(hex.substring(i * 2, i * 2 + 2), radix: 16);
    }
    return result;
  }

  /// PKCS7 填充。
  static Uint8List _pkcs7Pad(Uint8List input) {
    final padLen = 16 - (input.length % 16);
    final result = Uint8List(input.length + padLen);
    result.setRange(0, input.length, input);
    for (var i = input.length; i < result.length; i++) {
      result[i] = padLen;
    }
    return result;
  }

  /// PKCS7 去填充。
  static Uint8List _pkcs7Unpad(Uint8List input) {
    if (input.isEmpty) return input;
    final padLen = input.last;
    if (padLen < 1 || padLen > 16) return input;
    return input.sublist(0, input.length - padLen);
  }
}

// ─── 烽火 CPE 客户端 ─────────────────────────────────────────────

class FiberhomeClient {
  FiberhomeClient({
    this.host = '192.168.8.1',
    this.username = 'admin',
    required this.password,
    String sessionId = '',
    this.timeout = const Duration(seconds: 10),
  }) : _sessionId = sessionId {
    _http.findProxy = (_) => 'DIRECT';
  }

  final String host;
  final String username;
  final String password;
  final Duration timeout;
  final HttpClient _http = HttpClient();
  String _sessionId;

  String get _normalizedHost {
    return host
        .trim()
        .replaceFirst(RegExp(r'^https?://'), '')
        .replaceFirst(RegExp(r'/$'), '');
  }

  String get sessionId => _sessionId;

  // ─── URI 定义 ────────────────────────────────────────────────

  Uri get _toolUri => Uri.parse('http://$_normalizedHost/api/tmp/FHTOOLAPIS');

  Uri get _apisUri => Uri.parse('http://$_normalizedHost/api/tmp/FHAPIS');

  Uri get _sessionUri => Uri.parse(
        'http://$_normalizedHost/api/tmp/FHNCAPIS'
        '?ajaxmethod=get_refresh_sessionid',
      );

  Uri _toolGetUri(String ajaxMethod) {
    return Uri.parse('http://$_normalizedHost/api/tmp/FHTOOLAPIS').replace(
      queryParameters: <String, String>{
        'ajaxmethod': ajaxMethod,
        'sessionid': _sessionId.trim(),
      },
    );
  }

  // ─── 认证 ────────────────────────────────────────────────────

  Future<void> login() async {
    if (password.trim().isEmpty && _sessionId.trim().isEmpty) {
      throw StateError('烽火设备需要管理密码，或临时 sessionid。');
    }
    if (_sessionId.trim().isEmpty) {
      _sessionId = await refreshSessionId();
    }
    if (password.trim().isEmpty) {
      return;
    }
    final response = await _post(
      'app_do_login',
      dataObj: <String, String>{
        'username': username.trim().isEmpty ? 'admin' : username.trim(),
        'password': password,
      },
      allowEmptyPassword: true,
    );
    final ret = response['ret'];
    final errmsg = response['errmsg']?.toString() ?? '';
    if (ret != null && ret.toString() != '0' && errmsg.isNotEmpty) {
      throw StateError('烽火登录失败：$errmsg');
    }
    final nextSession = response['sessionid']?.toString() ?? '';
    if (nextSession.isNotEmpty) {
      _sessionId = nextSession;
    }
  }

  Future<String> refreshSessionId() async {
    final request = await _http.getUrl(_sessionUri).timeout(timeout);
    _applyHeaders(request);
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join();
    _raiseForStatus(response, text);
    final decoded = _decodeJson(text);
    final nextSession = decoded['sessionid']?.toString() ?? '';
    if (nextSession.isEmpty) {
      throw StateError('烽火 get_refresh_sessionid 未返回 sessionid。');
    }
    return nextSession;
  }

  Future<void> _ensureLoggedIn() async {
    if (_sessionId.trim().isEmpty) {
      await login();
    }
  }

  // ─── Web 登录（superadmin，FHAPIS 用） ──────────────────────

  /// 通过 Web 登录接口获取 superadmin 会话。
  /// 返回加密后的 sessionid，后续 FHAPIS 调用使用此 sessionid。
  Future<String> superLogin() async {
    _sessionId = await refreshSessionId();
    final innerJson = jsonEncode(<String, Object?>{
      'dataObj': <String, String>{
        'username': username.trim().isEmpty ? 'superadmin' : username.trim(),
        'password': password,
      },
      'ajaxmethod': 'DO_WEB_LOGIN',
      'sessionid': _sessionId.trim(),
    });

    final encryptedBody = _FiberhomeAes.encrypt(innerJson, _sessionId.trim());
    final uri = Uri.parse('http://$_normalizedHost/api/sign/DO_WEB_LOGIN');
    final request = await _http.postUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
    _applyHeaders(request);
    final payload = utf8.encode(encryptedBody);
    request.contentLength = payload.length;
    request.add(payload);

    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join();
    _raiseForStatus(response, text);
    final decrypted = _FiberhomeAes.decrypt(text, _sessionId.trim());
    final decoded = _decodeJson(decrypted);
    final nextSession = decoded['sessionid']?.toString() ?? '';
    if (nextSession.isNotEmpty) {
      _sessionId = nextSession;
    }
    return _sessionId;
  }

  // ─── FHTOOLAPIS 明文接口 ──────────────────────────────────────

  Future<Map<String, dynamic>> call(
    String ajaxMethod, {
    Object? dataObj,
  }) async {
    await _ensureLoggedIn();
    _sessionId = await refreshSessionId();
    return _post(ajaxMethod, dataObj: dataObj);
  }

  Future<Map<String, dynamic>> _post(
    String ajaxMethod, {
    Object? dataObj,
    bool allowEmptyPassword = false,
  }) async {
    if (_sessionId.trim().isEmpty) {
      throw StateError('烽火设备需要 sessionid。');
    }
    if (!allowEmptyPassword && password.trim().isEmpty) {
      throw StateError('烽火设备需要管理密码。');
    }
    final request = await _http.postUrl(_toolUri).timeout(timeout);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    _applyHeaders(request);
    final payload = _encodeToolPayload(
      ajaxMethod: ajaxMethod,
      sessionId: _sessionId.trim(),
      dataObj: dataObj,
    );
    request.contentLength = payload.length;
    request.add(payload);
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join();
    _raiseForStatus(response, text);
    return _decodeJson(text);
  }

  Future<Map<String, dynamic>> getTool(String ajaxMethod) async {
    await _ensureLoggedIn();
    final request =
        await _http.getUrl(_toolGetUri(ajaxMethod)).timeout(timeout);
    _applyHeaders(request);
    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join();
    _raiseForStatus(response, text);
    return _decodeJson(text);
  }

  // ─── FHAPIS AES 加密接口 ──────────────────────────────────────

  /// 调用 FHAPIS 端点（AES-CBC 加密）。
  ///
  /// [ajaxMethod] 是 FHAPIS 的 ajaxmethod（如 set_at_command）。
  /// [dataObj] 会作为 JSON 字符串被 AES 加密后发送。
  Future<Map<String, dynamic>> callApis(
    String ajaxMethod, {
    Object? dataObj,
  }) async {
    // FHAPIS 需要 superadmin web 登录
    if (_sessionId.trim().isEmpty || username == 'superadmin') {
      await superLogin();
    }
    _sessionId = await refreshSessionId();

    // 构造明文 JSON
    final innerJson = jsonEncode(<String, Object?>{
      'dataObj': dataObj,
      'ajaxmethod': ajaxMethod,
      'sessionid': _sessionId.trim(),
    });

    // AES 加密
    final encryptedBody = _FiberhomeAes.encrypt(innerJson, _sessionId.trim());

    // 发送 POST
    final request = await _http.postUrl(_apisUri).timeout(timeout);
    request.headers.set(HttpHeaders.contentTypeHeader, 'text/plain');
    _applyHeaders(request);
    final payload = utf8.encode(encryptedBody);
    request.contentLength = payload.length;
    request.add(payload);

    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join();
    _raiseForStatus(response, text);

    // AES 解密响应
    final decrypted = _FiberhomeAes.decrypt(text, _sessionId.trim());
    return _decodeJson(decrypted);
  }

  // ─── AT 命令接口 ──────────────────────────────────────────────

  /// 通过 AT 命令接口查询 5G 模块信息。
  ///
  /// 底层调用 mipc_wan_cli --at_cmd <command>，输出返回到 at_result 字段。
  /// 常见 AT 命令示例：
  ///   AT+QENG="servingcell"  — 查询当前服务小区详细信息
  ///   AT+QENG="neighbourcell" — 查询邻区列表
  ///   AT+QCAINFO            — 载波聚合信息
  ///   AT+C5GREG?            — 5G 注册状态
  Future<Map<String, dynamic>> sendAtCommand(String command) {
    return callApis(
      'set_at_command',
      dataObj: <String, String>{'command': command},
    );
  }

  // ─── TR-069 参数读写（无需认证）────────────────────────────────

  /// 通过 FHNCAPIS 读取 TR-069 参数（无需超管登录）。
  ///
  /// [parameter] 是完整的 TR-069 参数路径，例如：
  ///   InternetGatewayDevice.X_FH_WebUserInfo.2.WebSuperPassword
  Future<Map<String, dynamic>> getTr069Parameter(String parameter) async {
    final uri = Uri.parse(
      'http://$_normalizedHost/api/tmp/FHNCAPIS'
      '?ajaxmethod=get_value_by_xmlnode',
    );
    final sid = _sessionId.trim().isNotEmpty
        ? _sessionId.trim()
        : await refreshSessionId();

    final body = jsonEncode(<String, Object?>{
      'dataObj': <String, String>{
        parameter: '',
      },
      'ajaxmethod': 'get_value_by_xmlnode',
      'sessionid': sid,
    });

    final request = await _http.postUrl(uri).timeout(timeout);
    request.headers.set(HttpHeaders.contentTypeHeader, 'application/json');
    _applyHeaders(request);
    final payload = utf8.encode(body);
    request.contentLength = payload.length;
    request.add(payload);

    final response = await request.close().timeout(timeout);
    final text = await response.transform(utf8.decoder).join();
    _raiseForStatus(response, text);
    return _decodeJson(text);
  }

  // ─── 标准业务接口 ──────────────────────────────────────────────

  Future<Map<String, dynamic>> baseInfo() {
    return getTool('app_get_base_info');
  }

  Future<Map<String, dynamic>> airplane() {
    return getTool('app_get_airplane');
  }

  Future<Map<String, dynamic>> networkInfo() {
    return call('app_get_network_info');
  }

  Future<Map<String, dynamic>> lockBand() {
    return call('app_get_lockband');
  }

  Future<Map<String, dynamic>> cellList() {
    return call('app_get_cell_list');
  }

  Future<Map<String, dynamic>> snapshot() async {
    await login();
    final nextBaseInfo = await baseInfo();
    return <String, dynamic>{
      'baseInfo': nextBaseInfo,
      'networkInfo': await networkInfo(),
      'lockBand': await lockBand(),
      'cellList': await cellList(),
      'airplane': await airplane(),
      'session': <String, String>{'sessionid': _sessionId},
    };
  }

  // ─── 配置写入接口 ──────────────────────────────────────────────

  Future<Map<String, dynamic>> setNetworkMode(FiberhomeNetworkPreset preset) {
    return call(
      'app_set_network_info',
      dataObj: <String, String>{
        'networkMode': preset.networkMode,
        'ENDC': preset.endc,
      },
    );
  }

  Future<Map<String, dynamic>> setLockBand({
    required bool enabled,
    String lteBands = '',
    String nrBands = '',
  }) {
    return call(
      'app_set_lockband',
      dataObj: <String, String>{
        'lockBandEnable': enabled ? '1' : '0',
        'LTELockBAND': lteBands,
        'NRLockBAND': nrBands,
      },
    );
  }

  Future<Map<String, dynamic>> clearLockedCells({bool keepEnabled = true}) {
    return call(
      'app_set_cell_list',
      dataObj: <String, Object>{
        'enable': keepEnabled ? '1' : '0',
        'lock_cell': <Object>[],
      },
    );
  }

  Future<Map<String, dynamic>> setLockedCells({
    required bool enabled,
    required List<FiberhomeLockCell> cells,
  }) {
    return call(
      'app_set_cell_list',
      dataObj: <String, Object>{
        'enable': enabled ? '1' : '0',
        'lock_cell': cells.map((cell) => cell.toJson()).toList(),
      },
    );
  }

  // ─── HTTP 工具 ─────────────────────────────────────────────────

  static List<int> _encodeToolPayload({
    required String ajaxMethod,
    required String sessionId,
    Object? dataObj,
  }) {
    return utf8.encode(jsonEncode(<String, Object?>{
      'dataObj': dataObj,
      'ajaxmethod': ajaxMethod,
      'sessionid': sessionId,
    }));
  }

  void _applyHeaders(HttpClientRequest request) {
    request.headers
        .set('Accept', 'application/json, text/javascript, */*; q=0.01');
    request.headers.set('Origin', 'http://$_normalizedHost');
    request.headers.set('Referer', 'http://$_normalizedHost/main.html');
    request.headers.set('User-Agent', 'Mozilla/5.0 CPEManager/0.4.0');
    request.headers.set('X-Requested-With', 'XMLHttpRequest');
    request.headers.set('Accept-Language', 'zh-CN,en,*');
  }

  static Map<String, dynamic> _decodeJson(String text) {
    if (text.trim().isEmpty) {
      return <String, dynamic>{};
    }
    final decoded = jsonDecode(text);
    if (decoded is Map) {
      return decoded.map((key, value) => MapEntry(key.toString(), value));
    }
    return <String, dynamic>{'value': decoded};
  }

  static void _raiseForStatus(HttpClientResponse response, String body) {
    if (response.statusCode >= 400) {
      throw HttpException('HTTP ${response.statusCode}: $body');
    }
  }
}

// ─── 枚举和模型 ──────────────────────────────────────────────────

enum FiberhomeNetworkPreset {
  lteOnly('仅 LTE', '0', '1'),
  saOnly('仅 SA', '2', '1'),
  nsaPreferred('NSA', '3', '2'),
  auto('自动', '3', '3');

  const FiberhomeNetworkPreset(this.label, this.networkMode, this.endc);

  final String label;
  final String networkMode;
  final String endc;
}

class FiberhomeLockCell {
  const FiberhomeLockCell({
    required this.act,
    required this.arfcn,
    required this.pci,
  });

  final String act;
  final String arfcn;
  final String pci;

  Map<String, String> toJson() {
    return <String, String>{
      'act': act,
      'arfcn': arfcn,
      'pci': pci,
    };
  }
}

String fiberhomeNetworkModeText(Map<String, dynamic> networkInfo) {
  final networkMode = networkInfo['networkMode']?.toString();
  final endc = networkInfo['ENDC']?.toString();
  if (networkMode == '0') {
    return 'LTE Only';
  }
  if (networkMode == '2' && endc == '1') {
    return '5G SA';
  }
  if (networkMode == '3' && endc == '2') {
    return '5G NSA';
  }
  if (networkMode == '3' && endc == '3') {
    return 'AUTO';
  }
  return 'M$networkMode / E$endc';
}
