import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'package:http/http.dart' as http;
import 'dart:typed_data';
import 'dart:convert';
import 'dart:async';
import 'dart:developer' as developer;
import 'dart:io';
import 'package:path_provider/path_provider.dart';

void main() {
  // 設置日誌過濾，隱藏 Flutter Blue Plus 的 debug 訊息
  FlutterBluePlus.setLogLevel(LogLevel.warning);

  runApp(const MyApp());
}

// 注意：如果是Android系統，可能需要在 android/app/src/main/AndroidManifest.xml 中添加權限：
// <uses-permission android:name="android.permission.WRITE_EXTERNAL_STORAGE" />
// <uses-permission android:name="android.permission.READ_EXTERNAL_STORAGE" />

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
  BluetoothCharacteristic? timeSyncCharacteristic;

  final String imuServiceUUID = "14A168D7-04D1-6C4F-7E53-F2E800B11900";
  final String imuCharacteristicUUID = "14A168D7-04D1-6C4F-7E53-F2E801B11900";
  final String timeSyncCharacteristicUUID =
      "14A168D7-04D1-6C4F-7E53-F2E802B11900";

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
  int maxPoints = 100;
  final double displayTimeWindow = 1.5;
  int deviceId = 0;

  final int batchSize = 1000;

  // Az 峰值增強參數
  double azThreshold = 0.5;
  double azEnhanceFactor = 1.5;

  // 添加數據統計相關變數
  int dataCountThisSecond = 0;
  DateTime lastSecondTime = DateTime.now();
  Timer? statisticsTimer;
  double averageDataRate = 0;

  // 時間同步相關變數
  bool isTimeSyncing = false;
  String timeSyncStatus = '未同步';
  DateTime? lastSyncTime;

  // 新增：預測功能相關變數
  bool isPredictionEnabled = false;
  List<Map<String, dynamic>> predictionBuffer = [];
  bool isCollectingPredictionData = false;
  final int predictionDataCount = 30;
  final double triggerThreshold = 3.0; // 修改觸發閾值為3.0
  List<Map<String, dynamic>> predictionHistory = [];

  // 新增：數據緩衝區用於保存觸發前的數據
  List<Map<String, dynamic>> dataBuffer = [];
  final int maxBufferSize = 50; // 保持足夠的緩衝區大小
  int remainingDataToCollect = 0; // 觸發後還需要收集的數據數量

  @override
  void initState() {
    super.initState();
    startScan();
    startStatisticsTimer();
  }

  @override
  void dispose() {
    statisticsTimer?.cancel();
    super.dispose();
  }

  void startStatisticsTimer() {
    statisticsTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      // print('Data rate: $dataCountThisSecond packets/second');

      if (averageDataRate == 0) {
        averageDataRate = dataCountThisSecond.toDouble();
      } else {
        averageDataRate = (averageDataRate * 0.8) + (dataCountThisSecond * 0.2);
      }

      maxPoints = (averageDataRate * displayTimeWindow).round();
      if (maxPoints < 10) maxPoints = 10;
      if (maxPoints > 500) maxPoints = 500;

      // print(
      //   'Display window: ${displayTimeWindow}s, Max points: $maxPoints, Avg rate: ${averageDataRate.toStringAsFixed(1)} Hz',
      // );

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
          timeSyncCharacteristic = null;
          timeSyncStatus = '未同步';
          lastSyncTime = null;
          isRecording = false;
          recordedData.clear();
          // 重置預測相關狀態
          isPredictionEnabled = false;
          predictionBuffer.clear();
          dataBuffer.clear();
          isCollectingPredictionData = false;
          remainingDataToCollect = 0;
        });
        startScan();
      }
    });
  }

  Future<void> discoverServices(BluetoothDevice device) async {
    List<BluetoothService> services = await device.discoverServices();
    for (BluetoothService service in services) {
      if (service.uuid.toString().toUpperCase() == imuServiceUUID) {
        for (BluetoothCharacteristic characteristic
            in service.characteristics) {
          String charUUID = characteristic.uuid.toString().toUpperCase();

          if (charUUID == imuCharacteristicUUID) {
            setState(() {
              imuCharacteristic = characteristic;
            });
            await subscribeToIMUData();
          } else if (charUUID == timeSyncCharacteristicUUID) {
            setState(() {
              timeSyncCharacteristic = characteristic;
            });
            print('發現時間同步特徵');
          }
        }
      }
    }

    if (timeSyncCharacteristic != null) {
      await performTimeSync();
    }
  }

  Future<void> performTimeSync() async {
    if (timeSyncCharacteristic == null || isTimeSyncing) {
      return;
    }

    setState(() {
      isTimeSyncing = true;
      timeSyncStatus = '同步中...';
    });

    try {
      int utcTimestampMs = DateTime.now().toUtc().millisecondsSinceEpoch;

      ByteData byteData = ByteData(8);
      byteData.setInt64(0, utcTimestampMs, Endian.little);

      Uint8List timeData = byteData.buffer.asUint8List();

      print('發送時間同步請求: $utcTimestampMs ms (UTC)');
      print(
        '時間數據: ${timeData.map((b) => b.toRadixString(16).padLeft(2, '0')).join(' ')}',
      );

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

      developer.log('時間同步失敗', name: 'TimeSync', error: e, time: DateTime.now());
    } finally {
      setState(() {
        isTimeSyncing = false;
      });
    }
  }

  // 修改：檢查是否觸發預測收集
  void checkPredictionTrigger(double ax, double ay, double az) {
    if (!isPredictionEnabled || isCollectingPredictionData) return;

    // 新的觸發條件：|ax|>3 or |ay|>3 or |az|>3
    bool triggered =
        ax.abs() > triggerThreshold ||
        ay.abs() > triggerThreshold ||
        az.abs() > triggerThreshold;

    if (triggered) {
      print(
        '預測觸發！ax: ${ax.toStringAsFixed(3)}, ay: ${ay.toStringAsFixed(3)}, az: ${az.toStringAsFixed(3)}',
      );
      print(
        '觸發條件：|ax|>${triggerThreshold} or |ay|>${triggerThreshold} or |az|>${triggerThreshold}',
      );

      setState(() {
        isCollectingPredictionData = true;
        predictionBuffer.clear();

        // 從緩衝區取得觸發前的10筆數據 (修改這裡)
        int preDataCount = dataBuffer.length >= 10 ? 10 : dataBuffer.length;
        if (preDataCount > 0) {
          predictionBuffer.addAll(
            dataBuffer.sublist(dataBuffer.length - preDataCount),
          );
          print('從緩衝區獲取觸發前數據：${preDataCount}筆');
        }

        // 設定還需要收集的數據數量（觸發點後的20筆）(修改這裡)
        remainingDataToCollect = 20;
        print('準備收集觸發後數據：${remainingDataToCollect}筆');
      });
    }
  }

  // 修改：收集預測數據
  void collectPredictionData(Map<String, dynamic> data) {
    // 始終維護數據緩衝區（用於觸發前數據）
    if (isPredictionEnabled) {
      dataBuffer.add(data);
      if (dataBuffer.length > maxBufferSize) {
        dataBuffer.removeAt(0); // 保持緩衝區大小
      }
    }

    // 如果正在收集預測數據
    if (isCollectingPredictionData && remainingDataToCollect > 0) {
      predictionBuffer.add(data);
      remainingDataToCollect--;

      print(
        '收集觸發後數據，剩餘：${remainingDataToCollect}筆，已收集：${predictionBuffer.length}筆',
      );

      // 收集完成30筆數據
      if (remainingDataToCollect <= 0 &&
          predictionBuffer.length >= predictionDataCount) {
        print('數據收集完成！總計：${predictionBuffer.length}筆');
        sendPredictionRequest();
        setState(() {
          isCollectingPredictionData = false;
          remainingDataToCollect = 0;
        });
      }
    }
  }

  // 新增：保存預測數據到CSV
  Future<void> savePredictionDataToCSV(
    List<Map<String, dynamic>> sensorData,
  ) async {
    try {
      // 嘗試獲取外部存儲目錄，如果失敗則使用應用程式目錄
      Directory? directory;
      try {
        directory = await getExternalStorageDirectory();
      } catch (e) {
        print('無法獲取外部存儲目錄: $e');
      }

      // 如果外部存儲不可用，使用應用程式文件目錄
      directory ??= await getApplicationDocumentsDirectory();

      final timestamp = DateTime.now().millisecondsSinceEpoch;
      final fileName = 'prediction_data_$timestamp.csv';
      final filePath = '${directory.path}/$fileName';
      final file = File(filePath);

      print('準備保存CSV檔案到: $filePath');

      // CSV 標題行
      String csvContent = 'ts,ax,ay,az,gx,gy,gz,mic_level,mic_peak\n';

      // 寫入30筆連續性資料
      for (var data in sensorData) {
        csvContent +=
            '${data['ts']},${data['ax']},${data['ay']},${data['az']},${data['gx']},${data['gy']},${data['gz']},${data['mic_level']},${data['mic_peak']}\n';
      }

      await file.writeAsString(csvContent);

      // 驗證檔案是否成功建立
      if (await file.exists()) {
        final fileSize = await file.length();
        print('✓ CSV檔案保存成功！');
        print('  檔案路徑: $filePath');
        print('  檔案大小: $fileSize bytes');
        print('  資料筆數: ${sensorData.length}筆');
      } else {
        print('✗ 檔案保存失敗：檔案不存在');
      }
    } catch (e, stackTrace) {
      print('✗ 保存CSV檔案時發生錯誤: $e');
      print('錯誤詳情: $stackTrace');
    }
  }

  // 新增：發送預測請求
  Future<void> sendPredictionRequest() async {
    if (predictionBuffer.isEmpty) return;

    try {
      final requestData = {
        "sensor_data":
            predictionBuffer
                .map(
                  (data) => {
                    "ts": data["ts"],
                    "ax": data["ax"],
                    "ay": data["ay"],
                    "az": data["az"],
                    "gx": data["gx"],
                    "gy": data["gy"],
                    "gz": data["gz"],
                    // "mic_level": data["mic_level"],
                    // "mic_peak": data["mic_peak"],
                  },
                )
                .toList(),
      };

      print('發送預測請求，數據點數: ${predictionBuffer.length}');
      print('請求數據: $requestData');
      // 保存30筆連續性資料到CSV
      await savePredictionDataToCSV(predictionBuffer);

      final response = await http.post(
        Uri.parse('https://badminton-461016.de.r.appspot.com/predict'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode(requestData),
      );

      if (response.statusCode == 200) {
        final responseData = jsonDecode(response.body);
        print('收到預測結果: $responseData');

        // 保存到歷史記錄
        setState(() {
          predictionHistory.insert(0, responseData);
          // 只保留最近50筆記錄
          if (predictionHistory.length > 50) {
            predictionHistory.removeLast();
          }
        });

        showSnackbar(
          '預測成功: ${responseData['prediction']} (${(responseData['confidence'] * 100).toStringAsFixed(1)}%)',
          true,
        );
      } else {
        print('預測請求失敗: ${response.statusCode}');
        showSnackbar('預測請求失敗: ${response.statusCode}', false);
      }
    } catch (e) {
      print('預測請求錯誤: $e');
      showSnackbar('預測請求錯誤: $e', false);
    }
  }

  Future<void> subscribeToIMUData() async {
    if (imuCharacteristic != null) {
      await imuCharacteristic!.setNotifyValue(true);
      imuCharacteristic!.onValueReceived.listen((value) {
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

        DateTime timestampDateTime = DateTime.fromMillisecondsSinceEpoch(
          timestamp,
          isUtc: true,
        );
        DateTime currentTime = DateTime.now().toUtc();
        int timeDifference = currentTime.millisecondsSinceEpoch - timestamp;

        DateTime deviceTimeTW = timestampDateTime.add(const Duration(hours: 8));
        DateTime currentTimeTW = DateTime.now();

        String formatTaiwanTime(DateTime dt) {
          return '${dt.year}/${dt.month.toString().padLeft(2, '0')}/${dt.day.toString().padLeft(2, '0')} '
              '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:'
              '${dt.second.toString().padLeft(2, '0')}.${dt.millisecond.toString().padLeft(3, '0')}';
        }

        // print(
        //   '接收到數據: '
        //   '時間戳: ${formatTaiwanTime(deviceTimeTW)} (UTC+8), '
        //   '設備時間差: ${timeDifference}ms, '
        //   '設備ID: ${eqpId.toRadixString(16).toUpperCase()}, '
        //   'ax: $ax, ay: $ay, az: $az, '
        //   'gx: $gx, gy: $gy, gz: $gz, '
        //   '麥克風音量: $micLevel, 峰值: $micPeak',
        // );

        // 新增：檢查預測觸發和收集數據
        checkPredictionTrigger(ax, ay, az);

        Map<String, dynamic> currentData = {
          "ts": timestamp,
          "ax": ax,
          "ay": ay,
          "az": az,
          "gx": gx,
          "gy": gy,
          "gz": gz,
          "mic_level": micLevel,
          "mic_peak": micPeak,
        };

        collectPredictionData(currentData);

        double processedAz = az;
        if (az.abs() > azThreshold) {
          processedAz =
              az.sign *
              (azThreshold + (az.abs() - azThreshold) * azEnhanceFactor);
        }

        setState(() {
          deviceId = eqpId;
          counter++;
          addData(axData, counter.toDouble(), ax);
          addData(ayData, counter.toDouble(), ay);
          addData(azData, counter.toDouble(), processedAz);
          addData(gxData, counter.toDouble(), gx);
          addData(gyData, counter.toDouble(), gy);
          addData(gzData, counter.toDouble(), gz);
          addData(micLevelData, counter.toDouble(), micLevel.toDouble());
          addData(micPeakData, counter.toDouble(), micPeak.toDouble());
        });

        if (isRecording) {
          recordedData.add(currentData);

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
        actions: [
          if (connectedDevice != null)
            IconButton(
              icon: const Icon(Icons.psychology),
              onPressed: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder:
                        (context) => PredictionPage(
                          predictionHistory: predictionHistory,
                          isPredictionEnabled: isPredictionEnabled,
                          isCollectingData: isCollectingPredictionData,
                          bufferSize: predictionBuffer.length,
                          onTogglePrediction: (value) {
                            setState(() {
                              isPredictionEnabled = value;
                              if (!value) {
                                predictionBuffer.clear();
                                isCollectingPredictionData = false;
                              }
                            });
                          },
                        ),
                  ),
                );
              },
              tooltip: '預測結果',
            ),
        ],
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
                              // 時間同步狀態區域
                              Container(
                                padding: const EdgeInsets.all(12),
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color:
                                      timeSyncStatus == '同步成功'
                                          ? Colors.green.shade50
                                          : timeSyncStatus == '同步失敗'
                                          ? Colors.red.shade50
                                          : Colors.orange.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color:
                                        timeSyncStatus == '同步成功'
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
                                      color:
                                          timeSyncStatus == '同步成功'
                                              ? Colors.green.shade700
                                              : timeSyncStatus == '同步失敗'
                                              ? Colors.red.shade700
                                              : Colors.orange.shade700,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '時間同步狀態: $timeSyncStatus',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
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
                                    if (timeSyncCharacteristic != null &&
                                        !isTimeSyncing)
                                      ElevatedButton.icon(
                                        onPressed: performTimeSync,
                                        icon: const Icon(Icons.sync, size: 16),
                                        label: const Text('重新同步'),
                                        style: ElevatedButton.styleFrom(
                                          backgroundColor: Colors.blue,
                                          foregroundColor: Colors.white,
                                          padding: const EdgeInsets.symmetric(
                                            horizontal: 12,
                                            vertical: 8,
                                          ),
                                          textStyle: const TextStyle(
                                            fontSize: 12,
                                          ),
                                        ),
                                      ),
                                    if (isTimeSyncing)
                                      const SizedBox(
                                        width: 20,
                                        height: 20,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      ),
                                  ],
                                ),
                              ),

                              // 新增：預測功能控制區域
                              Container(
                                padding: const EdgeInsets.all(12),
                                margin: const EdgeInsets.only(bottom: 16),
                                decoration: BoxDecoration(
                                  color:
                                      isPredictionEnabled
                                          ? Colors.purple.shade50
                                          : Colors.grey.shade50,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color:
                                        isPredictionEnabled
                                            ? Colors.purple.shade300
                                            : Colors.grey.shade300,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    Icon(
                                      Icons.psychology,
                                      color:
                                          isPredictionEnabled
                                              ? Colors.purple.shade700
                                              : Colors.grey.shade600,
                                      size: 20,
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '預測功能: ${isPredictionEnabled ? "啟用" : "關閉"}',
                                            style: const TextStyle(
                                              fontWeight: FontWeight.bold,
                                            ),
                                          ),
                                          if (isPredictionEnabled)
                                            Text(
                                              isCollectingPredictionData
                                                  ? '正在收集數據'
                                                  : '等待觸發',
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Colors.grey.shade600,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                    Switch(
                                      value: isPredictionEnabled,
                                      onChanged: (value) {
                                        setState(() {
                                          isPredictionEnabled = value;
                                          if (!value) {
                                            predictionBuffer.clear();
                                            isCollectingPredictionData = false;
                                          }
                                        });
                                      },
                                      activeColor: Colors.purple,
                                    ),
                                  ],
                                ),
                              ),

                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceEvenly,
                                children: [
                                  if (!isRecording)
                                    Column(
                                      children: [
                                        const Text(
                                          '錄製模式',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        DropdownButton<String>(
                                          value: selectedMode,
                                          items:
                                              recordingModes
                                                  .map(
                                                    (mode) => DropdownMenuItem(
                                                      value: mode,
                                                      child: Text(mode),
                                                    ),
                                                  )
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
                                        const Text(
                                          '動作類型',
                                          style: TextStyle(
                                            fontWeight: FontWeight.bold,
                                          ),
                                        ),
                                        DropdownButton<String>(
                                          value: selectedAction,
                                          items:
                                              actions
                                                  .map(
                                                    (action) =>
                                                        DropdownMenuItem(
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
                                      ],
                                    ),
                                ],
                              ),
                              const SizedBox(height: 16),
                              ElevatedButton.icon(
                                onPressed: toggleRecording,
                                icon: Icon(
                                  isRecording ? Icons.stop : Icons.play_arrow,
                                ),
                                label: Text(isRecording ? '停止錄製' : '開始錄製'),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      isRecording ? Colors.red : Colors.green,
                                  foregroundColor: Colors.white,
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 24,
                                    vertical: 12,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      const SizedBox(height: 20),

                      // 加速度圖表
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
                                    style: TextStyle(
                                      fontSize: 18,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  const Spacer(),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 4,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.blue.shade200,
                                      borderRadius: BorderRadius.circular(12),
                                    ),
                                    child: Text(
                                      'Az峰值增強',
                                      style: TextStyle(
                                        fontSize: 10,
                                        color: Colors.blue.shade800,
                                      ),
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
                                    gridData: FlGridData(
                                      show: true,
                                      drawHorizontalLine: true,
                                    ),
                                    titlesData: FlTitlesData(
                                      leftTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: true,
                                          reservedSize: 40,
                                        ),
                                      ),
                                      bottomTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
                                      topTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
                                      rightTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
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
                                        barWidth: 3,
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

                      // 陀螺儀圖表
                      Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '🌀 陀螺儀 (deg/s)',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 250,
                                child: LineChart(
                                  LineChartData(
                                    minY: -1000,
                                    maxY: 2000,
                                    gridData: FlGridData(
                                      show: true,
                                      drawHorizontalLine: true,
                                    ),
                                    titlesData: FlTitlesData(
                                      leftTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: true,
                                          reservedSize: 50,
                                        ),
                                      ),
                                      bottomTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
                                      topTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
                                      rightTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
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

                      // 麥克風圖表
                      Card(
                        elevation: 4,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text(
                                '🎤 麥克風 (音量/峰值)',
                                style: TextStyle(
                                  fontSize: 18,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                height: 250,
                                child: LineChart(
                                  LineChartData(
                                    minY: 0,
                                    maxY: 2500,
                                    gridData: FlGridData(
                                      show: true,
                                      drawHorizontalLine: true,
                                    ),
                                    titlesData: FlTitlesData(
                                      leftTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: true,
                                          reservedSize: 50,
                                        ),
                                      ),
                                      bottomTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
                                      topTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
                                      rightTitles: AxisTitles(
                                        sideTitles: SideTitles(
                                          showTitles: false,
                                        ),
                                      ),
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

                      // 資料統計資訊
                      Card(
                        elevation: 2,
                        color: Colors.blue.shade50,
                        child: Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            children: [
                              const Text(
                                '📊 即時統計',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              const SizedBox(height: 8),
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceAround,
                                children: [
                                  Column(
                                    children: [
                                      Text(
                                        '資料頻率',
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      Text(
                                        '${averageDataRate.toStringAsFixed(1)} Hz',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Column(
                                    children: [
                                      Text(
                                        '顯示點數',
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      Text(
                                        '$maxPoints 點',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
                                    ],
                                  ),
                                  Column(
                                    children: [
                                      Text(
                                        '時間窗口',
                                        style: TextStyle(
                                          color: Colors.grey.shade600,
                                        ),
                                      ),
                                      Text(
                                        '${displayTimeWindow}s',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.bold,
                                        ),
                                      ),
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

// 新增：預測結果頁面
class PredictionPage extends StatelessWidget {
  final List<Map<String, dynamic>> predictionHistory;
  final bool isPredictionEnabled;
  final bool isCollectingData;
  final int bufferSize;
  final Function(bool) onTogglePrediction;

  const PredictionPage({
    super.key,
    required this.predictionHistory,
    required this.isPredictionEnabled,
    required this.isCollectingData,
    required this.bufferSize,
    required this.onTogglePrediction,
  });

  String formatTimestamp(int timestamp) {
    DateTime dt = DateTime.fromMillisecondsSinceEpoch(timestamp);
    return '${dt.hour.toString().padLeft(2, '0')}:${dt.minute.toString().padLeft(2, '0')}:${dt.second.toString().padLeft(2, '0')}.${dt.millisecond.toString().padLeft(3, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('🎯 預測結果'),
        backgroundColor: Colors.purple.shade100,
      ),
      body: Column(
        children: [
          // 控制區域
          Container(
            padding: const EdgeInsets.all(16),
            margin: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color:
                  isPredictionEnabled
                      ? Colors.purple.shade50
                      : Colors.grey.shade50,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color:
                    isPredictionEnabled
                        ? Colors.purple.shade300
                        : Colors.grey.shade300,
              ),
            ),
            child: Column(
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.psychology,
                      color:
                          isPredictionEnabled
                              ? Colors.purple.shade700
                              : Colors.grey.shade600,
                      size: 24,
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '預測功能控制',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                              color:
                                  isPredictionEnabled
                                      ? Colors.purple.shade700
                                      : Colors.grey.shade700,
                            ),
                          ),
                          Text(
                            isPredictionEnabled ? '已啟用' : '已關閉',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade600,
                            ),
                          ),
                        ],
                      ),
                    ),
                    Switch(
                      value: isPredictionEnabled,
                      onChanged: onTogglePrediction,
                      activeColor: Colors.purple,
                    ),
                  ],
                ),
                if (isPredictionEnabled) ...[
                  const SizedBox(height: 12),
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white,
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.purple.shade200),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          isCollectingData
                              ? Icons.fiber_manual_record
                              : Icons.sensors,
                          color: isCollectingData ? Colors.red : Colors.green,
                          size: 16,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            isCollectingData
                                ? '正在收集數據: $bufferSize/30'
                                : '等待觸發 (閾值: |ax|+|ay|+|az| > 4.0)',
                            style: const TextStyle(fontSize: 14),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),

          // 預測歷史記錄
          Expanded(
            child:
                predictionHistory.isEmpty
                    ? Center(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.history,
                            size: 64,
                            color: Colors.grey.shade400,
                          ),
                          const SizedBox(height: 16),
                          Text(
                            '尚無預測記錄',
                            style: TextStyle(
                              fontSize: 18,
                              color: Colors.grey.shade600,
                            ),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            isPredictionEnabled ? '等待觸發預測...' : '請先啟用預測功能',
                            style: TextStyle(
                              fontSize: 14,
                              color: Colors.grey.shade500,
                            ),
                          ),
                        ],
                      ),
                    )
                    : ListView.builder(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: predictionHistory.length,
                      itemBuilder: (context, index) {
                        final prediction = predictionHistory[index];
                        final strokeType =
                            prediction['stroke_type'] ?? 'Unknown';
                        final confidence =
                            (prediction['confidence'] ?? 0.0) as double;
                        final timestamp = prediction['timestamp'] ?? 0;
                        final allProbabilities =
                            prediction['all_probabilities']
                                as Map<String, dynamic>? ??
                            {};

                        return Card(
                          margin: const EdgeInsets.only(bottom: 12),
                          elevation: 2,
                          child: Padding(
                            padding: const EdgeInsets.all(16),
                            child: Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Colors.grey.shade50,
                                borderRadius: BorderRadius.circular(8),
                              ),
                              child: Text(
                                jsonEncode(prediction),
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontFamily: 'monospace',
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
          ),
        ],
      ),
    );
  }
}
