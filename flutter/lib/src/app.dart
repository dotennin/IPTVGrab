import 'dart:async';

import 'package:flutter/material.dart';

import 'controller.dart';
import 'library_tab.dart';
import 'settings_tab.dart';
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
      title: 'Media Nest',
      theme: buildAppTheme(),
      home: AnimatedBuilder(
        animation: _controller,
        builder: (context, _) {
          return Scaffold(
            body: SafeArea(
              bottom: false,
              child: IndexedStack(
                index: _index,
                children: <Widget>[
                  // 0 – Library
                  LibraryTab(
                    controller: _controller,
                    onUseChannel: () => setState(() => _index = 1),
                  ),
                  // 1 – Activity
                  TasksTab(controller: _controller),
                  // 2 – Settings
                  SettingsTab(controller: _controller),
                ],
              ),
            ),
            bottomNavigationBar: NavigationBar(
              selectedIndex: _index,
              destinations: const <NavigationDestination>[
                NavigationDestination(
                  icon: Icon(Icons.video_library_rounded),
                  selectedIcon: Icon(Icons.video_library_rounded),
                  label: 'Library',
                ),
                NavigationDestination(
                  icon: Icon(Icons.task_alt),
                  label: 'Activity',
                ),
                NavigationDestination(
                  icon: Icon(Icons.settings_rounded),
                  selectedIcon: Icon(Icons.settings_rounded),
                  label: 'Settings',
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
