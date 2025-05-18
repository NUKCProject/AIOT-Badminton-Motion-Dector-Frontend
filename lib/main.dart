import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'dart:convert';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE IMU Recorder',
      theme: ThemeData(
        primarySwatch: Colors.blue,
        primaryColor: const Color(0xFF00BCD4),
      ),
      home: const BleScannerScreen(),
    );
  }
}

class BleScannerScreen extends StatefulWidget {
  const BleScannerScreen({super.key});

  @override
  State<BleScannerScreen> createState() => _BleScannerScreenState();
}

class _BleScannerScreenState extends State<BleScannerScreen> {
  List<ScanResult> scanResults = [];
  BluetoothDevice? connectedDevice;
  BluetoothCharacteristic? imuCharacteristic;
  String filterOption = "No Filter";
  bool isScanning = false;

  final String imuServiceUUID = "14A168D7-04D1-6C4F-7E53-F2E800B11900";
  final String imuCharacteristicUUID = "14A168D7-04D1-6C4F-7E53-F2E801B11900";

  final List<String> recordingModes = ['Reference', 'Training'];
  final List<String> actions = [
    'smash',
    'drive',
    'clear',
    'drop',
    'toss',
    'other',
  ];

  String selectedMode = 'Reference';
  String selectedAction = 'smash';
  bool isRecording = false;

  List<Map<String, dynamic>> recordedData = [];

  List<FlSpot> axData = [];
  List<FlSpot> ayData = [];
  List<FlSpot> azData = [];
  List<FlSpot> gxData = [];
  List<FlSpot> gyData = [];
  List<FlSpot> gzData = [];
  List<FlSpot> micLevelData = [];
  List<FlSpot> micPeakData = [];

  int counter = 0;
  final int maxPoints = 50;
  int deviceId = 0;

  final int batchSize = 1000;

  // Current page index for the bottom navigation
  int _currentIndex = 0;

  @override
  void initState() {
    super.initState();
    // 啟動應用時立即開始掃描
    WidgetsBinding.instance.addPostFrameCallback((_) {
      startScan();
    });

    // 監聽掃描狀態變化
    FlutterBluePlus.isScanning.listen((scanning) {
      setState(() {
        isScanning = scanning;
      });
    });
  }

  void startScan() {
    if (!isScanning) {
      setState(() {
        scanResults = []; // 清空之前的結果
      });
      FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
      FlutterBluePlus.scanResults.listen((results) {
        setState(() {
          scanResults = results;
        });
      });
    }
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    try {
      await device.connect();
      setState(() {
        connectedDevice = device;
      });
      monitorConnection(device);
      discoverServices(device);
    } catch (e) {
      showSnackbar('連接失敗: $e', false);
    }
  }

  void monitorConnection(BluetoothDevice device) {
    device.connectionState.listen((BluetoothConnectionState state) {
      if (state == BluetoothConnectionState.disconnected) {
        showSnackbar('藍牙已斷線，請重新連接', false);
        setState(() {
          connectedDevice = null;
          imuCharacteristic = null;
          isRecording = false;
          recordedData.clear();
        });
        startScan(); // 斷線後自動重新掃描
      }
    });
  }

  Future<void> discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid.toString().toUpperCase() == imuServiceUUID) {
        for (BluetoothCharacteristic characteristic
            in service.characteristics) {
          if (characteristic.uuid.toString().toUpperCase() ==
              imuCharacteristicUUID) {
            setState(() {
              imuCharacteristic = characteristic;
            });
            await subscribeToIMUData();
            break;
          }
        }
      }
    }
  }

  Future<void> subscribeToIMUData() async {
    if (imuCharacteristic != null) {
      await imuCharacteristic!.setNotifyValue(true);
      imuCharacteristic!.onValueReceived.listen((value) {
        final byteData = ByteData.sublistView(Uint8List.fromList(value));

        int timestamp = byteData.getInt64(0, Endian.little);
        int eqpId = byteData.getUint16(8, Endian.little); // 2 bytes
        double ax = byteData.getFloat32(10, Endian.little);
        double ay = byteData.getFloat32(14, Endian.little);
        double az = byteData.getFloat32(18, Endian.little);
        double gx = byteData.getFloat32(22, Endian.little);
        double gy = byteData.getFloat32(26, Endian.little);
        double gz = byteData.getFloat32(30, Endian.little);
        int micLevel = byteData.getUint16(34, Endian.little);
        int micPeak = byteData.getUint16(36, Endian.little);

        setState(() {
          deviceId = eqpId;
          counter++;
          addData(axData, counter.toDouble(), ax);
          addData(ayData, counter.toDouble(), ay);
          addData(azData, counter.toDouble(), az);
          addData(gxData, counter.toDouble(), gx);
          addData(gyData, counter.toDouble(), gy);
          addData(gzData, counter.toDouble(), gz);
          addData(micLevelData, counter.toDouble(), micLevel.toDouble());
          addData(micPeakData, counter.toDouble(), micPeak.toDouble());
        });

        if (isRecording) {
          recordedData.add({
            "ts": timestamp,
            "ax": ax,
            "ay": ay,
            "az": az,
            "gx": gx,
            "gy": gy,
            "gz": gz,
            "mic_level": micLevel,
            "mic_peak": micPeak,
          });

          if (batchSize > 0 && recordedData.length >= batchSize) {
            sendRecordedData();
          }
        }
      });
    }
  }

  void addData(List<FlSpot> dataList, double x, double y) {
    dataList.add(FlSpot(x, y));
    if (dataList.length > maxPoints) {
      dataList.removeAt(0);
    }
  }

  Future<void> sendRecordedData() async {
    if (recordedData.isEmpty) return;

    List<Map<String, dynamic>> dataToSend = List.from(recordedData); // 先copy
    recordedData.clear(); // 立刻清空！
    
    String url =
        selectedMode == 'Reference'
            ? 'https://badminton-457613.de.r.appspot.com/record-reference-raw-waveforms'
            : 'https://badminton-457613.de.r.appspot.com/record-training-raw-waveforms';

    final body = jsonEncode({
      "device_id": deviceId.toRadixString(16).toUpperCase(),
      "action": selectedAction,
      "waveform": dataToSend, // 傳copy出來的data
    });

    //showResponseDialog(body.length, body);

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      // 顯示 response 資訊在 UI 上
      showResponseDialog(response.statusCode, response.body);

      if (response.statusCode == 200) {
        showSnackbar('成功上傳${dataToSend.length}筆資料', true);
      } else {
        showSnackbar('上傳失敗: ${response.statusCode}', false);
      }
    } catch (e) {
      showSnackbar('上傳失敗_catch: $e', false);
      // 顯示詳細錯誤信息
      showResponseDialog(0, '連接錯誤: $e');
    }
  }

  // 改進的 showSnackbar 方法
  void showSnackbar(String message, bool success) {
    // 先移除當前顯示的 SnackBar
    ScaffoldMessenger.of(context).removeCurrentSnackBar();

    // 顯示新的 SnackBar
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green : Colors.red,
        duration: const Duration(seconds: 3), // 設置顯示時間
      ),
    );
  }

  // 新增的 showResponseDialog 方法，用於顯示 API 響應詳情
  void showResponseDialog(int statusCode, String body) {
    showDialog(
      context: context,
      builder:
          (context) => AlertDialog(
            title: Text(
              'API Response (Status: $statusCode)',
              style: TextStyle(
                color: statusCode == 200 ? Colors.green : Colors.red,
              ),
            ),
            content: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'Response Body:',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey.shade100,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: SelectableText(body), // 使用 SelectableText 以便用戶可以複製內容
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('確定'),
              ),
            ],
          ),
    );
  }

  void toggleRecording() async {
    if (isRecording) {
      await sendRecordedData();
    }
    setState(() {
      isRecording = !isRecording;
    });
  }

  // 新增過濾器選項變更
  void changeFilter(String filter) {
    setState(() {
      filterOption = filter;
      // 這裡可以添加實際過濾裝置的邏輯
    });
  }

  void _changePage(int index) {
    setState(() {
      _currentIndex = index;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title:
            connectedDevice == null
                ? const Text(
                  'Scanner',
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.bold,
                    color: Colors.white,
                  ),
                )
                : Text(
                  'BLE IMU Recorder (ID: ${deviceId.toRadixString(16).toUpperCase()})',
                  style: const TextStyle(fontSize: 20, color: Colors.white),
                ),
        backgroundColor: const Color(0xFF00BCD4),
        elevation: 0,
        actions: [
          if (connectedDevice == null)
            IconButton(
              icon: Icon(
                isScanning ? Icons.stop : Icons.play_arrow,
                color: Colors.white,
              ),
              onPressed:
                  isScanning ? () => FlutterBluePlus.stopScan() : startScan,
            ),
        ],
      ),
      body:
          connectedDevice == null
              ? _buildScannerView()
              : IndexedStack(
                index: _currentIndex,
                children: [_buildRealTimeChartsView(), _buildDeviceInfoView()],
              ),
      bottomNavigationBar:
          connectedDevice != null
              ? BottomNavigationBar(
                currentIndex: _currentIndex,
                onTap: _changePage,
                selectedItemColor: const Color(0xFF00BCD4),
                items: const [
                  BottomNavigationBarItem(
                    icon: Icon(Icons.show_chart),
                    label: 'Real-time Data',
                  ),
                  BottomNavigationBarItem(
                    icon: Icon(Icons.info_outline),
                    label: 'Device Info',
                  ),
                ],
              )
              : null,
    );
  }

  Widget _buildScannerView() {
    return Column(
      children: [
        // 掃描狀態指示
        if (isScanning)
          Container(
            padding: const EdgeInsets.symmetric(vertical: 8),
            color: Colors.blue.shade50,
            child: const Center(
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                  SizedBox(width: 8),
                  Text('正在掃描裝置...'),
                ],
              ),
            ),
          ),

        // 過濾器選項區域
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: const BoxDecoration(
            color: Color(0xFFE0E0E0),
            border: Border(bottom: BorderSide(color: Colors.grey, width: 0.5)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(filterOption, style: const TextStyle(fontSize: 16)),
              IconButton(
                icon: const Icon(Icons.arrow_upward),
                onPressed: () {
                  // 彈出過濾器選項對話框
                  showDialog(
                    context: context,
                    builder:
                        (context) => SimpleDialog(
                          title: const Text('選擇過濾器'),
                          children: [
                            SimpleDialogOption(
                              onPressed: () {
                                changeFilter('No Filter');
                                Navigator.pop(context);
                              },
                              child: const Text('No Filter'),
                            ),
                            SimpleDialogOption(
                              onPressed: () {
                                changeFilter('只顯示羽毛球裝置');
                                Navigator.pop(context);
                              },
                              child: const Text('只顯示羽毛球裝置'),
                            ),
                          ],
                        ),
                  );
                },
              ),
            ],
          ),
        ),

        // 裝置列表
        Expanded(
          child:
              scanResults.isEmpty
                  ? const Center(
                    child: Text(
                      '尚未找到裝置',
                      style: TextStyle(fontSize: 16, color: Colors.grey),
                    ),
                  )
                  : ListView.builder(
                    itemCount: scanResults.length,
                    itemBuilder: (context, index) {
                      final result = scanResults[index];
                      final deviceName =
                          result.device.name.isNotEmpty
                              ? result.device.name
                              : '(No Name)';
                      return Container(
                        decoration: const BoxDecoration(
                          border: Border(
                            bottom: BorderSide(color: Colors.grey, width: 0.2),
                          ),
                        ),
                        child: ListTile(
                          title: Text(
                            deviceName,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                          subtitle: Text(
                            result.device.id.id,
                            style: const TextStyle(
                              fontSize: 14,
                              color: Colors.grey,
                            ),
                          ),
                          trailing: ElevatedButton(
                            style: ElevatedButton.styleFrom(
                              backgroundColor: const Color(0xFF2F4F4F),
                              foregroundColor: Colors.white,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            onPressed: () {
                              FlutterBluePlus.stopScan();
                              connectToDevice(result.device);
                            },
                            child: const Text('Connect'),
                          ),
                        ),
                      );
                    },
                  ),
        ),
      ],
    );
  }

  // 實時圖表視圖
  Widget _buildRealTimeChartsView() {
    return SingleChildScrollView(
      child: Column(
        children: [
          const SizedBox(height: 10),
          if (!isRecording)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: DropdownButton<String>(
                value: selectedMode,
                isExpanded: true,
                underline: Container(),
                items:
                    recordingModes
                        .map(
                          (mode) =>
                              DropdownMenuItem(value: mode, child: Text(mode)),
                        )
                        .toList(),
                onChanged: (value) {
                  setState(() {
                    selectedMode = value!;
                  });
                },
              ),
            ),
          if (!isRecording)
            Container(
              margin: const EdgeInsets.symmetric(vertical: 8),
              padding: const EdgeInsets.symmetric(horizontal: 16),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.grey.shade300),
              ),
              child: DropdownButton<String>(
                value: selectedAction,
                isExpanded: true,
                underline: Container(),
                items:
                    actions
                        .map(
                          (action) => DropdownMenuItem(
                            value: action,
                            child: Text(action),
                          ),
                        )
                        .toList(),
                onChanged: (value) {
                  setState(() {
                    selectedAction = value!;
                  });
                },
              ),
            ),
          Container(
            margin: const EdgeInsets.symmetric(vertical: 16),
            child: ElevatedButton(
              style: ElevatedButton.styleFrom(
                backgroundColor:
                    isRecording ? Colors.red : const Color(0xFF00BCD4),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: toggleRecording,
              child: Text(
                isRecording ? '停止錄製' : '開始錄製',
                style: const TextStyle(fontSize: 16),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                const Text(
                  'Acceleration (m/s²)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                SizedBox(
                  height: 250,
                  child: LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        getDrawingHorizontalLine: (value) {
                          return FlLine(
                            color: Colors.grey.shade300,
                            strokeWidth: 1,
                          );
                        },
                        getDrawingVerticalLine: (value) {
                          return FlLine(
                            color: Colors.grey.shade300,
                            strokeWidth: 1,
                          );
                        },
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        rightTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        topTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      minY: -50,
                      maxY: 50,
                      lineBarsData: [
                        LineChartBarData(
                          spots: axData,
                          isCurved: true,
                          dotData: FlDotData(show: false),
                          color: Colors.red,
                        ),
                        LineChartBarData(
                          spots: ayData,
                          isCurved: true,
                          dotData: FlDotData(show: false),
                          color: Colors.green,
                        ),
                        LineChartBarData(
                          spots: azData,
                          isCurved: true,
                          dotData: FlDotData(show: false),
                          color: Colors.blue,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: Colors.grey.shade100,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Column(
              children: [
                const Text(
                  'Gyroscope (deg/s)',
                  style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                ),
                SizedBox(
                  height: 250,
                  child: LineChart(
                    LineChartData(
                      gridData: FlGridData(
                        show: true,
                        drawVerticalLine: true,
                        getDrawingHorizontalLine: (value) {
                          return FlLine(
                            color: Colors.grey.shade300,
                            strokeWidth: 1,
                          );
                        },
                        getDrawingVerticalLine: (value) {
                          return FlLine(
                            color: Colors.grey.shade300,
                            strokeWidth: 1,
                          );
                        },
                      ),
                      titlesData: FlTitlesData(
                        show: true,
                        rightTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                        topTitles: AxisTitles(
                          sideTitles: SideTitles(showTitles: false),
                        ),
                      ),
                      borderData: FlBorderData(
                        show: true,
                        border: Border.all(color: Colors.grey.shade300),
                      ),
                      minY: -2000,
                      maxY: 2000,
                      lineBarsData: [
                        LineChartBarData(
                          spots: gxData,
                          isCurved: true,
                          dotData: FlDotData(show: false),
                          color: Colors.orange,
                        ),
                        LineChartBarData(
                          spots: gyData,
                          isCurved: true,
                          dotData: FlDotData(show: false),
                          color: Colors.purple,
                        ),
                        LineChartBarData(
                          spots: gzData,
                          isCurved: true,
                          dotData: FlDotData(show: false),
                          color: Colors.cyan,
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // 設備信息視圖
  Widget _buildDeviceInfoView() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 設備狀態卡片
          Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF00BCD4).withOpacity(0.2),
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: const Icon(
                          Icons.bluetooth_connected,
                          color: Color(0xFF00BCD4),
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 12),
                      const Text(
                        'Badminton Tracker',
                        style: TextStyle(
                          fontSize: 20,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      const Text(
                        'Status:',
                        style: TextStyle(fontSize: 16, color: Colors.grey),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.green,
                          borderRadius: BorderRadius.circular(12),
                        ),
                        child: const Text(
                          'Connected',
                          style: TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 設備信息卡片
          Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Device Information',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  _buildInfoRow(
                    'Device ID',
                    deviceId.toRadixString(16).toUpperCase(),
                  ),
                  _buildInfoRow(
                    'Device Name',
                    connectedDevice?.name ?? 'Unknown',
                  ),
                  _buildInfoRow(
                    'MAC Address',
                    connectedDevice?.id.id ?? 'Unknown',
                  ),
                  _buildInfoRow('Service UUID', imuServiceUUID),
                  _buildInfoRow('Characteristic UUID', imuCharacteristicUUID),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 電池與連接狀態卡片
          Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Sensor Status',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  _buildBatteryIndicator(85), // 假設電池電量為85%
                  const SizedBox(height: 16),
                  _buildSignalStrengthIndicator(4), // 假設信號強度為4格(滿格)
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 數據統計卡片
          Card(
            elevation: 4,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Data Statistics',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 16),
                  _buildInfoRow('Samples Collected', '$counter'),
                  _buildInfoRow('Recording Mode', selectedMode),
                  _buildInfoRow('Current Action', selectedAction),
                  _buildInfoRow(
                    'Recording Status',
                    isRecording ? 'Active' : 'Paused',
                  ),
                  if (isRecording)
                    _buildInfoRow(
                      'Samples Pending Upload',
                      '${recordedData.length}/$batchSize',
                    ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),

          // 斷開連接按鈕
          Center(
            child: ElevatedButton.icon(
              icon: const Icon(Icons.bluetooth_disabled),
              label: const Text('Disconnect Device'),
              style: ElevatedButton.styleFrom(
                backgroundColor: Colors.red,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              onPressed: () async {
                if (isRecording) {
                  await sendRecordedData();
                }
                if (connectedDevice != null) {
                  await connectedDevice!.disconnect();
                  setState(() {
                    connectedDevice = null;
                    imuCharacteristic = null;
                  });
                  startScan();
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildInfoRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label, style: const TextStyle(fontSize: 16, color: Colors.grey)),
          Text(
            value,
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
        ],
      ),
    );
  }

  Widget _buildBatteryIndicator(int percentage) {
    Color batteryColor;
    IconData batteryIcon;

    if (percentage >= 80) {
      batteryColor = Colors.green;
      batteryIcon = Icons.battery_full;
    } else if (percentage >= 50) {
      batteryColor = Colors.amber;
      batteryIcon = Icons.battery_5_bar;
    } else if (percentage >= 20) {
      batteryColor = Colors.orange;
      batteryIcon = Icons.battery_3_bar;
    } else {
      batteryColor = Colors.red;
      batteryIcon = Icons.battery_1_bar;
    }

    return Row(
      children: [
        Icon(batteryIcon, color: batteryColor, size: 28),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Battery', style: TextStyle(fontSize: 16)),
                  Text(
                    '$percentage%',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              LinearProgressIndicator(
                value: percentage / 100,
                backgroundColor: Colors.grey.shade200,
                valueColor: AlwaysStoppedAnimation<Color>(batteryColor),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSignalStrengthIndicator(int bars) {
    return Row(
      children: [
        Icon(
          bars > 3
              ? Icons.network_wifi
              : bars > 2
              ? Icons.network_wifi_3_bar
              : bars > 1
              ? Icons.network_wifi_2_bar
              : bars > 0
              ? Icons.network_wifi_1_bar
              : Icons.wifi_off,
          color: bars > 1 ? Colors.green : Colors.red,
          size: 28,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text('Signal Strength', style: TextStyle(fontSize: 16)),
                  Text(
                    '${bars * 25}%',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 4),
              Row(
                children: List.generate(
                  4,
                  (index) => Expanded(
                    child: Container(
                      height: 8,
                      margin: const EdgeInsets.symmetric(horizontal: 1),
                      decoration: BoxDecoration(
                        color:
                            index < bars ? Colors.green : Colors.grey.shade300,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
