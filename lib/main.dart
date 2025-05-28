import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async'; // 添加這個 import
import 'dart:developer' as developer;

void main() {
  // 設置日誌過濾，隱藏 Flutter Blue Plus 的 debug 訊息
  FlutterBluePlus.setLogLevel(LogLevel.warning);
  
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE IMU Recorder',
      theme: ThemeData(primarySwatch: Colors.blue),
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
  BluetoothCharacteristic? timeSyncCharacteristic; // 新增：時間同步特徵

  final String imuServiceUUID = "14A168D7-04D1-6C4F-7E53-F2E800B11900";
  final String imuCharacteristicUUID = "14A168D7-04D1-6C4F-7E53-F2E801B11900";
  final String timeSyncCharacteristicUUID = "14A168D7-04D1-6C4F-7E53-F2E802B11900"; // 新增：時間同步特徵UUID

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
  int maxPoints = 100; // 改為變數，會根據資料頻率動態調整
  final double displayTimeWindow = 1.5; // 顯示時間窗口：1.5秒
  int deviceId = 0;

  final int batchSize = 1000;

  // Az 峰值增強參數
  double azThreshold = 0.5;  // az 峰值閾值
  double azEnhanceFactor = 1.5;  // az 峰值增強倍數

  // 添加數據統計相關變數
  int dataCountThisSecond = 0;
  DateTime lastSecondTime = DateTime.now();
  Timer? statisticsTimer;
  double averageDataRate = 0; // 平均資料頻率

  // 新增：時間同步相關變數
  bool isTimeSyncing = false;
  String timeSyncStatus = '未同步';
  DateTime? lastSyncTime;

  @override
  void initState() {
    super.initState();
    startScan();
    // 啟動統計 timer
    startStatisticsTimer();
  }

  @override
  void dispose() {
    // 清理 timer
    statisticsTimer?.cancel();
    super.dispose();
  }

  // 啟動統計計時器
  void startStatisticsTimer() {
    statisticsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      // 每秒輸出統計資訊到 console
      print('Data rate: $dataCountThisSecond packets/second');
      
      // 更新平均資料頻率（使用簡單的移動平均）
      if (averageDataRate == 0) {
        averageDataRate = dataCountThisSecond.toDouble();
      } else {
        averageDataRate = (averageDataRate * 0.8) + (dataCountThisSecond * 0.2);
      }
      
      // 根據資料頻率動態調整顯示點數 (1.5秒的資料)
      maxPoints = (averageDataRate * displayTimeWindow).round();
      if (maxPoints < 10) maxPoints = 10; // 最少顯示10個點
      if (maxPoints > 500) maxPoints = 500; // 最多顯示500個點
      
      print('Display window: ${displayTimeWindow}s, Max points: $maxPoints, Avg rate: ${averageDataRate.toStringAsFixed(1)} Hz');
      
      // 重置計數器
      dataCountThisSecond = 0;
      lastSecondTime = DateTime.now();
    });
  }

  void startScan() {
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 5));
    FlutterBluePlus.scanResults.listen((results) {
      setState(() {
        scanResults = results;
      });
    });
  }

  Future<void> connectToDevice(BluetoothDevice device) async {
    await device.connect();
    setState(() {
      connectedDevice = device;
    });
    monitorConnection(device);
    discoverServices(device);
  }

  void monitorConnection(BluetoothDevice device) {
    device.connectionState.listen((BluetoothConnectionState state) {
      if (state == BluetoothConnectionState.disconnected) {
        showSnackbar('藍牙已斷線，請重新連接', false);
        setState(() {
          connectedDevice = null;
          imuCharacteristic = null;
          timeSyncCharacteristic = null; // 新增：重置時間同步特徵
          timeSyncStatus = '未同步'; // 新增：重置同步狀態
          lastSyncTime = null; // 新增：重置同步時間
          isRecording = false;
          recordedData.clear();
        });
        startScan();
      }
    });
  }

  Future<void> discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid.toString().toUpperCase() == imuServiceUUID) {
        for (BluetoothCharacteristic characteristic in service.characteristics) {
          String charUUID = characteristic.uuid.toString().toUpperCase();
          
          if (charUUID == imuCharacteristicUUID) {
            setState(() {
              imuCharacteristic = characteristic;
            });
            await subscribeToIMUData();
          } else if (charUUID == timeSyncCharacteristicUUID) {
            // 新增：發現時間同步特徵
            setState(() {
              timeSyncCharacteristic = characteristic;
            });
            print('發現時間同步特徵');
          }
        }
      }
    }
    
    // 新增：自動執行時間同步
    if (timeSyncCharacteristic != null) {
      await performTimeSync();
    }
  }

  // 新增：執行時間同步
  Future<void> performTimeSync() async {
    if (timeSyncCharacteristic == null || isTimeSyncing) {
      return;
    }

    setState(() {
      isTimeSyncing = true;
      timeSyncStatus = '同步中...';
    });

    try {
      // 獲取當前UTC時間戳記（毫秒）
      int utcTimestampMs = DateTime.now().toUtc().millisecondsSinceEpoch;
      
      // 將時間戳記轉換為8位元組小端序格式
      ByteData byteData = ByteData(8);
      byteData.setInt64(0, utcTimestampMs, Endian.little);
      
      // 轉換為Uint8List
      Uint8List timeData = byteData.buffer.asUint8List();
      
      print('發送時間同步請求: $utcTimestampMs ms (UTC)');
      print('時間數據: ${timeData.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}');
      
      // 發送時間同步請求到藍芽設備
      await timeSyncCharacteristic!.write(timeData, withoutResponse: false);
      
      setState(() {
        timeSyncStatus = '同步成功';
        lastSyncTime = DateTime.now();
      });
      
      showSnackbar('時間同步成功', true);
      print('時間同步完成');
      
    } catch (e) {
      setState(() {
        timeSyncStatus = '同步失敗';
      });
      
      showSnackbar('時間同步失敗: $e', false);
      print('時間同步失敗: $e');
      
      // 記錄錯誤詳情
      developer.log(
        '時間同步失敗',
        name: 'TimeSync',
        error: e,
        time: DateTime.now(),
      );
    } finally {
      setState(() {
        isTimeSyncing = false;
      });
    }
  }

  Future<void> subscribeToIMUData() async {
    if (imuCharacteristic != null) {
      await imuCharacteristic!.setNotifyValue(true);
      imuCharacteristic!.onValueReceived.listen((value) {
        // 增加數據計數
        dataCountThisSecond++;
        
        final byteData = ByteData.sublistView(Uint8List.fromList(value));

        int timestamp = byteData.getInt64(0, Endian.little);
        int eqpId = byteData.getUint16(8, Endian.little);
        double ax = byteData.getFloat32(10, Endian.little);
        double ay = byteData.getFloat32(14, Endian.little);
        double az = byteData.getFloat32(18, Endian.little);
        double gx = byteData.getFloat32(22, Endian.little);
        double gy = byteData.getFloat32(26, Endian.little);
        double gz = byteData.getFloat32(30, Endian.little);
        int micLevel = byteData.getUint16(34, Endian.little);
        int micPeak = byteData.getUint16(36, Endian.little);

        // 輸出時間戳資訊到控制台 (台灣時間格式)
        DateTime timestampDateTime = DateTime.fromMillisecondsSinceEpoch(timestamp, isUtc: true);
        DateTime currentTime = DateTime.now().toUtc();
        int timeDifference = currentTime.millisecondsSinceEpoch - timestamp;
        
        // 轉換為台灣時間 (UTC+8)
        DateTime deviceTimeTW = timestampDateTime.add(const Duration(hours: 8));
        DateTime currentTimeTW = DateTime.now(); // 本地時間已經是台灣時間
        
        // 格式化台灣時間顯示
        String formatTaiwanTime(DateTime dt) {
          return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
                 '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:'
                 '${dt.second.toString().padLeft(2, '0')}.${dt.millisecond.toString().padLeft(3, '0')}';
        }
        
        print('═══ IMU 數據時間戳資訊 ═══');
        print('原始時間戳: $timestamp ms');
        print('sensor時間 (台灣): ${formatTaiwanTime(deviceTimeTW)}');
        print('當前時間 (台灣): ${formatTaiwanTime(currentTimeTW)}');
        print('時間差異: ${timeDifference}ms (${(timeDifference/1000).toStringAsFixed(3)}s)');
        print('sensorID: ${eqpId.toRadixString(16).toUpperCase()}');
        print('數據包計數: $counter');
        print('──────────────────────────');

        // 處理 Az 數據 - 增強峰值顯著性
        double processedAz = az;
        if (az.abs() > azThreshold) {
          // 當 az 值超過閾值時，增強其顯著性
          processedAz = az.sign * (azThreshold + (az.abs() - azThreshold) * azEnhanceFactor);
        }

        setState(() {
          deviceId = eqpId;
          counter++;
          addData(axData, counter.toDouble(), ax);
          addData(ayData, counter.toDouble(), ay);
          addData(azData, counter.toDouble(), processedAz); // 使用處理後的 az 值
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
            "az": az, // 記錄原始值，不是放大後的值
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

    List<Map<String, dynamic>> dataToSend = List.from(recordedData);
    recordedData.clear();

    String url =
        selectedMode == 'Reference'
            ? 'https://badminton-461016.de.r.appspot.com/record-reference-raw-waveforms'
            : 'https://badminton-461016.de.r.appspot.com/record-training-raw-waveforms';

    final body = jsonEncode({
      "device_id": deviceId.toRadixString(16).toUpperCase(),
      "action": selectedAction,
      "waveform": dataToSend,
    });

    try {
      final response = await http.post(
        Uri.parse(url),
        headers: {'Content-Type': 'application/json'},
        body: body,
      );

      if (response.statusCode == 200) {
        showSnackbar('成功上傳${dataToSend.length}筆資料', true);
      } else {
        showSnackbar('上傳失敗: ${response.statusCode}', false);
      }
    } catch (e) {
      showSnackbar('上傳失敗: $e', false);
    }
  }

  void showSnackbar(String message, bool success) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: success ? Colors.green : Colors.red,
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

  // 改進的圖例建構函數，支援更多樣式
  Widget buildLegend(String label, Color color, {IconData? icon}) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        icon != null 
          ? Icon(icon, color: color, size: 12)
          : Container(
              width: 12, 
              height: 12, 
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
        const SizedBox(width: 6),
        Text(
          label, 
          style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w500),
        ),
      ],
    );
  }

  // 建構完整的圖例區域
  Widget buildLegendSection(List<Widget> legends) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12),
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: Colors.grey.shade50,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: Colors.grey.shade300),
      ),
      child: Wrap(
        alignment: WrapAlignment.center,
        spacing: 16,
        runSpacing: 8,
        children: legends,
      ),
    );
  }

  // 新增：格式化時間顯示
  String formatSyncTime(DateTime? time) {
    if (time == null) return '無';
    return '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'BLE IMU Recorder (ID: ${deviceId.toRadixString(16).toUpperCase()})',
        ),
        backgroundColor: Colors.blue.shade100,
      ),
      body:
          connectedDevice == null
              ? ListView.builder(
                itemCount: scanResults.length,
                itemBuilder: (context, index) {
                  final result = scanResults[index];
                  return ListTile(
                    title: Text(
                      result.device.name.isNotEmpty
                          ? result.device.name
                          : '(No Name)',
                    ),
                    subtitle: Text(result.device.id.id),
                    onTap: () {
                      FlutterBluePlus.stopScan();
                      connectToDevice(result.device);
                    },
                  );
                },
              )
              : SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(16.0),
                  child: Column(
                    children: [
                      // 控制區域
                      Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            children: [
                              // 新增：時間同步狀態區域
                              Container(
                                padding: const EdgeInsets.all(12),
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color: timeSyncStatus == '同步成功' 
                                      ? Colors.green.shade50 
                                      : timeSyncStatus == '同步失敗'
                                          ? Colors.red.shade50
                                          : Colors.orange.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: timeSyncStatus == '同步成功' 
                                        ? Colors.green.shade300 
                                        : timeSyncStatus == '同步失敗'
                                            ? Colors.red.shade300
                                            : Colors.orange.shade300,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      timeSyncStatus == '同步成功' 
                                          ? Icons.check_circle 
                                          : timeSyncStatus == '同步失敗'
                                              ? Icons.error
                                              : timeSyncStatus == '同步中...'
                                                  ? Icons.sync
                                                  : Icons.schedule,
                                      color: timeSyncStatus == '同步成功' 
                                          ? Colors.green.shade700 
                                          : timeSyncStatus == '同步失敗'
                                              ? Colors.red.shade700
                                              : Colors.orange.shade700,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '時間同步狀態: $timeSyncStatus',
                                            style: const TextStyle(fontWeight: FontWeight.bold),
                                          ),
                                          if (lastSyncTime != null)
                                            Text(
                                              '上次同步: ${formatSyncTime(lastSyncTime)}',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    if (timeSyncCharacteristic != null && !isTimeSyncing)
                                      ElevatedButton.icon(
                                        onPressed: performTimeSync,
                                        icon: const Icon(Icons.sync, size: 16),
                                        label: const Text('重新同步'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.blue,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                          textStyle: const TextStyle(fontSize: 12),
                                        ),
                                      ),
                                    if (isTimeSyncing)
                                      const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(strokeWidth: 2),
                                      ),
                                  ],
                                ),
                              ),
                              
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (!isRecording)
                                    Column(
                                      children: [
                                        const Text('錄製模式', style: TextStyle(fontWeight: FontWeight.bold)),
                                        DropdownButton<String>(
                                          value: selectedMode,
                                          items: recordingModes
                                              .map((mode) => DropdownMenuItem(
                                                    value: mode,
                                                    child: Text(mode),
                                                  ))
                                              .toList(),
                                          onChanged: (value) {
                                            setState(() {
                                              selectedMode = value!;
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                  if (!isRecording)
                                    Column(
                                      children: [
                                        const Text('動作類型', style: TextStyle(fontWeight: FontWeight.bold)),
                                        DropdownButton<String>(
                                          value: selectedAction,
                                          items: actions
                                              .map((action) => DropdownMenuItem(
                                                    value: action,
                                                    child: Text(action),
                                                  ))
                                              .toList(),
                                          onChanged: (value) {
                                            setState(() {
                                              selectedAction = value!;
                                            });
                                          },
                                        ),
                                      ],
                                    ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                onPressed: toggleRecording,
                                icon: Icon(isRecording ? Icons.stop : Icons.play_arrow),
                                label: Text(isRecording ? '停止錄製' : '開始錄製'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor: isRecording ? Colors.red : Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // 加速度圖表 (保持不變)
                      Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  const Text(
                                    '🚀 加速度 (m/s²)',
                                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                                  ),
                                  const Spacer(),
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.shade200,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      'Az峰值增強',
                                      style: TextStyle(fontSize: 10, color: Colors.blue.shade800),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 250,
                                child: LineChart(
                                  LineChartData(
                                    minY: -10,
                                    maxY: 10,
                                    gridData: FlGridData(show: true, drawHorizontalLine: true),
                                    titlesData: FlTitlesData(
                                      leftTitles: AxisTitles(
                                        sideTitles: SideTitles(showTitles: true, reservedSize: 40),
                                      ),
                                      bottomTitles: AxisTitles(
                                        sideTitles: SideTitles(showTitles: false),
                                      ),
                                      topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                      rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                    ),
                                    lineBarsData: [
                                      LineChartBarData(
                                        spots: axData,
                                        isCurved: true,
                                        curveSmoothness: 0.2,
                                        dotData: FlDotData(show: false),
                                        color: Colors.red,
                                        barWidth: 2,
                                      ),
                                      LineChartBarData(
                                        spots: ayData,
                                        isCurved: true,
                                        curveSmoothness: 0.2,
                                        dotData: FlDotData(show: false),
                                        color: Colors.green,
                                        barWidth: 2,
                                      ),
                                      LineChartBarData(
                                        spots: azData,
                                        isCurved: true,
                                        curveSmoothness: 0.2,
                                        dotData: FlDotData(show: false),
                                        color: Colors.blue,
                                        barWidth: 3, // Az 線條加粗以突出顯示
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              buildLegendSection([
                                buildLegend('X軸 (左右)', Colors.red),
                                buildLegend('Y軸 (前後)', Colors.green),
                                buildLegend('Z軸 (上下)', Colors.blue),
                              ]),
                            ],
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // 陀螺儀圖表 (保持不變)
                      Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '🌀 陀螺儀 (deg/s)',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 250,
                                child: LineChart(
                                  LineChartData(
                                    minY: -1000,
                                    maxY: 2000,
                                    gridData: FlGridData(show: true, drawHorizontalLine: true),
                                    titlesData: FlTitlesData(
                                      leftTitles: AxisTitles(
                                        sideTitles: SideTitles(showTitles: true, reservedSize: 50),
                                      ),
                                      bottomTitles: AxisTitles(
                                        sideTitles: SideTitles(showTitles: false),
                                      ),
                                      topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                      rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                    ),
                                    lineBarsData: [
                                      LineChartBarData(
                                        spots: gxData,
                                        isCurved: true,
                                        curveSmoothness: 0.2,
                                        dotData: FlDotData(show: false),
                                        color: Colors.orange,
                                        barWidth: 2,
                                      ),
                                      LineChartBarData(
                                        spots: gyData,
                                        isCurved: true,
                                        curveSmoothness: 0.2,
                                        dotData: FlDotData(show: false),
                                        color: Colors.purple,
                                        barWidth: 2,
                                      ),
                                      LineChartBarData(
                                        spots: gzData,
                                        isCurved: true,
                                        curveSmoothness: 0.2,
                                        dotData: FlDotData(show: false),
                                        color: Colors.cyan,
                                        barWidth: 2,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              buildLegendSection([
                                buildLegend('Gx (翻滾)', Colors.orange),
                                buildLegend('Gy (俯仰)', Colors.purple),
                                buildLegend('Gz (偏航)', Colors.cyan),
                              ]),
                            ],
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // 麥克風圖表 (保持不變)
                      Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '🎤 麥克風 (音量/峰值)',
                                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 250,
                                child: LineChart(
                                  LineChartData(
                                    minY: 0,
                                    maxY: 2500,
                                    gridData: FlGridData(show: true, drawHorizontalLine: true),
                                    titlesData: FlTitlesData(
                                      leftTitles: AxisTitles(
                                        sideTitles: SideTitles(showTitles: true, reservedSize: 50),
                                      ),
                                      bottomTitles: AxisTitles(
                                        sideTitles: SideTitles(showTitles: false),
                                      ),
                                      topTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                      rightTitles: AxisTitles(sideTitles: SideTitles(showTitles: false)),
                                    ),
                                    lineBarsData: [
                                      LineChartBarData(
                                        spots: micLevelData,
                                        isCurved: true,
                                        curveSmoothness: 0.2,
                                        dotData: FlDotData(show: false),
                                        color: Colors.amber,
                                        barWidth: 2,
                                      ),
                                      LineChartBarData(
                                        spots: micPeakData,
                                        isCurved: true,
                                        curveSmoothness: 0.2,
                                        dotData: FlDotData(show: false),
                                        color: Colors.pink,
                                        barWidth: 2,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                              buildLegendSection([
                                buildLegend('音量 Level', Colors.amber),
                                buildLegend('峰值 Peak', Colors.pink),
                              ]),
                            ],
                          ),
                        ),
                      ),
                      
                      const SizedBox(height: 20),
                      
                      // 資料統計資訊 (保持不變)
                      Card(
                        elevation: 2,
                        color: Colors.blue.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            children: [
                              const Text('📊 即時統計', style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment: MainAxisAlignment.spaceAround,
                                children: [
                                  Column(
                                    children: [
                                      Text('資料頻率', style: TextStyle(color: Colors.grey.shade600)),
                                      Text('${averageDataRate.toStringAsFixed(1)} Hz', 
                                           style: const TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  Column(
                                    children: [
                                      Text('顯示點數', style: TextStyle(color: Colors.grey.shade600)),
                                      Text('$maxPoints 點', 
                                           style: const TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                  Column(
                                    children: [
                                      Text('時間窗口', style: TextStyle(color: Colors.grey.shade600)),
                                      Text('${displayTimeWindow}s', 
                                           style: const TextStyle(fontWeight: FontWeight.bold)),
                                    ],
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
    );
  }
}