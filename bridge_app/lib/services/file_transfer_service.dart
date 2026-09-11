import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_background_service/flutter_background_service.dart';
import 'package:uuid/uuid.dart';

import 'socket_service.dart';
import 'pairing_storage_service.dart';

const _filesChannel = MethodChannel('bridge/files');
const _chunkSize = 65536; // 64 KB
const _uuid = Uuid();

// ── Progress models ───────────────────────────────────────────────────────────

class FileSendProgress {
  final String transferId;
  final String fileName;
  final int bytesSent;
  final int totalBytes;
  final bool done;
  final String? error;

  const FileSendProgress({
    required this.transferId,
    required this.fileName,
    required this.bytesSent,
    required this.totalBytes,
    required this.done,
    this.error,
  });

  double get fraction => totalBytes > 0 ? bytesSent / totalBytes : 0.0;

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'fileName': fileName,
    'bytesSent': bytesSent,
    'totalBytes': totalBytes,
    'done': done,
    'error': error,
  };

  factory FileSendProgress.fromJson(Map<String, dynamic> json) => FileSendProgress(
    transferId: json['transferId'] as String? ?? '',
    fileName: json['fileName'] as String? ?? 'file',
    bytesSent: json['bytesSent'] as int? ?? 0,
    totalBytes: json['totalBytes'] as int? ?? 0,
    done: json['done'] as bool? ?? false,
    error: json['error'] as String?,
  );
}

class FileReceiveProgress {
  final String transferId;
  final String fileName;
  final int bytesReceived;
  final int totalBytes;
  final bool done;
  final bool error;

  const FileReceiveProgress({
    required this.transferId,
    required this.fileName,
    required this.bytesReceived,
    required this.totalBytes,
    required this.done,
    this.error = false,
  });

  double get fraction => totalBytes > 0 ? bytesReceived / totalBytes : 0.0;

  Map<String, dynamic> toJson() => {
    'transferId': transferId,
    'fileName': fileName,
    'bytesReceived': bytesReceived,
    'totalBytes': totalBytes,
    'done': done,
    'error': error,
  };

  factory FileReceiveProgress.fromJson(Map<String, dynamic> json) => FileReceiveProgress(
    transferId: json['transferId'] as String? ?? '',
    fileName: json['fileName'] as String? ?? 'file',
    bytesReceived: json['bytesReceived'] as int? ?? 0,
    totalBytes: json['totalBytes'] as int? ?? 0,
    done: json['done'] as bool? ?? false,
    error: json['error'] as bool? ?? false,
  );
}

// ── Helper sink for incremental SHA-256 calculation ─────────────────────────

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) {
    value = data;
  }

  @override
  void close() {}
}

// ── Receive state ─────────────────────────────────────────────────────────────

class _ReceiveState {
  final String token;
  final String fileName;
  final int totalChunks;
  final int totalBytes;
  final _DigestSink _digestSink = _DigestSink();
  late final ByteConversionSink _hashSink;
  final Completer<bool> initCompleter = Completer<bool>();
  Future<void> _writeQueue = Future.value();
  int chunksReceived = 0;
  int bytesReceived = 0;

  _ReceiveState({
    required this.token,
    required this.fileName,
    required this.totalChunks,
    required this.totalBytes,
  }) {
    _hashSink = sha256.startChunkedConversion(_digestSink);
  }

  void addBytes(Uint8List bytes) {
    _hashSink.add(bytes);
  }

  void queueWrite(Future<void> Function() writeAction) {
    _writeQueue = _writeQueue.then((_) => writeAction()).catchError((e) {
      debugPrint('[_ReceiveState] write error: $e');
    });
  }

  Future<void> waitForWrites() async {
    await _writeQueue;
  }

  /// Returns the final hex digest. Call only after all chunks have been added.
  String finalizeDigest() {
    _hashSink.close();
    return _digestSink.value?.toString() ?? '';
  }
}

// ── Service ───────────────────────────────────────────────────────────────────

class FileTransferService {
  FileTransferService._();
  static final instance = FileTransferService._();

  static ValueNotifier<FileSendProgress?> get sendProgress => instance._sendProgress;
  static ValueNotifier<FileReceiveProgress?> get receiveProgress => instance._receiveProgress;

  static void init({
    bool isBackgroundService = false,
    void Function(FileReceiveProgress)? onReceiveProgress,
    void Function(String fileName, String pcName)? onFileReceived,
  }) =>
      instance._init(
        isBackgroundService: isBackgroundService,
        onReceiveProgress: onReceiveProgress,
        onFileReceived: onFileReceived,
      );

  static Future<void> sendFiles(
    List<String> paths, {
    void Function(FileSendProgress)? onSendProgress,
  }) =>
      instance._sendFiles(paths, onSendProgress: onSendProgress);

  static Future<void> sendFile(
    String sourcePath, {
    void Function(FileSendProgress)? onSendProgress,
  }) =>
      instance._sendFile(sourcePath, onSendProgress: onSendProgress);

  final ValueNotifier<FileSendProgress?> _sendProgress = ValueNotifier(null);
  final ValueNotifier<FileReceiveProgress?> _receiveProgress = ValueNotifier(null);

  final _receives = <String, _ReceiveState>{};
  bool _isBackground = false;
  void Function(FileReceiveProgress)? _onReceiveProgress;
  void Function(String fileName, String pcName)? _onFileReceived;

  void _init({
    bool isBackgroundService = false,
    void Function(FileReceiveProgress)? onReceiveProgress,
    void Function(String fileName, String pcName)? onFileReceived,
  }) {
    _isBackground = isBackgroundService;
    _onReceiveProgress = onReceiveProgress;
    _onFileReceived = onFileReceived;

    if (isBackgroundService) {
      SocketService.instance.onFileMessage(_handleIncoming);
    } else {
      // In UI isolate: subscribe to cross-isolate events from FlutterBackgroundService
      final service = FlutterBackgroundService();
      service.on('file_receive_progress').listen((event) {
        if (event == null) return;
        final progress = FileReceiveProgress.fromJson(Map<String, dynamic>.from(event));
        _receiveProgress.value = progress;
        if (progress.done) {
          Future.delayed(const Duration(seconds: 4), () {
            if (_receiveProgress.value?.transferId == progress.transferId) {
              _receiveProgress.value = null;
            }
          });
        }
      });

      service.on('file_send_progress').listen((event) {
        if (event == null) return;
        final progress = FileSendProgress.fromJson(Map<String, dynamic>.from(event));
        _sendProgress.value = progress;
        if (progress.done) {
          Future.delayed(const Duration(seconds: 4), () {
            if (_sendProgress.value?.transferId == progress.transferId) {
              _sendProgress.value = null;
            }
          });
        }
      });
    }
  }

  // ── Android → Windows: send one or more files ─────────────────────────────

  Future<void> _sendFiles(
    List<String> paths, {
    void Function(FileSendProgress)? onSendProgress,
  }) async {
    if (!_isBackground) {
      // In UI isolate: delegate to background service isolate
      FlutterBackgroundService().invoke('send_files', {'paths': paths});
      return;
    }

    for (final path in paths) {
      await _sendFile(path, onSendProgress: onSendProgress);
    }
  }

  /// Sends a file to Windows. [sourcePath] is either:
  /// - A content:// URI (from share sheet — streams via platform channel)
  /// - A file:// path or raw file path (from in-app file picker — reads via dart:io)
  Future<void> _sendFile(
    String sourcePath, {
    void Function(FileSendProgress)? onSendProgress,
  }) async {
    if (!_isBackground) {
      FlutterBackgroundService().invoke('send_files', {'paths': [sourcePath]});
      return;
    }

    final pairing = await PairingStorageService.instance.getPairing();
    if (pairing == null) throw Exception('Not paired');

    await SocketService.instance.ensureConnected();

    final bool isContentUri = sourcePath.startsWith('content://');
    final transferId = _uuid.v4();

    String fileName;
    String mimeType;
    int totalBytes;

    void notifyProgress(FileSendProgress p) {
      _sendProgress.value = p;
      onSendProgress?.call(p);
    }

    if (isContentUri) {
      // Content URI: use platform channel to open and stream
      final token = _uuid.v4();
      final meta = await _filesChannel.invokeMapMethod<String, dynamic>(
        'openContentUri',
        {'uri': sourcePath, 'token': token},
      );
      fileName = (meta?['fileName'] as String?) ?? 'file';
      mimeType = (meta?['mimeType'] as String?) ?? 'application/octet-stream';
      totalBytes = (meta?['totalBytes'] as int?) ?? -1;
      final totalChunks = totalBytes > 0 ? (totalBytes / _chunkSize).ceil() : -1;

      _emit({
        'event': 'file-meta',
        'transferId': transferId,
        'fileName': fileName,
        'mimeType': mimeType,
        'totalBytes': totalBytes,
        'totalChunks': totalChunks,
      });

      // Stream via platform channel with incremental hash
      int index = 0;
      int bytesSent = 0;
      final digestSink = _DigestSink();
      final hashSink = sha256.startChunkedConversion(digestSink);

      while (true) {
        final chunk = await _filesChannel.invokeMethod<Uint8List>(
          'readChunk',
          {'token': token},
        );
        if (chunk == null || chunk.isEmpty) break;
        hashSink.add(chunk);
        _emit({
          'event': 'file-chunk',
          'transferId': transferId,
          'index': index,
          'data': base64Encode(chunk),
        });
        bytesSent += chunk.length;
        index++;
        notifyProgress(FileSendProgress(
          transferId: transferId,
          fileName: fileName,
          bytesSent: bytesSent,
          totalBytes: totalBytes,
          done: false,
        ));
      }
      await _filesChannel.invokeMethod('closeInputStream', {'token': token});
      hashSink.close();
      final digest = digestSink.value?.toString() ?? '';
      _emit({'event': 'file-complete', 'transferId': transferId, 'sha256': digest});
      notifyProgress(FileSendProgress(
        transferId: transferId,
        fileName: fileName,
        bytesSent: bytesSent,
        totalBytes: totalBytes,
        done: true,
      ));
    } else {
      // Regular file path from file_picker — stream via dart:io
      final file = File(sourcePath);
      fileName = sourcePath.split(Platform.pathSeparator).last;
      totalBytes = await file.length();
      mimeType = 'application/octet-stream';
      final totalChunks = (totalBytes / _chunkSize).ceil();

      _emit({
        'event': 'file-meta',
        'transferId': transferId,
        'fileName': fileName,
        'mimeType': mimeType,
        'totalBytes': totalBytes,
        'totalChunks': totalChunks,
      });

      int index = 0;
      int bytesSent = 0;
      final digestSink = _DigestSink();
      final hashSink = sha256.startChunkedConversion(digestSink);

      final stream = file.openRead();
      await for (final chunk in stream) {
        final bytes = Uint8List.fromList(chunk);
        hashSink.add(bytes);
        _emit({
          'event': 'file-chunk',
          'transferId': transferId,
          'index': index,
          'data': base64Encode(bytes),
        });
        bytesSent += bytes.length;
        index++;
        notifyProgress(FileSendProgress(
          transferId: transferId,
          fileName: fileName,
          bytesSent: bytesSent,
          totalBytes: totalBytes,
          done: false,
        ));
      }
      hashSink.close();
      final digest = digestSink.value?.toString() ?? '';
      _emit({'event': 'file-complete', 'transferId': transferId, 'sha256': digest});
      notifyProgress(FileSendProgress(
        transferId: transferId,
        fileName: fileName,
        bytesSent: bytesSent,
        totalBytes: totalBytes,
        done: true,
      ));
    }
  }

  // ── Windows → Android: receive a file ─────────────────────────────────────

  void _handleIncoming(Map<String, dynamic> payload) {
    final event = payload['event'] as String?;
    switch (event) {
      case 'file-meta':
        _onMeta(payload);
        break;
      case 'file-chunk':
        _onChunk(payload);
        break;
      case 'file-complete':
        _onComplete(payload);
        break;
    }
  }

  void _onMeta(Map<String, dynamic> p) async {
    final transferId = p['transferId'] as String;
    final fileName = p['fileName'] as String;
    final mimeType = p['mimeType'] as String? ?? 'application/octet-stream';
    final totalChunks = p['totalChunks'] as int? ?? -1;
    final totalBytes = p['totalBytes'] as int? ?? -1;
    final token = _uuid.v4();

    debugPrint('[FileTransferService] Receiving "$fileName" ($totalBytes bytes, $totalChunks chunks)...');

    final state = _ReceiveState(
      token: token,
      fileName: fileName,
      totalChunks: totalChunks,
      totalBytes: totalBytes,
    );

    // CRITICAL: Register state synchronously before ANY await, so chunks that arrive immediately are not lost
    _receives[transferId] = state;

    final prog = FileReceiveProgress(
      transferId: transferId,
      fileName: fileName,
      bytesReceived: 0,
      totalBytes: totalBytes,
      done: false,
    );
    _receiveProgress.value = prog;
    _onReceiveProgress?.call(prog);

    try {
      await _filesChannel.invokeMethod('createDownload', {
        'fileName': fileName,
        'mimeType': mimeType,
        'token': token,
      });
      state.initCompleter.complete(true);
    } catch (e) {
      debugPrint('[FileTransferService] createDownload error: $e');
      state.initCompleter.complete(false);
    }
  }

  void _onChunk(Map<String, dynamic> p) {
    final transferId = p['transferId'] as String;
    final state = _receives[transferId];
    if (state == null) {
      debugPrint('[FileTransferService] Received chunk for uninitialized transferId $transferId');
      return;
    }

    final rawBytes = base64Decode(p['data'] as String);
    state.addBytes(rawBytes); // incremental hash update immediately
    state.bytesReceived += rawBytes.length;
    state.chunksReceived++;

    final prog = FileReceiveProgress(
      transferId: transferId,
      fileName: state.fileName,
      bytesReceived: state.bytesReceived,
      totalBytes: state.totalBytes,
      done: false,
    );
    _receiveProgress.value = prog;
    _onReceiveProgress?.call(prog);

    state.queueWrite(() async {
      final ready = await state.initCompleter.future;
      if (!ready) return;
      try {
        await _filesChannel.invokeMethod('writeChunk', {
          'token': state.token,
          'data': rawBytes,
        });
      } catch (e) {
        debugPrint('[FileTransferService] writeChunk error: $e');
      }
    });
  }

  void _onComplete(Map<String, dynamic> p) async {
    final transferId = p['transferId'] as String;
    final expected = p['sha256'] as String;
    final state = _receives[transferId];
    if (state == null) return;

    // Ensure createDownload and all queued writeChunk calls have completed
    final ready = await state.initCompleter.future;
    await state.waitForWrites();

    _receives.remove(transferId);

    if (!ready) {
      debugPrint('[FileTransferService] Download init failed for "${state.fileName}"');
      final prog = FileReceiveProgress(
        transferId: transferId,
        fileName: state.fileName,
        bytesReceived: state.bytesReceived,
        totalBytes: state.totalBytes,
        done: true,
        error: true,
      );
      _receiveProgress.value = prog;
      _onReceiveProgress?.call(prog);
      return;
    }

    final computed = state.finalizeDigest();

    if (computed == expected) {
      debugPrint('[FileTransferService] Download complete for "${state.fileName}" (SHA-256 verified ✓)');
      try {
        await _filesChannel.invokeMethod('finalizeDownload', {'token': state.token});
      } catch (e) {
        debugPrint('[FileTransferService] finalizeDownload error: $e');
      }
      final prog = FileReceiveProgress(
        transferId: transferId,
        fileName: state.fileName,
        bytesReceived: state.bytesReceived,
        totalBytes: state.totalBytes,
        done: true,
      );
      _receiveProgress.value = prog;
      _onReceiveProgress?.call(prog);

      // Trigger completion notification in background service
      _onFileReceived?.call(state.fileName, 'Windows PC');
    } else {
      debugPrint('[FileTransferService] Checksum mismatch for "${state.fileName}"! Expected: $expected, Computed: $computed. Deleting.');
      try {
        await _filesChannel.invokeMethod('deleteDownload', {'token': state.token});
      } catch (e) {
        debugPrint('[FileTransferService] deleteDownload error: $e');
      }
      final prog = FileReceiveProgress(
        transferId: transferId,
        fileName: state.fileName,
        bytesReceived: state.bytesReceived,
        totalBytes: state.totalBytes,
        done: true,
        error: true,
      );
      _receiveProgress.value = prog;
      _onReceiveProgress?.call(prog);
    }
  }

  void _emit(Map<String, dynamic> payload) {
    SocketService.instance.emitFileMessage(payload);
  }
}
