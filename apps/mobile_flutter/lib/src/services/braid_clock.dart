import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:http/http.dart' as http;

/// One fresh public REST reading and one independent, synced wRPC reading.
/// No Braid-provided clock, resolver URL or cached chain reading is trusted.
class BraidClock {
  BraidClock(this.client, {this.socketRead});
  final http.Client client;
  final Future<int> Function()? socketRead;
  Future<String> broadcast(Map tx, String expectedId) async {
    final encoded = encodeBraidSubmit(tx);
    for (final host in ['muon-10.kaspa.blue', 'vega-10.kaspa.green']) {
      final url = 'wss://$host/kaspa/testnet-10/wrpc/borsh';
      try {
        decodeBraidServerInfo(await _rpc(url, 114, [1, 0]));
        final payload = braidRpcPayload(await _rpc(url, 125, encoded), 125);
        if (payload.length != 34) {
          throw StateError('Unexpected node submit response.');
        }
        final id = payload
            .sublist(2)
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join();
        if (id != expectedId) {
          throw StateError('Node returned a different transaction ID.');
        }
        return id;
      } catch (_) {
        /* Retry the exact signed bytes on another fixed TN10 node. */
      }
    }
    throw StateError(
        'Public-node submission could not be confirmed. The exact signed recovery remains saved.');
  }

  Future<List<int>> _rpc(String url, int op, List<int> payload) async {
    final socket =
        await WebSocket.connect(url).timeout(const Duration(seconds: 6));
    try {
      final frame = _BraidWriter()
        ..u8(1)
        ..u64(1)
        ..u8(op)
        ..u32(payload.length)
        ..raw(payload);
      socket.add(Uint8List.fromList(frame.b));
      return await socket
          .where((m) => m is List<int> && m.length > 12 && m[0] == 1)
          .cast<List<int>>()
          .first
          .timeout(const Duration(seconds: 10));
    } finally {
      unawaited(socket.close());
    }
  }

  Future<List<int>> read() async {
    final results = await Future.wait([
      _rest(),
      socketRead?.call() ?? _publicNode(),
    ]);
    if (results.any((d) => d <= 0) || (results[0] - results[1]).abs() > 600) {
      throw StateError(
          'Independent Kaspa chain clocks disagree. Nothing was signed.');
    }
    return results;
  }

  Future<int> _rest() async {
    final r = await client
        .get(Uri.parse('https://api-tn10.kaspa.org/info/blockdag'))
        .timeout(const Duration(seconds: 10));
    final d = jsonDecode(r.body);
    if (r.statusCode != 200 ||
        d is! Map ||
        d['networkName'] != 'kaspa-testnet-10') {
      throw StateError('Independent Testnet 10 clock is unavailable.');
    }
    return int.parse('${d['virtualDaaScore']}');
  }

  Future<int> _publicNode() async {
    for (final host in ['muon-10.kaspa.blue', 'vega-10.kaspa.green']) {
      try {
        final socket =
            await WebSocket.connect('wss://$host/kaspa/testnet-10/wrpc/borsh')
                .timeout(const Duration(seconds: 6));
        try {
          // Some(request-id=1), getServerInfo=114, len=2, request-version=1.
          socket.add(Uint8List.fromList(
              [1, 1, 0, 0, 0, 0, 0, 0, 0, 114, 2, 0, 0, 0, 1, 0]));
          final message =
              await socket.first.timeout(const Duration(seconds: 8));
          if (message is List<int>) return decodeBraidServerInfo(message);
        } finally {
          unawaited(socket.close());
        }
      } catch (_) {/* Try the other fixed public node, never a provider URL. */}
    }
    throw StateError(
        'The independent public-node clock is unavailable. Nothing was signed.');
  }
}

int decodeBraidServerInfo(List<int> frame) {
  if (frame.length < 20 || frame.length > 65536) {
    throw const FormatException('Invalid wRPC frame');
  }
  final bytes = Uint8List.fromList(frame);
  final data = ByteData.sublistView(bytes);
  if (bytes[0] != 1 ||
      data.getUint64(1, Endian.little) != 1 ||
      bytes[11] != 114 ||
      bytes[12] != 1) {
    throw const FormatException('Unexpected wRPC response');
  }
  final size = data.getUint32(13, Endian.little);
  if (size + 17 != bytes.length || size < 20) {
    throw const FormatException('Truncated server info');
  }
  final p = ByteData.sublistView(bytes, 17);
  var offset = 10 + p.getUint32(6, Endian.little);
  if (offset + 16 > size ||
      p.getUint8(offset) != 1 ||
      p.getUint8(offset + 1) != 1 ||
      p.getUint32(offset + 2, Endian.little) != 10) {
    throw const FormatException('Public node is not on Testnet 10');
  }
  offset += 6;
  if (p.getUint8(offset) != 1 || p.getUint8(offset + 1) != 1) {
    throw const FormatException('Public node is not synced/UTXO indexed');
  }
  final daa = p.getUint64(offset + 2, Endian.little);
  if (daa <= 0 || daa > 500000000000) {
    throw const FormatException('Invalid node chain time');
  }
  return daa;
}

Uint8List braidRpcPayload(List<int> frame, int op) {
  final bytes = Uint8List.fromList(frame);
  final b = ByteData.sublistView(bytes);
  if (bytes.length < 17 ||
      bytes[0] != 1 ||
      b.getUint64(1, Endian.little) != 1 ||
      bytes[11] != op ||
      bytes[12] != 1 ||
      b.getUint32(13, Endian.little) + 17 != bytes.length) {
    throw const FormatException('Node refused the wRPC operation');
  }
  return Uint8List.sublistView(bytes, 17);
}

class _BraidWriter {
  final b = <int>[];
  void raw(List<int> bytes) => b.addAll(bytes);
  void u8(int n) => b.add(n & 255);
  void u16(int n) {
    u8(n);
    u8(n >> 8);
  }

  void u32(int n) {
    for (var i = 0; i < 4; i++) {
      u8(n >> (8 * i));
    }
  }

  void u64(Object n) {
    var x = BigInt.parse('$n');
    if (x.isNegative || x >= BigInt.one << 64) {
      throw const FormatException('Invalid node integer');
    }
    for (var i = 0; i < 8; i++) {
      u8((x & BigInt.from(255)).toInt());
      x >>= 8;
    }
  }

  void hex(String s) {
    if (s.length.isOdd) throw const FormatException('Invalid hex');
    for (var i = 0; i < s.length; i += 2) {
      u8(int.parse(s.substring(i, i + 2), radix: 16));
    }
  }

  void vector(String s) {
    u32(s.length ~/ 2);
    hex(s);
  }

  void sub(void Function(_BraidWriter) fill) {
    final w = _BraidWriter();
    fill(w);
    u32(w.b.length);
    raw(w.b);
  }

  void none() => sub((w) => w.u8(0));
}

List<int> encodeBraidSubmit(Map tx) {
  if (tx['version'] != 1) {
    throw const FormatException('Braid recovery requires a v1 transaction');
  }
  final w = _BraidWriter()..u16(1);
  w.sub((t) {
    t.u16(1);
    t.u16(1);
    t.sub((v) {
      v.u32((tx['inputs'] as List).length);
      for (final i in tx['inputs'] as List) {
        v.sub((x) {
          x.u8(2);
          x.sub((o) {
            o.u8(1);
            o.hex('${i['transactionId']}');
            o.u32(i['index'] as int);
          });
          x.vector('${i['signatureScript']}');
          x.u64(i['sequence']);
          x.u8(i['sigOpCount'] as int);
          x.none();
          x.u16(i['computeBudget'] as int);
        });
      }
    });
    t.sub((v) {
      v.u32((tx['outputs'] as List).length);
      for (final o in tx['outputs'] as List) {
        v.sub((x) {
          x.u8(2);
          x.u64(o['value']);
          final spk = '${o['scriptPublicKey']}';
          if (!spk.startsWith('0000')) {
            throw const FormatException('Unsupported script version');
          }
          x.u16(0);
          x.vector(spk.substring(4));
          x.none();
          final c = o['covenant'];
          if (c == null) {
            x.none();
          } else {
            x.sub((k) {
              k.u8(1);
              k.sub((z) {
                z.u8(1);
                z.u16(c['authorizingInput'] as int);
                z.hex('${c['covenantId']}');
              });
            });
          }
        });
      }
    });
    t.u64(tx['lockTime']);
    t.hex('${tx['subnetworkId']}');
    t.u64(tx['gas']);
    t.vector('${tx['payload']}');
    t.u64(0);
    t.none();
  });
  w.u8(0);
  return w.b;
}
