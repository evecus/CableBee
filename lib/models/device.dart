enum ConnectionType { wifi, usb }
enum DeviceState { online, offline, unauthorized, connecting }

class AdbDevice {
  final String serial;
  final String? model;
  final String? product;
  final String? transportId;
  final ConnectionType connectionType;
  DeviceState state;

  AdbDevice({
    required this.serial,
    this.model,
    this.product,
    this.transportId,
    required this.connectionType,
    this.state = DeviceState.online,
  });

  String get displayName => model ?? serial;

  String get shortSerial {
    if (serial.contains(':')) return serial; // IP:port
    if (serial.length > 12) return '${serial.substring(0, 6)}…${serial.substring(serial.length - 4)}';
    return serial;
  }

  bool get isWifi => connectionType == ConnectionType.wifi;

  factory AdbDevice.fromAdbLine(String line) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) {
      return AdbDevice(
        serial: line.trim(),
        connectionType: ConnectionType.wifi,
        state: DeviceState.offline,
      );
    }

    final serial = parts[0];
    final stateStr = parts[1];
    final isWifi = serial.contains(':') || serial.contains('.');

    DeviceState state;
    switch (stateStr) {
      case 'device':
        state = DeviceState.online;
      case 'unauthorized':
        state = DeviceState.unauthorized;
      case 'offline':
        state = DeviceState.offline;
      default:
        state = DeviceState.offline;
    }

    String? model, product;
    for (final part in parts.skip(2)) {
      if (part.startsWith('model:')) model = part.substring(6);
      if (part.startsWith('product:')) product = part.substring(8);
    }

    return AdbDevice(
      serial: serial,
      model: model?.replaceAll('_', ' '),
      product: product,
      connectionType: isWifi ? ConnectionType.wifi : ConnectionType.usb,
      state: state,
    );
  }

  @override
  bool operator ==(Object other) => other is AdbDevice && other.serial == serial;

  @override
  int get hashCode => serial.hashCode;
}
