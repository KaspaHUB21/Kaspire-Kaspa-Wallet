import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/app_settings.dart';
import '../services/dapp_browser_catalog.dart';
import '../widgets/hub21_material.dart';
import 'dapp_browser_screen.dart';

class DappBrowserSelectionScreen extends StatelessWidget {
  const DappBrowserSelectionScreen({super.key});

  Widget _panel(Widget child) {
    final theme = AppSettings.theme.value;
    if ({KaspireTheme.hub21, KaspireTheme.glacier, KaspireTheme.neptune}
        .contains(theme)) {
      return Hub21Panel(
          radius: 20, padding: const EdgeInsets.all(18), child: child);
    }
    return Card(
        child: Padding(padding: const EdgeInsets.all(18), child: child));
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Kaspire Browser')),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(20), children: [
          for (final dapp in browserDapps) ...[
            Semantics(
                button: true,
                label: 'Open ${dapp.name}',
                child: InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => DappBrowserScreen(dapp: dapp),
                  )),
                  child: _panel(Row(children: [
                    SizedBox(
                        width: 52,
                        height: 52,
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(10),
                          child: dapp.logo.endsWith('.svg')
                              ? SvgPicture.asset(dapp.logo,
                                  placeholderBuilder: (_) =>
                                      const Icon(Icons.public),
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.public))
                              : Image.asset(dapp.logo,
                                  cacheWidth: 128,
                                  fit: BoxFit.contain,
                                  errorBuilder: (_, __, ___) =>
                                      const Icon(Icons.public)),
                        )),
                    const SizedBox(width: 16),
                    Expanded(
                        child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                          Text(dapp.name,
                              style: Theme.of(context).textTheme.titleLarge),
                          const SizedBox(height: 4),
                          Text(dapp.home.host,
                              style: Theme.of(context).textTheme.bodySmall),
                        ])),
                    const Icon(Icons.chevron_right),
                  ])),
                )),
            const SizedBox(height: 16),
          ],
          const SizedBox(height: 12),
          _panel(
              Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Integrate your dApp into Kaspire Browser',
                style: Theme.of(context).textTheme.titleLarge),
            const SizedBox(height: 12),
            Text.rich(TextSpan(children: [
              const TextSpan(
                  text: 'If you have a dApp that has already integrated '
                      'Kaspire App with WalletConnect v2 and want to get it listed '
                      'inside the Kaspire Browser, send a message to '),
              WidgetSpan(
                  alignment: PlaceholderAlignment.middle,
                  child: InkWell(
                    onTap: () async {
                      final opened = await launchUrl(
                          Uri.parse('https://x.com/kaspirewallet'),
                          mode: LaunchMode.externalApplication);
                      if (!opened && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(
                            const SnackBar(
                                content: Text(
                                    'Could not open x.com/kaspirewallet.')));
                      }
                    },
                    child: Text('https://x.com/kaspirewallet',
                        style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            decoration: TextDecoration.underline)),
                  )),
              const TextSpan(
                  text:
                      '. After review we will publish your dApp to the selection above.'),
            ])),
          ])),
          const SizedBox(height: 24),
        ])),
      );
}
