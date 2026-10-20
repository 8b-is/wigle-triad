"""Offline request-boundary regression tests: no sockets, radios or uploads."""
import importlib.util
import io
import pathlib
import unittest
from types import SimpleNamespace
from unittest.mock import patch

spec = importlib.util.spec_from_file_location('bridge', pathlib.Path(__file__).parents[1] / 'host/wiglewww.py')
bridge = importlib.util.module_from_spec(spec)
spec.loader.exec_module(bridge)

class PrivacyTests(unittest.TestCase):
    def test_upload_is_disabled_without_scanning_or_network(self):
        handler = object.__new__(bridge.WigleWWWHandler)
        handler.path = '/api/upload'
        handler.headers = {'Host': '127.0.0.1:8088', 'Content-Length': '0'}
        handler.server = SimpleNamespace(server_address=('127.0.0.1', 8088))
        handler.rfile = io.BytesIO()
        responses = []
        handler._send = lambda status, *args: responses.append(status)
        with patch.object(bridge, 'send_and_collect') as scan, patch.object(bridge, 'upload_csv_anonymously', return_value={}) as upload:
            handler.do_POST()
        self.assertEqual(responses, [403])
        scan.assert_not_called()
        upload.assert_not_called()

    def test_invalid_command_requests_never_scan(self):
        cases = [
            ({'Content-Length': '4097'}, b'', 413),
            ({'Content-Length': '-1'}, b'', 400),
            ({'Content-Length': 'bad'}, b'', 400),
            ({'Content-Length': '2'}, b'[]', 400),
            ({'Content-Length': '1'}, b'{', 400),
            ({'Content-Length': '2', 'Transfer-Encoding': 'chunked'}, b'{}', 400),
        ]
        for headers, raw, expected in cases:
            with self.subTest(headers=headers, raw=raw):
                handler = object.__new__(bridge.WigleWWWHandler)
                handler.path = '/api/cmd'
                handler.headers = {"Host": "127.0.0.1:8088", **headers}
                handler.server = SimpleNamespace(server_address=("127.0.0.1", 8088))
                handler.rfile = io.BytesIO(raw)
                responses = []
                handler._send = lambda status, *args: responses.append(status)
                with patch.object(bridge, 'send_and_collect', return_value=[]) as scan, patch.object(bridge, 'discover_ports', return_value=[]) as ports:
                    handler.do_POST()
                self.assertEqual(responses, [expected])
                scan.assert_not_called()
                ports.assert_not_called()

    def test_cross_site_and_rebinding_requests_are_denied(self):
        for headers in [{}, {'Host': 'evil.example:8088'},
                        {'Host': '127.0.0.1:8088', 'Origin': 'https://evil.example'},
                        {'Host': 'localhost:8088', 'Origin': 'null'},
                        {'Host': 'localhost:8088', 'Sec-Fetch-Site': 'cross-site'}]:
            for method, path in [('do_GET', '/api/triad.json'), ('do_POST', '/api/cmd')]:
                with self.subTest(headers=headers, method=method):
                    handler = object.__new__(bridge.WigleWWWHandler)
                    handler.path = path
                    handler.headers = headers
                    handler.server = SimpleNamespace(server_address=('127.0.0.1', 8088))
                    responses = []
                    handler._send = lambda status, *args: responses.append(status)
                    with patch.object(bridge, 'discover_ports') as ports:
                        getattr(handler, method)()
                    self.assertEqual(responses, [403])
                    ports.assert_not_called()

    def test_same_origin_command_is_accepted(self):
        handler = object.__new__(bridge.WigleWWWHandler)
        handler.path = '/api/cmd'
        raw = b'{"cmd":"ping"}'
        handler.headers = {'Host': 'localhost:8088', 'Origin': 'http://localhost:8088',
                           'Content-Length': str(len(raw))}
        handler.server = SimpleNamespace(server_address=('127.0.0.1', 8088))
        handler.rfile = io.BytesIO(raw)
        responses = []
        handler._send = lambda status, *args: responses.append(status)
        with patch.object(bridge, 'discover_ports', return_value=[]) as ports, patch.object(bridge, 'send_and_collect', return_value=[]) as scan:
            handler.do_POST()
        self.assertEqual(responses, [200])
        scan.assert_called_once_with([], 'PING', wait_s=0.4)

    def test_disabled_cli_upload_does_not_probe(self):
        with patch('sys.argv', ['wiglewww', '--upload']), patch.object(bridge, 'discover_ports') as ports, patch.object(bridge, 'send_and_collect') as scan, patch('sys.stdout', io.StringIO()):
            self.assertEqual(bridge.main(), 2)
        ports.assert_not_called()
        scan.assert_not_called()
        self.assertFalse(bridge.upload_csv_anonymously('synthetic')['ok'])

    def test_csv_preserves_text_and_unknown_location(self):
        import csv
        row = dict(bssid='02:00:00:00:00:01', ssid='test,"quoted"\nname',
                   auth='OPEN', seen='2026-01-01', ch=1, rssi=-50)
        with patch.dict(bridge.BEACONS, {'test': row}, clear=True):
            records = list(csv.reader(io.StringIO(bridge.build_wigle_csv())))[2:]
        self.assertEqual(len(records), 1)
        self.assertEqual(records[0][1], row['ssid'])
        self.assertEqual(records[0][6:10], ['', '', '', ''])

if __name__ == '__main__':
    unittest.main()
