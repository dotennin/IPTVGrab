import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

import 'cast_bridge.dart';
import 'models.dart';
import 'theme.dart';
import 'utils.dart';

// ── Public entry point ────────────────────────────────────────────────────────

/// Opens the appropriate player for the given [uri]:
/// - **Native non-FLV** → native AVPlayer/ExoPlayer via [CastBridge.showNativePlayer]
/// - **Native FLV** → launches VLC for Mobile app (user must install it)
/// - **Web** → in-app [_VideoPlayerPage]
///
/// [probeKind] is an optional async function called when the stream format
/// cannot be determined from the URL alone (e.g. live streams with no
/// extension).  It should return 'flv', 'hls', or 'unknown'.
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
  Future<String> Function(String url)? probeKind,
}) async {
  // Web: always use in-app video_player.
  if (kIsWeb) {
    final page = _VideoPlayerPage(
      title: title,
      uri: uri,
      httpHeaders: httpHeaders,
      isLive: isLive,
      copyUrl: copyUrl ?? uri.toString(),
    );
    if (context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    }
    return;
  }

  // Native: detect FLV.
  bool isFlv = _isFlvUri(uri);

  // For live streams with opaque URLs, probe the server to detect format.
  // Treat 'unknown' as non-HLS and use VLC — VLC handles both FLV and HLS,
  // so it's a safe fallback for any live stream whose format can't be identified.
  if (isLive && !isFlv && probeKind != null) {
    final kind = await probeKind(uri.toString());
    isFlv = kind != 'hls';
  }

  if (isFlv) {
    if (context.mounted) await _openInVlcApp(context, uri);
    return;
  }

  // Native non-FLV: use AVPlayer / ExoPlayer.
  final playUrl = localFilePath != null
      ? 'file://$localFilePath'
      : (copyUrl ?? uri.toString());
  await CastBridge.instance.showNativePlayer(
    url: playUrl,
    title: title,
    headers: httpHeaders,
    isLive: isLive,
  );
}

/// Detect FLV by URL heuristics (fast path — no network call).
bool _isFlvUri(Uri uri) {
  final path = uri.path.toLowerCase();
  final str = uri.toString().toLowerCase();
  return path.endsWith('.flv') ||
      str.contains('.flv?') ||
      str.contains('.flv#') ||
      str.contains('type=flv') ||
      str.contains('format=flv');
}

/// Launch the stream URL in VLC for Mobile (iOS / Android).
/// Shows an install-prompt dialog if VLC is not installed.
Future<void> _openInVlcApp(BuildContext context, Uri streamUri) async {
  // vlc:// prefix tells VLC for Mobile to open the URL as a network stream.
  final vlcUri = Uri.parse('vlc://${streamUri.toString()}');
  bool launched = false;
  try {
    launched = await launchUrl(vlcUri, mode: LaunchMode.externalApplication);
  } catch (_) {}
  if (!launched && context.mounted) {
    await _showVlcInstallDialog(context);
  }
}

Future<void> _showVlcInstallDialog(BuildContext context) {
  const iosUrl = 'https://apps.apple.com/app/vlc-for-mobile/id650377962';
  const androidUrl =
      'https://play.google.com/store/apps/details?id=org.videolan.vlc';
  final storeUrl = defaultTargetPlatform == TargetPlatform.iOS ? iosUrl : androidUrl;

  return showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('需要 VLC'),
      content: const Text(
        '播放 FLV 格式视频需要安装 VLC for Mobile。\n\n'
        '安装完成后返回本应用重新播放即可。',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            Navigator.pop(ctx);
            await launchUrl(Uri.parse(storeUrl),
                mode: LaunchMode.externalApplication);
          },
          child: const Text('安装 VLC'),
        ),
      ],
    ),
  );
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
