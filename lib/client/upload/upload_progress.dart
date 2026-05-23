// lib/server/upload/upload_progress.dart

/// Snapshot of an in-progress upload.
class UploadProgress {
  const UploadProgress({
    required this.sent,
    required this.total,
  });

  const UploadProgress.idle()
      : sent = 0,
        total = 0;

  const UploadProgress.done(int bytes)
      : sent = bytes,
        total = bytes;

  final int sent;
  final int total;

  /// 0.0 → 1.0 progress ratio. Returns 0 if total is unknown.
  double get percent => total > 0 ? sent / total : 0.0;

  /// True when the upload has completed (sent == total and total > 0).
  bool get isDone => total > 0 && sent >= total;

  /// Megabytes sent.
  double get sentMB => sent / 1024 / 1024;

  /// Total megabytes.
  double get totalMB => total / 1024 / 1024;

  @override
  String toString() =>
      'UploadProgress(${(percent * 100).toStringAsFixed(1)}% — ${sentMB.toStringAsFixed(2)}/${totalMB.toStringAsFixed(2)} MB)';
}
