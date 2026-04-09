import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_vlc_player/flutter_vlc_player.dart';
import 'package:video_player/video_player.dart';

import 'cast_bridge.dart';
import 'models.dart';
import 'theme.dart';
import 'utils.dart';

// ── Public entry point ────────────────────────────────────────────────────────

/// Opens the appropriate player for the given [uri]:
/// - **Native non-FLV** → native AVPlayerViewController via [CastBridge.showCastPicker]
///   (AVPlayer on iOS, ExoPlayer/Cast on Android)
/// - **Native FLV** → minimal VLC player page
/// - **Web** → minimal video_player page
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
}) async {
  if (!kIsWeb && !_isFlvUri(uri)) {
    // Native default: present AVPlayerViewController directly (no AirPlay
    // route picker popup). The user can still tap the AirPlay button inside
    // the native player UI if they want to cast.
    final playUrl = localFilePath != null
        ? 'file://$localFilePath'
        : (copyUrl ?? uri.toString());
    await CastBridge.instance.showNativePlayer(
      url: playUrl,
      title: title,
      headers: httpHeaders,
      isLive: isLive,
    );
    return;
  }

  // Fallback for FLV (native) or web: push a Flutter player page.
  final page = !kIsWeb && _isFlvUri(uri)
      ? _VlcPlayerPage(title: title, uri: uri, httpHeaders: httpHeaders, isLive: isLive)
      : _VideoPlayerPage(title: title, uri: uri, httpHeaders: httpHeaders, isLive: isLive, copyUrl: copyUrl ?? uri.toString());

  if (context.mounted) {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
  }
}

bool _isFlvUri(Uri uri) {
  final path = uri.path.toLowerCase();
  final str = uri.toString().toLowerCase();
  return path.endsWith('.flv') ||
      str.contains('.flv?') ||
      str.contains('.flv#') ||
      str.contains('type=flv') ||
      str.contains('format=flv');
}

// ── VLC player page (FLV native only) ────────────────────────────────────────

class _VlcPlayerPage extends StatefulWidget {
  const _VlcPlayerPage({
    required this.title,
    required this.uri,
    required this.httpHeaders,
    required this.isLive,
  });

  final String title;
  final Uri uri;
  final Map<String, String> httpHeaders;
  final bool isLive;

  @override
  State<_VlcPlayerPage> createState() => _VlcPlayerPageState();
}

class _VlcPlayerPageState extends State<_VlcPlayerPage> {
  late VlcPlayerController _ctrl;
  bool _showControls = true;
  bool _muted = false;
  bool _isFullscreen = false;
  Timer? _controlsTimer;

  int _seekFeedback = 0;
  Timer? _seekFeedbackTimer;
  Offset? _doubleTapPos;

  @override
  void initState() {
    super.initState();
    _ctrl = VlcPlayerController.network(
      widget.uri.toString(),
      hwAcc: HwAcc.full,
      autoPlay: true,
      options: _buildVlcOptions(widget.httpHeaders),
    )..addListener(_onUpdate);
    _scheduleControlsHide();
  }

  VlcPlayerOptions _buildVlcOptions(Map<String, String> headers) {
    if (headers.isEmpty) return VlcPlayerOptions();
    String? userAgent;
    String? referrer;
    final extraLines = <String>[];
    headers.forEach((key, value) {
      switch (key.toLowerCase()) {
        case 'user-agent':
          userAgent = value;
        case 'referer':
        case 'referrer':
          referrer = value;
        default:
          extraLines.add('$key: $value');
      }
    });
    return VlcPlayerOptions(
      http: [
        if (userAgent != null) VlcHttpOptions.httpUserAgent(userAgent!),
        if (referrer != null) VlcHttpOptions.httpReferrer(referrer!),
      ].isNotEmpty
          ? VlcHttpOptions([
              if (userAgent != null) VlcHttpOptions.httpUserAgent(userAgent!),
              if (referrer != null) VlcHttpOptions.httpReferrer(referrer!),
            ])
          : null,
      extras: extraLines.isNotEmpty
          ? [':http-extra-headers=${extraLines.join('\r\n')}\r\n']
          : null,
    );
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _seekFeedbackTimer?.cancel();
    _ctrl.removeListener(_onUpdate);
    _ctrl.dispose();
    if (_isFullscreen) _restoreSystemUi();
    super.dispose();
  }

  void _restoreSystemUi() {
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    SystemChrome.setPreferredOrientations(const [
      DeviceOrientation.portraitUp,
      DeviceOrientation.portraitDown,
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ]);
  }

  bool get _ready => _ctrl.value.isInitialized;
  bool get _playing => _ctrl.value.isPlaying;
  Duration get _position => _ctrl.value.position;
  Duration get _duration => _ctrl.value.duration;
  double get _aspectRatio {
    final sz = _ctrl.value.size;
    return (sz.width > 0 && sz.height > 0) ? sz.width / sz.height : 16 / 9;
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleControlsHide();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (!_playing) return;
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && _playing) setState(() => _showControls = false);
    });
  }

  Future<void> _togglePlay() async {
    if (_playing) {
      await _ctrl.pause();
      _controlsTimer?.cancel();
      setState(() => _showControls = true);
    } else {
      await _ctrl.play();
      _scheduleControlsHide();
    }
  }

  Future<void> _seekRelative(int seconds) async {
    var target = _position + Duration(seconds: seconds);
    if (target < Duration.zero) target = Duration.zero;
    final dur = _duration;
    if (dur > Duration.zero && target > dur) target = dur;
    await _ctrl.seekTo(target);
    _showSeekHint(seconds);
    _scheduleControlsHide();
  }

  void _showSeekHint(int s) {
    _seekFeedbackTimer?.cancel();
    setState(() => _seekFeedback = s);
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 700), () {
      if (mounted) setState(() => _seekFeedback = 0);
    });
  }

  Future<void> _setFullscreen(bool v) async {
    if (v) {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
      await SystemChrome.setPreferredOrientations(const [
        DeviceOrientation.landscapeLeft,
        DeviceOrientation.landscapeRight,
      ]);
    } else {
      _restoreSystemUi();
    }
    if (!mounted) return;
    setState(() {
      _isFullscreen = v;
      _showControls = true;
    });
    _scheduleControlsHide();
  }

  @override
  Widget build(BuildContext context) {
    final dur = _duration;
    final pos = _position;
    final hasScrub = _ready && dur > Duration.zero;

    final playerView = Stack(
      children: [
        Positioned.fill(
          child: ColoredBox(
            color: Colors.black,
            child: Center(
              child: _ready
                  ? VlcPlayer(
                      controller: _ctrl,
                      aspectRatio: _aspectRatio,
                      placeholder: const Center(child: CircularProgressIndicator()),
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
        ),
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _toggleControls,
            onDoubleTapDown: (d) => _doubleTapPos = d.localPosition,
            onDoubleTap: () {
              if (!_ready || widget.isLive) return;
              final pos = _doubleTapPos;
              if (pos == null) return;
              final w = MediaQuery.of(context).size.width;
              unawaited(_seekRelative(pos.dx > w / 2 ? 10 : -10));
            },
            child: const SizedBox.expand(),
          ),
        ),
        if (_seekFeedback != 0)
          Positioned.fill(
            child: IgnorePointer(
              child: Center(
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
                  decoration: BoxDecoration(
                      color: Colors.black54, borderRadius: BorderRadius.circular(32)),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _seekFeedback > 0 ? Icons.forward_10 : Icons.replay_10,
                        color: Colors.white,
                        size: 30,
                      ),
                      const SizedBox(width: 6),
                      Text('${_seekFeedback.abs()}s',
                          style: const TextStyle(
                              color: Colors.white, fontSize: 18, fontWeight: FontWeight.w600)),
                    ],
                  ),
                ),
              ),
            ),
          ),
        AnimatedOpacity(
          duration: const Duration(milliseconds: 180),
          opacity: _showControls ? 1 : 0,
          child: IgnorePointer(
            ignoring: !_showControls,
            child: _buildControls(context, pos, dur, hasScrub),
          ),
        ),
      ],
    );

    return PopScope<void>(
      canPop: !_isFullscreen,
      onPopInvokedWithResult: (didPop, _) async {
        if (!didPop && _isFullscreen) await _setFullscreen(false);
      },
      child: Scaffold(
        backgroundColor: Colors.black,
        appBar: _isFullscreen ? null : AppBar(title: Text(widget.title)),
        body: SafeArea(
          top: !_isFullscreen,
          bottom: !_isFullscreen,
          child: _isFullscreen
              ? playerView
              : AspectRatio(aspectRatio: _aspectRatio, child: playerView),
        ),
      ),
    );
  }

  Widget _buildControls(BuildContext ctx, Duration pos, Duration dur, bool hasScrub) {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topCenter,
          end: Alignment.bottomCenter,
          colors: [Colors.black38, Colors.transparent, Colors.black54],
        ),
      ),
      child: Column(
        children: [
          if (_isFullscreen)
            SafeArea(
              bottom: false,
              child: Row(children: [
                IconButton(
                  onPressed: () => _setFullscreen(false),
                  icon: const Icon(Icons.arrow_back, color: Colors.white),
                ),
                Expanded(
                  child: Text(widget.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600)),
                ),
              ]),
            ),
          const Spacer(),
          if (_ready && _isFullscreen)
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                _bigIconBtn(Icons.replay_10, () => unawaited(_seekRelative(-10))),
                const SizedBox(width: 32),
                _bigIconBtn(
                  _playing ? Icons.pause : Icons.play_arrow,
                  _togglePlay,
                  size: 88,
                  iconSize: 48,
                ),
                const SizedBox(width: 32),
                _bigIconBtn(Icons.forward_10, () => unawaited(_seekRelative(10))),
              ],
            ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
            color: Colors.black45,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (hasScrub)
                  SliderTheme(
                    data: SliderTheme.of(ctx).copyWith(
                      activeTrackColor: appPrimary,
                      inactiveTrackColor: const Color(0xFF1E293B),
                      thumbColor: appPrimary,
                      overlayColor: appPrimary.withValues(alpha: 0.16),
                      trackHeight: 3,
                    ),
                    child: Slider(
                      value: pos.inMilliseconds
                          .clamp(0, math.max(dur.inMilliseconds, 1))
                          .toDouble(),
                      min: 0,
                      max: math.max(dur.inMilliseconds, 1).toDouble(),
                      onChanged: _ready
                          ? (v) => unawaited(_ctrl.seekTo(Duration(milliseconds: v.round())))
                          : null,
                    ),
                  ),
                Row(
                  children: [
                    IconButton(
                      onPressed: _ready ? _togglePlay : null,
                      icon: Icon(_playing ? Icons.pause : Icons.play_arrow),
                      color: Colors.white,
                    ),
                    if (widget.isLive && !hasScrub)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                        decoration: BoxDecoration(
                          color: appDanger.withValues(alpha: 0.18),
                          borderRadius: BorderRadius.circular(999),
                        ),
                        child: const Text('LIVE',
                            style: TextStyle(color: appDanger, fontWeight: FontWeight.w700)),
                      )
                    else if (hasScrub)
                      Text(
                        '${formatDurationLabel(pos)} / ${formatDurationLabel(dur)}',
                        style: const TextStyle(color: Colors.white70),
                      ),
                    const Spacer(),
                    IconButton(
                      onPressed: _ready
                          ? () async {
                              await _ctrl.setVolume(_muted ? 100 : 0);
                              setState(() => _muted = !_muted);
                            }
                          : null,
                      icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                      color: Colors.white,
                    ),
                    IconButton(
                      onPressed: _ready ? () => unawaited(_setFullscreen(!_isFullscreen)) : null,
                      icon: Icon(_isFullscreen ? Icons.fullscreen_exit : Icons.fullscreen),
                      color: Colors.white,
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _bigIconBtn(IconData icon, VoidCallback onPressed, {double size = 72, double iconSize = 38}) {
    return IconButton.filled(
      style: IconButton.styleFrom(
        backgroundColor: Colors.black.withValues(alpha: 0.55),
        foregroundColor: Colors.white,
        minimumSize: Size(size, size),
      ),
      onPressed: onPressed,
      icon: Icon(icon, size: iconSize),
    );
  }
}

// ── Web video_player page ─────────────────────────────────────────────────────

class _VideoPlayerPage extends StatefulWidget {
  const _VideoPlayerPage({
    required this.title,
    required this.uri,
    required this.httpHeaders,
    required this.isLive,
    required this.copyUrl,
  });

  final String title;
  final Uri uri;
  final Map<String, String> httpHeaders;
  final bool isLive;
  final String copyUrl;

  @override
  State<_VideoPlayerPage> createState() => _VideoPlayerPageState();
}

class _VideoPlayerPageState extends State<_VideoPlayerPage> {
  VideoPlayerController? _ctrl;
  String? _error;
  bool _initialized = false;
  bool _showControls = true;
  bool _muted = false;
  Timer? _controlsTimer;

  @override
  void initState() {
    super.initState();
    _ctrl = VideoPlayerController.networkUrl(
      widget.uri,
      httpHeaders: widget.httpHeaders,
    )..addListener(_onUpdate);
    unawaited(_init());
  }

  Future<void> _init() async {
    try {
      await _ctrl!.initialize();
      await _ctrl!.setLooping(!widget.isLive);
      await _ctrl!.play();
      if (!mounted) return;
      setState(() => _initialized = true);
      _scheduleControlsHide();
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  void _onUpdate() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controlsTimer?.cancel();
    _ctrl?.removeListener(_onUpdate);
    _ctrl?.dispose();
    super.dispose();
  }

  void _scheduleControlsHide() {
    _controlsTimer?.cancel();
    if (_ctrl?.value.isPlaying != true) return;
    _controlsTimer = Timer(const Duration(seconds: 4), () {
      if (mounted && (_ctrl?.value.isPlaying ?? false)) {
        setState(() => _showControls = false);
      }
    });
  }

  void _toggleControls() {
    setState(() => _showControls = !_showControls);
    if (_showControls) _scheduleControlsHide();
  }

  @override
  Widget build(BuildContext context) {
    final ctrl = _ctrl;
    final err = _error;
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.title),
        actions: [
          IconButton(
            tooltip: 'Copy URL',
            onPressed: () => copyToClipboard(context, widget.copyUrl, label: 'URL copied.'),
            icon: const Icon(Icons.copy),
          ),
        ],
      ),
      body: SafeArea(
        child: err != null
            ? Center(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Text(err,
                      style: TextStyle(color: Theme.of(context).colorScheme.error)),
                ),
              )
            : !_initialized || ctrl == null
                ? const Center(child: CircularProgressIndicator())
                : GestureDetector(
                    onTap: _toggleControls,
                    child: Stack(
                      children: [
                        Center(
                          child: AspectRatio(
                            aspectRatio: ctrl.value.aspectRatio,
                            child: VideoPlayer(ctrl),
                          ),
                        ),
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 180),
                          opacity: _showControls ? 1 : 0,
                          child: IgnorePointer(
                            ignoring: !_showControls,
                            child: _buildControls(context, ctrl),
                          ),
                        ),
                      ],
                    ),
                  ),
      ),
    );
  }

  Widget _buildControls(BuildContext context, VideoPlayerController ctrl) {
    final pos = ctrl.value.position;
    final dur = ctrl.value.duration;
    final hasScrub = dur > Duration.zero;
    return Align(
      alignment: Alignment.bottomCenter,
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        color: Colors.black54,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (hasScrub)
              VideoProgressIndicator(
                ctrl,
                allowScrubbing: true,
                padding: const EdgeInsets.symmetric(vertical: 10),
                colors: const VideoProgressColors(
                  playedColor: appPrimary,
                  bufferedColor: Color(0xFF475569),
                  backgroundColor: Color(0xFF1E293B),
                ),
              ),
            Row(
              children: [
                IconButton(
                  onPressed: () async {
                    if (ctrl.value.isPlaying) {
                      await ctrl.pause();
                      _controlsTimer?.cancel();
                      setState(() => _showControls = true);
                    } else {
                      await ctrl.play();
                      _scheduleControlsHide();
                    }
                  },
                  icon: Icon(ctrl.value.isPlaying ? Icons.pause : Icons.play_arrow),
                  color: Colors.white,
                ),
                if (widget.isLive && !hasScrub)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    decoration: BoxDecoration(
                      color: appDanger.withValues(alpha: 0.18),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: const Text('LIVE',
                        style: TextStyle(color: appDanger, fontWeight: FontWeight.w700)),
                  )
                else if (hasScrub)
                  Text(
                    '${formatDurationLabel(pos)} / ${formatDurationLabel(dur)}',
                    style: const TextStyle(color: Colors.white70),
                  ),
                const Spacer(),
                IconButton(
                  onPressed: () async {
                    final newMuted = !_muted;
                    await ctrl.setVolume(newMuted ? 0 : 1);
                    setState(() => _muted = newMuted);
                  },
                  icon: Icon(_muted ? Icons.volume_off : Icons.volume_up),
                  color: Colors.white,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
