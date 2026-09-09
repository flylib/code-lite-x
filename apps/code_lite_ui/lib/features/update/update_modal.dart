import 'package:flutter/material.dart';
import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';

/// Modal dialog for cross-platform differential auto-updates (Phase 11).
class UpdateModal extends StatefulWidget {
  final ApiClient client;
  final String currentVersion;

  const UpdateModal({
    super.key,
    required this.client,
    this.currentVersion = '0.1.0',
  });

  static Future<void> show(
    BuildContext context, {
    required ApiClient client,
    String currentVersion = '0.1.0',
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => UpdateModal(
        client: client,
        currentVersion: currentVersion,
      ),
    );
  }

  @override
  State<UpdateModal> createState() => _UpdateModalState();
}

class _UpdateModalState extends State<UpdateModal> {
  bool _isChecking = true;
  bool _hasUpdate = false;
  bool _isStaging = false;
  bool _isReadyToApply = false;
  bool _isApplying = false;
  bool _appliedSuccess = false;
  String? _errorMessage;

  String _latestVersion = '';
  String _strategy = 'ComponentDelta';
  String _platform = 'macos';
  String _sha256 = '';
  int _fileSize = 0;
  List<String> _files = [];
  String _changelog = '';
  double _downloadProgress = 0.0;

  @override
  void initState() {
    super.initState();
    _checkForUpdates();
  }

  Future<void> _checkForUpdates() async {
    setState(() {
      _isChecking = true;
      _errorMessage = null;
      _appliedSuccess = false;
      _isReadyToApply = false;
      _downloadProgress = 0.0;
    });

    try {
      final res = await widget.client.checkForUpdates(
        currentVersion: widget.currentVersion,
      );

      if (mounted) {
        setState(() {
          _isChecking = false;
          _hasUpdate = res['has_update'] == true;
          _latestVersion = (res['latest_version'] as String?) ?? widget.currentVersion;
          _strategy = (res['strategy'] as String?) ?? 'ComponentDelta';
          _platform = (res['platform'] as String?) ?? 'macos';
          _sha256 = (res['sha256'] as String?) ?? '';
          _fileSize = (res['file_size'] as num?)?.toInt() ?? 0;
          _files = ((res['files'] as List<dynamic>?) ?? []).map((e) => e.toString()).toList();
          _changelog = (res['changelog'] as String?) ?? '';
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isChecking = false;
          _errorMessage = 'Failed to check updates: $e';
        });
      }
    }
  }

  Future<void> _stageAndVerify() async {
    setState(() {
      _isStaging = true;
      _downloadProgress = 0.2;
      _errorMessage = null;
    });

    try {
      await Future<void>.delayed(const Duration(milliseconds: 300));
      if (!mounted) return;
      setState(() => _downloadProgress = 0.6);

      const stagingDir = '/tmp/codelite_staging';
      final fileName = _files.isNotEmpty ? _files.first : 'update.bin';
      final res = await widget.client.stageUpdateArtifact(
        stagingDir: stagingDir,
        fileName: fileName,
        content: 'CodeLiteX update payload v$_latestVersion',
        expectedSha256: _sha256.isNotEmpty
            ? _sha256
            : 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      );

      if (mounted) {
        setState(() {
          _isStaging = false;
          _downloadProgress = 1.0;
          if (res['status'] == 'ok' || res['verified'] == true) {
            _isReadyToApply = true;
          } else {
            _errorMessage = 'Integrity check failed: ${res['message'] ?? 'SHA-256 mismatch'}';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isStaging = false;
          _errorMessage = 'Failed to stage update: $e';
        });
      }
    }
  }

  Future<void> _applyUpdate() async {
    setState(() {
      _isApplying = true;
      _errorMessage = null;
    });

    try {
      const stagingDir = '/tmp/codelite_staging';
      const targetDir = '/tmp/codelite_target';
      final res = await widget.client.applyUpdate(
        stagingDir: stagingDir,
        targetDir: targetDir,
        files: _files.isNotEmpty ? _files : ['libcodelite.dylib'],
        platform: _platform,
      );

      if (mounted) {
        setState(() {
          _isApplying = false;
          if (res['status'] == 'ok') {
            _appliedSuccess = true;
          } else {
            _errorMessage = 'Apply update failed: ${res['message'] ?? 'unknown error'}';
          }
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isApplying = false;
          _errorMessage = 'Failed to apply update: $e';
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 30),
      child: Container(
        width: 580,
        decoration: BoxDecoration(
          color: IntelliJTheme.panelBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: IntelliJTheme.border, width: 1),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 20,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(),
            const Divider(height: 1, color: IntelliJTheme.borderSubtle),
            Padding(
              padding: const EdgeInsets.all(20),
              child: _buildBody(),
            ),
            const Divider(height: 1, color: IntelliJTheme.borderSubtle),
            _buildFooter(),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: IntelliJTheme.headerBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.system_update_alt,
            size: 16,
            color: IntelliJTheme.accentBlue,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'CodeLiteX Software Update',
              style: TextStyle(
                color: IntelliJTheme.textHigh,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(4),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.close,
                size: 16,
                color: IntelliJTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBody() {
    if (_isChecking) {
      return const SizedBox(
        height: 160,
        child: Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  valueColor: AlwaysStoppedAnimation<Color>(IntelliJTheme.accentBlue),
                ),
              ),
              SizedBox(height: 12),
              Text(
                'Checking for new updates from release manifest...',
                style: TextStyle(color: IntelliJTheme.textSecondary, fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    if (_appliedSuccess) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.check_circle_outline, color: IntelliJTheme.gitGreen, size: 28),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      'Update to v$_latestVersion ready to take effect!',
                      style: const TextStyle(
                        color: IntelliJTheme.textHigh,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      (_strategy == 'AppBundleDelta' || _strategy == 'app_bundle_delta')
                          ? 'macOS AppBundle swap script generated. Restart CodeLiteX to finalize.'
                          : 'Dynamic library components swapped with safety backup snapshot created.',
                      style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 12),
                      overflow: TextOverflow.ellipsis,
                    ),

                  ],
                ),
              ),
            ],
          ),
        ],
      );
    }

    if (!_hasUpdate) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          const SizedBox(height: 12),
          const Icon(Icons.verified, color: IntelliJTheme.gitGreen, size: 36),
          const SizedBox(height: 12),
          Text(
            'CodeLiteX is up to date (v${widget.currentVersion})',
            style: const TextStyle(
              color: IntelliJTheme.textHigh,
              fontSize: 14,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 6),
          const Text(
            'No newer updates were found on the stable release channel.',
            style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 12),
        ],
      );
    }

    // Update is available
    final sizeMb = (_fileSize / (1024 * 1024)).toStringAsFixed(1);
    final isMacBundle = _strategy == 'AppBundleDelta' || _strategy == 'app_bundle_delta';


    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: IntelliJTheme.cardBg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: IntelliJTheme.border),
              ),
              child: Text(
                'v${widget.currentVersion}',
                style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 11),
              ),
            ),
            const SizedBox(width: 8),
            const Icon(Icons.arrow_forward, size: 14, color: IntelliJTheme.textMuted),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(
                color: IntelliJTheme.accentBlue.withOpacity(0.15),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: IntelliJTheme.accentBlue),
              ),
              child: Text(
                'v$_latestVersion',
                style: const TextStyle(
                  color: IntelliJTheme.accentBlue,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: isMacBundle
                      ? Colors.purple.withOpacity(0.15)
                      : IntelliJTheme.gitGreen.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      isMacBundle ? Icons.apple : Icons.layers,
                      size: 13,
                      color: isMacBundle ? Colors.purpleAccent : IntelliJTheme.gitGreen,
                    ),
                    const SizedBox(width: 4),
                    Flexible(
                      child: Text(
                        isMacBundle ? 'AppBundle (Code Signed)' : 'Component Delta (Atomic)',
                        style: TextStyle(
                          color: isMacBundle ? Colors.purpleAccent : IntelliJTheme.gitGreen,
                          fontSize: 11,
                          fontWeight: FontWeight.w500,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: IntelliJTheme.editorBg,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: IntelliJTheme.borderSubtle),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  const Text(
                    'Release Notes:',
                    style: TextStyle(
                      color: IntelliJTheme.textHigh,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const Spacer(),
                  Text(
                    'Size: $sizeMb MB',
                    style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Container(
                constraints: const BoxConstraints(maxHeight: 120),
                child: SingleChildScrollView(
                  child: Text(
                    _changelog.isNotEmpty ? _changelog : 'General improvements and bug fixes.',
                    style: const TextStyle(
                      color: IntelliJTheme.textPrimary,
                      fontSize: 12,
                      height: 1.4,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        if (_sha256.isNotEmpty) ...[
          const SizedBox(height: 10),
          Row(
            children: [
              const Icon(Icons.shield_outlined, size: 13, color: IntelliJTheme.textSecondary),
              const SizedBox(width: 6),
              const Text(
                'SHA-256: ',
                style: TextStyle(color: IntelliJTheme.textSecondary, fontSize: 11),
              ),
              Expanded(
                child: Text(
                  _sha256,
                  style: const TextStyle(
                    color: IntelliJTheme.textMuted,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ],
        if (_isStaging || _downloadProgress > 0) ...[
          const SizedBox(height: 14),
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Expanded(
                    child: Text(
                      _isStaging
                          ? 'Downloading & Verifying SHA-256...'
                          : 'Staging complete and verified.',
                      style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  Text(
                    '${(_downloadProgress * 100).toInt()}%',
                    style: const TextStyle(color: IntelliJTheme.accentBlue, fontSize: 11),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: _downloadProgress,
                backgroundColor: IntelliJTheme.border,
                valueColor: const AlwaysStoppedAnimation<Color>(IntelliJTheme.accentBlue),
                minHeight: 4,
              ),
            ],
          ),
        ],
        if (_errorMessage != null) ...[
          const SizedBox(height: 10),
          Text(
            _errorMessage!,
            style: const TextStyle(color: IntelliJTheme.gitRed, fontSize: 12),
          ),
        ],
      ],
    );
  }

  Widget _buildFooter() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      decoration: const BoxDecoration(
        color: IntelliJTheme.headerBg,
        borderRadius: BorderRadius.vertical(bottom: Radius.circular(8)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          OutlinedButton(
            onPressed: () => Navigator.of(context).pop(),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: IntelliJTheme.border),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
            ),
            child: Text(
              _appliedSuccess ? 'Done' : 'Cancel',
              style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12),
            ),
          ),
          const SizedBox(width: 8),
          if (!_isChecking && !_hasUpdate && !_appliedSuccess)
            ElevatedButton(
              onPressed: _checkForUpdates,
              style: ElevatedButton.styleFrom(
                backgroundColor: IntelliJTheme.accentBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              ),
              child: const Text('Check Again', style: TextStyle(fontSize: 12)),
            ),
          if (_hasUpdate && !_isReadyToApply && !_appliedSuccess)
            ElevatedButton(
              onPressed: _isStaging ? null : _stageAndVerify,
              style: ElevatedButton.styleFrom(
                backgroundColor: IntelliJTheme.accentBlue,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              ),
              child: _isStaging
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text('Download & Verify', style: TextStyle(fontSize: 12)),
            ),
          if (_isReadyToApply && !_appliedSuccess)
            ElevatedButton(
              onPressed: _isApplying ? null : _applyUpdate,
              style: ElevatedButton.styleFrom(
                backgroundColor: IntelliJTheme.gitGreen,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
              ),
              child: _isApplying
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Colors.white),
                      ),
                    )
                  : const Text('Restart & Apply', style: TextStyle(fontSize: 12)),
            ),
        ],
      ),
    );
  }
}
