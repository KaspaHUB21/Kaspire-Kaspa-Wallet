class DiagnosticCheck {
  const DiagnosticCheck({
    required this.name,
    required this.endpoint,
    required this.ok,
    required this.detail,
    required this.elapsedMs,
  });

  final String name;
  final String endpoint;
  final bool ok;
  final String detail;
  final int elapsedMs;
}
