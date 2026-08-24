import 'dart:async';
import 'dart:convert';

import 'package:app_links/app_links.dart';
import 'package:flutter/material.dart';
import 'package:reown_walletkit/reown_walletkit.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'number_format.dart';
import 'kaspa_address.dart';
import 'screens/home_shell.dart';
import 'screens/onboarding_screen.dart';
import 'services/dapp_session_service.dart';
import 'services/activity_store.dart';
import 'services/kaspa_api.dart';
import 'services/native_security.dart';
import 'services/preferences_service.dart';
import 'services/app_settings.dart';
import 'services/signer_service.dart';
import 'services/update_service.dart';
import 'services/network_settings.dart';
import 'services/evm_api.dart';
import 'theme.dart';

class KasVaultApp extends StatefulWidget {
  const KasVaultApp({super.key});

  @override
  State<KasVaultApp> createState() => _KasVaultAppState();
}

class _KasVaultAppState extends State<KasVaultApp> with WidgetsBindingObserver {
  final _preferences = PreferencesService();
  final _security = NativeSecurity();
  final _dapps = DappSessionService.instance;
  final _appLinks = AppLinks();
  final _navigatorKey = GlobalKey<NavigatorState>();
  StreamSubscription<Uri>? _linkSubscription;
  StreamSubscription<SessionProposalEvent>? _proposalSubscription;
  StreamSubscription<SessionRequestEvent>? _requestSubscription;
  Future<void> _dappQueue = Future.value();
  final Set<String> _handledAppLinks = {};
  final Set<String> _handledRequestIds = {};
  late Future<String?> _address;
  DateTime _lastActivity = DateTime.now();
  DateTime? _lastPersistedActivity;
  DateTime? _backgroundedAt;
  Timer? _inactivityTimer;
  Timer? _dappStateTimer;
  String? _lastDappAddress;
  KaspaNetwork? _lastDappNetwork;
  final Map<String, int> _lastDappBalances = {};
  bool _locked = false;
  bool _unlocking = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _address = _loadInitialAddress();
    _proposalSubscription = _dapps.proposals.listen(
      (event) => _enqueueDapp(() => _handleProposal(event)),
    );
    _requestSubscription = _dapps.requests.listen(
      (event) => _enqueueDapp(() => _handleRequest(event)),
    );
    _linkSubscription = _appLinks.uriLinkStream.listen(_queueAppLink);
    unawaited(_loadInitialAppLink());
    _dapps.initialize();
    unawaited(UpdateService.instance.checkIfDue());
    _inactivityTimer = Timer.periodic(
      const Duration(seconds: 30),
      (_) => _checkInactivity(),
    );
    _dappStateTimer = Timer.periodic(
      const Duration(seconds: 15),
      (_) => unawaited(_publishDappState()),
    );
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _inactivityTimer?.cancel();
    _dappStateTimer?.cancel();
    _linkSubscription?.cancel();
    _proposalSubscription?.cancel();
    _requestSubscription?.cancel();
    super.dispose();
  }

  Future<void> _publishDappState() async {
    if (_dapps.activeSessions().isEmpty) {
      _lastDappAddress = null;
      _lastDappNetwork = null;
      _lastDappBalances.clear();
      return;
    }
    final storedAddress = await _preferences.getAddress();
    final network = NetworkSettings.network.value;
    if (_lastDappAddress != null && storedAddress != _lastDappAddress) {
      for (final chain in DappSessionService.supportedKaspaChains) {
        final address = storedAddress == null
            ? null
            : kaspaAddressWithPrefix(
                storedAddress,
                chain == DappSessionService.testnet10ChainId
                    ? 'kaspatest'
                    : 'kaspa',
              );
        await _dapps.emitKaspaEvent(
          'accountsChanged',
          address == null ? const <String>[] : <String>[address],
          forChainId: chain,
        );
      }
    }
    if (_lastDappNetwork != null &&
        network != _lastDappNetwork &&
        (network == KaspaNetwork.mainnet || network == KaspaNetwork.tn10)) {
      final chain = network == KaspaNetwork.tn10
          ? DappSessionService.testnet10ChainId
          : DappSessionService.chainId;
      await _dapps.emitKaspaEvent(
        'networkChanged',
        network == KaspaNetwork.tn10 ? 'testnet-10' : network.name,
        forChainId: chain,
      );
    }
    _lastDappAddress = storedAddress;
    _lastDappNetwork = network;
    if (network != KaspaNetwork.mainnet && network != KaspaNetwork.tn10) {
      _lastDappBalances.clear();
      return;
    }
    final activeChain = network == KaspaNetwork.tn10
        ? DappSessionService.testnet10ChainId
        : DappSessionService.chainId;
    final sessionAddresses = _dapps
        .activeSessions()
        .keys
        .map((topic) => _dapps.addressForTopic(topic, chainId: activeChain))
        .whereType<String>()
        .toSet();
    for (final address in sessionAddresses) {
      try {
        final sompi = await KaspaApi().loadBalanceSompi(address);
        final previous = _lastDappBalances[address];
        if (previous != null && previous != sompi) {
          await _dapps.emitKaspaEvent(
              'balanceChanged',
              <String, Object?>{
                'current': sompi / 100000000,
                'pending': 0,
                'outgoing': 0,
              },
              forChainId: activeChain);
        }
        _lastDappBalances[address] = sompi;
      } catch (_) {
        // A temporary node failure must not terminate the WalletConnect session.
      }
    }
    _lastDappBalances.removeWhere(
      (address, _) => !sessionAddresses.contains(address),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused ||
        state == AppLifecycleState.detached ||
        state == AppLifecycleState.hidden) {
      _backgroundedAt ??= DateTime.now();
      unawaited(AppSettings.recordBackgroundedAt(_backgroundedAt!));
      if (AppSettings.lockMinutes.value == 0 && mounted) {
        setState(() => _locked = true);
      }
      return;
    }
    if (state == AppLifecycleState.resumed) {
      final since = _backgroundedAt;
      _backgroundedAt = null;
      final minutes = AppSettings.lockMinutes.value;
      if (since != null &&
          (minutes == 0 ||
              DateTime.now().difference(since) >= Duration(minutes: minutes)) &&
          mounted) {
        setState(() => _locked = true);
      }
    }
  }

  void _recordActivity() {
    final now = DateTime.now();
    _lastActivity = now;
    if (_lastPersistedActivity == null ||
        now.difference(_lastPersistedActivity!) > const Duration(seconds: 15)) {
      _lastPersistedActivity = now;
      unawaited(AppSettings.recordBackgroundedAt(now));
    }
  }

  void _checkInactivity() {
    final minutes = AppSettings.lockMinutes.value;
    if (minutes == 0 || _locked || !mounted) return;
    if (DateTime.now().difference(_lastActivity) >=
        Duration(minutes: minutes)) {
      setState(() => _locked = true);
    }
  }

  Future<void> _unlock() async {
    if (_unlocking) return;
    final context = _navigatorKey.currentContext;
    if (context == null) return;
    setState(() => _unlocking = true);
    final authenticated = await _security.authenticate(
      context,
      'Unlock Kaspire',
    );
    if (!mounted) return;
    setState(() {
      _unlocking = false;
      if (authenticated) {
        _locked = false;
        _lastActivity = DateTime.now();
        _lastPersistedActivity = _lastActivity;
        unawaited(AppSettings.recordBackgroundedAt(_lastActivity));
      }
    });
  }

  void _enqueueDapp(Future<void> Function() operation) {
    _dappQueue = _dappQueue.then((_) => operation()).catchError((_) {});
  }

  void _queueAppLink(Uri link) {
    final key = link.toString();
    if (!_handledAppLinks.add(key)) return;
    if (_handledAppLinks.length > 32) {
      _handledAppLinks.remove(_handledAppLinks.first);
    }
    _enqueueDapp(() => _handleLink(link));
  }

  Future<void> _loadInitialAppLink() async {
    try {
      final link = await _appLinks.getInitialLink();
      if (link != null) _queueAppLink(link);
    } catch (_) {
      // A later uriLinkStream event can still deliver a resumed-app link.
    }
  }

  Future<BuildContext?> _contextWhenReady() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final context = _navigatorKey.currentContext;
      if (context != null) return context;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return null;
  }

  Future<void> _handleLink(Uri link) async {
    try {
      await _dapps.handleAppLink(link);
    } catch (error) {
      final context = await _contextWhenReady();
      if (context == null || !context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            error
                .toString()
                .replaceFirst('FormatException: ', '')
                .replaceFirst('Bad state: ', ''),
          ),
        ),
      );
    }
  }

  Future<void> _handleProposal(SessionProposalEvent event) async {
    final problem = _dapps.proposalProblem(event);
    final evmChains = _dapps.requestedEvmChains(event);
    final kaspaChains = _dapps.requestedKaspaChains(event);
    final address = await _preferences.getAddress();
    final methods = _dapps.requestedMethods(event).toList()..sort();
    final needsKey = methods.any((method) =>
        method != 'kaspa_getAccounts' &&
        method != 'eth_accounts' &&
        method != 'eth_requestAccounts' &&
        method != 'eth_chainId' &&
        method != 'wallet_switchEthereumChain');
    final hasKey =
        address != null && await _security.hasNativeWalletFor(address);
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) {
      await _dapps.reject(event, message: 'Wallet UI is unavailable.');
      return;
    }
    if (problem != null || address == null || (needsKey && !hasKey)) {
      final message = problem ??
          (address == null
              ? 'No wallet is open.'
              : 'This dApp requires a signing wallet, but the selected address is watch-only.');
      await _dapps.reject(event, message: message);
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('dApp connection rejected: $message')),
      );
      return;
    }
    final metadata = event.params.proposer.metadata;
    final verification = event.verifyContext;
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: const Text('Connect dApp?'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                metadata.name,
                style:
                    const TextStyle(fontSize: 20, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 4),
              SelectableText(metadata.url),
              const SizedBox(height: 12),
              Text(metadata.description),
              const SizedBox(height: 16),
              _DappVerification(context: verification),
              const SizedBox(height: 16),
              const Text('Requested permissions:',
                  style: TextStyle(fontWeight: FontWeight.w800)),
              const SizedBox(height: 6),
              ...methods.map((method) => Text('• ${_methodLabel(method)}')),
              ...kaspaChains.map((chain) => Text(
                  '• Network: ${chain == DappSessionService.testnet10ChainId ? 'Kaspa Testnet 10' : 'Kaspa Mainnet'}')),
              ...evmChains.map((chain) => Text(
                  '• Network: ${chain == DappSessionService.kasplexChainId ? 'Kasplex L2' : 'Igra L2'}')),
              const SizedBox(height: 14),
              SelectableText('Wallet: $address'),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(buttonLabel('REJECT')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(buttonLabel('CONNECT')),
          ),
        ],
      ),
    );
    if (approved == true) {
      final evmAddress =
          evmChains.isEmpty ? null : await _security.getEvmAddress();
      await _dapps.approve(event, address, evmAddress: evmAddress);
    } else {
      await _dapps.reject(event);
    }
  }

  String _methodLabel(String method) => switch (method) {
        'kaspa_getAccounts' => 'View the approved Kaspa address',
        'kaspa_getNetwork' => 'Read the approved Kaspa network',
        'kaspa_getBalance' => 'Read the current KAS balance',
        'kaspa_getPublicKey' => 'Read the approved Kaspa public key',
        'kaspa_switchNetwork' => 'Switch between Kaspa Mainnet and Testnet 10',
        'kaspa_signPersonal' => 'Request KIP-5 personal-message signatures',
        'kaspa_signAuth' =>
          'Request an authentication signature and public key',
        'kaspa_sendTransaction' => 'Request KAS payments',
        'kaspa_sendKrc20' => 'Request reviewed KRC-20 transfers',
        'kaspa_sendKrc721' => 'Request reviewed KRC-721 NFT transfers',
        'kaspa_sendKcc20' => 'Request verified KCC20 covenant transfers',
        'kaspa_signPskt' =>
          'Request reviewed partial transaction signatures (PSKT)',
        'kaspa_signVaultTransaction' =>
          'Request policy-verified vault heartbeat signatures',
        'eth_accounts' => 'View the approved L2 address',
        'eth_requestAccounts' => 'View the approved L2 address',
        'eth_chainId' => 'Read the approved L2 network',
        'wallet_switchEthereumChain' => 'Switch between Kasplex and Igra',
        'eth_sendTransaction' => 'Request a reviewed L2 transaction',
        _ => method,
      };

  Future<void> _handleRequest(SessionRequestEvent request) async {
    final requestKey = '${request.topic}:${request.id}';
    if (!_handledRequestIds.add(requestKey)) {
      await _dapps.respondError(request, 'Duplicate request rejected.',
          code: -32600);
      return;
    }
    if (_handledRequestIds.length > 1024) {
      _handledRequestIds.remove(_handledRequestIds.first);
    }
    try {
      if (request.chainId == DappSessionService.kasplexChainId ||
          request.chainId == DappSessionService.igraChainId) {
        await _handleEvmRequest(request);
        return;
      }
      if (!DappSessionService.supportedKaspaChains.contains(request.chainId) ||
          !DappSessionService.supportedMethods.contains(request.method)) {
        await _dapps.respondError(request, 'Unsupported Kaspa request.',
            code: -32601);
        return;
      }
      final requestedNetwork =
          request.chainId == DappSessionService.testnet10ChainId
              ? KaspaNetwork.tn10
              : KaspaNetwork.mainnet;
      if (NetworkSettings.network.value != requestedNetwork) {
        await NetworkSettings.setNetwork(requestedNetwork);
        _lastDappNetwork = requestedNetwork;
        await _dapps.emitKaspaEvent(
          'networkChanged',
          requestedNetwork == KaspaNetwork.tn10 ? 'testnet-10' : 'mainnet',
          forChainId: request.chainId,
        );
      }
      final address =
          _dapps.addressForTopic(request.topic, chainId: request.chainId);
      if (address == null) {
        await _dapps.respondError(request, 'Session account is invalid.',
            code: -32602);
        return;
      }
      switch (request.method) {
        case 'kaspa_getAccounts':
          await _dapps.respondResult(request, [address]);
        case 'kaspa_getNetwork':
          await _dapps.respondResult(request,
              requestedNetwork == KaspaNetwork.tn10 ? 'testnet-10' : 'mainnet');
        case 'kaspa_getBalance':
          final sompi = await KaspaApi().loadBalanceSompi(address);
          await _dapps.respondResult(request, <String, Object?>{
            'current': sompi / 100000000,
            'pending': 0,
            'outgoing': 0,
          });
        case 'kaspa_getPublicKey':
          await _dapps.respondResult(
              request, await _security.publicKey(address));
        case 'kaspa_switchNetwork':
          await _handleKaspaNetworkSwitch(request);
        case 'kaspa_signPersonal':
          await _handlePersonalSign(request, address);
        case 'kaspa_signAuth':
          await _handlePersonalSign(request, address, includePublicKey: true);
        case 'kaspa_sendTransaction':
          await _handleDappPayment(request, address);
        case 'kaspa_sendKrc20':
          if (requestedNetwork == KaspaNetwork.tn10) {
            throw const FormatException(
                'KRC-20 transfers are not supported on Testnet 10.');
          }
          await _handleDappKrc20(request, address);
        case 'kaspa_sendKrc721':
          if (requestedNetwork == KaspaNetwork.tn10) {
            throw const FormatException(
                'KRC-721 transfers are not supported on Testnet 10.');
          }
          await _handleDappKrc721(request, address);
        case 'kaspa_sendKcc20':
          if (requestedNetwork == KaspaNetwork.tn10) {
            throw const FormatException(
                'KCC20 transfers are not supported on Testnet 10.');
          }
          await _handleDappKcc20(request, address);
        case 'kaspa_signPskt':
          await _handlePskt(request, address);
        case 'kaspa_signVaultTransaction':
          if (requestedNetwork == KaspaNetwork.tn10) {
            throw const FormatException(
                'The typed vault policy is available on Mainnet only.');
          }
          await _handleVaultTransaction(request, address);
      }
    } catch (error) {
      final message = error is FormatException
          ? error.message
          : 'Request failed safely inside Kaspire.';
      await _dapps.respondError(request, message, code: -32000);
      final context = await _contextWhenReady();
      if (context != null && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text("dApp request rejected: $message")),
        );
      }
    }
  }

  Future<void> _handleKaspaNetworkSwitch(SessionRequestEvent request) async {
    final params = _paramsMap(request.params);
    if (params.keys.any((key) => key != 'network')) {
      throw const FormatException('Unknown network-switch field.');
    }
    final network = params['network'];
    if (network != 'mainnet' && network != 'testnet-10') {
      throw const FormatException(
          'Only mainnet and testnet-10 can be selected.');
    }
    final chain = network == 'testnet-10'
        ? DappSessionService.testnet10ChainId
        : DappSessionService.chainId;
    if (!_dapps.sessionSupportsKaspaChain(request.topic, chain)) {
      throw const FormatException(
          'The requested network was not approved for this session.');
    }
    final target =
        network == 'testnet-10' ? KaspaNetwork.tn10 : KaspaNetwork.mainnet;
    if (NetworkSettings.network.value != target) {
      await NetworkSettings.setNetwork(target);
      _lastDappNetwork = target;
      await _dapps.emitKaspaEvent(
        'networkChanged',
        network,
        forChainId: chain,
      );
    }
    await _dapps.respondResult(request, network);
  }

  Future<void> _handleEvmRequest(SessionRequestEvent request) async {
    if (!DappSessionService.evmMethods.contains(request.method)) {
      await _dapps.respondError(request, 'Unsupported L2 request.',
          code: -32601);
      return;
    }
    final network = request.chainId == DappSessionService.kasplexChainId
        ? KaspaNetwork.kasplex
        : KaspaNetwork.igra;
    await NetworkSettings.setNetwork(network);
    final address =
        _dapps.evmAddressForTopic(request.topic, chainId: request.chainId);
    if (address == null) {
      throw const FormatException('Session L2 account is invalid.');
    }
    if (request.method == 'eth_accounts' ||
        request.method == 'eth_requestAccounts') {
      await _dapps.respondResult(request, [address]);
      return;
    }
    if (request.method == 'eth_chainId') {
      await _dapps.respondResult(
          request, '0x${EvmNetworkConfig.current.chainId.toRadixString(16)}');
      return;
    }
    if (request.method == 'wallet_switchEthereumChain') {
      final params = request.params;
      final first = params is List && params.isNotEmpty ? params.first : null;
      final requested =
          first is Map ? '${first['chainId'] ?? ''}'.toLowerCase() : '';
      final expected =
          '0x${EvmNetworkConfig.current.chainId.toRadixString(16)}';
      if (requested != expected) {
        throw const FormatException(
            'The requested L2 network is not approved for this session.');
      }
      await _dapps.respondResult(request, null);
      return;
    }
    final params = request.params;
    final txRaw = params is List && params.isNotEmpty ? params.first : null;
    if (txRaw is! Map) {
      throw const FormatException('Invalid L2 transaction request.');
    }
    final tx = txRaw.map((key, value) => MapEntry(key.toString(), value));
    final from = '${tx['from'] ?? ''}';
    final to = '${tx['to'] ?? ''}';
    if (from.toLowerCase() != address.toLowerCase() ||
        !RegExp(r'^0x[0-9a-fA-F]{40}$').hasMatch(to)) {
      throw const FormatException('Invalid L2 sender or recipient.');
    }
    final api = EvmApi();
    BigInt hexValue(Object? value) {
      final raw = '${value ?? '0x0'}';
      return BigInt.parse(
          raw.replaceFirst('0x', '').isEmpty ? '0' : raw.replaceFirst('0x', ''),
          radix: 16);
    }

    final value = hexValue(tx['value']);
    final data = '${tx['data'] ?? tx['input'] ?? ''}';
    final nonce =
        tx['nonce'] == null ? await api.nonce(address) : hexValue(tx['nonce']);
    final gasPrice = tx['gasPrice'] == null
        ? await api.gasPrice()
        : hexValue(tx['gasPrice']);
    final gas = tx['gas'] == null
        ? await api.estimateGas(address, to, value.toString(), data)
        : hexValue(tx['gas']);
    final requestMap = <String, Object?>{
      'walletAddress': await _preferences.getAddress() ?? '',
      'from': address,
      'to': to,
      'recipient': to,
      'valueWei': value.toString(),
      'nonce': nonce.toInt(),
      'gasLimit': gas.toInt(),
      'gasPriceWei': gasPrice.toString(),
      'chainId': EvmNetworkConfig.current.chainId,
      'data': data,
      'tokenSymbol': EvmNetworkConfig.current.nativeSymbol,
      'displayAmount': formatUnits(value, 18, visible: 18),
    };
    final prepared = await _security.prepareEvmTransaction(requestMap);
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) {
      throw const FormatException('Wallet UI is unavailable.');
    }
    final approved = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => AlertDialog(
                title: Text(
                    '${_dapps.dappName(request.topic)} requests an L2 transaction'),
                content: SelectableText(
                    'Network\n${EvmNetworkConfig.current.name}\n\nFrom\n$address\n\nTo / contract\n$to\n\nValue\n${formatUnits(value, 18, visible: 18)} ${EvmNetworkConfig.current.nativeSymbol}\n\nMaximum network fee\n${formatUnits(gas * gasPrice, 18, visible: 18)} ${EvmNetworkConfig.current.nativeSymbol}\n\nGas\n$gas\n\nData\n${data.isEmpty ? 'None' : data}'),
                actions: [
                  TextButton(
                      onPressed: () => Navigator.pop(context, false),
                      child: const Text('Reject')),
                  FilledButton(
                      onPressed: () => Navigator.pop(context, true),
                      child: const Text('Sign'))
                ]));
    if (approved != true) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }
    final signed = await _security.signEvmTransaction(
        requestMap, '${prepared['reviewHash']}');
    final hash = await api.broadcast('${signed['rawTransaction']}');
    await _dapps.respondResult(request, hash);
  }

  Map<String, Object?> _paramsMap(dynamic params) {
    if (params is! Map) {
      throw const FormatException('Invalid request parameters.');
    }
    return params.map((key, value) => MapEntry(key.toString(), value));
  }

  Future<void> _requireActiveSessionAddress(String address) async {
    if (await _preferences.getAddress() !=
        NetworkSettings.storageAddress(address)) {
      throw const FormatException(
        'The WalletConnect account is no longer the active wallet. Reconnect the dApp.',
      );
    }
  }

  Future<void> _handlePersonalSign(SessionRequestEvent request, String address,
      {bool includePublicKey = false}) async {
    await _requireActiveSessionAddress(address);
    final params = _paramsMap(request.params);
    if (params.keys.any((key) => key != 'message' && key != 'address')) {
      throw const FormatException('Unknown message-signing field.');
    }
    final message = params['message'];
    final requestedAddress = params['address'] ?? address;
    if (message is! String ||
        message.length > 4096 ||
        requestedAddress != address) {
      throw const FormatException('Invalid personal-message request.');
    }
    if (!await _security.hasNativeWalletFor(address)) {
      throw const FormatException('The session wallet is watch-only.');
    }
    final selectedAddressBeforeApproval = await _preferences.getAddress();
    final networkBeforeApproval = NetworkSettings.network.value;
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) {
      throw const FormatException('Wallet UI is unavailable.');
    }
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('${_dapps.dappName(request.topic)} wants a signature'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                  'Read the complete message. A signature can prove wallet ownership.'),
              const SizedBox(height: 14),
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: KasVaultTheme.ink,
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(color: KasVaultTheme.line),
                ),
                child: SingleChildScrollView(child: SelectableText(message)),
              ),
              const SizedBox(height: 12),
              SelectableText('Signing address:\n$address'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(buttonLabel('REJECT'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(buttonLabel('SIGN'))),
        ],
      ),
    );
    if (approved != true) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }
    if (!context.mounted) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }
    if (NetworkSettings.network.value != networkBeforeApproval ||
        await _preferences.getAddress() != selectedAddressBeforeApproval) {
      throw const FormatException(
        'Wallet account or network changed during approval. Build a fresh request.',
      );
    }
    final signature = await _security.signPersonalMessage(address, message);
    await _dapps.respondResult(
      request,
      includePublicKey
          ? <String, Object?>{
              'publicKey': await _security.publicKey(address),
              'signedMessage': signature,
              'signature': signature,
            }
          : signature,
    );
  }

  Future<void> _handleDappPayment(
    SessionRequestEvent request,
    String address,
  ) async {
    await _requireActiveSessionAddress(address);
    final params = _paramsMap(request.params);
    if (params.keys.any(
      (key) =>
          key != 'to' &&
          key != 'amountSompi' &&
          key != 'from' &&
          key != 'priorityFeeSompi',
    )) {
      throw const FormatException('Unknown payment field.');
    }
    final recipient = params['to'];
    final rawAmount = params['amountSompi'];
    final from = params['from'] ?? address;
    final rawPriorityFee = params['priorityFeeSompi'] ?? 0;
    const maxKasSupplySompi = 21000000 * 100000000;
    final amount = rawAmount is int
        ? rawAmount
        : rawAmount is String
            ? int.tryParse(rawAmount)
            : null;
    final priorityFeeSompi = rawPriorityFee is int
        ? rawPriorityFee
        : rawPriorityFee is String
            ? int.tryParse(rawPriorityFee)
            : null;
    final expectedPrefix = NetworkSettings.isTestnet ? 'kaspatest:' : 'kaspa:';
    if (recipient is! String ||
        !recipient.startsWith(expectedPrefix) ||
        !RegExp(r'^kaspa(test)?:[a-z0-9]{61,63}$').hasMatch(recipient) ||
        amount == null ||
        amount <= 0 ||
        amount > maxKasSupplySompi ||
        priorityFeeSompi == null ||
        priorityFeeSompi < 0 ||
        priorityFeeSompi > 100000000 ||
        from != address) {
      throw const FormatException('Invalid KAS payment request.');
    }
    if (!await _security.hasNativeWalletFor(address)) {
      throw const FormatException('The session wallet is watch-only.');
    }
    final api = KaspaApi();
    final results = await Future.wait([
      api.loadUtxos(address),
      api.loadFeeRate(),
    ]);
    var feeRate = results[1] as double;
    var payment = await SignerService().prepare(
      sender: address,
      recipient: recipient,
      amountSompi: amount,
      feeRate: feeRate,
      utxosJson: results[0] as String,
    );
    if (priorityFeeSompi > 0) {
      feeRate =
          (feeRate + priorityFeeSompi / payment.mass).clamp(1, 1000).toDouble();
      payment = await SignerService().prepare(
        sender: address,
        recipient: recipient,
        amountSompi: amount,
        feeRate: feeRate,
        utxosJson: results[0] as String,
      );
    }
    final selectedAddressBeforeApproval = await _preferences.getAddress();
    final networkBeforeApproval = NetworkSettings.network.value;
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) {
      throw const FormatException('Wallet UI is unavailable.');
    }
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('${_dapps.dappName(request.topic)} requests a payment'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('${formatEnglishNumber(payment.amountKas)} KAS',
                  style: const TextStyle(
                      fontSize: 26, fontWeight: FontWeight.w900)),
              const SizedBox(height: 14),
              const Text('Recipient',
                  style: TextStyle(color: KasVaultTheme.muted)),
              SelectableText(recipient),
              const SizedBox(height: 12),
              Text('Network fee: ${formatEnglishNumber(payment.feeKas)} KAS'),
              Text('Change: ${formatEnglishNumber(payment.changeKas)} KAS'),
              Text(
                  '${payment.inputCount} inputs · ${payment.outputCount} outputs · mass ${payment.mass}'),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: Text(buttonLabel('REJECT'))),
          FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(buttonLabel('PAY'))),
        ],
      ),
    );
    if (approved != true) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }
    if (!context.mounted) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }
    if (NetworkSettings.network.value != networkBeforeApproval ||
        await _preferences.getAddress() != selectedAddressBeforeApproval) {
      throw const FormatException(
        'Wallet account or network changed during approval. Build a fresh request.',
      );
    }
    final signed = await SignerService().sign(payment);
    final broadcastId = await api.broadcast(signed.submitJson);
    if (broadcastId.isNotEmpty && broadcastId != signed.transactionId) {
      throw const FormatException(
          'Node returned a mismatching transaction ID.');
    }
    await _dapps.respondResult(
      request,
      params.containsKey('priorityFeeSompi')
          ? <String, Object?>{'transactionId': signed.transactionId}
          : signed.transactionId,
    );
  }

  String _displayKrc20Amount(BigInt amount, int decimals) {
    return formatRawTokenAmount(amount, decimals);
  }

  Future<void> _handleDappKrc20(
    SessionRequestEvent request,
    String address,
  ) async {
    await _requireActiveSessionAddress(address);
    final pendingKey =
        'kaspire_pending_inscription_v2_${address.toLowerCase()}';
    const legacyPendingKey = 'kaspire_pending_inscription_v1';
    final params = _paramsMap(request.params);
    if (params.keys.any(
      (key) =>
          key != 'to' && key != 'ticker' && key != 'amount' && key != 'from',
    )) {
      throw const FormatException('Unknown KRC-20 transfer field.');
    }
    final recipient = params['to'];
    final ticker = params['ticker']?.toString().trim().toUpperCase();
    final rawAmount = params['amount']?.toString();
    final amount = rawAmount == null ? null : BigInt.tryParse(rawAmount);
    final from = params['from'] ?? address;
    if (recipient is! String ||
        !RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(recipient) ||
        ticker == null ||
        ticker.isEmpty ||
        ticker.length > 32 ||
        !RegExp(r'^[A-Z0-9_-]+$').hasMatch(ticker) ||
        amount == null ||
        amount <= BigInt.zero ||
        from != address) {
      throw const FormatException('Invalid KRC-20 transfer request.');
    }
    if (!await _security.hasNativeWalletFor(address)) {
      throw const FormatException('The session wallet is watch-only.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(pendingKey) || prefs.containsKey(legacyPendingKey)) {
      throw const FormatException(
        'Finish the saved pending asset transfer in Kaspire first.',
      );
    }

    final api = KaspaApi();
    final wallet = await api.loadWallet(address);
    final token = wallet.krc20Tokens
        .where((asset) => asset.symbol.toUpperCase() == ticker)
        .firstOrNull;
    final available = BigInt.tryParse(token?.rawBalance ?? '');
    if (token == null || available == null || amount > available) {
      throw const FormatException(
        'The approved wallet does not hold enough of this KRC-20 token.',
      );
    }
    final displayAmount = _displayKrc20Amount(amount, token.decimals);
    final operation = <String, Object?>{
      'kind': 'krc20',
      'sender': address,
      'recipient': recipient,
      'ticker': ticker,
      'amount': amount.toString(),
      'displayAmount': displayAmount,
      'tokenId': '',
      'assetId': '',
    };
    final plan = await _security.prepareInscription(operation);
    final results = await Future.wait([
      api.loadUtxos(address),
      api.loadFeeRate(),
    ]);
    final signer = SignerService();
    final commit = await signer.prepare(
      sender: address,
      recipient: plan['commitAddress']! as String,
      amountSompi: (plan['commitAmountSompi'] as num).toInt(),
      feeRate: results[1] as double,
      utxosJson: results[0] as String,
    );
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) {
      throw const FormatException('Wallet UI is unavailable.');
    }
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('${_dapps.dappName(request.topic)} requests KRC-20'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$displayAmount $ticker',
                style:
                    const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 14),
              const Text('Recipient',
                  style: TextStyle(color: KasVaultTheme.muted)),
              SelectableText(recipient),
              const SizedBox(height: 12),
              const Text('Commit amount: 0.30000000 KAS'),
              Text(
                  'Commit network fee: ${formatEnglishNumber(commit.feeKas)} KAS'),
              const SizedBox(height: 12),
              const Text(
                'KRC-20 uses commit/reveal. Keep Kaspire open and approve both signing steps. The commit value returns as change minus network fees.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(buttonLabel('REJECT')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(buttonLabel('CONTINUE')),
          ),
        ],
      ),
    );
    if (approved != true || !context.mounted) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }

    final signedCommit = await signer.sign(commit);
    final commitBroadcastId = await api.broadcast(signedCommit.submitJson);
    if (commitBroadcastId.isNotEmpty &&
        commitBroadcastId != signedCommit.transactionId) {
      throw const FormatException('Node returned a mismatching commit ID.');
    }
    final pending = <String, Object?>{
      'operation': operation,
      'plan': plan,
      'commitTransactionId': signedCommit.transactionId,
      'commitFeeSompi': commit.feeSompi,
      'createdAt': DateTime.now().toIso8601String(),
    };
    await prefs.setString(pendingKey, jsonEncode(pending));
    if (!context.mounted) {
      throw const FormatException(
        'Commit saved. Resume the reveal from Kaspire.',
      );
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(minutes: 2),
        content: Text(
          'Commit accepted. Keep Kaspire open while the reveal becomes available.',
        ),
      ),
    );
    try {
      String? commitUtxos;
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          final candidate =
              await api.loadUtxos(plan['commitAddress']! as String);
          final rows = jsonDecode(candidate) as List;
          if (rows.any((entry) =>
              (entry as Map)['outpoint']?['transactionId'] ==
              signedCommit.transactionId)) {
            commitUtxos = candidate;
            break;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      if (commitUtxos == null) {
        throw const FormatException(
          'Commit saved but not spendable yet. Resume the reveal in Kaspire.',
        );
      }
      final revealRequest = <String, Object?>{
        'operation': operation,
        'commitTransactionId': signedCommit.transactionId,
        'commitUtxosJson': commitUtxos,
        'feeRate': await api.loadFeeRate(),
      };
      final reveal = await _security.prepareReveal(revealRequest);
      if (!context.mounted) {
        throw const FormatException(
          'Reveal approval cancelled. Resume it from Kaspire.',
        );
      }
      final signedReveal = await _security.signReveal(
        revealRequest,
        reveal['reviewHash']! as String,
      );
      final revealBroadcastId =
          await api.broadcast(signedReveal['submitJson']! as String);
      if (revealBroadcastId.isNotEmpty &&
          revealBroadcastId != signedReveal['transactionId']) {
        throw const FormatException('Node returned a mismatching reveal ID.');
      }
      await prefs.remove(pendingKey);
      await ActivityStore().recordAssetTransfer(
        wallet: address,
        operation: operation,
        transactionId: signedReveal['transactionId']! as String,
        timestamp: DateTime.now(),
      );
      await _dapps.respondResult(request, <String, Object?>{
        'ticker': ticker,
        'amount': amount.toString(),
        'commitTransactionId': signedCommit.transactionId,
        'revealTransactionId': signedReveal['transactionId'],
        'commitFeeSompi': commit.feeSompi,
        'revealFeeSompi': reveal['feeSompi'],
      });
    } finally {
      messenger.hideCurrentSnackBar();
    }
  }

  Future<void> _handleDappKrc721(
    SessionRequestEvent request,
    String address,
  ) async {
    await _requireActiveSessionAddress(address);
    final pendingKey =
        'kaspire_pending_inscription_v2_${address.toLowerCase()}';
    const legacyPendingKey = 'kaspire_pending_inscription_v1';
    final params = _paramsMap(request.params);
    if (params.keys.any(
      (key) =>
          key != 'to' && key != 'ticker' && key != 'tokenId' && key != 'from',
    )) {
      throw const FormatException('Unknown KRC-721 transfer field.');
    }
    final recipient = params['to'];
    final ticker = params['ticker']?.toString().trim().toUpperCase();
    final tokenId = params['tokenId']?.toString().trim();
    final from = params['from'] ?? address;
    if (recipient is! String ||
        !RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(recipient) ||
        ticker == null ||
        ticker.isEmpty ||
        ticker.length > 32 ||
        !RegExp(r'^[A-Z0-9_-]+$').hasMatch(ticker) ||
        tokenId == null ||
        tokenId.isEmpty ||
        tokenId.length > 128 ||
        tokenId.runes.any((value) => value < 0x20 || value == 0x7f) ||
        from != address) {
      throw const FormatException('Invalid KRC-721 transfer request.');
    }
    if (!await _security.hasNativeWalletFor(address)) {
      throw const FormatException('The session wallet is watch-only.');
    }
    final prefs = await SharedPreferences.getInstance();
    if (prefs.containsKey(pendingKey) || prefs.containsKey(legacyPendingKey)) {
      throw const FormatException(
        'Finish the saved pending asset transfer in Kaspire first.',
      );
    }

    final api = KaspaApi();
    var ownsNft = false;
    var offset = 0;
    for (var pageNumber = 0; pageNumber < 100; pageNumber++) {
      final page = await api.loadNftCollection(
        address,
        ticker,
        offset: offset,
      );
      if (page.nfts.any(
        (nft) => nft.ticker.toUpperCase() == ticker && nft.tokenId == tokenId,
      )) {
        ownsNft = true;
        break;
      }
      final next = page.nextOffset;
      if (next == null || next <= offset) break;
      offset = next;
    }
    if (!ownsNft) {
      throw const FormatException(
        'The approved wallet does not hold this KRC-721 token.',
      );
    }

    final operation = <String, Object?>{
      'kind': 'krc721',
      'sender': address,
      'recipient': recipient,
      'ticker': ticker,
      'amount': '',
      'displayAmount': '1',
      'tokenId': tokenId,
      'assetId': '',
    };
    final plan = await _security.prepareInscription(operation);
    final results = await Future.wait([
      api.loadUtxos(address),
      api.loadFeeRate(),
    ]);
    final signer = SignerService();
    final commit = await signer.prepare(
      sender: address,
      recipient: plan['commitAddress']! as String,
      amountSompi: (plan['commitAmountSompi'] as num).toInt(),
      feeRate: results[1] as double,
      utxosJson: results[0] as String,
    );
    final selectedAddressBeforeApproval = await _preferences.getAddress();
    final networkBeforeApproval = NetworkSettings.network.value;
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) {
      throw const FormatException('Wallet UI is unavailable.');
    }
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('${_dapps.dappName(request.topic)} requests KRC-721'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$ticker #$tokenId',
                style: const TextStyle(
                  fontSize: 26,
                  fontWeight: FontWeight.w900,
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'Escrow / recipient',
                style: TextStyle(color: KasVaultTheme.muted),
              ),
              SelectableText(recipient),
              const SizedBox(height: 12),
              const Text('Commit amount: 0.30000000 KAS'),
              Text(
                'Commit network fee: ${formatEnglishNumber(commit.feeKas)} KAS',
              ),
              const SizedBox(height: 12),
              const Text(
                'KRC-721 uses commit/reveal. Kaspire verifies ownership of the exact NFT, constructs both transactions locally, and requires fresh authorization for signing.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(buttonLabel('REJECT')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(buttonLabel('CONTINUE')),
          ),
        ],
      ),
    );
    if (approved != true || !context.mounted) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }
    if (NetworkSettings.network.value != networkBeforeApproval ||
        await _preferences.getAddress() != selectedAddressBeforeApproval) {
      throw const FormatException(
        'Wallet account or network changed during approval. Build a fresh request.',
      );
    }

    final signedCommit = await signer.sign(commit);
    final commitBroadcastId = await api.broadcast(signedCommit.submitJson);
    if (commitBroadcastId.isNotEmpty &&
        commitBroadcastId != signedCommit.transactionId) {
      throw const FormatException('Node returned a mismatching commit ID.');
    }
    final pending = <String, Object?>{
      'operation': operation,
      'plan': plan,
      'commitTransactionId': signedCommit.transactionId,
      'commitFeeSompi': commit.feeSompi,
      'createdAt': DateTime.now().toIso8601String(),
    };
    await prefs.setString(pendingKey, jsonEncode(pending));
    if (!context.mounted) {
      throw const FormatException(
        'Commit saved. Resume the reveal from Kaspire.',
      );
    }
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        duration: Duration(minutes: 2),
        content: Text(
          'NFT commit accepted. Keep Kaspire open while the reveal becomes available.',
        ),
      ),
    );
    try {
      String? commitUtxos;
      for (var attempt = 0; attempt < 40; attempt++) {
        try {
          final candidate =
              await api.loadUtxos(plan['commitAddress']! as String);
          final rows = jsonDecode(candidate) as List;
          if (rows.any((entry) =>
              (entry as Map)['outpoint']?['transactionId'] ==
              signedCommit.transactionId)) {
            commitUtxos = candidate;
            break;
          }
        } catch (_) {}
        await Future<void>.delayed(const Duration(seconds: 3));
      }
      if (commitUtxos == null) {
        throw const FormatException(
          'Commit saved but not spendable yet. Resume the reveal in Kaspire.',
        );
      }
      final revealRequest = <String, Object?>{
        'operation': operation,
        'commitTransactionId': signedCommit.transactionId,
        'commitUtxosJson': commitUtxos,
        'feeRate': await api.loadFeeRate(),
      };
      final reveal = await _security.prepareReveal(revealRequest);
      if (!context.mounted) {
        throw const FormatException(
          'Reveal approval cancelled. Resume it from Kaspire.',
        );
      }
      final signedReveal = await _security.signReveal(
        revealRequest,
        reveal['reviewHash']! as String,
      );
      final revealBroadcastId =
          await api.broadcast(signedReveal['submitJson']! as String);
      if (revealBroadcastId.isNotEmpty &&
          revealBroadcastId != signedReveal['transactionId']) {
        throw const FormatException('Node returned a mismatching reveal ID.');
      }
      await prefs.remove(pendingKey);
      await ActivityStore().recordAssetTransfer(
        wallet: address,
        operation: operation,
        transactionId: signedReveal['transactionId']! as String,
        timestamp: DateTime.now(),
      );
      await _dapps.respondResult(request, <String, Object?>{
        'ticker': ticker,
        'tokenId': tokenId,
        'commitTransactionId': signedCommit.transactionId,
        'revealTransactionId': signedReveal['transactionId'],
        'commitFeeSompi': commit.feeSompi,
        'revealFeeSompi': reveal['feeSompi'],
      });
    } finally {
      messenger.hideCurrentSnackBar();
    }
  }

  Future<void> _handlePskt(
    SessionRequestEvent request,
    String address,
  ) async {
    await _requireActiveSessionAddress(address);
    final params = _paramsMap(request.params);
    const allowedFields = {
      'txJsonString',
      'psktTransactionJson',
      'options',
      'signInputs',
      'scripts',
      'submitTransaction',
    };
    if (params.keys.any((key) => !allowedFields.contains(key))) {
      throw const FormatException('Unknown PSKT signing field.');
    }
    final normalizedRequest = params.containsKey('psktTransactionJson');
    final txJson = params['psktTransactionJson'] ?? params['txJsonString'];
    final options = params['options'];
    final optionsMap = options == null
        ? <String, Object?>{}
        : options is Map
            ? options.map((key, value) => MapEntry(key.toString(), value))
            : throw const FormatException('Invalid PSKT signing options.');
    if (optionsMap.keys.any((key) => key != 'signInputs' && key != 'scripts')) {
      throw const FormatException('Invalid PSKT signing options.');
    }
    final rawInputs =
        params['signInputs'] ?? optionsMap['signInputs'] ?? const [];
    final rawScripts = params['scripts'] ?? optionsMap['scripts'] ?? const [];
    final submitTransaction = params['submitTransaction'] ?? false;
    if (txJson is! String ||
        txJson.isEmpty ||
        txJson.length > 512 * 1024 ||
        rawInputs is! List ||
        rawScripts is! List ||
        submitTransaction is! bool) {
      throw const FormatException('Invalid PSKT signing request.');
    }
    if (submitTransaction) {
      throw const FormatException(
        'Wallet-side PSKT broadcast is not enabled. Request sign-only and broadcast the returned PSKT through the dApp backend.',
      );
    }
    if (rawInputs.length > 256 ||
        rawScripts.length > 256 ||
        (rawInputs.isEmpty && rawScripts.isEmpty)) {
      throw const FormatException('Invalid PSKT input selection.');
    }
    final signInputs = <Map<String, Object?>>[];
    for (final raw in rawInputs) {
      if (raw is! Map) {
        throw const FormatException('Invalid PSKT input selection.');
      }
      final item = raw.map((key, value) => MapEntry(key.toString(), value));
      if (item.keys.any((key) => key != 'index' && key != 'sighashType')) {
        throw const FormatException('Unknown PSKT input field.');
      }
      final index = item['index'];
      final sighash = item['sighashType'] ?? 1;
      if (index is! int ||
          index < 0 ||
          index > 255 ||
          sighash is! int ||
          !const {1, 2, 4, 129, 130, 132}.contains(sighash)) {
        throw const FormatException('Invalid PSKT input selection.');
      }
      signInputs.add({'index': index, 'sighashType': sighash});
    }
    final scripts = <Map<String, Object?>>[];
    for (final raw in rawScripts) {
      if (raw is! Map) {
        throw const FormatException('Invalid PSKT script selection.');
      }
      scripts.add(raw.map((key, value) => MapEntry(key.toString(), value)));
    }
    if (!await _security.hasNativeWalletFor(address)) {
      throw const FormatException('The session wallet is watch-only.');
    }
    final selectedAddressBeforeApproval = await _preferences.getAddress();
    final networkBeforeApproval = NetworkSettings.network.value;
    final psktRequest = <String, Object?>{
      'sender': address,
      'txJsonString': txJson,
      'signInputs': signInputs,
      'scripts': scripts,
    };
    final review = await _security.preparePskt(psktRequest);
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) {
      throw const FormatException('Wallet UI is unavailable.');
    }
    final inputs = (review['inputs'] as List).whereType<Map>().toList();
    final outputs = (review['outputs'] as List).whereType<Map>().toList();
    final warnings =
        (review['warnings'] as List).map((item) => item.toString()).toList();
    final payloadText = review['payloadUtf8']?.toString();
    final walletNet = (review['walletNetSompi'] as num).toInt();
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('${_dapps.dappName(request.topic)} requests PSKT signing'),
        content: SizedBox(
          width: double.maxFinite,
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'Kaspire verified the Kaspa transaction structure and will sign only the selected inputs. You must decide whether the dApp action and any covenant rules are trustworthy.',
                ),
                const SizedBox(height: 14),
                Text(
                  'Wallet effect: ${walletNet <= 0 ? '−' : '+'}${formatSompi(walletNet.abs())} KAS',
                  style: const TextStyle(
                      fontSize: 23, fontWeight: FontWeight.w900),
                ),
                Text(
                    'Network fee: ${formatSompi((review['feeSompi'] as num).toInt())} KAS'),
                Text(
                    'Signing ${review['selectedInputCount']} of ${review['inputCount']} inputs · ${review['outputCount']} outputs'),
                const SizedBox(height: 12),
                const Text('Transaction ID',
                    style: TextStyle(color: KasVaultTheme.muted)),
                SelectableText(review['transactionId']!.toString()),
                if (warnings.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('IMPORTANT WARNINGS',
                      style: TextStyle(
                          color: Color(0xFFFFC857),
                          fontWeight: FontWeight.w900)),
                  const SizedBox(height: 6),
                  ...warnings.map((warning) => Padding(
                        padding: const EdgeInsets.only(bottom: 5),
                        child: Text('• $warning',
                            style: const TextStyle(color: Color(0xFFFFC857))),
                      )),
                ],
                const SizedBox(height: 16),
                const Text('INPUTS',
                    style: TextStyle(fontWeight: FontWeight.w900)),
                ...inputs.map((raw) {
                  final item = raw.cast<String, Object?>();
                  return Padding(
                    padding: const EdgeInsets.only(top: 9),
                    child: SelectableText(
                      '#${item['index']} · ${formatSompi((item['amountSompi'] as num).toInt())} KAS'
                      '${item['selected'] == true ? ' · SIGN ${item['sighashLabel']}' : ''}'
                      '${item['scriptAware'] == true ? ' · ${item['signatureScriptMode']}' : ''}\n'
                      '${item['address'] ?? 'Non-standard/covenant script'}\n'
                      '${item['outpoint']}',
                    ),
                  );
                }),
                const SizedBox(height: 16),
                const Text('OUTPUTS',
                    style: TextStyle(fontWeight: FontWeight.w900)),
                ...outputs.map((raw) {
                  final item = raw.cast<String, Object?>();
                  return Padding(
                    padding: const EdgeInsets.only(top: 9),
                    child: SelectableText(
                      '#${item['index']} · ${formatSompi((item['amountSompi'] as num).toInt())} KAS'
                      '${item['returnsToWallet'] == true ? ' · RETURNS TO WALLET' : ''}\n'
                      '${item['address'] ?? 'Non-standard/covenant script'}'
                      '${item['covenantId'] == null ? '' : '\nCovenant: ${item['covenantId']}'}\n'
                      'Script: ${item['scriptPublicKey']}',
                    ),
                  );
                }),
                if ((review['payloadHex'] as String).isNotEmpty) ...[
                  const SizedBox(height: 16),
                  const Text('PAYLOAD',
                      style: TextStyle(fontWeight: FontWeight.w900)),
                  SelectableText(payloadText ?? review['payloadHex'] as String),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(buttonLabel('REJECT')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(buttonLabel('SIGN SELECTED INPUTS')),
          ),
        ],
      ),
    );
    if (approved != true) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }
    if (NetworkSettings.network.value != networkBeforeApproval ||
        await _preferences.getAddress() != selectedAddressBeforeApproval) {
      throw const FormatException(
        'Wallet account or network changed during approval. Build a fresh request.',
      );
    }
    final signed = await _security.signPskt(
      psktRequest,
      review['reviewHash']! as String,
    );
    // Keep the legacy string response while also supporting KaspaCom's
    // normalized sign-only adapter contract.
    await _dapps.respondResult(
      request,
      normalizedRequest || params.containsKey('submitTransaction')
          ? <String, Object?>{
              'psktTransactionJson': signed['signedTxJson'],
            }
          : signed['signedTxJson'],
    );
  }

  Future<void> _handleVaultTransaction(
    SessionRequestEvent request,
    String address,
  ) async {
    await _requireActiveSessionAddress(address);
    final params = _paramsMap(request.params);
    if (params.keys.any((key) =>
        key != 'txJsonString' &&
        key != 'signInputIndexes' &&
        key != 'redeemScript')) {
      throw const FormatException('Unknown vault-signing field.');
    }
    final txJson = params['txJsonString'];
    final indexes = params['signInputIndexes'];
    final redeemScript = params['redeemScript'];
    final isCreate = indexes is List && indexes.length == 1 && indexes[0] == 0;
    final isHeartbeat = indexes is List &&
        indexes.length == 2 &&
        indexes[0] == 0 &&
        indexes[1] == 1;
    if (txJson is! String ||
        txJson.length > 256 * 1024 ||
        (!isCreate && !isHeartbeat) ||
        redeemScript is! String ||
        (isHeartbeat &&
            !RegExp(r'^(?:0x)?[0-9a-fA-F]+$').hasMatch(redeemScript)) ||
        (isCreate && redeemScript.isNotEmpty) ||
        redeemScript.length > 32768) {
      throw const FormatException('Invalid vault-signing request.');
    }
    if (!await _security.hasNativeWalletFor(address)) {
      throw const FormatException('The session wallet is watch-only.');
    }
    final policyRequest = <String, Object?>{
      'sender': address,
      'txJsonString': txJson,
      'signInputIndexes': indexes,
      'redeemScript': redeemScript,
    };
    final review = await _security.preparePolicyTransaction(policyRequest);
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) {
      throw const FormatException('Wallet UI is unavailable.');
    }
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title:
            Text('${_dapps.dappName(request.topic)} requests a vault action'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Kaspire verified that this transaction recreates the same covenant with the same locked amount and returns all remaining change to this wallet.',
              ),
              const SizedBox(height: 14),
              Text(
                '${formatEnglishNumber((review['vaultAmountSompi'] as num).toInt() / 100000000)} KAS ${review['action'] == 'dms-heartbeat' ? 'remain locked' : 'will be locked'}',
                style:
                    const TextStyle(fontSize: 23, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 10),
              Text(
                'Network fee: ${formatEnglishNumber((review['feeSompi'] as num).toInt() / 100000000)} KAS',
              ),
              const SizedBox(height: 10),
              const Text(
                'Only the two reviewed inputs will be signed. Unknown PSKT and arbitrary scripts are rejected.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(buttonLabel('REJECT')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(buttonLabel('AUTHORIZE')),
          ),
        ],
      ),
    );
    if (approved != true) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }
    final signed = await _security.signPolicyTransaction(
      policyRequest,
      review['reviewHash']! as String,
    );
    await _dapps.respondResult(request, <String, Object?>{
      'signedTxJson': signed['signedTxJson'],
      'profile': review['profile'],
      'reviewHash': review['reviewHash'],
    });
  }

  Future<void> _handleDappKcc20(
    SessionRequestEvent request,
    String address,
  ) async {
    await _requireActiveSessionAddress(address);
    final params = _paramsMap(request.params);
    if (params.keys.any((key) =>
        key != 'to' &&
        key != 'covenantId' &&
        key != 'amount' &&
        key != 'from')) {
      throw const FormatException('Unknown KCC20 transfer field.');
    }
    final recipient = params['to'];
    final covenantId = params['covenantId']?.toString().toLowerCase();
    final amount = BigInt.tryParse(params['amount']?.toString() ?? '');
    final from = params['from'] ?? address;
    if (recipient is! String ||
        !RegExp(r'^kaspa:[a-z0-9]{61,63}$').hasMatch(recipient) ||
        covenantId == null ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(covenantId) ||
        amount == null ||
        amount <= BigInt.zero ||
        amount > BigInt.from(0x7fffffffffffffff) ||
        from != address) {
      throw const FormatException('Invalid KCC20 transfer request.');
    }
    if (!await _security.hasNativeWalletFor(address)) {
      throw const FormatException('The session wallet is watch-only.');
    }
    final api = KaspaApi();
    final wallet = await api.loadWallet(address);
    final token = wallet.kcc20Tokens
        .where((asset) => asset.covenantId == covenantId)
        .firstOrNull;
    final available = BigInt.tryParse(token?.rawBalance ?? '');
    if (token == null ||
        token.validationStatus != 'verified' ||
        !token.discoveryComplete ||
        token.kcc20Cells.isEmpty ||
        available == null ||
        amount > available) {
      throw const FormatException(
        'The approved wallet has no complete, verified KCC20 balance for this covenant.',
      );
    }
    await api.verifyKcc20CellsOnOwnNode(token.kcc20Cells, covenantId);
    final fundingUtxos = await api.loadUtxos(address);
    final transfer = <String, Object?>{
      'sender': address,
      'recipient': recipient,
      'covenantId': covenantId,
      'ticker': token.symbol,
      'amount': amount.toInt(),
      'decimals': token.decimals,
      'feeRate': 100.0,
      'templateHash': token.templateHash,
      'cells': token.kcc20Cells.map((cell) => cell.toJson()).toList(),
      'fundingUtxosJson': fundingUtxos,
    };
    final review = await _security.prepareKcc20Transfer(transfer);
    final displayAmount = formatRawTokenAmount(amount, token.decimals);
    final context = await _contextWhenReady();
    if (context == null || !context.mounted) {
      throw const FormatException('Wallet UI is unavailable.');
    }
    final approved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => AlertDialog(
        title: Text('${_dapps.dappName(request.topic)} requests KCC20'),
        content: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$displayAmount ${token.symbol}',
                style:
                    const TextStyle(fontSize: 26, fontWeight: FontWeight.w900),
              ),
              const SizedBox(height: 14),
              const Text('Recipient',
                  style: TextStyle(color: KasVaultTheme.muted)),
              SelectableText(recipient),
              const SizedBox(height: 12),
              const Text('Validation: KCC20 indexer verified'),
              Text('Covenant ID: $covenantId'),
              Text('Template: ${review['templateHash']}'),
              Text(
                  'KAS in token inputs: ${formatSompi((review['lockedKasSompi'] as num).toInt())} KAS'),
              if ((review['lockedKasTopUpSompi'] as num?)?.toInt() != 0)
                Text(
                    'KAS reserve top-up: ${formatSompi((review['lockedKasTopUpSompi'] as num).toInt())} KAS'),
              if ((review['lockedKasReleasedSompi'] as num?)?.toInt() != 0)
                Text(
                    'KAS returned to wallet: ${formatSompi((review['lockedKasReleasedSompi'] as num).toInt())} KAS'),
              Text(
                  'KAS in new token cells: ${formatSompi((review['lockedKasOutputSompi'] as num).toInt())} KAS'),
              Text(
                  'Network fee: ${formatSompi((review['feeSompi'] as num).toInt())} KAS'),
              Text(
                  '${review['covenantInputCount']} covenant input(s) · effective mass ${review['mass']}'),
              Text(
                  'Compute ${review['computeMass']} · storage ${review['storageMass']} · transient ${review['transientMass']} · budget ${review['computeBudget']}'),
              Text('Safe storage target: ${review['storageMassTarget']}'),
              Text('Fee mass: ${review['feeMass']}'),
              if ((review['lockedKasTopUpSompi'] as num?)?.toInt() != 0)
                const Text(
                  'The reserve top-up adds only the KAS needed to keep the new token cells spendable. It is not a network fee.',
                  style: TextStyle(color: Color(0xFFFFC857)),
                ),
              if ((review['lockedKasReleasedSompi'] as num?)?.toInt() != 0)
                Text(
                  'Excess KAS from the consumed token cells returns as normal wallet change.',
                  style: TextStyle(color: KasVaultTheme.mint),
                ),
              const SizedBox(height: 12),
              const Text(
                'Kaspire reconstructs and executes every state locally before sending the transaction to Kaspa mainnet.',
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(buttonLabel('REJECT')),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(buttonLabel('VERIFY + SEND')),
          ),
        ],
      ),
    );
    if (approved != true || !context.mounted) {
      await _dapps.respondError(request, 'User rejected.', code: 4001);
      return;
    }
    final signed = await _security.signKcc20Transfer(
      transfer,
      review['reviewHash']! as String,
    );
    final transactionId = signed['transactionId']! as String;
    await api.broadcastKcc20(
      signed['wrpcJson']! as String,
      expectedTransactionId: transactionId,
    );
    final operation = <String, Object?>{
      'kind': 'kcc20',
      'sender': address,
      'recipient': recipient,
      'ticker': token.symbol,
      'amount': amount.toString(),
      'displayAmount': displayAmount,
      'covenantId': covenantId,
    };
    await ActivityStore().recordAssetTransfer(
      wallet: address,
      operation: operation,
      transactionId: transactionId,
      timestamp: DateTime.now(),
    );
    await _dapps.respondResult(request, <String, Object?>{
      'transactionId': transactionId,
      'covenantId': covenantId,
      'ticker': token.symbol,
      'amount': amount.toString(),
      'feeSompi': review['feeSompi'],
      'mass': review['mass'],
      'validation': 'toccata-node',
    });
  }

  Future<String?> _loadInitialAddress() async {
    await _security.initializeVault();
    final saved = await _preferences.getAddress();
    if (saved != null) {
      if (!await _security.hasNativeWalletFor(saved)) {
        await _preferences.addWatchWallet(saved);
      }
      final lastActive = await AppSettings.lastBackgroundedAt();
      final minutes = AppSettings.lockMinutes.value;
      _locked = minutes == 0 ||
          lastActive == null ||
          DateTime.now().difference(lastActive) >= Duration(minutes: minutes);
      return saved;
    }
    final nativeAddress = await _security.getNativeAddress();
    if (nativeAddress != null) await _preferences.setAddress(nativeAddress);
    return nativeAddress;
  }

  void _openWallet(String address) async {
    await _preferences.setAddress(address);
    if (!mounted) return;
    setState(() => _address = Future.value(address));
  }

  void _reset() async {
    await _preferences.clearAddress();
    if (mounted) setState(() => _address = Future.value(null));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<KaspireTheme>(
      valueListenable: AppSettings.theme,
      builder: (context, selectedTheme, _) => ValueListenableBuilder<bool>(
        valueListenable: AppSettings.uppercaseButtons,
        builder: (context, _, __) => ValueListenableBuilder<FiatCurrency>(
          valueListenable: AppSettings.fiatCurrency,
          builder: (context, selectedCurrency, ___) => MaterialApp(
            navigatorKey: _navigatorKey,
            title: 'Kaspire',
            debugShowCheckedModeBanner: false,
            theme: KasVaultTheme.forTheme(selectedTheme),
            builder: (context, child) => Listener(
              behavior: HitTestBehavior.translucent,
              onPointerDown: (_) => _recordActivity(),
              child: child,
            ),
            home: FutureBuilder<String?>(
              future: _address,
              builder: (context, snapshot) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const Scaffold(
                    body: Center(child: CircularProgressIndicator()),
                  );
                }
                final address = snapshot.data;
                if (address != null && _locked) {
                  return _KaspireLockScreen(
                    unlocking: _unlocking,
                    onUnlock: _unlock,
                  );
                }
                return address == null
                    ? OnboardingScreen(onConnected: _openWallet)
                    : HomeShell(
                        key: ValueKey('$address-${selectedCurrency.code}'),
                        address: address,
                        onSwitchWallet: _openWallet,
                        onDisconnect: _reset,
                      );
              },
            ),
          ),
        ),
      ),
    );
  }
}

class _KaspireLockScreen extends StatelessWidget {
  const _KaspireLockScreen({
    required this.unlocking,
    required this.onUnlock,
  });

  final bool unlocking;
  final VoidCallback onUnlock;

  @override
  Widget build(BuildContext context) => Scaffold(
        body: SafeArea(
          child: Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Icon(Icons.lock_rounded, size: 58),
                  const SizedBox(height: 18),
                  const Text(
                    'Kaspire is locked',
                    style: TextStyle(fontSize: 24, fontWeight: FontWeight.w900),
                  ),
                  const SizedBox(height: 8),
                  const Text(
                    'Authenticate to restore your wallet session.',
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 24),
                  FilledButton.icon(
                    onPressed: unlocking ? null : onUnlock,
                    icon: unlocking
                        ? const SizedBox.square(
                            dimension: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(Icons.fingerprint_rounded),
                    label: Text(buttonLabel('UNLOCK KASPIRE')),
                  ),
                ],
              ),
            ),
          ),
        ),
      );
}

class _DappVerification extends StatelessWidget {
  const _DappVerification({required this.context});
  final VerifyContext? context;

  @override
  Widget build(BuildContext context) {
    final verification = this.context;
    final validation = verification?.validation;
    final (icon, color, label) = switch (validation) {
      Validation.VALID => (
          Icons.verified_rounded,
          KasVaultTheme.mint,
          'Domain verified by Reown Verify',
        ),
      Validation.SCAM => (
          Icons.dangerous_rounded,
          const Color(0xFFFF6B6B),
          'Known scam domain',
        ),
      Validation.INVALID => (
          Icons.warning_amber_rounded,
          const Color(0xFFFFB65C),
          'Domain verification failed',
        ),
      _ => (
          Icons.help_outline_rounded,
          const Color(0xFFFFB65C),
          'Domain is not verified',
        ),
    };
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(icon, color: color, size: 20),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            verification?.origin.isNotEmpty == true
                ? '$label\n${verification!.origin}'
                : label,
            style: TextStyle(color: color, height: 1.3),
          ),
        ),
      ],
    );
  }
}
