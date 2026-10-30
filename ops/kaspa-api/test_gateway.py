import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch
from types import SimpleNamespace
from io import BytesIO
from copy import deepcopy

spec = importlib.util.spec_from_file_location("gateway", Path(__file__).with_name("gateway.py"))
gateway = importlib.util.module_from_spec(spec)
spec.loader.exec_module(gateway)


def response(status, payload, headers=None):
    return status, headers or {}, json.dumps(payload).encode()


class HistoryTests(unittest.TestCase):
    def call(self, local, public, *, synced=True, limit=1, offset=0):
        calls = []

        def request(base, *args, **kwargs):
            calls.append(base)
            result = local if base == gateway.LOCAL else public
            if isinstance(result, Exception):
                raise result
            return result

        with patch.object(gateway, "_is_history_healthy", return_value=synced), patch.object(gateway, "_request", side_effect=request):
            result = gateway._merged_history(f"/addresses/synthetic/full-transactions?limit={limit}&offset={offset}")
        return result, calls

    def test_empty_synced_discovery_never_calls_public_fallback(self):
        (status, _, body), calls = self.call(response(200, []), response(429, {}))
        self.assertEqual((status, json.loads(body)), (200, []))
        self.assertEqual(calls, [gateway.LOCAL])

    def test_reloading_gap_cannot_self_trigger_public_rate_limit(self):
        for _ in range(120):
            _, calls = self.call(response(200, []), response(429, {}))
            self.assertEqual(calls, [gateway.LOCAL])

    def test_positive_discovery_normalizes_wrapped_rows(self):
        row = {"transaction_id": "a" * 64}
        (status, _, body), calls = self.call(response(200, {"transactions": [row]}), OSError())
        self.assertEqual((status, json.loads(body)), (200, [row]))
        self.assertEqual(calls, [gateway.LOCAL])

    def test_fallback_429_cannot_mask_valid_empty_synced_primary(self):
        (status, _, body), _ = self.call(response(200, []), response(429, {}), limit=20)
        self.assertEqual((status, json.loads(body)), (200, []))

    def test_unsynced_empty_primary_requires_successful_fallback(self):
        (status, _, _), calls = self.call(response(200, []), response(429, {}), synced=False)
        self.assertEqual(status, 429)
        self.assertEqual(len(calls), 2)

    def test_transport_failure_plus_unsynced_empty_is_not_empty_account(self):
        with self.assertRaises(OSError):
            self.call(response(200, []), OSError(), synced=False)

    def test_two_transport_failures_are_not_empty_account(self):
        with self.assertRaises(OSError):
            self.call(OSError(), OSError())

    def test_primary_failure_uses_public_fallback(self):
        row = {"transaction_id": "a" * 64}
        (status, _, body), _ = self.call(response(503, {}), response(200, [row]))
        self.assertEqual((status, json.loads(body)), (200, [row]))

    def test_malformed_success_is_not_unused(self):
        (status, _, _), calls = self.call(response(200, {"detail": "error"}), response(429, {}))
        self.assertEqual(status, 429)
        self.assertEqual(len(calls), 2)

    def test_activity_merge_and_pagination_are_preserved(self):
        a = {"transaction_id": "a", "block_time": 100}
        b = {"transaction_id": "b", "block_time": 200}
        (status, _, body), _ = self.call(response(200, [a]), response(200, [b, a]), limit=1, offset=1)
        self.assertEqual((status, json.loads(body)), (200, [a]))

    def test_rate_limit_retains_retry_after(self):
        (status, headers, _), _ = self.call(response(503, {}), response(429, {}, {"Retry-After": "45"}))
        self.assertEqual(status, 429)
        self.assertEqual(headers["Retry-After"], "45")

    def test_history_beyond_first_hundred_uses_actual_backend_pagination(self):
        rows = [{'transaction_id':str(i),'block_time':1000-i} for i in range(250)]
        calls = []
        def request(base, method, path, **kwargs):
            query = gateway.urllib.parse.parse_qs(gateway.urllib.parse.urlsplit(path).query)
            limit, offset = int(query['limit'][0]), int(query['offset'][0])
            self.assertLessEqual(limit, 100)
            calls.append((base, offset))
            return response(200, rows[offset:offset+limit])
        with patch.object(gateway,'_is_history_healthy',return_value=True), patch.object(gateway,'_request',side_effect=request):
            status, _, body = gateway._merged_history('/addresses/x/full-transactions?limit=51&offset=100')
        self.assertEqual(status,200)
        self.assertEqual([r['transaction_id'] for r in json.loads(body)],[str(i) for i in range(100,151)])
        self.assertIn((gateway.LOCAL,100),calls)
        self.assertIn((gateway.PUBLIC,100),calls)

    def test_excessive_history_window_is_explicit_not_a_false_end_of_history(self):
        with patch.object(gateway,'_request') as request:
            status, _, _ = gateway._merged_history('/addresses/x/full-transactions?limit=50&offset=1000')
        self.assertEqual(status,416)
        request.assert_not_called()

    def test_local_history_requires_a_synced_database(self):
        errors = []
        handler = SimpleNamespace(path="/local-node/addresses/synthetic/full-transactions", _error=lambda status, text: errors.append(status))
        with patch.object(gateway, "_is_local_healthy", return_value=True), patch.object(gateway, "_is_history_healthy", return_value=False), patch.object(gateway, "_request") as request:
            gateway.GatewayHandler._proxy_local_node_read(handler)
        self.assertEqual(errors, [503])
        request.assert_not_called()

    def test_synced_local_history_never_uses_public_fallback(self):
        replies = []
        handler = SimpleNamespace(path="/local-node/addresses/synthetic/full-transactions?limit=1", _respond=lambda *args: replies.append(args))
        with patch.object(gateway, "_is_local_healthy", return_value=True), patch.object(gateway, "_is_history_healthy", return_value=True), patch.object(gateway, "_request", return_value=response(200, [])) as request:
            gateway.GatewayHandler._proxy_local_node_read(handler)
        self.assertEqual(replies[0][0], 200)
        request.assert_called_once_with(gateway.LOCAL, "GET", "/addresses/synthetic/full-transactions?limit=1", timeout=15)

    def test_retry_after_is_forwarded_to_clients(self):
        headers = {}
        handler = SimpleNamespace(send_response=lambda status: None, send_header=lambda k, v: headers.update({k: v}), end_headers=lambda: None, wfile=BytesIO())
        gateway.GatewayHandler._respond(handler, 429, {"Retry-After": "45"}, b"{}")
        self.assertEqual(headers["retry-after"], "45")


class LocalUtxoScriptVersionTests(unittest.TestCase):
    def row(self, version="omitted"):
        script = {"scriptPublicKey": "aa20" + "ab" * 32 + "87"}
        if version != "omitted":
            script["version"] = version
        return {"address": "kaspa:synthetic", "outpoint": {"transactionId": "11" * 32, "index": 0},
                "utxoEntry": {"amount": "200000000", "blockDaaScore": "579612899",
                              "isCoinbase": False, "scriptPublicKey": script}}

    def test_proto3_zero_is_explicit_and_all_other_chain_data_is_identical(self):
        original = self.row()
        expected = deepcopy(original)
        expected["utxoEntry"]["scriptPublicKey"]["version"] = 0
        status, headers, body = gateway._explicit_local_utxo_script_versions(
            "/addresses/kaspa%3Asynthetic/utxos?unused=1", response(200, [original]))
        self.assertEqual(status, 200)
        self.assertEqual(json.loads(body), [expected])
        self.assertNotIn("version", original["utxoEntry"]["scriptPublicKey"])
        self.assertNotIn("covenantId", json.loads(body)[0]["utxoEntry"])

    def test_explicit_versions_and_missing_or_invalid_scripts_are_not_repaired(self):
        rows = [self.row(0), self.row(1), self.row(65535), self.row(None), self.row("bad")]
        rows += [{}, {"utxoEntry": {}}, {"utxoEntry": {"scriptPublicKey": {}}},
                 {"utxoEntry": {"scriptPublicKey": {"scriptPublicKey": "not-hex"}}}]
        original = response(200, rows)
        self.assertIs(gateway._explicit_local_utxo_script_versions("/addresses/x/utxos", original), original)

    def test_failures_non_utxo_routes_and_unreadable_responses_are_unchanged(self):
        for status in (404, 429, 500):
            original = response(status, {"detail": "unavailable"}, {"Retry-After": "5"})
            self.assertIs(gateway._explicit_local_utxo_script_versions("/addresses/x/utxos", original), original)
        for path in ("/transactions/id", "/addresses/x/full-transactions", "/addresses/x/utxos/other"):
            original = response(200, [self.row()])
            self.assertIs(gateway._explicit_local_utxo_script_versions(path, original), original)
        for body in (b"not-json", b"{}", b"[]"):
            original = (200, {}, body)
            self.assertIs(gateway._explicit_local_utxo_script_versions("/addresses/x/utxos", original), original)

    def test_local_node_handler_wires_normalization_without_public_fallback(self):
        replies = []
        handler = SimpleNamespace(path="/local-node/addresses/x/utxos", _respond=lambda *args: replies.append(args))
        with patch.object(gateway, "_is_local_healthy", return_value=True), patch.object(
            gateway, "_request", return_value=response(200, [self.row()])
        ) as request:
            gateway.GatewayHandler._proxy_local_node_read(handler)
        request.assert_called_once_with(gateway.LOCAL, "GET", "/addresses/x/utxos", timeout=15)
        self.assertEqual(json.loads(replies[0][2])[0]["utxoEntry"]["scriptPublicKey"]["version"], 0)


if __name__ == "__main__":
    unittest.main()
