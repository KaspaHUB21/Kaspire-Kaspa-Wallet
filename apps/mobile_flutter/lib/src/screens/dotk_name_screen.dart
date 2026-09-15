import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../services/dotk_service.dart';
import '../services/kaspa_api.dart';
import '../services/app_settings.dart';
import '../widgets/hub21_material.dart';

class DotkNameScreen extends StatefulWidget {
  const DotkNameScreen({super.key, required this.name});
  final DotkName name;
  @override
  State<DotkNameScreen> createState() => _DotkNameScreenState();
}

class _DotkNameScreenState extends State<DotkNameScreen> {
  late Future<DotkName> _verified;
  @override
  void initState() {
    super.initState();
    _verified = KaspaApi().dotk.resolve(widget.name.name);
  }

  Widget _field(String title, String value, {bool copy = false}) => Card(
        child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title,
                    style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SelectableText(value),
                if (copy)
                  Align(
                      alignment: Alignment.centerRight,
                      child: IconButton(
                        tooltip: 'Copy $title',
                        icon: const Icon(Icons.copy_rounded),
                        onPressed: () async {
                          await Clipboard.setData(ClipboardData(text: value));
                          if (mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(content: Text('Copied')));
                          }
                        },
                      )),
              ],
            )),
      );

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: Text(widget.name.name)),
        body: SafeArea(
            child: ListView(padding: const EdgeInsets.all(20), children: [
          _field('dot.k covenant name', widget.name.name, copy: true),
          FutureBuilder<DotkName>(
              future: _verified,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Card(
                      child: Padding(
                          padding: EdgeInsets.all(20),
                          child: Column(children: [
                            CircularProgressIndicator(),
                            SizedBox(height: 16),
                            Text(
                                'Verifying the current owner with the Kaspa node…'),
                          ])));
                }
                if (snapshot.hasError) {
                  return Card(
                      child: Padding(
                          padding: const EdgeInsets.all(16),
                          child: Column(children: [
                            Text(
                                'Ownership could not be verified.\n${snapshot.error}'),
                            TextButton(
                                onPressed: () => setState(() => _verified =
                                    KaspaApi().dotk.resolve(widget.name.name)),
                                child: Text(buttonLabel('RETRY'))),
                          ])));
                }
                final name = snapshot.requireData;
                return Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      const Card(
                          child: ListTile(
                              leading: Icon(Icons.verified_user_outlined),
                              title: Text('Ownership verified'),
                              subtitle: Text(
                                  'Native deed derivation + live node proof'))),
                      if (name.address != widget.name.address)
                        const Card(
                            child: Padding(
                                padding: EdgeInsets.all(16),
                                child: Text(
                                    'The owner has changed since this wallet listing was loaded. Refresh the wallet.'))),
                      _field('Payment address', name.address, copy: true),
                      _field('Deed address (not a payment recipient)',
                          name.deedAddress!),
                      _field('Registry covenant ID', DotkService.registry),
                      _field('Live deed outpoint', name.outpoint!),
                    ]);
              }),
          const SizedBox(height: 16),
          const Hub21Readable(
              child: Text(
                  'Use this .k name in the KAS or asset recipient field. Kaspire verifies its current owner again when preparing a payment.\n\nThis test supports name display and payment resolution. Registration, transfer of the name itself and custom records are not included.')),
          const SizedBox(height: 24),
        ])),
      );
}
