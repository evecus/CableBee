import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

class UsbDevice {
  final String name;
  final int vendorId;
  final int productId;
  final String deviceName;
  final String serialNumber;

  UsbDevice({
    required this.name,
    required this.vendorId,
    required this.productId,
    required this.deviceName,
    required this.serialNumber,
  });

  factory UsbDevice.fromMap(Map m) => UsbDevice(
    name:         m['name'] as String? ?? '',
    vendorId:     m['vendorId'] as int? ?? 0,
    productId:    m['productId'] as int? ?? 0,
    deviceName:   m['deviceName'] as String? ?? '',
    serialNumber: m['serialNumber'] as String? ?? '',
  );

  String get displayId => '${vendorId.toRadixString(16).padLeft(4,'0')}:'
      '${productId.toRadixString(16).padLeft(4,'0')}';
}

class UsbService extends ChangeNotifier {
  static const _method = MethodChannel('com.cablebee/usb');
  static const _events = EventChannel('com.cablebee/usb_events');

  List<UsbDevice> _devices = [];
  bool _hostSupported = false;
  StreamSubscription? _eventSub;

  List<UsbDevice> get devices => List.unmodifiable(_devices);
  bool get hostSupported => _hostSupported;

  Future<void> initialize() async {
    try {
      _hostSupported = await _method.invokeMethod('hasUsbHostSupport') ?? false;
    } catch (_) {
      _hostSupported = false;
    }

    // Listen for USB attach/detach
    _eventSub = _events.receiveBroadcastStream().listen((event) {
      final e = Map<String, dynamic>.from(event as Map);
      if (e['event'] == 'attached' || e['event'] == 'detached') {
        refresh();
      }
    });

    await refresh();
  }

  Future<void> refresh() async {
    try {
      final raw = await _method.invokeListMethod('getConnectedUsbDevices');
      if (raw != null) {
        _devices = raw
            .map((e) => UsbDevice.fromMap(Map<String, dynamic>.from(e as Map)))
            .toList();
        notifyListeners();
      }
    } catch (_) {}
  }

  @override
  void dispose() {
    _eventSub?.cancel();
    super.dispose();
  }
}
