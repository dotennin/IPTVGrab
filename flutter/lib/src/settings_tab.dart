import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'source_settings_page.dart';
import 'theme.dart';

/// App Settings tab — the rightmost item in the bottom navigation.
/// Provides access to stream source management and other configuration.
class SettingsTab extends StatelessWidget {
  const SettingsTab({super.key, required this.controller});

  final AppController controller;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar(
            pinned: true,
            floating: false,
            elevation: 0,
            title: const Text(
              'Settings',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 22),
            ),
            centerTitle: false,
          ),
          SliverList(
            delegate: SliverChildListDelegate([
              const SizedBox(height: 8),
              // ── Sources ────────────────────────────────────────────────
              _SectionHeader(label: 'Sources'),
              _SettingsRow(
                icon: Icons.playlist_add_rounded,
                color: appPrimary,
                label: 'Stream Sources',
                subtitle: 'Manage M3U playlists and source lists',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) =>
                        SourceSettingsPage(controller: controller),
                  ),
                ),
              ),
              const _Divider(),

              // ── Connection ─────────────────────────────────────────────
              _SectionHeader(label: 'Connection'),
              AnimatedBuilder(
                animation: controller,
                builder: (context, _) {
                  final connected = controller.isConnected;
                  final error = controller.localServerError;
                  final baseUrl = controller.api.baseUrl;

                  if (error != null) {
                    return _SettingsRow(
                      icon: Icons.error_rounded,
                      color: Colors.red,
                      label: 'Connection Failed',
                      subtitle: error,
                      trailing: TextButton(
                        onPressed: () =>
                            unawaited(controller.retryLocalServer()),
                        child: const Text('Retry'),
                      ),
                      onTap: null,
                    );
                  }

                  return _SettingsRow(
                    icon: Icons.wifi_rounded,
                    color: connected ? Colors.green : Colors.orange,
                    label: connected ? 'Connected' : 'Connecting…',
                    subtitle:
                        baseUrl.isNotEmpty ? baseUrl : 'Starting local server…',
                    trailing: connected
                        ? const Icon(Icons.circle, size: 10, color: Colors.green)
                        : const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                    onTap: null,
                  );
                },
              ),
              const SizedBox(height: 16),
            ]),
          ),
        ],
      ),
    );
  }
}

// ── Section Header ────────────────────────────────────────────────────────────

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 6),
      child: Text(
        label.toUpperCase(),
        style: Theme.of(context).textTheme.labelSmall?.copyWith(
              color: appTextMuted,
              letterSpacing: 1.0,
              fontWeight: FontWeight.w600,
            ),
      ),
    );
  }
}

// ── Settings Row ──────────────────────────────────────────────────────────────

class _SettingsRow extends StatelessWidget {
  const _SettingsRow({
    required this.icon,
    required this.color,
    required this.label,
    this.subtitle,
    this.trailing,
    this.onTap,
  });
  final IconData icon;
  final Color color;
  final String label;
  final String? subtitle;
  final Widget? trailing;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 2),
      leading: Container(
        width: 40,
        height: 40,
        decoration: BoxDecoration(
          color: color.withAlpha((0.15 * 255).round()),
          borderRadius: BorderRadius.circular(10),
        ),
        child: Icon(icon, color: color, size: 22),
      ),
      title: Text(
        label,
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
              fontWeight: FontWeight.w500,
            ),
      ),
      subtitle: subtitle != null
          ? Text(
              subtitle!,
              style: TextStyle(color: appTextMuted, fontSize: 12),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            )
          : null,
      trailing: trailing ??
          (onTap != null
              ? Icon(Icons.chevron_right_rounded, color: appTextMuted)
              : null),
      onTap: onTap,
    );
  }
}

class _Divider extends StatelessWidget {
  const _Divider();

  @override
  Widget build(BuildContext context) =>
      const Divider(height: 1, indent: 72, endIndent: 0);
}
