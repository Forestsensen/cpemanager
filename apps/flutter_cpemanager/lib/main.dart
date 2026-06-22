import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:path_provider/path_provider.dart';

import 'package:flutter/material.dart';

import 'api/cpe_client.dart';
import 'api/fiberhome_client.dart';
import 'domain/cell_math.dart';

void main() {
  runApp(const CpeManagerApp());
}

enum CpeVendor {
  fiberhome('Fiberhome', '烽火'),
  huawei('Huawei', '华为');

  const CpeVendor(this.code, this.label);

  final String code;
  final String label;
}

enum DisplayMode {
  simple('简洁', '翻译字段'),
  professional('专业', '源参数');

  const DisplayMode(this.label, this.description);

  final String label;
  final String description;
}

enum AppThemeMode {
  system('跟随系统', Icons.brightness_6),
  light('浅色模式', Icons.wb_sunny),
  dark('深色模式', Icons.nights_stay);

  const AppThemeMode(this.label, this.icon);
  final String label;
  final IconData icon;
}

class CpeDeviceProfile {
  const CpeDeviceProfile({
    required this.vendor,
    required this.title,
    required this.protocol,
    required this.description,
    required this.icon,
  });

  final CpeVendor vendor;
  final String title;
  final String protocol;
  final String description;
  final IconData icon;
}

const cpeDeviceProfiles = <CpeDeviceProfile>[
  CpeDeviceProfile(
    vendor: CpeVendor.fiberhome,
    title: '烽火 CPE',
    protocol: 'FHNCAPIS / FHTOOLAPIS',
    description: '适用于烽火 LG61xx 系列，使用 JSON 接口读取信号、SIM 与锁定状态。',
    icon: Icons.hub_outlined,
  ),
  CpeDeviceProfile(
    vendor: CpeVendor.huawei,
    title: '华为 CPE',
    protocol: 'Huawei XML API',
    description: '适用于华为/智选类 CPE，使用 challenge_login 和 XML 状态接口。',
    icon: Icons.router_outlined,
  ),
];

CpeDeviceProfile cpeProfile(CpeVendor vendor) {
  return cpeDeviceProfiles.firstWhere((item) => item.vendor == vendor);
}

class CpeManagerApp extends StatefulWidget {
  const CpeManagerApp({super.key});
  @override
  State<CpeManagerApp> createState() => _CpeManagerAppState();
}

class _CpeManagerAppState extends State<CpeManagerApp> {
  AppThemeMode _themeMode = AppThemeMode.dark;

  @override
  void initState() {
    super.initState();
    _loadTheme();
  }

  Future<void> _loadTheme() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(dir.path + '/cpe_credentials.json');
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      final saved = data['themeMode'] as String?;
      if (saved != null) {
        final match = AppThemeMode.values.where((m) => m.name == saved);
        if (match.isNotEmpty) {
          setState(() {
            _themeMode = match.first;
            CpeColors.isDark = _effectiveIsDark;
          });
        }
      }
    } catch (_) {}
  }

  bool get _effectiveIsDark {
    if (_themeMode == AppThemeMode.system) {
      return WidgetsBinding.instance.platformDispatcher.platformBrightness == Brightness.dark;
    }
    return _themeMode == AppThemeMode.dark;
  }

  void _setThemeMode(AppThemeMode mode) {
    setState(() {
      _themeMode = mode;
      CpeColors.isDark = _effectiveIsDark;
    });
    _saveTheme(mode);
  }

  Future<void> _saveTheme(AppThemeMode mode) async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      final file = File(dir.path + '/cpe_credentials.json');
      Map<String, dynamic> data = {};
      if (await file.exists()) {
        data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      }
      data['themeMode'] = mode.name;
      await file.writeAsString(jsonEncode(data));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    CpeColors.isDark = _effectiveIsDark;
    final seed = CpeColors.primary;
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'CPE Manager',
      themeMode: _themeMode == AppThemeMode.system ? ThemeMode.system
          : _themeMode == AppThemeMode.light ? ThemeMode.light : ThemeMode.dark,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.light),
        scaffoldBackgroundColor: CpeColors.background,
        useMaterial3: true,
        fontFamilyFallback: ['PingFang SC', 'Noto Sans CJK SC'],
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: seed, brightness: Brightness.dark),
        scaffoldBackgroundColor: CpeColors.background,
        useMaterial3: true,
        fontFamilyFallback: ['PingFang SC', 'Noto Sans CJK SC'],
      ),
      home: HomeScreen(onThemeModeChanged: _setThemeMode, themeMode: _themeMode),
    );
  }
}

class HomeScreen extends StatefulWidget {
  const HomeScreen({this.onThemeModeChanged, this.themeMode, super.key});
  final ValueChanged<AppThemeMode>? onThemeModeChanged;
  final AppThemeMode? themeMode;
  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final hostController = TextEditingController(text: '192.168.8.1');
  final usernameController = TextEditingController(text: 'admin');
  final passwordController = TextEditingController();
  final lteBandController = TextEditingController();
  final nrBandController = TextEditingController(text: '41,77,78');
  final lockArfcnController = TextEditingController();
  final lockPciController = TextEditingController();
  final lteLockArfcnController = TextEditingController();
  final lteLockPciController = TextEditingController();
  final scrollController = ScrollController();

  CpeVendor vendor = CpeVendor.fiberhome;
  DisplayMode displayMode = DisplayMode.simple;
  int tabIndex = 1;
  Map<String, dynamic>? snapshot;
  Map<String, List<Map<String, String>>>? neighbors;
  String rawOutput = '';
  String? error;
  bool busy = false;
  bool autoRefresh = true;
  bool backgroundRefresh = false;
  String busyLabel = '';
  DateTime? lastUpdated;
  Timer? refreshTimer;

  @override
  void initState() {
    super.initState();
    _loadSavedCredentials();
    refreshTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (!mounted || !autoRefresh || snapshot == null || busy) {
        return;
      }
      unawaited(refreshSnapshot(silent: true));
    });
  }

  Future<File> get _credFile async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/cpe_credentials.json');
  }

  Future<void> _loadSavedCredentials() async {
    try {
      final file = await _credFile;
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
      if (data['host'] != null && (data['host'] as String).isNotEmpty) {
        hostController.text = data['host'];
      }
      if (data['username'] != null && (data['username'] as String).isNotEmpty) {
        usernameController.text = data['username'];
      }
      if (data['password'] != null && (data['password'] as String).isNotEmpty) {
        passwordController.text = data['password'];
      }
      if (data['vendor'] != null) {
        final match = CpeVendor.values.where((v) => v.code == data['vendor']);
        if (match.isNotEmpty) {
          setState(() {
            vendor = match.first;
          });
        }
      }
    } catch (_) {}
  }

  Future<void> _saveCredentials() async {
    try {
      final file = await _credFile;
      await file.writeAsString(jsonEncode({
        'host': hostController.text.trim(),
        'username': usernameController.text.trim(),
        'password': passwordController.text,
        'vendor': vendor.code,
      }));
    } catch (_) {}
  }

  @override
  void dispose() {
    refreshTimer?.cancel();
    scrollController.dispose();
    hostController.dispose();
    usernameController.dispose();
    passwordController.dispose();
    lteBandController.dispose();
    nrBandController.dispose();
    lockArfcnController.dispose();
    lockPciController.dispose();
    lteLockArfcnController.dispose();
    lteLockPciController.dispose();
    super.dispose();
  }

  CpeClient huaweiClient() {
    return CpeClient(
      host: normalizedHost,
      username: usernameController.text.trim().isEmpty
          ? 'admin'
          : usernameController.text.trim(),
      password: passwordController.text,
    );
  }

  FiberhomeClient fiberhomeClient() {
    return FiberhomeClient(
      host: normalizedHost,
      username: usernameController.text.trim().isEmpty
          ? 'admin'
          : usernameController.text.trim(),
      password: passwordController.text,
    );
  }

  String get normalizedHost {
    return hostController.text.trim().isEmpty
        ? '192.168.8.1'
        : hostController.text.trim();
  }

  Future<void> runTask(
    String label,
    Future<void> Function() task, {
    bool silent = false,
  }) async {
    if (passwordController.text.isEmpty) {
      setState(() {
        error =
            vendor == CpeVendor.huawei ? '请输入华为 CPE 管理密码。' : '请输入烽火 CPE 管理密码。';
      });
      return;
    }
    if (!silent) {
      setState(() {
        busy = true;
        busyLabel = label;
        error = null;
      });
    }
    try {
      await task();
    } catch (exception) {
      if (mounted) {
        setState(() {
          error = exception.toString();
        });
      }
    } finally {
      if (mounted && !silent) {
        setState(() {
          busy = false;
          busyLabel = '';
        });
      }
    }
  }

  Future<void> refreshSnapshot({bool silent = false}) async {
    if (silent && backgroundRefresh) {
      return;
    }
    if (silent) {
      backgroundRefresh = true;
    }
    try {
      await runTask('读取设备状态', () async {
        if (vendor == CpeVendor.huawei) {
          final cpe = huaweiClient();
          final next = await cpe.snapshot();
          final nextNeighbors = await cpe.neighborCells();
          if (!mounted) {
            return;
          }
          setState(() {
            snapshot = next;
            neighbors = nextNeighbors;
            rawOutput = const JsonEncoder.withIndent('  ').convert(next);
            lastUpdated = DateTime.now();
          });
        } else {
          final cpe = fiberhomeClient();
          final next = await cpe.snapshot();
          if (!mounted) {
            return;
          }
          setState(() {
            snapshot = next;
            neighbors = fiberhomeNeighbors(next);
            rawOutput = const JsonEncoder.withIndent('  ').convert(next);
            lastUpdated = DateTime.now();
          });
        }
      }, silent: silent);
    } finally {
      if (silent) {
        backgroundRefresh = false;
      }
    }
  }

  Future<void> setAutoMode() async {
    final confirmed = await confirm(
      vendor == CpeVendor.huawei ? '恢复自动网络模式并启用 SA+NSA？' : '将烽火设备切到 Auto 模式？',
    );
    if (!confirmed) {
      return;
    }
    return runTask('写入网络模式', () async {
      Object result;
      if (vendor == CpeVendor.huawei) {
        result = await huaweiClient().setNetMode(
          networkMode: '00',
          networkOption: '2',
        );
      } else {
        result =
            await fiberhomeClient().setNetworkMode(FiberhomeNetworkPreset.auto);
      }
      await refreshSnapshot();
      setState(() {
        rawOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    });
  }

  Future<void> unlockAll() async {
    final confirmed = await confirm(
      vendor == CpeVendor.huawei
          ? '解除所有锁频？这可能改变当前驻网小区。'
          : '清空烽火锁小区列表？这会保留锁小区开关状态。',
    );
    if (!confirmed) {
      return;
    }
    return runTask('解除锁定', () async {
      Object result;
      if (vendor == CpeVendor.huawei) {
        result = await huaweiClient().unlockAll();
      } else {
        result = await fiberhomeClient().clearLockedCells();
      }
      await refreshSnapshot();
      setState(() {
        rawOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    });
  }

  Future<void> setFiberhomeNetwork(FiberhomeNetworkPreset preset) {
    return runTask('写入 ${preset.label}', () async {
      final result = await fiberhomeClient().setNetworkMode(preset);
      await refreshSnapshot();
      setState(() {
        rawOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    });
  }

  Future<void> setFiberhomeBands() {
    return runTask('写入锁 Band', () async {
      final result = await fiberhomeClient().setLockBand(
        enabled: true,
        lteBands: lteBandController.text.trim(),
        nrBands: nrBandController.text.trim(),
      );
      await refreshSnapshot();
      setState(() {
        rawOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    });
  }

  Future<void> setFiberhomeCellLock() {
    final arfcn = lockArfcnController.text.trim();
    final pci = lockPciController.text.trim();
    if (arfcn.isEmpty || pci.isEmpty) {
      setState(() {
        error = '请输入 NR ARFCN 和 PCI 后再执行锁小区。';
      });
      return Future<void>.value();
    }
    return runTask('写入锁小区', () async {
      final result = await fiberhomeClient().setLockedCells(
        enabled: true,
        cells: <FiberhomeLockCell>[
          FiberhomeLockCell(
            act: '2',
            arfcn: arfcn,
            pci: pci,
          ),
        ],
      );
      await refreshSnapshot();
      setState(() {
        rawOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    });
  }

  Future<void> setFiberhomeDualCellLock() {
    final nrArfcn = lockArfcnController.text.trim();
    final nrPci = lockPciController.text.trim();
    final lteArfcn = lteLockArfcnController.text.trim();
    final ltePci = lteLockPciController.text.trim();
    if ([nrArfcn, nrPci, lteArfcn, ltePci].any((value) => value.isEmpty)) {
      setState(() {
        error = '请输入 NR 和 LTE 的 ARFCN/PCI 后再执行 4G+5G 同锁。';
      });
      return Future<void>.value();
    }
    return runTask('写入 4G+5G 同锁', () async {
      final result = await fiberhomeClient().setLockedCells(
        enabled: true,
        cells: <FiberhomeLockCell>[
          FiberhomeLockCell(act: '2', arfcn: nrArfcn, pci: nrPci),
          FiberhomeLockCell(act: '1', arfcn: lteArfcn, pci: ltePci),
        ],
      );
      await refreshSnapshot();
      setState(() {
        rawOutput = const JsonEncoder.withIndent('  ').convert(result);
      });
    });
  }

  Future<bool> confirm(String message) async {
    return await showDialog<bool>(
          context: context,
          builder: (context) {
            return AlertDialog(
              title: const Text('确认操作'),
              content: Text(message),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () => Navigator.of(context).pop(true),
                  child: const Text('继续'),
                ),
              ],
            );
          },
        ) ??
        false;
  }

  @override
  Widget build(BuildContext context) {
    final model = DashboardModel.from(
      vendor: vendor,
      displayMode: displayMode,
      snapshot: snapshot,
      neighbors: neighbors,
    );
    return Scaffold(
      body: SafeArea(
        child: CustomScrollView(
          controller: scrollController,
          slivers: [
            if (tabIndex == 3)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(18, 14, 18, 10),
                child: HeaderPanel(
                  model: model,
                  vendor: vendor,
                  busy: busy,
                  busyLabel: busyLabel,
                  autoRefresh: autoRefresh,
                  lastUpdated: lastUpdated,
                  displayMode: displayMode,
                  themeMode: widget.themeMode ?? AppThemeMode.dark,
                  onThemeModeChanged: widget.onThemeModeChanged,
                  onRefresh: () => refreshSnapshot(),
                  onAutoRefreshChanged: (value) {
                    setState(() {
                      autoRefresh = value;
                    });
                  },
                  onDisplayModeChanged: (next) {
                    setState(() {
                      displayMode = next;
                    });
                  },
                  onVendorChanged: (next) {
                    setState(() {
                      vendor = next;
                      snapshot = null;
                      neighbors = null;
                      rawOutput = '';
                      error = null;
                      lastUpdated = null;
                    });
                    if (scrollController.hasClients) {
                      scrollController.jumpTo(0);
                    }
                  },
                ),
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(18, 0, 18, 22),
              sliver: SliverList.list(
                children: [
                  if (busy) const LinearProgressIndicator(minHeight: 3),
                  if (error != null) ...[
                    const SizedBox(height: 12),
                    ErrorPanel(message: error!),
                  ],
                  const SizedBox(height: 12),
                  IndexedStack(
                    index: tabIndex,
                    children: [
                      PccWorkspace(model: model),
                      CarrierWorkspace(model: model),
                      LockWorkspace(
                        vendor: vendor,
                        model: model,
                        lteBandController: lteBandController,
                        nrBandController: nrBandController,
                        lockArfcnController: lockArfcnController,
                        lockPciController: lockPciController,
                        lteLockArfcnController: lteLockArfcnController,
                        lteLockPciController: lteLockPciController,
                        onAuto: busy ? null : setAutoMode,
                        onUnlock: busy ? null : unlockAll,
                        onFiberhomeNetwork: busy ? null : setFiberhomeNetwork,
                        onFiberhomeBands: busy ? null : setFiberhomeBands,
                        onFiberhomeCell: busy ? null : setFiberhomeCellLock,
                        onFiberhomeDualCell:
                            busy ? null : setFiberhomeDualCellLock,
                      ),
                      LoginWorkspace(
                        vendor: vendor,
                        hostController: hostController,
                        usernameController: usernameController,
                        passwordController: passwordController,
                        onRead: busy ? null : () { _saveCredentials(); refreshSnapshot(); },
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: tabIndex,
        onDestinationSelected: (index) {
          setState(() {
            tabIndex = index;
          });
          if (scrollController.hasClients) {
            scrollController.jumpTo(0);
          }
        },
        backgroundColor: CpeColors.panel,
        indicatorColor: CpeColors.tileAccent,
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.tune),
            selectedIcon: Icon(Icons.tune),
            label: '连接',
          ),
          NavigationDestination(
            icon: Icon(Icons.cell_tower_outlined),
            selectedIcon: Icon(Icons.cell_tower),
            label: '载波聚合',
          ),
          NavigationDestination(
            icon: Icon(Icons.lock_outline),
            selectedIcon: Icon(Icons.lock),
            label: '锁频',
          ),
          NavigationDestination(
            icon: Icon(Icons.account_circle_outlined),
            selectedIcon: Icon(Icons.account_circle),
            label: '登录',
          ),
        ],
      ),
    );
  }
}

class HeaderPanel extends StatelessWidget {
  const HeaderPanel({
    required this.model,
    required this.vendor,
    required this.busy,
    required this.busyLabel,
    required this.autoRefresh,
    required this.lastUpdated,
    required this.displayMode,
    required this.onRefresh,
    required this.onAutoRefreshChanged,
    required this.onDisplayModeChanged,
    required this.onVendorChanged,
    this.themeMode = AppThemeMode.dark,
    this.onThemeModeChanged,
    super.key,
  });

  final DashboardModel model;
  final CpeVendor vendor;
  final bool busy;
  final String busyLabel;
  final bool autoRefresh;
  final DateTime? lastUpdated;
  final DisplayMode displayMode;
  final VoidCallback onRefresh;
  final ValueChanged<bool> onAutoRefreshChanged;
  final ValueChanged<DisplayMode> onDisplayModeChanged;
  final ValueChanged<CpeVendor> onVendorChanged;
  final AppThemeMode themeMode;
  final ValueChanged<AppThemeMode>? onThemeModeChanged;

  @override
  Widget build(BuildContext context) {
    return Surface(
      tinted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      model.headerTitle,
                      style:
                          Theme.of(context).textTheme.headlineSmall?.copyWith(
                                fontWeight: FontWeight.w900,
                                letterSpacing: 0,
                                color: CpeColors.ink,
                              ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      model.subtitle,
                      style: TextStyle(
                        color: CpeColors.muted,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton.filledTonal(
                tooltip: busy ? busyLabel : '立即刷新',
                onPressed: busy ? null : onRefresh,
                icon: const Icon(Icons.refresh),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: themeMode.label,
                child: IconButton.filledTonal(
                  onPressed: onThemeModeChanged != null
                      ? () {
                          final next = AppThemeMode.values[
                              (themeMode.index + 1) % AppThemeMode.values.length];
                          onThemeModeChanged!(next);
                        }
                      : null,
                  icon: Icon(themeMode.icon, size: 20),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          DeviceProfileSelector(
            vendor: vendor,
            onChanged: onVendorChanged,
          ),
          const SizedBox(height: 12),
          HeaderControls(
            autoRefresh: autoRefresh,
            lastUpdated: lastUpdated,
            displayMode: displayMode,
            onAutoRefreshChanged: onAutoRefreshChanged,
            onDisplayModeChanged: onDisplayModeChanged,
          ),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              StatusChip(label: model.modeBadge, strong: true),
              StatusChip(label: model.operatorBadge),
              StatusChip(
                label: model.rrcBadge,
                color: model.rrcBadge.contains('正常')
                    ? CpeColors.good
                    : CpeColors.primary,
              ),
              StatusChip(label: vendor.label),
            ],
          ),
        ],
      ),
    );
  }
}

class DeviceProfileSelector extends StatelessWidget {
  const DeviceProfileSelector({
    required this.vendor,
    required this.onChanged,
    super.key,
  });

  final CpeVendor vendor;
  final ValueChanged<CpeVendor> onChanged;

  @override
  Widget build(BuildContext context) {
    return DropdownButtonFormField<CpeVendor>(
      initialValue: vendor,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: '设备档案',
        prefixIcon: Icon(Icons.router_outlined),
      ),
      items: CpeVendor.values.map((item) {
        final profile = cpeProfile(item);
        return DropdownMenuItem<CpeVendor>(
          value: item,
          child: Row(
            children: [
              Icon(profile.icon, size: 20, color: CpeColors.primary),
              const SizedBox(width: 10),
              Expanded(
                child: Text(
                  '${profile.title} · ${profile.protocol}',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: CpeColors.ink,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
            ],
          ),
        );
      }).toList(),
      onChanged: (value) {
        if (value != null) {
          onChanged(value);
        }
      },
    );
  }
}

class HeaderControls extends StatelessWidget {
  const HeaderControls({
    required this.autoRefresh,
    required this.lastUpdated,
    required this.displayMode,
    required this.onAutoRefreshChanged,
    required this.onDisplayModeChanged,
    super.key,
  });

  final bool autoRefresh;
  final DateTime? lastUpdated;
  final DisplayMode displayMode;
  final ValueChanged<bool> onAutoRefreshChanged;
  final ValueChanged<DisplayMode> onDisplayModeChanged;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        FilterChip(
          selected: autoRefresh,
          onSelected: onAutoRefreshChanged,
          avatar: Icon(
            autoRefresh ? Icons.sync : Icons.sync_disabled,
            size: 18,
          ),
          label: Text(autoRefresh ? '5秒自动刷新' : '手动刷新'),
        ),
        StatusChip(label: '更新 ${timeText(lastUpdated)}'),
        SegmentedButton<DisplayMode>(
          segments: DisplayMode.values
              .map(
                (item) => ButtonSegment<DisplayMode>(
                  value: item,
                  label: Text(item.label),
                  icon: Icon(
                    item == DisplayMode.simple
                        ? Icons.translate
                        : Icons.data_object,
                  ),
                ),
              )
              .toList(),
          selected: <DisplayMode>{displayMode},
          showSelectedIcon: false,
          onSelectionChanged: (value) => onDisplayModeChanged(value.first),
        ),
      ],
    );
  }
}

class LoginWorkspace extends StatelessWidget {
  const LoginWorkspace({
    required this.vendor,
    required this.hostController,
    required this.usernameController,
    required this.passwordController,
    required this.onRead,
    super.key,
  });

  final CpeVendor vendor;
  final TextEditingController hostController;
  final TextEditingController usernameController;
  final TextEditingController passwordController;
  final VoidCallback? onRead;

  @override
  Widget build(BuildContext context) {
    final isHuawei = vendor == CpeVendor.huawei;
    final profile = cpeProfile(vendor);
    return Column(
      children: [
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '连接设备'),
              const SizedBox(height: 12),
              DeviceProfileCard(profile: profile),
              const SizedBox(height: 12),
              FieldBlock(
                label: 'CPE 地址',
                helper: '局域网后台地址，默认 192.168.8.1',
                child: TextField(
                  controller: hostController,
                  keyboardType: TextInputType.url,
                  decoration: InputDecoration(hintText: '192.168.8.1'),
                ),
              ),
              const SizedBox(height: 12),
              FieldBlock(
                label: '用户名',
                helper: '默认账号通常为 admin',
                child: TextField(
                  controller: usernameController,
                  decoration: InputDecoration(hintText: 'admin'),
                ),
              ),
              const SizedBox(height: 12),
              FieldBlock(
                label: '管理密码',
                helper: isHuawei ? '用于读取华为状态接口' : '用于读取烽火状态接口',
                child: TextField(
                  controller: passwordController,
                  obscureText: true,
                  decoration: InputDecoration(
                    hintText: isHuawei ? '华为 CPE 管理密码' : '烽火 CPE 管理密码',
                  ),
                ),
              ),
              const SizedBox(height: 14),
              SizedBox(
                width: double.infinity,
                child: FilledButton.icon(
                  onPressed: onRead,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('读取状态'),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        InfoStrip(
          title: '当前设备档案',
          body:
              '${profile.title} · ${profile.protocol}。后续新增设备时会继续放进这个档案选择器，不需要改变登录流程。',
        ),
      ],
    );
  }
}

class DeviceProfileCard extends StatelessWidget {
  const DeviceProfileCard({required this.profile, super.key});

  final CpeDeviceProfile profile;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CpeColors.tile,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CpeColors.border),
      ),
      child: Row(
        children: [
          Container(
            width: 44,
            height: 44,
            decoration: BoxDecoration(
              color: CpeColors.tileAccent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Icon(profile.icon, color: CpeColors.primary),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  profile.title,
                  style: TextStyle(
                    color: CpeColors.ink,
                    fontWeight: FontWeight.w900,
                    fontSize: 16,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  profile.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: CpeColors.muted,
                    fontWeight: FontWeight.w600,
                    height: 1.25,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class PccWorkspace extends StatelessWidget {
  const PccWorkspace({required this.model, super.key});

  final DashboardModel model;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Column(
        children: [
          // ── 1. 连接情况 (Connection Status) ──
          _ConnHeader(model: model),
          const SizedBox(height: 10),
          // ── 2. SIM卡AMBR ──
          _SimAmbrPanel(model: model),
          const SizedBox(height: 10),
          // ── 4. 当前小区 (Cell Info) - 2x3 grid ──
          _SectionCard(
            title: '当前小区',
            child: _MetricGrid2x(items: [
              ...model.primaryItems.take(3),
              ...model.identityItems.take(3),
            ]),
          ),
          const SizedBox(height: 10),
          // ── 5. 射频质量 (RF Quality) - 2x3 grid with bars ──
          _SectionCard(
            title: '射频质量',
            child: _RfGrid(items: model.signalBars),
          ),
          const SizedBox(height: 10),
          // ── 6. 当前功率 (Power) - grid ──
          _SectionCard(
            title: '当前功率',
            child: _PowerGrid(model: model),
          ),
          const SizedBox(height: 10),
          // ── 7. 链路信息 (Link Info) - 2 columns ──
          _LinkInfoRow(model: model),
          const SizedBox(height: 10),
          // ── 8. 设备信息 (Device & Traffic) - 2 column grid ──
          _SectionCard(title: '设备信息', child: _DeviceGrid(model: model)),
          const SizedBox(height: 80), // bottom nav space
        ],
      ),
    );
  }
}

// ════════════════════════════════════════════════
// CPE++ Layout Components
// ════════════════════════════════════════════════

/// Section card container
class _SectionCard extends StatelessWidget {
  const _SectionCard({this.title, required this.child});
  final String? title;
  final Widget child;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(12),
    decoration: BoxDecoration(
      color: CpeColors.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: CpeColors.border),
    ),
    child: title != null
        ? Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(title!, style: TextStyle(color: CpeColors.ink, fontWeight: FontWeight.w700, fontSize: 14)),
            const SizedBox(height: 10),
            child,
          ])
        : child,
  );
}

/// 1. Connection Header - 标题 + RRC/模式/运营商徽章 + 刷新按钮
class _ConnHeader extends StatelessWidget {
  const _ConnHeader({required this.model});
  final DashboardModel model;

  Color get _rrcClr => model.rrcBadge.contains('正常') ? const Color(0xffc17702) : CpeColors.danger;

  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
    decoration: BoxDecoration(
      color: CpeColors.surface,
      borderRadius: BorderRadius.circular(10),
      border: Border.all(color: CpeColors.border),
    ),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [
        Text('连接情况', style: TextStyle(color: CpeColors.ink, fontWeight: FontWeight.w800, fontSize: 15)),
        const Spacer(),
        GestureDetector(
          onTap: () {},
          child: Text('刷新', style: TextStyle(color: CpeColors.accent.withValues(alpha: 0.7), fontWeight: FontWeight.w600, fontSize: 13)),
        ),
      ]),
      const SizedBox(height: 10),
      Wrap(spacing: 6, runSpacing: 6, children: [
        _Badge(text: model.rrcBadge, color: _rrcClr),
        _Badge(text: model.modeBadge, color: const Color(0xff4493f5)),
        _Badge(text: model.operatorBadge, color: CpeColors.muted),
      ]),
    ]),
  );
}

class _Badge extends StatelessWidget {
  const _Badge({required this.text, required this.color});
  final String text; final Color color;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
    decoration: BoxDecoration(
      color: color.withValues(alpha: 0.15),
      borderRadius: BorderRadius.circular(4),
      border: Border.all(color: color.withValues(alpha: 0.3)),
    ),
    child: Text(text, style: TextStyle(color: color, fontWeight: FontWeight.w700, fontSize: 11)),
  );
}


/// 3. SIM AMBR panel
class _SimAmbrPanel extends StatelessWidget {
  const _SimAmbrPanel({required this.model});
  final DashboardModel model;

  @override
  Widget build(BuildContext context) => _SectionCard(
    child: Row(children: [
      Text('SIM卡AMBR', style: TextStyle(color: CpeColors.ink, fontWeight: FontWeight.w700, fontSize: 14)),
      const Spacer(),
      GestureDetector(
        onTap: () {},
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
          decoration: BoxDecoration(color: CpeColors.accent.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(16)),
          child: Text('获取', style: TextStyle(color: CpeColors.accent, fontWeight: FontWeight.w600, fontSize: 12)),
        ),
      ),
    ]),
  );
}

/// 4. Metric tile (label top, value bottom)
class _MetricTile extends StatelessWidget {
  const _MetricTile({required this.label, required this.value});
  final String label; final String value;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 8),
    decoration: BoxDecoration(color: CpeColors.tile, borderRadius: BorderRadius.circular(8)),
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Text(label, style: TextStyle(color: CpeColors.muted, fontSize: 11, fontWeight: FontWeight.w600)),
      const SizedBox(height: 4),
      Text(value, maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(color: CpeColors.ink, fontSize: 14, fontWeight: FontWeight.w900)),
    ]),
  );
}

/// 2-column metric grid using KvItem data
class _MetricGrid2x extends StatelessWidget {
  const _MetricGrid2x({required this.items});
  final List<KvItem> items;

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      mainAxisExtent: 56,
    ),
    itemCount: items.length,
    itemBuilder: (_, i) => _MetricTile(label: items[i].label, value: items[i].value),
  );
}

/// 5. RF Quality grid - tiles with colored progress bar under value
class _RfGrid extends StatelessWidget {
  const _RfGrid({required this.items});
  final List<BarItem> items;

  @override
  Widget build(BuildContext context) => GridView.builder(
    shrinkWrap: true,
    physics: const NeverScrollableScrollPhysics(),
    gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
      crossAxisCount: 2,
      crossAxisSpacing: 8,
      mainAxisSpacing: 8,
      mainAxisExtent: 64,
    ),
    itemCount: items.length,
    itemBuilder: (_, i) => _RfTile(item: items[i]),
  );
}

class _RfTile extends StatelessWidget {
  const _RfTile({required this.item});
  final BarItem item;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
    decoration: BoxDecoration(color: CpeColors.tile, borderRadius: BorderRadius.circular(8)),
    child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
      Text(item.label, style: TextStyle(color: CpeColors.muted, fontSize: 11, fontWeight: FontWeight.w600)),
      const SizedBox(height: 3),
      Text(item.value, style: TextStyle(color: item.color, fontSize: 16, fontWeight: FontWeight.w900)),
      const SizedBox(height: 4),
      ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(
          value: item.progress, minHeight: 3,
          backgroundColor: CpeColors.input,
          valueColor: AlwaysStoppedAnimation(item.color),
        ),
      ),
    ]),
  );
}

/// 6. Power grid - dBm values with color coding
class _PowerGrid extends StatelessWidget {
  const _PowerGrid({required this.model});
  final DashboardModel model;

  static Color _powerColor(String val) {
    if (!val.contains('dBm')) return CpeColors.ink;
    final n = double.tryParse(val.replaceAll(RegExp(r'[^\d.\-]'), '')) ?? 0;
    if (n >= 23) return const Color(0xffe74c3c);
    if (n >= 18) return const Color(0xffe67e22);
    if (n >= 12) return const Color(0xffd4a017);
    return const Color(0xff30a14e);
  }

  @override
  Widget build(BuildContext context) {
    final base = model.powerItems.map((e) => e).toList();
    while (base.length < 4) base.add(KvItem('--', '--'));
    return Wrap(spacing: 8, runSpacing: 8, children: [
      for (final item in base)
        SizedBox(width: 90, child: _PTile(label: item.label, value: item.value)),
      // BW + TM placeholders
      _PTile(label: 'DL BW', value: '--'),
      _PTile(label: 'UL BW', value: '--'),
      _PTile(label: 'TM', value: '--'),
    ]);
  }
}

class _PTile extends StatelessWidget {
  const _PTile({required this.label, required this.value});
  final String label; final String value;

  Color get c {
    if (!value.contains('dBm') && !value.startsWith('TM')) return CpeColors.ink;
    final n = double.tryParse(value.replaceAll(RegExp(r'[^\d.\-]'), '')) ?? 0;
    if (n >= 23) return const Color(0xffe74c3c);
    if (n >= 18) return const Color(0xffe67e22);
    if (n >= 12) return const Color(0xffd4a017);
    return const Color(0xff30a14e);
  }

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 10),
    decoration: BoxDecoration(color: CpeColors.tile, borderRadius: BorderRadius.circular(8)),
    child: Column(children: [
      Text(label, style: TextStyle(color: CpeColors.muted, fontSize: 10, fontWeight: FontWeight.w600)),
      const SizedBox(height: 3),
      Text(value, style: TextStyle(color: c, fontSize: 13, fontWeight: FontWeight.w900)),
    ]),
  );
}

/// 7. Link info - downlink/uplink side by side
class _LinkInfoRow extends StatelessWidget {
  const _LinkInfoRow({required this.model});
  final DashboardModel model;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Expanded(child: _SectionCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('下行链路', style: TextStyle(color: CpeColors.ink, fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 8),
        for (final it in model.downlinkItems) Padding(padding: const EdgeInsets.only(bottom: 3), child: _ILine(it)),
      ]))),
      const SizedBox(width: 10),
      Expanded(child: _SectionCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('上行链路', style: TextStyle(color: CpeColors.ink, fontWeight: FontWeight.w700, fontSize: 13)),
        const SizedBox(height: 8),
        for (final it in model.uplinkItems) Padding(padding: const EdgeInsets.only(bottom: 3), child: _ILine(it)),
      ]))),
    ],
  );
}

class _ILine extends StatelessWidget {
  const _ILine(this.item);
  final KvItem item;

  @override
  Widget build(BuildContext context) => Row(children: [
    Text(item.label, style: TextStyle(color: CpeColors.muted, fontSize: 12, fontWeight: FontWeight.w600)),
    const Spacer(),
    Text(item.value, style: TextStyle(color: CpeColors.ink, fontSize: 12, fontWeight: FontWeight.w800)),
  ]);
}

/// 8. Device info grid - dense 2-column rows matching CPE++ screenshot
class _DeviceGrid extends StatelessWidget {
  const _DeviceGrid({required this.model});
  final DashboardModel model;

  String get _deviceModel => model.subtitle.split('/').first.trim();
  String get _swVersion => model.identityItems.length > 3 ? model.identityItems[3].value : '--';
  String get _temperature {
    for (final item in model.trafficItems) {
      if (item.label.toLowerCase().contains('temp')) return formatTemperature(item.value);
    }
    for (final item in model.identityItems) {
      if (item.label.toLowerCase().contains('temp')) return formatTemperature(item.value);
    }
    return '--';
  }

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      // Row 1: 3 columns
      Row(children: [
        Expanded(child: _DITile(l: '设备型号', v: _deviceModel)),
        const SizedBox(width: 8),
        Expanded(child: _DITile(l: '软件版本', v: _swVersion)),
        const SizedBox(width: 8),
        Expanded(child: _DITile(l: '当前温度', v: _temperature)),
      ]),
      const SizedBox(height: 8),
      // Row 2
      Row(children: [
        Expanded(child: _DITile(l: '下载速率', v: model.downloadRate)),
        const SizedBox(width: 8),
        Expanded(child: _DITile(l: '上传速率', v: model.uploadRate)),
      ]),
      const SizedBox(height: 8),
      // Row 3
      Row(children: [
        Expanded(child: _DITile(l: '当日下载', v: model.trafficItems.isNotEmpty ? formatBytes(model.trafficItems[0].value) : '--')),
        const SizedBox(width: 8),
        Expanded(child: _DITile(l: '当日上传', v: model.trafficItems.length > 1 ? formatBytes(model.trafficItems[1].value) : '--')),
      ]),
      const SizedBox(height: 8),
      // Row 4
      Row(children: [
        Expanded(child: _DITile(l: '当月下载', v: model.vendor == CpeVendor.fiberhome && model.trafficItems.length > 4 ? formatBytes(model.trafficItems[4].value) : '--')),
        const SizedBox(width: 8),
        Expanded(child: _DITile(l: '当月上传', v: model.vendor == CpeVendor.fiberhome && model.trafficItems.length > 5 ? formatBytes(model.trafficItems[5].value) : '--')),
      ]),
      const SizedBox(height: 8),
      // Row 5
      Row(children: [
        Expanded(child: _DITile(l: '系统运行时长', v: model.trafficItems.length > 2 ? model.trafficItems[2].value : '--')),
        const SizedBox(width: 8),
        Expanded(child: _DITile(l: '当前上网时长', v: '--')),
      ]),
    ],
  );
}

class _DI { const _DI(this.k, this.v); final String k, v; }

class _DITile extends StatelessWidget {
  const _DITile({required this.l, required this.v});
  final String l, v;

  @override
  Widget build(BuildContext context) => l.isEmpty ? const SizedBox.shrink()
      : Row(children: [
        Text(l, style: TextStyle(color: CpeColors.muted, fontSize: 11.5, fontWeight: FontWeight.w600)),
        const Spacer(), Text(v, style: TextStyle(color: CpeColors.ink, fontSize: 11.5, fontWeight: FontWeight.w800)),
      ]);
}


class CarrierWorkspace extends StatelessWidget {
  const CarrierWorkspace({required this.model, super.key});

  final DashboardModel model;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '邻区信息'),
              const SizedBox(height: 12),
              CellTable(cells: model.neighborCells),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '载波聚合'),
              const SizedBox(height: 12),
              EmptyOrText(
                text: model.caSummary,
                empty: '当前没有可展示的辅载波数据。',
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class LockWorkspace extends StatelessWidget {
  const LockWorkspace({
    required this.vendor,
    required this.model,
    required this.lteBandController,
    required this.nrBandController,
    required this.lockArfcnController,
    required this.lockPciController,
    required this.lteLockArfcnController,
    required this.lteLockPciController,
    required this.onAuto,
    required this.onUnlock,
    required this.onFiberhomeNetwork,
    required this.onFiberhomeBands,
    required this.onFiberhomeCell,
    required this.onFiberhomeDualCell,
    super.key,
  });

  final CpeVendor vendor;
  final DashboardModel model;
  final TextEditingController lteBandController;
  final TextEditingController nrBandController;
  final TextEditingController lockArfcnController;
  final TextEditingController lockPciController;
  final TextEditingController lteLockArfcnController;
  final TextEditingController lteLockPciController;
  final VoidCallback? onAuto;
  final VoidCallback? onUnlock;
  final ValueChanged<FiberhomeNetworkPreset>? onFiberhomeNetwork;
  final VoidCallback? onFiberhomeBands;
  final VoidCallback? onFiberhomeCell;
  final VoidCallback? onFiberhomeDualCell;

  @override
  Widget build(BuildContext context) {
    final isFiberhome = vendor == CpeVendor.fiberhome;
    return Column(
      children: [
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '配置操作'),
              const SizedBox(height: 12),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  ActionPill(
                    label: '自动模式',
                    icon: Icons.restart_alt,
                    onPressed: onAuto,
                  ),
                  ActionPill(
                    label: isFiberhome ? '清空小区' : '解除锁频',
                    icon: Icons.lock_open,
                    onPressed: onUnlock,
                  ),
                ],
              ),
              const SizedBox(height: 14),
              if (isFiberhome) ...[
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: FiberhomeNetworkPreset.values
                      .map(
                        (preset) => ActionPill(
                          label: preset.label,
                          icon: Icons.network_cell,
                          onPressed: onFiberhomeNetwork == null
                              ? null
                              : () => onFiberhomeNetwork!(preset),
                        ),
                      )
                      .toList(),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: FieldBlock(
                        label: 'LTE Band',
                        helper: '例如 1,3,8',
                        child: TextField(controller: lteBandController),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FieldBlock(
                        label: 'NR Band',
                        helper: '例如 41,77,78',
                        child: TextField(controller: nrBandController),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: onFiberhomeBands,
                    icon: const Icon(Icons.save_outlined),
                    label: const Text('写入锁 Band'),
                  ),
                ),
                const SizedBox(height: 14),
                Row(
                  children: [
                    Expanded(
                      child: FieldBlock(
                        label: 'NR ARFCN',
                        helper: 'HAR 示例 627264',
                        child: TextField(controller: lockArfcnController),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FieldBlock(
                        label: 'PCI',
                        helper: 'HAR 示例 553',
                        child: TextField(controller: lockPciController),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: FieldBlock(
                        label: 'LTE ARFCN',
                        helper: 'HAR 示例 1000',
                        child: TextField(controller: lteLockArfcnController),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FieldBlock(
                        label: 'LTE PCI',
                        helper: 'HAR 示例 553',
                        child: TextField(controller: lteLockPciController),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: OutlinedButton.icon(
                        onPressed: onFiberhomeCell,
                        icon: const Icon(Icons.cell_tower),
                        label: const Text('执行 NR 锁小区'),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: onFiberhomeDualCell,
                        icon: const Icon(Icons.published_with_changes),
                        label: const Text('执行 4G+5G 同锁'),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                const InfoStrip(
                  title: '烽火写入格式',
                  body:
                      '按 HAR 写入 app_set_cell_list：NR 使用 act=2，LTE 使用 act=1，写完立即读回锁小区列表。',
                ),
              ] else
                EmptyOrText(
                  text: model.lockSummary,
                  empty: 'Huawei 详细锁频表单沿用旧 CLI；移动端本轮先保留自动模式和解除锁频。',
                ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        Surface(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const SectionTitle(title: '当前锁定状态'),
              const SizedBox(height: 10),
              DenseKvGrid(items: model.lockItems),
            ],
          ),
        ),
      ],
    );
  }
}

class SpeedWorkspace extends StatelessWidget {
  const SpeedWorkspace({
    required this.model,
    required this.rawOutput,
    super.key,
  });

  final DashboardModel model;
  final String rawOutput;

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        TrafficPanel(model: model),
        const SizedBox(height: 12),
        RawPanel(rawOutput: rawOutput),
      ],
    );
  }
}

// Replaced by _ConnectionHeader inside PccWorkspace
@Deprecated('Use _ConnectionHeader instead')
class PrimaryCellCard extends StatelessWidget {
  const PrimaryCellCard({required this.model, super.key});
  final DashboardModel model;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

@Deprecated('Use _MetricTile instead')
class _MetricRow extends StatelessWidget {
  const _MetricRow({required this.label, required this.value, this.compact = false});
  final String label; final String value; final bool compact;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}
@Deprecated('Use _RfQualityGrid inside PccWorkspace instead')
class SignalQualityPanel extends StatelessWidget {
  const SignalQualityPanel({required this.model, super.key});
  final DashboardModel model;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class SimInfoPanel extends StatelessWidget {
  const SimInfoPanel({required this.model, super.key});

  final DashboardModel model;

  @override
  Widget build(BuildContext context) {
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: 'SIM 信息'),
          const SizedBox(height: 12),
          DenseKvGrid(items: model.simItems, compact: true),
        ],
      ),
    );
  }
}

@Deprecated('Use _PowerGrid inside PccWorkspace instead')
class PowerPanel extends StatelessWidget {
  const PowerPanel({required this.model, super.key});
  final DashboardModel model;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

@Deprecated('Use _LinkPanels inside PccWorkspace instead')
class LinkPanel extends StatelessWidget {
  const LinkPanel({required this.model, super.key});
  final DashboardModel model;
  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

class TrafficPanel extends StatelessWidget {
  const TrafficPanel({required this.model, super.key});

  final DashboardModel model;

  @override
  Widget build(BuildContext context) {
    return Surface(
      tinted: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: '设备统计'),
          const SizedBox(height: 14),
          DenseKvGrid(items: model.trafficItems),
        ],
      ),
    );
  }
}

class CellTable extends StatelessWidget {
  const CellTable({required this.cells, super.key});

  final List<Map<String, String>> cells;

  @override
  Widget build(BuildContext context) {
    if (cells.isEmpty) {
      return const EmptyOrText(
        text: '',
        empty: '读取状态后显示邻区或锁小区记录。',
      );
    }
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: Table(
        columnWidths: const {
          0: FlexColumnWidth(1.0),
          1: FlexColumnWidth(1.4),
          2: FlexColumnWidth(1.0),
          3: FlexColumnWidth(1.1),
          4: FlexColumnWidth(1.1),
        },
        children: [
          TableRow(
            decoration: BoxDecoration(color: CpeColors.tileAccent),
            children: [
              TableCellText('BAND', head: true),
              TableCellText('ARFCN', head: true),
              TableCellText('PCI', head: true),
              TableCellText('RSRP', head: true),
              TableCellText('RSRQ', head: true),
            ],
          ),
          for (var index = 0; index < cells.take(8).length; index += 1)
            TableRow(
              decoration: BoxDecoration(
                color: index.isEven ? CpeColors.tile : CpeColors.panel,
              ),
              children: [
                TableCellText(
                    cells[index]['band'] ?? cells[index]['act'] ?? '--'),
                TableCellText(
                    cells[index]['earfcn'] ?? cells[index]['arfcn'] ?? '--'),
                TableCellText(cells[index]['pci'] ?? '--'),
                TableCellText(cells[index]['rsrp'] ?? '--'),
                TableCellText(cells[index]['rsrq'] ?? '--'),
              ],
            ),
        ],
      ),
    );
  }
}

class DenseKvGrid extends StatelessWidget {
  const DenseKvGrid({
    required this.items,
    this.compact = false,
    super.key,
  });

  final List<KvItem> items;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final columns = constraints.maxWidth > 560 ? 3 : 2;
        return GridView.builder(
          itemCount: items.length,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: columns,
            crossAxisSpacing: 10,
            mainAxisSpacing: 10,
            mainAxisExtent: compact ? 86 : 98,
          ),
          itemBuilder: (context, index) => KvTile(item: items[index]),
        );
      },
    );
  }
}

class KvTile extends StatelessWidget {
  const KvTile({required this.item, super.key});

  final KvItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: item.highlight ? CpeColors.tileAccent : CpeColors.tile,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CpeColors.border.withValues(alpha: 0.5)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            item.label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: CpeColors.muted,
              fontWeight: FontWeight.w600,
              fontSize: 11,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            item.value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: CpeColors.ink,
              fontWeight: FontWeight.w900,
              fontSize: 16,
            ),
          ),
        ],
      ),
    );
  }
}

class MetricBar extends StatelessWidget {
  const MetricBar({required this.item, super.key});

  final BarItem item;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: CpeColors.tile,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          SizedBox(
            width: 52,
            child: Text(
              item.label,
              style: TextStyle(
                color: CpeColors.muted,
                fontWeight: FontWeight.w700,
                fontSize: 13,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(
                value: item.progress,
                minHeight: 14,
                backgroundColor: CpeColors.input,
                valueColor: AlwaysStoppedAnimation(item.color),
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 58,
            child: Text(
              item.value,
              textAlign: TextAlign.right,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: CpeColors.ink,
                fontWeight: FontWeight.w900,
                fontSize: 14,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class PowerRow extends StatelessWidget {
  const PowerRow({
    required this.label,
    required this.value,
    super.key,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 11),
      decoration: BoxDecoration(
        color: CpeColors.tile,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: CpeColors.ink,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: CpeColors.ink,
              fontWeight: FontWeight.w900,
            ),
          ),
        ],
      ),
    );
  }
}

class MiniPanel extends StatelessWidget {
  const MiniPanel({
    required this.title,
    required this.items,
    super.key,
  });

  final String title;
  final List<KvItem> items;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CpeColors.tile,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: CpeColors.ink,
              fontWeight: FontWeight.w900,
              fontSize: 18,
            ),
          ),
          const SizedBox(height: 10),
          for (final item in items)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      item.label,
                      style: TextStyle(
                        color: CpeColors.muted,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                  ),
                  Text(
                    item.value,
                    style: TextStyle(
                      color: CpeColors.ink,
                      fontWeight: FontWeight.w900,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class SpeedTile extends StatelessWidget {
  const SpeedTile({
    required this.label,
    required this.value,
    super.key,
  });

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 14),
      decoration: BoxDecoration(
        color: CpeColors.tile,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Expanded(
            child: Text(
              label,
              style: TextStyle(
                color: CpeColors.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Text(
            value,
            style: TextStyle(
              color: CpeColors.ink,
              fontWeight: FontWeight.w900,
              fontSize: 17,
            ),
          ),
        ],
      ),
    );
  }
}

class RawPanel extends StatelessWidget {
  const RawPanel({required this.rawOutput, super.key});

  final String rawOutput;

  @override
  Widget build(BuildContext context) {
    return Surface(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const SectionTitle(title: '原始快照'),
          const SizedBox(height: 8),
          ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 120),
            child: SelectableText(
              rawOutput.isEmpty ? '暂无数据。' : rawOutput,
              style: TextStyle(
                fontFamily: 'monospace',
                fontSize: 12.5,
                height: 1.35,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class FieldBlock extends StatelessWidget {
  const FieldBlock({
    required this.label,
    required this.helper,
    required this.child,
    super.key,
  });

  final String label;
  final String helper;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: CpeColors.ink,
            fontWeight: FontWeight.w800,
          ),
        ),
        const SizedBox(height: 6),
        child,
        const SizedBox(height: 4),
        Text(
          helper,
          style: TextStyle(color: CpeColors.muted, fontSize: 12),
        ),
      ],
    );
  }
}

class StatusChip extends StatelessWidget {
  const StatusChip({
    required this.label,
    this.strong = false,
    this.color,
    super.key,
  });

  final String label;
  final bool strong;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: color?.withValues(alpha: 0.14) ??
            (strong ? CpeColors.tileAccent : CpeColors.tile),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: color ?? CpeColors.ink,
          fontWeight: FontWeight.w900,
        ),
      ),
    );
  }
}

class ActionPill extends StatelessWidget {
  const ActionPill({
    required this.label,
    required this.icon,
    required this.onPressed,
    super.key,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) {
    return FilledButton.tonalIcon(
      onPressed: onPressed,
      icon: Icon(icon, size: 18),
      label: Text(label),
    );
  }
}

class InfoStrip extends StatelessWidget {
  const InfoStrip({
    required this.title,
    required this.body,
    super.key,
  });

  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: CpeColors.notice,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CpeColors.noticeBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(
              color: CpeColors.noticeText,
              fontWeight: FontWeight.w900,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            body,
            style: TextStyle(color: CpeColors.noticeText),
          ),
        ],
      ),
    );
  }
}

class EmptyOrText extends StatelessWidget {
  const EmptyOrText({
    required this.text,
    required this.empty,
    super.key,
  });

  final String text;
  final String empty;

  @override
  Widget build(BuildContext context) {
    return Text(
      text.trim().isEmpty ? empty : text,
      style: TextStyle(
        color: CpeColors.muted,
        fontWeight: FontWeight.w600,
        height: 1.4,
      ),
    );
  }
}

class TableCellText extends StatelessWidget {
  const TableCellText(this.text, {this.head = false, super.key});

  final String text;
  final bool head;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11, horizontal: 8),
      child: Text(
        text,
        textAlign: TextAlign.center,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: CpeColors.ink,
          fontWeight: head ? FontWeight.w900 : FontWeight.w700,
        ),
      ),
    );
  }
}

class ErrorPanel extends StatelessWidget {
  const ErrorPanel({required this.message, super.key});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: CpeColors.error,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CpeColors.errorBorder),
      ),
      child: Text(
        message,
        style: TextStyle(color: CpeColors.errorText),
      ),
    );
  }
}

class Surface extends StatelessWidget {
  const Surface({
    required this.child,
    this.tinted = false,
    super.key,
  });

  final Widget child;
  final bool tinted;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: tinted ? CpeColors.panel : CpeColors.surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: CpeColors.border),
        boxShadow: [
          BoxShadow(
            blurRadius: 24,
            offset: Offset(0, 12),
            color: CpeColors.shadow,
          ),
        ],
      ),
      child: child,
    );
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle({required this.title, super.key});
  final String title;

  @override
  Widget build(BuildContext context) {
    return Text(
      title,
      style: TextStyle(
        color: CpeColors.ink,
        fontWeight: FontWeight.w700,
        fontSize: 14,
      ),
    );
  }
}

class DashboardModel {
  const DashboardModel({
    required this.vendor,
    required this.headerTitle,
    required this.subtitle,
    required this.modeBadge,
    required this.operatorBadge,
    required this.rrcBadge,
    required this.primaryItems,
    required this.identityItems,
    required this.signalBars,
    required this.modulationItems,
    required this.powerItems,
    required this.simItems,
    required this.downlinkItems,
    required this.uplinkItems,
    required this.trafficItems,
    required this.neighborCells,
    required this.caSummary,
    required this.lockSummary,
    required this.lockItems,
    required this.downloadRate,
    required this.uploadRate,
  });

  final CpeVendor vendor;
  final String headerTitle;
  final String subtitle;
  final String modeBadge;
  final String operatorBadge;
  final String rrcBadge;
  final List<KvItem> primaryItems;
  final List<KvItem> identityItems;
  final List<BarItem> signalBars;
  final List<KvItem> modulationItems;
  final List<KvItem> powerItems;
  final List<KvItem> simItems;
  final List<KvItem> downlinkItems;
  final List<KvItem> uplinkItems;
  final List<KvItem> trafficItems;
  final List<Map<String, String>> neighborCells;
  final String caSummary;
  final String lockSummary;
  final List<KvItem> lockItems;
  final String downloadRate;
  final String uploadRate;

  factory DashboardModel.from({
    required CpeVendor vendor,
    required DisplayMode displayMode,
    required Map<String, dynamic>? snapshot,
    required Map<String, List<Map<String, String>>>? neighbors,
  }) {
    if (vendor == CpeVendor.fiberhome) {
      return DashboardModel._fiberhome(snapshot, neighbors, displayMode);
    }
    return DashboardModel._huawei(snapshot, neighbors, displayMode);
  }

  factory DashboardModel._huawei(
    Map<String, dynamic>? snapshot,
    Map<String, List<Map<String, String>>>? neighbors,
    DisplayMode displayMode,
  ) {
    final signal = mapAt(snapshot, 'signal');
    final traffic = mapAt(snapshot, 'traffic');
    final status = mapAt(snapshot, 'status');
    final plmn = mapAt(snapshot, 'plmn');
    final netMode = mapAt(snapshot, 'netMode');
    final mode = firstValue(signal, ['mode'], fallback: '--');
    final nrMode = mode == '12' ? '5G SA/NR' : (mode == '7' ? 'LTE' : 'NR/LTE');
    final tacDecimal = decimalText(parseTacDecimal(signal['tac']));
    final gci = firstValue(signal, ['cell_id', 'gci', 'nr_cell_id']);
    final gnbId = firstValue(
      signal,
      ['gnb_id', 'nr_gNB_ID', 'enodeb_id'],
      fallback: '',
    );
    final nrLocalCellId = firstValue(
      signal,
      ['nr_cell_id_4bit', 'local_cell_id', 'cellid'],
      fallback: '',
    );
    final computedGci = computeGci(gnbId: gnbId, cellId: nrLocalCellId);
    final displayedGci = computedGci ?? parseFlexibleInt(gci);
    final gnbCell = deriveNrGnbCell(
      gnbId: gnbId,
      localCellId: nrLocalCellId,
      gci: gci,
    );
    final eci = computeEci(
      enbId: signal['enodeb_id'],
      cellId: firstValue(signal, ['lte_cell_id', 'cellid'], fallback: ''),
    );
    return DashboardModel(
      vendor: CpeVendor.huawei,
      headerTitle: mode == '7' ? 'LTE 主小区' : 'NR 主小区',
      subtitle: nrMode,
      modeBadge: mode == '12' ? '5G SA' : (netMode['NetworkMode'] ?? nrMode),
      operatorBadge: operatorLabel(plmn),
      rrcBadge: signal['rrc_status'] == '1'
          ? 'RRC 正常'
          : 'RRC ${signal['rrc_status'] ?? '--'}',
      primaryItems: [
        KvItem(metricLabel(displayMode, '频段', 'bandInfo'),
            cleanBand(firstValue(signal, ['bandInfo', 'band']))),
        KvItem(metricLabel(displayMode, '物理小区', 'pci'),
            firstValue(signal, ['pci'])),
        KvItem(metricLabel(displayMode, '频点', 'nrearfcn'),
            firstValue(signal, ['nrearfcn', 'earfcn'])),
        KvItem(metricLabel(displayMode, '下行带宽', 'nrdlbandwidth'),
            firstValue(signal, ['nrdlbandwidth', 'bandwidth'])),
        KvItem(metricLabel(displayMode, 'TAC 十进制', 'tac_decimal'), tacDecimal),
        KvItem(metricLabel(displayMode, 'GCI 十进制', 'gci_decimal'),
            decimalText(displayedGci)),
      ],
      identityItems: [
        KvItem(metricLabel(displayMode, 'gNB - Cell', 'gNB_Cell'), gnbCell),
        KvItem(metricLabel(displayMode, 'NR CellID', 'cell_id'),
            decimalText(parseFlexibleInt(gci))),
        KvItem(metricLabel(displayMode, 'TAC 原始', 'tac'),
            firstValue(signal, ['tac'])),
        KvItem(metricLabel(displayMode, '下行/上行频率', 'DL_UL_Freq'),
            dlUlText(signal)),
        KvItem(
            metricLabel(displayMode, 'ECI(LTE)', 'eci_lte'), decimalText(eci)),
      ],
      signalBars: [
        BarItem.rsrp(firstValue(signal, ['nrrsrp', 'rsrp'])),
        BarItem.rsrq(firstValue(signal, ['nrrsrq', 'rsrq'])),
        BarItem.sinr(firstValue(signal, ['nrsinr', 'sinr'])),
        BarItem.rssi(firstValue(signal, ['nrrssi', 'rssi'])),
        BarItem.cqi(firstValue(signal, ['nrcqi0', 'cqi'])),
      ],
      modulationItems: [
        KvItem(metricLabel(displayMode, '下行调制', 'DL_Modulation'),
            parseModulation(firstValue(signal, ['nrdlmcs']))),
        KvItem(metricLabel(displayMode, '上行调制', 'UL_Modulation'),
            parseModulation(firstValue(signal, ['nrulmcs']))),
      ],
      powerItems: parsePower(firstValue(signal, ['nrtxpower'])),
      simItems: [
        KvItem(metricLabel(displayMode, '上行签约带宽', 'UL_AMBR'), '--'),
        KvItem(metricLabel(displayMode, '下行签约带宽', 'DL_AMBR'), '--'),
        KvItem(metricLabel(displayMode, '承载等级', 'QCI'),
            firstValue(signal, ['QCI', 'qci'])),
      ],
      downlinkItems: [
        KvItem(metricLabel(displayMode, '调制', 'DL_Modulation'),
            parseModulation(firstValue(signal, ['nrdlmcs']))),
        KvItem(metricLabel(displayMode, 'MCS', 'nrdlmcs'),
            parseMcs(firstValue(signal, ['nrdlmcs']))),
        KvItem(metricLabel(displayMode, 'RANK', 'nrrank'),
            firstValue(signal, ['nrrank'])),
        KvItem(metricLabel(displayMode, 'RB', 'nrdlrb'),
            firstValue(signal, ['nrdlrb', 'dl_rb'], fallback: '--')),
      ],
      uplinkItems: [
        KvItem(metricLabel(displayMode, '调制', 'UL_Modulation'),
            parseModulation(firstValue(signal, ['nrulmcs']))),
        KvItem(metricLabel(displayMode, 'MCS', 'nrulmcs'),
            parseMcs(firstValue(signal, ['nrulmcs']))),
        KvItem(metricLabel(displayMode, 'RANK', 'UL_RANK'),
            firstValue(signal, ['nrrank', 'ul_rank'], fallback: '--')),
        KvItem(metricLabel(displayMode, 'RB', 'nrulrb'),
            firstValue(signal, ['nrulrb', 'ul_rb'], fallback: '--')),
      ],
      trafficItems: [
        KvItem(metricLabel(displayMode, '当前下载', 'CurrentDownload'),
            formatBytes(firstValue(traffic, ['CurrentDownload']))),
        KvItem(metricLabel(displayMode, '当前上传', 'CurrentUpload'),
            formatBytes(firstValue(traffic, ['CurrentUpload']))),
        KvItem(metricLabel(displayMode, '当前时长', 'CurrentConnectTime'),
            formatBytes(firstValue(traffic, ['CurrentConnectTime']))),
        KvItem(metricLabel(displayMode, '总下载', 'TotalDownload'),
            formatBytes(firstValue(traffic, ['TotalDownload']))),
        KvItem(metricLabel(displayMode, '总上传', 'TotalUpload'),
            formatBytes(firstValue(traffic, ['TotalUpload']))),
        KvItem(metricLabel(displayMode, 'WiFi 设备', 'CurrentWifiUser'),
            '${status['CurrentWifiUser'] ?? '--'} / ${status['TotalWifiUser'] ?? '--'}'),
      ],
      neighborCells: neighbors?['nr'] ?? <Map<String, String>>[],
      caSummary: 'NR 辅小区接口已预留；当前主界面优先展示邻区和 PCC。',
      lockSummary:
          'NetworkMode=${netMode['NetworkMode'] ?? '--'}  LTEBand=${netMode['LTEBand'] ?? '--'}',
      lockItems: [
        KvItem('NetworkMode', netMode['NetworkMode'] ?? '--'),
        KvItem('networkOption', netMode['networkOption'] ?? '--'),
        KvItem('LTEBand', netMode['LTEBand'] ?? '--'),
        KvItem('NetworkBand', netMode['NetworkBand'] ?? '--'),
      ],
      downloadRate: rateText(traffic['CurrentDownloadRate']),
      uploadRate: rateText(traffic['CurrentUploadRate']),
    );
  }

  factory DashboardModel._fiberhome(
    Map<String, dynamic>? snapshot,
    Map<String, List<Map<String, String>>>? neighbors,
    DisplayMode displayMode,
  ) {
    final base = mapAt(snapshot, 'baseInfo');
    final network = mapAt(snapshot, 'networkInfo');
    final lockBand = mapAt(snapshot, 'lockBand');
    final cellList = mapAt(snapshot, 'cellList');
    final session = mapAt(snapshot, 'session');
    final airplane = mapAt(snapshot, 'airplane');
    final mode = firstValue(base, ['WorkMode'],
        fallback: fiberhomeNetworkModeText(network));
    final enabled = cellList['enable'] == '1' ? '开启' : '关闭';
    final tac = firstValue(base, ['TAC']);
    final ncgi = firstValue(base, ['NCGI']);
    final ecgi = firstValue(base, ['ECGI']);
    final gnbCell = deriveNrGnbCell(gci: ncgi);
    final primaryPci = firstCsvValue(firstValue(base, ['PCI_NBR']));
    final primaryArfcn = firstCsvValue(firstValue(base, ['EARFCN_NBR']));
    final primaryBand =
        firstCsvValue(firstValue(base, ['NR_Band', 'BAND_NBR', 'BAND']));
    final nrBand = primaryBand == '--' || primaryBand.startsWith('N')
        ? primaryBand
        : 'N$primaryBand';
    return DashboardModel(
      vendor: CpeVendor.fiberhome,
      headerTitle: '烽火 NR 主小区',
      subtitle: '${firstValue(base, [
            'modelName'
          ], fallback: 'Fiberhome')} / FHTOOLAPIS',
      modeBadge: mode,
      operatorBadge: plmnLabel(firstValue(base, ['PLMN'])),
      rrcBadge: base['RRCStatus'] == '1'
          ? 'RRC 正常'
          : 'RRC ${base['RRCStatus'] ?? '--'}',
      primaryItems: [
        KvItem(metricLabel(displayMode, '5G 频段', 'NR_Band'), nrBand),
        KvItem(metricLabel(displayMode, '物理小区', 'PCI_NBR'), primaryPci),
        KvItem(metricLabel(displayMode, '频点', 'EARFCN_NBR'), primaryArfcn),
        KvItem(metricLabel(displayMode, '下行带宽', 'DlBandWidth'),
            firstValue(base, ['DlBandWidth'])),
        KvItem(metricLabel(displayMode, 'TAC 十进制', 'TAC'),
            decimalText(parseTacDecimal(tac))),
        KvItem(metricLabel(displayMode, 'GCI 十进制', 'NCGI'),
            decimalText(parseFlexibleInt(ncgi))),
      ],
      identityItems: [
        KvItem(metricLabel(displayMode, 'gNB - Cell', 'gNB_Cell'), gnbCell),
        KvItem(metricLabel(displayMode, 'NCGI', 'NCGI'),
            decimalText(parseFlexibleInt(ncgi))),
        KvItem(metricLabel(displayMode, 'ECGI', 'ECGI'),
            ecgi == '--' ? decimalText(parseFlexibleInt(ecgi)) : ecgi),
        KvItem(metricLabel(displayMode, '软件版本', 'Software_version'),
            firstValue(base, ['Software_version'])),
        KvItem(metricLabel(displayMode, '温度', 'Temperature'),
            formatTemperature(base['Temperature'])),
        KvItem(metricLabel(displayMode, '会话', 'sessionid'),
            maskSession(session['sessionid'])),
      ],
      signalBars: [
        BarItem.rsrp(firstValue(base, ['SSB_RSRP', 'RSRP'])),
        BarItem.rsrq(firstValue(base, ['RSRQ'])),
        BarItem.sinr(firstValue(base, ['SSB_SINR', 'SINR'])),
        BarItem.rssi(firstValue(base, ['RSSI'])),
        BarItem.cqi(firstValue(base, ['CQI'])),
      ],
      modulationItems: [
        KvItem(
          metricLabel(displayMode, '下行调制', 'DL_Modulation'),
          fiberhomeModulation(
            base,
            rawKeys: const ['DL_Modulation', 'DlModulation', 'DLModulation'],
            mcsKey: 'DlMCS',
            displayMode: displayMode,
          ),
        ),
        KvItem(
          metricLabel(displayMode, '上行调制', 'UL_Modulation'),
          fiberhomeModulation(
            base,
            rawKeys: const ['UL_Modulation', 'UlModulation', 'ULModulation'],
            mcsKey: 'UlMCS',
            displayMode: displayMode,
          ),
        ),
      ],
      powerItems: [
        KvItem(metricLabel(displayMode, 'PUSCH 发射功率', 'PUSCH_TX_Power'),
            dbmText(base['PUSCH_TX_Power'])),
        KvItem(metricLabel(displayMode, 'PUCCH 发射功率', 'PUCCH_TX_Power'),
            dbmText(base['PUCCH_TX_Power'])),
      ],
      simItems: [
        KvItem(metricLabel(displayMode, '上行签约带宽', 'UL_AMBR'),
            ambrMbpsText(base['UL_AMBR'])),
        KvItem(metricLabel(displayMode, '下行签约带宽', 'DL_AMBR'),
            ambrMbpsText(base['DL_AMBR'])),
        KvItem(
            metricLabel(displayMode, '承载等级', 'QCI'), firstValue(base, ['QCI'])),
      ],
      downlinkItems: [
        KvItem(metricLabel(displayMode, '调制', 'DL_Modulation'),
            fiberhomeModulation(base, rawKeys: const ['DL_Modulation', 'DlModulation'], mcsKey: 'DlMCS', displayMode: displayMode)),
        KvItem(metricLabel(displayMode, 'MCS', 'DlMCS'),
            firstValue(base, ['DlMCS'])),
        KvItem(metricLabel(displayMode, 'RANK', 'DlMimo'),
            firstValue(base, ['DlMimo'])),
        KvItem(metricLabel(displayMode, 'RB', 'DlBandWidth'),
            firstValue(base, ['DlBandWidth'])),
      ],
      uplinkItems: [
        KvItem(metricLabel(displayMode, '调制', 'UL_Modulation'),
            fiberhomeModulation(base, rawKeys: const ['UL_Modulation', 'UlModulation'], mcsKey: 'UlMCS', displayMode: displayMode)),
        KvItem(metricLabel(displayMode, 'MCS', 'UlMCS'),
            firstValue(base, ['UlMCS'])),
        KvItem(metricLabel(displayMode, 'RANK', 'UlMimo'),
            firstValue(base, ['UlMimo'])),
        KvItem(metricLabel(displayMode, 'RB', 'UlBandWidth'),
            firstValue(base, ['UlBandWidth'])),
      ],
      trafficItems: [
        KvItem(metricLabel(displayMode, '当前下载', 'RxSpeed'),
            rateText(base['RxSpeed'])),
        KvItem(metricLabel(displayMode, '当前上传', 'TxSpeed'),
            rateText(base['TxSpeed'])),
        KvItem(metricLabel(displayMode, '今日下载', 'todayRxBytes'),
            formatBytes(base['todayRxBytes'])),
        KvItem(metricLabel(displayMode, '今日上传', 'todayTxBytes'),
            formatBytes(base['todayTxBytes'])),
        KvItem(metricLabel(displayMode, '当月下载', 'monthRxBytes'),
            formatBytes(base['monthRxBytes'])),
        KvItem(metricLabel(displayMode, '当月上传', 'monthTxBytes'),
            formatBytes(base['monthTxBytes'])),
        KvItem(
            metricLabel(displayMode, 'IMS', 'ims'), firstValue(base, ['ims'])),
        KvItem(metricLabel(displayMode, '连接类型', 'ConnectType'),
            firstValue(base, ['ConnectType'])),
      ],
      neighborCells: neighbors?['nr'] ?? <Map<String, String>>[],
      caSummary:
          '邻区来自 app_get_base_info：${neighbors?['nr']?.length ?? 0} 条；飞行模式=${airplane['airplaneOn'] ?? '--'}。',
      lockSummary:
          'NR=${lockBand['NRLockBAND'] ?? '--'} LTE=${lockBand['LTELockBAND'] ?? '--'}',
      lockItems: [
        KvItem('lockBandEnable', lockBand['lockBandEnable'] ?? '--'),
        KvItem('NRLockBAND', lockBand['NRLockBAND'] ?? '--'),
        KvItem('LTELockBAND', lockBand['LTELockBAND'] ?? '--'),
        KvItem('cellLock', enabled),
        KvItem('networkMode', network['networkMode'] ?? '--'),
        KvItem('ENDC', network['ENDC'] ?? '--'),
      ],
      downloadRate: rateText(base['RxSpeed']),
      uploadRate: rateText(base['TxSpeed']),
    );
  }
}

class KvItem {
  const KvItem(this.label, this.value, {this.highlight = false});

  final String label;
  final String value;
  final bool highlight;
}

class BarItem {
  const BarItem({
    required this.label,
    required this.value,
    required this.progress,
    required this.color,
  });

  factory BarItem.rsrp(String value) {
    final number = numeric(value);
    return BarItem(
      label: 'RSRP',
      value: value,
      progress: normalize(number, -120, -70),
      color: number != null && number > -95 ? CpeColors.good : CpeColors.warn,
    );
  }

  factory BarItem.rsrq(String value) {
    final number = numeric(value);
    return BarItem(
      label: 'RSRQ',
      value: value,
      progress: normalize(number, -20, -6),
      color: number != null && number > -12 ? CpeColors.good : CpeColors.warn,
    );
  }

  factory BarItem.sinr(String value) {
    final number = numeric(value);
    return BarItem(
      label: 'SINR',
      value: value,
      progress: normalize(number, 0, 30),
      color: number != null && number > 12 ? CpeColors.good : CpeColors.warn,
    );
  }

  factory BarItem.rssi(String value) {
    final number = numeric(value);
    return BarItem(
      label: 'RSSI',
      value: value,
      progress: normalize(number, -100, -45),
      color: CpeColors.good,
    );
  }

  factory BarItem.cqi(String value) {
    final number = numeric(value);
    return BarItem(
      label: 'CQI',
      value: value,
      progress: normalize(number, 0, 15),
      color: CpeColors.good,
    );
  }

  factory BarItem.placeholder(String label) {
    return BarItem(
      label: label,
      value: '--',
      progress: 0,
      color: CpeColors.primary,
    );
  }

  final String label;
  final String value;
  final double progress;
  final Color color;
}

class CpeColors {
  static bool _isDark = true;
  static bool get isDark => _isDark;
  static set isDark(bool v) { if (_isDark != v) _isDark = v; }

  static Color get background => _isDark ? const Color(0xff0a0d12) : const Color(0xffF5F7FA);
  static Color get surface    => _isDark ? const Color(0xff111620) : const Color(0xffFFFFFF);
  static Color get panel      => _isDark ? const Color(0xff111620) : const Color(0xffFFFFFF);
  static Color get input      => _isDark ? const Color(0xff1a2030) : const Color(0xffE8ECF1);
  static Color get tile       => _isDark ? const Color(0xff161d2a) : const Color(0xffEDF0F5);
  static Color get tileAccent => _isDark ? const Color(0xff1e2838) : const Color(0xffD6E4F0);
  static Color get border     => _isDark ? const Color(0xff252d3a) : const Color(0xffD1D5DB);
  static Color get primary    => const Color(0xff4493f5);
  static Color get ink        => _isDark ? const Color(0xffe0e6ed) : const Color(0xff1A1D24);
  static Color get muted      => _isDark ? const Color(0xff7a869a) : const Color(0xff6B7280);
  static Color get good       => _isDark ? const Color(0xff30a14e) : const Color(0xff16A34A);
  static Color get warn       => _isDark ? const Color(0xffd4a017) : const Color(0xffCA8A04);
  static Color get danger     => _isDark ? const Color(0xffe74c3c) : const Color(0xffDC2626);
  static Color get orange     => _isDark ? const Color(0xffe67e22) : const Color(0xffEA580C);
  static Color get notice     => _isDark ? const Color(0xff2d1b00) : const Color(0xffFEF3C7);
  static Color get noticeBorder => _isDark ? const Color(0xff5a3e00) : const Color(0xffF59E0B);
  static Color get noticeText => _isDark ? const Color(0xffe3b341) : const Color(0xff92400E);
  static Color get error      => _isDark ? const Color(0xff3d1117) : const Color(0xffFEE2E2);
  static Color get errorBorder=> _isDark ? const Color(0xff6e2229) : const Color(0xffEF4444);
  static Color get errorText  => _isDark ? const Color(0xffff7b72) : const Color(0xffDC2626);
  static Color get shadow     => _isDark ? const Color(0x33000000) : const Color(0x1A000000);
  static Color get accent     => const Color(0xff4493f5);
  static Color get accentLight=> const Color(0xff66a8ff);
  static Color get cardBg     => _isDark ? const Color(0xff111620) : const Color(0xffFFFFFF);
  static Color get badgeRrc   => _isDark ? const Color(0xffc17702) : const Color(0xffB45309);
  static Color get badgeMode  => const Color(0xff4493f5);
}

Map<String, String> mapAt(Map<String, dynamic>? value, String key) {
  final item = value?[key];
  if (item is Map<String, String>) {
    return item;
  }
  if (item is Map) {
    return item.map((key, value) => MapEntry(key.toString(), value.toString()));
  }
  return <String, String>{};
}

Map<String, List<Map<String, String>>> fiberhomeNeighbors(
  Map<String, dynamic> snapshot,
) {
  final baseInfo = snapshot['baseInfo'];
  if (baseInfo is Map) {
    final base = baseInfo
        .map((key, value) => MapEntry(key.toString(), value.toString()));
    final bands = splitCsv(base['BAND_NBR']);
    final arfcns = splitCsv(base['EARFCN_NBR']);
    final pcis = splitCsv(base['PCI_NBR']);
    final rsrps = splitCsv(base['RSRP_NBR']);
    final rsrqs = splitCsv(base['RSRQ_NBR']);
    final sinrs = splitCsv(base['SINR_NBR']);
    final count = [
      bands.length,
      arfcns.length,
      pcis.length,
      rsrps.length,
      rsrqs.length,
      sinrs.length,
    ].reduce((value, element) => value > element ? value : element);
    if (count > 0) {
      return <String, List<Map<String, String>>>{
        'nr': [
          for (var index = 0; index < count; index += 1)
            <String, String>{
              'band': valueAt(bands, index),
              'arfcn': valueAt(arfcns, index),
              'pci': valueAt(pcis, index),
              'rsrp': valueAt(rsrps, index),
              'rsrq': valueAt(rsrqs, index),
              'sinr': valueAt(sinrs, index),
            },
        ],
      };
    }
  }
  final cellList = snapshot['cellList'];
  if (cellList is! Map) {
    return <String, List<Map<String, String>>>{'nr': []};
  }
  final records = cellList['lock_cell'];
  if (records is! List) {
    return <String, List<Map<String, String>>>{'nr': []};
  }
  return <String, List<Map<String, String>>>{
    'nr': records.whereType<Map>().map((item) {
      return <String, String>{
        'band': item['act'] == '2' ? 'NR' : 'LTE',
        'act': item['act']?.toString() ?? '--',
        'arfcn': item['arfcn']?.toString() ?? '--',
        'pci': item['pci']?.toString() ?? '--',
        'rsrp': '--',
        'rsrq': '--',
      };
    }).toList(),
  };
}

List<String> splitCsv(String? value) {
  if (value == null || value.trim().isEmpty || value.trim() == '--') {
    return <String>[];
  }
  return value
      .split(',')
      .map((item) => item.trim())
      .where((item) => item.isNotEmpty)
      .toList();
}

String valueAt(List<String> values, int index) {
  return index < values.length ? values[index] : '--';
}

String firstCsvValue(String value) {
  final values = splitCsv(value);
  return values.isEmpty ? value : values.first;
}

String firstValue(
  Map<String, String> data,
  List<String> keys, {
  String fallback = '--',
}) {
  for (final key in keys) {
    final value = data[key];
    if (value != null && value.trim().isNotEmpty) {
      return value.trim();
    }
  }
  return fallback;
}

String metricLabel(DisplayMode mode, String simple, String raw) {
  return mode == DisplayMode.professional ? raw : simple;
}

String timeText(DateTime? value) {
  if (value == null) {
    return '--';
  }
  return '${twoDigits(value.hour)}:${twoDigits(value.minute)}:${twoDigits(value.second)}';
}

String twoDigits(int value) => value.toString().padLeft(2, '0');

String operatorLabel(Map<String, String> plmn) {
  final full = plmn['FullName'] ?? plmn['fullname'] ?? '';
  final numeric = plmn['Numeric'] ?? plmn['numeric'] ?? plmn['plmn'] ?? '';
  if (full.isNotEmpty && numeric.isNotEmpty) {
    return '$full $numeric';
  }
  if (full.isNotEmpty) {
    return full;
  }
  if (numeric.isNotEmpty) {
    return numeric;
  }
  return '--';
}

String plmnLabel(String plmn) {
  return switch (plmn) {
    '46000' || '46002' || '46007' || '46008' => '中国移动 $plmn',
    '46001' || '46006' || '46009' => '中国联通 $plmn',
    '46003' || '46005' || '46011' => '中国电信 $plmn',
    '46015' => '中国广电 $plmn',
    '--' || '' => '--',
    _ => plmn,
  };
}

String cleanBand(String value) {
  if (value == '--') {
    return value;
  }
  final match = RegExp(r'\((N?\d+)\)').firstMatch(value);
  if (match != null) {
    return match.group(1)!;
  }
  return value.replaceAll('MHz@', 'M@');
}

String dlUlText(Map<String, String> signal) {
  final dl = firstValue(signal, ['nrdlfreq', 'ltedlfreq']);
  final ul = firstValue(signal, ['nrulfreq', 'lteulfreq']);
  if (dl == '--' && ul == '--') {
    return '--';
  }
  return '${formatKhz(dl)} / ${formatKhz(ul)}';
}

String formatKhz(String value) {
  final number = numeric(value);
  if (number == null) {
    return value;
  }
  if (value.toLowerCase().contains('khz')) {
    return '${(number / 1000).toStringAsFixed(2)} MHz';
  }
  return value;
}

List<KvItem> parsePower(String value) {
  if (value == '--') {
    return const [
      KvItem('PUSCH', '--'),
      KvItem('PUCCH', '--'),
      KvItem('SRS', '--'),
      KvItem('PRACH', '--'),
    ];
  }
  final labels = <String, String>{
    'PPusch': 'PUSCH',
    'PPucch': 'PUCCH',
    'PSrs': 'SRS',
    'PPrach': 'PRACH',
  };
  final items = <KvItem>[];
  for (final entry in labels.entries) {
    final match = RegExp('${entry.key}:([^\\s]+)').firstMatch(value);
    items.add(KvItem(entry.value, match?.group(1) ?? '--'));
  }
  return items;
}

String parseMcs(String value) {
  final match = RegExp(r':(\d+)@').firstMatch(value);
  return match?.group(1) ?? '--';
}

String parseModulation(String value) {
  final match = RegExp(r'@([A-Za-z0-9]+)').firstMatch(value);
  return match?.group(1) ?? '--';
}

String fiberhomeModulation(
  Map<String, String> data, {
  required List<String> rawKeys,
  required String mcsKey,
  required DisplayMode displayMode,
}) {
  final raw = firstValue(data, rawKeys, fallback: '');
  if (raw.isNotEmpty) {
    return raw;
  }
  if (displayMode == DisplayMode.professional) {
    return '--';
  }
  return modulationEstimateFromMcs(data[mcsKey]);
}

String modulationEstimateFromMcs(String? value) {
  final mcs = int.tryParse(value ?? '');
  if (mcs == null) {
    return '--';
  }
  if (mcs <= 9) {
    return 'QPSK(估)';
  }
  if (mcs <= 16) {
    return '16QAM(估)';
  }
  if (mcs <= 28) {
    return '64QAM(估)';
  }
  return '256QAM(估)';
}

String formatBytes(String? value) {
  final bytes = int.tryParse(value ?? '');
  if (bytes == null) {
    return '--';
  }
  if (bytes >= 1073741824) {
    return '${(bytes / 1073741824).toStringAsFixed(2)} GB';
  }
  if (bytes >= 1048576) {
    return '${(bytes / 1048576).toStringAsFixed(2)} MB';
  }
  if (bytes >= 1024) {
    return '${(bytes / 1024).toStringAsFixed(2)} KB';
  }
  return '$bytes B';
}

String rateText(String? value) {
  final bytes = int.tryParse(value ?? '');
  if (bytes == null) {
    return '--';
  }
  return '${(bytes * 8 / 1000000).toStringAsFixed(2)} Mbps';
}

String formatTemperature(String? value) {
  final number = numeric(value ?? '');
  if (number == null) {
    return '--';
  }
  final celsius = number.abs() > 1000 ? number / 1000 : number;
  return '${celsius.toStringAsFixed(1)} °C';
}

String dbmText(String? value) {
  if (value == null || value.trim().isEmpty) {
    return '--';
  }
  return value.toLowerCase().contains('dbm') ? value : '${value}dBm';
}

String kbpsText(String? value) {
  final number = int.tryParse(value ?? '');
  if (number == null) {
    return '--';
  }
  if (number >= 1000000) {
    return '${(number / 1000000).toStringAsFixed(2)} Gbps';
  }
  if (number >= 1000) {
    return '${(number / 1000).toStringAsFixed(1)} Mbps';
  }
  return '$number Kbps';
}

String ambrMbpsText(String? value) {
  final number = int.tryParse(value ?? '');
  if (number == null) {
    return '--';
  }
  final mbps = number / 1000;
  final text = mbps == mbps.roundToDouble()
      ? mbps.toStringAsFixed(0)
      : mbps.toStringAsFixed(1);
  return '$text Mbps';
}

String maskSession(String? value) {
  if (value == null || value.isEmpty) {
    return '--';
  }
  if (value.length <= 8) {
    return value;
  }
  return '${value.substring(0, 4)}...${value.substring(value.length - 4)}';
}

double? numeric(String value) {
  return double.tryParse(value.replaceAll(RegExp(r'[^0-9.\-]'), ''));
}

double normalize(double? value, double min, double max) {
  if (value == null) {
    return 0;
  }
  return ((value - min) / (max - min)).clamp(0.0, 1.0);
}
