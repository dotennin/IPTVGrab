import 'dart:async';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:photo_manager/photo_manager.dart';
import 'package:sensors_plus/sensors_plus.dart';
import 'package:share_plus/share_plus.dart';
import 'package:video_player/video_player.dart';

import 'background_execution_bridge.dart';
import 'models.dart';
import 'native_ios_player.dart';
import 'theme.dart';
import 'utils.dart';

Future<void> openMediaPlayer(
  BuildContext context, {
  required String title,
  required Uri uri,
  required Map<String, String> httpHeaders,
  bool isLive = false,
  String? localFilePath,
  String? localFileName,
  String? copyUrl,
  String? copyLabel,
  VoidCallback? onGrabRequested,
  bool allowPictureInPicture = false,
  Future<List<StreamVariant>> Function()? onFetchVariants,
}) {
  return Navigator.of(context).push(
    MaterialPageRoute<void>(
      builder: (_) => MediaPlayerPage(
        title: title,
        uri: uri,
        httpHeaders: httpHeaders,
        isLive: isLive,
        localFilePath: localFilePath,
        localFileName: localFileName,
        copyUrl: copyUrl,
        copyLabel: copyLabel,
        onGrabRequested: onGrabRequested,
        allowPictureInPicture: allowPictureInPicture,
        onFetchVariants: onFetchVariants,
      ),
    ),
  );
}

class MediaPlayerPage extends StatefulWidget {
  const MediaPlayerPage({
    super.key,
    required this.title,
    required this.uri,
    required this.httpHeaders,
    this.isLive = false,
    this.localFilePath,
    this.localFileName,
    this.copyUrl,
    this.copyLabel,
    this.onGrabRequested,
    this.allowPictureInPicture = false,
    this.onFetchVariants,
  });

  final String title;
  final Uri uri;
  final Map<String, String> httpHeaders;
  final bool isLive;
  final String? localFilePath;
  final String? localFileName;
  final String? copyUrl;
  final String? copyLabel;
  final VoidCallback? onGrabRequested;
  final bool allowPictureInPicture;
  final Future<List<StreamVariant>> Function()? onFetchVariants;

  @override
  State<MediaPlayerPage> createState() => _MediaPlayerPageState();
}

class _MediaPlayerPageState extends State<MediaPlayerPage> {
  VideoPlayerController? _controller;
  NativeIosPlayerController? _iosController;
  String? _error;
  bool _initialized = false;
  bool _isFullscreen = false;
  bool _showControls = true;
  bool _muted = false;
  bool _enteringPictureInPicture = false;
  String? _pictureInPictureFailure;
  List<String> _pictureInPictureReasons = const <String>[];
  Timer? _controlsTimer;
  StreamSubscription<AccelerometerEvent>? _accelSub;
  bool _settingFullscreen = false;
  DateTime? _gyroToggleTime;
  final GlobalKey _playerKey = GlobalKey();

  List<StreamVariant> _variants = const [];
  bool _fetchingVariants = false;
  bool _variantsLoaded = false;
  int _selectedVariantIndex = -1;
  int _iosPlayerVersion = 0;

  Offset? _doubleTapPos;
  int _seekFeedback = 0;
  Timer? _seekFeedbackTimer;

  bool get _usesNativeIosPlayer => Platform.isIOS;

  bool get _playerInitialized => _usesNativeIosPlayer
      ? (_iosController?.initialized ?? false)
      : _initialized;

  bool get _playerIsPlaying => _usesNativeIosPlayer
      ? (_iosController?.isPlaying ?? false)
      : _controller!.value.isPlaying;

  Duration get _playerPosition => _usesNativeIosPlayer
      ? (_iosController?.position ?? Duration.zero)
      : _controller!.value.position;

  Duration get _playerDuration => _usesNativeIosPlayer
      ? (_iosController?.duration ?? Duration.zero)
      : _controller!.value.duration;

  double get _playerAspectRatio {
    if (_usesNativeIosPlayer) {
      final aspectRatio = _iosController?.aspectRatio ?? 16 / 9;
      return aspectRatio > 0 ? aspectRatio : 16 / 9;
    }
    final controller = _controller!;
    return controller.value.isInitialized && controller.value.aspectRatio > 0
        ? controller.value.aspectRatio
        : 16 / 9;
  }

  String? get _playerError =>
      _usesNativeIosPlayer ? (_iosController?.error ?? _error) : _error;

  List<String> get _pictureInPictureDiagnostics {
    final reasons = <String>[
      ...(_iosController?.diagnostics ?? const <String>[]),
      ..._pictureInPictureReasons,
    ];
    if (_usesNativeIosPlayer &&
        !(_iosController?.isPictureInPictureSupported ?? false)) {
      reasons.add(
        'This iPhone or iOS build reports that Picture in Picture is not supported.',
      );
    }
    if (_usesNativeIosPlayer &&
        _playerInitialized &&
        !(_iosController?.isPictureInPicturePossible ?? false)) {
      reasons.add(
        'The native AVPictureInPictureController still reports that Picture in Picture is not currently possible for this stream.',
      );
    }
    if (_usesNativeIosPlayer && !_playerInitialized) {
      reasons.add(
        'The native player is still initializing, so Picture in Picture is not ready yet.',
      );
    }
    if (_playerError != null) {
      reasons.add('Playback error: $_playerError');
    }
    return dedupeMessages(reasons);
  }

  @override
  void initState() {
    super.initState();
    if (_usesNativeIosPlayer) {
      _iosController = NativeIosPlayerController(
        uri: widget.uri,
        httpHeaders: widget.httpHeaders,
        isLive: widget.isLive,
      )..addListener(_handleControllerUpdate);
    } else {
      _controller = VideoPlayerController.networkUrl(
        widget.uri,
        httpHeaders: widget.httpHeaders,
      );
      _controller!.addListener(_handleControllerUpdate);
      unawaited(_initialize());
    }
    _accelSub = accelerometerEventStream(
      samplingPeriod: SensorInterval.normalInterval,
    ).listen(_onAccelerometer);
  }

  void _onAccelerometer(AccelerometerEvent event) {
    if (_settingFullscreen) return;
    final now = DateTime.now();
    if (_gyroToggleTime != null &&
        now.difference(_gyroToggleTime!) <
            const Duration(milliseconds: 1500)) {
      return;
    }
    final absX = event.x.abs();
    final absY = event.y.abs();
    if (!_isFullscreen && absX >= 7.0 && absY < 5.0) {
      _gyroToggleTime = now;
      unawaited(_setFullscreen(true, fromGyro: true));
    } else if (_isFullscreen && absY >= 7.0 && absX < 5.0) {
      _gyroToggleTime = now;
      unawaited(_setFullscreen(false, fromGyro: true));
    }
  }

  Future<void> _initialize() async {
    try {
      final controller = _controller!;
      await controller.initialize();
      await controller.setLooping(!widget.isLive);
      await controller.setVolume(_muted ? 0 : 1);
      await controller.play();
      if (!mounted) {
        return;
      }
      setState(() => _initialized = true);
      _scheduleControlsHide();
      unawaited(_loadVariants());
    } catch (error) {
      if (!mounted) {
        return;
      }
      setState(() => _error = error.toString());
    }
  }

  void _handleControllerUpdate() {
    if (!mounted) {
      return;
    }
    setState(() {});
    if (_usesNativeIosPlayer && _playerInitialized && !_variantsLoaded) {
      _variantsLoaded = true;
      unawaited(_loadVariants());
    }
  }

  Future<void> _togglePlayback() async {
    if (_playerIsPlaying) {
      if (_usesNativeIosPlayer) {
        await _iosController!.pause();
      } else {
        await _controller!.pause();
      }
      _controlsTimer?.cancel();
      setState(() => _showControls = true);
      return;
    }
    if (_usesNativeIosPlayer) {
      await _iosController!.play();
    } else {
      await _controller!.play();
    }
    _scheduleControlsHide();
  }

  Future<void> _seekRelative(int seconds) async {
    final position = _playerPosition;
    final duration = _playerDuration;
    final target = position + Duration(seconds: seconds);
    final clamped = target < Duration.zero
        ? Duration.zero
        : (duration > Duration.zero && target > duration ? duration : target);
    await _seekTo(clamped);
    _scheduleControlsHide();
  }

  Future<void> _seekTo(Duration position) async {
    if (_usesNativeIosPlayer) {
      await _iosController!.seekTo(position);
    } else {
      await _controller!.seekTo(position);
    }
  }

  Future<void> _setMuted(bool value) async {
    if (_usesNativeIosPlayer) {
      await _iosController!.setMuted(value);
    } else {
      await _controller!.setVolume(value ? 0 : 1);
    }
    if (!mounted) {
      return;
    }
    setState(() => _muted = value);
    _scheduleControlsHide();
  }

  Future<void> _setFullscreen(bool enabled, {bool fromGyro = false}) async {
    if (_settingFullscreen) return;
    _settingFullscreen = true;
    try {
      if (enabled) {
        await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
        if (!fromGyro) {
          await SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
            DeviceOrientation.landscapeLeft,
            DeviceOrientation.landscapeRight,
          ]);
        }
      } else {
        _restoreSystemUi();
      }
      if (!mounted) return;
      setState(() {
        _isFullscreen = enabled;
        _showControls = true;
      });
      _scheduleControlsHide();
    } finally {
      _settingFullscreen = false;
    }
  }

  void _restoreSystemUi() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const <DeviceOrientation>[
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) {
      _scheduleControlsHide();
    } else {
      _controlsTimer?.cancel();
    }
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_isFullscreen || !_playerIsPlaying) {
      return;
    }
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (!mounted || !_playerIsPlaying) {
        return;
      }
      setState(() => _showControls = false);
    });
  }

  String get _resolvedCopyUrl => widget.copyUrl ?? widget.uri.toString();

  Future<void> _loadVariants() async {
    if (widget.onFetchVariants == null || _fetchingVariants) return;
    setState(() => _fetchingVariants = true);
    try {
      final variants = await widget.onFetchVariants!();
      if (!mounted) return;
      setState(() {
        _variants = variants;
        _selectedVariantIndex = variants.isEmpty ? -1 : 0;
        _variantsLoaded = true;
        _fetchingVariants = false;
      });
    } catch (_) {
      if (mounted) setState(() => _fetchingVariants = false);
    }
  }

  Future<void> _switchVariant(int index) async {
    if (index == _selectedVariantIndex) return;
    final variant = _variants[index];
    final uri = Uri.parse(variant.url);
    if (_usesNativeIosPlayer) {
      final cap = (index == 0 || variant.bandwidth == 0) ? 0 : variant.bandwidth;
      await _iosController!.setPreferredBitRate(cap);
      if (!mounted) return;
      setState(() => _selectedVariantIndex = index);
    } else {
      setState(() {
        _selectedVariantIndex = index;
        _initialized = false;
      });
      final oldCtrl = _controller;
      oldCtrl?.removeListener(_handleControllerUpdate);
      await oldCtrl?.pause();
      await oldCtrl?.dispose();
      final ctrl = VideoPlayerController.networkUrl(
        uri,
        httpHeaders: widget.httpHeaders,
      );
      _controller = ctrl;
      ctrl.addListener(_handleControllerUpdate);
      await ctrl.initialize();
      await ctrl.setVolume(_muted ? 0 : 1);
      await ctrl.play();
      if (mounted) setState(() => _initialized = true);
    }
  }

  void _showQualitySheet(BuildContext context) {
    if (_variants.isEmpty) return;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.black87,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (_) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 14),
              child: Text(
                'Quality',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 16,
                ),
              ),
            ),
            const Divider(color: Colors.white24, height: 1),
            ..._variants.asMap().entries.map((e) {
              final i = e.key;
              final v = e.value;
              final selected = i == _selectedVariantIndex;
              return ListTile(
                leading: Icon(
                  selected ? Icons.check_circle : Icons.radio_button_unchecked,
                  color: selected ? Colors.blue : Colors.white54,
                  size: 20,
                ),
                title: Text(
                  v.displayLabel,
                  style: TextStyle(
                    color: selected ? Colors.white : Colors.white70,
                  ),
                ),
                onTap: () {
                  Navigator.of(context).pop();
                  unawaited(_switchVariant(i));
                },
              );
            }),
          ],
        ),
      ),
    );
  }

  void _handleDoubleTap() {
    if (!_isFullscreen || !_playerInitialized || widget.isLive) return;
    final pos = _doubleTapPos;
    if (pos == null) return;
    final screenW = MediaQuery.of(context).size.width;
    final seconds = pos.dx > screenW / 2 ? 10 : -10;
    unawaited(_seekRelative(seconds));
    _showSeekFeedback(seconds);
  }

  void _showSeekFeedback(int seconds) {
    _seekFeedbackTimer?.cancel();
    setState(() => _seekFeedback = seconds);
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFeedback = 0);
    });
  }

  String get _resolvedCopyLabel =>
      widget.copyLabel ??
      'Media URL copied. It still requires the active session cookie when auth is enabled.';

  bool get _canUsePictureInPicture =>
      widget.allowPictureInPicture && (Platform.isAndroid || Platform.isIOS);

  Future<void> _enterPictureInPicture() async {
    if (_enteringPictureInPicture) {
      return;
    }
    setState(() => _enteringPictureInPicture = true);
    try {
      final entered = _usesNativeIosPlayer
          ? await _iosController!.enterPictureInPicture()
          : await BackgroundExecutionBridge.instance.enterPictureInPicture(
              uri: widget.uri,
              headers: widget.httpHeaders,
              position: widget.isLive ? null : await _controller!.position,
            );
      if (!mounted) {
        return;
      }
      if (entered) {
        setState(() {
          _pictureInPictureFailure = null;
          _pictureInPictureReasons = const <String>[];
        });
      } else {
        _recordPictureInPictureFailure(
          'Picture in Picture is unavailable right now.',
          _pictureInPictureDiagnostics,
        );
      }
    } on NativeIosPlayerException catch (error) {
      if (!mounted) {
        return;
      }
      _recordPictureInPictureFailure(error.message, error.details);
    } on BackgroundExecutionBridgeException catch (error) {
      if (!mounted) {
        return;
      }
      showMessage(context, error.message, error: true);
    } finally {
      if (mounted) {
        setState(() => _enteringPictureInPicture = false);
      }
    }
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _accelSub?.cancel();
    _restoreSystemUi();
    _iosController?.removeListener(_handleControllerUpdate);
    _controller?.removeListener(_handleControllerUpdate);
    _controller?.dispose();
    _iosController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final aspectRatio = _playerAspectRatio;

    final gestureLayer = Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _playerInitialized ? _toggleControls : null,
        onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
        onDoubleTap: _handleDoubleTap,
        child: const SizedBox.expand(),
      ),
    );

    final player = SizedBox(
      key: _playerKey,
      child: Stack(
        children: <Widget>[
          Positioned.fill(
            child: DecoratedBox(
              decoration: BoxDecoration(
                color: Colors.black,
                borderRadius: BorderRadius.circular(_isFullscreen ? 0 : 20),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(_isFullscreen ? 0 : 20),
                child: _buildPlayerSurface(context),
              ),
            ),
          ),
          gestureLayer,
          Positioned.fill(child: _buildControls(context)),
          if (_seekFeedback != 0)
            Positioned.fill(
              child: IgnorePointer(
                child: Center(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                        horizontal: 20, vertical: 10),
                    decoration: BoxDecoration(
                      color: Colors.black54,
                      borderRadius: BorderRadius.circular(32),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          _seekFeedback > 0
                              ? Icons.forward_10
                              : Icons.replay_10,
                          color: Colors.white,
                          size: 30,
                        ),
                        const SizedBox(width: 6),
                        Text(
                          '${_seekFeedback.abs()}s',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    return PopScope<void>(
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, _) async {
        if (didPop || !_isFullscreen) {
          return;
        }
        await _setFullscreen(false);
      },
      child: Scaffold(
        backgroundColor: _isFullscreen ? Colors.black : null,
        appBar: _isFullscreen
            ? null
            : AppBar(
                title: Text(widget.title),
                actions: <Widget>[
                  if (widget.onGrabRequested != null)
                    IconButton(
                      tooltip: 'Save offline',
                      onPressed: widget.onGrabRequested,
                      icon: const Icon(Icons.download_for_offline),
                    ),
                  if (_canUsePictureInPicture)
                    IconButton(
                      tooltip: 'Picture in picture',
                      onPressed: _enteringPictureInPicture
                          ? null
                          : _enterPictureInPicture,
                      icon: const Icon(Icons.picture_in_picture_alt_outlined),
                    ),
                  IconButton(
                    tooltip: 'Copy URL',
                    onPressed: () => copyToClipboard(
                      context,
                      _resolvedCopyUrl,
                      label: _resolvedCopyLabel,
                    ),
                    icon: const Icon(Icons.copy),
                  ),
                  if (widget.localFilePath != null &&
                      widget.localFileName != null)
                    IconButton(
                      tooltip: 'Share file',
                      onPressed: () => _shareFile(context),
                      icon: const Icon(Icons.ios_share),
                    ),
                  if (widget.localFilePath != null &&
                      widget.localFileName != null)
                    IconButton(
                      tooltip: 'Save to Photos',
                      onPressed: () => _saveToPhotos(context),
                      icon: const Icon(Icons.photo_library_outlined),
                    ),
                ],
              ),
        body: SafeArea(
          top: !_isFullscreen,
          bottom: !_isFullscreen,
          child: _isFullscreen
              ? Center(
                  child: AspectRatio(
                    aspectRatio: aspectRatio,
                    child: player,
                  ),
                )
              : Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    children: <Widget>[
                      AspectRatio(
                        aspectRatio: aspectRatio,
                        child: player,
                      ),
                      const SizedBox(height: 12),
                      Row(
                        children: <Widget>[
                          Expanded(
                            child: Text(
                              widget.isLive
                                  ? 'Live preview from your source. Use fullscreen for a cleaner view.'
                                  : 'Pause, seek, clip a segment, or keep a local copy in your library.',
                              style: Theme.of(context)
                                  .textTheme
                                  .bodySmall
                                  ?.copyWith(color: appTextMuted),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 12),
                      if (_usesNativeIosPlayer &&
                          _canUsePictureInPicture &&
                          _pictureInPictureFailure != null)
                        Align(
                          alignment: Alignment.centerLeft,
                          child: TextButton.icon(
                            onPressed: _showPictureInPictureDiagnosticsDialog,
                            icon: const Icon(Icons.info_outline),
                            label: const Text('Show PiP diagnostics'),
                          ),
                        ),
                      if (_usesNativeIosPlayer &&
                          _canUsePictureInPicture &&
                          _pictureInPictureFailure != null)
                        const SizedBox(height: 8),
                      Align(
                        alignment: Alignment.centerLeft,
                        child: SelectableText(
                          _resolvedCopyUrl,
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ),
                    ],
                  ),
                ),
        ),
      ),
    );
  }

  Future<void> _shareFile(BuildContext context) async {
    final file = File(widget.localFilePath!);
    try {
      if (!await file.exists()) {
        throw Exception('Local media file not found: ${widget.localFileName}');
      }
      await _doShareFile(context, file, widget.localFileName!);
    } on Exception catch (error) {
      if (!context.mounted) return;
      showMessage(context, error.toString(), error: true);
    }
  }

  Future<void> _doShareFile(BuildContext context, File file, String filename) async {
    final renderObject = context.findRenderObject();
    Rect? shareOrigin;
    if (renderObject is RenderBox) {
      final origin = renderObject.localToGlobal(Offset.zero);
      shareOrigin = origin & renderObject.size;
    }
    await SharePlus.instance.share(
      ShareParams(
        files: <XFile>[XFile(file.path, mimeType: 'video/mp4', name: filename)],
        title: filename,
        subject: filename,
        text: filename,
        sharePositionOrigin: shareOrigin,
      ),
    );
  }

  Future<void> _saveToPhotos(BuildContext context) async {
    final file = File(widget.localFilePath!);
    try {
      if (!await file.exists()) {
        throw Exception('Local media file not found: ${widget.localFileName}');
      }
      final permission = await PhotoManager.requestPermissionExtend(
        requestOption: const PermissionRequestOption(
          iosAccessLevel: IosAccessLevel.addOnly,
          androidPermission: AndroidPermission(type: RequestType.video, mediaLocation: false),
        ),
      );
      if (!permission.hasAccess) {
        throw Exception('Photo library permission is required.');
      }
      await PhotoManager.editor.saveVideo(
        file,
        title: widget.localFileName!.replaceFirst(RegExp(r'\.mp4$'), ''),
      );
      if (!context.mounted) return;
      showMessage(context, 'Saved to Photos.');
    } on Exception catch (error) {
      if (!context.mounted) return;
      showMessage(context, error.toString(), error: true);
    }
  }

  Widget _buildControls(BuildContext context) {
    final current = _playerPosition;
    final total = _playerDuration;
    final hasTimeline =
        _playerInitialized && !widget.isLive && total > Duration.zero;
    return AnimatedOpacity(
      duration: const Duration(milliseconds: 180),
      opacity: !_isFullscreen || _showControls ? 1 : 0,
      child: IgnorePointer(
        ignoring: _isFullscreen && !_showControls,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: (_isFullscreen && _showControls) ? _toggleControls : null,
          child: Container(
          decoration: BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: <Color>[
                Colors.black.withValues(alpha: _isFullscreen ? 0.38 : 0.12),
                Colors.transparent,
                Colors.black.withValues(alpha: 0.56),
              ],
            ),
          ),
          child: Column(
            children: <Widget>[
              if (_isFullscreen)
                SafeArea(
                  bottom: false,
                  child: Row(
                    children: <Widget>[
                      IconButton(
                        onPressed: () => _setFullscreen(false),
                        icon: const Icon(Icons.arrow_back, color: Colors.white),
                      ),
                      Expanded(
                        child: Text(
                          widget.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              const Spacer(),
              if (_playerInitialized && _isFullscreen)
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: <Widget>[
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.55),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(72, 72),
                      ),
                      onPressed: () => _seekRelative(-10),
                      icon: const Icon(Icons.replay_10, size: 38),
                    ),
                    const SizedBox(width: 32),
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.55),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(88, 88),
                      ),
                      onPressed: _togglePlayback,
                      icon: Icon(
                        _playerIsPlaying ? Icons.pause : Icons.play_arrow,
                        size: 48,
                      ),
                    ),
                    const SizedBox(width: 32),
                    IconButton.filled(
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.black.withValues(alpha: 0.55),
                        foregroundColor: Colors.white,
                        minimumSize: const Size(72, 72),
                      ),
                      onPressed: () => _seekRelative(10),
                      icon: const Icon(Icons.forward_10, size: 38),
                    ),
                  ],
                ),
              const Spacer(),
              Container(
                padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                color: Colors.black.withValues(alpha: 0.36),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    if (hasTimeline) _buildTimeline(context, current, total),
                    Row(
                      children: <Widget>[
                        if (hasTimeline)
                          IconButton(
                            onPressed: _playerInitialized
                                ? () => _seekRelative(-10)
                                : null,
                            icon: const Icon(Icons.replay_10),
                          ),
                        IconButton(
                          onPressed:
                              _playerInitialized ? _togglePlayback : null,
                          icon: Icon(
                            _playerIsPlaying ? Icons.pause : Icons.play_arrow,
                          ),
                        ),
                        if (hasTimeline)
                          IconButton(
                            onPressed: _playerInitialized
                                ? () => _seekRelative(10)
                                : null,
                            icon: const Icon(Icons.forward_10),
                          ),
                        if (widget.isLive)
                          Container(
                            padding: const EdgeInsets.symmetric(
                                horizontal: 10, vertical: 6),
                            decoration: BoxDecoration(
                              color: appDanger.withValues(alpha: 0.18),
                              borderRadius: BorderRadius.circular(999),
                            ),
                            child: const Text(
                              'LIVE',
                              style: TextStyle(
                                color: appDanger,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ),
                        const Spacer(),
                        Text(
                          widget.isLive
                              ? 'Live'
                              : '${formatDurationLabel(current)} / ${formatDurationLabel(total)}',
                          style: const TextStyle(color: Colors.white70),
                        ),
                        IconButton(
                          onPressed: _playerInitialized
                              ? () => _setMuted(!_muted)
                              : null,
                          icon: Icon(
                            _muted ? Icons.volume_off : Icons.volume_up,
                          ),
                        ),
                        if (_fetchingVariants)
                          const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white54,
                            ),
                          )
                        else if (_variants.length > 1)
                          TextButton.icon(
                            onPressed: () => _showQualitySheet(context),
                            icon: const Icon(Icons.hd, size: 18),
                            label: Text(
                              _selectedVariantIndex >= 0
                                  ? _variants[_selectedVariantIndex].displayLabel
                                  : 'Auto',
                              style: const TextStyle(fontSize: 12),
                            ),
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white,
                              padding:
                                  const EdgeInsets.symmetric(horizontal: 4),
                              minimumSize: Size.zero,
                              tapTargetSize:
                                  MaterialTapTargetSize.shrinkWrap,
                            ),
                          ),
                        IconButton(
                          onPressed: _playerInitialized
                              ? () => _setFullscreen(!_isFullscreen)
                              : null,
                          icon: Icon(
                            _isFullscreen
                                ? Icons.fullscreen_exit
                                : Icons.fullscreen,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        ),
      ),
    );
  }

  Widget _buildPlayerSurface(BuildContext context) {
    final overlay = _playerError != null
        ? Center(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Text(
                _playerError!,
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ),
          )
        : !_playerInitialized
            ? const Center(child: CircularProgressIndicator())
            : null;

    if (_usesNativeIosPlayer) {
      return Stack(
        children: <Widget>[
          Positioned.fill(
            child: NativeIosPlayerView(
              key: ValueKey(_iosPlayerVersion),
              controller: _iosController!,
            ),
          ),
          if (overlay != null) Positioned.fill(child: overlay),
        ],
      );
    }

    if (overlay != null) {
      return overlay;
    }
    return Center(child: VideoPlayer(_controller!));
  }

  Widget _buildTimeline(
    BuildContext context,
    Duration current,
    Duration total,
  ) {
    if (!_usesNativeIosPlayer) {
      return VideoProgressIndicator(
        _controller!,
        allowScrubbing: true,
        padding: const EdgeInsets.symmetric(vertical: 10),
        colors: const VideoProgressColors(
          playedColor: appPrimary,
          bufferedColor: Color(0xFF475569),
          backgroundColor: Color(0xFF1E293B),
        ),
      );
    }

    final totalMs = math.max(total.inMilliseconds, 1);
    final currentMs = current.inMilliseconds.clamp(0, totalMs).toDouble();
    return SliderTheme(
      data: SliderTheme.of(context).copyWith(
        activeTrackColor: appPrimary,
        inactiveTrackColor: const Color(0xFF1E293B),
        thumbColor: appPrimary,
        overlayColor: appPrimary.withValues(alpha: 0.16),
        trackHeight: 3,
      ),
      child: Slider(
        value: currentMs,
        min: 0,
        max: totalMs.toDouble(),
        onChanged: _playerInitialized
            ? (value) =>
                unawaited(_seekTo(Duration(milliseconds: value.round())))
            : null,
      ),
    );
  }

  Future<void> _showPictureInPictureDiagnosticsDialog() {
    final message =
        _pictureInPictureFailure ?? 'Picture in Picture diagnostics';
    final mergedReasons = dedupeMessages(<String>[
      ..._pictureInPictureDiagnostics,
      ...(_iosController?.diagnostics ?? const <String>[]),
    ]);
    return showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Picture in Picture diagnostics'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Text(message),
                if (mergedReasons.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  for (final reason in mergedReasons)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 8),
                      child: Text('• $reason'),
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  void _recordPictureInPictureFailure(
    String message,
    List<String> reasons,
  ) {
    final mergedReasons = dedupeMessages(<String>[
      ...reasons,
      ...(_iosController?.diagnostics ?? const <String>[]),
    ]);
    setState(() {
      _pictureInPictureFailure = message;
      _pictureInPictureReasons = mergedReasons;
    });
    showMessage(context, message, error: true);
    unawaited(_showPictureInPictureDiagnosticsDialog());
  }
}
