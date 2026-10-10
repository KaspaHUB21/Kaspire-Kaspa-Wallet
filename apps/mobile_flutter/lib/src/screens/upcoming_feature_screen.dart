import 'package:flutter/material.dart';
import '../theme.dart';
import '../widgets/hub21_material.dart';
import 'dapp_browser_screen.dart';
import '../services/dapp_browser_catalog.dart';

class UpcomingFeatureScreen extends StatelessWidget {
  const UpcomingFeatureScreen({super.key, required this.vaults});
  final bool vaults;

  @override
  Widget build(BuildContext context) {
    final content =
        Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Icon(vaults ? Icons.lock_person_outlined : Icons.swap_horiz_rounded,
          size: 40, color: Theme.of(context).colorScheme.primary),
      const SizedBox(height: 20),
      Text(vaults ? 'Your money. Your rules.' : 'KCC20 DEX Swaps',
          style: Theme.of(context).textTheme.headlineMedium),
      const SizedBox(height: 20),
      Text(
          vaults
              ? 'Programmable self-custody and true sovereignty. Secured by covenant logic and Kaspa consensus.'
              : 'Available very soon',
          style: Theme.of(context).textTheme.bodyLarge),
      if (vaults) ...[
        const SizedBox(height: 20),
        const Text(
            'New Silverscript Vaults are releasing very soon directly inside Kaspire. In the meantime you can test the previous vaults from KasCoven Vaults inside Kaspire Browser.'),
        const SizedBox(height: 24),
        FilledButton.icon(
          icon: const Icon(Icons.public),
          label: const Text('Open KasCoven Vaults'),
          onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
            builder: (_) => DappBrowserScreen(
                dapp: browserDapps.singleWhere(
                    (dapp) => dapp.home.host == 'vaults.kaslab.space')),
          )),
        ),
      ],
    ]);
    return Scaffold(
      appBar: AppBar(title: Text(vaults ? 'Vaults' : 'Swap')),
      body: SafeArea(
          child: ListView(padding: const EdgeInsets.all(20), children: [
        if (KasVaultTheme.isDecorative)
          Hub21Panel(
              radius: 20, padding: const EdgeInsets.all(24), child: content)
        else
          Card(
              child:
                  Padding(padding: const EdgeInsets.all(24), child: content)),
        const SizedBox(height: 24),
      ])),
    );
  }
}
