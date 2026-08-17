import 'dart:async';

import 'package:reown_walletkit/reown_walletkit.dart';

class DappSessionService {
  DappSessionService._();
  static final instance = DappSessionService._();

  static const chainId = 'kaspa:mainnet';
  static const kasplexChainId = 'eip155:202555';
  static const igraChainId = 'eip155:38833';
  static const evmMethods = <String>{
    'eth_accounts',
    'eth_requestAccounts',
    'eth_chainId',
    'wallet_switchEthereumChain',
    'eth_sendTransaction',
  };
  static const supportedMethods = <String>{
    'kaspa_getAccounts',
    'kaspa_signPersonal',
    'kaspa_sendTransaction',
    'kaspa_sendKrc20',
    'kaspa_sendKcc20',
    'kaspa_signPskt',
    'kaspa_signVaultTransaction',
  };
  static const supportedEvents = <String>{'accountsChanged'};
  // Reown project IDs are public application identifiers, not credentials.
  // Keeping Kaspire's ID in source lets F-Droid reproduce a fully functional
  // WalletConnect build without asking F-Droid to register for an API key.
  static const _projectId = String.fromEnvironment(
    'REOWN_PROJECT_ID',
    defaultValue: '3dae39e7c46fbc79ee7bc33018184dd1',
  );

  final _proposals = StreamController<SessionProposalEvent>.broadcast();
  final _requests = StreamController<SessionRequestEvent>.broadcast();
  final _changes = StreamController<void>.broadcast();
  final Set<String> _consumedPairingTopics = {};
  final Set<String> _deliveredRequestIds = {};
  ReownWalletKit? _walletKit;
  Future<void>? _initializing;
  String? _lastError;

  bool get configured => _projectId.trim().isNotEmpty;
  bool get ready => _walletKit != null;
  String? get lastError => _lastError;
  Stream<SessionProposalEvent> get proposals => _proposals.stream;
  Stream<SessionRequestEvent> get requests => _requests.stream;
  Stream<void> get changes => _changes.stream;

  Future<void> initialize() => _initializing ??= _initialize();

  Future<void> _initialize() async {
    if (!configured) {
      _lastError = 'REOWN_PROJECT_ID is not configured in this build.';
      _changes.add(null);
      return;
    }
    try {
      final walletKit = await ReownWalletKit.createInstance(
        projectId: _projectId,
        metadata: const PairingMetadata(
          name: 'Kaspire',
          description: 'Kaspa Mainnet, Kasplex and Igra wallet',
          url: 'https://kaspire.kaslab.space',
          icons: ['https://kaspire.kaslab.space/kaspire-logo.png'],
          redirect:
              Redirect(universal: 'https://kaspire.kaslab.space/kaspire/wc'),
        ),
      );
      walletKit.onSessionProposal.subscribe(_onProposal);
      walletKit.onSessionRequest.subscribe(_onRequest);
      walletKit.onSessionConnect.subscribe((_) => _changes.add(null));
      walletKit.onSessionDelete.subscribe((_) => _changes.add(null));
      walletKit.onSessionExpire.subscribe((_) => _changes.add(null));
      _walletKit = walletKit;
      _lastError = null;
      _replayPendingRequests();
    } catch (_) {
      _lastError = 'Could not initialize the encrypted dApp relay.';
    }
    _changes.add(null);
  }

  void _onProposal(SessionProposalEvent? event) {
    if (event != null) _proposals.add(event);
  }

  void _onRequest(SessionRequestEvent? event) {
    if (event == null) return;
    final key = "${event.topic}:${event.id}";
    if (!_deliveredRequestIds.add(key)) return;
    if (_deliveredRequestIds.length > 1024) {
      _deliveredRequestIds.remove(_deliveredRequestIds.first);
    }
    _requests.add(event);
  }

  void _replayPendingRequests() {
    final walletKit = _walletKit;
    if (walletKit == null) return;
    for (final request in walletKit.getPendingSessionRequests().values) {
      _onRequest(SessionRequestEvent.fromSessionRequest(request));
    }
  }

  Future<void> handleAppLink(Uri link) async {
    final trustedWakeLink = link.scheme == 'kaspire' &&
        link.host == 'dapp' &&
        (link.path.isEmpty || link.path == '/') &&
        link.query.isEmpty &&
        link.fragment.isEmpty;
    if (trustedWakeLink) {
      await initialize();
      _replayPendingRequests();
      return;
    }
    final trustedHttps = link.scheme == 'https' &&
        (link.host == 'kaspire.kaslab.space' || link.host == 'kaslab.space') &&
        link.path == '/kaspire/wc';
    final trustedAppScheme = link.scheme == 'kaspire' &&
        link.host == 'wc' &&
        (link.path.isEmpty || link.path == '/');
    if ((!trustedHttps && !trustedAppScheme) || link.fragment.isNotEmpty) {
      throw const FormatException('Untrusted Kaspire link origin.');
    }
    final parameters = link.queryParametersAll;
    if (parameters.length != 1 ||
        parameters['uri'] == null ||
        parameters['uri']!.length != 1) {
      throw const FormatException('The link must contain one pairing URI.');
    }
    await pair(parameters['uri']!.single);
  }

  static String pairingUriFromQrPayload(String payload) {
    final value = payload.trim();
    if (value.isEmpty || value.length > 4096) {
      throw const FormatException('Invalid dApp pairing QR code.');
    }
    if (value.startsWith('wc:')) {
      _validatedPairingUri(value);
      return value;
    }
    final link = Uri.tryParse(value);
    if (link == null) {
      throw const FormatException('Invalid dApp pairing QR code.');
    }
    final trustedHttps = link.scheme == 'https' &&
        (link.host == 'kaspire.kaslab.space' || link.host == 'kaslab.space') &&
        link.path == '/kaspire/wc';
    final trustedAppScheme = link.scheme == 'kaspire' &&
        link.host == 'wc' &&
        (link.path.isEmpty || link.path == '/');
    if ((!trustedHttps && !trustedAppScheme) || link.fragment.isNotEmpty) {
      throw const FormatException('Untrusted dApp pairing QR code.');
    }
    final parameters = link.queryParametersAll;
    if (parameters.length != 1 ||
        parameters['uri'] == null ||
        parameters['uri']!.length != 1) {
      throw const FormatException('The QR code must contain one pairing URI.');
    }
    final pairingUri = parameters['uri']!.single;
    _validatedPairingUri(pairingUri);
    return pairingUri;
  }

  Future<void> pairQrPayload(String payload) =>
      pair(pairingUriFromQrPayload(payload));

  Future<void> pair(String rawUri) async {
    final uri = _validatedPairingUri(rawUri);
    final topic = RegExp(r'^([0-9a-fA-F]{64})@2$')
        .firstMatch(uri.path)!
        .group(1)!
        .toLowerCase();
    if (!_consumedPairingTopics.add(topic)) {
      throw const FormatException('This pairing link was already consumed.');
    }
    await initialize();
    final walletKit = _walletKit;
    if (walletKit == null) {
      _consumedPairingTopics.remove(topic);
      throw StateError(_lastError ?? 'dApp relay is unavailable.');
    }
    try {
      await walletKit.pair(uri: uri);
    } catch (_) {
      _consumedPairingTopics.remove(topic);
      throw StateError('Encrypted pairing failed. Request a fresh link.');
    }
  }

  static Uri _validatedPairingUri(String rawUri) {
    if (rawUri.length > 2048) {
      throw const FormatException('Pairing URI is too long.');
    }
    final uri = Uri.tryParse(rawUri);
    if (uri == null || uri.scheme != 'wc' || uri.fragment.isNotEmpty) {
      throw const FormatException('Invalid WalletConnect URI.');
    }
    final topicMatch = RegExp(r'^([0-9a-fA-F]{64})@2$').firstMatch(uri.path);
    final query = uri.queryParametersAll;
    final symKey = query['symKey'];
    final relay = query['relay-protocol'];
    if (topicMatch == null ||
        symKey?.length != 1 ||
        !RegExp(r'^[0-9a-fA-F]{64}$').hasMatch(symKey!.single) ||
        relay?.length != 1 ||
        relay!.single != 'irn') {
      throw const FormatException('Unsupported WalletConnect pairing URI.');
    }
    final allowed = {'symKey', 'relay-protocol', 'expiryTimestamp'};
    if (query.keys.any((key) => !allowed.contains(key))) {
      throw const FormatException('Pairing URI contains unknown fields.');
    }
    final expiry = query['expiryTimestamp'];
    if (expiry != null &&
        (expiry.length != 1 ||
            int.tryParse(expiry.single) == null ||
            int.parse(expiry.single) <=
                DateTime.now().millisecondsSinceEpoch ~/ 1000)) {
      throw const FormatException('Pairing URI has expired.');
    }
    return uri;
  }

  String? proposalProblem(SessionProposalEvent event) {
    final verification = event.verifyContext;
    if (verification?.validation == Validation.SCAM ||
        verification?.isScam == true) {
      return 'Reown Verify marked this domain as a scam.';
    }
    for (final entry in event.params.requiredNamespaces.entries) {
      if (entry.key == 'eip155') {
        final chains = entry.value.chains ?? const <String>[];
        if (!supportsEvmChains(chains)) {
          return 'Only Kasplex and Igra EVM networks are supported.';
        }
        if (entry.value.methods.any((method) => !evmMethods.contains(method))) {
          return 'The L2 dApp requires an unsupported method.';
        }
        continue;
      }
      if (entry.key != 'kaspa') return 'Required namespace is unsupported.';
      final chains = entry.value.chains ?? const <String>[];
      if (chains.isEmpty || chains.any((chain) => chain != chainId)) {
        return 'Only Kaspa Mainnet is supported.';
      }
      if (entry.value.methods.any(
        (method) => !supportedMethods.contains(method),
      )) {
        return 'The dApp requires an unsupported method.';
      }
      if (entry.value.events.any(
        (event) => !supportedEvents.contains(event),
      )) {
        return 'The dApp requires an unsupported event.';
      }
    }
    return null;
  }

  static bool supportsEvmChains(Iterable<String> chains) {
    final unique = chains.toSet();
    return unique.isNotEmpty &&
        unique.length == chains.length &&
        unique.every(
          (chain) => chain == kasplexChainId || chain == igraChainId,
        );
  }

  Set<String> requestedMethods(SessionProposalEvent event) {
    final methods = <String>{};
    final required = event.params.requiredNamespaces['kaspa'];
    final optional = event.params.optionalNamespaces['kaspa'];
    if (required != null) methods.addAll(required.methods);
    if (optional != null) {
      methods.addAll(optional.methods.where(supportedMethods.contains));
    }
    final evmRequired = event.params.requiredNamespaces['eip155'];
    final evmOptional = event.params.optionalNamespaces['eip155'];
    if (evmRequired != null) methods.addAll(evmRequired.methods);
    if (evmOptional != null) {
      methods.addAll(evmOptional.methods.where(evmMethods.contains));
    }
    return methods;
  }

  List<String> requestedEvmChains(SessionProposalEvent event) {
    final result = <String>[];
    for (final namespace in [
      event.params.requiredNamespaces['eip155'],
      event.params.optionalNamespaces['eip155']
    ]) {
      for (final chain in namespace?.chains ?? const <String>[]) {
        if ((chain == kasplexChainId || chain == igraChainId) &&
            !result.contains(chain)) {
          result.add(chain);
        }
      }
    }
    return result;
  }

  String? requestedEvmChain(SessionProposalEvent event) =>
      requestedEvmChains(event).firstOrNull;

  Future<void> approve(SessionProposalEvent event, String address,
      {String? evmAddress}) async {
    final problem = proposalProblem(event);
    if (problem != null) throw StateError(problem);
    final methods = requestedMethods(event).toList()..sort();
    final events = <String>{};
    for (final namespace in [
      event.params.requiredNamespaces['kaspa'],
      event.params.optionalNamespaces['kaspa'],
    ]) {
      if (namespace != null) {
        events.addAll(namespace.events.where(supportedEvents.contains));
      }
    }
    final namespaces = <String, Namespace>{};
    if (event.params.requiredNamespaces.containsKey('kaspa') ||
        event.params.optionalNamespaces.containsKey('kaspa')) {
      namespaces['kaspa'] = Namespace(
          chains: const [chainId],
          accounts: ['$chainId:${address.replaceFirst('kaspa:', '')}'],
          methods: methods.where(supportedMethods.contains).toList(),
          events: events.toList());
    }
    final evmChains = requestedEvmChains(event);
    if (evmChains.isNotEmpty && evmAddress != null) {
      namespaces['eip155'] = Namespace(
          chains: evmChains,
          accounts: evmChains.map((chain) => '$chain:$evmAddress').toList(),
          methods: methods.where(evmMethods.contains).toList(),
          events: const ['accountsChanged', 'chainChanged']);
    }
    await _walletKit!.approveSession(
      id: event.id,
      namespaces: namespaces,
      sessionProperties: const {
        'kaspire.protocol': '3',
        'kaspire.multichain': 'kaspa+eip155'
      },
    );
    _changes.add(null);
  }

  Future<void> reject(SessionProposalEvent event, {String? message}) async {
    await _walletKit!.rejectSession(
      id: event.id,
      reason: ReownSignError(
        code: 5000,
        message: message ?? 'User rejected the dApp session.',
      ),
    );
  }

  Map<String, SessionData> activeSessions() =>
      _walletKit?.getActiveSessions() ?? const {};

  String? addressForTopic(String topic) {
    final session = activeSessions()[topic];
    final account = session?.namespaces['kaspa']?.accounts.firstOrNull;
    if (account == null) return null;
    final parts = account.split(':');
    if (parts.length != 3 || parts[0] != 'kaspa' || parts[1] != 'mainnet') {
      return null;
    }
    return 'kaspa:${parts[2]}';
  }

  String? evmAddressForTopic(String topic, {String? chainId}) {
    final accounts =
        activeSessions()[topic]?.namespaces['eip155']?.accounts ?? const [];
    final account = chainId == null
        ? accounts.firstOrNull
        : accounts.where((entry) => entry.startsWith('$chainId:')).firstOrNull;
    if (account == null) return null;
    final parts = account.split(':');
    return parts.length == 3 && parts[0] == 'eip155' ? parts[2] : null;
  }

  String dappName(String topic) =>
      activeSessions()[topic]?.peer.metadata.name ?? 'Unknown dApp';

  Future<void> respondResult(SessionRequestEvent request, Object? result) =>
      _walletKit!.respondSessionRequest(
        topic: request.topic,
        response: JsonRpcResponse(id: request.id, result: result),
      );

  Future<void> respondError(
    SessionRequestEvent request,
    String message, {
    int code = -32000,
  }) =>
      _walletKit!.respondSessionRequest(
        topic: request.topic,
        response: JsonRpcResponse(
          id: request.id,
          error: JsonRpcError(code: code, message: message),
        ),
      );

  Future<void> disconnect(String topic) async {
    await _walletKit!.disconnectSession(
      topic: topic,
      reason: const ReownSignError(code: 6000, message: 'User disconnected.'),
    );
    _changes.add(null);
  }

  Future<void> disconnectAll() async {
    await initialize();
    final topics = activeSessions().keys.toList(growable: false);
    for (final topic in topics) {
      await disconnect(topic);
    }
  }
}
