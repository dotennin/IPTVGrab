import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'download_tab.dart';
import 'playlists_tab.dart';
import 'tasks_tab.dart';
import 'theme.dart';

class M3u8FlutterClientApp extends StatefulWidget {
  const M3u8FlutterClientApp({super.key});

  @override
  State<M3u8FlutterClientApp> createState() => _M3u8FlutterClientAppState();
}

class _M3u8FlutterClientAppState extends State<M3u8FlutterClientApp>
    with WidgetsBindingObserver {
  late final AppController _controller;
  int _index = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _controller = AppController();
    unawaited(_controller.bootstrapLocalServer());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    unawaited(_controller.handleAppLifecycleState(state));
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'MediaNest',
      theme: buildAppTheme(),
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Scaffold(
            appBar: AppBar(
              title: const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text('MediaNest',
                      style:
                          TextStyle(fontSize: 18, fontWeight: FontWeight.bold)),
                  Text(
                    'Personal media archive',
                    style: TextStyle(fontSize: 12, color: appTextMuted),
                  ),
                ],
              ),
              actions: <Widget>[],
            ),
            body: IndexedStack(
              index: _index,
              children: <Widget>[
                PlaylistsTab(
                  controller: _controller,
                  onUseChannel: () => setState(() => _index = 2),
                ),
                TasksTab(controller: _controller),
                DownloadTab(
                  controller: _controller,
                  onOpenTasks: () => setState(() => _index = 1),
                ),
              ],
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.playlist_play),
                  label: 'Sources',
                ),
                NavigationDestination(
                  icon: Icon(Icons.task_alt),
                  label: 'Activity',
                ),
                NavigationDestination(
                  icon: Icon(Icons.download),
                  label: 'Library',
                ),
              ],
              onDestinationSelected: (index) => setState(() => _index = index),
            ),
          );
        },
      ),
    );
  }
}
