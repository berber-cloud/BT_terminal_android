// main.dart
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_blue_plus/flutter_blue_plus.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() => runApp(BtTerminalApp());

class BtTerminalApp extends StatelessWidget {
  @override
  Widget build(BuildContext context) => MaterialApp(
        debugShowCheckedModeBanner: false,
        title: 'Bluetooth Terminal',
        theme: ThemeData.dark().copyWith(
          colorScheme: ColorScheme.fromSeed(seedColor: Colors.teal),
        ),
        home: HomeScreen(),
      );
}

// ------------------- Модель кнопки -------------------
enum ButtonMode { normal, toggle, hold }

class ButtonConfig {
  final String id;
  String label;
  String value;           // основное значение (для normal / hold)
  String? offValue;       // для toggle – значение при выключении
  Color color;
  ButtonMode mode;
  int repeatDelayMs;      // для hold (мс)
  int repeatCount;        // 0 = бесконечно
  // transient state (не сохраняется)
  bool toggleState;

  ButtonConfig({
    required this.id,
    this.label = 'Btn',
    this.value = '',
    this.offValue,
    this.color = Colors.teal,
    this.mode = ButtonMode.normal,
    this.repeatDelayMs = 500,
    this.repeatCount = 0,
    this.toggleState = false,
  });

  Map<String, dynamic> toJson() => {
        'id': id,
        'label': label,
        'value': value,
        'offValue': offValue,
        'color': color.value.toRadixString(16),
        'mode': mode.index,
        'repeatDelayMs': repeatDelayMs,
        'repeatCount': repeatCount,
      };

  factory ButtonConfig.fromJson(Map<String, dynamic> json) => ButtonConfig(
        id: json['id'] as String,
        label: json['label'] as String? ?? 'Btn',
        value: json['value'] as String? ?? '',
        offValue: json['offValue'] as String?,
        color: Color(int.parse(json['color'] as String, radix: 16)),
        mode: ButtonMode.values[json['mode'] as int? ?? 0],
        repeatDelayMs: json['repeatDelayMs'] as int? ?? 500,
        repeatCount: json['repeatCount'] as int? ?? 0,
      );
}

// ------------------- Основной экран -------------------
class HomeScreen extends StatefulWidget {
  @override
  _HomeScreenState createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  // Bluetooth
  BluetoothDevice? _device;
  BluetoothCharacteristic? _txCharacteristic;
  BluetoothCharacteristic? _rxCharacteristic;
  List<BluetoothDevice> _devices = [];
  String _status = 'Not connected';
  bool _connecting = false;
  String? _lastDeviceAddress;

  // Buttons config
  List<ButtonConfig> _buttons = [];
  final String _buttonsPrefsKey = 'bt_buttons';

  // Terminal log
  final List<String> _log = [];

  // Подписки
  StreamSubscription? _scanSubscription;
  StreamSubscription? _connectionSubscription;
  StreamSubscription? _rxSubscription;

  @override
  void initState() {
    super.initState();
    _loadButtons();
    _loadLastDevice();
    _initBluetooth();
  }

  @override
  void dispose() {
    _scanSubscription?.cancel();
    _connectionSubscription?.cancel();
    _rxSubscription?.cancel();
    _device?.disconnect();
    super.dispose();
  }

  // ---------------- Инициализация Bluetooth ----------------
  void _initBluetooth() {
    // Слушаем состояние адаптера
    FlutterBluePlus.adapterState.listen((state) {
      if (state == BluetoothAdapterState.on) {
        _startScan();
      }
    });
    // Если адаптер уже включен — начинаем сканирование
    if (FlutterBluePlus.adapterStateNow == BluetoothAdapterState.on) {
      _startScan();
    }
  }

  void _startScan() {
    _devices.clear();
    FlutterBluePlus.startScan(timeout: const Duration(seconds: 15));
    _scanSubscription = FlutterBluePlus.onScanResults.listen((results) {
      for (ScanResult r in results) {
        if (!_devices.any((d) => d.remoteId == r.device.remoteId)) {
          setState(() => _devices.add(r.device));
        }
      }
    });
  }

  Future<void> _connectToDevice(BluetoothDevice device) async {
    if (_device != null) {
      await _device!.disconnect();
    }
    setState(() {
      _connecting = true;
      _status = 'Connecting...';
    });
    try {
      // Подключаемся
      await device.connect(timeout: const Duration(seconds: 15));
      setState(() {
        _device = device;
        _status = 'Discovering services...';
      });

      // Ищем сервисы
      List<BluetoothService> services = await device.discoverServices();
      BluetoothCharacteristic? tx, rx;
      // Ищем стандартный UART сервис (UUID: 6E400001-B5A3-F393-E0A9-E50E24DCCA9E)
      for (var service in services) {
        for (var characteristic in service.characteristics) {
          if (characteristic.uuid.toString() == '6E400002-B5A3-F393-E0A9-E50E24DCCA9E') {
            tx = characteristic;
          } else if (characteristic.uuid.toString() == '6E400003-B5A3-F393-E0A9-E50E24DCCA9E') {
            rx = characteristic;
          }
        }
      }
      // Если не нашли, ищем любой write/notify
      if (tx == null || rx == null) {
        for (var service in services) {
          for (var characteristic in service.characteristics) {
            if (characteristic.properties.write) tx ??= characteristic;
            if (characteristic.properties.notify) rx ??= characteristic;
          }
        }
      }
      if (tx == null) throw 'No writable characteristic found';

      setState(() {
        _txCharacteristic = tx;
        _rxCharacteristic = rx;
        _status = 'Connected to ${device.platformName}';
        _lastDeviceAddress = device.remoteId.toString();
      });
      _saveLastDevice();

      // Подписываемся на входящие данные
      if (rx != null) {
        await rx.setNotifyValue(true);
        _rxSubscription = rx.onValueReceived.listen((value) {
          setState(() => _log.add('← ${utf8.decode(value)}'));
        });
      }

      // Отслеживаем отключение
      _connectionSubscription = device.connectionState.listen((state) {
        if (state == BluetoothConnectionState.disconnected && mounted) {
          setState(() {
            _status = 'Disconnected';
            _device = null;
            _txCharacteristic = null;
            _rxCharacteristic = null;
          });
        }
      });
    } catch (e) {
      setState(() => _status = 'Connection failed');
      _showError(e.toString());
    } finally {
      setState(() => _connecting = false);
    }
  }

  Future<void> _connectLastDevice() async {
    if (_lastDeviceAddress == null) {
      _showError('No last device saved');
      return;
    }
    // Ищем устройство в списке
    final device = _devices.firstWhere(
      (d) => d.remoteId.toString() == _lastDeviceAddress,
      orElse: () => throw 'Device not found',
    );
    await _connectToDevice(device);
  }

  void _disconnect() async {
    await _device?.disconnect();
    setState(() {
      _device = null;
      _txCharacteristic = null;
      _rxCharacteristic = null;
      _status = 'Disconnected';
    });
  }

  void _send(String data) async {
    if (_txCharacteristic == null) {
      _showError('Not connected');
      return;
    }
    await _txCharacteristic!.write(utf8.encode(data));
    setState(() => _log.add('→ $data'));
  }

  // ---------------- Управление кнопками ----------------
  Future<void> _loadButtons() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = prefs.getString(_buttonsPrefsKey);
    if (jsonStr != null) {
      final list = jsonDecode(jsonStr) as List;
      setState(() {
        _buttons = list.map((e) => ButtonConfig.fromJson(e)).toList();
      });
    }
  }

  Future<void> _saveButtons() async {
    final prefs = await SharedPreferences.getInstance();
    final jsonStr = jsonEncode(_buttons.map((b) => b.toJson()).toList());
    await prefs.setString(_buttonsPrefsKey, jsonStr);
  }

  void _addButton() => _showButtonEditor(null);

  void _editButton(ButtonConfig btn) => _showButtonEditor(btn);

  void _deleteButton(ButtonConfig btn) {
    setState(() => _buttons.remove(btn));
    _saveButtons();
  }

  // ---------------- Last device persistence ----------------
  Future<void> _loadLastDevice() async {
    final prefs = await SharedPreferences.getInstance();
    _lastDeviceAddress = prefs.getString('last_device');
  }

  Future<void> _saveLastDevice() async {
    if (_lastDeviceAddress == null) return;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString('last_device', _lastDeviceAddress!);
  }

  void _showError(String msg) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
  }

  // ---------------- Диалог редактирования кнопки ----------------
  void _showButtonEditor(ButtonConfig? existing) {
    final id = existing?.id ?? DateTime.now().millisecondsSinceEpoch.toString();
    final labelCtrl = TextEditingController(text: existing?.label ?? '');
    final valueCtrl = TextEditingController(text: existing?.value ?? '');
    final offValueCtrl = TextEditingController(text: existing?.offValue ?? '');
    ButtonMode mode = existing?.mode ?? ButtonMode.normal;
    Color color = existing?.color ?? Colors.teal;
    int repeatDelay = existing?.repeatDelayMs ?? 500;
    int repeatCount = existing?.repeatCount ?? 0;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'New button' : 'Edit button'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: labelCtrl, decoration: InputDecoration(labelText: 'Label')),
                SizedBox(height: 8),
                TextField(controller: valueCtrl, decoration: InputDecoration(labelText: 'Value')),
                SizedBox(height: 8),
                DropdownButtonFormField<ButtonMode>(
                  value: mode,
                  decoration: InputDecoration(labelText: 'Mode'),
                  items: ButtonMode.values
                      .map((m) => DropdownMenuItem(value: m, child: Text(m.name)))
                      .toList(),
                  onChanged: (v) => setDialogState(() => mode = v!),
                ),
                if (mode == ButtonMode.toggle) ...[
                  SizedBox(height: 8),
                  TextField(
                      controller: offValueCtrl,
                      decoration: InputDecoration(labelText: 'Off value')),
                ],
                if (mode == ButtonMode.hold) ...[
                  SizedBox(height: 8),
                  TextField(
                    decoration: InputDecoration(labelText: 'Repeat delay (ms)'),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => repeatDelay = int.tryParse(v) ?? 500,
                    controller: TextEditingController(text: repeatDelay.toString()),
                  ),
                  SizedBox(height: 8),
                  TextField(
                    decoration: InputDecoration(labelText: 'Repeat count (0=infinite)'),
                    keyboardType: TextInputType.number,
                    onChanged: (v) => repeatCount = int.tryParse(v) ?? 0,
                    controller: TextEditingController(text: repeatCount.toString()),
                  ),
                ],
                SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: Colors.primaries.map((c) => GestureDetector(
                    onTap: () => setDialogState(() => color = c),
                    child: Container(
                      width: 32, height: 32,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: color == c ? Border.all(color: Colors.white, width: 2) : null,
                      ),
                    ),
                  )).toList(),
                ),
              ],
            ),
          ),
          actions: [
            if (existing != null)
              TextButton(
                onPressed: () {
                  _deleteButton(existing);
                  Navigator.pop(ctx);
                },
                child: Text('Delete', style: TextStyle(color: Colors.red)),
              ),
            TextButton(onPressed: () => Navigator.pop(ctx), child: Text('Cancel')),
            ElevatedButton(
              onPressed: () {
                final newBtn = ButtonConfig(
                  id: id,
                  label: labelCtrl.text,
                  value: valueCtrl.text,
                  offValue: mode == ButtonMode.toggle ? offValueCtrl.text : null,
                  color: color,
                  mode: mode,
                  repeatDelayMs: repeatDelay,
                  repeatCount: repeatCount,
                );
                setState(() {
                  final idx = _buttons.indexWhere((b) => b.id == id);
                  if (idx >= 0) {
                    _buttons[idx] = newBtn;
                  } else {
                    _buttons.add(newBtn);
                  }
                });
                _saveButtons();
                Navigator.pop(ctx);
              },
              child: Text('Save'),
            ),
          ],
        ),
      ),
    );
  }

  // ---------------- Терминал (Bottom Sheet) ----------------
  void _openTerminal() {
    showModalBottomSheet(
      context: context,
      isScrollControlled: true,
      backgroundColor: Colors.transparent,
      builder: (ctx) => DraggableScrollableSheet(
        initialChildSize: 0.4,
        minChildSize: 0.1,
        maxChildSize: 0.9,
        builder: (ctx, scrollCtrl) => Container(
          decoration: BoxDecoration(
            color: Theme.of(ctx).scaffoldBackgroundColor,
            borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
          ),
          child: Column(
            children: [
              Container(
                margin: EdgeInsets.symmetric(vertical: 8),
                width: 40,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey[600],
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              Expanded(
                child: ListView.builder(
                  controller: scrollCtrl,
                  itemCount: _log.length,
                  itemBuilder: (ctx, i) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
                    child: Text(_log[i], style: TextStyle(fontFamily: 'monospace')),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8.0),
                child: Row(
                  children: [
                    Expanded(
                      child: TextField(
                        decoration: InputDecoration(
                          hintText: 'Type command...',
                          border: OutlineInputBorder(),
                          contentPadding: EdgeInsets.symmetric(horizontal: 12),
                        ),
                        onSubmitted: (text) {
                          if (text.isNotEmpty) _send(text);
                        },
                      ),
                    ),
                    SizedBox(width: 8),
                    ElevatedButton(
                      onPressed: () {
                        // Пусто: отправка только по Enter в данном примере
                      },
                      child: Text('Send'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------- Построение кнопки действия ----------------
  Widget _buildActionButton(ButtonConfig btn) {
    final isHold = btn.mode == ButtonMode.hold;
    final isToggle = btn.mode == ButtonMode.toggle;
    final Color bgColor = isToggle && btn.toggleState ? btn.color.withOpacity(0.8) : btn.color;
    final Widget child = Container(
      width: double.infinity,
      padding: EdgeInsets.symmetric(vertical: 16),
      alignment: Alignment.center,
      child: Text(
        btn.label,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 16),
      ),
    );

    if (isHold) {
      Timer? _timer;
      int _sentCount = 0;
      return GestureDetector(
        onTapDown: (_) {
          if (_txCharacteristic == null) {
            _showError('Not connected');
            return;
          }
          _send(btn.value);
          _sentCount = 1;
          if (btn.repeatCount == 1 || btn.repeatDelayMs <= 0) return;
          _timer = Timer.periodic(Duration(milliseconds: btn.repeatDelayMs), (timer) {
            if (btn.repeatCount > 0 && _sentCount >= btn.repeatCount) {
              timer.cancel();
              return;
            }
            _send(btn.value);
            _sentCount++;
          });
        },
        onTapUp: (_) => _timer?.cancel(),
        onTapCancel: () => _timer?.cancel(),
        child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: bgColor.withOpacity(0.5), blurRadius: 8, offset: Offset(0, 4))],
          ),
          child: child,
        ),
      );
    } else if (isToggle) {
      return GestureDetector(
        onTap: () {
          if (_txCharacteristic == null) {
            _showError('Not connected');
            return;
          }
          setState(() => btn.toggleState = !btn.toggleState);
          _send(btn.toggleState ? btn.value : (btn.offValue ?? btn.value));
        },
        child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: btn.color.withOpacity(0.5), blurRadius: 8, offset: Offset(0, 4))],
          ),
          child: child,
        ),
      );
    } else {
      return GestureDetector(
        onTap: () {
          if (_txCharacteristic == null) {
            _showError('Not connected');
            return;
          }
          _send(btn.value);
        },
        child: Container(
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(12),
            boxShadow: [BoxShadow(color: btn.color.withOpacity(0.5), blurRadius: 8, offset: Offset(0, 4))],
          ),
          child: child,
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('BT Terminal'),
        leading: PopupMenuButton<BluetoothDevice>(
          icon: Icon(Icons.bluetooth),
          tooltip: 'Select device',
          onSelected: (device) => _connectToDevice(device),
          itemBuilder: (ctx) => _devices.map((d) => PopupMenuItem(
            value: d,
            child: Text(d.platformName.isEmpty ? d.remoteId.toString() : d.platformName),
          )).toList(),
        ),
        actions: [
          IconButton(
            icon: Icon(Icons.replay),
            tooltip: 'Connect last device',
            onPressed: _connectLastDevice,
          ),
          IconButton(
            icon: Icon(Icons.terminal),
            tooltip: 'Open terminal',
            onPressed: _openTerminal,
          ),
          if (_device != null)
            IconButton(
              icon: Icon(Icons.close, color: Colors.red),
              tooltip: 'Disconnect',
              onPressed: _disconnect,
            ),
        ],
        bottom: PreferredSize(
          preferredSize: Size.fromHeight(4),
          child: _connecting
              ? LinearProgressIndicator()
              : Container(height: 4, color: _device != null ? Colors.green : Colors.red),
        ),
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text(_status, style: TextStyle(fontSize: 12, color: Colors.grey)),
          ),
          Expanded(
            child: _buttons.isEmpty
                ? Center(child: Text('No buttons. Tap "+" to add.'))
                : GridView.builder(
                    padding: EdgeInsets.all(8),
                    gridDelegate: SliverGridDelegateWithMaxCrossAxisExtent(
                      maxCrossAxisExtent: 150,
                      crossAxisSpacing: 12,
                      mainAxisSpacing: 12,
                      childAspectRatio: 1.5,
                    ),
                    itemCount: _buttons.length,
                    itemBuilder: (ctx, i) => GestureDetector(
                      onLongPress: () => _editButton(_buttons[i]),
                      child: _buildActionButton(_buttons[i]),
                    ),
                  ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton(
        child: Icon(Icons.add),
        onPressed: _addButton,
      ),
    );
  }
}