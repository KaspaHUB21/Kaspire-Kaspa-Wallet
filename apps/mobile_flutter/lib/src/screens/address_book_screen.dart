import 'package:flutter/material.dart';

import '../services/kaspa_api.dart';
import '../services/preferences_service.dart';
import '../theme.dart';
import '../services/app_settings.dart';

class AddressBookScreen extends StatefulWidget {
  const AddressBookScreen({super.key, this.selectAddress = false});
  final bool selectAddress;

  @override
  State<AddressBookScreen> createState() => _AddressBookScreenState();
}

class _AddressBookScreenState extends State<AddressBookScreen> {
  final _preferences = PreferencesService();
  List<AddressBookEntry> _entries = const [];

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final entries = await _preferences.getAddressBook();
    if (mounted) setState(() => _entries = entries);
  }

  Future<void> _add() async {
    await _edit();
  }

  Future<void> _edit([AddressBookEntry? existing]) async {
    final name = TextEditingController();
    final address = TextEditingController();
    if (existing != null) {
      name.text = existing.name;
      address.text = existing.address;
    }
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(existing == null ? 'Add contact' : 'Edit contact'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: name,
                decoration: const InputDecoration(labelText: 'Name'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: address,
                decoration: const InputDecoration(
                  labelText: 'Kaspa address or name.kas',
                ),
              ),
              if (error != null)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Text(
                    error!,
                    style: const TextStyle(color: Color(0xFFFF8A65)),
                  ),
                ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(buttonLabel('CANCEL')),
            ),
            FilledButton(
              onPressed: () async {
                try {
                  if (name.text.trim().isEmpty) {
                    throw StateError('Enter a contact name.');
                  }
                  final resolved = await KaspaApi().resolveWalletInput(
                    address.text,
                  );
                  await _preferences.saveAddressBookEntry(
                    AddressBookEntry(
                      id: existing?.id ??
                          'contact-${DateTime.now().microsecondsSinceEpoch}',
                      name: name.text.trim(),
                      address: resolved,
                    ),
                  );
                  if (context.mounted) Navigator.pop(context, true);
                } catch (value) {
                  setDialogState(
                      () => error = '$value'.replaceFirst('Bad state: ', ''));
                }
              },
              child: Text(buttonLabel('SAVE')),
            ),
          ],
        ),
      ),
    );
    name.dispose();
    address.dispose();
    if (saved == true) await _load();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('Address book')),
        floatingActionButton: FloatingActionButton.extended(
          onPressed: _add,
          icon: const Icon(Icons.person_add_alt_1_rounded),
          label: Text(buttonLabel('ADD CONTACT')),
        ),
        body: SafeArea(
          child: Column(
            children: [
              ValueListenableBuilder<bool>(
                valueListenable: AppSettings.recipientAllowlist,
                builder: (context, enabled, _) => SwitchListTile(
                  value: enabled,
                  onChanged: AppSettings.setRecipientAllowlist,
                  secondary: Icon(
                    Icons.verified_user_outlined,
                    color: KasVaultTheme.mint,
                  ),
                  title: const Text('Only allow saved recipients'),
                  subtitle: const Text(
                    'Blocks KAS, token, NFT and KNS transfers to addresses '
                    'that are not in this address book.',
                  ),
                ),
              ),
              const Divider(height: 1),
              Expanded(
                child: _entries.isEmpty
                    ? const Center(
                        child: Text(
                          'No saved contacts.',
                          style: TextStyle(color: KasVaultTheme.muted),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 96),
                        itemCount: _entries.length,
                        itemBuilder: (context, index) {
                          final entry = _entries[index];
                          return Card(
                            child: ListTile(
                              onTap: widget.selectAddress
                                  ? () => Navigator.pop(context, entry.address)
                                  : null,
                              leading: const CircleAvatar(
                                child: Icon(Icons.person_outline_rounded),
                              ),
                              title: Text(entry.name),
                              subtitle: Text(
                                entry.address,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              ),
                              trailing: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    tooltip: 'Edit contact',
                                    onPressed: () => _edit(entry),
                                    icon: const Icon(Icons.edit_outlined),
                                  ),
                                  IconButton(
                                    tooltip: 'Delete contact',
                                    onPressed: () async {
                                      await _preferences
                                          .removeAddressBookEntry(entry.id);
                                      await _load();
                                    },
                                    icon: const Icon(
                                        Icons.delete_outline_rounded),
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      );
}
