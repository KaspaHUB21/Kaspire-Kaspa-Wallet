import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import '../services/nexus_service.dart';
import '../services/network_settings.dart';
import '../services/native_security.dart';
import 'hub21_material.dart';
import '../screens/nexus_screen.dart';

class NexusBell extends StatefulWidget {
  const NexusBell({super.key, required this.address, this.notificationService});
  final String address;
  final NexusService? notificationService;
  @override
  State<NexusBell> createState() => _NexusBellState();
}

class _NexusBellState extends State<NexusBell>
    with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late NexusService service;
  late final animation = AnimationController(
      vsync: this, duration: const Duration(milliseconds: 1200));
  Timer? timer;
  int unread = 0;
  bool polling = false, foreground = true;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    service = widget.notificationService ?? NexusService(widget.address);
    timer = Timer.periodic(const Duration(seconds: 10), (_) => _poll());
    _poll();
  }

  @override
  void didUpdateWidget(covariant NexusBell old) {
    super.didUpdateWidget(old);
    if (old.address != widget.address) {
      service.close();
      NexusService.disconnect();
      service = widget.notificationService ?? NexusService(widget.address);
      unread = 0;
      animation.stop();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    foreground = state == AppLifecycleState.resumed;
    if (foreground) {
      _poll();
    } else {
      animation.stop();
    }
  }

  Future<void> _poll() async {
    if (polling ||
        !foreground ||
        NetworkSettings.network.value != KaspaNetwork.mainnet) {
      return;
    }
    polling = true;
    try {
      if (!service.connected &&
          (!NativeSecurity.internalNexusUnlocked || !await service.connect())) {
        return;
      }
      final rows = nexusRows(
          await service.request('dashboard/notifications', private: true));
      if (!mounted) return;
      setState(() => unread = rows.where((r) => r['readAt'] == null).length);
      if (unread > 0) {
        animation.repeat();
      } else {
        animation.stop();
      }
    } catch (_) {
      /* Keep notifications failures separate from wallet balance. */
    } finally {
      polling = false;
    }
  }

  @override
  void dispose() {
    timer?.cancel();
    animation.dispose();
    service.close();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
      animation: animation,
      builder: (context, _) => Transform.rotate(
          angle:
              unread > 0 ? math.sin(animation.value * math.pi * 6) * 0.15 : 0,
          child: Badge(
              isLabelVisible: unread > 0,
              label: Text('$unread'),
              child: KaspireHeaderIconFrame(
                  child: IconButton(
                      tooltip: 'Nexus Offers notifications',
                      icon: const Icon(Icons.notifications_outlined),
                      onPressed: () async {
                        await Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                                builder: (_) => NexusScreen(
                                    address: widget.address,
                                    initialView: 'notifications')));
                        _poll();
                      })))));
}
