import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

class WindowsSingleInstance {
  static const MethodChannel _channel = MethodChannel('windows_single_instance');
  static const _kOpenPipeTimeout = Duration(seconds: 5);
  static const _kReadBufferSize = 4096;
  static const _kWaitSliceMS = 1000;
  static const _kReadTimeoutMS = 1000;

  static final _waitNamedPipe = DynamicLibrary.open('kernel32.dll').lookupFunction<Int32 Function(Pointer<Utf16>, Uint32), int Function(Pointer<Utf16>, int)>('WaitNamedPipeW');

  WindowsSingleInstance._();

  static HANDLE? _openPipe(String filename) {
    final cPipe = filename.toPcwstr();
    try {
      final timeoutMS = _kOpenPipeTimeout.inMilliseconds;
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsedMilliseconds < timeoutMS) {
        final Win32Result(:value, :error) = CreateFile(
          cPipe,
          GENERIC_WRITE,
          FILE_SHARE_NONE,
          null,
          OPEN_EXISTING,
          FILE_ATTRIBUTE_NORMAL,
          null,
        );
        if (value != INVALID_HANDLE_VALUE) return value;

        if (error == ERROR_PIPE_BUSY) {
          final remainingMS = timeoutMS - stopwatch.elapsedMilliseconds;
          final waitMS = remainingMS.clamp(1, timeoutMS);
          _waitNamedPipe(cPipe, waitMS);
        } else if (error == ERROR_FILE_NOT_FOUND) {
          // -- first instance didn't create the pipe yet
          sleep(const Duration(milliseconds: 20));
        } else {
          return null;
        }
      }
      return null;
    } finally {
      free(cPipe);
    }
  }

  static HANDLE _createPipe(String filename) {
    final cPipe = filename.toPcwstr();
    try {
      return CreateNamedPipe(
        cPipe,
        FILE_FLAGS_AND_ATTRIBUTES(
          PIPE_ACCESS_INBOUND | FILE_FLAG_FIRST_PIPE_INSTANCE | FILE_FLAG_OVERLAPPED,
        ),
        NAMED_PIPE_MODE(
          PIPE_TYPE_MESSAGE | PIPE_READMODE_MESSAGE | PIPE_WAIT,
        ),
        PIPE_UNLIMITED_INSTANCES,
        4096,
        4096,
        0,
        null,
      );
    } finally {
      free(cPipe);
    }
  }

  static void _readPipe(SendPort writer, HANDLE pipeHandle) {
    final overlap = calloc<OVERLAPPED>();
    final Win32Result(value: event) = CreateEvent(null, true, false, null);
    overlap.ref.hEvent = event;
    final numTransferred = calloc<Uint32>();
    final buffer = calloc<Uint8>(_kReadBufferSize);
    try {
      while (true) {
        final Win32Result(value: didConnect, :error) = ConnectNamedPipe(pipeHandle, overlap);
        if (error == ERROR_INVALID_HANDLE) return;

        final isPending = !didConnect && error == ERROR_IO_PENDING;
        // -- other results can still have a client that connected or already wrote
        final isConnected = isPending ? _waitOverlapped(pipeHandle, overlap, numTransferred).value : true;
        final message = isConnected ? _readMessage(pipeHandle, overlap, buffer, numTransferred) : null;
        if (message != null) {
          try {
            writer.send(jsonDecode(message));
          } catch (error) {
            stderr.writeln("[MultiInstanceHandler]: ERROR: $error");
          }
        } else if (!isPending) {
          // -- no busy loop if connecting keeps failing
          sleep(const Duration(milliseconds: 50));
        }
        DisconnectNamedPipe(pipeHandle);
      }
    } finally {
      CloseHandle(event);
      free(buffer);
      free(numTransferred);
      free(overlap);
    }
  }

  static String? _readMessage(HANDLE pipeHandle, Pointer<OVERLAPPED> overlap, Pointer<Uint8> buffer, Pointer<Uint32> numTransferred) {
    final bytes = BytesBuilder();
    while (true) {
      final Win32Result(value: didStartRead, error: startError) = ReadFile(pipeHandle, buffer, _kReadBufferSize, null, overlap);
      if (!didStartRead && startError != ERROR_IO_PENDING && startError != ERROR_MORE_DATA) return null;

      final Win32Result(value: didRead, :error) = _waitOverlapped(pipeHandle, overlap, numTransferred, timeoutMS: _kReadTimeoutMS);
      if (!didRead && error != ERROR_MORE_DATA) return null;

      bytes.add(buffer.asTypedList(numTransferred.value));
      if (didRead) return utf8.decode(bytes.takeBytes());
    }
  }

  // -- waits in slices so the isolate can still be killed (hot restart, shutdown)
  static Win32Result<bool> _waitOverlapped(HANDLE pipeHandle, Pointer<OVERLAPPED> overlap, Pointer<Uint32> numTransferred, {int? timeoutMS}) {
    final event = overlap.ref.hEvent;
    final waitMS = timeoutMS ?? _kWaitSliceMS;
    while (WaitForSingleObject(event, waitMS).value == WAIT_TIMEOUT) {
      if (timeoutMS != null) {
        CancelIoEx(pipeHandle, overlap);
        return GetOverlappedResult(pipeHandle, overlap, numTransferred, true);
      }
    }
    return GetOverlappedResult(pipeHandle, overlap, numTransferred, false);
  }

  static void _writePipeData(String filename, List<String>? arguments) {
    final pipe = _openPipe(filename);
    if (pipe == null) return;
    final bytesString = jsonEncode(arguments ?? []);
    final bytes = bytesString.toNativeUtf8();
    final numWritten = malloc<Uint32>();
    try {
      WriteFile(pipe, bytes.cast<Uint8>(), bytes.length, numWritten, null);
    } finally {
      free(numWritten);
      free(bytes);
      CloseHandle(pipe);
    }
  }

  static void _startReadPipeIsolate(Map args) {
    final pipe = _createPipe(args["pipe"] as String);
    if (pipe == INVALID_HANDLE_VALUE) {
      print("Pipe create failed");
      return;
    }
    _readPipe(args["port"] as SendPort, pipe);
  }

  /// Checks that the current window is unique, and exits the app if not.
  ///
  /// __Arguments__\
  /// `arguments`: List of strings that will be passed to the callback function of the open instance if this window is not unique\
  /// `pipeName`: A string unique to your app\
  /// `bringWindowToFront`: Should your active window become visible\
  /// `onSecondWindow`: Callback function that is called when a second window is attempted to be opened.
  /// `exitFunction`: An alternate function to exit the app, if not provided, the app will be exited using `exit(0)`.
  static Future ensureSingleInstance(
    List<String> arguments,
    String pipeName, {
    Function(List<String>)? onSecondWindow,
    bool bringWindowToFront = true,
    Future<void> Function()? exitFunction,
  }) async {
    if (!Platform.isWindows) return;
    final fullPipeName = "\\\\.\\pipe\\$pipeName";
    final bool isSingleInstance = await _channel.invokeMethod('isSingleInstance', <String, Object>{
      "pipe": pipeName,
    });
    if (!isSingleInstance) {
      _writePipeData(fullPipeName, arguments);
      await (exitFunction?.call() ?? Future.value(exit(0)));
      return;
    }

    // No callback so don't bother starting pipe
    if (onSecondWindow == null && bringWindowToFront == false) {
      return;
    }

    final reader = ReceivePort()
      ..listen((dynamic msg) {
        if (msg is List) {
          if (onSecondWindow != null) {
            onSecondWindow(msg.map((o) => o.toString()).toList());
          }
          if (bringWindowToFront) _bringWindowToFront();
        }
      });
    await Isolate.spawn(_startReadPipeIsolate, {"port": reader.sendPort, "pipe": fullPipeName});
  }

  static void _bringWindowToFront() {
    _channel.invokeMethod('bringToFront');
  }
}
