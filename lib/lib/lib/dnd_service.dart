import 'package:flutter/services.dart';

class DndService {
  static const _ch = MethodChannel('factory_shift/dnd');

  static Future<bool> hasPermission() async {
    try {
      return await _ch.invokeMethod<bool>('hasPermission') ?? false;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openSettings() async {
    try {
      await _ch.invokeMethod('openSettings');
    } catch (_) {}
  }

  static Future<bool> setDnd(bool on) async {
    try {
      return await _ch.invokeMethod<bool>('setDnd', {'on': on}) ?? false;
    } catch (_) {
      return false;
    }
  }
}
