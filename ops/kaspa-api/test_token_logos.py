import base64
import os
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch
import token_logos

PNG = base64.b64decode('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO+jWZkAAAAASUVORK5CYII=')


class LogoTests(unittest.TestCase):
    def test_cold_logo_is_persisted_and_survives_process_cache_recreation(self):
        with tempfile.TemporaryDirectory() as directory:
            first = token_logos.TokenLogoCache(directory)
            with patch.object(first, '_download', return_value=PNG) as download:
                self.assertEqual(first.response('kasbtc')[0], 200)
                download.assert_called_once_with('kasbtc')
            second = token_logos.TokenLogoCache(directory)
            with patch.object(second, '_download', side_effect=OSError('offline')) as download:
                status, headers, body = second.response('kasbtc')
                self.assertEqual((status, headers['content-type'], body), (200, 'image/png', PNG))
                download.assert_not_called()

    def test_stale_logo_remains_available_when_original_is_offline(self):
        jobs = []
        class Executor:
            def submit(self, function, *args):
                jobs.append((function, args))
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / 'souls.img'
            path.write_bytes(PNG)
            os.utime(path, (1, 1))
            cache = token_logos.TokenLogoCache(directory)
            with patch.object(token_logos, '_executor', Executor()), patch.object(cache, '_download', side_effect=OSError('offline')):
                self.assertEqual(cache.response('souls')[2], PNG)
                self.assertEqual(len(jobs), 1)
                function, args = jobs.pop()
                function(*args)
                self.assertEqual(cache.response('souls')[2], PNG)
                self.assertEqual(path.read_bytes(), PNG)

    def test_invalid_tickers_never_access_the_origin(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = token_logos.TokenLogoCache(directory)
            with patch.object(cache, '_download') as download:
                for ticker in ['../keys', 'https://127.0.0.1', '%2fetc', 'x?url=http://x', 'x'*33, '']:
                    self.assertEqual(cache.response(ticker)[0], 400)
                download.assert_not_called()

    def test_miss_backoff_prevents_repeated_origin_requests(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = token_logos.TokenLogoCache(directory)
            with patch.object(cache, '_download', side_effect=OSError('missing')) as download:
                self.assertEqual(cache.response('unknown')[0], 404)
                self.assertEqual(cache.response('unknown')[0], 404)
                self.assertEqual(download.call_count, 1)

    def test_html_svg_and_excessive_dimensions_are_not_raster_logos(self):
        for data in [b'<html>failure</html>', b'<svg onload="x"/>', PNG[:16] + b'\xff'*8 + PNG[24:]]:
            with self.assertRaises(ValueError):
                token_logos.raster_type(data)

    def test_metadata_cannot_redirect_cache_to_arbitrary_hosts(self):
        with tempfile.TemporaryDirectory() as directory:
            cache = token_logos.TokenLogoCache(directory)
            with patch.object(cache, '_read_url', side_effect=[OSError('missing'), b'{"data":{"image_url":"http://127.0.0.1/private"}}']) as read:
                self.assertEqual(cache.response('x')[0], 404)
                self.assertEqual(read.call_count, 2)

if __name__ == '__main__':
    unittest.main()
