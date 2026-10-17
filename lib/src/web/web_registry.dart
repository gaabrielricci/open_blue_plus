// State that must survive a Flutter hot restart.
//
// A hot restart re-runs the Dart program in the same page: the browser keeps
// the BluetoothDevice objects (and their connections, notifications and
// advertisement watches) alive, with the listeners of the previous run still
// attached. Everything this plugin attaches is therefore tracked on `window`,
// so the new run can detach it and adopt the devices.
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import 'web_bluetooth.dart';

JSObject get _root {
  final w = web.window as JSObject;
  final existing = w['__openBluePlus'];
  if (existing != null) return existing as JSObject;
  final root = JSObject();
  root['targets'] = _newSet();
  root['devices'] = (globalContext['Map'] as JSFunction).callAsConstructor();
  w['__openBluePlus'] = root;
  return root;
}

JSObject _newSet() => (globalContext['Set'] as JSFunction).callAsConstructor();

List<T> _values<T extends JSAny>(JSObject iterable) =>
    ((globalContext['Array'] as JSObject).callMethod<JSArray<T>>(
            'from'.toJS, iterable.callMethod('values'.toJS)))
        .toDart;

String _slot(String type) => '__fbpo_$type';

/// Adds [listener] for [type] on [target], replacing the one this plugin
/// added before (in this run or a previous one): at most one per type.
void listen(web.EventTarget target, String type, JSFunction listener) {
  final t = target as JSObject;
  final old = t[_slot(type)];
  if (old != null) target.removeEventListener(type, old as JSFunction);
  t[_slot(type)] = listener;
  target.addEventListener(type, listener);
  (_root['targets'] as JSObject).callMethod('add'.toJS, target);
}

/// Removes the listener for [type] on [target]; with [only], just when it is
/// still that one.
void unlisten(web.EventTarget target, String type, [JSFunction? only]) {
  final t = target as JSObject;
  final old = t[_slot(type)];
  if (old == null) return;
  if (only != null && !old.strictEquals(only).toDart) return;
  target.removeEventListener(type, old as JSFunction);
  t.delete(_slot(type).toJS);
  if (_slots(t).isEmpty) {
    (_root['targets'] as JSObject).callMethod('delete'.toJS, target);
  }
}

Iterable<JSString> _slots(JSObject target) =>
    (globalContext['Object'] as JSObject)
        .callMethod<JSArray<JSString>>('keys'.toJS, target)
        .toDart
        .where((k) => k.toDart.startsWith('__fbpo_'));

/// Detaches every listener added by any previous run.
void unlistenAll() {
  final targets = _root['targets'] as JSObject;
  for (final target in _values<JSObject>(targets)) {
    for (final k in _slots(target).toList()) {
      final key = k.toDart;
      (target as web.EventTarget).removeEventListener(
          key.substring('__fbpo_'.length), target[key] as JSFunction);
      target.delete(k);
    }
  }
  _root['targets'] = _newSet();
}

/// Devices handed out by the browser in this page, by id.
void rememberDevice(BluetoothDevice device) => (_root['devices'] as JSObject)
    .callMethod('set'.toJS, device.id.toJS, device);

List<BluetoothDevice> rememberedDevices() =>
    _values<BluetoothDevice>(_root['devices'] as JSObject);

/// The advertisement watch of the running scan, if any.
web.AbortController? get scanAbort =>
    _root['scanAbort'] as web.AbortController?;

set scanAbort(web.AbortController? abort) => _root['scanAbort'] = abort;
