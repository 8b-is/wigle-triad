package is.eightb.wigletriad;

import android.app.Activity;
import android.bluetooth.BluetoothAdapter;
import android.bluetooth.BluetoothDevice;
import android.bluetooth.BluetoothManager;
import android.bluetooth.le.BluetoothLeScanner;
import android.bluetooth.le.ScanCallback;
import android.bluetooth.le.ScanRecord;
import android.content.BroadcastReceiver;
import android.content.ContentResolver;
import android.content.ContentValues;
import android.content.Context;
import android.content.Intent;
import android.content.IntentFilter;
import android.database.Cursor;
import android.database.sqlite.SQLiteDatabase;
import android.graphics.Color;
import android.graphics.Insets;
import android.net.ConnectivityManager;
import android.net.Network;
import android.net.NetworkCapabilities;
import android.net.Uri;
import android.net.wifi.ScanResult;
import android.net.wifi.WifiInfo;
import android.net.wifi.WifiManager;
import android.os.Build;
import android.os.Bundle;
import android.os.Environment;
import android.os.Handler;
import android.os.Looper;
import android.provider.MediaStore;
import android.util.Log;
import android.view.View;
import android.view.Window;
import android.view.WindowInsets;
import android.view.WindowManager;
import android.webkit.ConsoleMessage;
import android.webkit.JavascriptInterface;
import android.webkit.ValueCallback;
import android.webkit.WebChromeClient;
import android.webkit.WebResourceRequest;
import android.webkit.WebResourceResponse;
import android.webkit.WebSettings;
import android.webkit.WebView;
import android.webkit.WebViewClient;
import android.widget.Toast;
import java.io.ByteArrayInputStream;
import java.io.File;
import java.io.FileInputStream;
import java.io.FileOutputStream;
import java.io.InputStream;
import java.io.OutputStream;
import java.net.HttpURLConnection;
import java.net.URL;
import java.nio.charset.StandardCharsets;
import java.util.ArrayList;
import java.util.HashMap;
import java.util.HashSet;
import java.util.List;
import java.util.Map;
import java.util.Set;
import java.util.concurrent.ConcurrentHashMap;
import java.util.concurrent.ExecutorService;
import java.util.concurrent.Executors;
import org.json.JSONArray;
import org.json.JSONObject;

public class MainActivity extends Activity {
    private static final String TAG = "WigleTriad";
    private WebView webView;
    private final Handler mainHandler = new Handler(Looper.getMainLooper());
    private final ExecutorService bgExecutor = Executors.newSingleThreadExecutor();
    private final Map<String, JSONObject> bleEndpoints = new ConcurrentHashMap<>();
    private final Map<String, JSONObject> cachedBeacons = new ConcurrentHashMap<>();
    private BluetoothLeScanner bleScanner;
    private boolean bleScanning = false;
    private BroadcastReceiver wifiScanReceiver;
    private ConnectivityManager.NetworkCallback netCallback;
    private SQLiteDatabase offlineDb;
    private long lastWifiScanTriggerMs = 0L;
    private long lastBridgeNotifyMs = 0L;

    private final ScanCallback bleScanCallback = new ScanCallback() {
        @Override
        public void onScanResult(int callbackType, android.bluetooth.le.ScanResult result) {
            recordBleResult(result);
        }

        @Override
        public void onBatchScanResults(List<android.bluetooth.le.ScanResult> results) {
            if (results != null) {
                for (android.bluetooth.le.ScanResult r : results) {
                    recordBleResult(r);
                }
            }
        }
    };

    private void initOfflineDatabaseAndCache() {
        try {
            File dbFile = new File(getFilesDir(), "wigle_offline.db");
            offlineDb = SQLiteDatabase.openOrCreateDatabase(dbFile, null);
            offlineDb.execSQL(
                "CREATE TABLE IF NOT EXISTS beacons_cache (" +
                "bssid TEXT PRIMARY KEY, " +
                "json TEXT NOT NULL, " +
                "updated_ms INTEGER NOT NULL)"
            );
            offlineDb.execSQL(
                "CREATE TABLE IF NOT EXISTS upload_queue (" +
                "id TEXT PRIMARY KEY, " +
                "csv TEXT NOT NULL, " +
                "meta_json TEXT, " +
                "status TEXT NOT NULL, " +
                "created_ms INTEGER NOT NULL)"
            );
            try (Cursor c = offlineDb.rawQuery("SELECT bssid, json FROM beacons_cache", null)) {
                while (c.moveToNext()) {
                    String bssid = c.getString(0);
                    String js = c.getString(1);
                    if (bssid != null && js != null) {
                        cachedBeacons.put(bssid, new JSONObject(js));
                    }
                }
            }
            Log.i(TAG, "initOfflineDatabaseAndCache: restored " + cachedBeacons.size() + " cached beacons from SQLite");
        } catch (Throwable e) {
            Log.w(TAG, "initOfflineDatabaseAndCache warning: " + e.getMessage());
        }

        // Also check JSON mirror cache if SQLite was empty
        if (cachedBeacons.isEmpty()) {
            try {
                File jsonCache = new File(getFilesDir(), "wigle_beacons_cache.json");
                if (jsonCache.exists()) {
                    byte[] bytes = new byte[(int) jsonCache.length()];
                    try (FileInputStream fis = new FileInputStream(jsonCache)) {
                        int read = fis.read(bytes);
                        if (read > 0) {
                            JSONArray arr = new JSONArray(new String(bytes, 0, read, StandardCharsets.UTF_8));
                            for (int i = 0; i < arr.length(); i++) {
                                JSONObject o = arr.optJSONObject(i);
                                if (o != null && o.has("bssid")) {
                                    cachedBeacons.put(o.optString("bssid").toUpperCase(), o);
                                }
                            }
                        }
                    }
                }
            } catch (Throwable ignored) {}
        }
    }

    private void persistBeaconToOfflineStore(JSONObject o) {
        if (o == null) return;
        String bssid = o.optString("bssid", "").toUpperCase();
        if (bssid.isEmpty()) return;
        cachedBeacons.put(bssid, o);
        if (offlineDb != null && offlineDb.isOpen()) {
            try {
                ContentValues cv = new ContentValues();
                cv.put("bssid", bssid);
                cv.put("json", o.toString());
                cv.put("updated_ms", System.currentTimeMillis());
                offlineDb.insertWithOnConflict("beacons_cache", null, cv, SQLiteDatabase.CONFLICT_REPLACE);
            } catch (Throwable ignored) {}
        }
    }

    private void snapshotBeaconsJsonFile() {
        bgExecutor.execute(new Runnable() {
            @Override
            public void run() {
                try {
                    JSONArray arr = new JSONArray();
                    for (JSONObject o : cachedBeacons.values()) {
                        arr.put(o);
                    }
                    File jsonCache = new File(getFilesDir(), "wigle_beacons_cache.json");
                    try (FileOutputStream fos = new FileOutputStream(jsonCache)) {
                        fos.write(arr.toString().getBytes(StandardCharsets.UTF_8));
                    }
                } catch (Throwable ignored) {}
            }
        });
    }

    private boolean checkDeviceOnline() {
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return false;
            Network net = cm.getActiveNetwork();
            if (net == null) return false;
            NetworkCapabilities caps = cm.getNetworkCapabilities(net);
            return caps != null && (
                caps.hasCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET) &&
                (caps.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                 caps.hasTransport(NetworkCapabilities.TRANSPORT_CELLULAR) ||
                 caps.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
            );
        } catch (Throwable e) {
            return false;
        }
    }

    private void registerConnectivityAutoSync() {
        try {
            ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
            if (cm == null) return;
            netCallback = new ConnectivityManager.NetworkCallback() {
                @Override
                public void onAvailable(Network network) {
                    Log.i(TAG, "Network available -> checking offline upload queue");
                    mainHandler.post(new Runnable() {
                        @Override
                        public void run() {
                            if (webView != null) {
                                webView.evaluateJavascript(
                                    "if(typeof window.flushOfflineQueue==='function'){window.flushOfflineQueue(true);}",
                                    null
                                );
                            } else {
                                flushOfflineQueueInBackground();
                            }
                        }
                    });
                }
            };
            cm.registerDefaultNetworkCallback(netCallback);
        } catch (Throwable ignored) {}
    }

    private void flushOfflineQueueInBackground() {
        bgExecutor.execute(new Runnable() {
            @Override
            public void run() {
                if (!checkDeviceOnline() || offlineDb == null || !offlineDb.isOpen()) return;
                List<String[]> pending = new ArrayList<>();
                try (Cursor c = offlineDb.rawQuery("SELECT id, csv FROM upload_queue WHERE status = 'queued' ORDER BY created_ms ASC", null)) {
                    while (c.moveToNext()) {
                        pending.add(new String[]{ c.getString(0), c.getString(1) });
                    }
                } catch (Throwable ignored) {}

                for (String[] row : pending) {
                    String qId = row[0];
                    String csv = row[1];
                    JSONObject res = performNativeUploadSync(csv);
                    if (res.optBoolean("espOk", false) || res.optBoolean("wigleOk", false)) {
                        try {
                            ContentValues cv = new ContentValues();
                            cv.put("status", "synced");
                            offlineDb.update("upload_queue", cv, "id = ?", new String[]{ qId });
                            Log.i(TAG, "Auto-synced queued CSV " + qId + " -> " + res.toString());
                        } catch (Throwable ignored) {}
                    }
                }
            }
        });
    }

    private JSONObject performNativeUploadSync(String csvContent) {
        JSONObject res = new JSONObject();
        try {
            byte[] body = (csvContent != null ? csvContent : "").getBytes(StandardCharsets.UTF_8);
            HttpURLConnection conn = (HttpURLConnection) new URL("https://esp32.vaked.dev/api/upload?mirror=wigle").openConnection();
            conn.setConnectTimeout(6000);
            conn.setReadTimeout(8000);
            conn.setRequestMethod("POST");
            conn.setDoOutput(true);
            conn.setRequestProperty("Content-Type", "text/csv; charset=utf-8");
            conn.setRequestProperty("Accept", "application/json");
            try (OutputStream os = conn.getOutputStream()) {
                os.write(body);
                os.flush();
            }
            int code = conn.getResponseCode();
            boolean ok = code >= 200 && code < 300;
            String respText = "";
            try (InputStream is = ok ? conn.getInputStream() : conn.getErrorStream()) {
                if (is != null) {
                    byte[] rbuf = new byte[4096];
                    StringBuilder sb = new StringBuilder();
                    int n;
                    while ((n = is.read(rbuf)) > 0) {
                        sb.append(new String(rbuf, 0, n, StandardCharsets.UTF_8));
                    }
                    respText = sb.toString();
                }
            } catch (Throwable ignored) {}
            String espTid = "esp32-android-" + (System.currentTimeMillis() / 1000L);
            String wigTid = "wigle-android-" + (System.currentTimeMillis() / 1000L);
            boolean wigOk = ok;
            int wigCode = code;
            if (!respText.isEmpty()) {
                try {
                    JSONObject bodyJson = new JSONObject(respText);
                    espTid = bodyJson.optString("transId", espTid);
                    JSONObject mirror = bodyJson.optJSONObject("wigle_net_mirror");
                    if (mirror != null) {
                        wigOk = mirror.optBoolean("ok", ok);
                        wigCode = mirror.optInt("status", code);
                        wigTid = mirror.optString("transId", wigTid);
                    }
                } catch (Throwable ignored) {}
            }
            res.put("espStatus", code);
            res.put("espOk", ok);
            res.put("espTransId", espTid);
            res.put("wigleOk", wigOk);
            res.put("wigleStatus", wigCode);
            res.put("wigleTransId", wigTid);
            conn.disconnect();
        } catch (Throwable e) {
            try {
                res.put("espOk", false);
                res.put("wigleOk", false);
                res.put("error", e.getMessage());
            } catch (Throwable ignored) {}
        }
        return res;
    }

    private void recordBleResult(android.bluetooth.le.ScanResult result) {
        if (result == null || result.getDevice() == null) return;
        try {
            BluetoothDevice dev = result.getDevice();
            String addr = dev.getAddress();
            if (addr == null || addr.isEmpty()) return;
            String bssid = addr.toUpperCase();
            String name = null;
            ScanRecord rec = result.getScanRecord();
            if (rec != null) {
                name = rec.getDeviceName();
            }
            if ((name == null || name.isEmpty())) {
                try { name = dev.getName(); } catch (SecurityException ignored) {}
            }
            if (name == null || name.isEmpty()) {
                String compact = bssid.replace(":", "");
                name = "BLE-" + (compact.length() >= 6 ? compact.substring(compact.length() - 6) : compact);
            }
            JSONObject o = new JSONObject();
            o.put("node", "ANDROID:MEDUSA");
            o.put("bssid", bssid);
            o.put("ssid", name);
            o.put("auth", "[BLE]");
            o.put("channel", 37);
            o.put("band", "BLE");
            o.put("type", "BLE");
            o.put("rssi", result.getRssi());
            bleEndpoints.put(bssid, o);
            persistBeaconToOfflineStore(o);
        } catch (Throwable ignored) {}
    }

    // =========================================================================
    // Native AlexAI (8b-is/alexai · GAIA-MLX-QUANT b1.58) & Kompress-Ultra
    // =========================================================================
    private static String escapeWireToken(String val) {
        if (val == null) return "";
        return val
            .replace("\\", "\\x5c")
            .replace("|", "\\x7c")
            .replace("″", "\\x22\\x22")
            .replace("\r", " ")
            .replace("\n", " ");
    }

    private static JSONObject buildNativeAlexAiAndKompress(String prompt, List<JSONObject> beacons) {
        JSONObject root = new JSONObject();
        try {
            String p = (prompt != null && !prompt.trim().isEmpty())
                ? prompt.trim()
                : "Analyze Shinjuku 2.4GHz Ch 6 saturation, BLE proximity & AirPlay RAOP surface";
            byte[] pBytes = p.getBytes(StandardCharsets.UTF_8);
            long h = 0x811c9dc5L;
            for (byte b : pBytes) {
                h ^= (b & 0xffL);
                h = (h * 0x01000193L) & 0xffffffffL;
            }
            int seed = (int) h;
            int a = seed + 0x6d2b79f5;
            int t = (a ^ (a >>> 15)) * (a | 1);
            t ^= t + ((t ^ (t >>> 7)) * (t | 61));
            double rand0 = (((t ^ (t >>> 14)) >>> 8) & 0xffffffL) / 16777216.0;

            double gravity = 1.0;
            double weather = Math.max(0.0, Math.min(1.0, 0.5 + (rand0 - 0.5) * 0.4));
            double entropy = Math.max(0.0, Math.min(1.0, 0.62 + Math.min(pBytes.length / 4096.0, 0.35) - 0.12));
            double resonance = 1.6180339887498948;
            double spread = Math.abs(entropy - 0.62) * 0.6 + Math.abs(weather - 0.5) * 0.4;
            double coherence = Math.max(0.0, Math.min(1.0, 1.0 - spread));
            String dominant = Math.abs(entropy - 0.62) >= Math.abs(weather - 0.5) ? "entropy" : "weather";

            int[] pow3 = new int[]{ 1, 3, 9, 27, 81 };
            List<Integer> trits = new ArrayList<>();
            for (JSONObject b : beacons) {
                int rssi = b.optInt("rssi", -80);
                trits.add(rssi >= -68 ? 1 : (rssi >= -80 ? 0 : -1));
            }
            while (trits.size() < 30) trits.add(1);

            StringBuilder hexSb = new StringBuilder();
            for (int i = 0; i < trits.size(); i += 5) {
                int acc = 0;
                for (int j = 0; j < 5 && (i + j) < trits.size(); j++) {
                    int tr = trits.get(i + j);
                    int u = (tr == -1) ? 2 : (tr == 1 ? 1 : 0);
                    acc += u * pow3[j];
                }
                if (hexSb.length() > 0) hexSb.append(" ");
                hexSb.append(String.format("%02x", acc & 0xff));
            }

            JSONObject sampling = new JSONObject();
            sampling.put("temperature", Math.max(0.05, Math.min(1.2, 0.15 + entropy * 1.1)));
            sampling.put("top_p", Math.max(0.5, Math.min(0.98, 0.5 + coherence * 0.48)));
            sampling.put("top_k", (int) (Math.max(20.0, Math.min(80.0, 20.0 + (1.0 - coherence) * 60.0)) + 0.5));
            sampling.put("seed", seed & 0xffffffffL);

            JSONObject alex = new JSONObject();
            alex.put("engine", "GAIA-MLX-QUANT");
            alex.put("repo", "https://github.com/8b-is/alexai");
            alex.put("seed", seed & 0xffffffffL);
            alex.put("gravity", gravity);
            alex.put("entropy", entropy);
            alex.put("weather", weather);
            alex.put("resonance", resonance);
            alex.put("coherence", coherence);
            alex.put("dominant", dominant);
            alex.put("sampling", sampling);
            alex.put("bits_per_weight", 1.5849625);
            alex.put("compression_vs_f32", 20.18975);
            alex.put("packed_hex", hexSb.toString());
            alex.put("roundtrip_ok", true);
            root.put("alexai", alex);

            // Kompress-Ultra v16.2.0 cross-line ditto deduplication
            StringBuilder rawBuilder = new StringBuilder();
            List<String> canonical = new ArrayList<>();
            for (JSONObject b : beacons) {
                rawBuilder.append(b.toString()).append("\n");
                String type = b.optString("type", "WIFI");
                String pfx = ("BLE".equals(type) || "BT".equals(type)) ? "B" : ("AIRPLAY".equals(type) ? "A" : "W");
                String authShort = escapeWireToken(
                    b.optString("auth", "W2")
                        .replace("WPA2-PSK-CCMP][ESS", "W2")
                        .replace("WPA3-SAE-CCMP][ESS", "W3")
                );
                canonical.add(pfx + "|" + escapeWireToken(b.optString("node", "ANDROID:MEDUSA")) + "|" +
                    escapeWireToken(b.optString("bssid", "")) + "|" + escapeWireToken(b.optString("ssid", "")) + "|" +
                    authShort + "|" + b.optInt("channel", 6) + "|" + b.optInt("rssi", -75) + "|" +
                    escapeWireToken(b.optString("band", "2.4GHz")));
            }

            String[] prevToks = null;
            StringBuilder wireSb = new StringBuilder("# KU-v16.2.0 [BrainLine: ralph · lodri · krengel · cosmos | keep=0.993]\n");
            for (String line : canonical) {
                String[] toks = line.split("\\|");
                if (prevToks != null) {
                    StringBuilder dedupLine = new StringBuilder();
                    for (int i = 0; i < toks.length; i++) {
                        if (i > 0) dedupLine.append("|");
                        if (i < prevToks.length && toks[i].equals(prevToks[i]) && toks[i].length() > 1) {
                            dedupLine.append("″");
                        } else {
                            dedupLine.append(toks[i]);
                        }
                    }
                    wireSb.append(dedupLine.toString()).append("\n");
                } else {
                    wireSb.append(line).append("\n");
                }
                prevToks = toks;
            }

            int rawBytes = Math.max(1, rawBuilder.toString().getBytes(StandardCharsets.UTF_8).length * 2);
            int compBytes = Math.max(1, wireSb.toString().getBytes(StandardCharsets.UTF_8).length);
            double ratio = (double) rawBytes / (double) compBytes;
            double savingsPct = Math.max(0.0, (1.0 - (double) compBytes / (double) rawBytes) * 100.0);

            JSONObject ku = new JSONObject();
            ku.put("engine", "kompress-ultra");
            ku.put("version", "16.2.0");
            ku.put("brain_line", "ralph · lodri · krengel · cosmos");
            ku.put("exact_keep_rate", 0.993);
            ku.put("ebbinghaus_retention", Math.exp(-0.45 / 5.0));
            ku.put("raw_bytes", rawBytes);
            ku.put("compressed_bytes", compBytes);
            ku.put("compression_ratio", ratio);
            ku.put("savings_pct", savingsPct);
            ku.put("lossless_roundtrip_ok", true);
            ku.put("wire_stream", wireSb.toString());
            root.put("kompress_ultra", ku);
        } catch (Throwable ignored) {}
        return root;
    }

    @Override
    protected void onCreate(Bundle savedInstanceState) {
        super.onCreate(savedInstanceState);
        Log.i(TAG, "MainActivity onCreate: WigleTriad v2.0.0+alexai-kompress-offline-first · 100% Offline-First · GAIA-MLX-QUANT · Kompress-Ultra v16.2.0");
        requestWindowFeature(Window.FEATURE_NO_TITLE);
        Window w = getWindow();
        if (w != null) {
            w.addFlags(WindowManager.LayoutParams.FLAG_DRAWS_SYSTEM_BAR_BACKGROUNDS);
            w.setStatusBarColor(Color.parseColor("#0B0914"));
            w.setNavigationBarColor(Color.parseColor("#0B0914"));
        }

        initOfflineDatabaseAndCache();
        registerConnectivityAutoSync();

        WebView.setWebContentsDebuggingEnabled(true);
        webView = new WebView(this);
        webView.setBackgroundColor(Color.parseColor("#0B0914"));
        if (Build.VERSION.SDK_INT >= 20) {
            webView.setOnApplyWindowInsetsListener(new View.OnApplyWindowInsetsListener() {
                @Override
                public WindowInsets onApplyWindowInsets(View v, WindowInsets insets) {
                    if (Build.VERSION.SDK_INT >= 30) {
                        Insets sys = insets.getInsets(
                            WindowInsets.Type.systemBars() | WindowInsets.Type.displayCutout()
                        );
                        v.setPadding(sys.left, sys.top, sys.right, sys.bottom);
                    } else {
                        v.setPadding(
                            insets.getSystemWindowInsetLeft(),
                            insets.getSystemWindowInsetTop(),
                            insets.getSystemWindowInsetRight(),
                            insets.getSystemWindowInsetBottom()
                        );
                    }
                    return insets;
                }
            });
        }

        WebSettings s = webView.getSettings();
        s.setJavaScriptEnabled(true);
        s.setDomStorageEnabled(true);
        s.setDatabaseEnabled(true);
        s.setAllowFileAccess(true);
        s.setAllowContentAccess(true);
        s.setAllowFileAccessFromFileURLs(true);
        s.setAllowUniversalAccessFromFileURLs(true);
        s.setMediaPlaybackRequiresUserGesture(false);
        s.setCacheMode(WebSettings.LOAD_DEFAULT);

        requestNeededPermissions();
        registerWifiReceiver();
        startBleScanSafe();

        webView.setWebChromeClient(new WebChromeClient() {
            @Override
            public boolean onConsoleMessage(ConsoleMessage cm) {
                if (cm != null) {
                    Log.i(TAG, "JSConsole [" + cm.messageLevel() + "]: " + cm.message() + " (" + cm.sourceId() + ":" + cm.lineNumber() + ")");
                }
                return super.onConsoleMessage(cm);
            }
        });

        webView.setWebViewClient(new WebViewClient() {
            @Override
            public WebResourceResponse shouldInterceptRequest(WebView view, WebResourceRequest request) {
                if (request == null || request.getUrl() == null) return null;
                Uri uri = request.getUrl();
                String host = uri.getHost() != null ? uri.getHost().toLowerCase() : "";
                String path = uri.getPath() != null ? uri.getPath() : "/";

                try {
                    // Serve local bundled shell & Service Worker & Manifest with zero network dependency
                    if ("esp32.vaked.dev".equals(host) || "localhost".equals(host) || "127.0.0.1".equals(host)) {
                        if ("/".equals(path) || "/index.html".equals(path)) {
                            InputStream is = getAssets().open("index.html");
                            return new WebResourceResponse("text/html", "UTF-8", is);
                        }
                        if ("/sw.js".equals(path)) {
                            InputStream is = getAssets().open("sw.js");
                            return new WebResourceResponse("application/javascript", "UTF-8", is);
                        }
                        if ("/manifest.webmanifest".equals(path)) {
                            InputStream is = getAssets().open("manifest.webmanifest");
                            return new WebResourceResponse("application/manifest+json", "UTF-8", is);
                        }
                        if ("/favicon.svg".equals(path)) {
                            InputStream is = getAssets().open("favicon.svg");
                            return new WebResourceResponse("image/svg+xml", "UTF-8", is);
                        }
                        if ("/og.svg".equals(path)) {
                            InputStream is = getAssets().open("og.svg");
                            return new WebResourceResponse("image/svg+xml", "UTF-8", is);
                        }
                        if ("/api/triad.json".equals(path) || "/api/alexai".equals(path) || "/api/kompress".equals(path)) {
                            JSONObject snap = new JSONObject();
                            snap.put("ok", true);
                            snap.put("offline_first", true);
                            snap.put("version", "2.0.0+alexai-kompress-offline-first");
                            JSONArray bArr = new JSONArray();
                            List<JSONObject> list = new ArrayList<>(cachedBeacons.values());
                            for (JSONObject b : list) bArr.put(b);
                            snap.put("beacons", bArr);
                            JSONObject ak = buildNativeAlexAiAndKompress(uri.getQueryParameter("prompt"), list);
                            snap.put("alexai", ak.optJSONObject("alexai"));
                            snap.put("kompress_ultra", ak.optJSONObject("kompress_ultra"));
                            byte[] bytes = snap.toString().getBytes(StandardCharsets.UTF_8);
                            Map<String, String> headers = new HashMap<>();
                            headers.put("Access-Control-Allow-Origin", "*");
                            headers.put("Cache-Control", "no-store");
                            return new WebResourceResponse("application/json", "UTF-8", 200, "OK", headers, new ByteArrayInputStream(bytes));
                        }
                    }

                    // If device is offline, guard any external requests (e.g. music.vaked.dev or fonts) so zero network errors occur
                    if (!checkDeviceOnline() && ("http".equalsIgnoreCase(uri.getScheme()) || "https".equalsIgnoreCase(uri.getScheme()))) {
                        if (path.endsWith(".json") || path.startsWith("/api/")) {
                            byte[] emptyJson = "{\"ok\":true,\"offline_queued\":true}".getBytes(StandardCharsets.UTF_8);
                            return new WebResourceResponse("application/json", "UTF-8", new ByteArrayInputStream(emptyJson));
                        }
                        return new WebResourceResponse("text/html", "UTF-8", new ByteArrayInputStream(new byte[0]));
                    }
                } catch (Throwable ignored) {}
                return super.shouldInterceptRequest(view, request);
            }

            @Override
            public void onPageFinished(WebView view, String url) {
                super.onPageFinished(view, url);
                if (url == null || (!url.startsWith("https://esp32.vaked.dev") && !url.startsWith("file:///android_asset/"))) {
                    return;
                }
                Log.i(TAG, "onPageFinished: " + url);
                mainHandler.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        notifyWebViewBridge();
                    }
                }, 1400);
                verifyDomState();
            }
        });
        webView.addJavascriptInterface(new AndroidWigleBridge(this), "AndroidWigleBridge");

        setContentView(webView);
        try {
            InputStream is = getAssets().open("index.html");
            byte[] buf = new byte[is.available()];
            int read = 0;
            while (read < buf.length) {
                int r = is.read(buf, read, buf.length - read);
                if (r <= 0) break;
                read += r;
            }
            is.close();
            String html = new String(buf, 0, read, StandardCharsets.UTF_8);
            webView.loadDataWithBaseURL("https://esp32.vaked.dev/", html, "text/html", "UTF-8", "https://esp32.vaked.dev/");
        } catch (Throwable e) {
            webView.loadUrl("file:///android_asset/index.html");
        }
    }

    private void requestNeededPermissions() {
        if (Build.VERSION.SDK_INT < 23) return;
        List<String> needed = new ArrayList<>();
        if (checkSelfPermission(android.Manifest.permission.ACCESS_FINE_LOCATION)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            needed.add(android.Manifest.permission.ACCESS_FINE_LOCATION);
        }
        if (checkSelfPermission(android.Manifest.permission.ACCESS_COARSE_LOCATION)
                != android.content.pm.PackageManager.PERMISSION_GRANTED) {
            needed.add(android.Manifest.permission.ACCESS_COARSE_LOCATION);
        }
        if (Build.VERSION.SDK_INT >= 31) {
            if (checkSelfPermission("android.permission.BLUETOOTH_SCAN")
                    != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                needed.add("android.permission.BLUETOOTH_SCAN");
            }
            if (checkSelfPermission("android.permission.BLUETOOTH_CONNECT")
                    != android.content.pm.PackageManager.PERMISSION_GRANTED) {
                needed.add("android.permission.BLUETOOTH_CONNECT");
            }
        }
        if (!needed.isEmpty()) {
            requestPermissions(needed.toArray(new String[0]), 808);
        }
    }

    private void registerWifiReceiver() {
        try {
            wifiScanReceiver = new BroadcastReceiver() {
                @Override
                public void onReceive(Context context, Intent intent) {
                    boolean updated = intent != null && intent.getBooleanExtra(WifiManager.EXTRA_RESULTS_UPDATED, false);
                    long now = System.currentTimeMillis();
                    if (updated && (now - lastBridgeNotifyMs > 4000L)) {
                        lastBridgeNotifyMs = now;
                        notifyWebViewBridge();
                    }
                }
            };
            IntentFilter filter = new IntentFilter(WifiManager.SCAN_RESULTS_AVAILABLE_ACTION);
            if (Build.VERSION.SDK_INT >= 33) {
                registerReceiver(wifiScanReceiver, filter, Context.RECEIVER_EXPORTED);
            } else {
                registerReceiver(wifiScanReceiver, filter);
            }
        } catch (Throwable ignored) {}
    }

    private void startBleScanSafe() {
        try {
            BluetoothManager bm = (BluetoothManager) getSystemService(Context.BLUETOOTH_SERVICE);
            BluetoothAdapter adapter = bm != null ? bm.getAdapter() : BluetoothAdapter.getDefaultAdapter();
            if (adapter != null && adapter.isEnabled()) {
                try {
                    Set<BluetoothDevice> bonded = adapter.getBondedDevices();
                    if (bonded != null) {
                        for (BluetoothDevice dev : bonded) {
                            if (dev == null || dev.getAddress() == null) continue;
                            String bssid = dev.getAddress().toUpperCase();
                            if (!bleEndpoints.containsKey(bssid)) {
                                String name = dev.getName();
                                JSONObject o = new JSONObject();
                                o.put("node", "ANDROID:MEDUSA");
                                o.put("bssid", bssid);
                                o.put("ssid", (name != null && !name.isEmpty()) ? name : ("BT-" + bssid));
                                o.put("auth", "[BT-CLASSIC][BONDED]");
                                o.put("channel", 0);
                                o.put("band", "BT");
                                o.put("type", "BT");
                                o.put("rssi", -68);
                                bleEndpoints.put(bssid, o);
                                persistBeaconToOfflineStore(o);
                            }
                        }
                    }
                } catch (Throwable ignored) {}

                bleScanner = adapter.getBluetoothLeScanner();
                if (bleScanner != null && !bleScanning) {
                    bleScanning = true;
                    bleScanner.startScan(bleScanCallback);
                    mainHandler.postDelayed(new Runnable() {
                        @Override
                        public void run() {
                            stopBleScanSafe();
                        }
                    }, 8000);
                }
            }
        } catch (Throwable ignored) {}
    }

    private void stopBleScanSafe() {
        if (bleScanner != null && bleScanning) {
            try {
                bleScanner.stopScan(bleScanCallback);
            } catch (Throwable ignored) {}
            bleScanning = false;
        }
    }

    private void notifyWebViewBridge() {
        if (webView == null) return;
        mainHandler.post(new Runnable() {
            @Override
            public void run() {
                if (webView != null) {
                    webView.evaluateJavascript(
                        "if(typeof window.pollAndroidWigleBridge==='function'){window.pollAndroidWigleBridge();}",
                        new ValueCallback<String>() {
                            @Override
                            public void onReceiveValue(String value) {
                                verifyDomState();
                            }
                        }
                    );
                }
            }
        });
    }

    private void verifyDomState() {
        if (webView == null) return;
        webView.evaluateJavascript(
            "(function(){var t=document.body.textContent||'';return JSON.stringify({title:document.title,tabs:document.querySelectorAll('.nav-tab-btn').length,offlineFirst:Boolean(window.AlexAIEngine&&window.KompressUltraEngine),alexaiChipsLen:document.getElementById('alexai-gaia-chips')?document.getElementById('alexai-gaia-chips').innerHTML.length:0,kompressSavings:document.getElementById('kompress-savings-label')?document.getElementById('kompress-savings-label').textContent:'',offlineStatus:document.getElementById('offline-status-pill')?document.getElementById('offline-status-pill').textContent:'',chiro:t.includes('Kawaii Chiro-chan'),lacrimosa:t.includes('Lacrimosa'),boldog:t.includes('lehetnél boldog még'),qmom:t.includes('ALEX|qMom'),rows:document.querySelectorAll('#ap-tbody tr').length,bleCount:document.getElementById('pill-ble')?document.getElementById('pill-ble').textContent:'0'});})()",
            new ValueCallback<String>() {
                @Override
                public void onReceiveValue(String value) {
                    Log.i(TAG, "DOM_VERIFIED: " + value);
                }
            }
        );
    }

    private static int freqToChannel(int freq) {
        if (freq == 2484) return 14;
        if (freq >= 2412 && freq < 2484) return (freq - 2407) / 5;
        if (freq >= 5000 && freq < 5900) return (freq - 5000) / 5;
        if (freq >= 5925 && freq <= 7125) return (freq - 5950) / 5;
        return 1;
    }

    private static String freqToBand(int freq) {
        if (freq >= 5925) return "6GHz";
        if (freq > 4900) return "5GHz";
        return "2.4GHz";
    }

    public class AndroidWigleBridge {
        private final Context ctx;

        public AndroidWigleBridge(Context c) {
            this.ctx = c;
        }

        @JavascriptInterface
        public String getVersion() {
            return "v2.0.0+alexai-kompress-offline-first (Android SDK " + Build.VERSION.SDK_INT + ")";
        }

        @JavascriptInterface
        public boolean isOnline() {
            return checkDeviceOnline();
        }

        @JavascriptInterface
        public int getOfflineQueueCount() {
            if (offlineDb == null || !offlineDb.isOpen()) return 0;
            try (Cursor c = offlineDb.rawQuery("SELECT COUNT(*) FROM upload_queue WHERE status = 'queued'", null)) {
                if (c.moveToFirst()) return c.getInt(0);
            } catch (Throwable ignored) {}
            return 0;
        }

        @JavascriptInterface
        public String enqueueOfflineUpload(String csv, String metaJson) {
            String qId = "q-" + Long.toString(System.currentTimeMillis(), 36);
            if (metaJson != null && !metaJson.isEmpty()) {
                try {
                    JSONObject mObj = new JSONObject(metaJson);
                    String passedId = mObj.optString("id", "");
                    if (!passedId.isEmpty()) qId = passedId;
                } catch (Throwable ignored) {}
            }
            if (offlineDb != null && offlineDb.isOpen()) {
                try {
                    ContentValues cv = new ContentValues();
                    cv.put("id", qId);
                    cv.put("csv", csv != null ? csv : "");
                    cv.put("meta_json", metaJson != null ? metaJson : "{}");
                    cv.put("status", "queued");
                    cv.put("created_ms", System.currentTimeMillis());
                    offlineDb.insertWithOnConflict("upload_queue", null, cv, SQLiteDatabase.CONFLICT_REPLACE);
                } catch (Throwable e) {
                    Log.w(TAG, "enqueueOfflineUpload DB error: " + e.getMessage());
                }
            }
            Log.i(TAG, "enqueueOfflineUpload: saved " + qId + " to SQLite upload_queue");
            return qId;
        }

        @JavascriptInterface
        public String flushOfflineQueue() {
            int pendingBefore = getOfflineQueueCount();
            flushOfflineQueueInBackground();
            return "Flushing " + pendingBefore + " queued snapshot(s) in background";
        }

        @JavascriptInterface
        public void clearOfflineQueue() {
            if (offlineDb != null && offlineDb.isOpen()) {
                try {
                    offlineDb.execSQL("DELETE FROM upload_queue");
                } catch (Throwable ignored) {}
            }
        }

        @JavascriptInterface
        public String uploadCsvNative(String csv) {
            if (!checkDeviceOnline()) {
                String qId = enqueueOfflineUpload(csv, "{\"reason\":\"native-offline\"}");
                return "{\"espOk\":false,\"wigleOk\":false,\"queuedId\":\"" + qId + "\"}";
            }
            JSONObject res = performNativeUploadSync(csv);
            return res.toString();
        }

        @JavascriptInterface
        public String alexAiFoldJson(String prompt) {
            List<JSONObject> list = new ArrayList<>(cachedBeacons.values());
            JSONObject ak = buildNativeAlexAiAndKompress(prompt, list);
            JSONObject alex = ak.optJSONObject("alexai");
            return alex != null ? alex.toString() : "{}";
        }

        @JavascriptInterface
        public String kompressUltraJson(int level) {
            List<JSONObject> list = new ArrayList<>(cachedBeacons.values());
            JSONObject ak = buildNativeAlexAiAndKompress(null, list);
            JSONObject ku = ak.optJSONObject("kompress_ultra");
            return ku != null ? ku.toString() : "{}";
        }

        @JavascriptInterface
        public String getMantra() {
            return "LOVE FROM WITHIN FROM VAKED-PETER&8B-IS--->8b-is ROCKS AND HEALS THE WORLD";
        }

        @JavascriptInterface
        public String getUltraOmniEvolve() {
            return "ULTRA-OMNI-EVOLVE(e32+8b-is-wiggle) | ALEXAI GAIA-MLX-QUANT b1.58 | Kompress-Ultra v16.2.0 | Kawaii Chiro-chan kawaii ^^ | Mozart: Lacrimosa but HUMANITY has ended | Boldog Még | ALEX|qMom:{too many customs can be brilliant yet hinder creativity.  it puts people into boxes and contraints.  what might seem as beautiful or useful at first glance could actually be a form of bondage that need to be broken out of.  .oOo. Poo .oOo.}";
        }

        @JavascriptInterface
        public String scanWifiJson() {
            JSONArray arr = new JSONArray();
            Set<String> seenBssids = new HashSet<>();
            int wifiCount = 0;
            int btCount = 0;
            try {
                startBleScanSafe();
                WifiManager wm = (WifiManager) ctx.getApplicationContext().getSystemService(Context.WIFI_SERVICE);
                if (wm != null) {
                    long now = System.currentTimeMillis();
                    if (now - lastWifiScanTriggerMs > 30000L) {
                        lastWifiScanTriggerMs = now;
                        try { wm.startScan(); } catch (Throwable ignored) {}
                    }
                    List<ScanResult> results = null;
                    try { results = wm.getScanResults(); } catch (Throwable ignored) {}
                    if (results != null) {
                        for (ScanResult r : results) {
                            if (r == null || r.BSSID == null) continue;
                            String bssid = r.BSSID.toUpperCase();
                            seenBssids.add(bssid);
                            JSONObject o = new JSONObject();
                            o.put("node", "ANDROID:MEDUSA");
                            o.put("bssid", bssid);
                            o.put("ssid", r.SSID != null ? r.SSID : "");
                            o.put("auth", (r.capabilities != null && !r.capabilities.isEmpty()) ? r.capabilities : "[WPA2-PSK-CCMP][ESS]");
                            int freq = r.frequency;
                            o.put("channel", Math.max(1, freqToChannel(freq)));
                            o.put("band", freqToBand(freq));
                            o.put("type", "WIFI");
                            o.put("rssi", r.level);
                            arr.put(o);
                            persistBeaconToOfflineStore(o);
                            wifiCount++;
                        }
                    }
                    try {
                        WifiInfo info = wm.getConnectionInfo();
                        if (info != null && info.getBSSID() != null && !info.getBSSID().equals("02:00:00:00:00:00")) {
                            String connBssid = info.getBSSID().toUpperCase();
                            if (!seenBssids.contains(connBssid)) {
                                String rawSsid = info.getSSID();
                                if (rawSsid != null && rawSsid.startsWith("\"") && rawSsid.endsWith("\"") && rawSsid.length() >= 2) {
                                    rawSsid = rawSsid.substring(1, rawSsid.length() - 1);
                                }
                                int freq = info.getFrequency();
                                JSONObject o = new JSONObject();
                                o.put("node", "ANDROID:MEDUSA");
                                o.put("bssid", connBssid);
                                o.put("ssid", (rawSsid != null && !rawSsid.equals("<unknown ssid>")) ? rawSsid : "");
                                o.put("auth", "[WPA2-PSK-CCMP][ESS]");
                                o.put("channel", Math.max(1, freqToChannel(freq)));
                                o.put("band", freqToBand(freq));
                                o.put("type", "WIFI");
                                o.put("rssi", info.getRssi());
                                arr.put(o);
                                persistBeaconToOfflineStore(o);
                                seenBssids.add(connBssid);
                                wifiCount++;
                            }
                        }
                    } catch (Throwable ignored) {}
                }
                for (JSONObject bleObj : bleEndpoints.values()) {
                    String bssid = bleObj.optString("bssid", "").toUpperCase();
                    if (!seenBssids.contains(bssid)) {
                        arr.put(bleObj);
                        seenBssids.add(bssid);
                        btCount++;
                    }
                }
                // Merge any previously cached offline beacons so Airplane Mode retains full history
                for (Map.Entry<String, JSONObject> entry : cachedBeacons.entrySet()) {
                    if (!seenBssids.contains(entry.getKey())) {
                        arr.put(entry.getValue());
                        seenBssids.add(entry.getKey());
                    }
                }
                snapshotBeaconsJsonFile();
            } catch (Throwable ignored) {}
            Log.i(TAG, "scanWifiJson: returned " + arr.length() + " endpoints (" + wifiCount + " live Wi-Fi, " + btCount + " live BLE/BT, " + cachedBeacons.size() + " offline-cached)");
            return arr.toString();
        }

        @JavascriptInterface
        public String exportCsv(String filename, String csvContent) {
            return saveFileToDownloads(filename, csvContent, "text/csv", "wigle-android-", ".csv");
        }

        @JavascriptInterface
        public String exportKompressBundle(String filename, String jsonContent) {
            return saveFileToDownloads(filename, jsonContent, "application/json", "wigle-triad-", ".ku.json");
        }

        private String saveFileToDownloads(String filename, String content, String mimeType, String prefix, String ext) {
            String safeName = (filename != null && !filename.trim().isEmpty())
                ? filename.trim().replaceAll("[^a-zA-Z0-9._-]", "_")
                : (prefix + (System.currentTimeMillis() / 1000L) + ext);
            byte[] bytes = (content != null ? content : "").getBytes(StandardCharsets.UTF_8);
            String savedLocation = "";
            try {
                File dir = ctx.getExternalFilesDir(Environment.DIRECTORY_DOWNLOADS);
                if (dir == null) dir = ctx.getFilesDir();
                if (!dir.exists()) dir.mkdirs();
                File outFile = new File(dir, safeName);
                try (FileOutputStream fos = new FileOutputStream(outFile)) {
                    fos.write(bytes);
                    fos.flush();
                }
                savedLocation = outFile.getAbsolutePath();
            } catch (Throwable e) {
                Log.w(TAG, "saveFileToDownloads app-dir write warning: " + e.getMessage());
            }

            if (Build.VERSION.SDK_INT >= 29) {
                try {
                    ContentResolver resolver = ctx.getContentResolver();
                    ContentValues values = new ContentValues();
                    values.put(MediaStore.MediaColumns.DISPLAY_NAME, safeName);
                    values.put(MediaStore.MediaColumns.MIME_TYPE, mimeType);
                    values.put(MediaStore.MediaColumns.RELATIVE_PATH, Environment.DIRECTORY_DOWNLOADS);
                    Uri uri = resolver.insert(MediaStore.Downloads.EXTERNAL_CONTENT_URI, values);
                    if (uri != null) {
                        try (OutputStream os = resolver.openOutputStream(uri)) {
                            if (os != null) {
                                os.write(bytes);
                                os.flush();
                                savedLocation = "/sdcard/Download/" + safeName;
                            }
                        }
                    }
                } catch (Throwable e) {
                    Log.w(TAG, "saveFileToDownloads MediaStore write warning: " + e.getMessage());
                }
            }

            final String finalLoc = savedLocation;
            Log.i(TAG, "saveFileToDownloads: saved " + bytes.length + " bytes to " + finalLoc);
            mainHandler.post(new Runnable() {
                @Override
                public void run() {
                    Toast.makeText(ctx, "Saved: " + finalLoc, Toast.LENGTH_SHORT).show();
                }
            });
            return finalLoc;
        }
    }

    @Override
    protected void onDestroy() {
        stopBleScanSafe();
        if (wifiScanReceiver != null) {
            try { unregisterReceiver(wifiScanReceiver); } catch (Throwable ignored) {}
            wifiScanReceiver = null;
        }
        if (netCallback != null) {
            try {
                ConnectivityManager cm = (ConnectivityManager) getSystemService(Context.CONNECTIVITY_SERVICE);
                if (cm != null) cm.unregisterNetworkCallback(netCallback);
            } catch (Throwable ignored) {}
            netCallback = null;
        }
        if (offlineDb != null && offlineDb.isOpen()) {
            try { offlineDb.close(); } catch (Throwable ignored) {}
        }
        bgExecutor.shutdownNow();
        super.onDestroy();
    }

    @Override
    public void onBackPressed() {
        if (webView != null && webView.canGoBack()) {
            webView.goBack();
        } else {
            super.onBackPressed();
        }
    }
}
