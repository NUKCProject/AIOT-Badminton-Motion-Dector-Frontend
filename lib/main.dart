import 'package:flutter/material.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:fl_chart/fl_chart.dart';
import 'dart:typed_data';

void main() {
  runApp(const MyApp());
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'BLE IMU Line Chart',
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

  List<FlSpot> axData = [];
  List<FlSpot> ayData = [];
  List<FlSpot> azData = [];
  List<FlSpot> gxData = [];
  List<FlSpot> gyData = [];
  List<FlSpot> gzData = [];

  int counter = 0;
  final int maxPoints = 50;

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
    discoverServices(device);
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
        double ax = byteData.getFloat32(8, Endian.little);
        double ay = byteData.getFloat32(12, Endian.little);
        double az = byteData.getFloat32(16, Endian.little);
        double gx = byteData.getFloat32(20, Endian.little);
        double gy = byteData.getFloat32(24, Endian.little);
        double gz = byteData.getFloat32(28, Endian.little);

        setState(() {
          counter++;
          addData(axData, counter.toDouble(), ax);
          addData(ayData, counter.toDouble(), ay);
          addData(azData, counter.toDouble(), az);
          addData(gxData, counter.toDouble(), gx);
          addData(gyData, counter.toDouble(), gy);
          addData(gzData, counter.toDouble(), gz);
        });
      });
    }
  }

  void addData(List<FlSpot> dataList, double x, double y) {
    dataList.add(FlSpot(x, y));
    if (dataList.length > maxPoints) {
      dataList.removeAt(0);
    }
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
      appBar: AppBar(title: const Text('BLE IMU Line Chart')),
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
                    SizedBox(
                      height: 300,
                      child: LineChart(
                        LineChartData(
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
                    const SizedBox(height: 20),
                    Wrap(
                      alignment: WrapAlignment.center,
                      spacing: 10,
                      children: [
                        buildLegend('Ax', Colors.red),
                        buildLegend('Ay', Colors.green),
                        buildLegend('Az', Colors.blue),
                        buildLegend('Gx', Colors.orange),
                        buildLegend('Gy', Colors.purple),
                        buildLegend('Gz', Colors.cyan),
                      ],
                    ),
                  ],
                ),
              ),
    );
  }
}
