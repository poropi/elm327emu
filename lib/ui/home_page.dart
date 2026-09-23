import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../app/emulator_controller.dart';
import 'common.dart';
import 'connection_tab.dart';
import 'dtc_tab.dart';
import 'ecu_tab.dart';
import 'faults_tab.dart';
import 'log_tab.dart';
import 'vehicle_tab.dart';

class HomePage extends StatelessWidget {
  const HomePage({super.key});

  static const tabs = ['接続', '車両', 'DTC', 'ECU', '障害', 'ログ'];

  @override
  Widget build(BuildContext context) {
    return DefaultTabController(
      length: tabs.length,
      child: Builder(
        builder: (context) {
          final c = context.watch<EmulatorController>();
          return Scaffold(
            backgroundColor: AppColors.tile,
            appBar: AppBar(
              backgroundColor: AppColors.teal,
              foregroundColor: Colors.white,
              title: const Text('ELM327 Emulator'),
              actions: [
                Padding(
                  padding: const EdgeInsets.only(right: 12),
                  child: Chip(
                    label: Text(
                      c.headlineStatus,
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                ),
              ],
              bottom: TabBar(
                labelColor: Colors.white,
                unselectedLabelColor: AppColors.tabInactive,
                indicatorColor: Colors.white,
                tabs: [for (final t in tabs) Tab(text: t)],
              ),
            ),
            body: TabBarView(
              children: [
                ConnectionTab(
                  onShowLog: () => DefaultTabController.of(
                    context,
                  ).animateTo(tabs.indexOf('ログ')),
                ),
                const VehicleTab(),
                const DtcTab(),
                const EcuTab(),
                const FaultsTab(),
                const LogTab(),
              ],
            ),
          );
        },
      ),
    );
  }
}
