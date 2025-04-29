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

  @override
  void initState() {
    super.initState();
    startScan();
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
        int eqpId = byteData.getUint16(8, Endian.little);
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

    List<Map<String, dynamic>> dataToSend = List.from(recordedData);
    recordedData.clear();

    String url =
        selectedMode == 'Reference'
            ? 'https://badminton-457613.de.r.appspot.com/record-reference-raw-data'
            : 'https://badminton-457613.de.r.appspot.com/record-training-raw-data';

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

  Widget buildLegend(String label, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(width: 10, height: 10, color: color),
        const SizedBox(width: 4),
        Text(label),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(
          'BLE IMU Recorder (ID: ${deviceId.toRadixString(16).toUpperCase()})',
        ),
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
                child: Column(
                  children: [
                    const SizedBox(height: 10),
                    if (!isRecording)
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
                    if (!isRecording)
                      DropdownButton<String>(
                        value: selectedAction,
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
                    ElevatedButton(
                      onPressed: toggleRecording,
                      child: Text(isRecording ? '停止錄製' : '開始錄製'),
                    ),
                    const SizedBox(height: 10),
                    const Text(
                      'Acceleration (m/s²)',
                      style: TextStyle(fontSize: 18),
                    ),
                    SizedBox(
                      height: 250,
                      child: LineChart(
                        LineChartData(
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
                    const SizedBox(height: 10),
                    const Text(
                      'Gyroscope (deg/s)',
                      style: TextStyle(fontSize: 18),
                    ),
                    SizedBox(
                      height: 250,
                      child: LineChart(
                        LineChartData(
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
                    const SizedBox(height: 10),
                    const Text(
                      'Mic Level/Peak',
                      style: TextStyle(fontSize: 18),
                    ),
                    SizedBox(
                      height: 250,
                      child: LineChart(
                        LineChartData(
                          minY: 0,
                          maxY: 5000,
                          lineBarsData: [
                            LineChartBarData(
                              spots: micLevelData,
                              isCurved: true,
                              dotData: FlDotData(show: false),
                              color: Colors.yellow,
                            ),
                            LineChartBarData(
                              spots: micPeakData,
                              isCurved: true,
                              dotData: FlDotData(show: false),
                              color: Colors.pink,
                            ),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(height: 10),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 10,
                      children: [
                        buildLegend('Level', Colors.yellow),
                        buildLegend('Peak', Colors.pink),
                      ],
                    ),
                  ],
                ),
              ),
    );
  }
}
