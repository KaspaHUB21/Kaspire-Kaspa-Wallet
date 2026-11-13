import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:kasvault_wallet/src/services/dapp_pskt_request.dart';

void main() {
  Map<String, Object?> request() => {
        'psktTransactionJson': '{"version":1}',
        'options': {
          'signInputs': [
            {'index': 0, 'sighashType': 1}
          ]
        },
        'scripts': [
          {
            'inputIndex': 0,
            'scriptHex': '00' * 56899,
            'signType': 1,
            'signatureScript': {'mode': 'wrap-signature', 'args': []}
          }
        ],
        'submitTransaction': false
      };
  test('normalized 56,899-byte script reaches native validation unchanged', () {
    final source = request(),
        result = normalizeDappPsktRequest(source, 'fixture');
    expect(result.normalizedResponse, true);
    expect(result.request['sender'], 'fixture');
    expect(result.request['txJsonString'], source['psktTransactionJson']);
    expect(result.request['scripts'], source['scripts']);
    expect(result.request['signInputs'], [
      {'index': 0, 'sighashType': 1}
    ]);
    expect(jsonEncode(result.request).length, lessThan(256 * 1024));
  });
  test('legacy shape and explicit normalized response remain compatible', () {
    final legacy = {
      'txJsonString': '{}',
      'signInputs': [
        {'index': 1}
      ]
    };
    expect(normalizeDappPsktRequest(legacy, 's').normalizedResponse, false);
    expect(
        normalizeDappPsktRequest({...legacy, 'submitTransaction': false}, 's')
            .normalizedResponse,
        true);
  });
  test('unknown envelope, option and selected-input names are returned', () {
    for (final (source, path) in <(Map<String, Object?>, String)>[
      ({...request(), 'unexpectedFlag': true}, 'unexpectedFlag'),
      (
        {
          ...request(),
          'options': {'unknownOption': true}
        },
        'options.unknownOption'
      ),
      (
        {
          ...request(),
          'signInputs': [
            {'index': 0, 'badInput': true}
          ]
        },
        'signInputs[0].badInput'
      ),
    ]) {
      expect(
          () => normalizeDappPsktRequest(source, 's'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'specific field', contains(path))));
    }
  });
  test('field-specific type and range errors stay actionable', () {
    for (final (source, path) in <(Map<String, Object?>, String)>[
      ({...request(), 'psktTransactionJson': 7}, 'transaction JSON'),
      ({...request(), 'options': []}, 'options'),
      ({...request(), 'signInputs': '0'}, 'signInputs'),
      ({...request(), 'scripts': {}}, 'scripts'),
      ({...request(), 'submitTransaction': 'false'}, 'submitTransaction'),
      (
        {
          ...request(),
          'signInputs': [
            {'index': '0'}
          ]
        },
        'signInputs[0].index'
      ),
      (
        {
          ...request(),
          'signInputs': [
            {'index': 0, 'sighashType': '1'}
          ]
        },
        'signInputs[0].sighashType'
      ),
      (
        {
          ...request(),
          'signInputs': [
            {'index': 0, 'expectedSighash': 1}
          ]
        },
        'signInputs[0].expectedSighash'
      ),
    ]) {
      expect(
          () => normalizeDappPsktRequest(source, 's'),
          throwsA(isA<FormatException>()
              .having((e) => e.message, 'typed field', contains(path))));
    }
  });
  test('script schema fields are preserved for strict native serde errors', () {
    final scripts = [
      {'inputIndex': 0, 'unknownNativeField': true}
    ];
    expect(
        normalizeDappPsktRequest({...request(), 'scripts': scripts}, 's')
            .request['scripts'],
        scripts);
  });
  test('sign-only policy and UTF-8 byte bound cannot be bypassed', () {
    expect(
        () => normalizeDappPsktRequest(
            {...request(), 'submitTransaction': true}, 's'),
        throwsFormatException);
    expect(
        () => normalizeDappPsktRequest(
            {...request(), 'psktTransactionJson': 'é' * (256 * 1024 + 1)}, 's'),
        throwsFormatException);
  });
}
