import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_cpemanager/main.dart';

void main() {
  test('fiberhome base_info rows are mapped into neighbor cells', () {
    final neighbors = fiberhomeNeighbors(<String, dynamic>{
      'baseInfo': <String, String>{
        'BAND_NBR': 'N78,N79',
        'EARFCN_NBR': '627264,723360',
        'PCI_NBR': '554,891',
        'RSRP_NBR': '-54,-67',
        'RSRQ_NBR': '-9,-11',
        'SINR_NBR': '32,31',
      },
    });

    expect(neighbors['nr'], hasLength(2));
    expect(neighbors['nr']!.first['band'], 'N78');
    expect(neighbors['nr']!.last['pci'], '891');
  });

  test('fiberhome dashboard model renders base_info values', () {
    final model = DashboardModel.from(
      vendor: CpeVendor.fiberhome,
      snapshot: <String, dynamic>{
        'baseInfo': <String, String>{
          'modelName': 'LG6151M',
          'WorkMode': 'SA',
          'PLMN': '46000',
          'NR_Band': '79',
          'PCI_NBR': '891',
          'EARFCN_NBR': '723360',
          'DlBandWidth': '100MHz',
          'TAC': '6685291',
          'NCGI': '1657430030',
          'SSB_RSRP': '-67',
          'RSRQ': '-11',
          'SSB_SINR': '31',
          'RSSI': '-57',
          'CQI': '15',
          'Temperature': '36448',
          'RxSpeed': '133911',
          'TxSpeed': '66472',
        },
        'networkInfo': <String, String>{'networkMode': '2', 'ENDC': '1'},
        'lockBand': <String, String>{},
        'cellList': <String, Object>{'enable': '0', 'lock_cell': <Object>[]},
      },
      neighbors: <String, List<Map<String, String>>>{
        'nr': <Map<String, String>>[]
      },
    );

    expect(model.headerTitle, '烽火 NR 主小区');
    expect(model.modeBadge, 'SA');
    expect(model.operatorBadge, '中国移动 46000');
    expect(model.primaryItems.first.value, 'N79');
    expect(model.identityItems.any((item) => item.value == '36.4 °C'), isTrue);
  });

  testWidgets('renders dashboard workspaces and navigation', (tester) async {
    await tester.pumpWidget(const CpeManagerApp());

    expect(find.text('NR 主小区'), findsWidgets);
    expect(find.text('PCC'), findsOneWidget);
    expect(find.text('载波聚合'), findsOneWidget);
    expect(find.text('锁频'), findsOneWidget);
    expect(find.text('速率'), findsOneWidget);
    expect(find.text('烽火'), findsOneWidget);

    await tester.tap(find.text('登录'));
    await tester.pumpAndSettle();

    expect(find.text('设备登录'), findsOneWidget);
    expect(find.text('读取状态'), findsOneWidget);
  });
}
